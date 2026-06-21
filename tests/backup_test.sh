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
assert_eq "$(parse_sub 'import-key')" "import-key" "import-key"
parse_sub bogus >/dev/null 2>&1; assert_status "$?" "2" "unknown -> 2"

assert_eq "$(SNAPCTL_backup_encrypt_key=ABC123 encryption_args)" "--encrypt-key ABC123" "enc key"
assert_eq "$(SNAPCTL_backup_encrypt=false encryption_args)"      "--no-encryption"       "no-encryption opt-out"
encryption_args >/dev/null 2>&1; assert_status "$?" "2" "neither set -> refuse"
assert_eq "$(SNAPCTL_backup_target=file:///b cfg target)" "file:///b" "cfg reads target"

src="$SNAP_DATA/backups"
b="$(SNAPCTL_backup_encrypt_key=KEY SNAPCTL_backup_target=file:///tgt SNAPCTL_backup_full_if_older_than=7D build_backup_cmd "$src")"
assert_contains "$b" "$(printf '%q' "$SNAP/usr/bin/python3") -m duplicity backup " "backup: staged python -m, explicit action"
assert_contains "$b" "--encrypt-key KEY"       "backup: enc key"
assert_contains "$b" "--full-if-older-than 7D" "backup: full-if-older"
assert_contains "$b" "--archive-dir"           "backup: archive-dir"
assert_contains "$b" "file:///tgt"             "backup: target"
assert_contains "$b" "--allow-source-mismatch" "backup: allow-source-mismatch (revision path)"
r="$(SNAPCTL_backup_encrypt_key=KEY SNAPCTL_backup_target=file:///tgt build_restore_cmd "$SNAP_DATA/restore")"
assert_contains "$r" "$(printf '%q' "$SNAP/usr/bin/python3") -m duplicity restore " "restore: staged python -m, restore verb"
assert_contains "$r" "file:///tgt"             "restore: target"
assert_contains "$r" "--gpg-options=--no-autostart" "restore: no-autostart gpg-option"
l="$(SNAPCTL_backup_encrypt_key=KEY SNAPCTL_backup_target=file:///tgt build_list_cmd)"
assert_contains "$l" "$(printf '%q' "$SNAP/usr/bin/python3") -m duplicity collection-status " "list: staged python -m, collection-status verb"
# shellcheck disable=SC2034  # DUP_PY is consumed inside build_backup_cmd (sourced)
hb="$( (DUP_PY='/tmp/evil path/python3'; SNAPCTL_backup_encrypt_key=KEY SNAPCTL_backup_target=file:///tgt build_backup_cmd "$src") )"
assert_contains "$hb" "/tmp/evil\\ path/python3 -m duplicity backup " "backup: interpreter %q-escaped (hostile path)"

rm -rf "$SNAP_DATA/backups"
has_backups; assert_status "$?" "1" "absent dir -> no backups"
mkdir -p "$SNAP_DATA/backups"
has_backups; assert_status "$?" "1" "empty dir -> no backups"
: > "$SNAP_DATA/backups/x"
has_backups; assert_status "$?" "0" "non-empty -> has backups"

rt="$(SNAPCTL_backup_encrypt_key=KEY SNAPCTL_backup_target=file:///tgt build_restore_cmd "$SNAP_DATA/restore" 2026-01-02)"
assert_contains "$rt" "--time 2026-01-02" "restore: time arg quoted"

# --- key-management: parse_sub + usage ---
assert_eq "$(parse_sub 'pick-key')"   "pick-key"   "pick-key"
assert_eq "$(parse_sub 'list-keys')"  "list-keys"  "list-keys"
assert_eq "$(parse_sub 'create-key')" "create-key" "create-key"
assert_eq "$(parse_sub 'export-key')" "export-key" "export-key"
parse_sub 'pick-key'   >/dev/null; assert_status "$?" "0" "pick-key -> status 0"
parse_sub 'create-key' >/dev/null; assert_status "$?" "0" "create-key -> status 0"
parse_sub 'export-key' >/dev/null; assert_status "$?" "0" "export-key -> status 0"

