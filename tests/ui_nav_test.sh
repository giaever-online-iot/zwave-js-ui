#!/usr/bin/env bash
set -u
# Pin a clean rendering baseline: GitHub Actions runners export no TERM, and
# bash then defaults TERM=dumb — which forces plain ctx and overrides
# UI_ASSUME_TTY, failing every styled assertion.
export TERM=xterm-256color
unset NO_COLOR
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
export SNAP="$HERE/fixtures"
: "${SNAP_NAME:=zwave-js-ui}"; export SNAP_NAME   # snapd sets this at runtime; pin it for tests
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT
export PATH="$HERE/fixtures/bin:$PATH"     # stub gum/less on PATH
export GUM_LOG="$SNAP_DATA/gum.log"; : > "$GUM_LOG"

snapctl() {
    case "$1" in
        services) printf 'Service  Startup  Current  Notes\nzwave-js-ui.zwave-js-ui  enabled  active  -\n' ;;
        get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
        *) : ;;
    esac
}
# shellcheck source=/dev/null
source "$ROOT/src/bin/ui"

# root guard: require_root calls `exit 1` (would kill the harness), so assert main
# CALLS it first by overriding it as a spy instead of running the real non-root path.
R="$SNAP_DATA/root.flag"; rm -f "$R"
require_root() { : > "$R"; }                  # spy
printf '%s\n' "Quit" > "$SNAP_DATA/q0"
UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$SNAP_DATA/q0" main >/dev/null 2>&1
assert_status "$([ -f "$R" ] && echo 0 || echo 1)" "0" "main calls require_root first"

# no-TTY -> pointer + status 2 (ui_interactive false because stdout is a pipe here)
out="$(UI_ASSUME_TTY='' main </dev/null 2>&1)"; st=$?
assert_status "$st" "2" "no-TTY -> returns 2"
assert_contains "$out" "$SNAP_NAME.help" "no-TTY -> points at help"

# interactive: pick Service then Quit -> dispatches nav_service, then exits cleanly
Q="$SNAP_DATA/choose.q"; printf '%s\n' "Service" "Quit" > "$Q"
nav_service() { echo "NAV_SERVICE_RAN"; }     # spy
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$Q" main 2>&1)"; st=$?
assert_status "$st" "0" "interactive loop exits 0 on Quit"
assert_contains "$out" "NAV_SERVICE_RAN" "Service menu entry dispatches nav_service"
assert_contains "$out" "$SNAP_NAME" "header shows the snap name"

finish
