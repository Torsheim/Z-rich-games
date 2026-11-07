import { createHash, randomBytes } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import * as db from "@/lib/db";
import { AppError } from "@/lib/errors";
import { hashPassword, verifyPassword } from "@/lib/password";
import { categories, type Category, type CreateActivityInput, type SessionUser } from "@/lib/types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const guestCookie = "cityquest_session";
const accountCookie = "cityquest_account";
const guestSessionAge = 60 * 60 * 24 * 365;
const accountSessionAge = 60 * 60 * 24 * 30;
const tokenPattern = /^[A-Za-z0-9_-]{43}$/;
const uuidPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const isoDatePattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;

function digest(token: string) {
  return createHash("sha256").update(token).digest("hex");
}

function sessionDigest(request: NextRequest, name: string) {
  const token = request.cookies.get(name)?.value;
  return token && tokenPattern.test(token) ? digest(token) : null;
}

function guestUser(request: NextRequest) {
  const token = sessionDigest(request, guestCookie);
  return token ? db.getSession(token) : null;
}

async function currentUser(request: NextRequest): Promise<SessionUser | null> {
  const token = sessionDigest(request, accountCookie);
  const account = token ? await db.getAccountSession(token) : null;
  return account ?? guestUser(request);
}

function setSessionCookie(response: NextResponse, request: NextRequest, name: string, token: string, maxAge: number) {
  response.cookies.set(name, token, {
    httpOnly: true,
    secure: process.env.VERCEL === "1" || request.nextUrl.protocol === "https:"
      || request.headers.get("x-forwarded-proto") === "https",
    sameSite: "lax",
    path: "/",
    maxAge,
  });
}