SNAP_NAME="${SNAP_NAME:-zwave-js-ui}"   # usage heredoc references ${SNAP_NAME}; set under `set -u`
_u="$(usage)"
assert_contains "$_u" "pick-key"   "usage lists pick-key"
assert_contains "$_u" "list-keys"  "usage lists list-keys"
assert_contains "$_u" "create-key" "usage lists create-key"
assert_contains "$_u" "export-key" "usage lists export-key"

# --- key-management: host keyring path ---
assert_eq "$(SNAP_REAL_HOME=/home/u gpg_host_homedir)" "/home/u/.gnupg" "host homedir from SNAP_REAL_HOME"
assert_eq "$(unset SNAP_REAL_HOME; HOME=/home/fallback gpg_host_homedir)" "/home/fallback/.gnupg" "host homedir fallback to HOME"

# --- key-management: pubkey list parser ---
_colons='pub:u:255:22:KEYID:1730000000:::-:::scESC::::::ed25519:::0:
fpr:::::::::0E32DAF912C2645073A3DFFA8956E92F1A70C779:
uid:u::::1730000000::HASH::Joachim <joachim@giaever.no>::::::::::0:
sub:u:255:18:SUBID:1730000000:::::e::::::cv25519::
fpr:::::::::AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555:'
_want="$(printf '0E32DAF912C2645073A3DFFA8956E92F1A70C779\tJoachim <joachim@giaever.no>')"
assert_eq "$(printf '%s\n' "$_colons" | parse_pubkey_list)" "$_want" "pubkey list: primary fpr+uid only (skips subkey fpr)"
_colons2='pub:u:255:22:KEYID1:1730000000:::-:::scESC::::::ed25519:::0:
fpr:::::::::1111111111111111111111111111111111111111:
uid:u::::1730000000::HASH1::Alice <alice@example.com>::::::::::0:
sub:u:255:18:SUBID1:1730000000:::::e::::::cv25519::
fpr:::::::::9999999999999999999999999999999999999999:
pub:u:255:22:KEYID2:1730000000:::-:::scESC::::::ed25519:::0:
fpr:::::::::2222222222222222222222222222222222222222:
uid:u::::1730000000::HASH2::Bob <bob@example.com>::::::::::0:'
_want2="$(printf '1111111111111111111111111111111111111111\tAlice <alice@example.com>\n2222222222222222222222222222222222222222\tBob <bob@example.com>')"
assert_eq "$(printf '%s\n' "$_colons2" | parse_pubkey_list)" "$_want2" "pubkey list: two keys, primary fpr+uid each (subkey fpr skipped)"

# --- key-management: first fingerprint ---
assert_eq "$(printf '%s\n' "$_colons" | first_fpr)" "0E32DAF912C2645073A3DFFA8956E92F1A70C779" "first_fpr"
assert_eq "$(printf 'tru::1:9:\n' | first_fpr)" "" "first_fpr: no fpr line -> empty"

# parse_collection_status: duplicity output -> TSV rows (awk collapses runs of spaces)
raw=' Type of backup set:                            Time:      Num volumes:
                Full         Mon Jun  9 00:00:01 2026                 2
         Incremental         Tue Jun 10 00:00:01 2026                 1'
assert_eq "$(printf '%s\n' "$raw" | parse_collection_status)" \
    "$(printf 'Full\tMon Jun 9 00:00:01 2026\t2\nIncremental\tTue Jun 10 00:00:01 2026\t1')" \
    "collection-status rows parsed"
assert_eq "$(printf 'No backup chains found\n' | parse_collection_status)" "" "no sets -> empty"

# cmd_status renders a table (plain ctx in CI); gpg absent -> private key "no"
out="$(SNAPCTL_backup_target="sftp://nas/zui" GNUPGHOME="$SNAP_COMMON/.gnupg" cmd_status)"
assert_contains "$out" "target" "status: target row"
assert_contains "$out" "sftp://nas/zui" "status: target value"
assert_contains "$out" "(unset)" "status: unset encrypt-key"
assert_contains "$out" "$SNAP_DATA/backups" "status: dir row"
assert_contains "$out" "3" "status: default retention"

