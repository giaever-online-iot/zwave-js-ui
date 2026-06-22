# Responsive UI — Live-Log Scrollable Viewer (Part B) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the live `logs` follower so an interactive terminal gets a follow-*and*-scrollable viewer (`less +F -R`) instead of an unscrollable stream — while pipes, redirects, and non-terminals keep today's raw stream byte-for-byte.

**Architecture:** The existing follower backgrounds one subshell per stream, all writing to stdout, then `wait`s. We extract that launch+reap+wait into `run_followers`, and on an interactive terminal feed its merged output through a FIFO into a foreground `less +F -R`; when the user quits `less`, the producer is killed and its trap reaps the tailers. `less` is staged into the snap (strict confinement reaches only in-snap binaries). Verified orchestration: `less` follows live FIFO data and the tailers are reaped on quit with no hang.

**Tech Stack:** bash, `less` (staged via snapcraft stage-packages), the existing `tests/` harness (`assert.sh` + source-the-script + `$SNAP`→`tests/fixtures`), `script(1)` for real-pty integration tests.

## Global Constraints

- The reshape applies ONLY on an interactive terminal (`[ -t 1 ]` true) with `less` available. Non-TTY / piped / redirected runs keep the exact current behavior (raw merged stream), so `sudo zwave-js-ui.logs | grep …` and any argument-driven path are unchanged.
- Do NOT change the follower resolution logic (`resolve_source`, `require_journal_access`, `follower_cmd`, `launch_follower`, the colour prefixes) — only how the launched followers' output is presented.
- `less` runs in the FOREGROUND (it reads keystrokes from `/dev/tty` itself); the producer (the followers + `wait`) runs backgrounded, writing into the FIFO; quitting `less` must terminate every tailer (no root-owned orphans).
- Tests: every `tests/*_test.sh` ends `N passed, 0 failed`; `shellcheck --severity=warning -x` clean over `src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh`. Run from the repo root.
- Snap base is `core26`; staged packages must exist for core26 (Ubuntu 24.04/`noble`).

---

### Task 1: Stage `less` in the snap

