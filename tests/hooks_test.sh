#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
export SNAP="$ROOT/src" SNAP_NAME=zwave-js-ui
T="$(mktemp -d "$ROOT/tests/.tmp.XXXXXX")"; trap 'rm -rf "$T"' EXIT     # under the checkout: the yq snap cannot read /tmp
export SNAP_DATA="$T/data" SNAP_COMMON="$T/common" SNAPCTL_STATE="$T/state" SNAPCTL_LOG="$T/snapctl.log" LOGGER_LOG="$T/logger.log"
mkdir -p "$SNAP_DATA" "$SNAP_COMMON" "$SNAPCTL_STATE" "$T/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$LOGGER_LOG"\n' > "$T/bin/logger"; chmod +x "$T/bin/logger"   # hooks run DAEMONIZED: lprint -> logger
export PATH="$T/bin:$HERE/fixtures/bin:$PATH"
reset_state() { rm -rf "$SNAPCTL_STATE"; mkdir -p "$SNAPCTL_STATE"; : > "$SNAPCTL_LOG"; : > "$LOGGER_LOG"; rm -f "$SNAP_COMMON/.daemon-config.sha256"
                for kv in "$@"; do printf '%s' "${kv#*=}" > "$SNAPCTL_STATE/${kv%%=*}"; done; }
run_hook()   { bash "$ROOT/src/hooks/$1" >"$T/stdout" 2>"$T/stderr"; }
digest_now() { ( source "$ROOT/src/helper/catalog"; daemon_config_digest ); }
VALID=(server.port=8091 server.ssl=false session.cookie-secure=false)

reset_state "${VALID[@]}"; run_hook configure; assert_status "$?" 0 "C1: valid config -> rc 0"
assert_contains "$(cat "$SNAPCTL_LOG")" "restart zwave-js-ui.zwave-js-ui" "C1: active + no digest file -> restart (timer line is inactive)"
assert_contains "$(cat "$LOGGER_LOG")" "Restarting zwave-js-ui.zwave-js-ui" "C1: restart notice goes to syslog"; assert_eq "$(cat "$T/stdout")" "" "C1: configure prints nothing on stdout (DAEMONIZED)"
reset_state "${VALID[@]}"; SNAPCTL_MAIN_STATE=inactive run_hook configure
assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C2: inactive daemon -> no restart"
reset_state "${VALID[@]}"; run_hook configure; digest_now > "$SNAP_COMMON/.daemon-config.sha256"; : > "$SNAPCTL_LOG"
run_hook configure; assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C3: equal digest (refresh case) -> no restart"
printf 'file:///x' > "$SNAPCTL_STATE/backup.target"; run_hook configure; assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C3: backup-only change -> no restart"
printf '10.0.0.9' > "$SNAPCTL_STATE/server.host"; run_hook configure; assert_contains "$(cat "$SNAPCTL_LOG")" "restart zwave-js-ui.zwave-js-ui" "C3: daemon key change -> restart"
reset_state server.ssl=false session.cookie-secure=false; run_hook configure; assert_status "$?" 0 "C4: unset server.port -> rc 0 (seeded, A3)"
assert_eq "$(cat "$SNAPCTL_STATE/server.port")" "8091" "C4: server.port seeded to 8091"
for bad in "server.port=abc|!! server.port must be a whole number, got abc" "server.port=70000|a port number 1-65535" "server.ssl=yes|!! server.ssl must be true or false, got yes" "backup.dir=relative|an absolute path" "backup.retention=x|a whole number"; do
    kv="${bad%%|*}"; msg="${bad#*|}"; reset_state "${VALID[@]}" "$kv"; run_hook configure; rc=$?
    assert_status "$rc" 1 "C5: $kv rejected"; assert_contains "$(cat "$T/stderr")" "$msg" "C5: $kv message"
    assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C5: $kv -> no restart"
    assert_eq "$(cat "$T/stdout")" "" "C5: $kv -> nothing on stdout"; assert_eq "$(grep -vc '^!! ' "$T/stderr")" "0" "C5: $kv -> stderr holds only the !! line"
