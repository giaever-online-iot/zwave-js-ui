#!/usr/bin/env bash
# retry.sh — run a command, retrying on failure to ride out TRANSIENT errors
# (network blips on remote store / Launchpad operations: artifact fetch, snap
# upload, track creation). Bounded: a genuinely-broken command still fails after
# <max-attempts>, but a one-off connection drop no longer fails the build.
#
# Usage:  retry.sh <max-attempts> <delay-seconds> -- <command> [args...]
# Exit:   0 on first success; otherwise the LAST attempt's exit status.
set -uo pipefail

max="${1:?usage: retry.sh <max-attempts> <delay-seconds> -- cmd ...}"
delay="${2:?usage: retry.sh <max-attempts> <delay-seconds> -- cmd ...}"
shift 2
[ "${1:-}" = "--" ] && shift
[ "$#" -gt 0 ] || { echo "retry.sh: no command given" >&2; exit 2; }

attempt=1
while true; do
    "$@" && exit 0
    rc=$?
    if [ "$attempt" -ge "$max" ]; then
        echo "retry.sh: '$1' failed after ${attempt} attempt(s) (exit ${rc})" >&2
        exit "$rc"
    fi
    echo "retry.sh: '$1' failed (exit ${rc}); retry ${attempt}/${max} in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
done
