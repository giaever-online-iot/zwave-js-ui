#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT
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
finish
