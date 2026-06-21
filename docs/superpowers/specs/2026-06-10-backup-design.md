# Design: `zwave-js-ui.backup` — encrypted off-box shipper for ZUI's backups

**Date:** 2026-06-10
**Status:** Approved (pending spec review)
**Scope:** Snap packaging only (`src/`, `snap/snapcraft.yaml`). No upstream `zwave-js-ui` code is modified; upstream is consulted read-only.

## Problem & purpose

ZUI can create local backups (NVM + store), but they land **inside `$SNAP_DATA`**, which is wiped on `snap remove` and is exactly what you lose in a rebuild/disaster. ZUI does not ship them off-box.

This feature adds **`zwave-js-ui.backup`**: a single-responsibility tool that **moves ZUI's existing backups safely off-box** — encrypted, incremental, to a configurable remote — and restores them back for ZUI to recover from. Disaster recovery that survives `snap remove`.

## Philosophy — single responsibility

**We relocate; ZUI creates.** This tool does **not** create Z-Wave backups, read live data, manage or enable ZUI's backup settings, or touch the running app. It ships whatever ZUI has already written to its backup directory. If ZUI's scheduled backups aren't enabled, there is simply nothing to ship — and that is fine, not an error.

Consequences of this boundary:
- **No consistency problem.** The artifacts under the backup dir are finalized, closed files ZUI wrote atomically on its own schedule. duplicity reading them is always consistent.
- **No service stop, ever.** We never read live data, so the Z-Wave network is never interrupted.
- **No coupling to ZUI's internals.** We back up the backup *directory tree as-is*; we don't parse filenames or subdirs.

## Source of truth — `backup.dir` → `BACKUPS_DIR`

ZUI's backup directory is set only via the `BACKUPS_DIR` env var (default `$STORE_DIR/backups`); there is no UI/`settings.json` key for the path. (Confirmed upstream: `api/config/app.ts` — `backupsDir = process.env.BACKUPS_DIR || joinPath(storeDir, 'backups')`.)

The snap exposes this as **one config key driving both sides**:

- `snap set zwave-js-ui backup.dir=<path>` is the single source of truth for the backup location.
- `env-wrapper` maps it to `BACKUPS_DIR` for the `zwave-js-ui`/`exec` apps, so **ZUI (writer)** stores backups there.
- The `backup` command reads the **same** resolved value as its **source**, so **the shipper (reader)** stays in lockstep with the writer.

Resolution lives in **one shared helper** in `functions` (e.g. `backup_dir`): use `snapctl get backup.dir`, falling back to **`$SNAP_DATA/backups`** computed at runtime when unset. Both `env-wrapper` (to export `BACKUPS_DIR`) and `bin/backup` (for its source) call this helper — single source of truth in code, not just in config.

Notes:
- Computing the default at **runtime** (not seeding a literal) keeps it correct across refreshes, where `$SNAP_DATA`'s revision component changes.
- Default (`backup.dir` unset) resolves under `$SNAP_DATA` — always writable, no extra interface.
- A `backup.dir` **outside** `$SNAP_DATA` (e.g. a `home`/removable path) requires the matching interface connected for **both** ZUI and `backup`; ZUI runs as root, so destination ownership/permissions must allow it. Avoid revision-embedded paths (`…/x2/…`) — they go stale on refresh.
- `configure` validates `backup.dir` (when set) is an absolute path; an unusable value is rejected with a message.

## Scope

**Back up the entire `$BACKUPS_DIR` tree, as-is** — no globbing, no per-file/subdir logic. Whatever ZUI puts there (today `nvm/NVM_*.bin` + `store/store-backup_*.zip`; tomorrow whatever) is shipped. New backup types are included automatically.

