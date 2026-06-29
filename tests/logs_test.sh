#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

# Source the script under test with a stubbed snap runtime.
export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT
# shellcheck source=/dev/null
source "$ROOT/src/bin/logs"

# --- tests appended by later tasks ---
assert_eq "$(normalize_target '')"      "both" "empty -> both"
assert_eq "$(normalize_target 'all')"   "both" "all -> both"
assert_eq "$(normalize_target '--all')" "both" "--all -> both"
assert_eq "$(normalize_target 'zui')"   "zui"  "zui -> zui"
assert_eq "$(normalize_target '--zui')" "zui"  "--zui -> zui"
assert_eq "$(normalize_target 'zwjs')"  "zwjs" "zwjs -> zwjs"
assert_eq "$(normalize_target '--zwjs')" "zwjs" "--zwjs -> zwjs"
normalize_target 'nope' >/dev/null 2>&1; assert_status "$?" "2" "unknown -> status 2"
parse_args a b >/dev/null 2>&1; assert_status "$?" "2" "two args -> status 2"
assert_eq "$(parse_args --zwjs)" "zwjs" "parse_args passes through"

assert_eq "$(setting_key zui)"  ".gateway.logToFile" "zui key"
assert_eq "$(setting_key zwjs)" ".zwave.logToFile"   "zwjs key"

# read_log_setting: file path + yq path -> true|false|""
_sf="$SNAP_DATA/settings.json"
printf '%s' '{"gateway":{"logToFile":true},"zwave":{"logToFile":false}}' > "$_sf"
assert_eq "$(read_log_setting "$_sf" .gateway.logToFile)" "true"  "reads true"
assert_eq "$(read_log_setting "$_sf" .zwave.logToFile)"   "false" "reads false"
assert_eq "$(read_log_setting "$_sf" .missing.key)"       ""      "missing key -> empty"
assert_eq "$(read_log_setting "/no/such/file" .gateway.logToFile)" "" "no file -> empty"

# canonical paths (logs_dir defaults to $SNAP_DATA/logs/zwavejs — the dir env-wrapper
# sets for the daemon; ZUI current file is z-ui_current.log, NOT zwave-js-ui_current.log)
assert_eq "$(canonical_log_path zwjs)" "$SNAP_DATA/logs/zwavejs/zwavejs_current.log" "zwjs canonical"
assert_eq "$(canonical_log_path zui)"  "$SNAP_DATA/logs/zwavejs/z-ui_current.log"    "zui canonical"

# resolve_source: explicit false -> journal
assert_eq "$(resolve_source zui false)" "journal" "false -> journal"

# explicit true, no file yet -> file:<canonical>
assert_eq "$(resolve_source zwjs true)" "file:$SNAP_DATA/logs/zwavejs/zwavejs_current.log" "true,no file -> canonical"

# unset, no file -> journal
assert_eq "$(resolve_source zui '')" "journal" "unset,no file -> journal"

# unset, file exists in logs_dir -> file:<existing>
mkdir -p "$SNAP_DATA/logs/zwavejs"
: > "$SNAP_DATA/logs/zwavejs/zwavejs_current.log"
assert_eq "$(resolve_source zwjs '')" "file:$SNAP_DATA/logs/zwavejs/zwavejs_current.log" "unset,file -> file"

# tolerant: ZUI file in the parent $SNAP_DATA/logs is also found
: > "$SNAP_DATA/logs/z-ui_current.log"
assert_eq "$(resolve_source zui '')" "file:$SNAP_DATA/logs/z-ui_current.log" "unset,zui file in parent -> file"

assert_eq "$(stream_upper zui)"  "ZUI"  "upper zui"
assert_eq "$(stream_upper zwjs)" "ZWJS" "upper zwjs"
assert_eq "$(stream_color zui)"  "cyan" "color zui"
assert_eq "$(stream_color zwjs)" "green" "color zwjs"
assert_eq "$(journal_label zwjs)" "ZWJS" "journal label single"
assert_eq "$(journal_label zui zwjs)" "ZUI/ZWJS" "journal label combined"

