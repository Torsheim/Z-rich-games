create table public.activity_cities(id text primary key, name text not null, timezone text not null);
insert into public.activity_cities values ('zurich', 'Zurich', 'Europe/Zurich');
create table public.activity_categories(id text primary key, name text not null);
insert into public.activity_categories values ('social','Social'),('culture','Culture'),('outdoors','Outdoors'),('food','Food & drink'),('sport','Sport');
create table public.activities (
  id uuid primary key default gen_random_uuid(),
  created_by_user_id uuid not null references public.profiles(id) on delete cascade,
  organizer_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'activity' check(kind = 'activity'),
  title text not null check(length(trim(title)) between 3 and 100),
  description text not null check(length(description) <= 4000),
  category_id text not null references public.activity_categories(id),
  cover_image_url text check(cover_image_url is null or cover_image_url ~ '^https://'),
  visibility text not null check(visibility in ('public','invite_only')),
  join_policy text not null check(join_policy in ('instant','approval_required','invitation_required')),
  max_participants integer check(max_participants between 1 and 10000),
  starts_at timestamptz not null,
  ends_at timestamptz check(ends_at >= starts_at),
  timezone text not null,
  city_id text not null references public.activity_cities(id),
  place_name text not null check(length(trim(place_name)) between 2 and 160),
  address text check(length(address) <= 300),
  latitude double precision check(latitude between -90 and 90),
  longitude double precision check(longitude between -180 and 180),
  status text not null check(status in ('draft','active','cancelled','completed')),
  first_published_at timestamptz,
  visibility_changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((latitude is null) = (longitude is null)),
  check ((visibility='invite_only' and join_policy='invitation_required') or (visibility='public' and join_policy in ('instant','approval_required')))
);
create index activities_discovery_idx on public.activities(city_id,status,starts_at) where visibility='public';
create index activities_creator_idx on public.activities(created_by_user_id);
create table public.activity_participants (
  activity_id uuid not null references public.activities(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check(role in ('host','co_host','participant')),
  status text not null check(status in ('requested','confirmed','waitlisted','cancelled','rejected','removed')),
  requested_at timestamptz not null default now(),
  confirmed_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(activity_id,user_id)
);
create index activity_participant_user_idx on public.activity_participants(user_id,status);
create table public.activity_invitations (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.activities(id) on delete cascade,
  invited_user_id uuid not null references public.profiles(id) on delete cascade,
  invited_by_user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','accepted','declined','revoked','expired')),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(activity_id,invited_user_id)
);
create index activity_invitation_user_idx on public.activity_invitations(invited_user_id,status);
alter table public.activities enable row level security;
alter table public.activity_participants enable row level security;
alter table public.activity_invitations enable row level security;
alter table public.activity_cities enable row level security;
alter table public.activity_categories enable row level security;
revoke all on public.activities,public.activity_participants,public.activity_invitations,public.activity_cities,public.activity_categories from anon,authenticated;
grant select on public.activities,public.activity_participants,public.activity_invitations,public.activity_cities,public.activity_categories to authenticated;
create policy "Cities" on public.activity_cities for select to authenticated using (true);
create policy "Categories" on public.activity_categories for select to authenticated using (true);

create function public.can_view_activity(activity_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.activities a where a.id=activity_id and (
 a.created_by_user_id=auth.uid() or (a.status <> 'draft' and (
 a.visibility='public' or exists(select 1 from public.activity_participants p where p.activity_id=a.id and p.user_id=auth.uid() and p.status='confirmed')
 or exists(select 1 from public.activity_invitations i where i.activity_id=a.id and i.invited_user_id=auth.uid() and i.status in ('pending','accepted','declined') and (i.expires_at is null or i.expires_at > now()))))));
$$;
create policy "Visible activities" on public.activities for select to authenticated using(public.can_view_activity(id));
create policy "Own participation or host" on public.activity_participants for select to authenticated using(user_id=auth.uid() or exists(select 1 from public.activities a where a.id=activity_id and a.created_by_user_id=auth.uid()));
create policy "Own invitation or host" on public.activity_invitations for select to authenticated using(invited_user_id=auth.uid() or invited_by_user_id=auth.uid());

create function public.activity_feed() returns setof jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(a) || jsonb_build_object('host_username',u.username,
 'participant_count',(select count(*) from public.activity_participants p where p.activity_id=a.id and p.status='confirmed'),
 'my_status',(select p.status from public.activity_participants p where p.activity_id=a.id and p.user_id=auth.uid()),
 'invite_status',(select i.status from public.activity_invitations i where i.activity_id=a.id and i.invited_user_id=auth.uid()))
 from public.activities a join public.profiles u on u.id=a.created_by_user_id where public.can_view_activity(a.id) order by a.starts_at;
$$;

create function public.create_activity(details jsonb, friend_ids uuid[] default '{}') returns uuid
language plpgsql security definer set search_path='' as $$
declare new_id uuid; city_zone text; friend_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 if coalesce(details->>'kind','activity') <> 'activity' then raise exception 'Only organizers can create events.'; end if;
 if coalesce(details->>'status','active') not in ('draft','active') then raise exception 'Invalid initial status.'; end if;
 if (details->>'starts_at')::timestamptz <= now() then raise exception 'Choose a future start time.'; end if;
 select timezone into city_zone from public.activity_cities where id=details->>'city_id';
 if city_zone is null then raise exception 'Choose a supported city.'; end if;
 foreach friend_id in array coalesce(friend_ids,'{}') loop
   if not exists(select 1 from public.friendships f where f.user_low=least(auth.uid(),friend_id) and f.user_high=greatest(auth.uid(),friend_id)) then
     raise exception 'You can only invite people from your friends list.';
   end if;
 end loop;
 insert into public.activities(created_by_user_id,organizer_id,title,description,category_id,cover_image_url,visibility,join_policy,max_participants,starts_at,ends_at,timezone,city_id,place_name,address,latitude,longitude,status,first_published_at)
 values(auth.uid(),auth.uid(),trim(details->>'title'),coalesce(details->>'description',''),details->>'category_id',nullif(details->>'cover_image_url',''),details->>'visibility',details->>'join_policy',nullif(details->>'max_participants','')::integer,(details->>'starts_at')::timestamptz,nullif(details->>'ends_at','')::timestamptz,city_zone,details->>'city_id',trim(details->>'place_name'),nullif(details->>'address',''),nullif(details->>'latitude','')::double precision,nullif(details->>'longitude','')::double precision,coalesce(details->>'status','active'),case when details->>'visibility'='public' and coalesce(details->>'status','active')='active' then now() end)
 returning id into new_id;
 insert into public.activity_participants(activity_id,user_id,role,status,confirmed_at) values(new_id,auth.uid(),'host','confirmed',now());
 insert into public.activity_invitations(activity_id,invited_user_id,invited_by_user_id)
 select new_id,x,auth.uid() from (select distinct unnest(coalesce(friend_ids,'{}')) as x) f;
 return new_id;
end;
$$;

create function public.respond_to_activity(target_activity_id uuid, response text) returns text
language plpgsql security definer set search_path='' as $$
declare a public.activities; invitation public.activity_invitations; next_status text; current_status text; booked integer;
begin
 if auth.uid() is null then raise exception 'Sign in first.'; end if;
 select * into a from public.activities where id=target_activity_id for update;
 if not found or not public.can_view_activity(target_activity_id) then raise exception 'Activity unavailable.'; end if;
 if a.created_by_user_id=auth.uid() then raise exception 'You are the host.'; end if;
 if a.status <> 'active' or a.starts_at <= now() then raise exception 'This activity is no longer open.'; end if;
 if response is null or response not in ('attend','decline') then raise exception 'Invalid response.'; end if;
 select * into invitation from public.activity_invitations where activity_id=a.id and invited_user_id=auth.uid() and status in ('pending','accepted','declined') and (expires_at is null or expires_at>now());
 select status into current_status from public.activity_participants where activity_id=a.id and user_id=auth.uid();
 if current_status='removed' then raise exception 'You cannot rejoin this activity.'; end if;
 if response='decline' then
   next_status := 'cancelled';
 else
   if a.visibility='invite_only' and invitation.id is null then raise exception 'An invitation is required.'; end if;
   if current_status='confirmed' then return 'confirmed'; end if;
   next_status := case when a.join_policy='approval_required' and invitation.id is null then 'requested' else 'confirmed' end;
   select count(*) into booked from public.activity_participants where activity_id=a.id and status='confirmed';
   if next_status='confirmed' and a.max_participants is not null and booked>=a.max_participants then raise exception 'This activity is full.'; end if;
 end if;
 insert into public.activity_participants(activity_id,user_id,role,status,confirmed_at) values(a.id,auth.uid(),'participant',next_status,case when next_status='confirmed' then now() end)
 on conflict(activity_id,user_id) do update set status=excluded.status,confirmed_at=excluded.confirmed_at,updated_at=now();
 if invitation.id is not null then update public.activity_invitations set status=case when response='attend' then 'accepted' else 'declined' end,updated_at=now() where id=invitation.id; end if;
 return next_status;
end;
$$;

create function public.publish_activity(target_activity_id uuid, new_visibility text, new_join_policy text) returns void
language plpgsql security definer set search_path='' as $$
declare a public.activities;
begin
 select * into a from public.activities where id=target_activity_id for update;
 if auth.uid() is null or a.created_by_user_id is distinct from auth.uid() then raise exception 'Only the host can change visibility.'; end if;
 if a.status not in ('draft','active') or a.starts_at<=now() then raise exception 'This activity is no longer open.'; end if;
 update public.activities set visibility=new_visibility,join_policy=new_join_policy,status='active',updated_at=now(),visibility_changed_at=now(),first_published_at=case when new_visibility='public' then coalesce(first_published_at,now()) else first_published_at end where id=a.id;
 if new_visibility='invite_only' then update public.activity_participants set status='rejected',updated_at=now() where activity_id=a.id and status='requested'; end if;
end;
$$;

create function public.activity_host_roster(target_activity_id uuid) returns table(user_id uuid,username text,status text)
language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.activities a where a.id=target_activity_id and a.created_by_user_id=auth.uid()) then raise exception 'Only the host can see this list.'; end if;
 return query select p.user_id,u.username,p.status from public.activity_participants p join public.profiles u on u.id=p.user_id where p.activity_id=target_activity_id
 union all select i.invited_user_id,u.username,'invited' from public.activity_invitations i join public.profiles u on u.id=i.invited_user_id where i.activity_id=target_activity_id and i.status='pending' and not exists(select 1 from public.activity_participants p where p.activity_id=i.activity_id and p.user_id=i.invited_user_id);
