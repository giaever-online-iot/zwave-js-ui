# Responsive CLI UI — every command fits the terminal — design

**Date:** 2026-06-21
**Status:** approved (brainstorming session)

## Problem

The gum CLI UI does not consistently fit the terminal:

- **Width.** Only `help` was made width-aware, and with bespoke logic living in
  `src/bin/help` (`settings_render`/`commands_render`/`settings_stack`/
  `commands_stack`). Other `ui_table` callers — `backup status` (`ui_kv`) and
  `backup list` — still emit fixed-width tables that overflow a narrow terminal
  and get hard-wrapped into mush.
- **Height.** Bounded output taller than the screen (a long `help`, a long
  `backup list`) scrolls off the top; there is no in-app way to page back.
- **Live logs.** `logs` streams an unbounded `tail -F` / `journalctl -f`; you
  cannot scroll back through it without fighting the incoming lines.

## Goal

Every command's output **fits the terminal** — width *and* height — with the
responsiveness centralized in the `ui` library (the single place gum is invoked),
not special-cased per command. The live log follower is reshaped into a
follow-*and*-scroll viewer.

### In scope

- `ui_lines` — terminal-height primitive (twin of `ui_cols`).
- `ui_table` made width-fit **globally**: the "stack when wider than the
  terminal" behavior moves out of `bin/help` and into `ui_table`, with one
  generic stacked form for any N-column table. Benefits `help`, `backup status`,
  `backup list`.
- `ui_pager` — scroll bounded output that overflows the screen height.
- Route `help`, `backup status`, `backup list` through `ui_pager`.
- Reshape the live `logs` follower into `less +F -R` (follow + scroll) on a TTY.
- Stage `less` in the snap.

### Out of scope

- A custom Go / Bubble Tea TUI (a live, gum-styled log viewport would require a
  new binary — disproportionate; `less +F` is the right tool).
- gum-styling `less`'s own chrome (we keep the log stream-prefix colors via `-R`;
  `less`'s status line stays `less`'s).
- Live re-flow of our **bash-side** layout snapshots: `ui_cols`/`ui_lines` are
  read once per render. gum widgets handle their own SIGWINCH resize while
  active; one-shot commands need no live re-flow, and the (future) navigator
  re-renders each menu loop anyway.
- The phase-2 navigator itself. When it is built, its menus/filters consume
  `ui_lines` to height-cap `gum choose`/`gum filter`; that wiring belongs to the
  navigator plan, not this one.

## Decisions made during brainstorming

1. **Responsiveness belongs in the `ui` library**, not bolted onto one command —
   "any command needs to fit the UI."
2. **One generic stacked table form for all tables** (title row, then indented
   `header: value` lines), replacing help's bespoke `key = value [default: …]`
   stacking. Consistency + DRY over per-command flair.
3. **Page on overflow, not always**: a command opens the pager only when its
   rendered output is taller than the terminal; short output prints normally (no
   gratuitous `q`-to-quit).
4. **`ui_pager` gates on stdout**, not stdin: a pager reads *content* from stdin
   and *keystrokes* from `/dev/tty`, so the interactivity test is `ui_ctx ==
   styled` (stdout is the terminal), unlike `ui_choose`/`ui_input` which read the
   user's answer from stdin and use `ui_interactive` (fd 0).
5. **Live logs → `less +F -R`** (chosen over a static `gum pager` snapshot, which
   does not reshape the *live* view, and over a hand-rolled scrollback buffer,
   which reimplements `less` badly). Stage `less`.

## Architecture

```
src/helper/ui        ui_lines (new), ui_pager (new), ui_table (width-fit), ui_kv
src/bin/help         drops settings_render/commands_render/*_stack; pages via ui_pager
src/bin/backup       status/list render through width-fit ui_table/ui_kv; page via ui_pager
src/bin/logs         interactive follower piped into `less +F -R`; raw when non-TTY
snap/snapcraft.yaml  stage `less`
```

The `ui` library remains the ONLY place gum is invoked, and the single place the
fit/scroll policy lives. Commands call `ui_table`/`ui_pager`; they do not size or
scroll themselves.

### Command classification (how each "fits")

| Command | How it fits |
|---|---|
| `help` | width-fit tables (auto-stack) + `ui_pager` on height overflow |
| `backup status` / `backup list` | width-fit `ui_kv`/`ui_table` + `ui_pager` |
| `enable` / `disable` / `restart` | one-line `✓`/`✗` — already fits, unchanged |
| `logs` (picker) | `gum choose` already sizes/scrolls itself |
| `logs` (live follower) | `less +F -R` on a TTY; raw stream when piped |
| `backup` key prompts | `gum input`/`confirm` — already fit |

