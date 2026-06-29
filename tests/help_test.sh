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
# every catalog row has exactly 5 TAB fields (key type default description scope)
settings_catalog | awk -F'\t' 'NF != 5 { exit 1 }'
assert_status "$?" "0" "every catalog row has exactly 5 fields"
# scope is common|advanced; type includes the secret pseudo-type
settings_catalog | awk -F'\t' '$5 != "common" && $5 != "advanced" { exit 1 }'
assert_status "$?" "0" "every row scope is common|advanced"
assert_eq "$(catalog_row session.secret | cut -f2)" "secret" "session.secret is type=secret"
assert_contains "$(catalog_keys)" "zwave.serial-port" "catalog has zwave.serial-port"
# help table shows ONLY common keys — advanced zwave keys are omitted
assert_contains "$(settings_rows)" "server.port"        "help table includes a common key"
case "$(settings_rows)" in *zwave.serial-port*) FAIL=$((FAIL+1)); echo "FAIL: advanced key leaked into help" >&2 ;; *) PASS=$((PASS+1)) ;; esac
# catalog_is_secret
( catalog_is_secret session.secret ); assert_status "$?" "0" "catalog_is_secret: session.secret -> yes"
( catalog_is_secret server.port );    assert_status "$?" "1" "catalog_is_secret: server.port -> no"

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
assert_contains "$(commands_rows)" "$SNAP_NAME.ui" "help lists the ui command"
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

# --- help renders via the width-fit ui_table (stacking lives in the library now) ---
unset NO_COLOR; export TERM=xterm-256color   # let UI_ASSUME_TTY reach styled
# shellcheck disable=SC2034
SNAPCTL_server_host="10.0.0.7"
mn="$(export UI_ASSUME_TTY=1 UI_COLS=40; plugs_connected() { :; }; main)"
assert_contains "$mn" "server.host"            "main: narrow styled shows the setting"
assert_contains "$mn" "    value: 10.0.0.7"    "main: narrow styled uses the generic stacked form"
mw="$(export UI_ASSUME_TTY=1 UI_COLS=999; plugs_connected() { :; }; main)"
assert_contains "$mw" "[table]"                "main: wide styled uses the gum table"

finish
