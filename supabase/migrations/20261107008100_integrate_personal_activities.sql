alter table public.cities add column slug text unique, add column timezone text;
alter table public.categories add column slug text unique;

insert into public.cities (slug, name, timezone)
select id, name, timezone from activity_legacy.activity_cities;

insert into public.categories (slug, name)
select id, name from activity_legacy.activity_categories;

insert into public.organizers (type, user_id, name)
select 'person', profile.id, profile.username
from public.profiles profile
where exists (
  select 1 from activity_legacy.activities activity where activity.organizer_id = profile.id
)
on conflict (user_id) do nothing;

-- Keep the original lifecycle timestamps on the copied rows.
alter table public.activities disable trigger activities_set_timestamps;

insert into public.activities (
  id, created_by_user_id, organizer_id, title, description, category_id, cover_image_url,
  visibility, join_policy, max_participants, starts_at, ends_at, timezone, city_id,
  place_name, address, latitude, longitude, status, first_published_at,
  visibility_changed_at, created_at, updated_at
)
select
  activity.id, activity.created_by_user_id, organizer.id, activity.title,
  activity.description, category.id, activity.cover_image_url,
  activity.visibility::public.activity_visibility, activity.join_policy::public.activity_join_policy,
  activity.max_participants, activity.starts_at, activity.ends_at, activity.timezone, city.id,
  activity.place_name, activity.address, activity.latitude, activity.longitude,
  activity.status::public.activity_status, activity.first_published_at,
  activity.visibility_changed_at, activity.created_at, activity.updated_at
from activity_legacy.activities activity
join public.organizers organizer on organizer.user_id = activity.organizer_id
join public.cities city on city.slug = activity.city_id
join public.categories category on category.slug = activity.category_id;

alter table public.activities enable trigger activities_set_timestamps;

insert into public.activity_participants (
  activity_id, user_id, role, status, requested_at, confirmed_at, updated_at
)
select activity_id, user_id, role::public.activity_participant_role,
  status::public.activity_participant_status, requested_at,
  case when status = 'confirmed' then coalesce(confirmed_at, requested_at) else confirmed_at end,
  updated_at
from activity_legacy.activity_participants;

insert into public.activity_invitations (
  id, activity_id, invited_user_id, invited_by_user_id, status, expires_at, created_at, updated_at
)
select id, activity_id, invited_user_id, invited_by_user_id,
  status::public.activity_invitation_status, expires_at, created_at, updated_at
from activity_legacy.activity_invitations;

drop table activity_legacy.activity_invitations, activity_legacy.activity_participants,
  activity_legacy.activities, activity_legacy.activity_cities, activity_legacy.activity_categories;
drop schema activity_legacy;

-- Preserve the personal-activity API used by existing Flutter clients.
create function public.can_view_activity(activity_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.activities activity
    join public.organizers organizer on organizer.id = activity.organizer_id
    where activity.id = $1
      and organizer.type = 'person'
      and (
        organizer.user_id = auth.uid()
        or (
          activity.status <> 'draft'
          and (
            activity.visibility = 'public'
            or exists (
              select 1 from public.activity_participants participant
              where participant.activity_id = activity.id
                and participant.user_id = auth.uid()
                and participant.status = 'confirmed'
            )
            or exists (
              select 1
              from (
                select invitation.status, invitation.expires_at
                from public.activity_invitations invitation
                where invitation.activity_id = activity.id and invitation.invited_user_id = auth.uid()
                order by invitation.created_at desc, invitation.id desc
                limit 1
              ) latest
              where latest.status in ('pending', 'accepted', 'declined')
                and (latest.expires_at is null or latest.expires_at > now())
            )
          )
        )
      )
  );
$$;

