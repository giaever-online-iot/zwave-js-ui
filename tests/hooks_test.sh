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
reset_state "${VALID[@]}"; mkdir -p "$SNAP_DATA/.ext-config/devices"; : > "$SNAP_DATA/.ext-config/devices/index.json"
run_hook post-refresh; [ ! -e "$SNAP_DATA/.ext-config/devices/index.json" ]; assert_status "$?" 0 "A9: index.json removed"
assert_not_contains "$(cat "$T/stderr")" "null byte" "A9: no bash warning"
printf '{"mqtt":{"host":"x"}}' > "$SNAP_DATA/settings.json"; cp "$SNAP_DATA/settings.json" "$T/ref.json"; : > "$LOGGER_LOG"
run_hook post-refresh; cmp -s "$SNAP_DATA/settings.json" "$T/ref.json"; assert_status "$?" 0 "A8: settings.json without the key is untouched"
assert_not_contains "$(cat "$LOGGER_LOG")" "not writable" "A8: no misleading log line"
mkdir -p "$T/x43/prio"; printf '{"zwave":{"deviceConfigPriorityDir":"%s/x42/prio"}}' "$T" > "$T/x43/settings.json"
SNAP_DATA="$T/x43" run_hook post-refresh; assert_eq "$(yq -r '.zwave.deviceConfigPriorityDir' "$T/x43/settings.json")" "$T/x43/prio" "A8: stale revision path still rewritten"
finish
