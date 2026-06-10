# Backup Key-Management Design

**Status:** Approved (design) — 2026-06-10
**Builds on:** `2026-06-10-backup-design.md` (the `zwave-js-ui.backup` off-box shipper)

**Goal:** Remove the manual GPG friction from configuring backup encryption. Today a
user must hand-find a fingerprint, run `gpg --export | sudo zwave-js-ui.backup
import-key`, then `snap set … backup.encrypt-key=<fpr>`. This adds `pick-key`,
`create-key`, and `export-key` subcommands so the common paths ("use a key I have",
"make me a key", "move the new key off the device") are one command each, while
preserving the invariant that **no decryption secret is forced to live on the device**.

**Architecture:** Three new subcommands on the existing `src/bin/backup` script, split
across two privilege contexts that the snap sandbox forces apart. `pick-key` runs as
the **invoking user** and reads the real `~/.gnupg`; `create-key`/`export-key`/
`import-key` run as **root** against the snap-private keyring (`$SNAP_COMMON/.gnupg`).
The two contexts cannot share a writable directory, so the host→snap hop is an explicit
pipe (`pick-key … | sudo … import-key`). Encryption always uses only a **public** key.

**Tech stack:** bash (existing `src/bin/backup` + `src/helper/functions`), GnuPG 2.x
(staged), snapd interfaces (`gpg-public-keys`), `snapctl` for config, the existing
zero-dependency bash test harness (`tests/lib/assert.sh`, `tests/backup_test.sh`).

---

## Background: the constraints that shaped this (all empirically verified on-device)

These were established by direct test on an installed snap (Ubuntu 24.04, strict
confinement), and they are *why* the design looks the way it does:

1. **The gpg interfaces are read-only.** `gpg-public-keys`/`gpg-keys` grant
   `owner @{HOME}/.gnupg/** r` — listing/exporting work, but writing (key generation)
   is denied (`gpg -k` printed `Note: trustdb not writable`; a `touch` into `~/.gnupg`
   returned `WRITE DENIED`). So the snap can **never create or modify keys in the host
   keyring**.
2. **Root cannot read the host keyring.** The interfaces' rules are `owner`-qualified,
   so a root process (euid 0) fails the owner-match against uid-1000 key files, and
   `@{HOME}` for root resolves to `/root`. `sudo … gpg --homedir ~user/.gnupg` returned
   `Permission denied` on the lock files. So **reading the host keyring requires running
   as the key's owner**, not root.
3. **`$HOME` is remapped inside the snap.** A confined gpg defaults to
   `$SNAP_USER_DATA/.gnupg`, not the real `~/.gnupg`. To reach the real keyring you must
   pass `--homedir "$SNAP_REAL_HOME/.gnupg"` (verified: lists the real keys, rc=0).
4. **There is no shared user-writable / root-readable directory.** `$SNAP_USER_COMMON`
   (`~/snap/zwave-js-ui/common`) is user-writable but **not** readable by the root
   daemon (`rc=1, permission denied` from inside the root confinement); `$SNAP_COMMON`
   (`/var/snap/…`) is root-only-writable. So the user→snap-store handoff **cannot** be a
   shared file — it must pass through a root invocation (a pipe or `sudo`).
5. **The backup/timer must run as root** (they read the root-owned
   `$SNAP_DATA/backups`). They therefore can only ever use the snap-private keyring.

Net: key *selection from the host keyring* is a user-context read; key *storage,
creation, and config* are root-context writes; the two are bridged by an explicit pipe.

---

## Subcommand surface

| cmd | uid | summary |
|---|---|---|
| `pick-key [<fpr>]` | **user** (no sudo) | list real-home public keys, or export one to stdout |
| `import-key` | **root** | import a piped armored public key → snap keyring → set `encrypt-key` |
| `create-key` | **root** | generate a software keypair in the snap keyring → set `encrypt-key` |
| `export-key` | **root** | export the snap keyring's private key, explain host import, offer to delete |

Existing subcommands (`backup`, `restore`, `list`, `status`) are unchanged in behaviour.

### `pick-key [<fpr>]` — user context

Runs **as the invoking user** (it must, to read their keyring). Uses
`gpg --homedir "$SNAP_REAL_HOME/.gnupg"`.

