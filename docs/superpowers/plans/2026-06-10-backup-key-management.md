# Backup Key-Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `pick-key`, `create-key`, and `export-key` subcommands to `zwave-js-ui.backup` (and auto-wire `import-key`) so configuring backup encryption is one command per scenario, without forcing a decryption secret onto the device.

**Architecture:** All work lands in the existing `src/bin/backup` bash script. Parsing/formatting logic (subcommand dispatch, GPG colon-format parsing, fingerprint extraction, the host-keyring path) is factored into small **pure helpers** that are unit-tested in `tests/backup_test.sh`. The four GPG-driven command bodies (`cmd_pick_key`/`cmd_import_key`/`cmd_create_key`/`cmd_export_key`) shell out to `gpg`/`snapctl` and are verified on-device. `pick-key` runs as the **invoking user** (reads the host `~/.gnupg`); the rest run as **root** against the snap keyring (`$SNAP_COMMON/.gnupg`). `snap/snapcraft.yaml` drops two now-unused gpg plugs.

**Tech Stack:** bash, GnuPG 2.4 (staged in the snap), `snapctl`, awk (base), the zero-dependency bash test harness in `tests/lib/assert.sh`.

**Spec:** `docs/superpowers/specs/2026-06-10-backup-key-management-design.md`

**Branch:** `feat/backup-key-management` (already created off `feat/backup`).

---

## File map

- **Modify `src/bin/backup`** — add pure helpers (`gpg_host_homedir`, `parse_pubkey_list`, `first_fpr`), extend `parse_sub` + `usage`, add command bodies (`cmd_pick_key`, `cmd_import_key`, `cmd_create_key`, `cmd_export_key`), restructure `main()` for per-subcommand root gating.
- **Modify `tests/backup_test.sh`** — append unit tests for the new pure helpers and `parse_sub`/`usage`.
- **Modify `snap/snapcraft.yaml`** — remove `gpg-keys` from the `backup` app; remove `gpg-public-keys` from `backup-timer`.
- **Modify `CLAUDE.md`** — document the new key-management subcommands.

Verification commands used throughout:
- Unit tests: `bash tests/backup_test.sh` → expect `N passed, 0 failed`.
- Lint: `shellcheck --severity=warning src/bin/backup` → expect no output.

---

### Task 1: Extend `parse_sub` and `usage`

**Files:**
- Modify: `src/bin/backup` (the `parse_sub` function ~line 22, the `usage` heredoc ~line 10)
- Test: `tests/backup_test.sh`

- [ ] **Step 1: Write the failing tests** — append to `tests/backup_test.sh` immediately before the final `finish` line:

```bash
# --- key-management: parse_sub + usage ---
assert_eq "$(parse_sub 'pick-key')"   "pick-key"   "pick-key"
assert_eq "$(parse_sub 'create-key')" "create-key" "create-key"
assert_eq "$(parse_sub 'export-key')" "export-key" "export-key"

SNAP_NAME="${SNAP_NAME:-zwave-js-ui}"   # usage heredoc references ${SNAP_NAME}; set under `set -u`
_u="$(usage)"
assert_contains "$_u" "pick-key"   "usage lists pick-key"
assert_contains "$_u" "create-key" "usage lists create-key"
assert_contains "$_u" "export-key" "usage lists export-key"
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `bash tests/backup_test.sh`
Expected: FAIL lines for `pick-key`/`create-key`/`export-key` (parse_sub returns empty + status 2; usage missing the verbs), non-zero "failed" count.

- [ ] **Step 3: Add the three cases to `parse_sub`** — in `src/bin/backup`, change:

```bash
        status)    echo status ;;
        import-key) echo import-key ;;
        *)         return 2 ;;
```
to:
```bash
        status)    echo status ;;
        import-key) echo import-key ;;
        pick-key)   echo pick-key ;;
        create-key) echo create-key ;;
        export-key) echo export-key ;;
        *)         return 2 ;;
