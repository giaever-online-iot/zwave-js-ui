#!/usr/bin/env bash
# Unit tests for src/helper/catalog: the six-column catalog, field helpers,
# validate_config and the daemon config digest.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"
SNAP_COMMON="$(mktemp -d)"; export SNAP_COMMON
snapctl() { case "$1 ${2:-}" in "get -d") [ $# -gt 2 ] || return 1; printf '%s' "${SNAPCTL_D:-{}}" ;; get*) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;; *) : ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/src/helper/catalog"

settings_catalog | awk -F'\t' 'NF != 6 { exit 1 }';                       assert_status "$?" 0 "every row has 6 fields"
settings_catalog | awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i=="") exit 1 }'; assert_status "$?" 0 "no empty field in any row"
settings_catalog | awk -F'\t' '$6!="daemon" && $6!="backup" { exit 1 }';   assert_status "$?" 0 "applies is daemon|backup"
assert_eq "$(catalog_field server.port 2)" "int"      "catalog_field: type"
assert_eq "$(catalog_field server.port 6)" "daemon"   "catalog_field: server.port applies daemon"
assert_eq "$(catalog_field backup.target 6)" "backup" "catalog_field: backup.target applies backup"
assert_eq "$(catalog_field backup.dir 6)" "daemon"    "catalog_field: backup.dir applies daemon (BACKUPS_DIR)"
assert_eq "$(catalog_field zwave.serial-port 5)" "advanced" "catalog_field: scope survives (A6)"
_rc=0; [ -n "$(catalog_field zwave.serial-port 4)" ] || _rc=1; assert_status "$_rc" 0 "zwave.serial-port has a description (A6)"
assert_eq "$(catalog_field nope 2)" "" "catalog_field: unknown key -> empty"
assert_eq "$(catalog_keys_for backup)" "$(printf 'backup.target\nbackup.encrypt\nbackup.encrypt-key\nbackup.full-if-older-than\nbackup.retention')" "keys_for backup"
assert_eq "$(catalog_keys_for daemon | grep -c .)" "16" "keys_for daemon: 8 common + backup.dir + 7 zwave"
v() { validate_config "$1" "$2" 2>"$SNAP_COMMON/err"; echo "$?"; }   # prints rc; message in err
assert_eq "$(v server.port 8091)" 0 "port ok";   assert_eq "$(v server.port 65535)" 0 "port max ok"
assert_eq "$(v server.port abc)" 1 "port abc";   assert_contains "$(cat "$SNAP_COMMON/err")" "!! server.port must be a whole number, got abc" "port abc message"
assert_eq "$(v server.port 0)" 1 "port 0";       assert_contains "$(cat "$SNAP_COMMON/err")" "a port number 1-65535" "port range message"
assert_eq "$(v server.port 70000)" 1 "port 70000"
assert_eq "$(v server.port 99999999999999999999)" 1 "port too long for [ -ge ]"
assert_eq "$(cat "$SNAP_COMMON/err")" "!! server.port must be a port number 1-65535, got 99999999999999999999" "long port: stderr is exactly the !! line (no bash [: error)"
assert_eq "$(v server.port 000080)" 1 "port with 6 digits rejected (length guard)"
assert_eq "$(v server.ssl yes)" 1 "bool yes";    assert_contains "$(cat "$SNAP_COMMON/err")" "!! server.ssl must be true or false, got yes" "bool message"
assert_eq "$(v server.ssl false)" 0 "bool ok";   assert_eq "$(v backup.encrypt false)" 0 "backup.encrypt bool ok"
assert_eq "$(v backup.retention 3)" 0 "retention ok"; assert_eq "$(v backup.retention x)" 1 "retention x"
assert_eq "$(v backup.dir relative/x)" 1 "dir rel"; assert_contains "$(cat "$SNAP_COMMON/err")" "!! backup.dir must be an absolute path, got relative/x" "dir message"
assert_eq "$(v backup.dir /srv/x)" 0 "dir abs ok"; assert_eq "$(v server.port '')" 0 "empty = default";  assert_eq "$(v timezone 'Any/Thing')" 0 "string ok"; assert_eq "$(v not.a.key 1)" 0 "unknown key passes"
assert_eq "$(validate_config server.port abc 2>&1 >/dev/null | wc -l)" 1 "message on stderr"
assert_eq "$(validate_config server.port abc 2>/dev/null)" "" "nothing on stdout"
d1="$(SNAPCTL_server_host=10.0.0.7 daemon_config_digest)"
_rc=0; [[ "$d1" =~ ^[0-9a-f]{64}$ ]] || _rc=1; assert_status "$_rc" 0 "digest is sha256 hex"
assert_eq "$(SNAPCTL_server_host=10.0.0.7 daemon_config_digest)" "$d1" "digest deterministic"
_rc=0; [ "$(SNAPCTL_server_host=10.0.0.8 daemon_config_digest)" != "$d1" ] || _rc=1; assert_status "$_rc" 0 "digest changes with a daemon key"
assert_eq "$(SNAPCTL_server_host=10.0.0.7 SNAPCTL_backup_target=file:///x daemon_config_digest)" "$d1" "digest ignores backup-only keys"
assert_eq "$(daemon_digest_file)" "$SNAP_COMMON/.daemon-config.sha256" "digest file path"
assert_eq "$(catalog_field session.secret 3)" "(unset)" "session.secret default is unset (D4)"
assert_eq "$(v backup.target sftp://user@nas/zui)" 0 "D7: sftp URL ok"; assert_eq "$(v backup.target file:///mnt/usb/zui)" 0 "D7: file URL ok"
assert_eq "$(v backup.target S3://bucket/x)" 0 "D7: upper-case scheme ok (duplicity accepts)"
assert_eq "$(v backup.target sftp:/nas/zui)" 1 "D7: missing slash rejected"; assert_contains "$(cat "$SNAP_COMMON/err")" "!! backup.target must be a duplicity URL like sftp://user@nas/zui, s3://bucket/path or file:///mnt/usb/zui, got sftp:/nas/zui" "D7: message"
assert_eq "$(v backup.target /mnt/usb/zui)" 1 "D7: bare path rejected"; assert_eq "$(v backup.full-if-older-than 1D12h)" 0 "D7: full-if-older-than unchecked"
_rc=0; [ "$(catalog_field session.secret 4 | wc -c)" -le 64 ] || _rc=1; assert_status "$_rc" 0 "polish: session.secret description ≤ 63 chars"
SNAPCTL_D='{"server":{"host":"x","prot":"1"},"mqtt":{"host":"y","name":"a.b=c d"},"timezone":"Europe/Oslo"}'
assert_eq "$(unknown_config_keys | sort | tr '\n' ' ')" "mqtt.host server.prot " "U1: unknown leaf paths only"
_rc=0; snapctl get -d >/dev/null 2>&1 || _rc=1; assert_status "$_rc" 1 "U8: stub refuses get -d without keys, like snapd"
assert_eq "$(SNAPCTL_D='{}' unknown_config_keys)" "" "U4: empty config -> nothing"; assert_eq "$(SNAPCTL_D='not json' unknown_config_keys 2>/dev/null; echo "rc=$?")" "rc=0" "U4: garbage -> nothing, rc 0"
assert_eq "$(SNAPCTL_D='{"mqtt":{"name":"a.b=c d"}}' unknown_config_keys)" "" "U5: dotted VALUE is not a key"
finish
