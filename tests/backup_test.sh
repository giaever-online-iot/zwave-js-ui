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

finish
