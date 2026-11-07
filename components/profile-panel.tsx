import { ArrowLeft, ArrowUpRight, LogIn, LogOut, UserRoundPlus } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";
import type { Profile, SessionUser } from "@/lib/types";

type ProfileFields = Pick<Profile, "displayName" | "bio">;

export type ProfileAction =
  | ({ action: "register"; username: string; password: string } & ProfileFields)
  | { action: "login"; username: string; password: string }
  | { action: "logout" }
  | ({ action: "updateProfile" } & ProfileFields);

type AccessMode = "register" | "login";

function readProfileFields(form: FormData): ProfileFields {
  return {
    displayName: String(form.get("displayName") ?? "").trim(),
    bio: String(form.get("bio") ?? "").trim(),
  };
}

function ProfileIdentity({ user, heading: Heading }: { user: SessionUser; heading: "h1" | "h2" }) {
  const letters = user.displayName.trim().split(/\s+/).slice(0, 2)
    .map((part) => Array.from(part)[0]).join("");

  return (
    <div className="cq-profile-identity">
      <span className="cq-avatar cq-profile-avatar" aria-hidden="true">{letters}</span>
      <div>
        <Heading>{user.displayName}</Heading>
        <p>{user.username ? `@${user.username}` : "Guest profile"}</p>
      </div>
    </div>
  );
}

