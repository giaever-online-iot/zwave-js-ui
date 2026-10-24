#!/usr/bin/env bash
# Unit tests for store-login-expiry.sh. No network: `snapcraft whoami` output is
# fed on stdin and "now" is pinned with NOW_EPOCH, so every case is deterministic.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPIRY="$HERE/store-login-expiry.sh"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

NOW_EPOCH="$(date -u -d 2026-10-25T00:00:00Z +%s)"; export NOW_EPOCH
FIX='email: someone@example.org
username: giaever-online
permissions: package_access, package_push, package_release
channels: no restrictions'

out="$("$EXPIRY" "store login" 30 <<EOT
$FIX
expires: 2027-10-24T00:00:00Z
EOT
)"; rc=$?
check "far from expiry: plain line"     "store login expires in 364 days (2027-10-24)" "$out"
check "far from expiry: exit 0"         "0" "$rc"

out="$("$EXPIRY" "store login" 30 <<EOT
$FIX
expires: 2026-11-06T05:00:00.000Z
EOT
)"; rc=$?
check "near expiry: warning annotation" "::warning::store login expires in 12 days (2026-11-06) — refresh it with \`snapcraft export-login\`" "$out"
check "near expiry: exit 0"             "0" "$rc"

out="$("$EXPIRY" "store login" 30 <<EOT
$FIX
expires: 2026-10-01T00:00:00Z
EOT
)"; rc=$?
check "expired: error annotation"       "::error::store login expired on 2026-10-01 — refresh it with \`snapcraft export-login\`" "$out"
check "expired: exit 0"                 "0" "$rc"

out="$("$EXPIRY" "store login" 30 <<EOT
$FIX
EOT
)"; rc=$?
check "no expires line: warning"        "::warning::store login: could not read the expiry from snapcraft whoami" "$out"
check "no expires line: exit 0"         "0" "$rc"

out="$("$EXPIRY" "store login" 30 <<EOT
$FIX
expires: soon
EOT
)"; rc=$?
check "unparseable expires: warning"    "::warning::store login: could not read the expiry from snapcraft whoami" "$out"
check "unparseable expires: exit 0"     "0" "$rc"

[ "$fail" -eq 0 ] && echo "All store-login-expiry tests passed." || echo "Some store-login-expiry tests FAILED."
exit "$fail"
