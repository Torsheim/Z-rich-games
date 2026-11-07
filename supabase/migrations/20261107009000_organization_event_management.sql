create function public.list_activity_options()
returns jsonb
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select jsonb_build_object(
    'cities', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'slug', slug, 'timezone', timezone) order by name)
      from public.cities where timezone is not null
    ), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'slug', slug) order by name)
      from public.categories
    ), '[]'::jsonb)
  );
$$;

create function public.list_my_event_organizations()
returns table (id uuid, name text, role public.organizer_member_role)
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select organizer.id, organizer.name, member.role
  from public.organizers organizer
  join public.organizer_members member on member.organizer_id = organizer.id
  where organizer.type = 'organization' and organizer.verified_at is not null
    and member.user_id = auth.uid()
  order by organizer.name, organizer.id;
$$;

create function public.list_managed_organization_events(p_organizer_id uuid)
returns setof jsonb
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if not exists (select 1 from public.list_my_event_organizations() where id = p_organizer_id) then
    raise exception using errcode = '42501', message = 'You cannot manage this organizer';
  end if;

  return query
  select (to_jsonb(activity) - array['created_by_user_id', 'created_at', 'updated_at', 'visibility_changed_at'])
    || jsonb_build_object('organizer_name', organizer.name, 'city_name', city.name, 'category_name', category.name)
  from public.activities activity
  join public.organizers organizer on organizer.id = activity.organizer_id
  join public.cities city on city.id = activity.city_id
  join public.categories category on category.id = activity.category_id
  where activity.organizer_id = p_organizer_id
  order by activity.starts_at desc, activity.id desc;
end;
$$;

create function public.list_organization_event_participants(p_activity_id uuid)
returns table (user_id uuid, username text, confirmed_at timestamptz)
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if not exists (
    select 1 from public.activities activity
    join public.list_my_event_organizations() organizer on organizer.id = activity.organizer_id
    where activity.id = p_activity_id and organizer.role in ('owner', 'admin')
  ) then
    raise exception using errcode = '42501', message = 'You cannot view this participant list';
  end if;

  return query
  select participant.user_id, coalesce(profile.username, 'Participant'), participant.confirmed_at
  from public.activity_participants participant
  left join public.profiles profile on profile.id = participant.user_id
  where participant.activity_id = p_activity_id and participant.status = 'confirmed'
  order by lower(profile.username), participant.user_id;
end;
$$;

create table public.event_updates (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.activities (id) on delete cascade,
  kind text not null check (kind in ('changed', 'cancelled')),
  title text not null,
  starts_at timestamptz not null,
  timezone text not null,
  place_name text not null,
  address text,
  cancellation_reason text,
  schedule_changed boolean not null,
  venue_changed boolean not null,
  created_at timestamptz not null default clock_timestamp()
);

create table public.event_update_recipients (
  user_id uuid not null references public.profiles (id) on delete cascade,
  update_id uuid not null references public.event_updates (id) on delete cascade,
  read_at timestamptz,
  primary key (user_id, update_id)
);

create index event_updates_activity_id_idx on public.event_updates (activity_id);
create index event_update_recipients_update_id_idx on public.event_update_recipients (update_id);

alter table public.event_updates enable row level security;
alter table public.event_update_recipients enable row level security;
revoke all on public.event_updates, public.event_update_recipients from public, anon, authenticated;

create function public.record_event_update()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  schedule_changed boolean := (new.starts_at, new.ends_at, new.timezone)
    is distinct from (old.starts_at, old.ends_at, old.timezone);
  venue_changed boolean := (new.place_name, new.address, new.latitude, new.longitude, new.city_id)
    is distinct from (old.place_name, old.address, old.latitude, old.longitude, old.city_id);
begin
  if old.status <> 'active' or old.visibility <> 'public'
    or (new.status <> 'cancelled' and (new.status <> 'active' or not (schedule_changed or venue_changed)))
    or not exists (select 1 from public.organizers where id = new.organizer_id and type = 'organization') then
    return new;
  end if;

  with recipients as materialized (
    select participant.user_id
    from public.activity_participants participant
    join public.profiles profile on profile.id = participant.user_id
    where participant.activity_id = new.id and participant.status = 'confirmed'
    for key share of profile
  ), update_record as (
    insert into public.event_updates (
      activity_id, kind, title, starts_at, timezone, place_name, address,
      cancellation_reason, schedule_changed, venue_changed
    )
    select new.id, case when new.status = 'cancelled' then 'cancelled' else 'changed' end,
      new.title, new.starts_at, new.timezone, new.place_name, new.address,
      new.cancellation_reason, schedule_changed, venue_changed
    where exists (select 1 from recipients)
    returning id
  )
  insert into public.event_update_recipients (user_id, update_id)
  select recipients.user_id, update_record.id from recipients cross join update_record;

  return new;
