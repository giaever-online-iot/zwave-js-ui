#!/usr/bin/env python3
"""Mint the Candid credential CI uses to create Snap Store tracks.

The credential is a long-lived (365 days) Candid macaroon for the Charmhub publisher gateway. It
feeds the SNAPCRAFT_GATEWAY_CREDENTIALS repo secret, which snap-create-track.py presents to the
gateway.

Renewal, about once a year (snap-create-track.py --check warns 30 days ahead):
  1. Run:  .github/scripts/store-gateway-login.py gateway.creds
  2. Tap the Candid link it prints, on any device, and sign in with Ubuntu One.
  3. Run the `gh secret set` command it then prints.

craft-store prints the login URL itself and also tries to open it through Python's `webbrowser`,
which honours $BROWSER; point $BROWSER at a stand-in script to capture the URL instead of opening
a tab. The helper never prints the credential: it writes it to <out-file> with mode 0600.

The login parameters below reproduce the login verified against the live gateway on 2026-10-25.
Do not change them casually: a scoped or differently-permissioned token is unverified against the
tracks endpoint.
"""

import os
import shlex
import sys

from craft_store import StoreClient, attenuations, endpoints

GATEWAY = "https://api.charmhub.io"
STORAGE = "https://storage.snapcraftcontent.com"
PERMISSIONS = [attenuations.PACKAGE_MANAGE, attenuations.PACKAGE_VIEW]
DESCRIPTION = "zwave-js-ui CI: create version tracks"
TTL_SECONDS = 365 * 24 * 3600
SECRET = "SNAPCRAFT_GATEWAY_CREDENTIALS"
REPO = "giaever-online-iot/zwave-js-ui"


def login() -> str:
    """Run the interactive Candid login; returns the base64 credential blob."""
    client = StoreClient(
        base_url=GATEWAY,
        storage_base_url=STORAGE,
        endpoints=endpoints.CHARMHUB,
        application_name="zwave-js-ui-ci",
        user_agent="zwave-js-ui-ci/1.0",
        ephemeral=True,  # nothing goes to the system keyring
    )
    return client.login(permissions=PERMISSIONS, description=DESCRIPTION, ttl=TTL_SECONDS)


def write_credential(path: str, blob: str) -> None:
    """Write the blob owner-only, replacing any existing file."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        os.fchmod(fd, 0o600)  # the mode above only applies when the file is created
        f.write(blob)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: store-gateway-login.py <out-file>", file=sys.stderr)
        return 2
    path = argv[1]
    print("Starting the Candid login; craft-store prints the URL to open (tap it on your phone and sign in with Ubuntu One).", flush=True)
    write_credential(path, login())
    print(f"Credential written to {path} (0600; valid 365 days). Set the repo secret with:")
    print(f"  gh secret set {SECRET} --repo {REPO} < {shlex.quote(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
