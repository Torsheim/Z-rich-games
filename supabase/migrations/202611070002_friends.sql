-- A single canonical row represents a mutual friendship.
create table public.friendships (
  user_low uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_low, user_high),
  check (user_low < user_high)
);
create index friendships_high_idx on public.friendships(user_high);
alter table public.friendships enable row level security;
revoke all on public.friendships from anon, authenticated;
grant select on public.friendships to authenticated;
create policy "Read own friendships" on public.friendships for select to authenticated
using ((select auth.uid()) in (user_low, user_high));

-- Possessing this unguessable token is the only way to add its owner.
-- Do not expose invitation records or add a user-search endpoint.
create table public.friend_invites (
  owner_id uuid primary key references public.profiles(id) on delete cascade,
  token text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  expires_at timestamptz not null default now() + interval '7 days'
);
alter table public.friend_invites enable row level security;
revoke all on public.friend_invites from anon, authenticated;

create function public.my_friend_invite(rotate boolean default false)
returns table(token text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  insert into public.friend_invites as i (owner_id) values (auth.uid())
  on conflict (owner_id) do update set
    token = case when rotate or i.expires_at <= now()
      then replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') else i.token end,
    expires_at = case when rotate or i.expires_at <= now()
      then now() + interval '7 days' else i.expires_at end;
  return query select i.token, i.expires_at from public.friend_invites i where i.owner_id = auth.uid();
end;
$$;

create function public.preview_friend_invite(invite_token text)
returns table(user_id uuid, username text, is_self boolean, already_friends boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  return query select p.id, p.username, p.id = auth.uid(), exists (
    select 1 from public.friendships f
    where f.user_low = least(p.id, auth.uid()) and f.user_high = greatest(p.id, auth.uid())
  ) from public.friend_invites i join public.profiles p on p.id = i.owner_id
  where i.token = invite_token and i.expires_at > now();
end;
$$;

create function public.accept_friend_invite(invite_token text) returns void
language plpgsql security definer set search_path = '' as $$
declare target uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  -- Serialize acceptance with token rotation, so revoked tokens cannot slip through.
  select i.owner_id into target from public.friend_invites i
    where i.token = invite_token and i.expires_at > now() for update;
  if target is null then raise exception 'This invitation has expired or is no longer valid.'; end if;
  if target = auth.uid() then raise exception 'You cannot add yourself.'; end if;
  insert into public.friendships(user_low, user_high)
    values (least(target, auth.uid()), greatest(target, auth.uid()))
    on conflict do nothing;
end;
$$;

create function public.my_friends()
returns table(user_id uuid, username text, friends_since timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, p.username, f.created_at from public.friendships f
  join public.profiles p on p.id = case when f.user_low = auth.uid() then f.user_high else f.user_low end
  where auth.uid() in (f.user_low, f.user_high) order by lower(p.username);
$$;

revoke all on function public.my_friend_invite(boolean) from public, anon;
revoke all on function public.preview_friend_invite(text) from public, anon;
revoke all on function public.accept_friend_invite(text) from public, anon;
revoke all on function public.my_friends() from public, anon;
grant execute on function public.my_friend_invite(boolean), public.preview_friend_invite(text),
  public.accept_friend_invite(text), public.my_friends() to authenticated;

alter publication supabase_realtime add table public.friendships;
