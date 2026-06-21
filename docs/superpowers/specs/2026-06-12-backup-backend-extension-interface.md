# Backup backend extension interface — design spec

**Status:** accepted design, NOT yet implemented — scoped as its own PR after #201 merges.
**Decided (2026-06-12):** the core snap ships the basic backends built in — `file://`,
sftp (paramiko), s3 (boto3), b2 (b2sdk), gdrive (google-api libs, service-account auth
via `backup.gdrive-credentials`). The extension interface exists for **custom** backends
(user-made or third-party), not for relocating the built-ins.

## Problem

duplicity supports many more backends (azure, swift, dropbox, webdav, …) than the core
snap should carry. Users who need an exotic backend — or a private/proprietary one —
must today wait for a core release that stages its Python libraries. Size is secondary
(the movable libs are ~12–15 MB compressed); the real goal is an open extension point
with no core-release coupling.

## Mechanism: snapd content interface

A **provider snap** exposes a read-only directory of Python packages; the core snap
mounts it and prepends it to the `PYTHONPATH` the backup script already exports.

### Core snap side (one-time PR)

```yaml
plugs:
  backup-backend-libs:
    interface: content
    content: zui-backup-backend-libs
    target: $SNAP_DATA/.backup-backends   # appears only when a provider is connected
```

`src/bin/backup` (main, next to the existing PYTHONPATH export):

```bash
# Custom backend libs grafted in via the content interface (empty when none).
BACKEND_LIBS="$SNAP_DATA/.backup-backends"
[ -d "$BACKEND_LIBS" ] && export PYTHONPATH="$BACKEND_LIBS:$PYTHONPATH"
```

Error UX: when duplicity fails with `ImportError`/"BackendException: … requires …",
the backup script appends a hint: *"this backend's Python libraries are not in the
snap — provide them with a backend snap connected to zwave-js-ui:backup-backend-libs"*.

### Provider snap contract (documented for users)

- Slot: `interface: content`, `content: zui-backup-backend-libs`, `read: [$SNAP/libs]`.
- `$SNAP/libs` contains importable Python packages (what `pip install --target` makes).
- **ABI rule:** must build against the same base as the core snap (core26 / Python 3.14).
  Pure-Python wheels are strongly recommended; binary wheels must match cp314 and the
  base bump cadence (a core base change is a breaking change for binary providers).
- Connection: `snap connect zwave-js-ui:backup-backend-libs <provider>:libs` — manual
  for third-party publishers (deliberate consent; see Trust), store-grantable for any
  first-party optional provider we publish later.

## Trust model (must be in user docs, loudly)

Provider code is imported by a root process that holds the snap GPG keyring and
network access. Connecting a third-party backend snap is equivalent to giving its
publisher root inside the backup job. Manual `snap connect` is the consent step —
the interface must never be auto-connected for arbitrary publishers.

## Credentials companion feature (same PR)

Backends authenticate via env vars (s3: `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`;
custom backends: theirs). The daily timer cannot receive ad-hoc env vars, so add:

- `backup.env-file=<path under $SNAP_DATA or $SNAP_COMMON>` — a root-owned `KEY=VALUE`
  file; the backup script validates ownership/mode (0600, root) and exports its
  entries before invoking duplicity. This also closes the existing "s3 works manually
  but not on the timer" gap for the built-ins.

## Out of scope

- Relocating built-in backends out of the core (explicitly decided against).
- A first-party "extra backends" companion snap (possible later; this interface is
  the prerequisite either way).
- Running provider *daemons* — providers are passive library carriers only.

## Verification sketch

- Unit: PYTHONPATH grafting + env-file parsing/permission checks (pure helpers).
- On-device: a throwaway provider snap (e.g. carrying `python3-swiftclient`) built in
  `.test/`, connected, then `backup.target=swift://…` exercised against a local
  mock or a real account; disconnect → confirm the guidance error appears.