```

- [ ] **Step 4: Extend `usage`** — replace the existing `usage` heredoc body so it reads:

```bash
usage() {
    cat <<EOF
Usage: ${SNAP_NAME}.backup [restore [<time>] | list | status | pick-key [<fpr>] | import-key | create-key | export-key]

  (no arg)    ship ZUI's backups now (incremental; full if older than threshold)
  restore     fetch+decrypt the latest backup back into the backup dir
  list        show available backup sets
  status      show current backup config
  pick-key    list YOUR host GPG public keys (no sudo); 'pick-key <fpr>' exports one to stdout
  import-key  import a GPG public key (armored, on stdin) into the snap keyring + set encrypt-key (sudo)
  create-key  generate a backup keypair in the snap keyring + set encrypt-key (sudo)
  export-key  export the snap keyring's private key to move it to your host/offline (sudo)
  -h|--help   this help

Typical setup with an existing key:
  ${SNAP_NAME}.backup pick-key <fpr> | sudo ${SNAP_NAME}.backup import-key
EOF
}
```

- [ ] **Step 5: Run tests + lint, verify pass**

Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed`
Run: `shellcheck --severity=warning src/bin/backup` → Expected: no output

- [ ] **Step 6: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "feat(backup): recognise pick-key/create-key/export-key in parse_sub + usage"
```

---

### Task 2: `gpg_host_homedir` helper

**Files:**
- Modify: `src/bin/backup` (add helper in the pure-helpers section, after `parse_sub`)
- Test: `tests/backup_test.sh`

- [ ] **Step 1: Write the failing test** — append before `finish`:

```bash
# --- key-management: host keyring path ---
assert_eq "$(SNAP_REAL_HOME=/home/u gpg_host_homedir)" "/home/u/.gnupg" "host homedir from SNAP_REAL_HOME"
```

- [ ] **Step 2: Run tests, verify it fails**

Run: `bash tests/backup_test.sh`
Expected: FAIL `host homedir from SNAP_REAL_HOME` (function not defined → empty output).

- [ ] **Step 3: Add the helper** — in `src/bin/backup`, after the `parse_sub` function:

```bash
# Path to the invoking user's REAL gpg home. Inside the snap, $HOME is remapped to the
# sandbox; $SNAP_REAL_HOME points at the actual home (e.g. /home/joachimmgg). pick-key
# must read THIS, not $HOME/.gnupg (which is the empty sandbox keyring).
gpg_host_homedir() { echo "${SNAP_REAL_HOME:-$HOME}/.gnupg"; }
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "feat(backup): add gpg_host_homedir helper"
```

---

### Task 3: `parse_pubkey_list` helper (colon format → fpr<TAB>uid)

**Files:**
- Modify: `src/bin/backup` (add helper after `gpg_host_homedir`)
- Test: `tests/backup_test.sh`

- [ ] **Step 1: Write the failing test** — append before `finish`:

```bash
# --- key-management: pubkey list parser ---
_colons='pub:u:255:22:KEYID:1730000000:::-:::scESC::::::ed25519:::0:
fpr:::::::::0E32DAF912C2645073A3DFFA8956E92F1A70C779:
uid:u::::1730000000::HASH::Joachim <joachim@giaever.no>::::::::::0:
sub:u:255:18:SUBID:1730000000:::::e::::::cv25519::
fpr:::::::::AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555:'
_want="$(printf '0E32DAF912C2645073A3DFFA8956E92F1A70C779\tJoachim <joachim@giaever.no>')"
assert_eq "$(printf '%s\n' "$_colons" | parse_pubkey_list)" "$_want" "pubkey list: primary fpr+uid only (skips subkey fpr)"
```

- [ ] **Step 2: Run tests, verify it fails**

Run: `bash tests/backup_test.sh`
Expected: FAIL `pubkey list...` (function not defined → empty output).

- [ ] **Step 3: Add the helper** — in `src/bin/backup`, after `gpg_host_homedir`:

```bash
# Reads `gpg --with-colons` key listing on stdin, emits one "FPR<TAB>primary-uid" line
# per key. Takes the first fpr after each `pub` (the primary key fingerprint) and the
# first `uid` after it, ignoring subkey fpr lines. Pure: stdin -> stdout, unit-tested.
parse_pubkey_list() {
    awk -F: '
        $1=="pub" { have=0 }
        $1=="fpr" && !have { fpr=$10; have=1 }
        $1=="uid" && have && !seen[fpr]++ { print fpr "\t" $10 }
    '
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "feat(backup): add parse_pubkey_list (colon-format -> fpr+uid)"
```

---

### Task 4: `first_fpr` helper

**Files:**
- Modify: `src/bin/backup` (add helper after `parse_pubkey_list`)
- Test: `tests/backup_test.sh`

- [ ] **Step 1: Write the failing test** — append before `finish` (reuses `$_colons` from Task 3):

```bash
# --- key-management: first fingerprint ---
assert_eq "$(printf '%s\n' "$_colons" | first_fpr)" "0E32DAF912C2645073A3DFFA8956E92F1A70C779" "first_fpr"
assert_eq "$(printf 'tru::1:9:\n' | first_fpr)" "" "first_fpr: no fpr line -> empty"
```

- [ ] **Step 2: Run tests, verify it fails**

Run: `bash tests/backup_test.sh`
Expected: FAIL `first_fpr` (function not defined).

- [ ] **Step 3: Add the helper** — in `src/bin/backup`, after `parse_pubkey_list`:

```bash
# Reads `gpg --with-colons` output on stdin, prints the FIRST fingerprint (field 10 of
# the first `fpr:` line) and stops. Empty if there is none. Pure, unit-tested.
first_fpr() { awk -F: '$1=="fpr"{print $10; exit}'; }
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "feat(backup): add first_fpr helper"
```

---

### Task 5: `cmd_pick_key` + `main()` restructure (user context)

**Files:**
- Modify: `src/bin/backup` (add `cmd_pick_key`; restructure `main()` lines ~69-147)

No unit test (it shells out to interactive `gpg`); its parsing dependency (`parse_pubkey_list`) is already tested in Task 3. Verified on-device in Step 4.

- [ ] **Step 1: Add `cmd_pick_key`** — in `src/bin/backup`, after `first_fpr`:

```bash
# USER-context: list the invoking user's host public keys, or export one (armored) to
# stdout. Refuses root (root can't read the user's keyring — owner-match fails). Pipe the
# export into `sudo zwave-js-ui.backup import-key` to store it in the snap keyring.
cmd_pick_key() {  # $1 = optional fingerprint to export
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        lprint "Run 'pick-key' WITHOUT sudo — it reads YOUR personal GPG keyring." >&2
        exit 1
    fi
    local home; home="$(gpg_host_homedir)"
    if [ ! -d "$home" ]; then
        lprint "No host GPG keyring at ${home}." >&2
        lprint "Create one with 'gpg --full-generate-key', or use 'sudo ${SNAP_NAME}.backup create-key'." >&2
        exit 1
    fi
    if [ -z "${1:-}" ]; then
        lprint "Your GPG public keys (use a fingerprint with: pick-key <fpr> | sudo ${SNAP_NAME}.backup import-key):" >&2
        gpg --homedir "$home" --list-keys --with-colons 2>/dev/null | parse_pubkey_list
    else
        gpg --homedir "$home" --export --armor "$1"
    fi
}
```

- [ ] **Step 2: Restructure `main()`** — replace the current `main()` body (the prologue through the `case` open) so `pick-key` is handled BEFORE `require_root`, and root setup happens only for root subcommands. Replace lines from `main() {` down to `local target; target="$(cfg target)"` with:

```bash
main() {
    case "${1:-}" in -h|--help) usage; exit 0 ;; esac

    local sub; sub="$(parse_sub "${1:-}")" || { usage >&2; exit 2; }

    # pick-key runs as the INVOKING USER against the host keyring — never root, and it
    # touches none of the root/duplicity/snap-keyring setup below.
    if [ "$sub" = "pick-key" ]; then
        cmd_pick_key "${2:-}"
        exit $?
    fi

    require_root
    mkdir -p "$ARCHIVE_DIR"
    export GNUPGHOME="${SNAP_COMMON:-/tmp}/.gnupg"   # snap-local keyring (confirmed by the GPG spike)
    # duplicity is a Python app staged under $SNAP; core24's interpreter does not
    # search $SNAP for modules, so its `import duplicity` fails without this
    # (verified on-device: import works only with dist-packages on PYTHONPATH).
    export PYTHONPATH="$SNAP/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"

    local target; target="$(cfg target)"
```

(The existing `case "$sub" in … esac` and the `backup`/`restore`/`list`/`status`/`import-key` arms remain unchanged in this task; Task 6 edits `import-key`, Tasks 7-8 add the new arms.)

- [ ] **Step 3: Lint**

Run: `shellcheck --severity=warning src/bin/backup` → Expected: no output
Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed` (no regressions; `main` is guarded so sourcing is safe)

- [ ] **Step 4: On-device verification** (requires a local `snapcraft` build + `sudo snap install --dangerous`; on-device steps across Tasks 5–8 may be batched into the Final verification to avoid rebuilding per task)

```bash
zwave-js-ui.backup pick-key                 # NO sudo → lists your real keys as "fpr<TAB>uid"
zwave-js-ui.backup pick-key <fpr> | head    # prints an armored PUBLIC key block
sudo zwave-js-ui.backup pick-key            # expect refusal: "Run 'pick-key' WITHOUT sudo"
```
Expected: list shows your real fingerprints; export emits `-----BEGIN PGP PUBLIC KEY BLOCK-----`; sudo form refuses. No AppArmor denials in `sudo dmesg | grep -i DENIED`.

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup
git commit -m "feat(backup): add user-context pick-key + per-subcommand root gating in main"
```

---

### Task 6: `cmd_import_key` — refactor + auto-set `encrypt-key`

**Files:**
- Modify: `src/bin/backup` (extract the inline `import-key)` arm into `cmd_import_key`; call it from the case)

Parsing dependency (`first_fpr`) is unit-tested (Task 4); the gpg/snapctl wiring is verified on-device.

- [ ] **Step 1: Add `cmd_import_key`** — in `src/bin/backup`, after `cmd_pick_key`:

```bash
# ROOT-context: import an armored PUBLIC key (stdin) into the snap keyring, then set
# backup.encrypt-key to its fingerprint so backups encrypt to it immediately.
cmd_import_key() {
    mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    local tmp; tmp="$(mktemp)"
    cat > "$tmp"
    local fpr; fpr="$(gpg --homedir "$GNUPGHOME" --show-keys --with-colons "$tmp" 2>/dev/null | first_fpr)"
    gpg --homedir "$GNUPGHOME" --import "$tmp"
    rm -f "$tmp"
    if [ -n "$fpr" ]; then
        snapctl set backup.encrypt-key="$fpr"
        lprint "Imported ${fpr} and set backup.encrypt-key=${fpr}." >&2
    else
        lprint "Imported key, but could not read its fingerprint — set backup.encrypt-key manually." >&2
    fi
}
```

- [ ] **Step 2: Replace the inline `import-key)` arm** — in `main()`'s `case`, change:

```bash
        import-key)
            # Read an armored public key from stdin into the snap-local keyring.
            # Asymmetric encryption keeps any decryption secret OFF the device, so
            # we only ever import a *public* key here.
            mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
            lprint "Importing armored GPG public key from stdin into ${GNUPGHOME} …" >&2
            gpg --homedir "$GNUPGHOME" --import
            ;;
