#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

# Source the script under test with a stubbed snap runtime.
export SNAP="$HERE/fixtures"
export SNAP_DATA="$(mktemp -d)"
trap 'rm -rf "$SNAP_DATA"' EXIT
# shellcheck source=/dev/null
source "$ROOT/src/bin/logs"

# --- tests appended by later tasks ---
assert_eq "$(normalize_target '')"      "both" "empty -> both"
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

finish
