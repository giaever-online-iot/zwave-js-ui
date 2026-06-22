#!/usr/bin/env bash
# Unit tests for retry.sh. No network: a stub command counts attempts in a file
# and succeeds once it reaches a threshold, so retry behaviour is deterministic.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETRY="$HERE/retry.sh"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# Stub command: bump counter file ($1), succeed once it reaches threshold ($2).
# shellcheck disable=SC2016  # $1/$2 are bash -c positional args — intentionally literal
FLAKY='n=0; [ -f "$1" ] && n=$(cat "$1"); n=$((n+1)); printf %s "$n" >"$1"; [ "$n" -ge "$2" ]'

st="$work/a"; "$RETRY" 3 0 -- bash -c "$FLAKY" _ "$st" 1; rc=$?
check "success first try: exit 0"        "0" "$rc"
check "success first try: ran once"      "1" "$(cat "$st")"

st="$work/b"; "$RETRY" 3 0 -- bash -c "$FLAKY" _ "$st" 3; rc=$?
check "recovers on 3rd attempt: exit 0"  "0" "$rc"
check "recovers on 3rd attempt: ran 3x"  "3" "$(cat "$st")"

st="$work/c"; "$RETRY" 2 0 -- bash -c "$FLAKY" _ "$st" 99; rc=$?
check "exhausts attempts: nonzero exit"  "1" "$rc"
check "exhausts attempts: ran max twice" "2" "$(cat "$st")"

"$RETRY" 1 0 -- bash -c 'exit 7'; check "propagates command exit code" "7" "$?"
"$RETRY" 3 0 -- 2>/dev/null;       check "no command -> usage exit 2"   "2" "$?"

[ "$fail" -eq 0 ] && echo "All retry tests passed." || echo "Some retry tests FAILED."
exit "$fail"