```
to:
```bash
        import-key) cmd_import_key ;;
```

- [ ] **Step 3: Lint + unit tests**

Run: `shellcheck --severity=warning src/bin/backup` → Expected: no output
Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed`

- [ ] **Step 4: On-device verification**

```bash
zwave-js-ui.backup pick-key <fpr> | sudo zwave-js-ui.backup import-key
sudo zwave-js-ui.backup status     # expect encrypt-key=<fpr>
```
Expected: import logs "Imported <fpr> and set backup.encrypt-key=<fpr>"; `status` shows that fingerprint.

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup
git commit -m "feat(backup): import-key auto-sets encrypt-key from the imported fingerprint"
```

---

### Task 7: `cmd_create_key` (root)

**Files:**
- Modify: `src/bin/backup` (add `cmd_create_key`; add `create-key)` arm to the case)

Interactive gpg generation — verified on-device.

- [ ] **Step 1: Add `cmd_create_key`** — in `src/bin/backup`, after `cmd_import_key`:

```bash
# ROOT-context: generate an ed25519/cv25519 backup keypair in the snap keyring and set
# backup.encrypt-key to it. The private key stays in the snap keyring until `export-key`
# moves it off. Prompts for the full UID (name, email, optional comment) and a passphrase.
cmd_create_key() {
    mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    local name email comment pass uid
    read -rp "Real name: " name
    read -rp "Email: " email
    read -rp "Comment (optional): " comment
    read -rsp "Passphrase for the new private key: " pass; echo >&2
    uid="$name"
    [ -n "$comment" ] && uid="$uid ($comment)"
    uid="$uid <$email>"
    gpg --homedir "$GNUPGHOME" --batch --pinentry-mode loopback --passphrase "$pass" \
        --quick-generate-key "$uid" ed25519 cert,sign never
    local fpr; fpr="$(gpg --homedir "$GNUPGHOME" --list-keys --with-colons "$email" 2>/dev/null | first_fpr)"
    gpg --homedir "$GNUPGHOME" --batch --pinentry-mode loopback --passphrase "$pass" \
        --quick-add-key "$fpr" cv25519 encr never
    snapctl set backup.encrypt-key="$fpr"
    lprint "Created ${fpr} and set backup.encrypt-key=${fpr}." >&2
    lprint "The private key currently lives ONLY in this snap. Run 'sudo ${SNAP_NAME}.backup export-key'" >&2
    lprint "to copy it to your host keyring / offline storage and remove it from this device." >&2
}
```

- [ ] **Step 2: Add the `create-key)` arm** — in `main()`'s `case`, after `import-key) cmd_import_key ;;`:

```bash
        create-key) cmd_create_key ;;