export function ProfilePanel({ user, onAction }: {
  user: SessionUser | null;
  onAction: (action: ProfileAction) => Promise<void>;
}) {
  const [mode, setMode] = useState<AccessMode>("register");
  const [pending, setPending] = useState<ProfileAction["action"] | null>(null);
  const [notice, setNotice] = useState<{ kind: "error" | "success"; text: string } | null>(null);

  async function submit(action: ProfileAction, success: string) {
    if (pending) return;
    setPending(action.action);
    setNotice(null);
    try {
      await onAction(action);
      if (action.action === "logout") setMode("login");
      setNotice({ kind: "success", text: success });
    } catch (error) {
      setNotice({ kind: "error", text: error instanceof Error ? error.message : "Something went wrong. Try again." });
    } finally {
      setPending(null);
    }
  }

  function submitAccess(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const fields = new FormData(event.currentTarget);
    const username = String(fields.get("username") ?? "").trim();
    const password = String(fields.get("password") ?? "");
    if (mode === "register") {
      void submit({ action: "register", username, password, ...readProfileFields(fields) }, "Profile created.");
    } else {
      void submit({ action: "login", username, password }, "You’re logged in.");
    }
  }

  function submitEdit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void submit({ action: "updateProfile", ...readProfileFields(new FormData(event.currentTarget)) }, "Profile saved.");
  }

  const registering = mode === "register";
  const accessLabel = registering ? "Create profile" : "Log in";

  return (
    <div className="cq-profile-view">
      <div className="cq-view-title">
        <p className="cq-kicker">Your account</p>
        <h1>{user?.username ? "Your profile" : "CityQuest profile"}</h1>
        <p>{user?.username ? "Manage how other participants see you." : "Keep your activities with you across devices."}</p>
      </div>
      {notice && (
        <p className={notice.kind === "error" ? "cq-message" : "cq-profile-success"}
          role={notice.kind === "error" ? "alert" : "status"}>
          {notice.text}
        </p>
      )}
      {user?.username ? (
        <>
          <section className="cq-panel cq-profile-card" aria-label="Your profile">
            <ProfileIdentity user={user} heading="h2" />
            <a className="cq-button cq-button-quiet" href={`#profile/${user.id}`}>
              View public profile <ArrowUpRight size={16} aria-hidden="true" />
            </a>
          </section>
          <form className="cq-panel cq-profile-form" aria-label="Edit profile" onSubmit={submitEdit} key={user.id}>
            <label className="cq-field">
              Display name
              <input className="cq-input" name="displayName" autoComplete="nickname"
                defaultValue={user.displayName} required maxLength={32} />
            </label>
            <div className="cq-field">
              <label htmlFor="profile-bio">About you (optional)</label>
              <textarea className="cq-input" id="profile-bio" name="bio" defaultValue={user.bio}
                maxLength={280} rows={3} aria-describedby="profile-bio-hint" />
              <small id="profile-bio-hint">Other participants can read this on your public profile.</small>
            </div>
            <button className="cq-button" disabled={pending !== null}>
              {pending === "updateProfile" ? "Saving…" : "Save profile"}
            </button>
          </form>
          <button type="button" className="cq-button cq-button-quiet" disabled={pending !== null}
            onClick={() => void submit({ action: "logout" }, "You’re logged out.")}>
            <LogOut size={17} aria-hidden="true" />
            {pending === "logout" ? "Logging out…" : "Log out"}
          </button>
        </>
      ) : (
        <section className="cq-panel cq-profile-access" aria-label="Account access">
          {user && <ProfileIdentity user={user} heading="h2" />}
          <div className="cq-profile-switch" role="group" aria-label="Profile access">
            <button type="button" className="cq-button cq-button-quiet" aria-pressed={registering}
              disabled={pending !== null} onClick={() => { setMode("register"); setNotice(null); }}>
              Create profile
            </button>
            <button type="button" className="cq-button cq-button-quiet" aria-pressed={!registering}
              disabled={pending !== null} onClick={() => { setMode("login"); setNotice(null); }}>
              Log in
            </button>
          </div>
          {user && (
            <p className="cq-profile-note">{registering
              ? "Create a profile to keep the activities you’ve joined or hosted as a guest."
              : "Log in to an existing profile. You’ll return to this guest session when you log out."}</p>
          )}
          <form className="cq-profile-form" aria-label={accessLabel} key={mode} onSubmit={submitAccess}>
            {registering && (
              <label className="cq-field">
                Display name
                <input className="cq-input" name="displayName" autoComplete="nickname"
                  defaultValue={user?.displayName ?? ""} required maxLength={32} />
              </label>
            )}
            <div className="cq-field">
              <label htmlFor="profile-username">Username</label>
              <input className="cq-input" id="profile-username" name="username" autoComplete="username"
                autoCapitalize="none" spellCheck={false} required minLength={3} maxLength={24}
                pattern="[a-zA-Z0-9_]{3,24}" aria-describedby={registering ? "profile-username-hint" : undefined} />
              {registering && <small id="profile-username-hint">Use 3–24 letters, numbers, or underscores. Usernames appear in lowercase.</small>}
            </div>
            <div className="cq-field">
              <label htmlFor="profile-password">Password</label>
              <input className="cq-input" id="profile-password" name="password" type="password"
                autoComplete={registering ? "new-password" : "current-password"}
                required minLength={registering ? 15 : undefined} maxLength={512}
                aria-describedby={registering ? "profile-password-hint" : undefined} />
              {registering && <small id="profile-password-hint">Use 15–128 characters.</small>}
            </div>
            {registering && (
              <div className="cq-field">
                <label htmlFor="profile-bio">About you (optional)</label>
                <textarea className="cq-input" id="profile-bio" name="bio" maxLength={280}
                  rows={3} aria-describedby="profile-bio-hint" />
                <small id="profile-bio-hint">Other participants can read this on your public profile.</small>
              </div>
            )}
            <button className="cq-button" disabled={pending !== null}>
              {registering ? <UserRoundPlus size={17} aria-hidden="true" /> : <LogIn size={17} aria-hidden="true" />}
              {pending === "register" ? "Creating…" : pending === "login" ? "Logging in…" : accessLabel}
            </button>
          </form>
          {!user && <a className="cq-profile-link" href="#explore">Explore as a guest</a>}
        </section>
      )}
    </div>
  );
}

export function PublicProfilePanel({ profileId, loadProfile }: {
  profileId: string;
  loadProfile: (profileId: string, signal: AbortSignal) => Promise<Profile>;
}) {
  const [result, setResult] = useState<{ profile: Profile } | { error: string } | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    loadProfile(profileId, controller.signal).then(
      (profile) => {
        if (!controller.signal.aborted) setResult({ profile });
      },
      (error: unknown) => {
        if (!controller.signal.aborted) {
          setResult({ error: error instanceof Error ? error.message : "Couldn’t load this profile." });
        }
      },
    );
    return () => controller.abort();
  }, [loadProfile, profileId]);

  return (
    <div className="cq-profile-view">
      <a className="cq-back" href="#explore"><ArrowLeft size={17} aria-hidden="true" /> Explore activities</a>
      {!result ? (
        <p className="cq-loading" role="status">Loading profile…</p>
      ) : "error" in result ? (
        <p className="cq-message" role="alert">{result.error}</p>
      ) : (
        <section className="cq-panel cq-profile-public">
          <ProfileIdentity user={result.profile} heading="h1" />
          {result.profile.bio && <p className="cq-profile-bio">{result.profile.bio}</p>}
        </section>
      )}
    </div>
  );
}
