# Design: `zwave-js-ui.logs` — unified log follower

**Date:** 2026-06-08
**Status:** Approved (pending spec review)
**Scope:** Snap packaging only (`src/`, `snap/snapcraft.yaml`). No upstream `zwave-js-ui` code is modified; upstream is consulted read-only to confirm defaults.

## Problem

Following Z-Wave JS UI logs from a terminal currently requires the user to know two things at once: whether each component logs to file or not, and the right command for each case. The `help` text documents both manual paths (`snap logs … -f` vs `tail -f $SNAP_DATA/*.log`). The existing `src/bin/logs-observe` was an unfinished attempt at automating this and does not work (stale `Z2M` references, a broken `ls` glob, and it only echoes command strings instead of running them).

## Goal

One command — `zwave-js-ui.logs` — that presents a **single, terminal-friendly, live-follow view** of the relevant logs, automatically choosing the correct source per component, with an optional filter to a single component.

## Components & streams

Two independent log streams, each configured separately in upstream `settings.json`:

| Stream | Label | `settings.json` key |
|--------|-------|---------------------|
| Z-Wave JS UI application ("gateway") | `ZUI` | `gateway.logToFile` |
| Z-Wave JS driver | `ZWJS` | `zwave.logToFile` |

**Shared-process caveat (important):** ZUI and the ZWJS driver run in the *same Node process*. When a stream logs **to file**, each writes its own file (cleanly separable). When a stream logs to the **journal** (logToFile off), both share **one** journald stream under the snap's service unit; they cannot be separated at the journal level. The command handles this honestly (see Source resolution) rather than faking per-stream separation of journal output.

## Command surface

```
zwave-js-ui.logs [TARGET]

  (no arg)        both streams, merged
  zui  | --zui    ZUI application stream only
  zwjs | --zwjs   Z-Wave JS driver stream only
  -h   | --help   usage
```

- Both a bare token and a `--`-prefixed flag are accepted and equivalent (parser strips a leading `--`, then matches `{zui, zwjs}`).
- An unrecognized token, or more than one token, prints usage to stderr and exits **2**.

## Source resolution (per selected stream)

Decide each stream's source by precedence — the filesystem is treated as ground truth, with config as the override and the upstream default as last resort:

1. **Setting explicit `true`** → **file source.** `tail -F` is used, so a not-yet-created file is waited for (honors intent before first write).
2. **Setting explicit `false`** → **journal source.**
3. **Setting unset / null / no `settings.json`** → **infer:**
   - If a current log file exists for the stream → **file source.**
   - Otherwise → **journal source** (upstream default).

**File source locations** (patterns are tolerant; exact names are a verification item):
- ZWJS: `${ZWAVEJS_LOGS_DIR:-$SNAP_DATA/logs/zwavejs}` — prefer `zwavejs_current.log`, else newest `zwavejs_*.log`.
- ZUI: under `$SNAP_DATA/logs/` — prefer a `*_current.log`, else newest matching `*.log` (excluding the `zwavejs/` subdir).

**Journal source** = the systemd unit `snap.${SNAP_NAME}.${SNAP_NAME}.service`, read via `journalctl`.

**Shared-journal rule:** all journal-backed streams collapse to **one** deduped follower. Label is derived from which selected streams resolve to the journal: only ZUI → `[ZUI]`; only ZWJS → `[ZWJS]`; both → `[ZUI/ZWJS]`. When a *filtered* selection resolves to the journal while the other stream is also journal-backed, emit a **one-time stderr notice** that journal output is a shared stream and may include the other component. Labels stay plain (no `[ZUI?]` uncertainty marker) even when the source was inferred.

## Multiplexing & lifecycle (Approach 1: parallel followers)

- Each active source runs as a backgrounded pipeline: `tail -n 20 -F <file>` or `journalctl -u <unit> -n 20 -f`, piped through a **prefixer**.
- The prefixer is a `while IFS= read -r line` loop that prepends the stream label; the loop is naturally line-buffered so lines appear promptly.
- **Backlog-then-follow:** the `-n 20` backlog on each source gives immediate context, then follows live.
- All followers write to the terminal concurrently → live interleave by *arrival order* (not a global timestamp sort; standard for live tailing).
- **Cleanup:** each pipeline runs in its own subshell; a `trap … EXIT INT TERM` tears down the whole process group so Ctrl-C kills every `tail`/`journalctl` with no orphans.

## Output & color

- Prefixer prepends `[LABEL] ` to each line.
- If stdout is a TTY (`[ -t 1 ]`), the label is ANSI-colored: ZUI = cyan, ZWJS = green, combined journal = yellow. If piped/redirected, output is plain so `| grep` and `> file` stay clean.
- Only the label is colored; log line content is passed through untouched.

## snapcraft.yaml change

```yaml
  logs:
    command: bin/logs
    plugs:
      - log-observe
```

- Reuses the existing snap-level `log-observe` plug (already declared for the daemon app) — no new plug.
- No `command-chain` (no env-var mapping needed).
- `SNAP_NAME` / `SNAP_DATA` are provided by snapd automatically.

## Error handling

| Condition | Behavior |
|-----------|----------|
| No `settings.json` (never configured) | Infer per Source resolution (→ journal by default); only show a friendly message if neither a file nor the journal yields anything. |
| logToFile on but file absent | `tail -F` waits; emit a one-time "waiting for `<file>`" notice. |
| `journalctl` denied / unavailable | Error with the `snap connect …:log-observe` hint. |
| Not root (if required — see Verification) | `require_root`, consistent with `enable`/`disable`/`restart`. |

## Code & docs changes

- **Add** `src/bin/logs` (sources `helper/functions` for `SNAP_NAME`, `lprint`, `require_root`, `zui_settings_file`). `DAEMONIZED` left unset so output reaches the terminal.
- **Delete** `src/bin/logs-observe` (broken, superseded).
- **Update** `env-wrapper --help`: the manual `snap logs` / `tail` hint becomes "or just run `zwave-js-ui.logs`".
- **Update** `CLAUDE.md`: add `zwave-js-ui.logs` to the inspecting/running command list; note `logs-observe` is gone.
- **Add** the `logs` app to `snap/snapcraft.yaml`.

## Verification checklist (resolve during implementation, do not guess)

1. **Exact log filenames** ZUI and ZWJS write on disk — confirm against a running instance and/or the upstream config/logging source. The `_current.log` → newest-glob resolution is built to tolerate variation, but the patterns must be checked.
2. **Upstream `logToFile` defaults** for `gateway` and `zwave` — confirm both default to `false` (console → journal) from the upstream source/schema, to set the last-resort fallback correctly. The runtime file-existence check makes the command correct in the common cases regardless; this only fixes the truly-fresh corner case.
3. **Root requirement** — whether `journalctl` under `log-observe` reads the journal without `sudo`, and whether `$SNAP_DATA` log files are readable unprivileged. If both work unprivileged, drop `require_root`; otherwise keep it.

## Explicitly out of scope (YAGNI)

- No `--lines N` flag (fixed backlog of 20).
- No timestamp-sorted global merge.
- No log-level filtering.
- No colorizing of log *content* (only labels).