create function public.activity_feed()
returns setof jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'id', activity.id,
    'kind', 'activity',
    'created_by_user_id', coalesce(activity.created_by_user_id, organizer.user_id),
    'organizer_id', organizer.user_id,
    'title', activity.title,
    'description', activity.description,
    'category_id', coalesce(category.slug, category.id::text),
    'cover_image_url', activity.cover_image_url,
    'visibility', activity.visibility,
    'join_policy', activity.join_policy,
    'max_participants', activity.max_participants,
    'starts_at', activity.starts_at,
    'ends_at', activity.ends_at,
    'timezone', activity.timezone,
    'city_id', coalesce(city.slug, city.id::text),
    'place_name', activity.place_name,
    'address', activity.address,
    'latitude', activity.latitude,
    'longitude', activity.longitude,
    'status', activity.status,
    'first_published_at', activity.first_published_at,
    'visibility_changed_at', activity.visibility_changed_at,
    'created_at', activity.created_at,
    'updated_at', activity.updated_at,
    'host_username', coalesce(profile.username, organizer.name),
    'participant_count', (
      select count(*) from public.activity_participants participant
      where participant.activity_id = activity.id and participant.status = 'confirmed'
    ),
    'my_status', (
      select participant.status from public.activity_participants participant
      where participant.activity_id = activity.id and participant.user_id = auth.uid()
    ),
    'invite_status', (
      select invitation.status from public.activity_invitations invitation
      where invitation.activity_id = activity.id and invitation.invited_user_id = auth.uid()
      order by invitation.created_at desc, invitation.id desc
      limit 1
    )
  )
  from public.activities activity
  join public.organizers organizer on organizer.id = activity.organizer_id
  join public.cities city on city.id = activity.city_id
  join public.categories category on category.id = activity.category_id
  left join public.profiles profile on profile.id = organizer.user_id
  where organizer.type = 'person' and public.can_view_activity(activity.id)
  order by activity.starts_at, activity.id;
$$;

create function public.create_activity(details jsonb, friend_ids uuid[] default '{}')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  personal_organizer_id uuid;
  new_activity_id uuid;
  selected_city public.cities;
  selected_category_id uuid;
  initial_status text := coalesce(details->>'status', 'active');
  activity_title text := trim(details->>'title');
  activity_description text := coalesce(details->>'description', '');
  activity_place text := trim(details->>'place_name');
  activity_address text := nullif(details->>'address', '');
  activity_cover text := nullif(details->>'cover_image_url', '');
  activity_start timestamptz := (details->>'starts_at')::timestamptz;
  capacity integer := nullif(details->>'max_participants', '')::integer;
  activity_latitude double precision := nullif(details->>'latitude', '')::double precision;
  activity_longitude double precision := nullif(details->>'longitude', '')::double precision;
begin
  if actor is null then raise exception 'Sign in first.'; end if;
  if coalesce(details->>'kind', 'activity') <> 'activity' then
    raise exception 'Only organizations can create events.';
  end if;
  if initial_status not in ('draft', 'active') then raise exception 'Invalid initial status.'; end if;
  if activity_start is null or not isfinite(activity_start) or activity_start <= clock_timestamp() then
    raise exception 'Choose a future start time.';
  end if;
  if activity_title is null or length(activity_title) not between 3 and 100
    or activity_place is null or length(activity_place) not between 2 and 160
    or length(activity_description) > 4000
    or length(activity_address) > 300
    or capacity not between 1 and 10000
    or activity_cover !~ '^https://'
    or (activity_latitude is null) <> (activity_longitude is null)
  then
    raise exception 'Invalid activity details.';
  end if;

  select city.* into selected_city from public.cities city where city.slug = details->>'city_id';
  if selected_city.timezone is null then raise exception 'Choose a supported city.'; end if;

  select category.id into selected_category_id
  from public.categories category where category.slug = details->>'category_id';
  if selected_category_id is null then raise exception 'Choose a supported category.'; end if;

  if exists (
    select 1 from unnest(friend_ids) as friend(id)
    where friend.id is null or not exists (
      select 1 from public.friendships friendship
      where friendship.user_low = least(actor, friend.id)
        and friendship.user_high = greatest(actor, friend.id)
    )
  ) then
    raise exception 'You can only invite people from your friends list.';
  end if;

  select id into personal_organizer_id from public.organizers where user_id = actor;
  if personal_organizer_id is null then
    insert into public.organizers (type, user_id, name)
    select 'person', profile.id, profile.username from public.profiles profile where profile.id = actor
    on conflict (user_id) do nothing;
    select id into personal_organizer_id from public.organizers where user_id = actor;
    if personal_organizer_id is null then raise exception 'Create a profile first.'; end if;
  end if;

  insert into public.activities (
    created_by_user_id, organizer_id, title, description, category_id, cover_image_url,
    visibility, join_policy, max_participants, starts_at, ends_at, timezone, city_id,
    place_name, address, latitude, longitude, status
  ) values (
    actor, personal_organizer_id, activity_title, activity_description, selected_category_id, activity_cover,
    (details->>'visibility')::public.activity_visibility, (details->>'join_policy')::public.activity_join_policy,
    capacity, activity_start, nullif(details->>'ends_at', '')::timestamptz,
    selected_city.timezone, selected_city.id, activity_place, activity_address,
    activity_latitude, activity_longitude, initial_status::public.activity_status
  ) returning id into new_activity_id;

  insert into public.activity_participants (activity_id, user_id, role, status, confirmed_at)
  values (new_activity_id, actor, 'host', 'confirmed', clock_timestamp());

  insert into public.activity_invitations (activity_id, invited_user_id, invited_by_user_id)
  select distinct new_activity_id, friend.id, actor from unnest(friend_ids) as friend(id);

  return new_activity_id;
