# City Together

Flutter app for discovering activities and meeting people in a city. The first feature is English-language user authentication. Mutual friendships via QR codes and invitation links are also implemented. Organizer accounts and activities are not implemented yet.

## Implemented

- Welcome screen with sign in and registration.
- Username, email, password and password confirmation with validation.
- Email verification with a code, including resend.
- Sign in, persisted sessions, profile and sign out.
- Forgotten password with email code and new password.
- Permanent account deletion after confirmation and server-side password verification.
- Private profiles with row-level security, unique case-insensitive usernames and automatic profile creation/deletion.

This requires a configured Supabase project. Without configuration, the app shows setup instructions; there is no simulated authentication.

## First local test (no cloud account needed)

Start Docker Desktop, then run:

```sh
./scripts/start-local.sh
```

Open the app at http://localhost:3000 and the local test mailbox at http://127.0.0.1:54324. Register with a test address such as `alex@example.com`. All outgoing development emails appear in the test mailbox, not in a real inbox. Copy the verification code into the app. You can also test sign out, sign in, password reset and account deletion.

The script starts the local Supabase database, applies migrations on first initialization, writes the ignored `config.local.json`, serves the deletion function and starts Flutter. The first run downloads Docker images. Stop Flutter with Ctrl+C; the database remains running so test accounts persist. Use `supabase stop` to stop the backend without deleting its data.

The configuration targets a browser on this computer. A physical phone needs a reachable backend address instead of loopback.

## Friends: QR codes and invitation links

On your profile, open **My QR code & link** to show your personal invitation. Another signed-in user can scan it with **Scan a QR code** or open the copied link. A dialog shows the inviter's username; **Add friend** creates one mutual friendship. Canceling or merely viewing the invitation creates nothing. **Remove** beside a friend opens a confirmation dialog; confirming ends the friendship for both people. Existing invitation links can still be used to reconnect; removal is not a block. No username search or direct add-by-user-ID endpoint is provided.

Invitations are reusable for seven days. **Replace invitation** immediately revokes the previous code/link; existing friendships remain. Both users see each other under **Friends**, with realtime updates and a refresh fallback. Self-invitations, invalid/expired tokens and repeated acceptance are handled. Account deletion cascades to friendships and invitations. Only the two participants can read their friendship, and the friend-list RPC exposes usernames rather than email addresses.

To test on this computer, create two users in separate browser profiles (or normal/incognito windows). Copy the first user's invitation link and open it in the second window. If signed out, sign in or register first: the invitation is stored locally and confirmation opens after login. The web link and the scanner feed the same confirmation flow. `python3 scripts/check_local_friends.py` exercises real local mutual friendships, RLS, token rotation and account deletion using disposable users.

For an existing cloud backend, apply **all** files in `supabase/migrations/` in order (or use `supabase db push`). Local upgrades use `supabase migration up`; no database reset is needed.

Browser links use the app's current address by default. Set optional `APP_PUBLIC_URL` in your Dart configuration to the deployed HTTPS app URL when sharing across devices. A localhost link only reaches this computer. Browser camera scanning requires HTTPS or localhost and camera permission. The scanner handles denied/unavailable cameras, and invitation links can also be pasted via **Open invitation link**.

Native builds support `citytogether://friend?friend=TOKEN` for installed apps (including cold and warm launch). Without `APP_PUBLIC_URL`, native invitations use this scheme. If using an HTTPS `APP_PUBLIC_URL`, links open the hosted web app; verified iOS Universal Links/Android App Links require a deployed domain and its association files before HTTPS links can directly launch the installed app. iOS camera usage text and Android camera permissions are included. Real camera scanning and native-device launch still require device testing.

## Connect Supabase

