#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
SNAP_COMMON="$(mktemp -d)"; export SNAP_COMMON
trap 'rm -rf "$SNAP_DATA" "$SNAP_COMMON"' EXIT

# Test stub for snapctl: `snapctl get backup.foo-bar` reads $SNAPCTL_backup_foo_bar.
snapctl() { case "$1" in get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;; *) : ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/src/bin/backup"          # backup's own helpers (+ stub functions via $SNAP); main is guarded
# shellcheck source=/dev/null
source "$ROOT/src/helper/functions"    # REAL shared helpers (e.g. backup_dir), resolved against the snapctl stub above

# --- tests appended by later tasks ---

assert_eq "$(backup_dir)" "$SNAP_DATA/backups" "default backup dir"
assert_eq "$(SNAPCTL_backup_dir=/srv/zui-backups backup_dir)" "/srv/zui-backups" "configured backup dir"

assert_eq "$(parse_sub '')"        "backup"  "no arg -> backup"
assert_eq "$(parse_sub 'backup')"  "backup"  "backup"
assert_eq "$(parse_sub 'restore')" "restore" "restore"
assert_eq "$(parse_sub 'list')"    "list"    "list"
assert_eq "$(parse_sub 'status')"  "status"  "status"
parse_sub bogus >/dev/null 2>&1; assert_status "$?" "2" "unknown -> 2"

assert_eq "$(SNAPCTL_backup_encrypt_key=ABC123 encryption_args)" "--encrypt-key ABC123" "enc key"
assert_eq "$(SNAPCTL_backup_encrypt=false encryption_args)"      "--no-encryption"       "no-encryption opt-out"
encryption_args >/dev/null 2>&1; assert_status "$?" "2" "neither set -> refuse"
assert_eq "$(SNAPCTL_backup_target=file:///b cfg target)" "file:///b" "cfg reads target"

src="$SNAP_DATA/backups"
b="$(SNAPCTL_backup_encrypt_key=KEY SNAPCTL_backup_target=file:///tgt SNAPCTL_backup_full_if_older_than=7D build_backup_cmd "$src")"
assert_contains "$b" "duplicity"               "backup: duplicity"
assert_contains "$b" "--encrypt-key KEY"       "backup: enc key"
assert_contains "$b" "--full-if-older-than 7D" "backup: full-if-older"
assert_contains "$b" "--archive-dir"           "backup: archive-dir"
assert_contains "$b" "file:///tgt"             "backup: target"
r="$(SNAPCTL_backup_encrypt_key=KEY SNAPCTL_backup_target=file:///tgt build_restore_cmd "$SNAP_DATA/restore")"
assert_contains "$r" "duplicity restore"       "restore: verb"
assert_contains "$r" "file:///tgt"             "restore: target"
l="$(SNAPCTL_backup_target=file:///tgt build_list_cmd)"
assert_contains "$l" "collection-status"       "list: verb"

finish
