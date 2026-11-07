create type public.organizer_type as enum ('person', 'organization');
create type public.organizer_member_role as enum ('owner', 'admin', 'editor');
create type public.activity_visibility as enum ('public', 'invite_only');
create type public.activity_join_policy as enum ('instant', 'approval_required', 'invitation_required');
create type public.activity_status as enum ('draft', 'active', 'cancelled', 'completed');
create type public.activity_participant_role as enum ('host', 'co_host', 'participant');
create type public.activity_participant_status as enum (
  'requested', 'confirmed', 'waitlisted', 'cancelled', 'rejected', 'removed'
);
create type public.activity_invitation_status as enum ('pending', 'accepted', 'declined', 'revoked', 'expired');

create table public.cities (
  id uuid primary key default gen_random_uuid(),
  name text not null check (name ~ '[^[:space:]]')
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null check (name ~ '[^[:space:]]')
);

create table public.organizers (
  id uuid primary key default gen_random_uuid(),
  type public.organizer_type not null,
  user_id uuid unique references auth.users (id),
  name text not null check (name ~ '[^[:space:]]'),
  description text,
  avatar_url text,
  website_url text,
  verified_at timestamptz check (isfinite(verified_at)),
  created_at timestamptz not null default now() check (isfinite(created_at)),
  constraint organizers_person_user_check
    check ((type = 'person') = (user_id is not null)),
  unique (id, type)
);

create table public.organizer_members (
  organizer_id uuid not null,
  user_id uuid not null references auth.users (id),
  role public.organizer_member_role not null,
  created_at timestamptz not null default now() check (isfinite(created_at)),
  -- The generated discriminator lets the foreign key enforce organization membership.
  organizer_type public.organizer_type generated always as ('organization'::public.organizer_type) stored,
  primary key (organizer_id, user_id),
  foreign key (organizer_id, organizer_type) references public.organizers (id, type)
);

create table public.activities (
  id uuid primary key default gen_random_uuid(),
  created_by_user_id uuid not null references auth.users (id),
  organizer_id uuid not null references public.organizers (id),
  title text not null check (title ~ '[^[:space:]]'),
  description text not null,
  category_id uuid not null references public.categories (id),
  cover_image_url text,
  visibility public.activity_visibility not null default 'invite_only',
  join_policy public.activity_join_policy not null default 'invitation_required',
  max_participants integer,
  starts_at timestamptz not null,
  ends_at timestamptz,
  timezone text not null,
  city_id uuid not null references public.cities (id),
  place_name text not null check (place_name ~ '[^[:space:]]'),
  address text,
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  status public.activity_status not null default 'draft',
  first_published_at timestamptz check (isfinite(first_published_at)),
  visibility_changed_at timestamptz not null default now() check (isfinite(visibility_changed_at)),
  created_at timestamptz not null default now() check (isfinite(created_at)),
  updated_at timestamptz not null default now() check (isfinite(updated_at)),
  constraint activities_visibility_join_policy_check
    check (
      (visibility = 'invite_only' and join_policy = 'invitation_required')
      or (visibility = 'public' and join_policy in ('instant', 'approval_required'))
    ),
  constraint activities_capacity_check check (max_participants > 0),
  constraint activities_time_range_check
    check (isfinite(starts_at) and (ends_at is null or (isfinite(ends_at) and ends_at >= starts_at)))
);

create table public.activity_participants (
  activity_id uuid not null references public.activities (id) on delete cascade,
  user_id uuid not null references auth.users (id),
  role public.activity_participant_role not null default 'participant',
  status public.activity_participant_status not null default 'requested',
  requested_at timestamptz not null default now() check (isfinite(requested_at)),
  confirmed_at timestamptz check (isfinite(confirmed_at)),
  updated_at timestamptz not null default now() check (isfinite(updated_at)),
  primary key (activity_id, user_id),
  constraint activity_participants_confirmation_check
    check (status <> 'confirmed' or confirmed_at is not null)
);

create table public.activity_invitations (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.activities (id) on delete cascade,
  invited_user_id uuid not null references auth.users (id),
  invited_by_user_id uuid not null references auth.users (id),
  status public.activity_invitation_status not null default 'pending',
  expires_at timestamptz check (isfinite(expires_at)),
  created_at timestamptz not null default now() check (isfinite(created_at)),
  updated_at timestamptz not null default now() check (isfinite(updated_at))
);

create index activities_public_city_status_start_idx
  on public.activities (city_id, status, starts_at)
  where visibility = 'public';

create index activity_participants_activity_status_idx
  on public.activity_participants (activity_id, status);

create index activity_invitations_recipient_status_idx
  on public.activity_invitations (invited_user_id, status);

create unique index activity_invitations_one_pending_idx
  on public.activity_invitations (activity_id, invited_user_id)
  where status = 'pending';

create function public.set_activity_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  changed_at timestamptz := pg_catalog.statement_timestamp();
  check_timezone boolean := true;
begin
  if tg_op = 'INSERT' then
    new.visibility_changed_at := changed_at;
    new.first_published_at := null;
  else
    if new.visibility is distinct from old.visibility then
      new.visibility_changed_at := changed_at;
    else
      new.visibility_changed_at := old.visibility_changed_at;
    end if;
    new.first_published_at := old.first_published_at;
    check_timezone := new.timezone is distinct from old.timezone;
  end if;

  if check_timezone and new.timezone is not null and not exists (
    select 1 from pg_catalog.pg_timezone_names where name = new.timezone
  ) then
    raise exception using errcode = '22023', message = 'Unknown activity timezone';
  end if;

  if new.visibility = 'public' and new.status = 'active' and new.first_published_at is null then
    new.first_published_at := changed_at;
  end if;

  new.updated_at := changed_at;
  return new;
end;
$$;

create function public.set_activity_child_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.statement_timestamp();
  return new;
end;
$$;

revoke execute on function public.set_activity_timestamps(), public.set_activity_child_updated_at()
  from public, anon, authenticated;

create trigger activities_set_timestamps
  before insert or update on public.activities
  for each row execute function public.set_activity_timestamps();

create trigger activity_participants_set_updated_at
  before update on public.activity_participants
  for each row execute function public.set_activity_child_updated_at();

create trigger activity_invitations_set_updated_at
  before update on public.activity_invitations
  for each row execute function public.set_activity_child_updated_at();

-- Access stays closed until workflows can apply organizer and participant authorization.
alter table public.cities enable row level security;
alter table public.categories enable row level security;
alter table public.organizers enable row level security;
alter table public.organizer_members enable row level security;
alter table public.activities enable row level security;
alter table public.activity_participants enable row level security;
alter table public.activity_invitations enable row level security;

revoke all on table
  public.cities,
  public.categories,
  public.organizers,
  public.organizer_members,
  public.activities,
  public.activity_participants,
  public.activity_invitations
from public, anon, authenticated;
