#!/usr/bin/env bash
# Create a Snap Store version track via the snapcraft.io storefront.
#
# Auth: the publisher web SESSION COOKIE in $SNAPCRAFT_SESSION_COOKIE. The storefront
# create-track endpoint accepts ONLY this cookie — NOT a snapcraft macaroon
# (SNAPCRAFT_STORE_CREDENTIALS), which lives in a different auth realm and is rejected
# here. `snapcraft` has no create-track command, hence this raw POST.
#
# Usage: snap-create-track.sh <snap-name> <track>
# Exit:  0 = track created; 1 = failure, with a ::error:: explaining the cause.
set -euo pipefail

snap="${1:?usage: snap-create-track.sh <snap-name> <track>}"
track="${2:?usage: snap-create-track.sh <snap-name> <track>}"
cookie="${SNAPCRAFT_SESSION_COOKIE:-}"
# Trim surrounding whitespace — a pasted cookie often carries a trailing newline,
# which would otherwise slip past this guard and surface as a confusing 302.
cookie="${cookie#"${cookie%%[![:space:]]*}"}"
cookie="${cookie%"${cookie##*[![:space:]]}"}"

if [ -z "$cookie" ]; then
  echo "::error::SNAPCRAFT_SESSION_COOKIE is empty or unset — cannot authenticate to create track ${track}. Set the repo secret to a current snapcraft.io session cookie." >&2
  exit 1
fi

resp="$(curl -sS \
  -w $'\n@@CODE@@%{http_code}\n@@REDIRECT@@%{redirect_url}' \
  -X POST "https://snapcraft.io/${snap}/create-track" \
  -H "Cookie: session=${cookie};" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Origin: https://snapcraft.io" \
  -H "Referer: https://snapcraft.io/${snap}/releases" \
  --data-urlencode "track-name=${track}")" \
  || { echo "::error::create-track: curl could not reach snapcraft.io." >&2; exit 1; }

code="$(printf '%s\n' "$resp" | sed -n 's/^@@CODE@@//p' | tail -n1)"
redirect="$(printf '%s\n' "$resp" | sed -n 's/^@@REDIRECT@@//p' | tail -n1)"
body="$(printf '%s\n' "$resp" | sed '/^@@CODE@@/,$d')"

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
  3*)
    echo "::error::create-track redirected to login (${redirect:-?}) — SNAPCRAFT_SESSION_COOKIE is invalid or expired; refresh the repo secret." >&2
    exit 1
    ;;
  401|403)
    echo "::error::create-track unauthorized (HTTP ${code}) — refresh SNAPCRAFT_SESSION_COOKIE, or verify track-creation guardrails for ${snap} (body: ${body})." >&2
    exit 1
    ;;
  *)
    echo "::error::create-track failed (HTTP ${code:-none}) for ${track} (body: ${body})." >&2
    exit 1
    ;;
esac
