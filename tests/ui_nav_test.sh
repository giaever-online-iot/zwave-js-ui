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

# Restore real nav_service (the spy above shadowed it; existing tests have all passed)
# shellcheck source=/dev/null
source "$ROOT/src/bin/ui"

# --- Service section ---
# Shim the service bins under $SNAP_DATA and point nav_service at them via NAV_BIN
# (no writing into $SNAP/fixtures). nav_service loops; a single choice then a drained
# queue (exit 130 -> ui_choose returns 2 -> `|| return`) backs out cleanly.
SVC="$SNAP_DATA/svcbin"; mkdir -p "$SVC"
for b in daemonize de-daemonize restart; do printf '#!/usr/bin/env bash\necho "RAN_%s"\n' "$b" > "$SVC/$b"; chmod +x "$SVC/$b"; done
QS="$SNAP_DATA/svc.q"; printf '%s\n' "Enable" > "$QS"
out="$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$QS" nav_service 2>&1)"
assert_contains "$out" "RAN_daemonize" "Service > Enable runs daemonize"
printf '%s\n' "Restart" > "$QS"
assert_contains "$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$QS" nav_service 2>&1)" "RAN_restart" "Service > Restart runs restart"

finish
