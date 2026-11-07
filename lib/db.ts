import "server-only";

import { randomInt } from "node:crypto";
import { Pool, type PoolClient } from "pg";
import { AppError } from "./errors";
import type {
  Activity,
  ActivityDetail,
  CreateActivityInput,
  GameStatus,
  GameView,
  User,
} from "./types";

const teamCapacity = 4;
let pool: Pool | undefined;

function database() {
  const connectionString = process.env.DATABASE_URL || process.env.POSTGRES_URL;
  if (!connectionString) {
    throw new AppError("CityQuest’s database is not configured.", 503);
  }
  if (!pool) {
    pool = new Pool({
      connectionString,
      max: process.env.VERCEL ? 1 : 5,
      connectionTimeoutMillis: 5000,
    });
    pool.on("error", (error) => console.error("Idle database connection failed", error.message));
  }
  return pool;
}

async function transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await database().connect();
  let discardClient = false;

  try {
    await client.query("begin");
    const result = await work(client);
    await client.query("commit");
    return result;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch {
      discardClient = true;
    }
    throw error;
  } finally {
    client.release(discardClient);
  }
}

export async function createSession(displayName: string, tokenDigest: string): Promise<User> {
  const result = await database().query<User>(
    `insert into cityquest.users (display_name, token_hash) values ($1, $2)
     returning id, display_name as "displayName"`,
    [displayName, tokenDigest],
  );
  return result.rows[0];
}

export async function getSession(tokenDigest: string): Promise<User | null> {
  const result = await database().query<User>(
    'select id, display_name as "displayName" from cityquest.users where token_hash = $1',
    [tokenDigest],
  );
  return result.rows[0] ?? null;
}

type ActivityRow = Omit<Activity, "startsAt"> & { startsAt: Date };
type ActivityDetailRow = ActivityRow & Pick<ActivityDetail, "participants">;

const activityColumns = `
  a.id, a.title, a.category, a.description, a.location,
  a.starts_at as "startsAt", a.max_participants as "maxParticipants",
  stats.count as "participantCount", stats.joined,
  coalesce(a.creator_id = $1, false) as "isHost",
  a.cancelled_at is not null as cancelled,
  g.id as "gameId"`;

const activityFrom = `
  from cityquest.activities a
  left join cityquest.games g on g.activity_id = a.id`;

function withIsoDate<T extends ActivityRow>(row: T): Omit<T, "startsAt"> & { startsAt: string } {
  return { ...row, startsAt: row.startsAt.toISOString() };
}

export async function listActivities(userId: string | null): Promise<{
  activities: Activity[];
  mine: Activity[];
}> {
  const result = await database().query<ActivityRow & { upcoming: boolean }>(
    `select ${activityColumns},
       a.cancelled_at is null and a.starts_at > now() as upcoming
     ${activityFrom}
     cross join lateral (
       select count(*)::int as count, coalesce(bool_or(p.user_id = $1), false) as joined
       from cityquest.activity_participants p where p.activity_id = a.id
     ) stats
     where (a.cancelled_at is null and a.starts_at > now())
       or a.creator_id = $1 or stats.joined
     order by a.starts_at, a.id`,
    [userId],
  );

  const activities: Activity[] = [];
  const mine: Activity[] = [];
  for (const { upcoming, ...row } of result.rows) {
    const activity = withIsoDate(row);
    if (upcoming) activities.push(activity);
    if (activity.joined || activity.isHost) mine.push(activity);
  }
  return { activities, mine };
}

export async function getActivity(id: string, userId: string | null): Promise<ActivityDetail> {
  const result = await database().query<ActivityDetailRow>(
    `select ${activityColumns}, stats.participants
     ${activityFrom}
     cross join lateral (
       select count(*)::int as count, coalesce(bool_or(p.user_id = $1), false) as joined,
         coalesce(json_agg(json_build_object('id', u.id, 'displayName', u.display_name)
           order by p.joined_at, u.id), '[]'::json) as participants
       from cityquest.activity_participants p
       join cityquest.users u on u.id = p.user_id
       where p.activity_id = a.id
     ) stats
     where a.id = $2`,
    [userId, id],
  );
  const row = result.rows[0];
  if (!row) throw new AppError("Activity not found.", 404);
  return withIsoDate(row);
}

function gameCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  return Array.from({ length: 6 }, () => alphabet[randomInt(alphabet.length)]).join("");
}

export async function createActivity(userId: string, input: CreateActivityInput): Promise<string> {
  return transaction(async (client) => {
    const result = await client.query<{ id: string }>(
      `insert into cityquest.activities (
         creator_id, title, category, description, location, starts_at, max_participants
       ) values ($1, $2, $3, $4, $5, $6, $7)
       returning id`,
      [
        userId,
        input.title,
        input.category,
        input.description,
        input.location,
        input.startsAt,
        input.maxParticipants,
      ],
    );
    const { id } = result.rows[0];
    await client.query(
      "insert into cityquest.activity_participants (activity_id, user_id) values ($1, $2)",
      [id, userId],
    );

    if (input.category === "cityquest") {
      for (let attempt = 0; attempt < 5; attempt++) {
        const game = await client.query(
          `insert into cityquest.games (activity_id, join_code) values ($1, $2)
           on conflict (join_code) do nothing returning id`,
          [id, gameCode()],
        );
        if (game.rowCount) return id;
      }
      throw new AppError("Could not create a join code. Please try again.", 503);
    }
    return id;
  });
}

type LockedActivity = {
  id: string;
  creatorId: string;
  maxParticipants: number;
  cancelled: boolean;
  started: boolean;
};

type LockedGame = {
  id: string;
  status: GameStatus;
};

async function lockActivity(client: PoolClient, id: string): Promise<LockedActivity> {
  // Activity membership and all game writes take this lock before reading mutable state.
  const result = await client.query<LockedActivity>(
    `select id, creator_id as "creatorId", max_participants as "maxParticipants",
       cancelled_at is not null as cancelled, starts_at <= now() as started
     from cityquest.activities where id = $1 for update`,
    [id],
  );
  const activity = result.rows[0];
  if (!activity) throw new AppError("Activity not found.", 404);
  return activity;
}

async function activityGame(client: PoolClient, activityId: string): Promise<LockedGame | undefined> {
  const result = await client.query<LockedGame>(
    "select id, status from cityquest.games where activity_id = $1",
    [activityId],
  );
  return result.rows[0];
}

async function joinLockedActivity(client: PoolClient, userId: string, id: string): Promise<void> {
  const activity = await lockActivity(client, id);
  if (activity.cancelled) throw new AppError("This activity was cancelled.", 409);

  const result = await client.query<{ count: number; joined: boolean }>(
    `select count(*)::int as count, coalesce(bool_or(user_id = $2), false) as joined
     from cityquest.activity_participants where activity_id = $1`,
    [id, userId],
  );
  const { count, joined } = result.rows[0];
  if (joined) return;

  const game = await activityGame(client, id);
  if (game && game.status !== "lobby") {
    throw new AppError("This CityQuest game is no longer accepting players.", 409);
  }
  if (!game && activity.started) throw new AppError("This activity has already started.", 409);
  if (count >= activity.maxParticipants) throw new AppError("This activity is full.", 409);

  await client.query(
    "insert into cityquest.activity_participants (activity_id, user_id) values ($1, $2)",
    [id, userId],
  );
}

export async function joinActivity(userId: string, id: string): Promise<void> {
  await transaction((client) => joinLockedActivity(client, userId, id));
}

export async function joinByCode(userId: string, code: string): Promise<string> {
  return transaction(async (client) => {
    const result = await client.query<{ activityId: string }>(
      'select activity_id as "activityId" from cityquest.games where join_code = $1',
      [code],
    );
    const game = result.rows[0];
    if (!game) throw new AppError("No CityQuest game matches this code.", 404);
    await joinLockedActivity(client, userId, game.activityId);
    return game.activityId;
  });
}

async function pruneTeam(client: PoolClient, teamId: string): Promise<void> {
  await client.query(
    `delete from cityquest.teams where id = $1
       and not exists (select 1 from cityquest.team_members where team_id = $1)`,
    [teamId],
  );
}

