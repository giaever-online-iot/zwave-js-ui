#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT

# snapctl stub: `snapctl get k` reads $SNAPCTL_<k with . and - as _>; `services` is canned.
snapctl() {
    case "$1" in
        get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
        services) printf 'Service  Startup  Current  Notes\nzwave-js-ui.zwave-js-ui  enabled  active  -\n' ;;
        *) : ;;
    esac
}

# shellcheck source=/dev/null
source "$ROOT/src/bin/help"     # sources stub functions + real ui/catalog via $SNAP shims

# --- catalog -----------------------------------------------------------------
assert_contains "$(catalog_keys)" "server.port"   "catalog has server.port"
assert_contains "$(catalog_keys)" "backup.target" "catalog has backup.target"
settings_catalog | awk -F'\t' 'NF != 4 { exit 1 }'
assert_status "$?" "0" "every catalog row has exactly 4 fields"

# --- help helpers --------------------------------------------------------------
assert_eq "$(snap_version)" "v0.0.0-test" "version from meta/snap.yaml"
assert_eq "$(service_state)" "enabled active" "service state parsed"

# shellcheck disable=SC2034  # SNAPCTL_* vars are read via eval in the snapctl() stub above
SNAPCTL_server_host="10.0.0.7"
assert_contains "$(settings_rows)" "$(printf 'server.host\t10.0.0.7')" "row shows current value"
# shellcheck disable=SC2034
SNAPCTL_session_secret="topsecret"
rows="$(settings_rows)"
assert_contains "$rows" "(hidden)" "session.secret is masked"
case "$rows" in *topsecret*) FAIL=$((FAIL+1)); echo "FAIL: secret leaked" >&2 ;; *) PASS=$((PASS+1)) ;; esac
assert_contains "$(SNAPCTL_server_port='' settings_rows)" "(unset)" "unset value rendered as (unset)"

# --- main renders (plain ctx) ---------------------------------------------------
out="$(plugs_connected() { :; }; main)"
assert_contains "$out" "== zwave-js-ui · v0.0.0-test · enabled active ==" "header line"
assert_contains "$out" "server.host" "settings table present"
assert_contains "$out" "snap set zwave-js-ui" "set-hint present"
assert_contains "$out" "zwave-js-ui.logs" "commands table present"
assert_contains "$out" "serial-port" "serial footnote present"

# --- drift guard ----------------------------------------------------------------
# The catalog duplicates defaults that test_default_config (helper/functions)
# seeds; this converts the catalog's "keep in sync" comment into a CI check.
# Deliberately only the keys with literal defaults — mqtt.name/session.* use
# placeholder defaults ("(unset)", "(generated)") that have no literal match.
for key in server.host server.port server.ssl timezone; do
    def="$(settings_catalog | awk -F'\t' -v k="$key" '$1 == k { print $3 }')"
    grep -Eq "testnset_config \"$key\" \"?$def\"?" "$ROOT/src/helper/functions"
    assert_status "$?" "0" "catalog default for $key matches test_default_config"
done

# --- width-aware settings layout ------------------------------------------------
unset NO_COLOR; export TERM=xterm-256color   # let UI_ASSUME_TTY reach styled below

# table_width estimates the bordered-table width: sum(col widths) + 3/col + 1.
assert_eq "$(printf 'aa\tbbbb\n' | table_width)" "13" "table_width = sumcols + 3/col + 1"

# settings_stack: one record per setting; default shown inline when the line fits.
st="$(printf 'server.host\t0.0.0.0\t0.0.0.0\tIP address the web UI binds to\n' | UI_COLS=120 settings_stack)"
assert_contains "$st" "server.host = 0.0.0.0"  "stack: key = value"
assert_contains "$st" "[default: 0.0.0.0]"     "stack: default shown inline"
assert_contains "$st" "      IP address the web UI binds to" "stack: description indented"

# A value too long for the line pushes [default: …] onto its own indented line.
lng="$(printf 'backup.encrypt-key\t0E32DAF912C2645073A3DFFA8956E92F1A70C779\t(unset)\tGPG fingerprint backups are encrypted to\n' | UI_COLS=50 settings_stack)"
assert_contains "$lng" "$(printf 'backup.encrypt-key = 0E32DAF912C2645073A3DFFA8956E92F1A70C779\n      [default: (unset)]')" "stack: long value wraps default onto its own line"

# Dispatch: styled + too-narrow -> stacked (no gum [table]); styled + wide -> gum table.
row="$(printf 'server.host\t0.0.0.0\t0.0.0.0\tIP address the web UI binds to\n')"
narrow="$(printf '%s\n' "$row" | UI_ASSUME_TTY=1 UI_COLS=40 settings_render)"
assert_contains "$narrow" "server.host = 0.0.0.0" "narrow styled -> stacked"
case "$narrow" in *'[table]'*) FAIL=$((FAIL+1)); echo "FAIL: narrow styled used gum table" >&2 ;; *) PASS=$((PASS+1)) ;; esac
wide="$(printf '%s\n' "$row" | UI_ASSUME_TTY=1 UI_COLS=999 settings_render)"
assert_contains "$wide" "[table]" "wide styled -> gum table"

# Plain context never stacks (keeps the aligned table, zero ANSI), whatever the width.
plainout="$(printf '%s\n' "$row" | NO_COLOR=1 UI_COLS=40 settings_render)"
assert_contains "$plainout" "server.host" "plain settings_render shows the row"
case "$plainout" in *'[default:'*) FAIL=$((FAIL+1)); echo "FAIL: plain ctx stacked unexpectedly" >&2 ;; *) PASS=$((PASS+1)) ;; esac

# Commands list is width-aware too: narrow styled stacks command over description.
crow="$(printf '%s\tfollow live logs (merged by default)\n' "$SNAP_NAME.logs [zui|zwjs]")"
cnarrow="$(printf '%s\n' "$crow" | UI_ASSUME_TTY=1 UI_COLS=20 commands_render)"
assert_contains "$cnarrow" "$SNAP_NAME.logs" "commands narrow styled -> stacked"
case "$cnarrow" in *'[table]'*) FAIL=$((FAIL+1)); echo "FAIL: commands narrow used gum table" >&2 ;; *) PASS=$((PASS+1)) ;; esac

# main() wires it together: narrow styled run stacks the settings.
mn="$(export UI_ASSUME_TTY=1 UI_COLS=40; plugs_connected() { :; }; main)"
assert_contains "$mn" "server.host = 10.0.0.7" "main: narrow styled stacks settings (live value)"

finish