**Files:**
- Modify: `snap/snapcraft.yaml` (the `local` part's `stage-packages`)

**Interfaces:**
- Produces: `less` present at `$SNAP/usr/bin/less` and on the app `PATH` at runtime.

- [ ] **Step 1: Find the part that stages user-facing tools**

Run: `yq '.parts.local' snap/snapcraft.yaml`
Expected: the `local` part (plugin `dump`, `source: src/`) with a `stage-packages:` list (currently `uuid`).

- [ ] **Step 2: Add `less` to the `local` part's stage-packages**

In `snap/snapcraft.yaml`, under `parts.local.stage-packages`, add `less` alongside `uuid`:

```yaml
  local:
    after: [dependencies]
    plugin: dump
    source: src/
    stage-packages:
      - uuid
      - less
    organize:
      hooks: snap/hooks
```

- [ ] **Step 3: Verify the recipe parses and lists less**

Run: `yq '.parts.local.stage-packages' snap/snapcraft.yaml`
Expected: a list containing `uuid` and `less`.

- [ ] **Step 4: Commit**

```bash
git add snap/snapcraft.yaml
git commit -m "build(snap): stage less (live-log scrollable viewer needs an in-snap pager)"
```

---

### Task 2: Reshape the live follower into `less +F -R`

**Files:**
- Modify: `src/bin/logs` (extract `run_followers`; add `logs_should_page`; rewrite `main`'s launch section)
- Modify: `tests/logs_test.sh` (append before `finish`)
- Modify: `tests/fixtures/bin/less` (NEW executable stub) — create it

**Interfaces:**
- Consumes: existing `launch_follower`, `make_prefix`, `stream_upper`/`stream_color`, `journal_label`, `resolve_source`, `read_log_setting`, `setting_key`, and the resolved locals in `main` (`file_streams`, `file_srcs`, `journal_streams`, `target`, `use_color`, `sf`, `BACKLOG`).
- Produces:
  - `run_followers` — launches every resolved follower, traps to reap them (EXIT/INT/TERM), then `wait`s. Reads `main`'s resolved locals via bash dynamic scope. Returns 1 (no `exit`) when nothing was launched.
  - `logs_should_page` — exit 0 iff stdout is a TTY and `less` is on PATH.

- [ ] **Step 1: Create the `less` stub fixture**

Create `tests/fixtures/bin/less`:

```bash
#!/usr/bin/env bash
# Fake less for unit tests: record argv, drain a few lines from the file arg
# (proves it can read the FIFO), then exit (simulates the user pressing q).
[ -n "${LESS_LOG:-}" ] && printf '%s\n' "$*" >> "$LESS_LOG"
f="${*: -1}"
n=0; while [ "$n" -lt 3 ] && IFS= read -r _; do n=$((n+1)); done < "$f" 2>/dev/null
exit 0
```

Run: `chmod +x tests/fixtures/bin/less`

- [ ] **Step 2: Write the failing tests**

In `tests/logs_test.sh`, insert before the final `finish`:

```bash
# --- live-log viewer: less +F -R on a TTY, raw stream when piped ----------------
# logs_should_page: needs both a TTY on stdout AND less on PATH.
( PATH="$HERE/fixtures/bin:$PATH"; logs_should_page </dev/null >/dev/null 2>&1 ); \
    assert_status "$?" "1" "should_page: no TTY on stdout -> no"

# Real-pty integration: under script(1), stdout is a TTY; with stub less + stub
# followers, main must launch the pager as `less +F -R <fifo>` and exit cleanly.
if command -v script >/dev/null 2>&1; then
    LESS_LOG="$SNAP_DATA/less.argv"
    out="$(ROOT="$ROOT" SNAP="$SNAP" SNAP_DATA="$SNAP_DATA" LESS_LOG="$LESS_LOG" \
        STUB="$HERE/fixtures/bin" \
        timeout 15 script -qec '
            export PATH="$STUB:$PATH"
            printf "%s" "{\"gateway\":{\"logToFile\":true},\"zwave\":{\"logToFile\":true}}" > "$SNAP_DATA/settings.json"
            require_root() { :; }
            source "$ROOT/src/bin/logs"
            main zui
        ' /dev/null 2>&1; echo "rc=$?")"
    assert_contains "$(cat "$LESS_LOG" 2>/dev/null)" "+F -R" "viewer: TTY run launches less +F -R"
    assert_contains "$out" "rc=0" "viewer: paged run exits cleanly (no hang)"
fi

# Piped (no TTY): main must NOT invoke less — raw stream path.
LESS_LOG2="$SNAP_DATA/less2.argv"; : > "$LESS_LOG2"
printf '%s' '{"gateway":{"logToFile":true},"zwave":{"logToFile":false}}' > "$SNAP_DATA/settings.json"
( PATH="$HERE/fixtures/bin:$PATH"; LESS_LOG="$LESS_LOG2"; require_root() { :; }
  TAIL_SENTINEL="$SNAP_DATA/t.ran"; export TAIL_SENTINEL
  timeout 10 bash -c 'source "$ROOT/src/bin/logs"; require_root() { :; }; main zui' </dev/null >/dev/null 2>&1 )
assert_eq "$(cat "$LESS_LOG2" 2>/dev/null)" "" "viewer: piped run does NOT invoke less"
```

(The `tests/fixtures/bin/tail` and `journalctl` stubs already exist from the journald-guard work and exit promptly so `wait` returns.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/logs_test.sh`
Expected: FAIL — `logs_should_page: command not found`, and the pty test's `less.argv` is empty (main still writes the raw stream, never calling `less`).

- [ ] **Step 4: Add `logs_should_page` and `run_followers` to `src/bin/logs`**

Immediately ABOVE `main()` in `src/bin/logs`, add:

```bash
logs_should_page() {           # page only on an interactive terminal with a pager available
    [ -t 1 ] && command -v less >/dev/null 2>&1
}

run_followers() {              # launch every resolved follower, reap on exit, then wait.
                               # Reads main's resolved locals via bash dynamic scope
                               # (file_streams, file_srcs, journal_streams, target, use_color,
                               # sf, BACKLOG). Returns 1 if nothing was launched (no `exit`,
                               # so it is safe whether run in the foreground or backgrounded).
    local pids=() i s other p
    trap 'for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done' EXIT INT TERM
    for i in "${!file_streams[@]}"; do
        s="${file_streams[$i]}"
        [ -e "${file_srcs[$i]#file:}" ] || lprint "Waiting for log file: ${file_srcs[$i]#file:}" >&2
        launch_follower "${file_srcs[$i]}" "$(make_prefix "$(stream_upper "$s")" "$(stream_color "$s")" "$use_color")"
        pids+=("$!")
    done
    if [ "${#journal_streams[@]}" -gt 0 ]; then
        if [ "$target" != both ]; then
            other=$([ "$target" = zui ] && echo zwjs || echo zui)
            if [ "$(resolve_source "$other" "$(read_log_setting "$sf" "$(setting_key "$other")")")" = journal ]; then
                lprint "Note: ${target} and ${other} share one journald stream; ${other} lines may also appear." >&2
            fi
        fi
        launch_follower journal "$(make_prefix "$(journal_label "${journal_streams[@]}")" yellow "$use_color")"
        pids+=("$!")
    fi
    if [ "${#pids[@]}" -eq 0 ]; then
        lprint "No logs to follow yet. Start/configure ${SNAP_NAME} first (see ${SNAP_NAME}.help)." >&2
        return 1
    fi
    wait
}
```

- [ ] **Step 5: Replace `main`'s launch section with the paged/plain dispatch**

In `src/bin/logs`'s `main()`, replace everything from the cleanup-trap comment line
(`# Register cleanup BEFORE launching anything,…`) through the final `wait` — i.e. the
current lines that register the trap, run the two launch loops, do the no-pids check,
and call `wait` — with:

```bash
    # Interactive terminal + a pager: follow live AND let the user scroll back.
    # The producer (followers + wait) backgrounds into a FIFO; less reads the FIFO
    # in the foreground (keys from /dev/tty) with +F (follow) and -R (keep colours).
    # Quitting less kills the producer, whose trap reaps the tailers — no orphans.
    if logs_should_page; then
        local fifo; fifo="$(mktemp -u "${SNAP_COMMON:-${TMPDIR:-/tmp}}/.zlogs.XXXXXX")"
        if ! mkfifo "$fifo" 2>/dev/null; then run_followers; return; fi
        run_followers >"$fifo" &
        local producer=$!
        less +F -R "$fifo"
        kill -TERM "$producer" 2>/dev/null
        wait "$producer" 2>/dev/null
        rm -f "$fifo"
    else
        run_followers
    fi
```

(Everything ABOVE that section — help, `require_root`, target/picker resolution, stream
classification, `require_journal_access` — is unchanged. `run_followers` now owns the
trap, the launch loops, the no-pids check, and `wait`.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/logs_test.sh`
Expected: `... passed, 0 failed`.

- [ ] **Step 7: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/logs tests/logs_test.sh`
Expected: no output.

```bash
git add src/bin/logs tests/logs_test.sh tests/fixtures/bin/less
git commit -m "feat(logs): scrollable live viewer via less +F -R on a TTY; raw stream when piped"
```

---

### Task 3: Docs + full verification

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the complete check suite**

```bash
shellcheck --severity=warning -x src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh
for t in tests/*_test.sh; do echo "== $t"; bash "$t" || exit 1; done
```

Expected: shellcheck silent; every suite ends `... passed, 0 failed`.

- [ ] **Step 2: Update CLAUDE.md**

In the "Inspecting / running the installed snap" code block, change the `zwave-js-ui.logs`
description line:

```bash
zwave-js-ui.logs       # unified, terminal-friendly live log view; append zui|zwjs to filter
```

to add the viewer note:

```bash
zwave-js-ui.logs       # unified live log view (scrollable via less on a TTY: Ctrl-C to scroll,
                       # F to resume follow, q to quit); append zui|zwjs to filter; raw when piped
```

And in the "User commands" section's `logs` sentence, append: ", and on an interactive terminal it follows in a `less +F -R` viewer (scroll back with Ctrl-C, resume with F, quit with q) while pipes keep the raw stream."

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the scrollable live-log viewer in CLAUDE.md"
```

---

## Spec coverage map (self-review)

| Spec item (Part B) | Task |
|---|---|
| Stage `less` in the snap | 1 |
| Live follower reshaped into `less +F -R` (follow + scroll, colours via `-R`) | 2 |
| Non-TTY / piped keeps the raw stream unchanged | 2 (test: "piped run does NOT invoke less") |
| Quitting the viewer reaps the tailers (no orphans / hang) | 2 (orchestration + pty test "exits cleanly") |
| Picker / resolution / journald-guard logic untouched | 2 (only the launch section changes) |
| Docs updated; full sweep green | 3 |

Out of scope (per the design spec): historical/rotated paging beyond what `less` gives on the live FIFO, and any gum-styling of `less`'s own chrome.