# no-color prefix is plain
assert_eq "$(make_prefix ZUI cyan 0)" "[ZUI] " "plain prefix"
# colored prefix contains the escape and the label
assert_contains "$(make_prefix ZUI cyan 1)" "[ZUI]" "color prefix has label"
assert_contains "$(make_prefix ZUI cyan 1)" "$(printf '\033[36m')" "color prefix has cyan"

# prefix_lines prepends to each line
out="$(printf 'a\nb\n' | prefix_lines '[X] ')"
assert_eq "$out" "$(printf '[X] a\n[X] b')" "prefix_lines per line"

# follower_cmd builds tail / journalctl invocations
assert_contains "$(follower_cmd 'file:/var/log/zui_current.log' 20)" "tail -n 20 -F" "file -> tail"
assert_contains "$(follower_cmd 'file:/var/log/zui_current.log' 20)" "zui_current.log" "file -> path"
assert_contains "$(follower_cmd journal 20)" "journalctl -u" "journal -> journalctl"
assert_contains "$(follower_cmd journal 20)" "snap.zwave-js-ui.zwave-js-ui.service" "journal -> unit"

# sel_to_target maps the interactive picker's labels onto follower targets
assert_eq "$(sel_to_target all)"  "both" "picker: all -> both"
assert_eq "$(sel_to_target zui)"  "zui"  "picker: zui"
assert_eq "$(sel_to_target zwjs)" "zwjs" "picker: zwjs"

# ---- journald guard: a journald-backed stream is unreadable without log-observe ----
STUB_BIN="$HERE/fixtures/bin"   # instant-exit tail/journalctl so main's `wait` returns

# require_journal_access: no journald-backed streams -> no-op, plug irrelevant
( export TEST_CONNECTED_PLUGS=""; require_journal_access ) >/dev/null 2>&1
assert_status "$?" "0" "guard: no journald streams -> ok"

# connected -> passes silently
out="$( ( export TEST_CONNECTED_PLUGS="log-observe"; require_journal_access zui ) 2>&1 )"; st=$?
assert_status "$st" "0" "guard: plug connected -> ok"
assert_eq "$out" "" "guard: plug connected -> silent"

# journald-backed + plug missing -> dies with the why and the fix
out="$( ( export TEST_CONNECTED_PLUGS=""; require_journal_access zui zwjs ) 2>&1 )"; st=$?
assert_status "$st" "1" "guard: missing plug -> exit 1"
assert_contains "$out" "ZUI/ZWJS" "guard: names the journald streams"
assert_contains "$out" "journald" "guard: says why"
assert_contains "$out" "snap connect zwave-js-ui:log-observe" "guard: connect instructions"

# main: a followed journald stream w/o the plug kills the command BEFORE any
# follower launches — the file-backed stream must not have been tailed.
printf '%s' '{"gateway":{"logToFile":true},"zwave":{"logToFile":false}}' > "$SNAP_DATA/settings.json"
out="$( ( PATH="$STUB_BIN:$PATH"; export TAIL_SENTINEL="$SNAP_DATA/tail.ran"; export TEST_CONNECTED_PLUGS=""; main ) 2>&1 )"; st=$?
assert_status "$st" "1" "main: journald stream w/o plug -> exit 1"
assert_contains "$out" "snap connect zwave-js-ui:log-observe" "main: death message has the fix"
[ ! -e "$SNAP_DATA/tail.ran" ]; assert_status "$?" "0" "main: no follower launched before death"

# main: all streams journald-backed w/o plug -> same death
printf '%s' '{"gateway":{"logToFile":false},"zwave":{"logToFile":false}}' > "$SNAP_DATA/settings.json"
( PATH="$STUB_BIN:$PATH"; export TEST_CONNECTED_PLUGS=""; main ) >/dev/null 2>&1
assert_status "$?" "1" "main: all-journald w/o plug -> exit 1"

# main: a purely file-backed selection still works — only FOLLOWED streams gate
printf '%s' '{"gateway":{"logToFile":true},"zwave":{"logToFile":false}}' > "$SNAP_DATA/settings.json"
( PATH="$STUB_BIN:$PATH"; export TEST_CONNECTED_PLUGS=""; main zui ) >/dev/null 2>&1
assert_status "$?" "0" "main: file-backed selection unaffected by missing plug"

