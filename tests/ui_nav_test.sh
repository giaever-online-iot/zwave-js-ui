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
# The fixture helper shim has no seeding functions; load the real ones (no drift) so Reset re-seeds.
# shellcheck disable=SC1090
source <(sed -n '/^function testnset_config {/,/^}/p;/^function test_default_config {/,/^}/p' "$ROOT/src/helper/functions")
SET_LOG="$SNAP_DATA/set.log"; : > "$SET_LOG"
snapctl() {
    case "$1" in
        services) printf 'Service  Startup  Current  Notes\nzwave-js-ui.zwave-js-ui  enabled  %s  -\n' "${SNAPCTL_MAIN_STATE:-active}" ;;
        get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
        set)   printf 'set %s\n' "$2" >> "$SET_LOG"; return 0 ;;
        unset) printf 'unset %s\n' "$2" >> "$SET_LOG"; return 0 ;;
        *) : ;;
    esac
}
# browse server.ssl -> Edit -> choose "true" -> Back; then Back out of settings
CQ="$SNAP_DATA/setc.q"; printf '%s\n' "server.ssl" "Edit" "true" "← Back" > "$CQ"
out="$(UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings 2>&1)"
assert_contains "$(cat "$SET_LOG")" "set server.ssl=true" "Edit bool -> snapctl set key=value"
assert_contains "$out" "set" "success surfaced"

INQ="$SNAP_DATA/in.q"
: > "$SET_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '99999\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "a port number 1-65535" "N1: client-side validation message"; assert_contains "$out" "Rejected" "N1: rejected banner"
assert_not_contains "$(cat "$SET_LOG")" "set server.port" "N1: nothing written on rejection"
: > "$SET_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "set server.port=8092" "N2: valid int written"
: > "$SET_LOG"; printf '%s\n' "server.port" "Reset to default" "← Back" > "$CQ"
UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "unset server.port" "N3: reset unsets"; assert_contains "$(cat "$SET_LOG")" "set server.port=8091" "N3: reset re-seeds the default"
: > "$GUM_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CONFIRM=0 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "RAN_restart" "N4: restart accepted -> restart bin runs"
: > "$GUM_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_not_contains "$out" "RAN_restart" "N4: restart declined -> no restart"; assert_contains "$(cat "$GUM_LOG")" "confirm" "N4: restart was offered"
: > "$GUM_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 SNAPCTL_MAIN_STATE=inactive GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "Takes effect when the service starts." "N5: inactive -> no offer, hint"; assert_not_contains "$(cat "$GUM_LOG")" "confirm" "N5: no confirm when inactive"
: > "$GUM_LOG"; printf '%s\n' "backup.target" "Edit" "← Back" > "$CQ"; printf 'file:///x\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "Used by the next backup run." "N6: backup key -> no restart talk"; assert_not_contains "$(cat "$GUM_LOG")" "confirm" "N6: no confirm for backup keys"
: > "$SET_LOG"; printf '%s\n' "session.cookie-secure" "Reset to default" "← Back" > "$CQ"
SNAPCTL_server_ssl=true UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "set session.cookie-secure=true" "N7: dependent default follows server.ssl"
: > "$SET_LOG"; printf '%s\n' "mqtt.name" "Edit" "← Back" > "$CQ"; printf '\n' > "$INQ"
UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "unset mqtt.name" "N8: empty edit = reset"
printf '%s\n' "backup.retention" "Reset to default" "← Back" > "$CQ"
out="$(UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings 2>&1)"
assert_contains "$out" "backup.retention reset to default: 3" "N9: run-time default shown from the catalog"
printf '%s\n' "mqtt.name" "Reset to default" "← Back" > "$CQ"
out="$(UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings 2>&1)"
assert_contains "$out" "mqtt.name reset to default: (unset)" "N9: a key without a default still says (unset)"
printf '%s\n' "zwave.serial-port" "← Back" > "$CQ"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings 2>&1)"
assert_contains "$out" "Serial device of the Z-Wave controller" "A6: real description shown"; assert_not_contains "$out" "advanced" "A6: scope no longer leaks into the description"

# session.secret value is masked in the success banner (not leaked)
# Re-source src/bin/ui to clear any spy overrides left by prior tests
# shellcheck source=/dev/null
source "$ROOT/src/bin/ui"
SQ="$SNAP_DATA/sec.q"; printf '%s\n' "session.secret" "Edit" "← Back" > "$SQ"
SIQ="$SNAP_DATA/sec.in"; printf 'supersecretvalue\n' > "$SIQ"
out="$(UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$SQ" GUM_INPUT_QUEUE="$SIQ" nav_settings 2>&1)"
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

# secret-typed zwave key is masked in the banner and never leaked (type=secret, not by name)
# Re-source src/bin/ui to clear any spy overrides left by prior tests
# shellcheck source=/dev/null
source "$ROOT/src/bin/ui"
SKQ="$SNAP_DATA/sk.q"; printf '%s\n' "zwave.s2-unauthenticated" "Edit" "← Back" > "$SKQ"
SKI="$SNAP_DATA/sk.in"; printf 'AABBCCDD\n' > "$SKI"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$SKQ" GUM_INPUT_QUEUE="$SKI" nav_settings 2>&1)"
case "$out" in *AABBCCDD*) FAIL=$((FAIL+1)); echo "FAIL: secret zwave key leaked" >&2 ;; *) PASS=$((PASS+1)) ;; esac
assert_contains "$out" "(hidden)" "secret zwave key shows (hidden) in banner"

# --- nav_mqtt: edits settings.json mqtt.* via yq (stubbed) ---
SF="$SNAP_DATA/settings.json"; printf '%s' '{"mqtt":{"host":"old"}}' > "$SF"
YQ_LOG="$SNAP_DATA/yq.log"; : > "$YQ_LOG"
# stub yq: log the expression+file; for reads (-e '.mqtt.host') echo a canned current value; writes succeed
yq() { printf '%s\n' "$*" >> "$YQ_LOG"; case "$*" in *'-o=json'*|*' = '*) cat "${@: -1}" 2>/dev/null || true ;; *) printf 'old\n' ;; esac; }
export -f yq 2>/dev/null || true
MQ="$SNAP_DATA/mqtt.q"; printf '%s\n' "mqtt.host" "← Back" > "$MQ"
MI="$SNAP_DATA/mqtt.in"; printf 'broker.local\n' > "$MI"
# decline the restart prompt
GUM_CONFIRM=1 UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$MQ" GUM_INPUT_QUEUE="$MI" SNAP_DATA="$SNAP_DATA" nav_mqtt >/dev/null 2>&1
assert_contains "$(cat "$YQ_LOG")" ".mqtt.host" "nav_mqtt writes mqtt.host via yq"

finish
