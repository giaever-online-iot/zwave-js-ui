# Uniform terminal/CLI UI (gum) — design

**Date:** 2026-06-11
**Status:** approved (brainstorming session)

## Problem

The snap's user-facing commands have no shared visual language. `help` is ~50 raw
`echo` lines (with typos) dumping `snapctl get … -d` JSON inline; `logs` has its own
private ANSI helpers; `backup` writes `lprint` one-liners and raw duplicity dumps;
`enable`/`disable` print ad-hoc hints; `restart` is silent on success. There is no
readable way to browse or edit settings, and no menu-driven entry point at all.

## Goal

A uniform terminal/CLI UI across every command endpoint, plus an interactive
navigator, built on **gum** (charmbracelet) as the rendering/interaction engine.

### In scope

- **Phase 1** — a shared gum-backed UI library (`src/helper/ui`); rewrite all
  command endpoints (`help`, `enable`, `disable`, `restart`, `logs`, `backup`) to
  use it; humanize `backup status` and `backup list` output.
- **Phase 2** — an interactive navigator app (`zwave-js-ui.ui`) offering:
  snap-config browse + edit, ZUI `settings.json` editing in an editor with JSON
  validation, live-log viewing with a stream picker (all | zui | zwjs), and
  service status/actions.

Each phase gets its own implementation plan and PR; phase 1 lands first.

### Out of scope

- Historical/rotated log paging (the live follower remains the only log reader).
- Read-only pretty viewer for `settings.json` (editing covers inspection).
- Editing `settings.json` keys individually from the navigator menu (whole-file
  editor only).
- Any change to the daemon, env-wrapper config translation, hooks' validation
  rules, or the `logs` follower machinery.

## Decisions made during brainstorming

1. **Both phases, staged** — library + restyle first, navigator second.
2. **gum for all endpoints** — chosen over a pure-bash styling lib and over
   whiptail/dialog, accepting ~15 MB/arch and a Go build part for a uniform,
   polished look everywhere.
3. **gum built from source** — snapcraft `go` plugin part pinned to a release tag
   (not downloaded release binaries), so Launchpad remote-build covers
   amd64/arm64/armhf without a per-arch checksum table. Renovate watches the tag.
4. **`settings.json` must be editable** — in a staged editor (nano), validated,
   with a restart offer; *not* read-only.
5. **Live logs in the navigator returns to the menu on Ctrl-C** — not exit to
   shell.
6. **Keep it tight** — remaining audit gaps (historical paging, settings.json
   viewer) are explicitly future work; humanized backup output is in.

## Architecture

```
src/helper/ui          NEW: gum-backed UI library (sourced like functions)
src/helper/functions   unchanged; lprint remains the daemon/hook primitive
src/bin/help           NEW: help moves out of env-wrapper
src/bin/{daemonize,de-daemonize,restart,logs,backup}   restyled via ui
src/bin/ui             NEW (phase 2): interactive navigator
snap/snapcraft.yaml    new `gum` part; stage nano; new `ui` app; help app points
                       at bin/help
```

The `ui` library is the **only** place gum is invoked. Commands call `ui_*`
functions, never `gum` directly. That chokepoint enforces the uniform look and
centralizes fallback behavior.

## The `ui` library contract

Output context is resolved once (a pure function of environment, unit-testable):

| Context | Behavior |
|---|---|
| TTY + gum present | styled output, interactive widgets allowed |
| no TTY, `NO_COLOR`, or `TERM=dumb` | plain text, identical wording, zero ANSI bytes |
| `DAEMONIZED=1` | route through `lprint` (syslog); never styled |
| gum missing/broken | plain text; decoration failure is never a hard failure |

Functions:

| Function | Interactive (TTY) | Fallback |
|---|---|---|
| `ui_header title` | styled banner (name · version · service state) | `== title ==` |
| `ui_kv` / `ui_table` | aligned, colored table | `key: value` lines |
| `ui_ok` / `ui_warn` / `ui_err` | ✓ / ! / ✗ glyph + color | plain text via `lprint` routing |
| `ui_choose prompt items…` | `gum choose` arrow-key menu | **exit 2** + one-line hint naming the non-interactive alternative |
| `ui_input` | `gum input` | read from piped stdin if present, else exit 2 |
| `ui_confirm` | `gum confirm` | read `y/N` from piped stdin if present (keeps `echo y \| …` automation working), else exit 2 |
| `ui_spin msg cmd…` | `gum spin` while running | print msg, run cmd |
| `ui_usage` | uniform help/usage layout | same, uncolored |

**Interactive widgets are additive, never load-bearing:** every command keeps an
argument-driven path (`logs zui`, `backup restore`), so scripts, the timer, and
pipes never hit a widget.

## Phase 1 — command restyle

Common skeleton: `ui_header` → body → `ui_ok`/`ui_err` outcome.

