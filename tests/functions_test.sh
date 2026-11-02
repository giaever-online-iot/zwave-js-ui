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


SNAP_COMMON="$(mktemp -d)"; export SNAP_COMMON; trap 'rm -rf "$SNAP_COMMON"' EXIT; MIG="$SNAP_COMMON/.session-secret-migrated"   # migrate runs once per marker
SLOG="$(mktemp)"; snapctl() { case "$1" in get) printf '%s' "${SECRET_VALUE:-}" ;; unset|set) printf '%s %s\n' "$1" "$2" >> "$SLOG" ;; *) : ;; esac; }
out="$(DAEMONIZED=0 SNAP_DATA=/snap/data SECRET_VALUE=6ba7b810-9dad-11d1-80b4-00c04fd430c8 migrate_session_secret)"
assert_contains "$(cat "$SLOG")" "unset session.secret" "migrate: v1 UUID is removed"
assert_contains "$out" "one re-login" "migrate: notice logged"; assert_not_contains "$out" "6ba7b810" "migrate: value not logged"
: > "$SLOG"; rm -f "$MIG"; SECRET_VALUE=123e4567-e89b-42d3-a456-426614174000 migrate_session_secret >/dev/null; assert_eq "$(cat "$SLOG")" "" "migrate: v4 UUID kept"
: > "$SLOG"; rm -f "$MIG"; SECRET_VALUE=my-own-secret migrate_session_secret >/dev/null;                       assert_eq "$(cat "$SLOG")" "" "migrate: custom value kept"
: > "$SLOG"; rm -f "$MIG"; SECRET_VALUE="" migrate_session_secret >/dev/null;                                    assert_eq "$(cat "$SLOG")" "" "migrate: unset stays unset"
: > "$SLOG"; snapctl() { case "$1" in get) printf '' ;; set) printf 'set %s\n' "$2" >> "$SLOG" ;; *) : ;; esac; }
test_default_config >/dev/null; assert_not_contains "$(cat "$SLOG")" "session.secret" "test_default_config no longer seeds session.secret"
assert_contains "$(cat "$SLOG")" "set server.port=8091" "test_default_config still seeds server.port"
assert_not_contains "$(cat "$SLOG")" "set timezone" "D5: test_default_config no longer seeds timezone"
assert_not_contains "$(cat "$SLOG")" "set session.cookie-secure" "D6: test_default_config no longer seeds session.cookie-secure"
# --- migrate_cookie_secure: drop the install-time copy of server.ssl once (marker), never a deliberate value
CMIG="$SNAP_COMMON/.cookie-secure-migrated"
snapctl() { case "$1 ${2:-}" in "get server.ssl") printf '%s' "${SSL_VALUE:-}" ;; "get session.cookie-secure") printf '%s' "${COOKIE_VALUE:-}" ;; unset*|set*) printf '%s %s\n' "$1" "$2" >> "$SLOG" ;; *) : ;; esac; }
: > "$SLOG"; rm -f "$CMIG"; out="$(DAEMONIZED=0 SSL_VALUE=false COOKIE_VALUE=false migrate_cookie_secure)"; _rc=$?
assert_status "$_rc" 0 "M1: equal -> rc 0"; assert_contains "$(cat "$SLOG")" "unset session.cookie-secure" "M1: equal -> unset"
assert_contains "$out" "session.cookie-secure: now follows server.ssl (was the install-time copy)" "M1: notice"
_rc=0; [ -e "$CMIG" ] || _rc=1; assert_status "$_rc" 0 "M1: marker written"
: > "$SLOG"; rm -f "$CMIG"; out="$(DAEMONIZED=0 SSL_VALUE=true COOKIE_VALUE=false migrate_cookie_secure)"
assert_eq "$(cat "$SLOG")" "" "M2: differing -> kept"; assert_eq "$out" "" "M2: no notice"
_rc=0; [ -e "$CMIG" ] || _rc=1; assert_status "$_rc" 0 "M2: marker written"
: > "$SLOG"; rm -f "$CMIG"; DAEMONIZED=0 SSL_VALUE=false COOKIE_VALUE="" migrate_cookie_secure >/dev/null; assert_eq "$(cat "$SLOG")" "" "M3: cookie unset -> nothing to unset"
: > "$SLOG"; : > "$CMIG"; out="$(DAEMONIZED=0 SSL_VALUE=true COOKIE_VALUE=true migrate_cookie_secure)"
assert_eq "$(cat "$SLOG")$out" "" "M4: marker present -> nothing"
rm -f "$SLOG"

PLOG="$(mktemp)"; logger() { printf '%s\n' "$*" >> "$PLOG"; }
snapctl() { case "$1" in is-connected) [ "$2" != raw-usb ] ;; *) : ;; esac; }     # only raw-usb missing
( DAEMONIZED=1 plugs_connected ); assert_status "$?" 0 "A7: serial-port + hardware-observe -> connected"
assert_eq "$(cat "$PLOG")" "" "A7: nothing logged when the alternative plug is present"
snapctl() { case "$1" in is-connected) [ "$2" = hardware-observe ] ;; *) : ;; esac; } # both alternatives missing
( DAEMONIZED=1 plugs_connected ); assert_status "$?" 1 "A7: both missing -> fail"
assert_contains "$(cat "$PLOG")" "Missing interface: raw-usb" "A7: raw-usb message logged"
assert_contains "$(cat "$PLOG")" "Connect raw-usb (USB stick) OR serial-port (see zwave-js-ui.help):" "A7: single header"
assert_contains "$(cat "$PLOG")" "serial-port" "A7: serial-port alternative logged"
assert_not_contains "$(cat "$PLOG")" "----- OR" "A7: no OR separator"; assert_not_contains "$(cat "$PLOG")" "\$ sudo" "A7: no prompt prefix"; assert_not_contains "$(cat "$PLOG")" "«" "A7: no guillemets"
# D12: require_root is one stderr line, nothing on stdout
out="$( (require_root) 2>&1 >/dev/null )"; assert_eq "$out" "zwave-js-ui: this command must run as root — re-run with sudo." "D12: require_root stderr line"
out="$( (require_root) 2>/dev/null )"; assert_eq "$out" "" "D12: require_root stdout empty"
(require_root) >/dev/null 2>&1; assert_status "$?" 1 "D12: require_root exits 1"
rm -f "$PLOG"
finish
