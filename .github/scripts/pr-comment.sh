#!/usr/bin/env bash
# pr-comment.sh — render the sticky PR-build comment body for pr-build-snap.yml.
# Pure: args in, markdown on stdout, no network. Unit-tested by pr-comment.test.sh.
#
# Usage:  pr-comment.sh <channel> <wanted-csv> <published-csv>
#   <wanted-csv>    archs the build targeted, e.g. "amd64,arm64,armhf"
#   <published-csv> archs that reached the channel (may be empty)
# Env:    SNAP_NAME (default zwave-js-ui)
set -euo pipefail

chan="${1:?usage: pr-comment.sh <channel> <wanted-csv> <published-csv>}"
wanted="${2:-}"
published="${3:-}"
snap="${SNAP_NAME:-zwave-js-ui}"

# csv -> sorted-unique newline list (empties dropped)
to_lines() { printf '%s' "${1:-}" | tr ',' '\n' | sed '/^$/d' | sort -u; }
w="$(to_lines "$wanted")"
p="$(to_lines "$published")"
count() { printf '%s\n' "${1}" | sed '/^$/d' | wc -l | tr -d ' '; }
nw="$(count "$w")"
np="$(count "$p")"

join_csv() { printf '%s\n' "${1}" | sed '/^$/d' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'; }
avail="$(join_csv "$p")"
failed="$(comm -23 <(printf '%s\n' "$w" | sed '/^$/d') <(printf '%s\n' "$p" | sed '/^$/d') | { tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'; })"

if [ "$np" -eq 0 ]; then
    printf '❌ No architectures were published for this PR.\n'
    exit 0
fi

if [ -z "$failed" ]; then
    printf "✅ Published to \`%s\` — available to install & test:\n\n" "$chan"
    printf '  Architectures: %s\n' "$avail"
    note="auto-selects your arch"
else
    printf "⚠️ Partial publish to \`%s\` — %s of %s architectures.\n\n" "$chan" "$np" "$nw"
    printf '  Available for: %s\n' "$avail"
    note="works on: $avail"
fi
printf '  sudo snap install %s --channel=%s      # %s\n' "$snap" "$chan" "$note"
printf '  # or: sudo snap refresh %s --channel=%s\n' "$snap" "$chan"
if [ -n "$failed" ]; then
    printf '\n  ❌ Failed: %s — use "Re-run failed jobs" to retry just that arch (no rebuild of the published archs).\n' "$failed"
fi
