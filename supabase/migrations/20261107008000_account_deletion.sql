-- The Auth delete and its effects on application data commit together.
alter table public.organizer_members
  drop constraint organizer_members_user_id_fkey,
  add constraint organizer_members_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade;

alter table public.activity_participants
  drop constraint activity_participants_user_id_fkey,
  add constraint activity_participants_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade;

alter table public.activity_invitations
  drop constraint activity_invitations_invited_user_id_fkey,
  drop constraint activity_invitations_invited_by_user_id_fkey,
  add constraint activity_invitations_invited_user_id_fkey
    foreign key (invited_user_id) references auth.users (id) on delete cascade,
  add constraint activity_invitations_invited_by_user_id_fkey
    foreign key (invited_by_user_id) references auth.users (id) on delete cascade;

-- An organization owns its activities independently of the account that created them.
alter table public.activities
  alter column created_by_user_id drop not null,
  drop constraint activities_created_by_user_id_fkey,
  add constraint activities_created_by_user_id_fkey
    foreign key (created_by_user_id) references auth.users (id) on delete set null;

-- Remove personal activities before their organizer disappears. This also keeps the
-- organizer foreign key valid if Auth deletion clears creator attribution first.
create function public.delete_personal_organizer_activities()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  delete from public.activities where organizer_id = old.id;
  return old;
end;
$$;

revoke execute on function public.delete_personal_organizer_activities()
  from public, anon, authenticated, service_role;

create trigger organizers_delete_personal_activities
  before delete on public.organizers
  for each row when (old.type = 'person')
  execute function public.delete_personal_organizer_activities();

-- Only a personal organizer is linked to an Auth account.
alter table public.organizers
  drop constraint organizers_user_id_fkey,
  add constraint organizers_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete cascade;

create index organizer_members_user_id_idx on public.organizer_members (user_id);
create index activity_participants_user_id_idx on public.activity_participants (user_id);
create index activity_invitations_activity_id_idx on public.activity_invitations (activity_id);
create index activity_invitations_invited_by_user_id_idx on public.activity_invitations (invited_by_user_id);
create index activities_created_by_user_id_idx on public.activities (created_by_user_id);
create index activities_organizer_id_idx on public.activities (organizer_id);
