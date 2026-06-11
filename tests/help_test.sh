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

finish
