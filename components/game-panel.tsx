"use client";

import {
  ArrowLeft, Check, ChevronDown, Clipboard, Flag, MapPinned, Play, Plus,
  RefreshCw, Trophy, UsersRound,
} from "lucide-react";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import type { GameView, User } from "@/lib/types";
import styles from "./game-panel.module.css";

type GameAction =
  | { action: "createTeam"; name: string }
  | { action: "joinTeam"; teamId: string }
  | { action: "setGameStatus"; status: "active" | "finished" }
  | { action: "completeChallenge"; challengeId: string };

const statusLabels = { lobby: "Lobby", active: "In play", finished: "Finished" };

export function GamePanel({ gameId, user, onBack }: { gameId: string; user: User; onBack: () => void }) {
  const [game, setGame] = useState<GameView>();
  const [teamName, setTeamName] = useState("");
  const [pending, setPending] = useState<string>();
  const [loadError, setLoadError] = useState("");
  const [actionError, setActionError] = useState("");
  const [copyMessage, setCopyMessage] = useState("");
  const request = useRef(0);
  const saving = useRef(false);

  const refresh = useCallback(async (reportError: boolean, signal?: AbortSignal) => {
    const requestId = ++request.current;
    try {
      const response = await fetch(`/api/cityquest?gameId=${encodeURIComponent(gameId)}`, {
        cache: "no-store",
        signal,
      });
      const result = await response.json().catch(() => null) as { game?: GameView; error?: string } | null;
      if (!response.ok || !result?.game) {
        throw new Error(result?.error || "The game could not be loaded.");
      }
      if (!signal?.aborted && requestId === request.current) {
        setGame(result.game);
        setLoadError("");
      }
    } catch (error) {
      if (reportError && !signal?.aborted && requestId === request.current) {
        setLoadError(error instanceof Error ? error.message : "The game could not be loaded.");
      }
    }
  }, [gameId]);

  useEffect(() => {
    const controller = new AbortController();
    queueMicrotask(() => {
      if (!controller.signal.aborted) void refresh(true, controller.signal);
    });
    const sync = () => {
      if (!saving.current && !document.hidden) {
        void refresh(false, controller.signal);
      }
    };
    const poll = window.setInterval(sync, 8000);
    document.addEventListener("visibilitychange", sync);
    return () => {
      controller.abort();
      window.clearInterval(poll);
      document.removeEventListener("visibilitychange", sync);
    };
  }, [refresh]);

  async function run(action: GameAction, pendingId: string) {
    if (saving.current) return;
    saving.current = true;
    request.current++;
    setPending(pendingId);
    setActionError("");
    try {
      const response = await fetch("/api/cityquest", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ gameId, ...action }),
      });
      const result = await response.json().catch(() => null) as { ok?: boolean; error?: string } | null;
      if (!response.ok || !result?.ok) {
        throw new Error(result?.error || "Your change could not be saved.");
      }
      if (action.action === "createTeam") setTeamName("");
      await refresh(true);
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "Your change could not be saved.");
      await refresh(false);
    } finally {
      saving.current = false;
      setPending(undefined);
    }
  }

  function createTeam(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const name = teamName.trim();
    if (name) void run({ action: "createTeam", name }, "create");
  }

  async function copyCode(code: string) {
    try {
      await navigator.clipboard.writeText(code);
      setCopyMessage("Join code copied.");
    } catch {
      setCopyMessage("Select the join code to copy it.");
    }
  }

  const back = (
    <button type="button" className={styles.button} data-variant="quiet" onClick={onBack}>
      <ArrowLeft size={17} aria-hidden="true" />
      Back to activity
    </button>
  );

  if (!game) {
    return (
      <div className={styles.panel}>
        <div>{back}</div>
        {loadError ? (
          <div className={styles.section}>
            <p className={styles.error} role="alert">{loadError}</p>
            <button type="button" className={styles.button} onClick={() => void refresh(true)}>
              Try again
            </button>
          </div>
        ) : (
          <p className={styles.muted} role="status">Loading CityQuest…</p>
        )}
      </div>
    );
  }

  const { status, teams, teamId, challenges } = game;
  const standings = [...teams].sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
  const team = teams.find((entry) => entry.id === teamId);
  const completedCount = challenges.filter((challenge) => challenge.completed).length;
  const canComplete = status === "active" && Boolean(team);
  const busy = Boolean(pending);

  return (
    <div className={styles.panel}>
      <div>{back}</div>
      <header className={styles.banner}>
        <div>
          <span className={styles.status} data-active={status === "active"} role="status">
            <Flag size={14} aria-hidden="true" />
            {statusLabels[status]}
          </span>
          <h1>{game.title}</h1>
          <p>
            {status === "lobby" && "Gather a team, then head out and explore the city together."}
            {status === "active" && "Explore together and mark challenges complete as your team finishes them."}
            {status === "finished" && "The game is over. See how the teams placed below."}
          </p>
          <div className={styles.controls}>
            {game.isHost && status === "lobby" && (
              <button
                type="button"
                className={styles.button}
                data-variant="lime"
                disabled={busy || teams.length === 0}
                onClick={() => void run({ action: "setGameStatus", status: "active" }, "start")}
              >
                <Play size={16} aria-hidden="true" />
                {pending === "start" ? "Starting…" : "Start game"}
              </button>
            )}
            {game.isHost && status === "active" && (
              <button
                type="button"
                className={styles.button}
                data-variant="lime"
                disabled={busy}
                onClick={() => {
                  if (window.confirm("Finish the game and lock the leaderboard?")) {
                    void run({ action: "setGameStatus", status: "finished" }, "finish");
                  }
                }}
              >
                <Flag size={16} aria-hidden="true" />
                {pending === "finish" ? "Finishing…" : "Finish game"}
              </button>
            )}
            <button
              type="button"
              className={styles.button}
              data-variant="glass"
              disabled={busy}
              onClick={() => void refresh(true)}
            >
              <RefreshCw size={16} aria-hidden="true" />
              Refresh
            </button>
            {game.isHost && status === "lobby" && (
              <p>{teams.length ? "Make sure everyone is on a team before you start." : "Create a team to start the game."}</p>
            )}
          </div>
        </div>
        {status === "lobby" && (
          <div className={styles.code}>
            <div>
              <span>Join code</span>
              <code>{game.joinCode}</code>
              <span role="status">{copyMessage}</span>
            </div>
            <button
              type="button"
              className={`${styles.button} ${styles.copyButton}`}
              data-variant="glass"
              aria-label="Copy join code"
              onClick={() => void copyCode(game.joinCode)}
            >
              {copyMessage === "Join code copied." ? (
                <Check size={18} aria-hidden="true" />
              ) : (
                <Clipboard size={18} aria-hidden="true" />
              )}
            </button>
          </div>
        )}
      </header>

      {loadError && <p className={styles.error} role="alert">{loadError}</p>}
      {actionError && <p className={styles.error} role="alert">{actionError}</p>}

      <div className={styles.columns}>
        <section className={`${styles.section} ${styles.teamSection}`} aria-labelledby="game-teams">
          <div className={styles.sectionHeader}>
            <div>
              <h2 id="game-teams"><UsersRound size={20} aria-hidden="true" /> Teams</h2>
              {status === "lobby" && <p>Join or create a team of up to four players before the game starts.</p>}
              {status === "active" && !team && <p>You can follow the game from the leaderboard.</p>}
            </div>
          </div>
          {teams.length ? (
            <ul className={styles.teams} role="list">
              {teams.map((entry) => {
                const current = entry.id === teamId;
                const full = entry.members.length >= 4;
                return (
                  <li key={entry.id} className={styles.team} data-current={current}>
                    <div className={styles.teamInfo}>
                      <strong id={`game-team-${entry.id}`}>{entry.name}{current && " · Your team"}</strong>
                      <p>
                        {entry.members.length}/4 players
                        {entry.members.length > 0 && " · "}
                        {entry.members.map((member) => member.id === user.id ? "You" : member.displayName).join(", ")}
                      </p>
                    </div>
                    {status === "lobby" && !current && (
                      <button
                        type="button"
                        className={styles.button}
                        data-variant="quiet"
                        disabled={busy || full}
                        aria-describedby={`game-team-${entry.id}`}
                        onClick={() => void run({ action: "joinTeam", teamId: entry.id }, entry.id)}
                      >
                        {pending === entry.id ? "Joining…" : full ? "Full" : team ? "Switch team" : "Join team"}
                      </button>
                    )}
                  </li>
                );
              })}
            </ul>
          ) : (
            <p className={styles.muted}>Create the first team.</p>
          )}
          {status === "lobby" && (
            <form className={styles.teamForm} onSubmit={createTeam}>
              <label htmlFor="game-team-name">Team name</label>
              <div className={styles.formFields}>
                <input
                  id="game-team-name"
                  value={teamName}
                  placeholder="e.g. Old Town Rovers"
                  required
                  maxLength={32}
                  onChange={(event) => setTeamName(event.target.value)}
                />
                <button type="submit" className={styles.button} disabled={busy || !teamName.trim()}>
                  <Plus size={16} aria-hidden="true" />
                  {pending === "create" ? "Creating…" : "Create team"}
                </button>
              </div>
            </form>
          )}
        </section>

        <section className={`${styles.section} ${styles.leaderboardSection}`} aria-labelledby="game-leaderboard">
          <div className={styles.sectionHeader}>
            <div>
              <h2 id="game-leaderboard"><Trophy size={20} aria-hidden="true" /> Leaderboard</h2>
              <p>{status === "finished" ? "Final team scores" : "Scores update as teams complete challenges."}</p>
            </div>
          </div>
          {standings.length ? (
            <ol className={styles.standings} role="list">
              {standings.map((entry) => (
                <li key={entry.id} className={styles.standing} data-current={entry.id === teamId}>
                  <span className={styles.rank}>{standings.findIndex((item) => item.score === entry.score) + 1}</span>
                  <span className={styles.standingName}>{entry.name}</span>
                  <span className={styles.standingScore} aria-live={entry.id === teamId ? "polite" : "off"}>
                    {entry.score} pts
                  </span>
                </li>
              ))}
            </ol>
          ) : (
            <p className={styles.muted}>Teams will appear here as they form.</p>
          )}
        </section>

        <section className={`${styles.section} ${styles.challengeSection}`} aria-labelledby="game-challenges">
          <div className={styles.sectionHeader}>
            <div>
              <h2 id="game-challenges"><MapPinned size={20} aria-hidden="true" /> Challenges</h2>
              <p>
                {status === "lobby"
                  ? "Read the challenges now and start scoring when the game begins."
                  : team ? `${completedCount} of ${challenges.length} completed by your team` : "Open a challenge to read the instructions."}
              </p>
            </div>
          </div>
          <ul className={styles.challenges} role="list">
            {challenges.map((challenge) => (
              <li key={challenge.id}>
                <details className={styles.challenge}>
                  <summary>
                    <span><small>{challenge.category}</small>{challenge.title}</span>
                    {challenge.completed && (
                      <span className={styles.done}>
                        <Check size={14} aria-hidden="true" />
                        <span className={styles.visuallyHidden}>Completed</span>
                      </span>
                    )}
                    <span className={styles.points}>{challenge.points} pts</span>
                    <ChevronDown className={styles.chevron} size={16} aria-hidden="true" />
                  </summary>
                  <div className={styles.challengeBody}>
                    <p>{challenge.description}</p>
                    {challenge.completed ? (
                      <p className={styles.muted}>Completed by your team.</p>
                    ) : canComplete && (
                      <button
                        type="button"
                        className={styles.button}
                        disabled={busy}
                        onClick={() => void run({
                          action: "completeChallenge",
                          challengeId: challenge.id,
                        }, challenge.id)}
                      >
                        <Check size={16} aria-hidden="true" />
                        {pending === challenge.id ? "Saving…" : "Mark complete"}
                      </button>
                    )}
                  </div>
                </details>
              </li>
            ))}
          </ul>
        </section>
      </div>
    </div>
  );
}
