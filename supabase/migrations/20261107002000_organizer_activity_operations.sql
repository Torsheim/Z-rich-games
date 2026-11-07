create function public.create_activity_draft(
  p_organizer_id uuid,
  p_title text,
  p_description text,
  p_category_id uuid,
  p_starts_at timestamptz,
  p_timezone text,
  p_city_id uuid,
  p_place_name text,
  p_ends_at timestamptz default null,
  p_address text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_max_participants integer default null,
  p_cover_image_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  activity_id uuid;
begin
  -- Hold both authorization rows until the draft is written.
  perform 1
  from public.organizers as organizer
  join public.organizer_members as member on member.organizer_id = organizer.id
  where organizer.id = p_organizer_id
    and organizer.type = 'organization'
    and organizer.verified_at is not null
    and member.user_id = actor_id
    and member.role in ('owner', 'admin', 'editor')
  for share of organizer, member;

  if not found then
    raise exception using errcode = '42501', message = 'You cannot create activities for this organizer';
  end if;

  insert into public.activities (
    organizer_id, created_by_user_id, title, description, category_id,
    starts_at, ends_at, timezone, city_id, place_name, address, latitude, longitude,
    max_participants, cover_image_url, status, visibility, join_policy
  ) values (
    p_organizer_id, actor_id, p_title, p_description, p_category_id,
    p_starts_at, p_ends_at, p_timezone, p_city_id, p_place_name, p_address, p_latitude, p_longitude,
    p_max_participants, p_cover_image_url, 'draft', 'invite_only', 'invitation_required'
  ) returning id into activity_id;

  return activity_id;
end;
$$;

create function public.publish_activity(p_activity_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  activity_to_publish public.activities%rowtype;
begin
  -- Serialize publication with changes to the activity, approval and membership.
  select activity.* into activity_to_publish
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
    raise exception using errcode = '42501', message = 'You cannot publish this activity';
  end if;

  if activity_to_publish.status = 'active'
    and activity_to_publish.visibility = 'public'
    and activity_to_publish.join_policy = 'instant' then
    return activity_to_publish.id;
  end if;

  if activity_to_publish.status <> 'draft' then
    raise exception using errcode = '55000', message = 'Only a draft activity can be published';
  end if;

  if activity_to_publish.description !~ '[^[:space:]]' then
    raise exception using errcode = '22023', message = 'An activity description is required to publish';
  end if;

  update public.activities
  set status = 'active', visibility = 'public', join_policy = 'instant'
  where id = activity_to_publish.id;

  return activity_to_publish.id;
end;
$$;

revoke execute on function
  public.create_activity_draft(
    uuid, text, text, uuid, timestamptz, text, uuid, text,
    timestamptz, text, double precision, double precision, integer, text
  ),
  public.publish_activity(uuid)
from public, anon, authenticated, service_role;

grant execute on function
  public.create_activity_draft(
    uuid, text, text, uuid, timestamptz, text, uuid, text,
    timestamptz, text, double precision, double precision, integer, text
  ),
  public.publish_activity(uuid)
to authenticated;
