create function public.join_activity(p_activity_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  activity_to_join public.activities%rowtype;
  existing_status public.activity_participant_status;
  registered_at timestamptz;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'Sign in to join an activity';
  end if;

  -- Capacity edits and cancellation take this same lock before changing the activity.
  select activity.* into activity_to_join
  from public.activities as activity
  where activity.id = p_activity_id
    and activity.visibility = 'public'
    and (
      activity.status = 'active'
      or (activity.status = 'cancelled' and activity.first_published_at is not null)
    )
  for no key update;

  if not found then
    raise exception using errcode = '42501', message = 'You cannot join this activity';
  end if;

  if activity_to_join.status <> 'active'
    or activity_to_join.join_policy <> 'instant'
    or activity_to_join.starts_at <= pg_catalog.clock_timestamp() then
    raise sqlstate 'PT409' using message = 'Activity is closed for direct signup', detail = 'activity_closed';
  end if;

  select participant.status into existing_status
  from public.activity_participants as participant
  where participant.activity_id = p_activity_id and participant.user_id = actor_id;

  if existing_status = 'confirmed' then
    return p_activity_id;
  end if;

  if existing_status in ('rejected', 'removed') then
    raise exception using errcode = '42501', message = 'You cannot join this activity';
  end if;

  if activity_to_join.max_participants is not null and (
    select count(*)
    from public.activity_participants as participant
    where participant.activity_id = p_activity_id and participant.status = 'confirmed'
  ) >= activity_to_join.max_participants then
    raise sqlstate 'PT409' using message = 'Activity is full', detail = 'activity_full';
  end if;

  registered_at := pg_catalog.clock_timestamp();

  insert into public.activity_participants as participant (
    activity_id, user_id, status, requested_at, confirmed_at, updated_at
  ) values (
    p_activity_id, actor_id, 'confirmed', registered_at, registered_at, registered_at
  )
  on conflict (activity_id, user_id) do update
  set status = 'confirmed',
      requested_at = case
        when participant.status = 'cancelled' then excluded.requested_at
        else participant.requested_at
      end,
      confirmed_at = excluded.confirmed_at;

  -- Advance the locked row version so repeatable-read transactions cannot count stale capacity.
  update public.activities
  set updated_at = pg_catalog.statement_timestamp()
  where id = p_activity_id;

  return p_activity_id;
end;
$$;

revoke execute on function public.join_activity(uuid) from public, anon, authenticated, service_role;
grant execute on function public.join_activity(uuid) to authenticated;
