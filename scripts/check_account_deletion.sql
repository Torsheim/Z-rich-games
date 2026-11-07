-- Run with psql against a disposable database with the profile, friendship,
-- and activity migrations applied. All fixtures and changes roll back.
\set ON_ERROR_STOP on
begin;

create function pg_temp.assert_true(ok boolean, description text)
returns void language plpgsql as $$
begin
  if ok is distinct from true then
    raise exception 'Account deletion regression: %', description;
  end if;
end;
$$;

create function pg_temp.expect_error(statement text, expected_code text, expected_detail text default null)
returns void language plpgsql as $$
declare
  detail text;
begin
  begin
    execute statement;
  exception when others then
    get stacked diagnostics detail = PG_EXCEPTION_DETAIL;
    if SQLSTATE = expected_code and (expected_detail is null or detail = expected_detail) then
      return;
    end if;
    raise;
  end;
  raise exception 'Expected SQLSTATE % from %', expected_code, statement;
end;
$$;
grant execute on function pg_temp.assert_true(boolean, text), pg_temp.expect_error(text, text, text)
  to anon, authenticated;

do $$
begin
  execute format('grant usage on schema %I to anon, authenticated', (
    select nspname from pg_namespace where oid = pg_my_temp_schema()
  ));
end;
$$;

select gen_random_uuid() as departing_user, gen_random_uuid() as remaining_admin,
       gen_random_uuid() as recipient, gen_random_uuid() as replacement,
       gen_random_uuid() as organization, gen_random_uuid() as personal_organizer,
       gen_random_uuid() as personal_activity, gen_random_uuid() as city, gen_random_uuid() as category
\gset

insert into auth.users (id, raw_user_meta_data)
select fixture_id::uuid, jsonb_build_object('username', 'qa_' || left(replace(fixture_id, '-', ''), 20))
from (values (:'departing_user'), (:'remaining_admin'), (:'recipient'), (:'replacement')) fixtures(fixture_id);
insert into public.cities (id, name) values (:'city', 'Test city');
insert into public.categories (id, name) values (:'category', 'Test category');
insert into public.organizers (id, type, user_id, name, verified_at) values
  (:'organization', 'organization', null, 'Test organization', now()),
  (:'personal_organizer', 'person', :'departing_user', 'Test personal organizer', null);
insert into public.organizer_members (organizer_id, user_id, role) values
  (:'organization', :'departing_user', 'owner'),
  (:'organization', :'remaining_admin', 'admin');

set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', :'departing_user', 'role', 'authenticated')::text, true);
select public.create_activity_draft(
  :'organization', 'Organization activity', 'Retained after account deletion.',
  :'category', now() + interval '1 day', 'Europe/Zurich', :'city', 'Venue',
  p_max_participants => 2
) as organization_activity
\gset
select public.publish_activity(:'organization_activity');
select public.join_activity(:'organization_activity');
select set_config('request.jwt.claims', jsonb_build_object('sub', :'recipient', 'role', 'authenticated')::text, true);
select public.join_activity(:'organization_activity');
reset role;

insert into public.activities (
  id, organizer_id, created_by_user_id, title, description, category_id, city_id,
  starts_at, timezone, place_name
) values (
  :'personal_activity', :'personal_organizer', :'departing_user', 'Personal activity',
  'Deleted with its organizer.', :'category', :'city', now() + interval '1 day',
  'Europe/Zurich', 'Venue'
);
insert into public.activity_participants (activity_id, user_id, status, confirmed_at)
values (:'personal_activity', :'recipient', 'confirmed', now());
insert into public.activity_invitations (activity_id, invited_user_id, invited_by_user_id, status) values
  (:'organization_activity', :'recipient', :'departing_user', 'accepted'),
  (:'organization_activity', :'departing_user', :'remaining_admin', 'pending'),
  (:'organization_activity', :'replacement', :'remaining_admin', 'pending'),
  (:'personal_activity', :'replacement', :'recipient', 'pending');
insert into public.friendships (user_low, user_high) values
  (least(:'departing_user'::uuid, :'recipient'::uuid), greatest(:'departing_user'::uuid, :'recipient'::uuid)),
  (least(:'recipient'::uuid, :'remaining_admin'::uuid), greatest(:'recipient'::uuid, :'remaining_admin'::uuid));
insert into public.friend_invites (owner_id) values (:'departing_user'), (:'recipient');

create temp table expected_activity as
  select to_jsonb(a) - array['created_by_user_id', 'updated_at'] as snapshot
  from public.activities a where id = :'organization_activity';
create temp table expected_organization as
  select to_jsonb(o) as snapshot from public.organizers o where id = :'organization';
create temp table expected_recipient as
  select to_jsonb(p) as snapshot from public.activity_participants p
  where activity_id = :'organization_activity' and user_id = :'recipient';

