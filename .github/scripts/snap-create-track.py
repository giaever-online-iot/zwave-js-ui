#!/usr/bin/env python3
"""Create a Snap Store version track with SNAPCRAFT_STORE_CREDENTIALS.

`snapcraft` has no create-track command, so this calls the publisher gateway through
craft-store's PublisherGateway.create_tracks. The `snapcraft export-login` blob holds
dashboard macaroons, which the gateway only accepts after an exchange at
/v1/tokens/dashboard/exchange: the flow snapcraft.io runs behind its "create track"
button. craft-store's UbuntuOneAuth exchanges at /v1/tokens/usso/exchange instead,
which is meant for craft-store's own Ubuntu One logins, hence the exchange here.

Usage: snap-create-track.py <snap-name> <track>
Exit:  0 = track created or already exists; 1 = failure, with a ::error:: explaining the cause.
"""

import base64
import json
import os
import sys

import httpx
from craft_store import errors
from craft_store.publisher import PublisherGateway
from pymacaroons import Macaroon
from pymacaroons.exceptions import MacaroonException

# The publisher gateway serves snaps as well as charms; it only lives on the charmhub host.
GATEWAY = "https://api.charmhub.io"
TIMEOUT_S = 60.0


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
        return "; ".join(e.get("message", "?") for e in resp.json().get("error-list", []))
    except (ValueError, AttributeError):
        return "unparseable body"


def exchange_header(creds: str) -> str:
    """Authorization value for the exchange: the root macaroon plus its bound discharge."""
    try:
        macaroons = json.loads(base64.b64decode(creds))["v"]  # {"t": "u1-macaroon", "v": {"r", "d"}}
        root, discharge = macaroons["r"], macaroons["d"]
        bound = Macaroon.deserialize(root).prepare_for_request(Macaroon.deserialize(discharge))
    except (ValueError, KeyError, TypeError, MacaroonException) as exc:
        # Type only: the message of a decode error can carry the decoded secret.
        raise TrackError(
            "could not read SNAPCRAFT_STORE_CREDENTIALS — expected the output of "
            f"`snapcraft export-login` ({type(exc).__name__})."
        ) from None
    return f"macaroon root={root}, discharge={bound.serialize()}"


def exchange(creds: str) -> str:
    try:
        with httpx.Client(timeout=TIMEOUT_S) as client:
            resp = client.post(
                f"{GATEWAY}/v1/tokens/dashboard/exchange",
                headers={"Authorization": exchange_header(creds)},
                json={},
            )
        token = resp.json().get("macaroon") if resp.is_success else None
    except httpx.HTTPError as exc:
        raise TrackError(f"token exchange: store unreachable ({type(exc).__name__}).") from None
    except (ValueError, AttributeError):
        raise TrackError(f"token exchange: unparseable response (HTTP {resp.status_code}).") from None
    if not token:
        raise TrackError(
            f"token exchange failed (HTTP {resp.status_code}: {error_messages(resp)}) — "
            "SNAPCRAFT_STORE_CREDENTIALS is invalid or expired; refresh it with `snapcraft export-login`."
        )
    print(f"::add-mask::{token}")
    return token


def create_track(snap: str, track: str, creds: str) -> None:
    auth = MacaroonAuth(exchange(creds))
    gateway = PublisherGateway(GATEWAY, "snap", auth)
    try:
        created = gateway.create_tracks(snap, {"name": track})
    except httpx.HTTPError as exc:
        raise TrackError(f"create-track {snap}/{track}: store unreachable ({type(exc).__name__}).") from None
    except errors.CraftStoreError as exc:
        if auth.status == 409:
            print(f"Track {track} already exists.")
            return
        hint = ""
        if auth.status in (401, 403):
            hint = " The credentials can't manage this snap's tracks, or the name misses its track-creation guardrails."
        raise TrackError(f"create-track {snap}/{track} failed: {exc}{hint}") from None
    if created < 1:
        raise TrackError(f"create-track {snap}/{track} returned success but created no track.")
    print(f"Track {track} created (num-tracks-created={created}).")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: snap-create-track.py <snap-name> <track>", file=sys.stderr)
        return 1
    snap, track = argv[1], argv[2]
    creds = os.environ.get("SNAPCRAFT_STORE_CREDENTIALS", "")
    try:
        if not creds.strip():
            raise TrackError(
                f"SNAPCRAFT_STORE_CREDENTIALS is empty or unset — cannot authenticate to create track {track}."
            )
        create_track(snap, track, creds)
    except TrackError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