end;
$$;

create trigger activities_record_event_update
  after update of starts_at, ends_at, timezone, place_name, address, latitude, longitude, city_id, status
  on public.activities for each row execute function public.record_event_update();

create function public.list_my_event_updates()
returns setof jsonb
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select to_jsonb(event_update) || jsonb_build_object('read_at', recipient.read_at)
  from public.event_update_recipients recipient
  join public.event_updates event_update on event_update.id = recipient.update_id
  where recipient.user_id = auth.uid()
  order by event_update.created_at desc, event_update.id desc
  limit 50;
$$;

create function public.mark_event_update_read(p_update_id uuid)
returns void
language sql security definer
set search_path = pg_catalog, pg_temp
as $$
  update public.event_update_recipients
  set read_at = clock_timestamp()
  where update_id = p_update_id and user_id = auth.uid() and read_at is null;
$$;

revoke execute on function public.list_activity_options(), public.list_my_event_organizations(),
  public.list_managed_organization_events(uuid), public.list_organization_event_participants(uuid),
  public.record_event_update(), public.list_my_event_updates(), public.mark_event_update_read(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.list_activity_options() to anon, authenticated;
grant execute on function public.list_my_event_organizations(), public.list_managed_organization_events(uuid),
  public.list_organization_event_participants(uuid), public.list_my_event_updates(), public.mark_event_update_read(uuid)
  to authenticated;

create function public.get_organization_event(p_activity_id uuid)
returns setof jsonb
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select to_jsonb(detail)
  from public.get_activity(p_activity_id) detail
  join public.organizers organizer on organizer.id = detail.organizer_id
  where organizer.type = 'organization';
$$;

-- Apply the organization filter before the shared public listing's page limit.
drop function public.list_public_activities(uuid, uuid, integer, timestamptz, uuid);

create function public.list_public_activities(
  p_city_id uuid default null,
  p_category_id uuid default null,
  p_limit integer default 20,
  p_after_starts_at timestamptz default null,
  p_after_activity_id uuid default null,
  p_organization_only boolean default false
)
returns table (
  id uuid,
  title text,
  organizer_id uuid,
  organizer_name text,
  city_id uuid,
  city_name text,
  category_id uuid,
  category_name text,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  place_name text,
  cover_image_url text,
  join_policy public.activity_join_policy
)
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception using errcode = '22023', message = 'Page size must be between 1 and 100';
  end if;

  if (p_after_starts_at is null) <> (p_after_activity_id is null)
    or (p_after_starts_at is not null and not pg_catalog.isfinite(p_after_starts_at)) then
    raise exception using errcode = '22023', message = 'Pass a finite start time and activity ID together for the cursor';
  end if;

  return query
  select activity.id, activity.title, activity.organizer_id, organizer.name,
    activity.city_id, city.name, activity.category_id, category.name,
    activity.starts_at, activity.ends_at, activity.timezone, activity.place_name,
    activity.cover_image_url, activity.join_policy
  from public.activities activity
  join public.organizers organizer on organizer.id = activity.organizer_id
  join public.cities city on city.id = activity.city_id
  join public.categories category on category.id = activity.category_id
  where activity.status = 'active' and activity.visibility = 'public'
    and (p_organization_only is not true or organizer.type = 'organization')
    and activity.starts_at >= greatest(pg_catalog.now(), p_after_starts_at)
    and (p_city_id is null or activity.city_id = p_city_id)
    and (p_category_id is null or activity.category_id = p_category_id)
    and (p_after_starts_at is null or (activity.starts_at, activity.id) > (p_after_starts_at, p_after_activity_id))
  order by activity.starts_at, activity.id
  limit p_limit;
end;
$$;

revoke execute on function public.get_organization_event(uuid),
  public.list_public_activities(uuid, uuid, integer, timestamptz, uuid, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.get_organization_event(uuid),
  public.list_public_activities(uuid, uuid, integer, timestamptz, uuid, boolean)
  to anon, authenticated;