For reference (not relied upon by the code), ZUI currently writes:
- `nvm/NVM_<ts>.bin` — raw controller NVM (the one DR artifact a headless tool can't produce itself; ZUI exports it via the running driver).
- `store/store-backup_<ts>.zip` — a complete, consistent store snapshot **including `settings.json`** (S0/S2 security keys), `scenes/nodes/users/configurationTemplates.json`, and all top-level `*.jsonl` value/node DBs. (Confirmed: `jsonStore.backup()` + `api/config/store.ts`.)

**Empty/absent `$BACKUPS_DIR`** → clean no-op: print a one-line "nothing to back up (ZUI backups not enabled or none yet)" and exit 0. duplicity is never invoked against a missing/empty source. Not a warning, not a prompt to enable anything.

## Engine — duplicity

duplicity provides encrypted, incremental backups to many backends. It is **not in the snap today** and is added via `stage-packages` (duplicity + GnuPG + per-backend libraries; core24/Ubuntu 24.04).

> **Superseded (2026-06-11):** since the core26 base switch, duplicity is pip-installed (pinned + hash-locked, `--no-deps`) and runs on snap-staged Python via `-m duplicity` — see `docs/superpowers/plans/2026-06-11-core26-pip-duplicity.md`. The contract in the rest of this spec is unchanged.

- **Incremental chains** with periodic fulls (`--full-if-older-than`, default `7D`) and pruning (`remove-older-than`, retention configurable).
- **Archive/cache dir** must be stable across runs for incrementals → `--archive-dir "$SNAP_COMMON/duplicity-cache"` (revision-independent, writable).
- The backup **source** is `$BACKUPS_DIR`; the **target** is `backup.target` (a duplicity URL).

## Encryption — asymmetric (no secret in snap config)

Backups are encrypted with **GPG public-key (asymmetric)** encryption, chosen specifically so **no decryption secret is ever stored in snapd config** (where any root user could read it via `snap get`):

- **Backup (encrypt):** `duplicity --encrypt-key <FPR>` to the configured public key. Non-interactive, no secret needed. `backup.encrypt-key=<fingerprint>` in config is **not secret**.
- **Restore (decrypt):** uses the user's **private** key via their real `~/.gnupg` (the `gpg-keys` interface); gpg-agent prompts for the key passphrase. **Interactive** — acceptable because restore is a deliberate manual step.
- `snap get` exposes only the public-key fingerprint and target URL — useless to an attacker.
- **Opt-out:** `backup.encrypt=false` runs `--no-encryption` (plaintext) with a loud warning; backup **refuses to run** if neither `backup.encrypt-key` is set nor `encrypt=false` is chosen.

> Backend-credential caveat: `s3://`/`b2://` etc. credentials, if used, would still sit in `backup.*` config (root-readable). Backends that avoid on-box secrets: `scp`/`sftp` with an SSH key, or local/removable media. Documented; the user chooses.

## Command surface

A single `backup` app (root-required: it reads root-owned `$SNAP_DATA` and writes the archive cache), with subcommands:

```
zwave-js-ui.backup                 # ship $BACKUPS_DIR now (incremental; full if older than threshold)
zwave-js-ui.backup restore [<time>]# fetch+decrypt latest (or at <time>) back into $BACKUPS_DIR
zwave-js-ui.backup list            # duplicity collection-status (available backup sets)
zwave-js-ui.backup status          # show current backup config
zwave-js-ui.backup --help
```

- Unknown subcommand → usage + exit 2.
- A separate snapd `timer:` daemon app runs `backup` on a schedule (see Scheduling).

## Configuration (`snap set zwave-js-ui …`)

Namespace `backup.*` (snapd config — distinct from ZUI's `settings.json` `backup.*`; documented to avoid confusion):

| Key | Meaning | Default |
|-----|---------|---------|
| `backup.dir` | where ZUI writes backups and `backup` reads them; maps to `BACKUPS_DIR` (see "Source of truth") | `$SNAP_DATA/backups` |
| `backup.target` | duplicity target URL (`file://`, `scp://`, `sftp://`, `s3://`, `b2://`, `webdav://`, …). Empty = backup disabled. | (unset) |
| `backup.encrypt-key` | GPG public-key fingerprint to encrypt to (non-secret) | (unset) |
| `backup.encrypt` | `false` to disable encryption (plaintext, warns) | `true` |
| `backup.full-if-older-than` | force a new full chain after this age | `7D` |
| `backup.retention` | prune: keep this many full chains (`remove-all-but-n-full`) | `3` |
| backend creds | e.g. `backup.aws-access-key`, `backup.aws-secret-key`, `backup.b2-*` → mapped to duplicity's env vars | (unset) |

`configure`/install seed no `backup.*` defaults beyond the documented behavior; backup stays off until `backup.target` is set.

## Interfaces & staging (`snap/snapcraft.yaml`)

- **Plugs** on the `backup` app: `network` (remote backends), `home` + `removable-media` (`file://` to user dirs / USB), `gpg-public-keys` (encrypt at backup time), `gpg-keys` (decrypt at restore time). `network` is already declared; the gpg interfaces are not auto-connect and need `snap connect` (documented).
- **`stage-packages`:** `duplicity`, `gnupg`, and the commonly-used backend libs (ssh/paramiko, `python3-boto3` for s3, `b2sdk` for b2, webdav). Exotic backends (Dropbox/gdocs/Azure) documented as addable later, not staged.
- **`BACKUPS_DIR`** is set *dynamically* from `backup.dir` (via the shared `backup_dir` helper), **not** a static `environment:` entry — `env-wrapper` exports it for the `zwave-js-ui`/`exec` apps, and `bin/backup` resolves the same helper for its source. (Static `environment:` can't read `snapctl`.)
- **Timer app** `backup-timer` — a `daemon: oneshot` with a fixed daily `timer: "00:00"` running `bin/backup`. It is **gated in-script on `backup.target`**: unconfigured runs exit 0 quietly (`DAEMONIZED=1`). There is no configurable schedule in this version; the cadence is daily-incremental + weekly-full (via `--full-if-older-than`). A configurable `backup.schedule` is a possible future enhancement.

## Restore flow

`zwave-js-ui.backup restore [<time>]`:
1. duplicity restores the `$BACKUPS_DIR` tree (latest, or at `<time>`) — decrypting via the user's private key (`gpg-keys`, interactive passphrase).
2. Files land back in `$SNAP_DATA/backups/{nvm,store}/`.
3. The command then **points the user at ZUI's in-app restore** (NVM restore + store restore) — ZUI performs the actual recovery. We never apply backups to the live store or stop the service.

This keeps the fiddly, app-specific recovery in ZUI (its supported path) and limits our responsibility to delivering the files.

## Error handling

| Condition | Behavior |
|-----------|----------|
| `backup.target` unset | "backup not configured: set `backup.target`"; exit 0 (scheduled) / exit 1 (manual) |
| `$BACKUPS_DIR` empty/absent | "nothing to back up (enable ZUI's scheduled backups in its settings)"; exit 0 |
| No `backup.encrypt-key` and `encrypt` ≠ `false` | refuse with guidance; exit 1 |
| Missing backend dep / bad creds | surface duplicity's error verbatim |
| Restore without `gpg-keys` connected | hint: `sudo snap connect zwave-js-ui:gpg-keys` |
| Not root | `require_root` (consistent with other service commands) |

## Verification items (resolve during implementation, do not guess)

1. **duplicity on core24 via `stage-packages`** — confirm the package set (duplicity + GnuPG + backend libs) stages and runs under confinement; confirm the binary path and that `--archive-dir`/`GNUPGHOME`/`HOME` are pointed at writable snap dirs.
2. **GPG keyring mechanics under confinement** — where the public key lives at backup time (snap-local keyring in `$SNAP_COMMON/.gnupg` that the user imports into, vs `gpg-public-keys` reading `~/.gnupg`), and how restore reaches the user's private key via `gpg-keys` as root vs the invoking user. Pick the simplest that works; document the import/connect steps.
3. **RESOLVED — timer model:** a static `timer: "00:00"` on a `daemon: oneshot` `backup-timer` app runs `bin/backup` daily; the script no-ops (exit 0, `DAEMONIZED=1`) until `backup.target` is configured. No configurable `backup.schedule` in this version (descoped); cadence is daily-incremental / weekly-full.
4. **`gpg-keys`/`gpg-public-keys` auto-connect** — whether to request store auto-connect or document manual `snap connect`.

## Out of scope (YAGNI)

- Creating Z-Wave backups (NVM/store) — that's ZUI's job; we only ship what exists.
- Triggering ZUI to make a fresh backup via its API.
- Backing up live store data or stopping the service.
- Restoring directly into the running app (ZUI's in-app restore does this).
- Staging every duplicity backend (only the common ones).
