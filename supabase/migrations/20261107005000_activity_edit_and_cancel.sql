alter table public.activities
  add column cancelled_at timestamptz,
  add column cancellation_reason text,
  add constraint activities_cancellation_metadata_check check (
    (cancelled_at is null or (status = 'cancelled' and isfinite(cancelled_at)))
    and (
      cancellation_reason is null or (
        cancelled_at is not null
        and char_length(cancellation_reason) <= 500
        and cancellation_reason ~ '[^[:space:]]'
      )
    )
  );

create function public.update_activity(p_activity_id uuid, p_changes jsonb)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  original_activity public.activities%rowtype;
  edited_activity public.activities%rowtype;
begin
  select activity.* into original_activity
  from public.activities as activity
  join public.organizers as organizer on organizer.id = activity.organizer_id
  join public.organizer_members as member on member.organizer_id = organizer.id
  where activity.id = p_activity_id
    and organizer.type = 'organization'
    and organizer.verified_at is not null
    and member.user_id = auth.uid()
    and (member.role in ('owner', 'admin') or (member.role = 'editor' and activity.status = 'draft'))
  for no key update of activity
  for share of organizer, member;

  if not found then
    raise exception using errcode = '42501', message = 'You cannot edit this activity';
  end if;

  if original_activity.status not in ('draft', 'active') then
    raise exception using errcode = '55000', message = 'Only draft or active activities can be edited';
  end if;

  if pg_catalog.jsonb_typeof(p_changes) is distinct from 'object' then
    raise exception using errcode = '22023', message = 'Activity changes must be a JSON object';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_each(p_changes) as change(field, value)
    where not (
      (change.field in ('title', 'description', 'category_id', 'starts_at', 'timezone', 'city_id', 'place_name')
        and pg_catalog.jsonb_typeof(change.value) = 'string')
      or (change.field in ('cover_image_url', 'ends_at', 'address')
        and pg_catalog.jsonb_typeof(change.value) in ('string', 'null'))
      or (change.field in ('max_participants', 'latitude', 'longitude')
        and pg_catalog.jsonb_typeof(change.value) in ('number', 'null'))
    )
  ) then
    raise exception using errcode = '22023', message = 'Invalid activity field or value';
  end if;

  -- Apply only the supplied fields to the locked row, including explicit nulls.
  edited_activity := pg_catalog.jsonb_populate_record(original_activity, p_changes);

  if edited_activity is not distinct from original_activity then
    return original_activity.id;
  end if;

  if original_activity.status = 'active' and p_changes ? 'description'
    and edited_activity.description !~ '[^[:space:]]' then
    raise exception using errcode = '22023', message = 'An active activity requires a description';
  end if;

  if edited_activity.max_participants is distinct from original_activity.max_participants
    and edited_activity.max_participants < (
      select count(*)
      from public.activity_participants as participant
      where participant.activity_id = original_activity.id and participant.status = 'confirmed'
    ) then
    raise exception using errcode = '22023', message = 'Capacity cannot be lower than the confirmed participant count';
  end if;

  update public.activities
  set title = edited_activity.title,
      description = edited_activity.description,
      category_id = edited_activity.category_id,
      cover_image_url = edited_activity.cover_image_url,
      max_participants = edited_activity.max_participants,
      starts_at = edited_activity.starts_at,
      ends_at = edited_activity.ends_at,
      timezone = edited_activity.timezone,
      city_id = edited_activity.city_id,
      place_name = edited_activity.place_name,
      address = edited_activity.address,
      latitude = edited_activity.latitude,
      longitude = edited_activity.longitude
  where id = original_activity.id;

  return original_activity.id;
end;
$$;

create function public.cancel_activity(p_activity_id uuid, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  activity_status public.activity_status;
  cancellation_note text;
begin
  select activity.status into activity_status
  from public.activities as activity
  join public.organizers as organizer on organizer.id = activity.organizer_id
  join public.organizer_members as member on member.organizer_id = organizer.id
  where activity.id = p_activity_id
    and organizer.type = 'organization'
    and organizer.verified_at is not null
    and member.user_id = auth.uid()
    and member.role in ('owner', 'admin')
  for no key update of activity
  for share of organizer, member;

  if not found then
    raise exception using errcode = '42501', message = 'You cannot cancel this activity';
  end if;

  if activity_status = 'cancelled' then
    return p_activity_id;
  end if;

  if activity_status <> 'active' then
    raise exception using errcode = '55000', message = 'Only active activities can be cancelled';
  end if;

  cancellation_note := nullif(pg_catalog.regexp_replace(p_reason, '^[[:space:]]+|[[:space:]]+$', '', 'g'), '');
  if pg_catalog.char_length(cancellation_note) > 500 then
    raise exception using errcode = '22023', message = 'Cancellation reason must be 500 characters or fewer';
  end if;

  update public.activities
  set status = 'cancelled',
      cancelled_at = pg_catalog.clock_timestamp(),
      cancellation_reason = cancellation_note
  where id = p_activity_id;

  return p_activity_id;
end;
$$;

-- Append cancellation details to the existing lookup result.
drop function public.get_activity(uuid);

create function public.get_activity(p_activity_id uuid)
returns table (
  id uuid,
  organizer_id uuid,
  organizer_name text,
  category_id uuid,
  category_name text,
  city_id uuid,
  city_name text,
  title text,
  description text,
  cover_image_url text,
  status public.activity_status,
  visibility public.activity_visibility,
  join_policy public.activity_join_policy,
  max_participants integer,
  starts_at timestamptz,
  ends_at timestamptz,
  timezone text,
  place_name text,
  address text,
  latitude double precision,
  longitude double precision,
  cancelled_at timestamptz,
  cancellation_reason text
)
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
  select
    activity.id, activity.organizer_id, organizer.name,
    activity.category_id, category.name, activity.city_id, city.name,
    activity.title, activity.description, activity.cover_image_url,
    activity.status, activity.visibility, activity.join_policy, activity.max_participants,
    activity.starts_at, activity.ends_at, activity.timezone,
    activity.place_name, activity.address, activity.latitude, activity.longitude,
    activity.cancelled_at, activity.cancellation_reason
  from public.activities as activity
  join public.organizers as organizer on organizer.id = activity.organizer_id
  join public.categories as category on category.id = activity.category_id
  join public.cities as city on city.id = activity.city_id
  where activity.id = p_activity_id
    and (
      (activity.visibility = 'public' and (
        activity.status = 'active'
        or (activity.status = 'cancelled' and activity.first_published_at is not null)
      ))
      or (
        activity.status in ('draft', 'cancelled')
        and (
          (organizer.type = 'person' and organizer.user_id = auth.uid())
          or (
            organizer.type = 'organization'
            and organizer.verified_at is not null
            and exists (
              select 1
              from public.organizer_members as member
              where member.organizer_id = organizer.id
                and member.user_id = auth.uid()
                and member.role in ('owner', 'admin', 'editor')
            )
          )
        )
      )
    );
$$;

revoke execute on function public.update_activity(uuid, jsonb), public.cancel_activity(uuid, text), public.get_activity(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.update_activity(uuid, jsonb), public.cancel_activity(uuid, text)
  to authenticated;
grant execute on function public.get_activity(uuid) to anon, authenticated;
