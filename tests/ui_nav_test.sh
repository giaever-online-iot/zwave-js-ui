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
export UI_NO_PAUSE=1                        # ui_pause must not block the suite (no real keypress)

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

# --- catalog_row ---
assert_eq "$(catalog_row server.port | cut -f2)" "int" "catalog_row server.port type"
assert_eq "$(catalog_row server.ssl | cut -f3)" "false" "catalog_row server.ssl default"
assert_eq "$(catalog_row nope)" "" "catalog_row unknown -> empty"

# --- Settings: edit a bool, apply via snapctl set ---
SET_LOG="$SNAP_DATA/set.log"; : > "$SET_LOG"
snapctl() {
    case "$1" in
        services) printf 'Service  Startup  Current  Notes\nzwave-js-ui.zwave-js-ui  enabled  active  -\n' ;;
        get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
        set)   printf 'set %s\n' "$2" >> "$SET_LOG"; [ -n "${SNAPCTL_SET_FAIL:-}" ] && { echo "configure: bad value" >&2; return 1; }; return 0 ;;
        unset) printf 'unset %s\n' "$2" >> "$SET_LOG"; return 0 ;;
        *) : ;;
    esac
}
# browse server.ssl -> Edit -> choose "true" -> Back; then Back out of settings
CQ="$SNAP_DATA/setc.q"; printf '%s\n' "server.ssl" "Edit" "true" "← Back" > "$CQ"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings 2>&1)"
assert_contains "$(cat "$SET_LOG")" "set server.ssl=true" "Edit bool -> snapctl set key=value"
assert_contains "$out" "set" "success surfaced"

# rejection: configure hook says no -> ui_err, message shown, value not claimed applied
# server.port is int -> the value comes from ui_input (GUM_INPUT_QUEUE), NOT the choose queue.
: > "$SET_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"
INQ="$SNAP_DATA/in.q"; printf '99999\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 SNAPCTL_SET_FAIL=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "configure: bad value" "rejection surfaces the hook message"

# reset to default -> snapctl unset
: > "$SET_LOG"; printf '%s\n' "mqtt.name" "Reset to default" "← Back" > "$CQ"
UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "unset mqtt.name" "Reset -> snapctl unset"

# session.secret value is masked in the success banner (not leaked)
# Re-source src/bin/ui to clear any spy overrides left by prior tests
# shellcheck source=/dev/null
source "$ROOT/src/bin/ui"
SQ="$SNAP_DATA/sec.q"; printf '%s\n' "session.secret" "Edit" "← Back" > "$SQ"
SIQ="$SNAP_DATA/sec.in"; printf 'supersecretvalue\n' > "$SIQ"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$SQ" GUM_INPUT_QUEUE="$SIQ" nav_settings 2>&1)"
case "$out" in *supersecretvalue*) FAIL=$((FAIL+1)); echo "FAIL: session.secret leaked in banner" >&2 ;; *) PASS=$((PASS+1)) ;; esac
assert_contains "$out" "(hidden)" "session.secret edit shows (hidden) in banner"

# --- Plugs section ---
snapctl() { case "$1" in is-connected) [ "$2" = hardware-observe ] && return 0 || return 1 ;; *) : ;; esac; }
PQ="$SNAP_DATA/plug.q"; printf '%s\n' "raw-usb" "← Back" > "$PQ"     # pick a disconnected plug
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$PQ" nav_plugs 2>&1)"
assert_contains "$out" "snap connect $SNAP_NAME:raw-usb" "disconnected plug shows the connect command"
printf '%s\n' "hardware-observe" "← Back" > "$PQ"                    # connected plug
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$PQ" nav_plugs 2>&1)"
case "$out" in *"snap connect $SNAP_NAME:hardware-observe"*) FAIL=$((FAIL+1)); echo "FAIL: connected plug should not show connect cmd" >&2 ;; *) PASS=$((PASS+1)) ;; esac

# --- Live logs + Help ---
mkdir -p "$SVC"; printf '#!/usr/bin/env bash\necho "RAN_logs $*"\n' > "$SVC/logs"; chmod +x "$SVC/logs"
printf '#!/usr/bin/env bash\necho "RAN_help"\n' > "$SVC/help"; chmod +x "$SVC/help"
LQ="$SNAP_DATA/logs.q"; printf '%s\n' "zui" > "$LQ"
assert_contains "$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$LQ" nav_logs 2>&1)" "RAN_logs zui" "Live logs > zui runs logs zui"
printf '%s\n' "all" > "$LQ"
assert_contains "$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$LQ" nav_logs 2>&1)" "RAN_logs all" "Live logs > all runs logs all"
assert_contains "$(NAV_BIN="$SVC" nav_help 2>&1)" "RAN_help" "Help runs help"

# navigator wipes the screen on each styled view (ui_clear wired into the loops)
cqx="$SNAP_DATA/clear.q"; printf '%s\n' "Enable" > "$cqx"
assert_contains "$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$cqx" nav_service 2>&1)" "$(printf '\033[2J')" "nav: styled view clears the screen"

finish
