# Social Coordination

Both tracks use the same `activities` table. The organizer track publishes activities for organizations. The private planning track can collect preferences in its own module and use the shared activity once there is a concrete plan.

## Shared database contract

The [foundation migration](supabase/migrations/20261107001000_activity_foundation.sql) defines the shared schema. User IDs refer to Supabase Auth's `auth.users.id`.

| Table | Responsibility |
| --- | --- |
| `organizers` | The person or organization responsible for an activity. A personal organizer is linked to exactly one user. |
| `organizer_members` | The users authorized to act for an organization, with `owner`, `admin` or `editor` as their membership role. |
| `activities` | The shared record for what is happening, when, where and how people can join. `created_by_user_id` records who created it. `organizer_id` records who is responsible for it. |
| `activity_participants` | One row per activity and user. Update that row when the user's participation changes. |
| `activity_invitations` | Invitations addressed to individual users. At most one pending invitation per activity and recipient. |
| `cities` and `categories` | Shared reference IDs for cities and categories. |

Lifecycle status is independent of visibility. Both public and invitation-only activities can be `active`.

| Visibility | Join policy | First use |
| --- | --- | --- |
| `public` | `instant` | An organization publishes an activity with direct signup. |
| `public` | `approval_required` | A host reviews participation requests. |
| `invite_only` | `invitation_required` | An invited group plans an activity. |

Keep the same `activity_id` when the visibility changes. Update visibility and join policy together. The database records the first time the activity is active and public and keeps that timestamp when the activity becomes private again.

## Integration rules for the next backend changes

- Use the signed-in user's ID for authorization. The creator field is provenance. Management rights come from the personal organizer's user or the organization's membership, subject to the operation's role checks. Publishing for an organization requires its `verified_at` to be set.
- Treat a draft as organizer-only. Public discovery selects active public activities. Invitation-only detail access comes from organizer authority, an eligible invitation or confirmed participation. Expose a confirmed count separately from the participant list.
- In the transaction that confirms a participant or changes capacity, lock the activity first. Count only `confirmed` rows. Use that same lock order for invitation acceptance and visibility changes. Accept an invitation and confirm participation together, and expire stale pending invitations before issuing a replacement.
- When changing an activity to invitation-only, keep confirmed participants and existing invitations. Reject pending public participation requests in that same operation.

The foundation enables row-level security and removes direct table access for the application roles. Add narrow grants and policies alongside the operations that need them.

## Organizer publishing

- `create_activity_draft` creates an `invite_only` draft with `invitation_required` and returns its UUID. A verified organization's owner, admin or editor can call it. Pass a description even if it is an empty string.
- `publish_activity` takes the draft UUID and returns the same UUID. An owner or admin of the activity's verified organization can publish once the description is nonblank. The call sets `status = active`, `visibility = public` and `join_policy = instant` atomically. Repeating the call in that state returns the UUID without updating the activity.

The Flutter example uses a Supabase client with a signed-in owner or admin session. Supply `organizerId`, `categoryId` and `cityId` from existing fixtures, with `verified_at` set on the organization.

```dart
final activityId = await supabase.rpc('create_activity_draft', params: {
  'p_organizer_id': organizerId,
  'p_title': 'Bowling night',
  'p_description': 'Meet at the front desk.',
  'p_category_id': categoryId,
  'p_starts_at': DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String(),
  'p_timezone': 'Europe/Zurich',
  'p_city_id': cityId,
  'p_place_name': 'Bowling center',
});

final publishedId = await supabase.rpc('publish_activity', params: {
  'p_activity_id': activityId,
});
```

The draft call also accepts `p_ends_at`, `p_address`, `p_latitude`, `p_longitude`, `p_max_participants` and `p_cover_image_url`.

## Edit and cancel an organizer activity

For a verified organization, an owner, admin or editor can edit a draft. An owner or admin can also edit or cancel an active activity. Both calls return the existing activity ID.

`update_activity` takes `p_changes`, an object with the fields to save. Send only changed fields and pass `null` to clear optional values. Date and time values use ISO 8601 strings with an offset. The editable fields are `title`, `description`, `category_id`, `cover_image_url`, `max_participants`, `starts_at`, `ends_at`, `timezone`, `city_id`, `place_name`, `address`, `latitude` and `longitude`. A new capacity must cover all confirmed participants.

```dart
await supabase.rpc('update_activity', params: {
  'p_activity_id': activityId,
  'p_changes': {'place_name': 'Bowling center, entrance B'},
});
```

`cancel_activity` accepts an optional `p_reason` of up to 500 characters. The activity disappears from the public listing. Its existing public link returns `status = cancelled`, `cancelled_at` and `cancellation_reason`, which the detail screen can display. A repeat call preserves the original cancellation details. Participants and invitations stay linked to the activity.

```dart
await supabase.rpc('cancel_activity', params: {
  'p_activity_id': activityId,
  'p_reason': 'The venue is closed.',
});
```

## Activity lookup

`get_activity` accepts an activity UUID. Visitors without a session can fetch active public activities and previously published activities that are still public after cancellation. Drafts and other cancelled activities are visible to the linked personal organizer or to an owner, admin or editor of their verified organization. The response includes event details and the names of the organizer, category and city. Hidden and unknown activities both return zero rows.

```dart
final activity = await supabase.rpc('get_activity', params: {
  'p_activity_id': activityId,
}).maybeSingle();
```

## Public activity listing

`list_public_activities` returns summaries of active public activities whose start time is at or after the request time. Visitors can call it without a user session. Results are sorted by `starts_at` and then `id`. Use the returned `id` with `get_activity` to open the activity details.

```dart
final activities = await supabase.rpc('list_public_activities', params: {
  'p_city_id': cityId,
});
```

Pass `p_city_id` and `p_category_id` to filter by city and category. Both filters are optional. `p_limit` defaults to 20 and accepts values from 1 to 100. For the next page, keep the same filters and pass the last row's `starts_at` string as `p_after_starts_at` and its `id` as `p_after_activity_id`. Supply both cursor values together.

## Test the activity API locally

Apply the migrations to a disposable local Supabase database. Use two confirmed test accounts. Give one the `owner` role in a verified organization and leave the other outside it. Create a city and category for the test activity.

- Set `SUPABASE_URL` to the local API URL and set `SUPABASE_PUBLISHABLE_KEY` or `SUPABASE_ANON_KEY` to the local key.
- Set `FIXTURE_ORGANIZER_ID`, `FIXTURE_CITY_ID` and `FIXTURE_CATEGORY_ID` to the local fixture UUIDs.
- Set `OWNER_EMAIL`, `OWNER_PASSWORD`, `OUTSIDER_EMAIL` and `OUTSIDER_PASSWORD` for the two test accounts. You can also supply sessions via `OWNER_ACCESS_TOKEN` and `OUTSIDER_ACCESS_TOKEN`.

```sh
python3 scripts/check_activity_access.py
```

Each run creates, edits, publishes and cancels one activity in the local database.

## Work on both tracks

Start both feature branches from the same foundation commit. Add new, uniquely timestamped migrations for schema changes and review shared table or enum changes together. Keep planning-specific data in its own tables and link it to the shared `activity_id` when needed.

For a local development database, install the Supabase CLI, start a Docker-compatible runtime and run the following from the repository root.

```sh
supabase start
supabase migration up --local
```

Use the local project for fixtures and access tests. [Supabase local migration workflow](https://supabase.com/docs/guides/local-development/database-migrations)
