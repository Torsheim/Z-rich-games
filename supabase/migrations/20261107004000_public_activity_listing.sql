create index activities_public_active_start_id_idx
  on public.activities (starts_at, id)
  where status = 'active' and visibility = 'public';

create function public.list_public_activities(
  p_city_id uuid default null,
  p_category_id uuid default null,
  p_limit integer default 20,
  p_after_starts_at timestamptz default null,
  p_after_activity_id uuid default null
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
language plpgsql
stable
security definer
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
  select
    activity.id, activity.title, activity.organizer_id, organizer.name,
    activity.city_id, city.name, activity.category_id, category.name,
    activity.starts_at, activity.ends_at, activity.timezone, activity.place_name,
    activity.cover_image_url, activity.join_policy
  from public.activities as activity
  join public.organizers as organizer on organizer.id = activity.organizer_id
  join public.cities as city on city.id = activity.city_id
  join public.categories as category on category.id = activity.category_id
  where activity.status = 'active'
    and activity.visibility = 'public'
    -- Bound the index scan by the cursor time, then break ties by activity ID.
    and activity.starts_at >= greatest(pg_catalog.now(), p_after_starts_at)
    and (p_city_id is null or activity.city_id = p_city_id)
    and (p_category_id is null or activity.category_id = p_category_id)
    and (p_after_starts_at is null or (activity.starts_at, activity.id) > (p_after_starts_at, p_after_activity_id))
  order by activity.starts_at, activity.id
  limit p_limit;
end;
$$;

revoke execute on function public.list_public_activities(uuid, uuid, integer, timestamptz, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.list_public_activities(uuid, uuid, integer, timestamptz, uuid)
  to anon, authenticated;
