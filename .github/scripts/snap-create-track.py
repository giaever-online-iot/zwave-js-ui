#!/usr/bin/env python3
"""Create a Snap Store version track with SNAPCRAFT_STORE_CREDENTIALS.

`snapcraft` has no create-track command, so this calls the publisher gateway through
craft-store's PublisherGateway.create_tracks. The `snapcraft export-login` blob holds
dashboard macaroons, which the gateway only accepts after an exchange at
/v1/tokens/dashboard/exchange: the flow snapcraft.io runs behind its "create track"
button. craft-store's UbuntuOneAuth exchanges at /v1/tokens/usso/exchange instead,
which is meant for craft-store's own Ubuntu One logins, hence the exchange here.

Usage: snap-create-track.py <snap-name> <track>
Exit:  0 = track created; 1 = failure, with a ::error:: explaining the cause.
"""

import base64
import json
import os
import sys

import httpx
from craft_store import errors
from craft_store.publisher import PublisherGateway
from pymacaroons import Macaroon

GATEWAY = "https://api.charmhub.io"


class MacaroonAuth(httpx.Auth):
    def __init__(self, token: str) -> None:
        self._token = token

    def auth_flow(self, request):
        request.headers["Authorization"] = f"Macaroon {self._token}"
        yield request


class Failure(Exception):
    pass


def dashboard_authorization(creds: str) -> str:
    try:
        v = json.loads(base64.b64decode(creds))["v"]
        bound = Macaroon.deserialize(v["r"]).prepare_for_request(
            Macaroon.deserialize(v["d"])
        )
    except Exception as exc:
        raise Failure(
            "could not read SNAPCRAFT_STORE_CREDENTIALS — expected the output of "
            f"`snapcraft export-login` ({exc!r})."
        ) from exc
    return f"macaroon root={v['r']}, discharge={bound.serialize()}"


def exchange(creds: str) -> str:
    with httpx.Client(timeout=60.0) as client:
        resp = client.post(
            f"{GATEWAY}/v1/tokens/dashboard/exchange",
            headers={"Authorization": dashboard_authorization(creds)},
            json={},
        )
    token = resp.json().get("macaroon") if resp.is_success else None
    if not token:
        raise Failure(
            f"token exchange failed (HTTP {resp.status_code}) — SNAPCRAFT_STORE_CREDENTIALS "
            f"is invalid or expired; refresh it with `snapcraft export-login` (body: {resp.text})."
        )
    return token


def create_track(snap: str, track: str, creds: str) -> None:
    if not creds.strip():
        raise Failure(
            f"SNAPCRAFT_STORE_CREDENTIALS is empty or unset — cannot authenticate to create track {track}."
        )
    gateway = PublisherGateway(GATEWAY, "snap", MacaroonAuth(exchange(creds)))
    try:
        created = gateway.create_tracks(snap, {"name": track})
    except errors.CraftStoreError as exc:
        hint = f" {exc.resolution}" if exc.resolution else ""
        raise Failure(
            f"create-track {snap}/{track} failed: {exc}{hint} A 401/403 means the credentials "
            "can't manage this snap's tracks or the name misses its track-creation guardrails."
        ) from exc
    if created < 1:
        raise Failure(f"create-track {snap}/{track} returned success but created no track.")
    print(f"Track {track} created (num-tracks-created={created}).")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: snap-create-track.py <snap-name> <track>", file=sys.stderr)
        return 1
    try:
        create_track(argv[1], argv[2], os.environ.get("SNAPCRAFT_STORE_CREDENTIALS", ""))
    except Failure as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
