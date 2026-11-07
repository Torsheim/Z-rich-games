"use client";

import {
  ArrowLeft, ArrowRight, CalendarDays, Check, CirclePlus, Compass, Coffee,
  Footprints, MapPin, Search, Sparkles, Ticket, Trophy, UserRound, Users, Volleyball,
} from "lucide-react";
import { useCallback, useEffect, useRef, useState, type FormEvent, type RefObject } from "react";
import { categories, type Activity, type ActivityDetail, type Category, type Profile, type SessionUser, type User } from "@/lib/types";
import { GamePanel } from "./game-panel";
import { ProfilePanel, PublicProfilePanel, type ProfileAction } from "./profile-panel";

type View =
  | { page: "explore" | "create" | "mine" | "profile" }
  | { page: "public-profile"; profileId: string }
  | { page: "activity"; activityId: string }
  | { page: "game"; gameId: string; activityId: string };

type Dashboard = { user: SessionUser | null; activities: Activity[]; mine: Activity[] };
type DetailResult = { id: string; activity: ActivityDetail } | { id: string; error: string };
type ActivityAction = "joinActivity" | "leaveActivity" | "cancelActivity";
type FormSubmit = (event: FormEvent<HTMLFormElement>) => void;

const endpoint = "/api/cityquest";
const refreshInterval = 8_000;
const navigation = [
  { page: "explore", label: "Explore", icon: Compass },
  { page: "create", label: "Create", icon: CirclePlus },
  { page: "mine", label: "My activities", icon: CalendarDays },
  { page: "profile", label: "Profile", icon: UserRound },
] as const;
const categoryIcons = {
  outdoors: Footprints,
  food: Coffee,
  sports: Volleyball,
  culture: Sparkles,
  social: Users,
  cityquest: Trophy,
  other: CalendarDays,
};
const categoryOptions = Object.entries(categories) as [Category, string][];
const dateFormat = new Intl.DateTimeFormat("en-GB", {
  day: "numeric", month: "short", weekday: "short", timeZone: "Europe/Zurich",
});
const timeFormat = new Intl.DateTimeFormat("en-GB", {
  hour: "2-digit", minute: "2-digit", timeZone: "Europe/Zurich",
});
const stampDay = new Intl.DateTimeFormat("en-GB", { day: "numeric", timeZone: "Europe/Zurich" });
const stampMonth = new Intl.DateTimeFormat("en-GB", { month: "short", timeZone: "Europe/Zurich" });

function readView(): View {
  const [page, id, activityId] = window.location.hash.slice(1).split("/");
  if (page === "activity" && id) return { page, activityId: id };
  if (page === "game" && id && activityId) return { page, gameId: id, activityId };
  if (page === "profile" && id) return { page: "public-profile", profileId: id };
  if (page === "mine" || page === "create" || page === "profile") return { page };
  return { page: "explore" };
}

function detailHash(id: string) {
  return `#activity/${id}`;
}

function gameHash(gameId: string, activityId: string) {
  return `#game/${gameId}/${activityId}`;
}

