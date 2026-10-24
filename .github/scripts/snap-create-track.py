#!/usr/bin/env python3
"""Create a Snap Store version track with SNAPCRAFT_GATEWAY_CREDENTIALS.

`snapcraft` has no create-track command, so this calls the publisher gateway through
craft-store's PublisherGateway.create_tracks. The credential is a Candid macaroon for that
gateway, written by store-gateway-login.py and presented to the gateway as it is: nothing
is swapped for another token here. craft-store still owns the track call: name validation,
error parsing and the num-tracks-created check stay Canonical's code rather than a copy of it.

Usage: snap-create-track.py <snap-name> <track>
Exit:  0 = track created or already exists; 1 = failure, with a ::error:: explaining the cause.
"""

import base64
import json
import os
import sys
from datetime import datetime, timezone
from typing import NamedTuple

import httpx
from craft_store import errors
from craft_store.publisher import PublisherGateway
from pymacaroons import Macaroon

# The publisher gateway serves snaps as well as charms; it only lives on the charmhub host.
GATEWAY = "https://api.charmhub.io"
TIMEOUT_S = 60.0

ENV_VAR = "SNAPCRAFT_GATEWAY_CREDENTIALS"
RENEW = (
    "renew: run .github/scripts/store-gateway-login.py locally (tap the Candid link on your phone), "
    f"then `gh secret set {ENV_VAR} < gateway.creds`"
)
EXPIRY_CAVEAT = b"time-before "
NOT_VERIFIED = "credential not verified — not a credentials problem"


class TrackError(Exception):
    pass


class MacaroonAuth(httpx.Auth):
    """Gateway auth (`Macaroon <token>`); keeps the status craft-store's errors don't expose."""

    def __init__(self, token: str) -> None:
        self._token = token
        self.status: int | None = None

    def auth_flow(self, request):
        request.headers["Authorization"] = f"Macaroon {self._token}"
        response = yield request
        self.status = response.status_code


def error_messages(resp: httpx.Response) -> str:
    try:
        errors_list = resp.json().get("error-list") or []
        return "; ".join(str(e.get("message") or "?") for e in errors_list) or "no error-list"
    except (ValueError, AttributeError, TypeError):
        return "unparseable body"


class Credential(NamedTuple):
    token: str
    expires: datetime | None  # tz-aware UTC; None when the macaroon has no time-before caveat


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def load_credential(blob: str) -> Credential:
    """Decode the base64 `{"t": "macaroon", "v": <v2 macaroon>}` file store-gateway-login.py writes."""
    blob = blob.strip()
    if not blob:
        raise TrackError(f"{ENV_VAR} is empty or unset — cannot authenticate.")
    try:
        obj = json.loads(base64.b64decode(blob))
        if obj["t"] != "macaroon" or not isinstance(obj["v"], str):
            raise ValueError("not a gateway macaroon credential")
        token = obj["v"]
        expires = None
        for caveat in Macaroon.deserialize(token).caveats:
            # Raw bytes: third-party caveat ids are binary and would not decode.
            if caveat.caveat_id_bytes.startswith(EXPIRY_CAVEAT):
                expires = datetime.fromisoformat(caveat.caveat_id_bytes.removeprefix(EXPIRY_CAVEAT).decode())
                if expires.tzinfo is None:
                    expires = expires.replace(tzinfo=timezone.utc)
                expires = expires.astimezone(timezone.utc)
                break
    except Exception as exc:  # noqa: BLE001 — decode-only block: any failure means unreadable credentials
        # Type only: the message of a decode error can carry the decoded secret.
        raise TrackError(
            f"could not read {ENV_VAR} — expected the file written by store-gateway-login.py ({type(exc).__name__})."
        ) from None
    return Credential(token, expires)