# --- create-key blocked (no agent): must suggest the interactive pick-key pipe ---
_ck="$( (ensure_agent() { return 1; }; cmd_create_key 2>&1) )"; _ckrc=$?
assert_status "$_ckrc" "1" "create-key blocked -> status 1"
assert_contains "$_ck" "pick-key | sudo ${SNAP_NAME}.backup import-key" "create-key blocked: suggests pick-key | import-key (interactive picker)"

# --- gdrive credentials env (setup_gdrive_env) ---
unset GOOGLE_SERVICE_JSON_FILE
setup_gdrive_env; assert_status "$?" "0" "gdrive: unconfigured -> ok"
assert_eq "${GOOGLE_SERVICE_JSON_FILE:-}" "" "gdrive: no env exported when unconfigured"
_gj="$(mktemp)"; echo '{}' > "$_gj"
(SNAPCTL_backup_gdrive_credentials="$_gj" setup_gdrive_env && [ "${GOOGLE_SERVICE_JSON_FILE:-}" = "$_gj" ])
assert_status "$?" "0" "gdrive: readable credentials file -> env exported"
SNAPCTL_backup_gdrive_credentials=/nonexistent/sa.json setup_gdrive_env 2>/dev/null
assert_status "$?" "1" "gdrive: unreadable credentials -> refuse"
rm -f "$_gj"

# --- multi-uid keys: parse appends the EXTRA-uid count; menu renders it ---
_colons3='pub:u:255:22:KEYID:1730000000:::-:::scESC::::::ed25519:::0:
fpr:::::::::3333333333333333333333333333333333333333:
uid:u::::1730000000::H1::Joachim (Private) <j@priv.no>::::::::::0:
uid:u::::1730000000::H2::Joachim (Vertskap) <j@vert.no>::::::::::0:
uid:u::::1730000000::H3::Joachim (Online) <j@onl.no>::::::::::0:
sub:u:255:18:SUBID:1730000000:::::e::::::cv25519::'
_want3="$(printf '3333333333333333333333333333333333333333\tJoachim (Private) <j@priv.no>\t2')"
assert_eq "$(printf '%s\n' "$_colons3" | parse_pubkey_list)" "$_want3" "multi-uid: primary uid + extra-uid count"
assert_eq "$(printf '%s\n' "$_want3" | number_pubkey_list)" " 1) Joachim (Private) <j@priv.no>  [3333333333333333333333333333333333333333]  (+2 more identities)" "menu: plural extra-identities suffix"
assert_eq "$(printf 'F\tU\t1' | number_pubkey_list)" " 1) U  [F]  (+1 more identity)" "menu: singular extra-identity suffix"

# --- pick-key interactive helpers (menu render + selection resolve) ---
_two="$(printf '1111111111111111111111111111111111111111\tAlice <alice@example.com>\n2222222222222222222222222222222222222222\tBob <bob@example.com>')"
_menu="$(printf ' 1) Alice <alice@example.com>  [1111111111111111111111111111111111111111]\n 2) Bob <bob@example.com>  [2222222222222222222222222222222222222222]')"
assert_eq "$(printf '%s\n' "$_two" | number_pubkey_list)" "$_menu" "menu: numbered 'N) uid  [fpr]' lines"
assert_eq "$(printf '%s\n' "$_two" | nth_fpr 1)" "1111111111111111111111111111111111111111" "nth_fpr: first"
assert_eq "$(printf '%s\n' "$_two" | nth_fpr 2)" "2222222222222222222222222222222222222222" "nth_fpr: second"
printf '%s\n' "$_two" | nth_fpr 3 >/dev/null 2>&1; assert_status "$?" "1" "nth_fpr: out of range -> 1"
printf '%s\n' "$_two" | nth_fpr x >/dev/null 2>&1; assert_status "$?" "1" "nth_fpr: non-numeric -> 1"
printf '%s\n' "$_two" | nth_fpr '' >/dev/null 2>&1; assert_status "$?" "1" "nth_fpr: empty -> 1"

finish
