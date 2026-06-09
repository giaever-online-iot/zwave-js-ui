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

`yq` is used pervasively (build step, CI, helper scripts). The build pins Node `22.20.0` and `core24` as the snap base.

### Inspecting / running the installed snap

The daemon is **disabled by default** after install — the user must enable it explicitly. The `apps` block in `snapcraft.yaml` exposes these commands:

```bash
zwave-js-ui.help       # full usage + current config; START HERE
zwave-js-ui.enable     # daemonize (snapctl start --enable)
zwave-js-ui.disable    # de-daemonize
zwave-js-ui.restart
zwave-js-ui.exec       # run the app in the foreground (debug boot issues before enabling)
snap logs zwave-js-ui -f                  # when "log to file" is OFF (logs to syslog)
tail -f $SNAP_DATA/*.log                  # when "log to file" is ON
```

## Architecture

### Version flow (how the upstream app gets in)

1. `snap/snapcraft.yaml` has `version: vX.Y.Z` matching an upstream GitHub release tag.
2. `src/node/package.json` is a stub package named `zui-snap` with **no** `zwave-js-ui` dependency in the file.
3. The `zwave-js-ui` part's `override-build` strips the leading `v` and uses `yq` to write the version into both `.version` and `.dependencies.zwave-js-ui` of `package.json` before `craftctl default` runs the npm plugin — so the correct upstream release is pulled at build time.
4. Renovate (`renovate.json`) watches `zwave-js/zwave-js-ui` GitHub releases and opens PRs bumping `version:` in `snapcraft.yaml`. **When changing the packaged app version, edit `snapcraft.yaml` `version:` only** — do not hand-edit `package.json`.

### Config translation layer (the core abstraction)

Snap users set config with `snap set zwave-js-ui server.host=0.0.0.0` (namespaces: `server.*`, `session.*`, `mqtt.*`, `timezone`). The upstream app reads plain env vars instead. The bridge:

- `src/helper/env-wrapper` is the snap `command-chain` for the `zwave-js-ui` and `exec` apps. It reads config via `snapctl get`, maps it to env vars (`server.host`→`HOST`, `server.ssl`→`HTTPS`, `session.secret`→`SESSION_SECRET`, `mqtt.name`→`MQTT_NAME`, `timezone`→`TZ`, etc.), unsets vars that should be absent, then `exec`s the real binary. SSL/secure-cookie logic has interdependencies — read this file before touching auth/SSL behavior.
- `src/helper/functions` is a shared bash library sourced by every hook and bin script. Key helpers: `test_default_config` (seeds defaults via `testnset_config`), `plugs_connected` (requires `hardware-observe` AND one of `raw-usb`/`serial-port`), `require_root`, and `lprint`.

### `DAEMONIZED` logging convention

`lprint` (in `functions`) routes output to `logger`/syslog when `DAEMONIZED` is set, otherwise to stdout. Hooks export `DAEMONIZED=1`; the daemon app sets it via `environment:` in `snapcraft.yaml`. Interactive bin commands leave it unset so messages reach the terminal. Honor this when adding user-facing output.

### Snap lifecycle hooks (`src/hooks/`, organized into `snap/hooks` at build)

- `configure` — validates `server.port`/`server.ssl`/`session.cookie-secure` types, seeds defaults, restarts the service. Runs on every `snap set`.
- `install` / `post-refresh` — seed defaults; `install` honors a `$SNAP_DATA/.install.hook.service` sentinel file to decide enable/disable (defaults to disabled).
- `pre-refresh` — runs `test_device_priority_dir` (rewrites stale `deviceConfigPriorityDir` paths that embedded the old revision number) and clears the external-config `devices/index.json` so it rebuilds.
- `disconnect-slot-store-dir` — re-enables the service when the `store-dir` content slot is disconnected.

### User commands (`src/bin/`)

`daemonize`/`de-daemonize`/`restart` wrap `snapctl` service control and require root + connected plugs. `backup` and `logs-observe` are present but minimal/WIP.

### Paths & layout

`STORE_DIR=$SNAP_DATA`, external config at `$SNAP_DATA/.ext-config`. The npm cache is redirected via a `layout:` bind to `$SNAP/.cache/npm` to keep it out of the writable store dir. The `store-dir` content slot exposes `$SNAP_DATA` for the optional `code-server` integration.

## CI / contribution rules

- **PRs must target `main` and originate from a branch in this repo. PRs from forks are auto-closed and labeled** by `.github/workflows/block-fork-prs.yml`.
- `pr-build-snap.yml` builds the snap via Launchpad remote-build on PRs (skips doc/config-only changes), then uploads per-arch artifacts. It can be run manually via `workflow_dispatch` with platform selection or by reusing a prior run's artifacts (`run_id`).
- `snap-create-track.yml` runs after a successful build to create version tracks and set the default track in the Snap Store.
- Release channels (`latest/stable`, `latest/candidate`, `latest/edge`) and version tracks (e.g. `v9.11`) are documented in `README.md`.