def expiry_status(expires: datetime | None, now: datetime, warn_days: int = 30) -> tuple[str, str]:
    """Classify the credential's remaining life as ("ok" | "warning" | "error", message)."""
    if expires is None:
        return "warning", f"{ENV_VAR} has no time-before caveat; expiry unknown — {RENEW}"
    date = expires.date().isoformat()
    if expires <= now:
        return "error", f"{ENV_VAR} expired on {date} — {RENEW}"
    days = (expires - now).days  # whole days, floored
    message = f"{ENV_VAR} expires in {days} days ({date})"
    if days < warn_days:
        return "warning", f"{message} — {RENEW}"
    return "ok", message


def create_track(snap: str, track: str, creds: str) -> None:
    auth = MacaroonAuth(load_credential(creds).token)
    gateway = PublisherGateway(GATEWAY, "snap", auth)
    try:
        created = gateway.create_tracks(snap, {"name": track})
    except httpx.HTTPError as exc:
        raise TrackError(f"create-track {snap}/{track}: store unreachable ({type(exc).__name__}).") from None
    # TypeError/AttributeError: craft-store's error parser chokes on an odd error-list shape.
    except (errors.CraftStoreError, TypeError, AttributeError) as exc:
        if auth.status == 409:
            print(f"Track {track} already exists.")
            return
        detail = exc if isinstance(exc, errors.CraftStoreError) else f"HTTP {auth.status}, unparseable error body"
        hint = ""
        if auth.status in (401, 403):
            hint = " The credentials can't manage this snap's tracks, or the name misses its track-creation guardrails."
        raise TrackError(f"create-track {snap}/{track} failed: {detail}{hint}") from None
    if created < 1:
        raise TrackError(f"create-track {snap}/{track} returned success but created no track.")
    print(f"Track {track} created (num-tracks-created={created}).")


def annotate(level: str, message: str) -> None:
    """Print one GitHub workflow command; it ends at the first newline, so escape %, CR and LF."""
    message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{level}::{message}", file=sys.stderr)


def whoami(token: str) -> tuple[str, str]:
    """Ask the gateway whose credential this is: ("ok" | "warning" | "error", message)."""
    try:
        with httpx.Client(timeout=TIMEOUT_S) as client:
            resp = client.get(f"{GATEWAY}/v1/tokens/whoami", auth=MacaroonAuth(token))
    except httpx.HTTPError as exc:
        return "warning", f"gateway whoami failed ({type(exc).__name__}); {NOT_VERIFIED}"
    status = resp.status_code
    if status == 200:
        try:
            username = resp.json()["account"]["username"]
        except (ValueError, KeyError, TypeError):
            username = "?"
        return "ok", f"gateway accepts the credential (account {username})"
    detail = f"HTTP {status}: {error_messages(resp)}"
    if status in (401, 403):
        return "error", f"gateway rejected {ENV_VAR} ({detail}) — {RENEW}"
    return "warning", f"gateway whoami failed ({detail}); {NOT_VERIFIED}"


def report(level: str, message: str) -> None:
    if level == "ok":
        print(message, flush=True)  # flushed so it can't trail a later annotation on the unbuffered stderr
    else:
        annotate(level, message)


def check(creds: str) -> int:
    """Credential health for CI: expiry, then whoami. Annotations only, so it always returns 0."""
    if not creds.strip():
        annotate("warning", f"{ENV_VAR} is not set in this context; skipping the gateway credential check")
        return 0
    try:
        credential = load_credential(creds)
    except TrackError as exc:
        annotate("error", str(exc))
        return 0
    report(*expiry_status(credential.expires, utcnow()))  # before the request, so a slow gateway can't hide it
    report(*whoami(credential.token))
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--check"]:
        return check(os.environ.get(ENV_VAR, ""))
    if len(argv) != 3:
        print("usage: snap-create-track.py <snap-name> <track> | --check", file=sys.stderr)
        return 1
    snap, track = argv[1], argv[2]
    creds = os.environ.get(ENV_VAR, "")
    try:
        create_track(snap, track, creds)
    except TrackError as exc:
        annotate("error", str(exc))  # craft-store messages can span several lines
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
