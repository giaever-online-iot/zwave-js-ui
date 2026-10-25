#!/usr/bin/env bash
# store-login-expiry.sh — read `snapcraft whoami` on stdin and print ONE line saying
# when the Ubuntu One login (SNAPCRAFT_STORE_CREDENTIALS) expires: a GitHub
# ::warning:: when fewer than <warn-days> remain, ::error:: once it has expired.
# Always exits 0 — a heads-up annotation, never a build gate.
#
# Usage:  snapcraft whoami | store-login-expiry.sh <label> <warn-days>
# Env:    NOW_EPOCH  override "now" (epoch seconds) — tests only.
set -euo pipefail

label="${1:?usage: store-login-expiry.sh <label> <warn-days>}"
warn_days="${2:?usage: store-login-expiry.sh <label> <warn-days>}"
now="${NOW_EPOCH:-$(date -u +%s)}"
hint="refresh it with \`snapcraft export-login\`"

input="$(cat)"
if [[ -z $input ]]; then
  # `snapcraft whoami` fails with no output when the login is expired or rejected.
  echo "::warning::$label: snapcraft whoami printed nothing (login expired or rejected?)"
  exit 0
fi
line="$(grep -m1 '^expires:' <<<"$input" || true)"
read -r _ expires <<<"$line"

# Require a leading ISO date: GNU date also accepts "", "now", "tomorrow" ...
if [[ $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] && exp="$(date -u -d "$expires" +%s 2>/dev/null)"; then
  ymd="${expires:0:10}"
  left=$((exp - now))
  days=$((left / 86400))
  if ((left < 0)); then
    echo "::error::$label expired on $ymd — $hint"
  elif ((days < warn_days)); then
    echo "::warning::$label expires in $days days ($ymd) — $hint"
  else
    echo "$label expires in $days days ($ymd)"
  fi
else
  echo "::warning::$label: could not read the expiry from snapcraft whoami"
fi