- **help** — moves from `env-wrapper --help` into `src/bin/help`; `env-wrapper`
  keeps only env translation (its `--help` branch is deleted; the `help` app's
  command changes to `bin/help`). Renders: header (version + daemon state), a
  settings table (key · current value · default · description) replacing the raw
  JSON dumps, a command list, and the serial-port guide as a footnote section.
- **enable / disable** — plug-check failures become `ui_err` blocks with styled
  connect commands; success is `ui_ok` plus a short next-steps table (log
  commands). Same message content as today, uniform rendering.
- **restart** — no longer silent: `ui_spin` around `snapctl restart`, then
  `ui_ok`.
- **logs** — follower machinery, stream-prefix colors, and tested helpers
  untouched. `usage()` re-rendered via `ui_usage`. New: interactive no-arg run
  shows `ui_choose` (all | zui | zwjs); non-TTY no-arg keeps today's default
  (merged both), so `sudo zwave-js-ui.logs | grep …` is unchanged.
- **backup** — `lprint` user messages become `ui_ok/warn/err`; `status` becomes a
  table: target, dir, encrypt-key (+ whether the private key is on-device),
  retention, timer state. `list` parses duplicity `collection-status` into a
  table (date · full/incremental · volumes) via a pure, unit-tested parser.
  Key subcommands use `ui_input` (name/email) and `ui_confirm` (private-key
  delete). The daemonized timer path degrades to today's plain `lprint`
  behavior throughout.

## Phase 2 — navigator (`zwave-js-ui.ui`)

New app `ui` → `src/bin/ui`, requires root, loops over `ui_choose` menus:

```
Main menu
├─ Settings (snap config)  table of all keys/values → pick key →
│                          ui_input (or ui_choose for booleans) → snap set
├─ Edit ZUI settings.json  staged nano → validate JSON → restart offer
├─ Live logs               ui_choose all|zui|zwjs → run logs follower;
│                          Ctrl-C returns to this menu
└─ Service                 status + enable/disable/restart actions
```

- **Settings editing** — wraps `snap set`; the `configure` hook remains the
  single source of validation truth. On hook rejection, show its stderr in a
  `ui_err` block and return to the menu with the old value intact. A static
  settings catalog (key, type, default, description) drives both this menu and
  the `help` settings table.
- **settings.json editing** — warn (not block) if the daemon is running (the app
  rewrites the file on its own saves). Edit a tempfile copy in staged nano;
  validate with `yq` on save; invalid → re-edit or discard; valid → atomic move
  over the original, then `ui_confirm "Restart daemon?"`. A broken file is never
  written.
- **Live logs, return-to-menu** — the navigator runs the `logs` script as a
  foreground child with its own `INT` trap set to a no-op around the wait.
  Ctrl-C signals the whole foreground process group: the logs script's existing
  trap reaps its `tail`/`journalctl` followers and exits; the navigator survives
  and redraws the menu. No new process-group machinery.

## Packaging changes (snapcraft.yaml)

- New part `gum`: `go` plugin, `source: https://github.com/charmbracelet/gum`,
  `source-tag` pinned; Renovate rule added to track gum releases.
- Stage `nano` (for settings.json editing; strict confinement forbids exec'ing
  host editors — only binaries inside the snap are reachable).
- New app `ui` (no extra plugs beyond what service control needs).
- `help` app command changes from `helper/env-wrapper --help` to `bin/help`.

## Error handling summary

- Context matrix above governs all rendering; wording is identical styled vs
  plain so docs/issues quote one canonical text.
- Interactive widget in non-TTY context → exit 2 + hint (e.g. `no TTY — pass a
  stream: zwave-js-ui.logs zui`).
- gum absent → plain-text fallback, never abort.
- `snap set` rejected by hook → styled error, old value intact.
- settings.json: tempfile + validate + atomic move; daemon-running warning.

## Testing

Same source-the-script pattern as `logs`/`backup`:

- **Pure helpers unit-tested:** context resolution (env → styled/plain/syslog),
  duplicity collection-status parser, settings catalog accessors, JSON-validation
  wrapper.
- **gum stub:** tests prepend a fake `gum` shim to `PATH` that records argv and
  emits canned selections, making menu dispatch testable without a TTY.
- **Fallback assertions:** every `ui_*` function tested in non-TTY mode emits
  zero ANSI bytes (guards the syslog/journal path).
- **Regression:** existing `logs`/`backup` unit tests keep passing; restyling
  must not change tested helpers' contracts.

## Risks / trade-offs accepted

- ~15 MB per arch for gum and a Go toolchain at build time (user-accepted).
- gum is a new supply-chain dependency; mitigated by pinned tag + source build.
- nano staged for editing (small, ~0.7 MB).
- Two visual systems exist transiently inside `logs` (its stream-prefix ANSI
  colors are kept by design — they tag log *data*, not chrome).