end;
$$;
create function public.review_activity_request(target_activity_id uuid, participant_user_id uuid, approve boolean) returns void
language plpgsql security definer set search_path='' as $$
declare a public.activities; booked integer;
begin
 select * into a from public.activities where id=target_activity_id for update;
 if auth.uid() is null or a.created_by_user_id is distinct from auth.uid() then raise exception 'Only the host can review requests.'; end if;
 if a.status<>'active' or a.starts_at<=now() then raise exception 'This activity is no longer open.'; end if;
 if not exists(select 1 from public.activity_participants p where p.activity_id=a.id and p.user_id=participant_user_id and p.status='requested') then raise exception 'No pending request.'; end if;
 select count(*) into booked from public.activity_participants where activity_id=a.id and status='confirmed';
 if approve and a.max_participants is not null and booked>=a.max_participants then raise exception 'This activity is full.'; end if;
 update public.activity_participants set status=case when approve then 'confirmed' else 'rejected' end,confirmed_at=case when approve then now() end,updated_at=now() where activity_id=a.id and user_id=participant_user_id;
end;
$$;
revoke all on function public.can_view_activity(uuid),public.activity_feed(),public.create_activity(jsonb,uuid[]),public.respond_to_activity(uuid,text),public.publish_activity(uuid,text,text),public.activity_host_roster(uuid),public.review_activity_request(uuid,uuid,boolean) from public,anon;
grant execute on function public.can_view_activity(uuid),public.activity_feed(),public.create_activity(jsonb,uuid[]),public.respond_to_activity(uuid,text),public.publish_activity(uuid,text,text),public.activity_host_roster(uuid),public.review_activity_request(uuid,uuid,boolean) to authenticated;

alter publication supabase_realtime add table public.activities,public.activity_participants,public.activity_invitations;
