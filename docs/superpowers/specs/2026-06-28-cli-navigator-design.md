# CLI Navigator (`zwave-js-ui.ui`) — Design

**Status:** approved design, pre-plan.
**Supersedes:** the Phase-2 sketch in `2026-06-11-cli-ui-design.md` (this is the detailed version).

## Goal

An interactive, root-only TUI that lets an operator **browse and act on** the
snap's configuration, service, plugs, and logs from one place — Phase 2 of the
CLI-UI work. It answers the original ask ("browse each config option, command,
plug…") with a guided, terminal-fitting interface: no wrapping, no raw-JSON
editing, every change validated by the existing authority.

Non-goals (v1): editing the full ZUI `settings.json` (see Phase 2b), replacing
the web UI, or any non-interactive/scriptable surface (that stays the existing
`snap set` + bin commands).

## Context (what already exists, and is reused — not duplicated)

- `src/helper/ui` — the gum chokepoint (`ui_choose`/`ui_input`/`ui_confirm`/
  `ui_table`/`ui_stack`/`ui_err`/`ui_pager`, context rules: styled/plain/syslog,
  widgets return 2 without a TTY).
- `src/helper/catalog` — the snap-settings catalog (key/type/default/description)
  that already drives `help`'s settings table.
- `src/helper/functions` — `require_root`, `plug_connected`/`plugs_connected`,
  `lprint`, `ui_interactive`.
- Bin commands: `help`, `daemonize`/`de-daemonize`/`restart`, `logs`, `backup`.
- The `configure` hook — the single validator for snap config (types, port range,
  SSL/cookie interdependencies) and the thing that restarts the daemon on change.

## Architecture

A new app **`zwave-js-ui.ui` → `src/bin/ui`**, a plain app (NOT through
`env-wrapper`; it is not the daemon). It is a **thin orchestrator**: it sources
`functions`, `ui`, `catalog`, then loops a `ui_choose` main menu. Each section is
one function in the file that **browses** via the existing catalog + `ui_*` and
**acts** by calling what already exists (`snapctl`, the bins). No validation,
settings, or service logic is reimplemented.

```
┌ zwave-js-ui · vX.Y.Z · enabled · active ┐   ← shared status header (ui_header)
└─────────────────────────────────────────┘
  Settings        view & change snap config
  Service         enable / disable / restart
  Plugs           USB / serial interface status + connect
  Live logs       follow zui / zwjs / both
  Help            static overview
  Quit
```

**Guards (decided):**
- `require_root` up front (one clear message, then exit) — acting needs root;
  non-root browsing is already served by `help`.
- No TTY (`ui_interactive` false) → print "needs an interactive terminal — see
  `zwave-js-ui.help`" and exit 2.
- `ui_choose` returns 2 on Ctrl-C/Esc/no-TTY → the loop treats 2/empty as
  back/Quit, so every menu backs out cleanly.

**Shared header:** the `name · version · status` banner currently lives in
`help`; factor it into a small `ui_header` helper used by both `help` and `ui`
(DRY) rather than duplicated.

## Sections

### §1 — Shell
Menu loop, `ui_header`, root/no-TTY guards, dispatch to `nav_*` functions,
redraw on return, Quit. Each section function returns to the loop (never
`exit`s the navigator).

### §2 — Settings (snap config; browse + act)
- **Browse:** list the catalog as `key = current-value` rows via
  `ui_choose`/filter (type-ahead, with each key's description shown); current
  values from `snapctl get`. Pick a key → detail card (`ui_stack`): current,
  default, type, description.
- **Act:** Edit / Reset to default / Back. Edit prompt by type — `bool`→
  `ui_choose true/false`; `int`/`string`→`ui_input` prefilled; `session.secret`
  special-cased (generated → warn/regenerate, not blind free-text).
- **Apply:** `snapctl set <key>=<value>` → snapd runs the **`configure` hook**
  (unchanged validator) → restart. Success → show new value. Rejection (hook
  non-zero → snapd rolls back) → surface the hook's message in `ui_err`, keep the
  old value. Reset = `snapctl unset <key>`.
- The navigator never re-implements validation; it surfaces the hook's verdict.
  Like `snap set`, each edit triggers a restart (batching is a later optimization).

### §3 — Service & Plugs
- **Service (browse + act):** state (`enabled/disabled · active/inactive`) from
  `snapctl services`; actions Enable/Disable/Restart call the existing
  `daemonize`/`de-daemonize`/`restart` bins as subprocesses (they keep their own
  root + connected-plugs checks). Show output, re-read status, return.
- **Plugs (browse + guide):** a small plug catalog (name → purpose) with live
  status via `plug_connected`/`snapctl is-connected`: `hardware-observe` +
  `raw-usb`/`serial-port` (the controller), `log-observe` (journald logs),
  `gpg-public-keys` (backup key picker). For a disconnected plug, show the exact
  `snap connect zwave-js-ui:<plug>` command (and the `experimental.hotplug`
  enablement for `serial-port`) in a copyable block. A confined snap cannot run
  `snap connect` (snapd does that host-side), so the navigator **guides**, never
  auto-connects; connected plugs show ✓.

### §4 — Live logs + Help
- **Live logs:** `ui_choose all/zui/zwjs` → run the existing `logs <target>` as a
  foreground child (the `less +F -R -f` viewer with the scroll-back hint). Quit
  the viewer (`q`) → back to the menu. No new log logic.
- **Help:** run the existing `help` (static overview). Reuse.

## Phase 2b (follow-up, NOT in v1) — curated `settings.json` editor

A guided editor (`gum filter` + typed prompts + `yq` write, **no `nano`**) for the
useful **`settings.json`-only** keys that have **no env-var path** and so cannot
be reached via §2: **MQTT broker connection** (`mqtt.host`/`port`/auth),
`zwave.serialPort`, security keys. Warn-if-running, validate, atomic move,
restart offer.

**Why deferred / why hand-curated:** investigated upstream — ZUI's settings.json
is TypeScript interfaces (`api/config/store.ts`: `mqtt`/`zwave`/`gateway`/
`zniffer`/`ui`) with **no human-readable descriptions** (those live in the web-UI
forms/i18n). The one described source, `docs/guide/env-vars.md`, is a **subset**
that ≈ what §2 already covers. So a schema-derived editor isn't feasible;
descriptions must be hand-authored regardless — same effort as extending §2's
catalog. v1's env-var-mapped settings are already in §2; 2b only adds value for
the settings.json-only keys (notably configuring the MQTT broker from the CLI).

## Incremental delivery (one plan, these increments)

1. **Shell + Service** — proves the menu loop with the simplest act.
2. **Settings** — the meaty browse → edit → validate path.
3. **Plugs** — browse status + connect guidance.
4. **Live logs + Help** — thin shell-outs.

*(Later: Phase 2b — the curated `settings.json` editor.)*

Each increment is an independently testable deliverable; the navigator stays
usable after each (later sections appear as menu items only once implemented).

## Error handling

- Root and no-TTY guarded by the shell; menu backs out on `ui_choose`=2.
- §2: `configure`-hook rejection → `ui_err` + old value kept.
- §3: a failed service action shows the bin's stderr; Plugs is read-only + guidance.
- All sections return to the loop on error — one failure never kills the navigator.

## Testing

Unit tests follow the established harness: source the script, stub `gum`
(`ui_choose`/`ui_input`/filter scripted), `snapctl` (`get`/`set`/`unset`/
`services`/`is-connected`), the service bins (or `snapctl start/stop`), and a
catalog fixture. Per-section assertions:
- §1: scripted menu sequence dispatches the right `nav_*`; no-TTY prints the
  pointer + returns 2; non-root refused.
- §2: edit → exact `snapctl set key=value`; rejection (stub non-zero) → `ui_err`,
  value unchanged; reset → `snapctl unset`.
- §3: action → right bin/command + status re-read; Plugs render connected vs
  disconnected and show `snap connect …` only for disconnected.
- §4: selection → `logs <target>` / `help` invoked.
- PTY (`script(1)`) tests where the flow is genuinely interactive, as for `logs`.

## Packaging

`snapcraft.yaml` `apps.ui` → `bin/ui` (plain app, no command-chain). `gum` is
already built. **No new stage-packages** for v1 (the catalog-driven editors avoid
`nano`); Phase 2b also needs none (it uses `gum` + `yq`).

## Open item to confirm in the first Settings task (a quick spike)

That `snapctl set` **from the `ui` app** triggers the `configure` hook and returns
its pass/fail (rollback + stderr on rejection) — snapd's documented behaviour,
the same path as `snap set`. If rejection isn't surfaced cleanly, adjust the
apply mechanism (e.g. read the hook's result explicitly) before building the rest
of §2. This is the only thing that could reshape the design.
