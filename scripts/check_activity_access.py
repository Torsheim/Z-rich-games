#!/usr/bin/env python3
"""Exercise the activity RPCs over HTTP in a disposable local database."""

import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import Barrier
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
from uuid import UUID, uuid4


ACTIVITY_FIELDS = {
    "id", "organizer_id", "organizer_name", "category_id", "category_name",
    "city_id", "city_name", "title", "description", "cover_image_url", "status",
    "visibility", "join_policy", "max_participants", "starts_at", "ends_at",
    "timezone", "place_name", "address", "latitude", "longitude",
    "cancelled_at", "cancellation_reason", "available_places",
}

PUBLIC_SUMMARY_FIELDS = {
    "id", "title", "organizer_id", "organizer_name", "city_id", "city_name",
    "category_id", "category_name", "starts_at", "ends_at", "timezone",
    "place_name", "cover_image_url", "join_policy",
}


class SmokeError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


http = build_opener(ProxyHandler({}), NoRedirect())


def check(condition, message):
    if not condition:
        raise SmokeError(message)


def required(name):
    value = os.environ.get(name)
    check(value, f"Set {name} for the local test.")
    return value


def local_url(value, name):
    try:
        url = urlsplit(value)
        valid = (
            url.scheme in ("http", "https")
            and url.hostname in ("127.0.0.1", "::1", "localhost")
            and (url.port is None or url.port > 0)
            and url.username is None
            and url.password is None
            and not url.query
            and not url.fragment
        )
    except ValueError:
        valid = False
    check(valid, f"{name} must be an HTTP(S) loopback URL.")
    return url.geturl().rstrip("/")


def post_json(url, body, key, label, token=None, expected=200):
    check(re.fullmatch(r"[!-~]+", key), "The local API key must be a single HTTP token.")
    headers = {"apikey": key, "Content-Type": "application/json"}
    if token:
        check(re.fullmatch(r"[!-~]+", token), f"{label} requires a single HTTP access token.")
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, data=json.dumps(body).encode(), headers=headers)
    try:
        response = http.open(request, timeout=10)
    except HTTPError as error:
        response = error
    except (URLError, OSError) as error:
        raise SmokeError(f"{label} could not reach the local server.") from error

    with response:
        status = response.status
        try:
            data = json.load(response)
        except (ValueError, UnicodeError) as error:
            raise SmokeError(f"{label} returned HTTP {status} without valid JSON.") from error

    statuses = (expected,) if isinstance(expected, int) else expected
    if status not in statuses:
        code = data.get("code") if isinstance(data, dict) else None
        suffix = f" ({code})" if isinstance(code, str) and re.fullmatch(r"\w{1,16}", code) else ""
        expected_status = " or ".join(str(value) for value in statuses)
        raise SmokeError(f"{label} returned HTTP {status}{suffix}. Expected HTTP {expected_status}.")
    return data


def access_token(role, base_url, key):
    token = os.environ.get(f"{role}_ACCESS_TOKEN")
    if token:
        return token
    credentials = {
        "email": required(f"{role}_EMAIL"),
        "password": required(f"{role}_PASSWORD"),
    }
    data = post_json(f"{base_url}/auth/v1/token?grant_type=password", credentials, key, f"{role} sign-in")
    token = data.get("access_token") if isinstance(data, dict) else None
    check(isinstance(token, str) and token, f"{role} sign-in returned no access token.")
    return token


def fixture_id(name):
    try:
        return str(UUID(required(name)))
    except ValueError as error:
        raise SmokeError(f"{name} must be a UUID.") from error


def activity_row(data, activity_id, state, label):
    check(isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict),
          f"{label} must return exactly one activity.")
    activity = data[0]
    check(set(activity) == ACTIVITY_FIELDS, f"{label} returned an unexpected activity field set.")
    check(activity["id"] == activity_id, f"{label} returned a different activity UUID.")
    actual = (activity["status"], activity["visibility"], activity["join_policy"])
    check(actual == state, f"{label} returned the wrong status, visibility, or join policy.")
    return activity