async function request<T>(suffix = "", body?: object, signal?: AbortSignal): Promise<T> {
  const response = await fetch(endpoint + suffix, {
    cache: "no-store",
    signal,
    ...(body && { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
  });
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    throw new Error(data?.error || "CityQuest couldn't load. Please try again.");
  }
  return data;
}

async function loadPublicProfile(id: string, signal: AbortSignal) {
  const { profile } = await request<{ profile: Profile }>(`?profileId=${encodeURIComponent(id)}`, undefined, signal);
  return profile;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Something went wrong. Please try again.";
}

function textField(form: FormData, key: string) {
  return String(form.get(key) ?? "").trim();
}

function initials(name: string) {
  return name.trim().split(/\s+/).slice(0, 2).map((part) => Array.from(part)[0]).join("");
}

function Header({ view, user }: { view: View; user: User | null }) {
  return (
    <header className="cq-header">
      <div className="cq-wrap cq-header-inner">
        <a className="cq-brand" href="#explore" aria-label="CityQuest home">
          <span className="cq-brand-icon"><Compass size={23} aria-hidden="true" /></span>
          <span>CityQuest<span className="cq-brand-dot">.</span></span>
        </a>
        <nav className="cq-nav" aria-label="Main navigation">
          {navigation.map(({ page, label, icon: Icon }) => (
            <a key={page} className="cq-nav-item" href={`#${page}`}
              aria-current={view.page === page ? "page" : undefined}>
              <Icon size={19} aria-hidden="true" />
              {label}
            </a>
          ))}
        </nav>
        {user ? (
          <a className="cq-user" href="#profile" aria-label="Open your profile" title={user.displayName}>
            <span className="cq-avatar" aria-hidden="true">{initials(user.displayName)}</span>
            <span>{user.displayName}</span>
          </a>
        ) : <span className="cq-header-place"><MapPin size={16} aria-hidden="true" /> Zürich, CH</span>}
      </div>
    </header>
  );
}

function Hero() {
  return (
    <section className="cq-hero" aria-labelledby="explore-title">
      <div className="cq-hero-copy">
        <p className="cq-kicker"><MapPin size={15} aria-hidden="true" /> Local plans in Zürich</p>
        <h1 id="explore-title">Get out<span>together.</span></h1>
        <p>Find someone for coffee, get a group together for bowling, or explore the city as a team.</p>
        <a className="cq-button cq-button-hero" href="#create">Create an activity <ArrowRight size={17} aria-hidden="true" /></a>
      </div>
      <span className="cq-hero-coordinate" aria-hidden="true">47.3769° N &nbsp; 8.5417° E</span>
    </section>
  );
}

function IdentityForm({ inputRef, onSubmit, busy }: {
  inputRef: RefObject<HTMLInputElement | null>; onSubmit: FormSubmit; busy: boolean;
}) {
  return (
    <section className="cq-identity" aria-label="Set up your display name">
      <div className="cq-identity-intro">
        <span className="cq-feature-icon"><Users size={22} aria-hidden="true" /></span>
        <div>
          <strong>New to CityQuest?</strong>
          <p>Pick a display name to continue as a guest, or <a className="cq-profile-link" href="#profile">create a profile or log in</a>.</p>
        </div>
      </div>
      <form className="cq-inline-form" onSubmit={onSubmit}>
        <label className="cq-field">
          Display name
          <input ref={inputRef} name="displayName" className="cq-input" placeholder="Your first name or nickname"
            autoComplete="nickname" required maxLength={32} />
        </label>
        <button className="cq-button" disabled={busy}>{busy ? "Saving…" : "Continue"}</button>
      </form>
    </section>
  );
}

function CategoryLabel({ category }: { category: Category }) {
  const Icon = categoryIcons[category];
  return (
    <span className={`cq-card-label${category === "cityquest" ? " cq-card-label-quest" : ""}`}>
      <Icon size={13} aria-hidden="true" /> {categories[category]}
    </span>
  );
}

function ActivityMeta({ activity, detailed = false }: { activity: Activity; detailed?: boolean }) {
  return (
    <div className="cq-meta">
      <span><MapPin size={15} aria-hidden="true" /> {activity.location}</span>
      <span>
        <CalendarDays size={15} aria-hidden="true" />
        <time dateTime={activity.startsAt}>
          {dateFormat.format(new Date(activity.startsAt))} · {timeFormat.format(new Date(activity.startsAt))}
          {detailed ? " Zürich time" : ""}
        </time>
      </span>
    </div>
  );
}

function ActivityCard({ activity, busy, onAction }: {
  activity: Activity; busy: boolean; onAction: (action: ActivityAction, id: string) => void;
}) {
  const startsAt = new Date(activity.startsAt);
  const full = activity.participantCount >= activity.maxParticipants;
  return (
    <li className="cq-card">
      <div>
        <CategoryLabel category={activity.category} />
        {activity.cancelled && <span className="cq-status-label">Cancelled</span>}
        <h3><a href={detailHash(activity.id)}>{activity.title}</a></h3>
        {activity.description && <p className="cq-card-description">{activity.description}</p>}
        <ActivityMeta activity={activity} />
      </div>
      <div className="cq-stamp" aria-hidden="true">
        <strong>{stampDay.format(startsAt)}</strong>
        <small>{stampMonth.format(startsAt)}</small>
      </div>
      <div className="cq-card-bottom">
        <span className="cq-card-count">
          <Users size={16} aria-hidden="true" /> {activity.participantCount} of {activity.maxParticipants} going
        </span>
        <div className="cq-card-actions">
          {activity.joined && !activity.cancelled && <span className="cq-joined"><Check size={15} aria-hidden="true" /> Joined</span>}
          <a className={`cq-button ${activity.joined ? "" : "cq-button-quiet"}`} href={detailHash(activity.id)}>
            Details
          </a>
          {!activity.joined && !activity.cancelled && (
            <button className="cq-button" disabled={busy || full}
              onClick={() => onAction("joinActivity", activity.id)}>
              {full ? "Full" : "Join activity"}
            </button>
          )}
        </div>
      </div>
    </li>
  );
}

function EmptyState({ title, description, action, href }: {
  title: string; description: string; action?: string; href?: string;
}) {
  return (
    <div className="cq-empty">
      <span className="cq-empty-icon"><CalendarDays size={22} aria-hidden="true" /></span>
      <h3>{title}</h3>
      <p>{description}</p>
      {action && <a className="cq-button cq-button-quiet" href={href}>{action}<ArrowRight size={15} aria-hidden="true" /></a>}
    </div>
  );
}

function Explore({ dashboard, onAction, joinByCode, busy }: {
  dashboard: Dashboard | null; onAction: (action: ActivityAction, id: string) => void;
  joinByCode: FormSubmit; busy: boolean;
}) {
  const [filter, setFilter] = useState<Category | "all">("all");
  const activities = dashboard?.activities ?? [];
  const filtered = filter === "all" ? activities : activities.filter(({ category }) => category === filter);

  return (
    <div className="cq-explore-grid">
      <section aria-labelledby="upcoming-title">
        <div className="cq-section-head">
          <div>
            <p className="cq-kicker">Find a plan</p>
            <h2 id="upcoming-title">Upcoming activities</h2>
            <p>Pick a plan and see who’s going.</p>
          </div>
        </div>
        {dashboard && activities.length > 0 && (
          <div className="cq-filters" role="group" aria-label="Filter by category">
            <button className="cq-filter" aria-pressed={filter === "all"} onClick={() => setFilter("all")}>
              <Search size={14} aria-hidden="true" /> All activities
            </button>
            {categoryOptions.filter(([category]) => activities.some((activity) => activity.category === category)
              || category === filter).map(([category, label]) => {
              const Icon = categoryIcons[category];
              return (
                <button className="cq-filter" key={category} aria-pressed={filter === category} onClick={() => setFilter(category)}>
                  <Icon size={14} aria-hidden="true" /> {label}
                </button>
              );
            })}
          </div>
        )}
        {dashboard && (filtered.length > 0 ? (
          <ul className="cq-cards">
            {filtered.map((activity) => <ActivityCard activity={activity} key={activity.id} busy={busy} onAction={onAction} />)}
          </ul>
        ) : (
          <EmptyState title={filter === "all" ? "No upcoming activities" : "No activities in this category"}
            description={filter === "all" ? "Be the first to put something on the calendar." : "Choose another category or start your own plan."}
            action="Host an activity" href="#create" />
        ))}
      </section>
      <aside className="cq-code-card" aria-labelledby="game-code-title">
        <span className="cq-feature-icon"><Ticket size={22} aria-hidden="true" /></span>
        <h2 id="game-code-title">Join a CityQuest</h2>
        <p>Got a code from a host? Use it to join their game.</p>
        <form onSubmit={joinByCode}>
          <label className="cq-code-input">
            <span className="cq-visually-hidden">Game code</span>
            <input className="cq-input" name="code" placeholder="6-character code" required minLength={6} maxLength={6}
              autoComplete="off" autoCapitalize="characters" pattern="[a-zA-Z0-9]{6}" spellCheck={false} />
          </label>
          <button className="cq-button" disabled={busy}>Join game</button>
        </form>
      </aside>
    </div>
  );
}

function CreateActivity({ onSubmit, busy }: { onSubmit: FormSubmit; busy: boolean }) {
  return (
    <form className="cq-panel cq-create-form" onSubmit={onSubmit}>
      <label className="cq-field">
        Activity title
        <input className="cq-input" name="title" required maxLength={80} placeholder="Bowling after work" />
      </label>
      <div className="cq-field">
        <label htmlFor="activity-category">Category</label>
        <select className="cq-input" id="activity-category" name="category" defaultValue="social" required>
          {categoryOptions.map(([key, label]) => <option value={key} key={key}>{label}</option>)}
        </select>
      </div>
      <label className="cq-field">
        Description (optional)
        <textarea className="cq-input" name="description" maxLength={500} rows={3} placeholder="What should people know before they come?" />
      </label>
      <div className="cq-field">
        <label htmlFor="activity-location">Meeting location</label>
        <input className="cq-input" id="activity-location" name="location" aria-describedby="location-hint"
          required maxLength={120} placeholder="Outside the entrance to the bowling alley" />
        <small id="location-hint">Choose a public meeting place that’s easy to find.</small>
      </div>
      <div className="cq-form-grid">
        <div className="cq-field">
          <label htmlFor="activity-date">Date and time</label>
          <input className="cq-input" id="activity-date" name="startsAt" type="datetime-local" aria-describedby="date-hint" required />
          <small id="date-hint">Uses this device’s time zone.</small>
        </div>
        <div className="cq-field">
          <label htmlFor="activity-capacity">Maximum participants</label>
          <input className="cq-input" id="activity-capacity" name="maxParticipants" type="number"
            aria-describedby="capacity-hint" required defaultValue={6} min={2} max={100} />
          <small id="capacity-hint">Count yourself in the total.</small>
        </div>
      </div>
      <button className="cq-button" disabled={busy}>{busy ? "Publishing…" : "Publish activity"} <ArrowRight size={16} aria-hidden="true" /></button>
    </form>
  );
}

function ActivityDetails({ activity, user, busy, onAction }: {
  activity: ActivityDetail; user: User | null; busy: boolean; onAction: (action: ActivityAction, id: string) => void;
}) {
  const [confirmCancel, setConfirmCancel] = useState(false);
  const full = activity.participantCount >= activity.maxParticipants;
  return (
    <div className="cq-detail">
      <section className="cq-panel cq-detail-intro" aria-labelledby="activity-title">
        <CategoryLabel category={activity.category} />
        {activity.cancelled && <span className="cq-status-label">Cancelled</span>}
        <h1 id="activity-title">{activity.title}</h1>
        <ActivityMeta activity={activity} detailed />
        {activity.description && <p>{activity.description}</p>}
        {!activity.cancelled && (
          <div className="cq-detail-actions">
            {activity.gameId && activity.joined && (
              <a className="cq-button" href={gameHash(activity.gameId, activity.id)}>
                <Trophy size={17} aria-hidden="true" /> Enter game
              </a>
            )}
            {activity.joined ? (
              <button className="cq-button cq-button-quiet" disabled={busy} onClick={() => onAction("leaveActivity", activity.id)}>
                Leave activity
              </button>
            ) : (
              <button className="cq-button" disabled={busy || full} onClick={() => onAction("joinActivity", activity.id)}>
                {full ? "Activity full" : "Join activity"}
              </button>
            )}
            {activity.isHost && !confirmCancel && (
              <button className="cq-button cq-button-danger" disabled={busy} onClick={() => setConfirmCancel(true)}>Cancel activity</button>
            )}
          </div>
        )}
        {confirmCancel && !activity.cancelled && (
          <div className="cq-cancel">
            <p>Cancel this activity for everyone?</p>
            <div>
              <button className="cq-button cq-button-quiet" disabled={busy} onClick={() => setConfirmCancel(false)}>Keep activity</button>
              <button className="cq-button cq-button-danger" disabled={busy} onClick={() => onAction("cancelActivity", activity.id)}>
                Confirm cancellation
              </button>
            </div>
          </div>
        )}
      </section>
      <section className="cq-panel" aria-labelledby="participants-title">
        <div className="cq-participants-head">
          <h2 id="participants-title">Who’s going</h2>
          <span>{activity.participantCount} of {activity.maxParticipants} spots filled</span>
        </div>
        {activity.participants.length > 0 ? (
          <ul className="cq-participants">
            {activity.participants.map((participant) => (
              <li key={participant.id}>
                <span className="cq-avatar" aria-hidden="true">{initials(participant.displayName)}</span>
                <span>
                  {participant.username ? (
                    <a className="cq-profile-link" href={`#profile/${participant.id}`}>{participant.displayName}</a>
                  ) : participant.displayName}
                  {participant.id === user?.id && <span className="cq-person-note"> (you)</span>}
                </span>
              </li>
            ))}
          </ul>
        ) : <p className="cq-loading">No participants yet.</p>}
      </section>
    </div>
  );
}

export function ActivityApp() {
  const [view, setView] = useState<View>({ page: "explore" });
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);
  const [detail, setDetail] = useState<DetailResult | null>(null);
  const [loadError, setLoadError] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const identityInput = useRef<HTMLInputElement>(null);
  const dashboardRequest = useRef(0);
  const detailRequest = useRef(0);
  const activityId = view.page === "activity" ? view.activityId : null;
  const user = dashboard?.user ?? null;

  useEffect(() => {
    function update() {
      setView(readView());
      setMessage("");
      window.scrollTo(0, 0);
    }
    update();
    window.addEventListener("hashchange", update);
    return () => window.removeEventListener("hashchange", update);
  }, []);

  const refreshDashboard = useCallback(async (signal?: AbortSignal) => {
    const sequence = ++dashboardRequest.current;
    try {
      const result = await request<Dashboard>("", undefined, signal);
      if (!signal?.aborted && sequence === dashboardRequest.current) {
        setDashboard(result);
        setLoadError("");
      }
    } catch (error) {
      if (!signal?.aborted && sequence === dashboardRequest.current) setLoadError(errorMessage(error));
    }
  }, []);

  const refreshDetail = useCallback(async (id: string, signal?: AbortSignal) => {
    const sequence = ++detailRequest.current;
    try {
      const { activity } = await request<{ activity: ActivityDetail }>(`?activityId=${encodeURIComponent(id)}`, undefined, signal);
      if (!signal?.aborted && sequence === detailRequest.current) setDetail({ id, activity });
    } catch (error) {
      if (!signal?.aborted && sequence === detailRequest.current) setDetail({ id, error: errorMessage(error) });
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    const refresh = () => {
      if (!document.hidden) void refreshDashboard(controller.signal);
    };
    refresh();
    const timer = window.setInterval(refresh, refreshInterval);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      controller.abort();
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [refreshDashboard]);

  useEffect(() => {
    if (!activityId) return;
    const id = activityId;
    const controller = new AbortController();
    const refresh = () => {
      if (!document.hidden) void refreshDetail(id, controller.signal);
    };
    refresh();
    const timer = window.setInterval(refresh, refreshInterval);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      controller.abort();
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [activityId, refreshDetail]);

  async function mutate(task: () => Promise<void>, requiresIdentity = true) {
    if (busy) return;
    setMessage("");
    if (requiresIdentity && !user) {
      setMessage("Add a display name to continue.");
      identityInput.current?.focus();
      return;
    }
    setBusy(true);
    try {
      await task();
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  function updateSession(nextUser: SessionUser | null) {
    ++dashboardRequest.current;
    setDashboard((current) => {
      if (!current) return current;
      if (current.user?.id === nextUser?.id) return { ...current, user: nextUser };

      return {
        user: nextUser,
        activities: current.activities.map((activity) => ({ ...activity, joined: false, isHost: false })),
        mine: [],
      };
    });
  }

  async function profileAction(action: ProfileAction) {
    const { user: updated } = await request<{ user: SessionUser | null }>("", action);
    updateSession(updated);
    setDetail(null);
    await Promise.all([refreshDashboard(), activityId ? refreshDetail(activityId) : undefined]);
  }

  function submitIdentity(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    void mutate(async () => {
      const { user: identified } = await request<{ user: SessionUser }>("", { action: "identify", displayName: textField(form, "displayName") });
      updateSession(identified);
      await Promise.all([refreshDashboard(), activityId ? refreshDetail(activityId) : undefined]);
    }, false);
  }

  function submitActivity(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    void mutate(async () => {
      const { activityId: id } = await request<{ activityId: string }>("", {
        action: "createActivity",
        title: textField(form, "title"),
        description: textField(form, "description"),
        category: textField(form, "category"),
        location: textField(form, "location"),
        startsAt: new Date(textField(form, "startsAt")).toISOString(),
        maxParticipants: Number(form.get("maxParticipants")),
      });
      window.location.hash = detailHash(id);
      await refreshDashboard();
    });
  }

  function submitCode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    void mutate(async () => {
      const { activityId: id } = await request<{ activityId: string }>("", { action: "joinByCode", code: textField(form, "code") });
      window.location.hash = detailHash(id);
      await refreshDashboard();
    });
  }

  function activityAction(action: ActivityAction, id: string) {
    void mutate(async () => {
      await request("", { action, activityId: id });
      await Promise.all([refreshDashboard(), id === activityId ? refreshDetail(id) : undefined]);
    });
  }

  const identity = dashboard && !user
    ? <IdentityForm inputRef={identityInput} onSubmit={submitIdentity} busy={busy} />
    : null;
  const notices = (
    <>
      {message && <div className="cq-message" role="alert">{message}</div>}
      {loadError && (
        <div className="cq-message" role="alert">
          {loadError}
          <button className="cq-button cq-button-quiet" onClick={() => void refreshDashboard()}>Retry</button>
        </div>
      )}
      {!dashboard && !loadError && <p className="cq-loading" role="status">Loading CityQuest…</p>}
    </>
  );
  const detailResult = detail && detail.id === activityId ? detail : null;

  return (
    <div className="cq-shell">
      <Header user={user} view={view} />
      <main className="cq-wrap cq-main">
        {view.page === "explore" && (
          <>
            <Hero />
            {notices}
            {identity}
            <Explore dashboard={dashboard} busy={busy} onAction={activityAction} joinByCode={submitCode} />
          </>
        )}
        {view.page === "create" && (
          <div className="cq-view">
            <div className="cq-view-title">
              <p className="cq-kicker">Host a get-together</p>
              <h1>Create an activity</h1>
              <p>Choose what to do, where to meet, and when to go.</p>
            </div>
            {notices}
            {identity}
            {user && <CreateActivity onSubmit={submitActivity} busy={busy} />}
          </div>
        )}
        {view.page === "mine" && (
          <div className="cq-view">
            <div className="cq-view-title">
              <p className="cq-kicker">Your plans</p>
              <h1>My activities</h1>
              <p>Activities you’ve joined or hosted.</p>
            </div>
            {notices}
            {identity}
            {user && (dashboard?.mine.length ? (
              <ul className="cq-cards">
                {dashboard.mine.map((activity) => <ActivityCard activity={activity} key={activity.id} busy={busy} onAction={activityAction} />)}
              </ul>
            ) : (
              <EmptyState title="No activities yet" description="Find something to join or create a plan of your own."
                action="Explore activities" href="#explore" />
            ))}
          </div>
        )}
        {view.page === "activity" && (
          <div className="cq-view">
            <a className="cq-back" href="#explore"><ArrowLeft size={17} aria-hidden="true" /> Explore activities</a>
            {notices}
            {identity}
            {!detailResult ? (
              <p className="cq-loading" role="status">Loading activity…</p>
            ) : "error" in detailResult ? (
              <div className="cq-message" role="alert">
                {detailResult.error}
                <button className="cq-button cq-button-quiet" onClick={() => void refreshDetail(view.activityId)}>Retry</button>
              </div>
            ) : (
              <ActivityDetails key={detailResult.id} activity={detailResult.activity}
                user={user} busy={busy} onAction={activityAction} />
            )}
          </div>
        )}
        {view.page === "profile" && (
          <>
            {notices}
            {dashboard && <ProfilePanel user={user} onAction={profileAction} />}
          </>
        )}
        {view.page === "public-profile" && (
          <PublicProfilePanel key={view.profileId} profileId={view.profileId} loadProfile={loadPublicProfile} />
        )}
        {view.page === "game" && (
          <>
            {notices}
            {identity}
            {user && <GamePanel key={view.gameId} gameId={view.gameId} user={user}
              onBack={() => { window.location.hash = detailHash(view.activityId); }} />}
          </>
        )}
        <footer className="cq-footer"><Compass size={15} aria-hidden="true" /> CityQuest · Zürich, Switzerland</footer>
      </main>
    </div>
  );
}
