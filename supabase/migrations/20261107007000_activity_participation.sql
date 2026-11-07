create function public.leave_activity(p_activity_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  activity_to_leave public.activities%rowtype;
  existing_status public.activity_participant_status;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'Sign in to leave an activity';
  end if;

  -- Lock the same row as join_activity before reading or changing participation.
  select activity.* into activity_to_leave
  from public.activities as activity
  where activity.id = p_activity_id
    and exists (
      select 1
      from public.activity_participants as participant
      where participant.activity_id = activity.id and participant.user_id = actor_id
    )
  for no key update;

  if not found then
    raise exception using errcode = '42501', message = 'You cannot leave this activity';
  end if;

  select participant.status into existing_status
  from public.activity_participants as participant
  where participant.activity_id = p_activity_id and participant.user_id = actor_id;

  if existing_status = 'cancelled' then
    return p_activity_id;
  end if;

  if not found or existing_status not in ('confirmed', 'requested', 'waitlisted') then
    raise exception using errcode = '42501', message = 'You cannot leave this activity';
  end if;

  if activity_to_leave.status <> 'active' or activity_to_leave.starts_at <= pg_catalog.clock_timestamp() then
    raise sqlstate 'PT409' using message = 'Activity is closed for withdrawal', detail = 'activity_closed';
  end if;

  update public.activity_participants
  set status = 'cancelled'
  where activity_id = p_activity_id and user_id = actor_id;

  -- Keep the activity row version in step with participation changes, as in join_activity.
  update public.activities
  set updated_at = pg_catalog.statement_timestamp()
  where id = p_activity_id;

  return p_activity_id;
end;
$$;

create function public.get_my_activity_participation(p_activity_id uuid)
returns public.activity_participant_status
language sql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
  select participant.status
  from public.activity_participants as participant
  where participant.activity_id = p_activity_id and participant.user_id = auth.uid();
$$;

-- Extend the existing detail response with a public aggregate.
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
  cancellation_reason text,
  available_places integer
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
    activity.cancelled_at, activity.cancellation_reason,
    case when activity.status = 'active'
      and activity.visibility = 'public'
      and activity.starts_at > pg_catalog.now()
      and activity.max_participants is not null then
        greatest(activity.max_participants - (
          select count(*)
          from public.activity_participants as participant
          where participant.activity_id = activity.id and participant.status = 'confirmed'
        ), 0)::integer
    end
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

revoke execute on function public.leave_activity(uuid), public.get_my_activity_participation(uuid), public.get_activity(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.leave_activity(uuid), public.get_my_activity_participation(uuid)
  to authenticated;
grant execute on function public.get_activity(uuid) to anon, authenticated;