async function userTeamId(client: PoolClient, gameId: string, userId: string): Promise<string | undefined> {
  const result = await client.query<{ teamId: string }>(
    'select team_id as "teamId" from cityquest.team_members where game_id = $1 and user_id = $2',
    [gameId, userId],
  );
  return result.rows[0]?.teamId;
}

export async function leaveActivity(userId: string, id: string): Promise<void> {
  await transaction(async (client) => {
    await lockActivity(client, id);
    const game = await activityGame(client, id);
    const teamId = game?.status === "lobby" ? await userTeamId(client, game.id, userId) : undefined;

    // The membership foreign key also removes the player from their game team.
    await client.query(
      "delete from cityquest.activity_participants where activity_id = $1 and user_id = $2",
      [id, userId],
    );
    if (teamId) await pruneTeam(client, teamId);
  });
}

export async function cancelActivity(userId: string, id: string): Promise<void> {
  await transaction(async (client) => {
    const activity = await lockActivity(client, id);
    if (activity.creatorId !== userId) throw new AppError("Only the host can cancel this activity.", 403);
    if (activity.cancelled) return;

    await client.query("update cityquest.activities set cancelled_at = now() where id = $1", [id]);
    await client.query("update cityquest.games set status = 'finished' where activity_id = $1", [id]);
  });
}

export async function getGame(gameId: string, userId: string): Promise<GameView> {
  const result = await database().query<GameView & { joined: boolean }>(
    `select g.id, a.id as "activityId", a.title, g.join_code as "joinCode", g.status,
       a.creator_id = $2 as "isHost", own_team.team_id as "teamId",
       exists (
         select 1 from cityquest.activity_participants p
         where p.activity_id = a.id and p.user_id = $2
       ) as joined,
       coalesce((
         select json_agg(team order by team.score desc, team.name, team.id) from (
           select t.id, t.name,
             coalesce((
               select json_agg(json_build_object('id', u.id, 'displayName', u.display_name)
                 order by m.joined_at, u.id)
               from cityquest.team_members m join cityquest.users u on u.id = m.user_id
               where m.team_id = t.id
             ), '[]'::json) as members,
             coalesce((
               select sum(c.points)::int from cityquest.challenge_completions cc
               join cityquest.challenges c on c.id = cc.challenge_id
               where cc.team_id = t.id
             ), 0) as score
           from cityquest.teams t where t.game_id = g.id
         ) team
       ), '[]'::json) as teams,
       coalesce((
         select json_agg(challenge order by challenge.id::int) from (
           select c.id::text as id, c.title, c.description, c.points, c.category,
             exists (
               select 1 from cityquest.challenge_completions cc
               where cc.team_id = own_team.team_id and cc.challenge_id = c.id
             ) as completed
           from cityquest.challenges c
         ) challenge
       ), '[]'::json) as challenges
     from cityquest.games g join cityquest.activities a on a.id = g.activity_id
     left join cityquest.team_members own_team on own_team.game_id = g.id and own_team.user_id = $2
     where g.id = $1`,
    [gameId, userId],
  );
  const row = result.rows[0];
  if (!row) throw new AppError("CityQuest game not found.", 404);
  const { joined, ...game } = row;
  if (!joined && !game.isHost) throw new AppError("Join the activity to open its game.", 403);
  return game;
}

async function lockGame(client: PoolClient, gameId: string) {
  const result = await client.query<{ activityId: string }>(
    'select activity_id as "activityId" from cityquest.games where id = $1',
    [gameId],
  );
  const game = result.rows[0];
  if (!game) throw new AppError("CityQuest game not found.", 404);

  const activity = await lockActivity(client, game.activityId);
  if (activity.cancelled) throw new AppError("This activity was cancelled.", 409);

  const lockedGame = await activityGame(client, activity.id);
  if (!lockedGame) throw new AppError("CityQuest game not found.", 404);
  return { activity, game: lockedGame };
}

