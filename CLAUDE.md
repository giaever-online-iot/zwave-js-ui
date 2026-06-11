# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is a **snap packaging wrapper** for [Z-Wave JS UI](https://github.com/zwave-js/zwave-js-ui), not the application itself. The upstream app is downloaded from npm at build time. This repo contributes:

- The snap build recipe (`snap/snapcraft.yaml`)
- Snap lifecycle hooks and user-facing commands (`src/`)
- A config-translation layer that maps snap configuration to the env vars the upstream app expects
- CI that auto-tracks upstream releases and publishes to the Snap Store

The published snap lives at `snapcraft.io/zwave-js-ui`; issues for *this packaging* go to `github.com/giaever-online-iot/zwave-js-ui`.

## Build & development commands

There is no `npm`/test toolchain at the repo root — everything is built by snapcraft.

```bash
# Build the snap locally (run from repo root, needs snapcraft + LXD/multipass)
snapcraft

# Remote build for multiple architectures (what CI uses, via Launchpad)
snapcraft remote-build -v --launchpad-accept-public-upload --build-for=amd64,arm64,armhf

# Clean a part to force a rebuild
snapcraft clean zwave-js-ui

# Install a locally built snap for testing (interfaces won't auto-connect)
sudo snap install --dangerous ./zwave-js-ui_*_amd64.snap
sudo snap connect zwave-js-ui:raw-usb
sudo snap connect zwave-js-ui:hardware-observe
```

`yq` is used pervasively (build step, CI, helper scripts). The build pins Node `22.20.0` and `core26` as the snap base.

### Inspecting / running the installed snap

The daemon is **disabled by default** after install — the user must enable it explicitly. The `apps` block in `snapcraft.yaml` exposes these commands:

```bash
zwave-js-ui.help       # full usage + current config; START HERE
zwave-js-ui.enable     # daemonize (snapctl start --enable)
zwave-js-ui.disable    # de-daemonize
zwave-js-ui.restart
zwave-js-ui.exec       # run the app in the foreground (debug boot issues before enabling)
zwave-js-ui.logs       # unified, terminal-friendly live log view; append zui|zwjs to filter
zwave-js-ui.backup     # ship ZUI's backups off-box via duplicity (restore|list|status|pick-key|import-key|create-key|export-key)
snap logs zwave-js-ui -f                  # manual fallback when "log to file" is OFF (syslog/journal)
tail -f $SNAP_DATA/*.log                  # manual fallback when "log to file" is ON
```

## Architecture

### Version flow (how the upstream app gets in)

1. `snap/snapcraft.yaml` has `version: vX.Y.Z` matching an upstream GitHub release tag.
2. `src/node/package.json` is a stub package named `zui-snap` with **no** `zwave-js-ui` dependency in the file.
3. The `zwave-js-ui` part's `override-build` strips the leading `v` and uses `yq` to write the version into both `.version` and `.dependencies.zwave-js-ui` of `package.json` before `craftctl default` runs the npm plugin — so the correct upstream release is pulled at build time.
4. Renovate (`renovate.json`) watches `zwave-js/zwave-js-ui` GitHub releases and opens PRs bumping `version:` in `snapcraft.yaml`. **When changing the packaged app version, edit `snapcraft.yaml` `version:` only** — do not hand-edit `package.json`. Renovate's `pip_requirements` manager also opens duplicity bump PRs for `requirements-duplicity.txt`; those build via CI (the workflows' `paths:` filters include the file) but fail closed until the hash refresh described in the file's header is applied.

### Config translation layer (the core abstraction)

Snap users set config with `snap set zwave-js-ui server.host=0.0.0.0` (namespaces: `server.*`, `session.*`, `mqtt.*`, `timezone`). The upstream app reads plain env vars instead. The bridge:

- `src/helper/env-wrapper` is the snap `command-chain` for the `zwave-js-ui` and `exec` apps. It reads config via `snapctl get`, maps it to env vars (`server.host`→`HOST`, `server.ssl`→`HTTPS`, `session.secret`→`SESSION_SECRET`, `mqtt.name`→`MQTT_NAME`, `timezone`→`TZ`, etc.), unsets vars that should be absent, then `exec`s the real binary. SSL/secure-cookie logic has interdependencies — read this file before touching auth/SSL behavior.
- `src/helper/functions` is a shared bash library sourced by every hook and bin script. Key helpers: `test_default_config` (seeds defaults via `testnset_config`), `plugs_connected` (requires `hardware-observe` AND one of `raw-usb`/`serial-port`), `require_root`, and `lprint`.