```

- [ ] **Step 3: Lint + unit tests**

Run: `shellcheck --severity=warning src/bin/backup` → Expected: no output
Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed`

- [ ] **Step 4: On-device verification**

```bash
sudo zwave-js-ui.backup create-key     # answer name/email/comment/passphrase
sudo zwave-js-ui.backup status         # expect encrypt-key=<new fpr>
# confirm it has an ENCRYPTION subkey (cv25519) so duplicity can encrypt:
sudo snap run --shell zwave-js-ui.backup -c 'gpg --homedir "$SNAP_COMMON/.gnupg" -K'
# then a real encrypted backup to a fresh target:
sudo snap set zwave-js-ui backup.target="file:///var/snap/zwave-js-ui/common/test-target-created"
sudo zwave-js-ui.backup; echo "rc=$?"  # expect Errors 0, rc=0
```
Expected: key created with an `[E]` cv25519 subkey; backup encrypts successfully.

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup
git commit -m "feat(backup): add create-key (ed25519/cv25519, sets encrypt-key)"
```

---

### Task 8: `cmd_export_key` (root)

**Files:**
- Modify: `src/bin/backup` (add `cmd_export_key`; add `export-key)` arm to the case)

- [ ] **Step 1: Add `cmd_export_key`** — in `src/bin/backup`, after `cmd_create_key`:

```bash
# ROOT-context: export the snap keyring's PRIVATE key (defaults to backup.encrypt-key) so
# the user can move it to their host keyring / offline, then offer to delete it from the
# snap (leaving the public key for backups). Delete prompt defaults to "no".
cmd_export_key() {
    local fpr; fpr="$(cfg encrypt-key)"
    [ -n "$fpr" ] || { lprint "backup.encrypt-key not set; nothing to export." >&2; exit 1; }
    if ! gpg --homedir "$GNUPGHOME" --list-secret-keys "$fpr" >/dev/null 2>&1; then
        lprint "No private key on this device for ${fpr} (public-only or card key); nothing to export." >&2
        exit 0
    fi
    lprint "# To add this key to your workstation keyring, run on the HOST (not in the snap):" >&2
    lprint "#     gpg --import   # paste/redirect the block below" >&2
    lprint "# Also store it OFFLINE — it is the ONLY way to decrypt your backups." >&2
    gpg --homedir "$GNUPGHOME" --export-secret-keys --armor "$fpr"
    local ans
    read -rp "Delete the private key from THIS device now? [y/N] " ans
    case "${ans:-N}" in
        y|Y|yes|YES)
            gpg --homedir "$GNUPGHOME" --batch --yes --delete-secret-keys "$fpr"
            lprint "Private key deleted from the snap keyring; the public key is retained for backups." >&2 ;;
        *)
            lprint "Kept the private key in the snap keyring." >&2 ;;
    esac
}
```

- [ ] **Step 2: Add the `export-key)` arm** — in `main()`'s `case`, after `create-key) cmd_create_key ;;`:

```bash
        export-key) cmd_export_key ;;