end;
$$;

create function public.respond_to_activity(target_activity_id uuid, response text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  activity public.activities;
  invitation public.activity_invitations;
  current_status public.activity_participant_status;
  next_status public.activity_participant_status;
begin
  if actor is null then raise exception 'Sign in first.'; end if;

  select activity_row.* into activity
  from public.activities activity_row
  join public.organizers organizer on organizer.id = activity_row.organizer_id
  where activity_row.id = target_activity_id and organizer.type = 'person'
  for no key update of activity_row;
  if not found or not public.can_view_activity(target_activity_id) then
    raise exception 'Activity unavailable.';
  end if;
  if exists (select 1 from public.organizers where id = activity.organizer_id and user_id = actor) then
    raise exception 'You are the host.';
  end if;
  if activity.status <> 'active' or activity.starts_at <= clock_timestamp() then
    raise exception 'This activity is no longer open.';
  end if;
  if response is null or response not in ('attend', 'decline') then raise exception 'Invalid response.'; end if;

  select invitation_row.* into invitation
  from public.activity_invitations invitation_row
  where invitation_row.activity_id = activity.id and invitation_row.invited_user_id = actor
  order by invitation_row.created_at desc, invitation_row.id desc
  limit 1
  for no key update;
  if invitation.status not in ('pending', 'accepted', 'declined')
    or invitation.expires_at <= clock_timestamp()
  then
    invitation.id := null;
  end if;

  select status into current_status
  from public.activity_participants where activity_id = activity.id and user_id = actor;
  if current_status = 'removed' then raise exception 'You cannot rejoin this activity.'; end if;

  if response = 'decline' then
    next_status := 'cancelled';
  elsif current_status = 'confirmed' then
    return 'confirmed';
  elsif activity.visibility = 'invite_only' and invitation.id is null then
    raise exception 'An invitation is required.';
  elsif activity.join_policy = 'approval_required' and invitation.id is null then
    next_status := 'requested';
  else
    next_status := 'confirmed';
    if activity.max_participants is not null and (
      select count(*) from public.activity_participants
      where activity_id = activity.id and status = 'confirmed'
    ) >= activity.max_participants then
      raise exception 'This activity is full.';
    end if;
  end if;

  insert into public.activity_participants as participant (activity_id, user_id, role, status, confirmed_at)
  values (activity.id, actor, 'participant', next_status, case when next_status = 'confirmed' then clock_timestamp() end)
  on conflict (activity_id, user_id) do update set
    status = excluded.status,
    requested_at = case when participant.status = 'cancelled' and excluded.status <> 'cancelled'
      then excluded.requested_at else participant.requested_at end,
    confirmed_at = coalesce(excluded.confirmed_at, participant.confirmed_at);

  if invitation.id is not null then
    update public.activity_invitations set status = (
      case when response = 'attend' then 'accepted' else 'declined' end
    )::public.activity_invitation_status where id = invitation.id;
  end if;

  -- Version the locked row for capacity checks and notify authorized Realtime subscribers.
  update public.activities set updated_at = statement_timestamp() where id = activity.id;
  return next_status::text;
end;
$$;

create function public.publish_activity(target_activity_id uuid, new_visibility text, new_join_policy text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  activity public.activities;
begin
  select activity_row.* into activity
  from public.activities activity_row
  join public.organizers organizer on organizer.id = activity_row.organizer_id
  where activity_row.id = target_activity_id and organizer.type = 'person' and organizer.user_id = auth.uid()
  for no key update of activity_row;
  if not found then raise exception 'Only the host can change visibility.'; end if;
  if activity.status not in ('draft', 'active') or activity.starts_at <= clock_timestamp() then
    raise exception 'This activity is no longer open.';
  end if;

  update public.activities
  set visibility = new_visibility::public.activity_visibility,
    join_policy = new_join_policy::public.activity_join_policy, status = 'active'
  where id = activity.id;
  if new_visibility = 'invite_only' then
    update public.activity_participants set status = 'rejected'
    where activity_id = activity.id and status = 'requested';
  end if;
end;
$$;

create function public.activity_host_roster(target_activity_id uuid)
returns table(user_id uuid, username text, status text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.activities activity
    join public.organizers organizer on organizer.id = activity.organizer_id
    where activity.id = target_activity_id and organizer.type = 'person' and organizer.user_id = auth.uid()
  ) then
    raise exception 'Only the host can see this list.';
  end if;

  return query
    select participant.user_id, profile.username, participant.status::text
    from public.activity_participants participant
    join public.profiles profile on profile.id = participant.user_id
    where participant.activity_id = target_activity_id
    union all
    select invitation.invited_user_id, profile.username, 'invited'
    from public.activity_invitations invitation
    join public.profiles profile on profile.id = invitation.invited_user_id
    where invitation.activity_id = target_activity_id and invitation.status = 'pending'
      and not exists (
        select 1 from public.activity_participants participant
        where participant.activity_id = invitation.activity_id and participant.user_id = invitation.invited_user_id
      );
end;
$$;

create function public.review_activity_request(target_activity_id uuid, participant_user_id uuid, approve boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  activity public.activities;
begin
  select activity_row.* into activity
  from public.activities activity_row
  join public.organizers organizer on organizer.id = activity_row.organizer_id
  where activity_row.id = target_activity_id and organizer.type = 'person' and organizer.user_id = auth.uid()
  for no key update of activity_row;
  if not found then raise exception 'Only the host can review requests.'; end if;
  if activity.status <> 'active' or activity.starts_at <= clock_timestamp() then
    raise exception 'This activity is no longer open.';
  end if;
  if approve is null then raise exception 'Invalid response.'; end if;

  if not exists (
    select 1 from public.activity_participants
    where activity_id = activity.id and user_id = participant_user_id and status = 'requested'
  ) then raise exception 'No pending request.'; end if;

  if approve and activity.max_participants is not null and (
    select count(*) from public.activity_participants
    where activity_id = activity.id and status = 'confirmed'
  ) >= activity.max_participants then
    raise exception 'This activity is full.';
  end if;

  update public.activity_participants set
    status = (case when approve then 'confirmed' else 'rejected' end)::public.activity_participant_status,
    confirmed_at = case when approve then clock_timestamp() end
  where activity_id = activity.id and user_id = participant_user_id and status = 'requested';
  if not found then raise exception 'No pending request.'; end if;

  update public.activities set updated_at = statement_timestamp() where id = activity.id;
end;
$$;

revoke execute on function public.can_view_activity(uuid), public.activity_feed(),
  public.create_activity(jsonb, uuid[]), public.respond_to_activity(uuid, text),
  public.publish_activity(uuid, text, text), public.activity_host_roster(uuid),
  public.review_activity_request(uuid, uuid, boolean)
from public, anon, authenticated, service_role;

grant execute on function public.can_view_activity(uuid), public.activity_feed(),
  public.create_activity(jsonb, uuid[]), public.respond_to_activity(uuid, text),
  public.publish_activity(uuid, text, text), public.activity_host_roster(uuid),
  public.review_activity_request(uuid, uuid, boolean)
to authenticated;

-- Clients refresh their feed when an authorized parent row changes. Do not publish roster
-- or invitation rows because Realtime DELETE events cannot enforce their row visibility.
grant select on public.activities to authenticated;
create policy "Read visible personal activities" on public.activities for select to authenticated
  using (public.can_view_activity(id));
alter publication supabase_realtime add table public.activities;