1. Create a Supabase project. Under **Authentication → Providers → Email**, enable email/password signups and **Confirm email**. Set the minimum password length to **12**.
2. Run `supabase/migrations/202611070001_profiles.sql` in the project's SQL Editor, or link the project with the Supabase CLI and run `supabase db push`. This migration targets a new database and is applied once.
3. Under **Authentication → Email Templates**, configure both **Confirm signup** and **Reset password** to show `{{ .Token }}` as the code in the email body. Example:

   ```html
   <h2>Your City Together code</h2>
   <p>Enter this code in the app:</p>
   <p><strong>{{ .Token }}</strong></p>
   <p>If you did not request this email, you can ignore it.</p>
   ```

   Keep the confirmation code numeric (6–10 digits). The app uses `verifyOTP` with `signup` or `recovery`, so no mobile callback/deep link is required. Do not use the default link-only templates for this flow.
4. Configure your SMTP provider for real email delivery. Supabase's default mail service has recipient restrictions and rate limits; check the project's current settings. Set the desired code expiry in Auth settings.
5. Install/login to the Supabase CLI, link the project and deploy the deletion function:

   ```sh
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase functions deploy delete-account
   ```

   The checked-in `supabase/config.toml` disables gateway JWT checking for this function because the function validates the bearer token with `auth.getUser` itself. The hosted function receives `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` from Supabase. Never put the service-role key in the Flutter app.
6. Copy `config.example.json` to `config.local.json` and enter the project URL and publishable/anon key from Supabase project settings. This file is Git-ignored.
7. Start the app:

   ```sh
   flutter pub get
   flutter run -d chrome --web-port 3000 --dart-define-from-file=config.local.json
   ```

   For iOS/Android, select a simulator or connected device with `flutter devices` and use its ID instead of `chrome`. Android release builds include internet permission.

Only the public publishable/anon key is used in the client; database authorization is enforced with RLS. Passwords are managed by Supabase Auth. Email addresses remain in Auth rather than a publicly readable profile table. Username uniqueness is enforced in Postgres; a conflicting registration can return a generic signup error rather than revealing account details.

## Verification

With the local stack and deletion function running, `python3 scripts/check_local_auth.py` checks real registration, confirmation email codes, profile access protection, login/refresh, password reset and permanent deletion.


```sh
flutter analyze
flutter test
flutter build web --dart-define-from-file=config.local.json
```

Live acceptance checks after backend configuration:

1. Register a fresh email/username. Confirm that sign in before email verification is rejected.
2. Enter a wrong/expired code, resend, then verify the new code. Profile should show the username and verified email.
3. Restart the app and verify session restoration; sign out and sign in again.
4. Request a password reset, enter the email code, and set a new password. Confirm the old password no longer works.
5. Try a duplicate username, including different capitalization.
6. With two users, confirm each user can only select their own profile and cannot insert/update/delete profile rows directly.
7. Cancel account deletion; then try an incorrect password. Neither should delete the account.
8. Delete with the correct password. Confirm both Auth user and profile are removed, the app returns to welcome, and the old credentials cannot sign in.
9. Call the deletion function without a token and with an invalid token; both must be rejected.

Account deletion currently removes the Auth user and cascading profile. Future activity, media and billing models will need explicit retention/deletion rules before those features ship. A deleted user's existing access token may remain cryptographically valid until expiry; RLS still finds no profile, and the deletion endpoint verifies the user exists with Auth.

## Project layout

- `lib/main.dart`: startup, configuration and theme.
- `lib/auth/auth_service.dart`: Supabase integration and validation.
- `lib/auth/auth_screen.dart`: authentication and profile UI.
- `supabase/migrations/`: database schema, profile trigger and RLS.
- `supabase/functions/delete-account/`: authenticated account deletion.
- `activity-datenmodell.md`: planned activity model.

## References

- [Supabase Flutter signup](https://supabase.com/docs/reference/dart/auth-signup)
- [Password authentication](https://supabase.com/docs/guides/auth/passwords)
- [Admin account deletion](https://supabase.com/docs/reference/dart/auth-admin-deleteuser)