-- Start account deletion checks.
set local role anon;
select set_config('request.jwt.claims', '{}', true);
select pg_temp.expect_error(format('delete from auth.users where id = %L', :'departing_user'), '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', :'departing_user', 'role', 'authenticated')::text, true);
select pg_temp.expect_error(format('delete from auth.users where id = %L', :'departing_user'), '42501');
select set_config('request.jwt.claims', jsonb_build_object('sub', :'replacement', 'role', 'authenticated')::text, true);
select pg_temp.expect_error(
  format('select public.join_activity(%L)', :'organization_activity'), 'PT409', 'activity_full'
);
reset role;

-- This is the database deletion that Supabase Auth performs after authorization.
delete from auth.users where id = :'departing_user';

select pg_temp.assert_true(
  not exists (select 1 from auth.users where id = :'departing_user')
  and not exists (select 1 from public.profiles where id = :'departing_user')
  and not exists (select 1 from public.friendships where :'departing_user' in (user_low, user_high))
  and not exists (select 1 from public.friend_invites where owner_id = :'departing_user')
  and exists (select 1 from public.profiles where id = :'recipient')
  and exists (select 1 from public.friendships where :'recipient' in (user_low, user_high)
                and :'remaining_admin' in (user_low, user_high))
  and exists (select 1 from public.friend_invites where owner_id = :'recipient'),
  'profile and friendship cleanup preserves unrelated users and relationships'
);
select pg_temp.assert_true(
  not exists (select 1 from public.organizer_members where user_id = :'departing_user')
  and exists (select 1 from public.organizer_members
              where organizer_id = :'organization' and user_id = :'remaining_admin' and role = 'admin')
  and (
    select to_jsonb(o) = e.snapshot from public.organizers o cross join expected_organization e
    where o.id = :'organization'
  ),
  'the organization and its remaining admin survive'
);
select pg_temp.assert_true(
  not exists (select 1 from public.organizers where id = :'personal_organizer')
  and not exists (select 1 from public.activities where id = :'personal_activity')
  and not exists (select 1 from public.activity_participants where activity_id = :'personal_activity')
  and not exists (select 1 from public.activity_invitations where activity_id = :'personal_activity'),
  'personal organizer, activity and dependent rows cascade'
);
select pg_temp.assert_true(
  (
    select a.created_by_user_id is null and to_jsonb(a) - array['created_by_user_id', 'updated_at'] = e.snapshot
    from public.activities a cross join expected_activity e where a.id = :'organization_activity'
  )
  and not exists (select 1 from public.activity_participants where user_id = :'departing_user')
  and (
    select to_jsonb(p) = e.snapshot from public.activity_participants p cross join expected_recipient e
    where p.activity_id = :'organization_activity' and p.user_id = :'recipient'
  ),
  'the organization activity survives with anonymous creator attribution and unchanged recipient participation'
);
select pg_temp.assert_true(
  not exists (
    select 1 from public.activity_invitations where :'departing_user' in (invited_user_id, invited_by_user_id)
  )
  and exists (
    select 1 from public.activity_invitations where activity_id = :'organization_activity'
      and invited_user_id = :'replacement' and invited_by_user_id = :'remaining_admin' and status = 'pending'
  ),
  'incoming and outgoing invitations cascade while unrelated invitations remain'
);

-- Isolate the activity FK from the organization membership FK.
savepoint check_organization_reference;
delete from public.organizer_members where organizer_id = :'organization';
select pg_temp.expect_error(format('delete from public.organizers where id = %L', :'organization'), '23503');
rollback to savepoint check_organization_reference;

set local role anon;
select set_config('request.jwt.claims', '{}', true);
select pg_temp.assert_true(
  (select available_places = 1 from public.get_activity(:'organization_activity')),
  'deleting the confirmed participant frees exactly one public place'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', :'recipient', 'role', 'authenticated')::text, true);
select pg_temp.assert_true(
  public.get_my_activity_participation(:'organization_activity') = 'confirmed',
  'the recipient of the deleted invitation stays confirmed'
);
select set_config('request.jwt.claims', jsonb_build_object('sub', :'replacement', 'role', 'authenticated')::text, true);
select pg_temp.assert_true(
  public.join_activity(:'organization_activity') = :'organization_activity',
  'a new participant can join the freed place'
);
select set_config('request.jwt.claims', jsonb_build_object('sub', :'remaining_admin', 'role', 'authenticated')::text, true);
select pg_temp.assert_true(
  public.update_activity(:'organization_activity', '{"title":"Still managed by organization"}') = :'organization_activity',
  'the sole remaining admin can still manage the activity'
);
reset role;
select pg_temp.assert_true(
  (select available_places = 0 and title = 'Still managed by organization'
   from public.get_activity(:'organization_activity')),
  'the freed place is consumed and the admin edit is visible'
);

rollback;
\echo Account deletion regression passed.