```

- [ ] **Step 3: Lint + unit tests**

Run: `shellcheck --severity=warning src/bin/backup` → Expected: no output
Run: `bash tests/backup_test.sh` → Expected: `N passed, 0 failed`

- [ ] **Step 4: On-device verification** (after a `create-key`)

```bash
sudo zwave-js-ui.backup export-key > /tmp/exported-key.asc   # answer N at the prompt
grep -q 'BEGIN PGP PRIVATE KEY BLOCK' /tmp/exported-key.asc && echo "private key exported"
# answering 'y' should delete the secret while backups still work:
sudo zwave-js-ui.backup export-key   # answer y
sudo zwave-js-ui.backup; echo "rc=$?"   # public retained -> still encrypts, rc=0
```
Expected: a `PRIVATE KEY BLOCK` is emitted to stdout (instructions to stderr); after `y`, the secret is gone but `backup` still succeeds (public key retained).

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup
git commit -m "feat(backup): add export-key (export private key, opt-in delete)"
```

---

### Task 9: Drop the now-unused gpg plugs

**Files:**
- Modify: `snap/snapcraft.yaml` (the `backup` app ~line 119, `backup-timer` ~line 127)

No unit test (snapcraft metadata); validated by a snap build + the on-device steps in earlier tasks.

- [ ] **Step 1: Remove `gpg-keys` from the `backup` app** — change:

```yaml
  backup:
    command: bin/backup
    plugs:
      - network
      - home
      - removable-media
      - gpg-public-keys
      - gpg-keys
```
to:
```yaml
  backup:
    command: bin/backup
    plugs:
      - network
      - home
      - removable-media
      - gpg-public-keys
```

- [ ] **Step 2: Remove `gpg-public-keys` from `backup-timer`** — change:

```yaml
  backup-timer:
    command: bin/backup
    daemon: oneshot
    timer: "00:00"
    environment:
      DAEMONIZED: 1
    plugs:
      - network
      - home
      - removable-media
      - gpg-public-keys
```
to:
```yaml
  backup-timer:
    command: bin/backup
    daemon: oneshot
    timer: "00:00"
    environment:
      DAEMONIZED: 1
    plugs:
      - network
      - home
      - removable-media
```

- [ ] **Step 3: Sanity-check YAML parses**

Run: `yq '.apps.backup.plugs, .apps."backup-timer".plugs' snap/snapcraft.yaml`
Expected: `backup` lists `network/home/removable-media/gpg-public-keys` (no `gpg-keys`); `backup-timer` lists `network/home/removable-media` (no `gpg-public-keys`).

- [ ] **Step 4: Commit**

```bash
git add snap/snapcraft.yaml
git commit -m "chore(backup): drop unused gpg-keys (backup) + gpg-public-keys (timer) plugs"
```

---

### Task 10: Document the key-management subcommands in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (the `### User commands` `backup` bullet)

- [ ] **Step 1: Update the `backup` description** — in `CLAUDE.md`, find the `backup` bullet under "User commands" and append after its existing text:

```markdown
  Key management for the encryption key lives in `backup` subcommands: `pick-key` (run **without** sudo — lists/export​s a public key from the *user's* `~/.gnupg`, since root can't read it), piped into `import-key` (root: store the public key in the snap keyring at `$SNAP_COMMON/.gnupg` and set `backup.encrypt-key`); `create-key` (root: generate an ed25519/cv25519 keypair in the snap keyring); and `export-key` (root: export the private key to move it to the host/offline, with an opt-in delete). Only `gpg-public-keys` is needed (on the `backup` app, for `pick-key`); `gpg-keys` and the timer's `gpg-public-keys` were removed as unused. See `docs/superpowers/specs/2026-06-10-backup-key-management-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document backup key-management subcommands in CLAUDE.md"
```

---

## Final verification (after all tasks)

- [ ] `shellcheck --severity=warning src/bin/backup` → no output
- [ ] `bash tests/backup_test.sh` → `N passed, 0 failed`
- [ ] `bash tests/logs_test.sh` → `N passed, 0 failed` (no regressions)
- [ ] Build + install the snap; run the on-device verifications from Tasks 5–8 end-to-end:
  `pick-key | import-key`, `create-key` → encrypted backup, `export-key` → private key out + optional delete, backups still encrypt with the retained public key.
- [ ] Confirm no AppArmor denials: `sudo dmesg | grep -i 'apparmor=.DENIED'` is empty for these flows.
```