- **No argument** → list the user's public keys as `fpr<TAB>uid` (one per line) to
  stdout, so the user can see fingerprints without `gpg` incantations. Implementation:
  `gpg --homedir "$SNAP_REAL_HOME/.gnupg" --list-keys --with-colons` parsed to
  `fpr` + primary `uid` lines.
- **With `<fpr>`** → export that key's **public** half, armored, to stdout:
  `gpg --homedir "$SNAP_REAL_HOME/.gnupg" --export --armor "<fpr>"`.
- **Usage shown in help:**
  `zwave-js-ui.backup pick-key <fpr> | sudo zwave-js-ui.backup import-key`
- **Errors:** if run as root, print "run `pick-key` without sudo (it reads *your*
  keyring)"; if `$SNAP_REAL_HOME` is unset or `~/.gnupg` is absent (e.g. Ubuntu Core),
  print "no host keyring found — use `create-key` or pipe a key to `import-key`" and
  exit non-zero.
- **Does NOT require root; does NOT touch `$GNUPGHOME`/snap keyring.**

### `import-key` — root context (extends today's command)

Unchanged input behaviour (reads an armored **public** key from stdin into
`$SNAP_COMMON/.gnupg`), plus:

- After a successful import, determine the imported key's fingerprint and
  **auto-set `backup.encrypt-key=<fpr>`** via `snapctl set backup.encrypt-key=<fpr>`.
  If multiple keys are imported, set it to the first/primary and log the choice.
- Log the resulting `encrypt-key` so the user sees the wiring happened.
- Idempotent: re-importing the same key is fine; encrypt-key is re-set to it.

### `create-key` — root context

Generates a **software** keypair directly in the snap keyring (root can write
`$SNAP_COMMON/.gnupg`).

- Key type: **ed25519 sign + cv25519 encrypt** (modern, small). RSA is not offered
  initially (YAGNI; revisit if an old-gpg restore target needs it).
- **Passphrase-protected**: prompt for a passphrase interactively (root invocation, user
  present). The passphrase is never stored; restore will prompt for it.
- UID: support the **full set** of UID fields — real name, email, and optional comment —
  supplied either interactively (prompt) or as arguments (user decision: "every" — accept
  all fields and both input modes).