function json(data: unknown, status = 200) {
  return NextResponse.json(data, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function errorResponse(error: unknown) {
  if (error instanceof AppError) {
    return json({ error: error.message }, error.status);
  }
  const code = error instanceof Error && "code" in error ? error.code : undefined;
  console.error("CityQuest API request failed", error instanceof Error ? error.name : "Unknown error", code);
  return json({ error: "CityQuest is temporarily unavailable. Try again in a moment." }, 500);
}

function field(value: unknown, label: string, limit: number, required = true) {
  if (typeof value !== "string") {
    if (!required && value == null) return "";
    throw new AppError(`${label} is required.`, 400);
  }
  const clean = value.trim();
  if (required && !clean) throw new AppError(`${label} is required.`, 400);
  if (clean.includes("\0")) throw new AppError(`Invalid ${label.toLowerCase()}.`, 400);
  if (clean.length > limit) {
    throw new AppError(`${label} must be ${limit} characters or fewer.`, 400);
  }
  return clean;
}

function usernameField(value: unknown) {
  const username = field(value, "Username", 24);
  if (!/^[A-Za-z0-9_]{3,24}$/.test(username)) {
    throw new AppError("Use 3–24 letters, numbers or underscores for your username.", 400);
  }
  return username.toLowerCase();
}

function passwordField(value: unknown, registering: boolean) {
  const password = typeof value === "string" && value.length <= 512 && value.isWellFormed()
    ? value.normalize("NFC")
    : "";
  const length = Array.from(password).length;
  if (length < (registering ? 15 : 1) || length > 128) {
    if (!registering) throw new AppError("Incorrect username or password.", 401);
    throw new AppError("Choose a password between 15 and 128 characters.", 400);
  }
  return password;
}

function profileFields(body: Record<string, unknown>) {
  return {
    displayName: field(body.displayName, "Display name", 32),
    bio: field(body.bio, "Bio", 280, false),
  };
}

async function checkAuthLimit(request: NextRequest, action: "login" | "register", username: string) {
  const ip = process.env.VERCEL
    ? request.headers.get("x-vercel-forwarded-for") ?? request.headers.get("x-forwarded-for") ?? "unknown"
    : "local";
  const ipAllowed = await db.consumeAuthAttempt(digest(`${action}:ip:${ip}`), action === "login" ? 60 : 30);
  const userAllowed = ipAllowed && (action !== "login"
    || await db.consumeAuthAttempt(digest(`login:username:${username}`), 12));
  if (!userAllowed) throw new AppError("Too many attempts. Try again in 15 minutes.", 429);
}

async function signIn(request: NextRequest, body: Record<string, unknown>, user: SessionUser | null) {
  if (user?.username) throw new AppError("Log out before signing in to another profile.", 409);

  const registering = body.action === "register";
  const username = usernameField(body.username);
  const password = passwordField(body.password, registering);
  await checkAuthLimit(request, registering ? "register" : "login", username);
  const token = randomBytes(32).toString("base64url");
  const tokenDigest = digest(token);

  if (registering) {
    const fields = profileFields(body);
    const guestToken = sessionDigest(request, guestCookie);
    const guest = user && guestToken ? { id: user.id, tokenDigest: guestToken } : undefined;
    const profile = await db.registerProfile({ ...fields, username, passwordHash: await hashPassword(password) }, tokenDigest, guest);
    const response = json({ user: profile }, 201);
    setSessionCookie(response, request, accountCookie, token, accountSessionAge);
    if (guest) setSessionCookie(response, request, guestCookie, "", 0);
    return response;
  }

  const credentials = await db.profileCredentials(username);
  const valid = await verifyPassword(password, credentials?.passwordHash);
  if (!credentials || !valid) throw new AppError("Incorrect username or password.", 401);
  const response = json({ user: await db.createAccountSession(credentials.id, tokenDigest) });
  setSessionCookie(response, request, accountCookie, token, accountSessionAge);
  return response;
}

function uuid(value: unknown, label: string) {
  if (typeof value !== "string" || !uuidPattern.test(value)) {
    throw new AppError(`Invalid ${label}.`, 400);
  }
  return value;
}

function activityInput(body: Record<string, unknown>): CreateActivityInput {
  const { category, maxParticipants } = body;
  if (typeof category !== "string" || !Object.hasOwn(categories, category)) {
    throw new AppError("Choose an activity category.", 400);
  }
  const startsAt = field(body.startsAt, "Date and time", 32);
  const startTime = Date.parse(startsAt);
  const canonicalDate = startsAt.includes(".") ? startsAt : startsAt.replace("Z", ".000Z");
  if (!isoDatePattern.test(startsAt) || !(startTime > Date.now())
      || new Date(startTime).toISOString() !== canonicalDate) {
    throw new AppError("Choose a date and time in the future.", 400);
  }
  if (typeof maxParticipants !== "number" || !Number.isInteger(maxParticipants)
      || maxParticipants < 2 || maxParticipants > 100) {
    throw new AppError("Choose a capacity between 2 and 100.", 400);
  }
  return {
    title: field(body.title, "Title", 80),
    category: category as Category,
    description: field(body.description, "Description", 500, false),
    location: field(body.location, "Meeting place", 120),
    startsAt,
    maxParticipants,
  };
}

async function readBody(request: NextRequest): Promise<Record<string, unknown>> {
  const origin = request.headers.get("origin");
  const host = request.headers.get("host") ?? request.nextUrl.host;
  if (request.headers.get("sec-fetch-site") === "cross-site" ||
      (origin && origin !== `https://${host}` && origin !== `http://${host}`)) {
    throw new AppError("This request must come from CityQuest.", 403);
  }
  const mediaType = request.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
  if (mediaType !== "application/json") {
    throw new AppError("Send an application/json request.", 415);
  }
  const body = await request.json().catch(() => null);
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new AppError("Invalid request.", 400);
  }
  return body;
}

export async function GET(request: NextRequest) {
  try {
    const { searchParams } = request.nextUrl;
    if (searchParams.has("profileId")) {
      const id = uuid(searchParams.get("profileId"), "profile");
      return json({ profile: await db.getPublicProfile(id) });
    }
    const user = await currentUser(request);
    if (searchParams.has("activityId")) {
      const id = uuid(searchParams.get("activityId"), "activity");
      return json({ activity: await db.getActivity(id, user?.id ?? null) });
    }
    if (searchParams.has("gameId")) {
      if (!user) throw new AppError("Choose a display name to enter the game.", 401);
      const id = uuid(searchParams.get("gameId"), "game");
      return json({ game: await db.getGame(id, user.id) });
    }
    return json({ user, ...await db.listActivities(user?.id ?? null) });
  } catch (error) {
    return errorResponse(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await readBody(request);
    const user = await currentUser(request);
    if (body.action === "register" || body.action === "login") return await signIn(request, body, user);
    if (body.action === "logout") {
      const token = sessionDigest(request, accountCookie);
      if (token) await db.revokeAccountSession(token);
      const response = json({ user: await guestUser(request) });
      setSessionCookie(response, request, accountCookie, "", 0);
      return response;
    }
    if (body.action === "updateProfile") {
      if (!user?.username) throw new AppError("Log in to edit your profile.", 401);
      return json({ user: await db.updateProfile(user.id, profileFields(body)) });
    }
    if (body.action === "identify") {
      if (user) return json({ user });
      const displayName = field(body.displayName, "Display name", 32);
      const token = randomBytes(32).toString("base64url");
      const response = json({ user: await db.createSession(displayName, digest(token)) }, 201);
      setSessionCookie(response, request, guestCookie, token, guestSessionAge);
      return response;
    }
    if (!user) throw new AppError("Choose a display name first.", 401);
    const userId = user.id;

    switch (body.action) {
      case "createActivity":
        return json({ activityId: await db.createActivity(userId, activityInput(body)) }, 201);
      case "joinActivity":
        await db.joinActivity(userId, uuid(body.activityId, "activity"));
        break;
      case "leaveActivity":
        await db.leaveActivity(userId, uuid(body.activityId, "activity"));
        break;
      case "cancelActivity":
        await db.cancelActivity(userId, uuid(body.activityId, "activity"));
        break;
      case "joinByCode": {
        const code = field(body.code, "Game code", 12).toUpperCase();
        if (!/^[A-Z0-9]{6}$/.test(code)) throw new AppError("Enter a six-character game code.", 400);
        return json({ activityId: await db.joinByCode(userId, code) });
      }
      case "createTeam":
        await db.createTeam(userId, uuid(body.gameId, "game"), field(body.name, "Team name", 32));
        break;
      case "joinTeam":
        await db.joinTeam(userId, uuid(body.gameId, "game"), uuid(body.teamId, "team"));
        break;
      case "setGameStatus": {
        const { status } = body;
        if (status !== "active" && status !== "finished") throw new AppError("Invalid game status.", 400);
        await db.setGameStatus(userId, uuid(body.gameId, "game"), status);
        break;
      }
      case "completeChallenge": {
        const challengeId = field(body.challengeId, "Challenge", 6);
        if (!/^[1-9]\d*$/.test(challengeId)) throw new AppError("Invalid challenge.", 400);
        await db.completeChallenge(userId, uuid(body.gameId, "game"), challengeId);
        break;
      }
      default:
        throw new AppError("Unknown action.", 400);
    }
    return json({ ok: true });
  } catch (error) {
    return errorResponse(error);
  }
}