# main: journald-backed WITH the plug connected -> follows the journal
printf '%s' '{"gateway":{"logToFile":false},"zwave":{"logToFile":false}}' > "$SNAP_DATA/settings.json"
( PATH="$STUB_BIN:$PATH"; export TEST_CONNECTED_PLUGS="log-observe"; main ) >/dev/null 2>&1
assert_status "$?" "0" "main: connected -> follows journal"

# --- live-log viewer: less +F -R on a TTY, raw stream when piped ----------------
# logs_should_page: needs both a TTY on stdout AND less on PATH.
( PATH="$HERE/fixtures/bin:$PATH"; logs_should_page </dev/null >/dev/null 2>&1 ); \
    assert_status "$?" "1" "should_page: no TTY on stdout -> no"

# Real-pty integration: under script(1), stdout is a TTY; with stub less + stub
# followers, main must launch the pager as `less +F -R <fifo>` and exit cleanly.
if command -v script >/dev/null 2>&1; then
    LESS_LOG="$SNAP_DATA/less.argv"
    out="$(ROOT="$ROOT" SNAP="$SNAP" SNAP_DATA="$SNAP_DATA" LESS_LOG="$LESS_LOG" \
        STUB="$HERE/fixtures/bin" \
        timeout 15 script -qec '
            export PATH="$STUB:$PATH"
            printf "%s" "{\"gateway\":{\"logToFile\":true},\"zwave\":{\"logToFile\":true}}" > "$SNAP_DATA/settings.json"
            require_root() { :; }
            source "$ROOT/src/bin/logs"
            main zui
        ' /dev/null 2>&1; echo "rc=$?")"
    assert_contains "$(cat "$LESS_LOG" 2>/dev/null)" "+F -R" "viewer: TTY run launches less +F -R"
    # The viewport is a FIFO, which real less refuses without -f ("not a regular
    # file") — the pager MUST pass -f, or the whole command breaks on a TTY.
    assert_contains "$(cat "$LESS_LOG" 2>/dev/null)" "-f" "viewer: less gets -f (FIFO is non-regular)"
    case "$out" in
        *"is not a regular file"*) FAIL=$((FAIL+1)); echo "FAIL: viewer hit less 'not a regular file' (needs -f on the FIFO)" >&2 ;;
        *) PASS=$((PASS+1)) ;;
    esac
    assert_contains "$out" "rc=0" "viewer: paged run exits cleanly (no hang)"
fi

# Piped (no TTY): main must NOT invoke less — raw stream path.
LESS_LOG2="$SNAP_DATA/less2.argv"; : > "$LESS_LOG2"
printf '%s' '{"gateway":{"logToFile":true},"zwave":{"logToFile":false}}' > "$SNAP_DATA/settings.json"
( PATH="$HERE/fixtures/bin:$PATH"; LESS_LOG="$LESS_LOG2"; require_root() { :; }
  TAIL_SENTINEL="$SNAP_DATA/t.ran"; export TAIL_SENTINEL
  timeout 10 bash -c 'source "$ROOT/src/bin/logs"; require_root() { :; }; main zui' </dev/null >/dev/null 2>&1 )
assert_eq "$(cat "$LESS_LOG2" 2>/dev/null)" "" "viewer: piped run does NOT invoke less"

# --- viewer hint: a key legend leads the paged buffer (discoverable on scroll-up) ---
h="$(use_color=1 log_viewer_hint)"
assert_contains "$h" "Ctrl-C" "hint: documents Ctrl-C (scroll back)"
assert_contains "$h" "F"      "hint: documents F (resume follow)"
assert_contains "$h" "q"      "hint: documents q (quit)"
# coloured on a TTY, plain otherwise
case "$h" in *$'\033'*) PASS=$((PASS+1)) ;; *) FAIL=$((FAIL+1)); echo "FAIL: TTY hint not coloured" >&2 ;; esac
hp="$(use_color=0 log_viewer_hint)"
case "$hp" in *$'\033'*) FAIL=$((FAIL+1)); echo "FAIL: plain hint has ANSI" >&2 ;; *) PASS=$((PASS+1)) ;; esac

finish
