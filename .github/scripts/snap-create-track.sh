#!/usr/bin/env bash
# Create a Snap Store version track via the publisher gateway (api.charmhub.io).
#
# Auth: SNAPCRAFT_STORE_CREDENTIALS (`snapcraft export-login`) — the same secret that
# uploads. Its dashboard macaroons are exchanged for a publisher-gateway token at
# /v1/tokens/dashboard/exchange, then used on POST /v1/snap/<snap>/tracks. This is the
# flow snapcraft.io itself runs behind its "create track" button, so no web session
# cookie is needed. `snapcraft` has no create-track command, hence the raw calls.
#
# Usage: snap-create-track.sh <snap-name> <track>
# Env:   PYTHON — interpreter with pymacaroons, used to bind the macaroons (default python3)
# Exit:  0 = track created or already exists; 1 = failure, with a ::error:: explaining the cause.
set -euo pipefail

snap="${1:?usage: snap-create-track.sh <snap-name> <track>}"
track="${2:?usage: snap-create-track.sh <snap-name> <track>}"
creds="${SNAPCRAFT_STORE_CREDENTIALS:-}"
gw="https://api.charmhub.io"

# Store track-name rule; also keeps $track safe to splice into the JSON body.
if ! [[ "$track" =~ ^[a-zA-Z0-9]([_.-]?[a-zA-Z0-9])*$ ]]; then
  echo "::error::invalid track name '${track}'." >&2
  exit 1
fi

if [ -z "$creds" ]; then
  echo "::error::SNAPCRAFT_STORE_CREDENTIALS is empty or unset — cannot authenticate to create track ${track}." >&2
  exit 1
fi

# Bind the discharge to the root macaroon; prints the exchange Authorization value.
dashboard_auth="$(printf '%s' "$creds" | "${PYTHON:-python3}" -c '
import base64, json, sys
from pymacaroons import Macaroon
v = json.loads(base64.b64decode(sys.stdin.read()))["v"]
bound = Macaroon.deserialize(v["r"]).prepare_for_request(Macaroon.deserialize(v["d"]))
print("macaroon root=%s, discharge=%s" % (v["r"], bound.serialize()))
' 2>/dev/null)" || {
  echo "::error::could not read SNAPCRAFT_STORE_CREDENTIALS — expected the output of \`snapcraft export-login\` (and pymacaroons for \$PYTHON)." >&2
  exit 1
}

# post <url> <authorization> <json-body>: sets $code and $body.
post() {
  local resp
  resp="$(curl -sS -w $'\n@@CODE@@%{http_code}' -X POST "$1" \
    -H "Authorization: $2" \
    -H "Content-Type: application/json" \
    --data "$3")" \
    || { echo "::error::create-track: curl could not reach ${gw}." >&2; exit 1; }
  code="$(printf '%s\n' "$resp" | sed -n 's/^@@CODE@@//p' | tail -n1)"
  body="$(printf '%s\n' "$resp" | sed '/^@@CODE@@/,$d')"
}

post "${gw}/v1/tokens/dashboard/exchange" "$dashboard_auth" '{}'
token="$(printf '%s' "$body" | sed -n 's/.*"macaroon": *"\([^"]*\)".*/\1/p' | head -n1)"
if [[ "$code" != 2* || -z "$token" ]]; then
  echo "::error::token exchange failed (HTTP ${code:-none}) — SNAPCRAFT_STORE_CREDENTIALS is invalid or expired; refresh it with \`snapcraft export-login\` (body: ${body})." >&2
  exit 1
fi

post "${gw}/v1/snap/${snap}/tracks" "Macaroon ${token}" "[{\"name\": \"${track}\"}]"
echo "create-track ${snap}/${track}: HTTP ${code:-none}"

case "$code" in
  2*)
    created="$(printf '%s' "$body" | grep -oE '"num-tracks-created": *[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
    if [ "${created:-0}" -ge 1 ]; then
      echo "Track ${track} created (num-tracks-created=${created})."
    else
      echo "::error::create-track returned HTTP ${code} but created no track (body: ${body})." >&2
      exit 1
    fi
    ;;
  409)
    echo "Track ${track} already exists."
    ;;
  401|403)
    echo "::error::create-track unauthorized (HTTP ${code}) — the SNAPCRAFT_STORE_CREDENTIALS account can't create tracks on ${snap}, or ${track} doesn't match its track-creation guardrails (body: ${body})." >&2
    exit 1
    ;;
  *)
    echo "::error::create-track failed (HTTP ${code:-none}) for ${track} (body: ${body})." >&2
    exit 1
    ;;
esac