### `DAEMONIZED` logging convention

`lprint` (in `functions`) routes output to `logger`/syslog when `DAEMONIZED` is set, otherwise to stdout. Hooks export `DAEMONIZED=1`; the daemon app sets it via `environment:` in `snapcraft.yaml`. Interactive bin commands leave it unset so messages reach the terminal. Honor this when adding user-facing output.

### Snap lifecycle hooks (`src/hooks/`, organized into `snap/hooks` at build)

- `configure` — validates `server.port`/`server.ssl`/`session.cookie-secure` types, seeds defaults, restarts the service. Runs on every `snap set`.
- `install` / `post-refresh` — seed defaults; `install` then disables the daemon by default (the user enables it explicitly with `zwave-js-ui.enable`).
- `pre-refresh` — runs `test_device_priority_dir` (rewrites stale `deviceConfigPriorityDir` paths that embedded the old revision number) and clears the external-config `devices/index.json` so it rebuilds.

### User commands (`src/bin/`)

`daemonize`/`de-daemonize`/`restart` wrap `snapctl` service control and require root + connected plugs. `logs` is the unified, terminal-friendly log follower. `backup` ships ZUI's backup directory (`$BACKUPS_DIR`, default `$SNAP_DATA/backups`) off-box via **duplicity** — encrypted (asymmetric GPG), incremental, optional daily timer — and restores it back for ZUI's in-app recovery. It does **not** create backups itself: it requires ZUI's own scheduled backups to be enabled (off by default) and is configured via `snap set zwave-js-ui backup.*` (`backup.target`, `backup.dir`, `backup.encrypt-key`, …). duplicity itself is pip-installed at build time from `requirements-duplicity.txt` (pinned + hash-locked, `--no-deps` — bump version AND hashes together) and runs on the snap-staged Python (`$SNAP/usr/bin/python3 -m duplicity`); its runtime deps are archive debs in the `backup-deps` part (except pure-Python `python-gettext`, which has no resolute deb and rides in the requirements file). A fixed daily timer runs it once `backup.target` is set. See `docs/superpowers/specs/2026-06-10-backup-design.md`.
  Key management for the encryption key lives in `backup` subcommands: `pick-key` (run **without** sudo — lists/exports a public key from the *user's* `~/.gnupg`, since root can't read it), piped into `import-key` (root: store the public key in the snap keyring at `$SNAP_COMMON/.gnupg` and set `backup.encrypt-key`); `create-key` (root: generate an ed25519/cv25519 keypair in the snap keyring); and `export-key` (root: export the private key to move it to the host/offline, with an opt-in delete). Only `gpg-public-keys` is needed (on the `backup` app, for `pick-key`); `gpg-keys` and the timer's `gpg-public-keys` were removed as unused. See `docs/superpowers/specs/2026-06-10-backup-key-management-design.md`.

### Paths & layout

`STORE_DIR=$SNAP_DATA`, external config at `$SNAP_DATA/.ext-config`. The npm cache is redirected via a `layout:` bind to `$SNAP/.cache/npm` to keep it out of the writable store dir. The `store-dir` content slot exposes `$SNAP_DATA` for the optional `code-server` integration.

## CI / contribution rules

- **PRs must target `main` and originate from a branch in this repo. PRs from forks are auto-closed and labeled** by `.github/workflows/block-fork-prs.yml`.
- `pr-build-snap.yml` builds the snap via Launchpad remote-build on PRs (skips doc/config-only changes), then **publishes each arch to the per-PR channel `v<major.minor>/edge/<PR#>`** in the Snap Store, creating the `v<MM>` track first if missing (dashboard `create-track` API via the `SNAPCRAFT_SESSION` secret). Partial-arch builds upload what succeeded and mark the check failed. A sticky PR comment shows the channel + install command.
- `release-on-merge.yml` runs when a PR merges: it **promotes the PR's revisions** from `v<MM>/edge/<PR#>` to `v<MM>/stable` and `latest/candidate` + `latest/edge` (and bumps the previous major's final to `latest/stable` on a major release), closes the PR branch, and sets the newest `v<MM>` as the default track. All version/channel math lives in `.github/scripts/snap-release.sh` (unit-tested via `snap-release.test.sh`).
- Release channels (`latest/stable`, `latest/candidate`, `latest/edge`) and version tracks (e.g. `v9.11`) are documented in `README.md`.
