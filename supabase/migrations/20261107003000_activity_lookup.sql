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
  longitude double precision
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
    activity.place_name, activity.address, activity.latitude, activity.longitude
  from public.activities as activity
  join public.organizers as organizer on organizer.id = activity.organizer_id
  join public.categories as category on category.id = activity.category_id
  join public.cities as city on city.id = activity.city_id
  where activity.id = p_activity_id
    and (
      (activity.status = 'active' and activity.visibility = 'public')
      or (
        activity.status = 'draft'
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

revoke execute on function public.get_activity(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_activity(uuid) to anon, authenticated;
