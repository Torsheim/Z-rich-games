# CityQuest

A mobile-first web app for meeting people and exploring Zürich together. Create a profile or continue as a guest, find activities and play a team scavenger hunt through any CityQuest event.

## Local development

You need Node.js 22 or later and access to a PostgreSQL 15+ database. Supabase works without configuring Supabase Auth or enabling its Data API for CityQuest.

1. Install dependencies with `npm ci`.
2. Copy `.env.example` to `.env.local`. Set `DATABASE_URL` to your development database connection string. When connecting to Supabase, also set `DATABASE_CA_CERT` to the PEM text of its root certificate.
3. Apply the files in [`supabase/migrations/`](supabase/migrations/) in filename order. For an existing database, apply only the migrations it still needs. In Supabase, use the SQL Editor. For a fresh database with `psql`, run the following.

   ```sh
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
     -f supabase/migrations/20261107000000_cityquest.sql \
     -f supabase/migrations/20261107000100_profiles.sql
   ```

   Set `DATABASE_URL` in your shell before running the command. Next.js reads `.env.local` for the application.

4. Run `npm run dev` and open the printed local URL.

Run `npm run lint`, `npm run typecheck` and `npm run build` to check changes.

## Deployment

1. Apply pending migrations to a dedicated production database before deploying.
2. Import the GitHub repository into Vercel as a Next.js project.
3. Set the server-side `DATABASE_URL` environment variable for Production. For Supabase on Vercel, use the [transaction pooler connection string](https://supabase.com/docs/guides/database/connecting-to-postgres#connection-pooler) with SSL. The native Supabase integration can supply `POSTGRES_URL` automatically. Set `DATABASE_CA_CERT` to the PEM text of the [Supabase root certificate](https://supabase.com/docs/guides/platform/ssl-enforcement) so the server can verify its TLS connection. Use a separate database for previews.
4. Deploy and verify the flow below on the public URL.

## Try the full flow

1. Open CityQuest in two independent browser sessions. Create a profile in one and continue as a guest in the other.
2. Create a bowling activity in the first session. Open it from Explore in the second session, join it, and check the two participant names and count.
3. Create a CityQuest activity. Enter its lobby as the host and share the six-character code with the second session. The second player can also join from Explore.
4. Create a team and have the second player join it. Start the game as host, complete one challenge, and check both sessions show the same score. Refresh either session to check that identity and progress persist.

The feed starts empty. The migration seeds 12 challenges. Players self-report completion, and the server derives the team score from unique completions. The host can start, finish or cancel a game. Teams support up to four players.

## Profiles and sign-in

Open **Profile** to create an account with a unique username and a password of at least 15 characters. Edit your display name and optional public bio there. Other people can open your profile from activity participant lists.

Guests can create an account from the same browser to keep their existing activities and game progress. Log in with the same username and password on another device to access that profile. Logging out ends the current account session. Password recovery is outside the current profile flow.

## Source layout

- `app/` contains the Next.js shell and the CityQuest API route.
- `components/` contains the activity and game interfaces.
- `lib/db.ts` contains PostgreSQL queries and transactions for activity capacity, team membership and scoring.
- `supabase/migrations/` contains the database schema and challenge catalogue.

Display names can repeat. The server hashes passwords with scrypt and stores only the digest of each session token. The browser holds the session token in an HTTP-only cookie.