async function lockLobby(client: PoolClient, gameId: string, userId: string): Promise<string> {
  const { activity, game } = await lockGame(client, gameId);
  const member = await client.query(
    "select 1 from cityquest.activity_participants where activity_id = $1 and user_id = $2",
    [activity.id, userId],
  );
  if (!member.rowCount) throw new AppError("Join the activity before choosing a team.", 403);
  if (game.status !== "lobby") throw new AppError("Teams can only be changed in the lobby.", 409);
  return activity.id;
}

async function moveToTeam(
  client: PoolClient,
  userId: string,
  gameId: string,
  activityId: string,
  teamId: string,
): Promise<void> {
  const previous = await userTeamId(client, gameId, userId);
  if (previous === teamId) return;

  await client.query(
    `insert into cityquest.team_members (game_id, activity_id, team_id, user_id)
     values ($1, $2, $3, $4)
     on conflict (game_id, user_id) do update set team_id = excluded.team_id, joined_at = now()`,
    [gameId, activityId, teamId, userId],
  );
  if (previous) await pruneTeam(client, previous);
}

export async function createTeam(userId: string, gameId: string, name: string): Promise<void> {
  await transaction(async (client) => {
    const activityId = await lockLobby(client, gameId, userId);
    const result = await client.query<{ id: string }>(
      `insert into cityquest.teams (game_id, name) values ($1, $2)
       on conflict (game_id, lower(name)) do nothing returning id`,
      [gameId, name],
    );
    const team = result.rows[0];
    if (!team) throw new AppError("A team already uses that name.", 409);
    await moveToTeam(client, userId, gameId, activityId, team.id);
  });
}

export async function joinTeam(userId: string, gameId: string, teamId: string): Promise<void> {
  await transaction(async (client) => {
    const activityId = await lockLobby(client, gameId, userId);
    const result = await client.query<{ count: number; joined: boolean }>(
      `select count(m.user_id)::int as count, coalesce(bool_or(m.user_id = $3), false) as joined
       from cityquest.teams t left join cityquest.team_members m on m.team_id = t.id
       where t.game_id = $1 and t.id = $2
       group by t.id`,
      [gameId, teamId, userId],
    );
    const team = result.rows[0];
    if (!team) throw new AppError("Team not found.", 404);
    if (team.joined) return;
    if (team.count >= teamCapacity) throw new AppError("This team is full.", 409);

    await moveToTeam(client, userId, gameId, activityId, teamId);
  });
}

export async function setGameStatus(
  userId: string,
  gameId: string,
  status: "active" | "finished",
): Promise<void> {
  await transaction(async (client) => {
    const { activity, game } = await lockGame(client, gameId);
    if (activity.creatorId !== userId) throw new AppError("Only the host can manage this game.", 403);
    if (game.status === status) return;

    if (status === "active") {
      if (game.status !== "lobby") throw new AppError("This game has already finished.", 409);
      const teams = await client.query(
        "select 1 from cityquest.team_members where game_id = $1 limit 1",
        [gameId],
      );
      if (!teams.rowCount) throw new AppError("Create a team before starting the game.", 409);
    } else if (game.status !== "active") {
      throw new AppError("Start the game before finishing it.", 409);
    }

    await client.query("update cityquest.games set status = $2 where id = $1", [gameId, status]);
  });
}

export async function completeChallenge(userId: string, gameId: string, challengeId: string): Promise<void> {
  await transaction(async (client) => {
    const { game } = await lockGame(client, gameId);
    const teamId = await userTeamId(client, gameId, userId);
    if (!teamId) throw new AppError("Join a team to complete challenges.", 403);
    if (game.status !== "active") throw new AppError("Challenges can only be completed during an active game.", 409);

    const challenge = await client.query<{ id: number }>(
      "select id from cityquest.challenges where id::text = $1",
      [challengeId],
    );
    if (!challenge.rows[0]) throw new AppError("Challenge not found.", 404);

    await client.query(
      `insert into cityquest.challenge_completions (team_id, challenge_id)
       values ($1, $2) on conflict (team_id, challenge_id) do nothing`,
      [teamId, challenge.rows[0].id],
    );
  });
}
