#!/usr/bin/env bash
# Unit tests for src/helper/functions (the shared bash library sourced by every
# hook and bin script). Same harness as the other suites: stub snapctl, source
# the real library, assert on rendered output.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"
export SNAP_NAME="zwave-js-ui"

# snapctl stub: `get` always misses so testnset_config takes its `set` branch;
# `set` succeeds silently.
snapctl() { case "$1" in get) return 1 ;; *) : ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/src/helper/functions"

# --- testnset_config: hooks run DAEMONIZED, so its lprints land in syslog.
# Secret values must be redacted there; everything else stays verbatim.

out="$(testnset_config "session.secret" "SUPERSECRET")"
assert_contains     "$out" "session.secret=(redacted)" "secret: value redacted in log line"
assert_not_contains "$out" "SUPERSECRET"               "secret: raw value absent from log output"

out="$(testnset_config "server.port" "8091")"
assert_contains "$out" "Setting server.port=8091" "non-secret: value logged verbatim"


SLOG="$(mktemp)"; snapctl() { case "$1" in get) printf '%s' "${SECRET_VALUE:-}" ;; unset|set) printf '%s %s\n' "$1" "$2" >> "$SLOG" ;; *) : ;; esac; }
out="$(DAEMONIZED=0 SNAP_DATA=/snap/data SECRET_VALUE=6ba7b810-9dad-11d1-80b4-00c04fd430c8 migrate_session_secret)"
assert_contains "$(cat "$SLOG")" "unset session.secret" "migrate: v1 UUID is removed"
assert_contains "$out" "one re-login" "migrate: notice logged"; assert_not_contains "$out" "6ba7b810" "migrate: value not logged"
: > "$SLOG"; SECRET_VALUE=123e4567-e89b-42d3-a456-426614174000 migrate_session_secret >/dev/null; assert_eq "$(cat "$SLOG")" "" "migrate: v4 UUID kept"
: > "$SLOG"; SECRET_VALUE=my-own-secret migrate_session_secret >/dev/null;                       assert_eq "$(cat "$SLOG")" "" "migrate: custom value kept"
: > "$SLOG"; SECRET_VALUE="" migrate_session_secret >/dev/null;                                    assert_eq "$(cat "$SLOG")" "" "migrate: unset stays unset"
: > "$SLOG"; snapctl() { case "$1" in get) printf '' ;; set) printf 'set %s\n' "$2" >> "$SLOG" ;; *) : ;; esac; }
test_default_config >/dev/null; assert_not_contains "$(cat "$SLOG")" "session.secret" "test_default_config no longer seeds session.secret"
assert_contains "$(cat "$SLOG")" "set server.port=8091" "test_default_config still seeds server.port"
rm -f "$SLOG"

PLOG="$(mktemp)"; logger() { printf '%s\n' "$*" >> "$PLOG"; }
snapctl() { case "$1" in is-connected) [ "$2" != raw-usb ] ;; *) : ;; esac; }     # only raw-usb missing
( DAEMONIZED=1 plugs_connected ); assert_status "$?" 0 "A7: serial-port + hardware-observe -> connected"
assert_eq "$(cat "$PLOG")" "" "A7: nothing logged when the alternative plug is present"
snapctl() { case "$1" in is-connected) [ "$2" = hardware-observe ] ;; *) : ;; esac; } # both alternatives missing
( DAEMONIZED=1 plugs_connected ); assert_status "$?" 1 "A7: both missing -> fail"
assert_contains "$(cat "$PLOG")" "Missing plug: «raw-usb»" "A7: raw-usb message logged"; assert_contains "$(cat "$PLOG")" "----- OR -----" "A7: OR line"; assert_contains "$(cat "$PLOG")" "serial-port" "A7: serial-port alternative logged"
rm -f "$PLOG"
finish