done
reset_state "${VALID[@]}" session.secret=SUPERSECRETVALUE; run_hook configure
assert_not_contains "$(cat "$LOGGER_LOG")$(cat "$T/stdout")$(cat "$T/stderr")" "SUPERSECRETVALUE" "C6: secret never logged"
reset_state "${VALID[@]}" "mqtt.name=my client=1"; run_hook configure; assert_status "$?" 0 "C7: value with space and = passes"
assert_eq "$(cat "$SNAPCTL_STATE/mqtt.name")" "my client=1" "C7: value untouched"
reset_state "${VALID[@]}"; SNAPCTL_SERVICES_FAIL=1 run_hook configure; assert_status "$?" 0 "C8: services unknown -> rc 0"
assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C8: services unknown -> no restart"
reset_state "${VALID[@]}"; printf 'garbage\n' > "$SNAP_COMMON/.daemon-config.sha256"; run_hook configure
assert_contains "$(cat "$SNAPCTL_LOG")" "restart zwave-js-ui.zwave-js-ui" "C9: corrupt digest file reads as changed -> restart"
reset_state "${VALID[@]}" session.secret=6ba7b810-9dad-11d1-80b4-00c04fd430c8; run_hook post-refresh
assert_contains "$(cat "$SNAPCTL_LOG")" "unset session.secret" "P1: post-refresh removes the seeded v1 UUID"
assert_eq "$(grep -c "^set session.secret" "$SNAPCTL_LOG")" "0" "P1: nothing re-seeds it"
assert_not_contains "$(cat "$LOGGER_LOG")" "6ba7b810" "P1: value not in syslog"
_rc=0; [ -e "$SNAP_COMMON/.session-secret-migrated" ] || _rc=1; assert_status "$_rc" 0 "P1: migration marker written"
V1=6ba7b810-9dad-11d1-80b4-00c04fd430c8
reset_state "${VALID[@]}" session.secret=$V1; run_hook post-refresh   # marker from P1 present
assert_not_contains "$(cat "$SNAPCTL_LOG")" "unset session.secret" "P3: marker present -> a deliberately set v1 UUID is kept"
assert_eq "$(cat "$SNAPCTL_STATE/session.secret")" "$V1" "P3: value untouched"
rm -f "$SNAP_COMMON/.session-secret-migrated"; reset_state "${VALID[@]}" session.secret=$V1; SNAPCTL_UNSET_FAIL=1 run_hook post-refresh
assert_not_contains "$(cat "$LOGGER_LOG")" "removed the generated" "P4: failed unset -> no 'removed' line"
# P2: values the old hook accepted but validate_config now rejects must not fail the refresh
reset_state "${VALID[@]}" server.force-disable-ssl=YESPLEASE backup.retention=-5; run_hook post-refresh; assert_status "$?" 0 "P2: post-refresh with invalid stored values -> rc 0"
assert_eq "$(cat "$SNAPCTL_STATE/server.force-disable-ssl" 2>/dev/null)" "false" "P2: invalid server.force-disable-ssl unset, then re-seeded to its default"
_rc=0; [ ! -e "$SNAPCTL_STATE/backup.retention" ] || _rc=1; assert_status "$_rc" 0 "P2: invalid backup.retention unset (run-time default applies)"
assert_contains "$(cat "$LOGGER_LOG")" "server.force-disable-ssl: removed invalid value; the default applies" "P2: notice for server.force-disable-ssl"
assert_contains "$(cat "$LOGGER_LOG")" "backup.retention: removed invalid value; the default applies" "P2: notice for backup.retention"
p2all="$(cat "$LOGGER_LOG" "$T/stdout" "$T/stderr")"; assert_not_contains "$p2all" "YESPLEASE" "P2: bool value never printed"; assert_not_contains "$p2all" "-5" "P2: int value never printed"
run_hook configure; assert_status "$?" 0 "P2: the configure run that follows passes"
reset_state "${VALID[@]}"; mkdir -p "$SNAP_DATA/.ext-config/devices"; : > "$SNAP_DATA/.ext-config/devices/index.json"
_rc=0; run_hook post-refresh; [ ! -e "$SNAP_DATA/.ext-config/devices/index.json" ] || _rc=1; assert_status "$_rc" 0 "A9: index.json removed"
assert_not_contains "$(cat "$T/stderr")" "null byte" "A9: no bash warning"
printf '{"mqtt":{"host":"x"}}' > "$SNAP_DATA/settings.json"; cp "$SNAP_DATA/settings.json" "$T/ref.json"; : > "$LOGGER_LOG"
run_hook post-refresh; cmp -s "$SNAP_DATA/settings.json" "$T/ref.json"; assert_status "$?" 0 "A8: settings.json without the key is untouched"
assert_not_contains "$(cat "$LOGGER_LOG")" "not writable" "A8: no misleading log line"
mkdir -p "$T/x43/prio"; printf '{"zwave":{"deviceConfigPriorityDir":"%s/x42/prio"}}' "$T" > "$T/x43/settings.json"
SNAP_DATA="$T/x43" run_hook post-refresh; assert_eq "$(yq -r '.zwave.deviceConfigPriorityDir' "$T/x43/settings.json")" "$T/x43/prio" "A8: stale revision path still rewritten"
reset_state "${VALID[@]}" server.prot=SEKRIT; run_hook configure; assert_status "$?" 1 "U2: unknown key rejected"
assert_contains "$(cat "$T/stderr")" '!! unknown setting "server.prot" — remove it with: sudo snap unset zwave-js-ui server.prot. Known settings: zwave-js-ui.help' "U2: message"
assert_not_contains "$(cat "$T/stderr")$(cat "$LOGGER_LOG")" "SEKRIT" "U2: value never shown"; assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "U2: no restart"
reset_state "${VALID[@]}" mqtt.host=broker; run_hook configure; assert_contains "$(cat "$T/stderr")" "MQTT broker settings live in settings.json — sudo zwave-js-ui.ui → MQTT broker" "U3: mqtt hint"
reset_state "${VALID[@]}" server.prot=SEKRIT; run_hook post-refresh; assert_status "$?" 0 "U6: post-refresh rc 0"
assert_contains "$(cat "$SNAPCTL_LOG")" "unset server.prot" "U6: stray key unset at refresh"; assert_contains "$(cat "$LOGGER_LOG")" "server.prot: removed unknown setting" "U6: notice"; assert_not_contains "$(cat "$LOGGER_LOG")" "SEKRIT" "U6: value not logged"
: > "$SNAPCTL_LOG"; run_hook configure; assert_status "$?" 0 "U6: configure passes after the refresh cleaned up"
reset_state "${VALID[@]}"; SNAPCTL_GET_D_RAW='garbage' run_hook configure; assert_status "$?" 0 "U4: unreadable get -d does not fail the hook"
reset_state "${VALID[@]}" foo.bar=1; run_hook configure; assert_status "$?" 0 "U7: key under an unknown namespace is undetectable by design"
run_hook post-refresh; assert_not_contains "$(cat "$SNAPCTL_LOG")" "unset foo.bar" "U7: sanitizer leaves it alone"
finish