def check_hidden_from_listing(data, activity_id, state):
    check(isinstance(data, list) and len(data) <= 1
          and all(isinstance(row, dict) and row.get("id") != activity_id for row in data),
          f"Anonymous listing must hide the {state} activity and respect the page limit.")


def run():
    base_url = local_url(required("SUPABASE_URL"), "SUPABASE_URL")
    rpc_url = local_url(os.environ.get("SUPABASE_RPC_URL") or f"{base_url}/rest/v1", "SUPABASE_RPC_URL")
    key = os.environ.get("SUPABASE_PUBLISHABLE_KEY") or required("SUPABASE_ANON_KEY")
    owner = access_token("OWNER", base_url, key)
    outsider = access_token("OUTSIDER", base_url, key)
    check(owner != outsider, "Use separate sessions for the owner and unrelated user.")

    def rpc(name, body, label, token=None, expected=200):
        return post_json(f"{rpc_url}/rpc/{name}", body, key, label, token, expected)

    title = f"Activity access smoke {uuid4().hex[:8]}"
    activity_id = rpc("create_activity_draft", {
        "p_organizer_id": fixture_id("FIXTURE_ORGANIZER_ID"),
        "p_category_id": fixture_id("FIXTURE_CATEGORY_ID"),
        "p_city_id": fixture_id("FIXTURE_CITY_ID"),
        "p_title": title,
        "p_description": "Meet at the front desk.",
        "p_starts_at": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(),
        "p_timezone": "Europe/Zurich",
        "p_place_name": "Bowling center",
        "p_max_participants": 1,
    }, "Owner draft creation", owner)
    try:
        check(isinstance(activity_id, str), "Draft creation must return a scalar UUID.")
        draft_uuid = UUID(activity_id)
    except ValueError as error:
        raise SmokeError("Draft creation must return a scalar UUID.") from error
    activity_args = {"p_activity_id": activity_id}
    missing_args = {"p_activity_id": str(uuid4())}

    draft = activity_row(rpc("get_activity", activity_args, "Owner draft lookup", owner),
                         activity_id, ("draft", "invite_only", "invitation_required"), "Owner draft lookup")
    check(draft["title"] == title, "Owner draft lookup returned the wrong title.")
    check(draft["max_participants"] == 1, "The signup fixture must have one place.")
    check(draft["available_places"] is None, "A draft must have no public availability.")
    check(draft["cancelled_at"] is None and draft["cancellation_reason"] is None,
          "The draft must have no cancellation metadata.")

    title = f"{title} edited"
    draft_edit = {**activity_args, "p_changes": {"title": title}}
    check(rpc("update_activity", draft_edit, "Owner draft edit", owner) == activity_id,
          "Draft editing must preserve the activity UUID.")
    draft = {**draft, "title": title}
    check(rpc("get_activity", activity_args, "Owner edited draft lookup", owner) == [draft],
          "The edited draft must show the new title and preserve the other fields.")

    # The previous UUID at the exact timestamp puts this activity first if visible.
    listing_args = {
        "p_city_id": draft["city_id"],
        "p_category_id": draft["category_id"],
        "p_limit": 1,
        "p_after_starts_at": draft["starts_at"],
        "p_after_activity_id": str(UUID(int=draft_uuid.int - 1)),
    }
    draft_listing = rpc("list_public_activities", listing_args, "Anonymous listing before publication")
    check_hidden_from_listing(draft_listing, activity_id, "draft")

    for label, token in (("Anonymous", None), ("Unrelated user", outsider)):
        hidden = rpc("get_activity", activity_args, f"{label} draft lookup", token)
        missing = rpc("get_activity", missing_args, f"{label} missing activity lookup", token)
        check(hidden == missing == [], f"{label} must receive the same empty array for hidden and missing rows.")
    check(rpc("get_activity", missing_args, "Owner missing activity lookup", owner) == [],
          "Owner lookup of a missing activity must return an empty array.")

    denied = rpc("publish_activity", activity_args, "Unrelated user publication", outsider, expected=403)
    check(isinstance(denied, dict) and denied.get("code") == "42501",
          "Unrelated user publication must fail with SQLSTATE 42501.")
    check(rpc("get_activity", activity_args, "Owner lookup after denied publication", owner) == [draft],
          "Denied publication must leave the original draft unchanged.")
    published_id = rpc("publish_activity", activity_args, "Owner publication", owner)
    check(published_id == activity_id, "Publication must preserve the activity UUID.")

    public = activity_row(rpc("get_activity", activity_args, "Anonymous public lookup"),
                          activity_id, ("active", "public", "instant"), "Anonymous public lookup")
    check(public["title"] == title, "Anonymous lookup returned the wrong title.")
    check(type(public["available_places"]) is int and public["available_places"] == 1,
          "The published activity must start with one available place.")
    check(public["cancelled_at"] is None and public["cancellation_reason"] is None,
          "The published activity must have no cancellation metadata.")
    check(rpc("get_activity", activity_args, "Unrelated user public lookup", outsider) == [public],
          "The unrelated user must see the same public activity as an anonymous visitor.")

    place_name = "Bowling center court entrance"
    active_edit = {**activity_args, "p_changes": {"place_name": place_name}}
    reason = "Venue closed."
    cancel_args = {**activity_args, "p_reason": reason}
    for operation, body, label in (
        ("update_activity", active_edit, "Unrelated user active edit"),
        ("cancel_activity", cancel_args, "Unrelated user cancellation"),
    ):
        denied = rpc(operation, body, label, outsider, expected=403)
        check(isinstance(denied, dict) and denied.get("code") == "42501",
              f"{label} must fail with SQLSTATE 42501.")
    check(rpc("get_activity", activity_args, "Anonymous lookup after denied changes") == [public],
          "Denied edit and cancellation must leave the published activity unchanged.")

    check(rpc("update_activity", active_edit, "Owner active edit", owner) == activity_id,
          "Active editing must preserve the activity UUID.")
    public = {**public, "place_name": place_name}
    check(rpc("get_activity", activity_args, "Anonymous edited activity lookup") == [public],
          "The edited public activity must show the new place and preserve the other fields.")
    summary = {field: public[field] for field in PUBLIC_SUMMARY_FIELDS}
    listing = rpc("list_public_activities", listing_args, "Anonymous listing after edit")
    check(listing == [summary], "Anonymous listing must return exactly the edited activity's public summary.")

    for operation, label in (
        ("join_activity", "Anonymous signup"),
        ("leave_activity", "Anonymous withdrawal"),
        ("get_my_activity_participation", "Anonymous participation lookup"),
    ):
        denied = rpc(operation, activity_args, label, expected=401)
        check(isinstance(denied, dict) and denied.get("code") == "42501",
              f"{label} must fail with SQLSTATE 42501.")

    def check_participation(label, places, owner_status, outsider_status):
        detail = rpc("get_activity", activity_args, f"{label} public lookup")
        check(detail == [{**public, "available_places": places}]
              and type(detail[0]["available_places"]) is int,
              f"{label} must show {places} available places without changing other public fields.")
        for role, token, status in (("owner", owner, owner_status), ("unrelated user", outsider, outsider_status)):
            actual = rpc("get_my_activity_participation", activity_args, f"{label} {role} status", token)
            check(actual == status, f"{label} returned the wrong participation status for the {role}.")

    check(rpc("join_activity", activity_args, "Unrelated user signup", outsider) == activity_id,
          "Signup must return the activity UUID.")
    check_participation("After signup", 0, None, "confirmed")
    check(rpc("join_activity", activity_args, "Unrelated user signup retry", outsider) == activity_id,
          "An existing participant must be able to retry signup for a full activity.")
    full = rpc("join_activity", activity_args, "Owner signup after capacity reached", owner, expected=409)
    check(isinstance(full, dict) and (full.get("code"), full.get("details")) == ("PT409", "activity_full"),
          "A second user must receive the activity_full conflict.")

    check(rpc("leave_activity", activity_args, "Unrelated user withdrawal", outsider) == activity_id,
          "Withdrawal must return the activity UUID.")
    check_participation("After withdrawal", 1, None, "cancelled")
    check(rpc("leave_activity", activity_args, "Unrelated user withdrawal retry", outsider) == activity_id,
          "Repeated withdrawal must return the same activity UUID.")
    check_participation("After repeated withdrawal", 1, None, "cancelled")
    check(rpc("join_activity", activity_args, "Owner signup after withdrawal", owner) == activity_id,
          "The user who was previously denied must be able to take the freed place.")
    check_participation("After booking the freed place", 0, "confirmed", "cancelled")

    check(rpc("leave_activity", activity_args, "Owner withdrawal for concurrency check", owner) == activity_id,
          "The owner must be able to free the place for the concurrency check.")
    check(rpc("join_activity", activity_args, "Unrelated user rebooking for concurrency check", outsider) == activity_id,
          "The previous participant must be able to rebook the place.")
    start = Barrier(2, timeout=5)

    def race(operation, label, token, expected=200):
        start.wait()
        return rpc(operation, activity_args, label, token, expected)

    with ThreadPoolExecutor(max_workers=2) as workers:
        leaving = workers.submit(race, "leave_activity", "Concurrent withdrawal", outsider)
        joining = workers.submit(race, "join_activity", "Concurrent signup", owner, (200, 409))
        check(leaving.result() == activity_id, "Concurrent withdrawal must return the activity UUID.")
        joined = joining.result()
    if joined != activity_id:
        check(isinstance(joined, dict) and (joined.get("code"), joined.get("details")) == ("PT409", "activity_full"),
              "A signup that reaches the full activity before withdrawal must receive activity_full.")
        check(rpc("join_activity", activity_args, "Signup retry after concurrent withdrawal", owner) == activity_id,
              "Signup must succeed on retry after concurrent withdrawal.")
    check_participation("After concurrent withdrawal and signup", 0, "confirmed", "cancelled")

    check(rpc("cancel_activity", cancel_args, "Owner cancellation", owner) == activity_id,
          "Cancellation must preserve the activity UUID.")
    cancelled = activity_row(rpc("get_activity", activity_args, "Anonymous cancelled activity lookup"),
                             activity_id, ("cancelled", "public", "instant"), "Anonymous cancelled activity lookup")
    cancelled_at = cancelled["cancelled_at"]
    check(isinstance(cancelled_at, str) and cancelled_at, "Cancellation must set a timestamp.")
    check(cancelled == {**public, "status": "cancelled", "available_places": None, "cancelled_at": cancelled_at,
                        "cancellation_reason": reason},
          "Cancelled activity lookup must retain public details and include the cancellation reason.")
    check(rpc("cancel_activity", cancel_args, "Owner repeated cancellation", owner) == activity_id,
          "Repeated cancellation must return the same activity UUID.")
    check(rpc("get_activity", activity_args, "Anonymous lookup after repeated cancellation") == [cancelled],
          "Repeated cancellation must preserve the timestamp and details.")
    cancelled_listing = rpc("list_public_activities", listing_args, "Anonymous listing after cancellation")
    check_hidden_from_listing(cancelled_listing, activity_id, "cancelled")
    closed = rpc("join_activity", activity_args, "Unrelated user signup after cancellation", outsider, expected=409)
    check(isinstance(closed, dict) and (closed.get("code"), closed.get("details")) == ("PT409", "activity_closed"),
          "Signup for a cancelled public activity must receive the activity_closed conflict.")
    print("Activity access smoke passed.")


if __name__ == "__main__":
    try:
        run()
    except SmokeError as error:
        sys.exit(f"Activity access smoke failed. {error}")
