-- Run against a disposable database with all migrations applied.
\set ON_ERROR_STOP on
begin;

create function pg_temp.verify(ok boolean, label text) returns void
language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'Event regression: %', label; end if;
end;
$$;

create function pg_temp.expect_denied(query text) returns void
language plpgsql as $$
begin
  begin
    execute query;
  exception when insufficient_privilege then
    return;
  end;
  raise exception 'Expected access denial for %', query;
end;
$$;

do $$
begin
  execute format('grant usage on schema %I to anon, authenticated', (
    select nspname from pg_namespace where oid = pg_my_temp_schema()
  ));
end;
$$;

select gen_random_uuid() as owner_id, gen_random_uuid() as editor_id,
       gen_random_uuid() as attendee_id, gen_random_uuid() as outsider_id,
       gen_random_uuid() as organization_id, gen_random_uuid() as personal_id,
       gen_random_uuid() as personal_activity_id
\gset

insert into auth.users (id, raw_user_meta_data)
select id::uuid, jsonb_build_object('username', 'event_' || left(replace(id, '-', ''), 18))
from (values (:'owner_id'), (:'editor_id'), (:'attendee_id'), (:'outsider_id')) fixture(id);
select id as city_id from public.cities where slug = 'zurich' \gset
select id as category_id from public.categories where slug = 'sport' \gset
insert into public.organizers (id, type, user_id, name, verified_at) values
  (:'organization_id', 'organization', null, 'Test bowling club', now()),
  (:'personal_id', 'person', :'outsider_id', 'Test personal host', null);
insert into public.organizer_members (organizer_id, user_id, role) values
  (:'organization_id', :'owner_id', 'owner'), (:'organization_id', :'editor_id', 'editor');
insert into public.activities (id, organizer_id, created_by_user_id, title, description, category_id,
  city_id, starts_at, timezone, place_name, status, visibility, join_policy)
values (:'personal_activity_id', :'personal_id', :'outsider_id', 'Private-track public plan', 'A plan',
  :'category_id', :'city_id', now() + interval '1 day', 'Europe/Zurich', 'Zurich', 'active', 'public', 'instant');

set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);
select public.create_activity_draft(:'organization_id', 'Bowling event', 'Bring socks',
  :'category_id', now() + interval '2 days', 'Europe/Zurich', :'city_id', 'Lane 1', p_max_participants => 2) as event_id
\gset
select pg_temp.verify((select count(*) = 1 from public.list_my_event_organizations()), 'owner can list organizations');
select pg_temp.verify((select count(*) = 1 from public.list_managed_organization_events(:'organization_id')), 'owner can list draft');
select public.publish_activity(:'event_id');

set local role anon;
select set_config('request.jwt.claims', '{}', true);
select pg_temp.verify((select count(*) = 1 from public.get_organization_event(:'event_id')), 'guest can open the event');
select pg_temp.verify((select count(*) = 0 from public.get_organization_event(:'personal_activity_id')), 'event route excludes personal plans');
select pg_temp.verify(exists (select 1 from public.list_public_activities(p_organization_only => true) where id = :'event_id')
  and not exists (select 1 from public.list_public_activities(p_organization_only => true) where id = :'personal_activity_id')
  and exists (select 1 from public.list_public_activities() where id = :'personal_activity_id'), 'organization filter preserves shared listing');
select pg_temp.expect_denied(format('select * from public.list_organization_event_participants(%L)', :'event_id'));

set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', :'attendee_id', 'role', 'authenticated')::text, true);
select public.join_activity(:'event_id');
select pg_temp.expect_denied(format('select * from public.list_organization_event_participants(%L)', :'event_id'));
select set_config('request.jwt.claims', jsonb_build_object('sub', :'editor_id', 'role', 'authenticated')::text, true);
select pg_temp.expect_denied(format('select * from public.list_organization_event_participants(%L)', :'event_id'));
select set_config('request.jwt.claims', jsonb_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);
select pg_temp.verify((select array_agg(user_id) = array[:'attendee_id'::uuid]
  from public.list_organization_event_participants(:'event_id')), 'roster contains only confirmed participants');
select public.update_activity(:'event_id', '{"description":"Bring socks and shoes"}');
select public.update_activity(:'event_id', jsonb_build_object('place_name', 'Lane 2', 'starts_at', now() + interval '3 days'));
select public.update_activity(:'event_id', '{"place_name":"Lane 2"}');
select set_config('request.jwt.claims', jsonb_build_object('sub', :'attendee_id', 'role', 'authenticated')::text, true);
select pg_temp.verify((select count(*) = 1 from public.list_my_event_updates()), 'only meaningful change creates an update');
select row->>'id' as update_id from public.list_my_event_updates() row
where row->>'kind' = 'changed' and row->>'schedule_changed' = 'true' and row->>'venue_changed' = 'true'
  and row->>'place_name' = 'Lane 2' and row->>'read_at' is null
\gset

select set_config('request.jwt.claims', jsonb_build_object('sub', :'outsider_id', 'role', 'authenticated')::text, true);
select pg_temp.verify((select count(*) = 0 from public.list_my_event_updates()), 'unrelated user has no updates');
select public.mark_event_update_read(:'update_id');
select set_config('request.jwt.claims', jsonb_build_object('sub', :'attendee_id', 'role', 'authenticated')::text, true);
select pg_temp.verify((select row->>'read_at' is null from public.list_my_event_updates() row), 'another user cannot mark update read');
select public.mark_event_update_read(:'update_id');
select pg_temp.verify((select row->>'read_at' is not null from public.list_my_event_updates() row), 'attendee can mark update read');

select set_config('request.jwt.claims', jsonb_build_object('sub', :'owner_id', 'role', 'authenticated')::text, true);
select public.cancel_activity(:'event_id', 'Venue unavailable');
select public.cancel_activity(:'event_id', 'Duplicate attempt');
select set_config('request.jwt.claims', jsonb_build_object('sub', :'attendee_id', 'role', 'authenticated')::text, true);
select pg_temp.verify((select count(*) = 2 from public.list_my_event_updates())
  and exists (select 1 from public.list_my_event_updates() row
    where row->>'kind' = 'cancelled' and row->>'cancellation_reason' = 'Venue unavailable'), 'one cancellation update');

reset role;
delete from auth.users where id = :'attendee_id';
select pg_temp.verify(not exists (select 1 from public.event_update_recipients where user_id = :'attendee_id'),
  'account deletion removes recipient records');
rollback;
\echo Organization event regression passed.
