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

finish
