#!/usr/bin/env bash
# Fixture-driven unit tests for snap-release.sh. No network.
set -uo pipefail  # no -e: keep all tests running even if earlier ones fail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$HERE/snap-release.sh"
INFO="$HERE/fixtures/snapcraft-status.txt"
fail=0

check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

check "version-to-track v-prefixed" "v11.19" "$("$SR" version-to-track v11.19.1)"
check "version-to-track bare"       "v11.19" "$("$SR" version-to-track 11.19.1)"
check "version-to-track x.0"        "v12.0"  "$("$SR" version-to-track v12.0.0)"
check "version-to-track empty"      ""       "$("$SR" version-to-track "")"

check "major v-prefixed" "12" "$("$SR" major v12.0.0)"
check "major bare"       "11" "$("$SR" major 11.19.1)"
check "major empty"      ""   "$("$SR" major "")"

check "channel-version candidate"  "v11.20.0" "$("$SR" channel-version latest/candidate <"$INFO")"
check "channel-version stable"     "v11.14.0" "$("$SR" channel-version latest/stable <"$INFO")"
check "channel-version inherited"  ""         "$("$SR" channel-version latest/beta <"$INFO")"
check "channel-version branch"     "v11.20.0" "$("$SR" channel-version v11.20/edge/204 <"$INFO")"
check "channel-version absent"     ""         "$("$SR" channel-version v99.9/stable <"$INFO")"

check "branch-has-revisions yes"   "yes" "$("$SR" branch-has-revisions v11.20 204 <"$INFO")"
check "branch-has-revisions no"    "no"  "$("$SR" branch-has-revisions v11.20 999 <"$INFO")"

# Same parser must also handle the interactive/TTY layout, where snapcraft blanks
# Track+Arch on continuation rows. CI captures non-interactively (repeated columns),
# but the parser is hardened for both — these lock that in.
TTY="$HERE/fixtures/snapcraft-status-tty.txt"
check "tty channel-version candidate" "v11.20.0" "$("$SR" channel-version latest/candidate <"$TTY")"
check "tty channel-version branch"    "v11.20.0" "$("$SR" channel-version v11.20/edge/204 <"$TTY")"
check "tty channel-version inherited" ""         "$("$SR" channel-version latest/beta <"$TTY")"
check "tty branch-has-revisions yes"  "yes"      "$("$SR" branch-has-revisions v11.20 204 <"$TTY")"

check "needs-stable-bump major"      "yes" "$("$SR" needs-stable-bump v12.0.0 v11.20.3)"
check "needs-stable-bump minor"      "no"  "$("$SR" needs-stable-bump v11.20.0 v11.19.1)"
check "needs-stable-bump empty-cand" "no"  "$("$SR" needs-stable-bump v11.19.1 "")"
check "needs-stable-bump empty-new"  "no"  "$("$SR" needs-stable-bump "" v11.19.1)"

check "is-at-least equal"        "yes" "$("$SR" is-at-least v11.19.1 v11.19.1)"
check "is-at-least greater"      "yes" "$("$SR" is-at-least v11.20.0 v11.19.9)"
check "is-at-least lesser"       "no"  "$("$SR" is-at-least v11.5.0 v11.19.0)"
check "is-at-least empty-floor"  "yes" "$("$SR" is-at-least v11.0.0 "")"
check "is-at-least minor-numeric" "yes" "$("$SR" is-at-least v11.20.0 v11.9.0)"

exit "$fail"