- On success: set `backup.encrypt-key=<fpr>`, then print next steps pointing at
  `export-key` ("your private key currently lives only in this snap; run
  `sudo zwave-js-ui.backup export-key` to copy it to your host keystore / offline and
  remove it from the device").
- The private key **remains in the snap keyring until `export-key` removes it** — this
  is the deliberate "convenient now, strict when you choose" posture.

### `export-key` — root context

Moves the software private key off the device.

- Export the snap keyring's **private** key, armored:
  `gpg --homedir "$GNUPGHOME" --export-secret-keys --armor "<fpr>"` (fpr defaults to the
  configured `backup.encrypt-key`).
- Print the exact command to import it into the host keystore, e.g.
  `… | gpg --import` (run as the user, on the host), and the recommendation to also
  store it offline (it is the only way to decrypt).
- **Then offer to delete** the private key from the snap keyring
  (`gpg --homedir "$GNUPGHOME" --delete-secret-keys "<fpr>"`), leaving the public key in
  place so backups keep encrypting. Default the prompt to "no" (don't delete unless
  confirmed) so an accidental run can't strand the user.
- **Errors:** if the keyring holds no secret key for the fingerprint (e.g. it was a
  `pick-key`/`import-key` public-only key, or a card key), report "no private key on
  this device for `<fpr>` — nothing to export" and exit 0.

---

## `main()` restructure

Today `main()` (`src/bin/backup`) calls `require_root` unconditionally (line 72) and
hard-sets `GNUPGHOME=$SNAP_COMMON/.gnupg` (line 77). `pick-key` violates both. Required
changes:

1. **Parse the subcommand first, then gate on root per-subcommand.** Move `require_root`
   out of the unconditional prologue. `pick-key` runs without it; every other subcommand
   calls `require_root` as its first action.
2. **Select the keyring per context.** Root subcommands keep
   `GNUPGHOME=$SNAP_COMMON/.gnupg`. `pick-key` never sets `$GNUPGHOME`; it always passes
   `--homedir "$SNAP_REAL_HOME/.gnupg"` explicitly.
3. `PYTHONPATH`/`ARCHIVE_DIR`/duplicity setup stay in the root path only (pick-key needs
   none of it).
4. Extend `parse_sub` to recognise `pick-key`, `create-key`, `export-key` (it already
   handles `import-key`).

Keep the pure, unit-testable helpers pattern: parsing/formatting (e.g. the colon-parse
that turns `--with-colons` into `fpr<TAB>uid`, fingerprint extraction, the
gpg-command-string builders) are separate functions covered by `tests/backup_test.sh`;
`main` wires them to `gpg`/`snapctl`.

---

## Interface changes (`snap/snapcraft.yaml`)

- **Keep `gpg-public-keys` on the `backup` app** — `pick-key`'s user-mode host read
  needs exactly this and nothing more.
- **Drop `gpg-keys`** from the `backup` app — no flow reads the host *private* keyring
  (root can't; restore uses the snap keyring). Removing it also drops a needless
  private-key permission that contradicts the "no decryption secret" story.
- **Drop `gpg-public-keys` from `backup-timer`** — the timer only ever *encrypts* via the
  snap keyring; it never reads the host keyring.

## Security model

- Backup and the timer encrypt with the **public** key in the snap keyring; no secret is
  needed at rest for normal operation.
- A software private key created by `create-key` sits **passphrase-protected** in the
  snap keyring until the user runs `export-key` to copy it out and (optionally) delete
  it — the user chooses when the device reaches "public-only".
- Card-backed (YubiKey) keys: the private key never leaves the token; `pick-key` exports
  only the public half, and restore requires the physical card. (On-card key generation
  is out of scope — see below.)
- `snap get/set` only ever stores the public **fingerprint** as `backup.encrypt-key`,
  never key material.

## Out of scope

- **Generating a key onto a FIDO/smartcard via the snap** — needs PCSC/smartcard write
  access inside confinement (`gpg --card-edit`, pcscd, raw-usb). The user creates the
  on-card key with their own `gpg`/`ykman`, then `pick-key`s its public half.
- **Writing to the host keyring from the snap** — impossible (read-only interface);
  `export-key` prints the host-side `gpg --import` command for the user to run instead.
- **RSA keys** in `create-key` — ed25519/cv25519 only for now.

## Testing

- **Unit (`tests/backup_test.sh`, no root, gpg stubbed/optional):**
  - `parse_sub` returns `pick-key`/`create-key`/`export-key`/`import-key` and `2` for
    unknown (extends existing assertions).
  - The `--with-colons` → `fpr<TAB>uid` parser: given canned colon output, emits the
    expected lines (table-driven, no gpg needed).
  - Fingerprint-extraction helper: given canned `--import`/`--list` output, returns the
    fpr.
  - `usage` lists the new subcommands.
- **On-device integration (manual, documented in the plan):**
  - `pick-key` (no sudo) lists real keys; `pick-key <fpr>` emits an armored public block.
  - `pick-key <fpr> | sudo … import-key` imports and sets `encrypt-key`; a subsequent
    `backup` encrypts to it.
  - `create-key` generates, sets `encrypt-key`, a `backup` encrypts; `export-key` emits
    the private key, prints the host import command, and (on confirm) removes the secret
    while `backup` still works (public retained).
  - Confinement: no AppArmor denials in `snap logs` / `dmesg` for the user-mode read.

## Resolved decisions

- Selection reads the **real** host keyring via `--homedir "$SNAP_REAL_HOME/.gnupg"`
  (user context); storage/creation/config are root against `$SNAP_COMMON/.gnupg`.
- The user→snap hop is an explicit pipe — no shared directory exists.
- `create-key` keeps the private key in the snap keyring until `export-key`; deletion is
  opt-in (prompt defaults to "no").
- ed25519/cv25519, passphrase-protected.
- `create-key` accepts all UID fields (name, email, optional comment) via prompt or args.
- `export-key`'s delete-from-keyring prompt defaults to "no" (confirmed).
- `gpg-keys` and the timer's `gpg-public-keys` are removed as unused.