## Components

### `ui_lines`
Terminal height in rows. `UI_LINES` overrides (tests). Reads `stty size` (first
field = rows) off the controlling tty, then fd 2, then fd 0 — never the
`$( )`-rebound fd 1 — with dup-before-suppress redirect ordering, exactly like
`ui_cols`. A 0×0 winsize counts as unknown → fallback `24`.

### `ui_table` (width-fit)
On `styled`, if the table's natural width (max column widths + borders/padding)
exceeds `ui_cols`, render the generic **stacked** form instead of the bordered
gum table:

```
<col-1 value>
    <header-2>: <col-2 value>
    <header-3>: <col-3 value>
```

The first column is the record title; each remaining column becomes an indented
line, prefixed `header: ` when a header was given to `ui_table`, or the bare
value when none was (so a headerless 2-column `ui_kv` row stacks as the label
followed by its indented value — e.g. a long `encrypt-key` fingerprint drops to
its own line instead of widening the table). `plain`/`syslog` keep today's
aligned-columns output (zero ANSI). This makes the width-fit logic available to
every caller and removes the help-specific helpers.

### `ui_pager`
```
ui_pager:  stdin = content to display
  if ui_ctx == styled AND (line count > ui_lines):  gum pager   (scroll; q quits)
  else:                                              cat         (plain passthrough)
```
Gates on stdout (`ui_ctx`), not stdin. `gum pager` reads content from stdin and
keystrokes from `/dev/tty`. Non-overflowing or plain output passes straight
through, so pipes (`help | cat`), the daemon, and CI are unaffected.

### `logs` reshape
The interactive follower (merged, colorized `tail -F` / `journalctl -f`) is piped
into `less +F -R`:
- `+F` starts in follow mode (matches today's default behavior).
- `-R` preserves the stream-prefix ANSI colors.
- Ctrl-C → scroll/search; `F` → resume follow; `q` → quit, which SIGPIPEs the
  upstream follower (its existing trap reaps `tail`/`journalctl`).
- **Non-TTY / piped** → bypass `less`, raw stream as today, so `logs | grep …`
  and the navigator's argument-driven path are byte-for-byte unchanged.
The `all/zui/zwjs` picker and the follower machinery are otherwise untouched.

### Packaging
`snap/snapcraft.yaml` stages `less` (stage-packages). Strict confinement allows
only in-snap binaries, so `less` must ship in the snap. `less` reads its content
from the pipe and draws to the terminal — no extra interfaces needed.

## Error handling / degradation

- The context matrix governs everything: `styled` → fit/scroll/`less`;
  `plain`/`syslog` → plain passthrough, zero ANSI, no pager, no `less`.
- A missing/again-broken `less` (should not happen once staged) → the follower
  falls back to the raw stream rather than aborting.
- `gum pager`/`less` absent or non-TTY → plain passthrough; decoration failure is
  never a hard failure.

## Testing

Same source-the-script + stubbed-binary + real-pty pattern as `ui_cols`:

- **`ui_lines`:** `UI_LINES` override; real-pty winsize via `script`/`stty rows`;
  fallback-to-24 when unknown.
- **`ui_table` width-fit:** UI_COLS-driven — wide ctx renders the gum table,
  narrow ctx renders the generic stacked form; plain ctx unchanged (aligned, zero
  ANSI). `ui_kv` two-column stacking.
- **`ui_pager`:** pages when `styled` AND overflow (stub gum records `pager`
  argv); passthrough when plain, when it fits, and asserts it keys off stdout not
  stdin.
- **`logs`:** stub `less` on PATH; assert the interactive follower invokes
  `less +F -R` and the piped/non-TTY path stays a raw stream. Existing follower
  unit tests keep passing.
- **Regression:** the help suite is updated for the generic stacked form; all
  existing suites stay green; full shellcheck sweep clean.

## Risks / trade-offs accepted

- `less`'s chrome is not gum-styled — accepted; it is the only way to get
  live-follow + scroll without a custom TUI, and the log colors survive via `-R`.
- New staged dependency `less` (~0.2 MB) — small, same pattern as `nano`.
- `less` and `gum pager` must read keystrokes from `/dev/tty` while their stdin is
  the content pipe, and must work under strict confinement — verified on a real
  pty during implementation (the rev-881 lesson: pty-test, don't assume).
- `help`'s narrow layout changes from the bespoke `key = value [default]` to the
  generic stacked form — accepted for consistency across commands.
