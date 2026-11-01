#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
SNAP_COMMON="$(mktemp -d)"; export SNAP_COMMON
trap 'rm -rf "$SNAP_DATA" "$SNAP_COMMON"' EXIT
export PATH="$HERE/fixtures/bin:$PATH"     # snapctl exec-stub on PATH

# env-wrapper sets env from snapctl then exec's its argument; run `env` to observe.
run_wrapper() { bash "$ROOT/src/helper/env-wrapper" env 2>/dev/null; }

# serial port present -> ZWAVE_PORT exported
out="$(SNAPCTL_zwave_serial_port=/dev/ttyACM0 run_wrapper)"
assert_contains "$out" "ZWAVE_PORT=/dev/ttyACM0" "serial-port -> ZWAVE_PORT"
# a security key present -> KEY_* exported
out="$(SNAPCTL_zwave_s2_unauthenticated=DEADBEEF run_wrapper)"
assert_contains "$out" "KEY_S2_Unauthenticated=DEADBEEF" "s2-unauthenticated -> KEY_S2_Unauthenticated"
# empty -> NOT exported (no blank override)
out="$(run_wrapper)"
case "$out" in *$'\n'ZWAVE_PORT=*|ZWAVE_PORT=*) FAIL=$((FAIL+1)); echo "FAIL: empty serial-port exported ZWAVE_PORT" >&2 ;; *) PASS=$((PASS+1)) ;; esac

# config digest: recorded at every start, 0600, no config values, daemon keys only
DF="$SNAP_COMMON/.daemon-config.sha256"
SNAPCTL_server_host=10.0.0.7 run_wrapper >/dev/null
[ -f "$DF" ]; assert_status "$?" 0 "E1: digest file written at start"
assert_eq "$(stat -c %a "$DF")" "600" "E2: digest file is 0600"
chmod 644 "$DF"; SNAPCTL_server_host=10.0.0.7 run_wrapper >/dev/null
assert_eq "$(stat -c %a "$DF")" "600" "E2: loose pre-existing digest file is re-tightened to 0600"
[[ "$(cat "$DF")" =~ ^[0-9a-f]{64}$ ]]; assert_status "$?" 0 "E2: digest is sha256 hex"
assert_not_contains "$(cat "$DF")" "10.0.0.7" "E2: no config value in the file"
d7="$(cat "$DF")"; SNAPCTL_server_host=10.0.0.8 run_wrapper >/dev/null
[ "$(cat "$DF")" != "$d7" ]; assert_status "$?" 0 "E3: daemon key change -> new digest"
SNAPCTL_server_host=10.0.0.7 SNAPCTL_backup_target=file:///x run_wrapper >/dev/null
assert_eq "$(cat "$DF")" "$d7" "E3: backup-only key does not change the digest"
out="$(SNAP_COMMON=/nonexistent/no-such-dir run_wrapper)"
assert_contains "$out" "HOST=" "E4: unwritable SNAP_COMMON still execs the app"
finish
