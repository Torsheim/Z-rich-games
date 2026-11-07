-- Free the shared table names while retaining all existing personal activity data.
create schema activity_legacy;
revoke all on schema activity_legacy from public, anon, authenticated, service_role;

alter publication supabase_realtime drop table
  public.activities, public.activity_participants, public.activity_invitations;

drop policy "Visible activities" on public.activities;
drop function
  public.activity_feed(),
  public.create_activity(jsonb, uuid[]),
  public.respond_to_activity(uuid, text),
  public.publish_activity(uuid, text, text),
  public.activity_host_roster(uuid),
  public.review_activity_request(uuid, uuid, boolean),
  public.can_view_activity(uuid);

alter table public.activities set schema activity_legacy;
alter table public.activity_participants set schema activity_legacy;
alter table public.activity_invitations set schema activity_legacy;
alter table public.activity_cities set schema activity_legacy;
alter table public.activity_categories set schema activity_legacy;

revoke all on all tables in schema activity_legacy from public, anon, authenticated, service_role;
