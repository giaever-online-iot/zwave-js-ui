# Responsive UI — Library + Bounded Commands — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every *bounded-output* command fit the terminal — width (tables auto-stack) and height (scroll when taller than the screen) — with the logic centralized in `src/helper/ui`.

**Architecture:** Add a height primitive `ui_lines` (twin of the existing `ui_cols`), make `ui_table` fall back to a generic stacked record form when it is wider than the terminal, and add `ui_pager` to scroll output taller than the screen. `help`, `backup status`, and `backup list` then fit automatically. The live-log viewer (`less +F -R`) is a **separate** plan (`2026-06-21-responsive-logs-viewer.md`).

**Tech Stack:** bash, gum v0.17.0 (`gum table`/`gum pager`), the zero-dependency `tests/` harness (`assert.sh` + source-the-script + `$SNAP`→`tests/fixtures`, stub `gum` on `$SNAP/bin/gum`).

## Global Constraints

- Scripts are sourced by tests with `export SNAP="$HERE/fixtures"`; real scripts guard execution with `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi` so sourcing is side-effect free.
- The `ui` library is the ONLY place `gum` is invoked. Commands call `ui_*`, never `gum`.
- Context matrix is law: `syslog` (`DAEMONIZED=1` → `lprint`), `plain` (no TTY / `NO_COLOR` / `TERM=dumb` / no gum → zero ANSI bytes), `styled` (TTY + gum). Responsive behavior (stack/scroll) happens ONLY in `styled`; `plain`/`syslog` keep today's output byte-for-byte.
- Terminal size is read off a fd command substitution does NOT rebind: controlling tty (`</dev/tty`), then fd 2 (`<&2`), then fd 0 (`<&0`) — never fd 1. `/dev/tty` uses suppress-before-open (`2>/dev/null </dev/tty`); fd 2/0 use dup-before-suppress (`<&2 2>/dev/null`). A `0` or non-numeric reading is "unknown".
- CI runs `shellcheck --severity=warning -x` over `src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh` and every `tests/*_test.sh`. Keep both clean. Success output ends `N passed, 0 failed`.
- Run all commands from the repo root (this worktree). Run a suite with `bash tests/<file>_test.sh`.

---

### Task 1: `ui_lines` — terminal-height primitive

**Files:**
- Modify: `src/helper/ui` (add `ui_lines` immediately after `ui_cols`)
- Test: `tests/ui_test.sh` (append before `finish`)

**Interfaces:**
- Produces: `ui_lines` → prints terminal height in rows (integer). `UI_LINES` env overrides. Falls back to `24` when unknown.

- [ ] **Step 1: Write the failing tests**

In `tests/ui_test.sh`, insert before the final `finish`:

```bash
# --- ui_lines: terminal height detection --------------------------------------
assert_eq "$(UI_LINES=42 ui_lines)" "42" "ui_lines honors UI_LINES override"
rows_auto="$(UI_LINES='' ui_lines)"
case "$rows_auto" in
    ''|0|*[!0-9]*) FAIL=$((FAIL+1)); printf 'FAIL: ui_lines not a positive int: %q\n' "$rows_auto" >&2 ;;
    *) PASS=$((PASS+1)) ;;
esac
if command -v script >/dev/null 2>&1; then
    rl="$(ROOT="$ROOT" script -qec 'stty rows 37 2>/dev/null; bash -c "source \"$ROOT/src/helper/ui\"; ui_lines"' /dev/null | tr -d '\r')"
    assert_contains "$rl" "37" "ui_lines reads real pty winsize (rows)"
fi
if command -v script >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1; then
    rl2="$(ROOT="$ROOT" script -qec 'stty rows 29 2>/dev/null; setsid bash -c "source \"$ROOT/src/helper/ui\"; ui_lines" </dev/null' /dev/null | tr -d '\r')"
    assert_contains "$rl2" "29" "ui_lines reads fd2 rows with no controlling tty / piped stdin"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/ui_test.sh`
Expected: FAIL / `ui_lines: command not found`.

- [ ] **Step 3: Implement `ui_lines`**

In `src/helper/ui`, directly after the `ui_cols` function's closing `}`, add:

```bash
ui_lines() {                   # terminal height in rows. UI_LINES overrides (tests); 24 if unknown.
                               # Same fd discipline as ui_cols; stty's FIRST field is rows.
    if [ -n "${UI_LINES:-}" ]; then printf '%s\n' "$UI_LINES"; return; fi
    local r
    r="$(stty size 2>/dev/null </dev/tty | cut -d' ' -f1)"
    case "$r" in ''|0|*[!0-9]*) r="$(stty size <&2 2>/dev/null | cut -d' ' -f1)" ;; esac
    case "$r" in ''|0|*[!0-9]*) r="$(stty size <&0 2>/dev/null | cut -d' ' -f1)" ;; esac
    case "$r" in ''|0|*[!0-9]*) r=24 ;; esac
    printf '%s\n' "$r"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/ui_test.sh`
Expected: `... passed, 0 failed`.

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/ui tests/ui_test.sh`
Expected: no output.

```bash
git add src/helper/ui tests/ui_test.sh
git commit -m "feat(ui): ui_lines terminal-height primitive (twin of ui_cols)"
```

---

### Task 2: `ui_table` width-fit — generic stacked fallback

**Files:**
- Modify: `src/helper/ui` (add `ui_table_width` + `ui_stack`; rewrite `ui_table`'s `styled` branch)
- Test: `tests/ui_test.sh` (append before `finish`)

**Interfaces:**
- Consumes: `ui_cols` (Task pre-exists), `ui_ctx`, `UI_GUM`.
- Produces:
  - `ui_table_width [headers...]` (stdin TSV) → integer natural bordered-table width.
  - `ui_stack [headers...]` (stdin TSV) → generic stacked records: col-1 as title, each later column an indented `header: value` line (bare value when no header).
  - `ui_table [headers...]` — unchanged signature; in `styled`, auto-stacks when wider than `ui_cols`.

- [ ] **Step 1: Write the failing tests**

In `tests/ui_test.sh`, insert before `finish`:

```bash
# --- ui_table width-fit: stack when wider than the terminal --------------------
assert_eq "$(printf 'aa\tbbbb\n' | ui_table_width)" "$((2+4+3*2+1))" "table_width = sumcols + 3/col + 1"

narrow="$(printf 'server.host\t0.0.0.0\tIP address the web UI binds to\n' \
    | UI_ASSUME_TTY=1 UI_COLS=20 ui_table setting value description)"
assert_contains "$narrow" "server.host"                              "stack: col-1 title"
assert_contains "$narrow" "    value: 0.0.0.0"                       "stack: indented header: value"
assert_contains "$narrow" "    description: IP address the web UI binds to" "stack: indented desc"
case "$narrow" in *'[table]'*) FAIL=$((FAIL+1)); echo "FAIL: narrow used gum table" >&2 ;; *) PASS=$((PASS+1)) ;; esac

assert_contains "$(printf 'k\tv\n' | UI_ASSUME_TTY=1 UI_COLS=999 ui_table key value)" "[table]" "wide -> gum table"

# headerless (ui_kv-style) 2-col: label is the title, value indented bare
kvn="$(printf 'encrypt-key\t0E32DAF912C2645073A3DFFA8956E92F1A70C779\n' | UI_ASSUME_TTY=1 UI_COLS=20 ui_table)"
assert_contains "$kvn" "encrypt-key"                                  "kv stack: label title"
assert_contains "$kvn" "    0E32DAF912C2645073A3DFFA8956E92F1A70C779" "kv stack: indented bare value"

# plain ctx unchanged (aligned columns, zero ANSI)
plain="$(printf 'k\tv\n' | ui_table key value)"
assert_contains "$plain" "k" "plain: aligned still works"
printf '%s' "$plain" | grep -q "$(printf '\033')"; assert_status "$?" "1" "plain: zero ANSI"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/ui_test.sh`
Expected: FAIL / `ui_table_width: command not found` and the stack assertions fail.

- [ ] **Step 3: Add `ui_table_width` and `ui_stack`**

In `src/helper/ui`, immediately BEFORE the existing `ui_table` function, add:

```bash
ui_table_width() {             # [headers...]; stdin TSV -> natural bordered-table width estimate
                               # sum(per-column max widths incl. headers) + 3 padding/border per col + 1
    { if [ "$#" -gt 0 ]; then local IFS=$'\t'; printf '%s\n' "$*"; fi; cat; } | awk -F'\t' '
        { for (i=1;i<=NF;i++) if (length($i)>w[i]) w[i]=length($i); if (NF>nc) nc=NF }
        END { s=0; for (i=1;i<=nc;i++) s+=w[i]; print s + 3*nc + 1 }'
}

ui_stack() {                   # [headers...]; stdin TSV -> generic stacked records
                               # col-1 = title; later columns = indented "header: value" (bare if no header)
    local headers=("$@") line i
    local -a fields
    while IFS= read -r line; do
        IFS=$'\t' read -ra fields <<< "$line"
        printf '%s\n' "${fields[0]}"
        for i in "${!fields[@]}"; do
            [ "$i" -eq 0 ] && continue
            if [ -n "${headers[$i]:-}" ]; then
                printf '    %s: %s\n' "${headers[$i]}" "${fields[$i]}"
            else
                printf '    %s\n' "${fields[$i]}"
            fi
        done
        printf '\n'
    done
}
```

- [ ] **Step 4: Rewrite `ui_table`'s `styled` branch to auto-stack**

Replace the entire existing `ui_table` function with:

```bash
# shellcheck disable=SC2120  # called with header args from ui_kv and external scripts
ui_table() {                   # stdin: TAB-separated rows; args: optional column headers
                               # headers must not contain commas (gum --columns delimiter)
    local cols rows
    case "$(ui_ctx)" in
        styled)
            rows="$(cat)"
            if [ "$(printf '%s\n' "$rows" | ui_table_width "$@")" -gt "$(ui_cols)" ]; then
                printf '%s\n' "$rows" | ui_stack "$@"
            elif [ "$#" -gt 0 ]; then
                cols="$(IFS=,; printf '%s' "$*")"
                printf '%s\n' "$rows" | "$UI_GUM" table --print --separator "$(printf '\t')" --columns "$cols"
            else
                printf '%s\n' "$rows" | "$UI_GUM" table --print --separator "$(printf '\t')"
            fi ;;
        *)
            {
                if [ "$#" -gt 0 ]; then local IFS=$'\t'; printf '%s\n' "$*"; fi
                cat
            } | ui_align ;;
    esac
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/ui_test.sh`
Expected: `... passed, 0 failed`.

- [ ] **Step 6: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/ui tests/ui_test.sh`
Expected: no output.

```bash
git add src/helper/ui tests/ui_test.sh
git commit -m "feat(ui): ui_table auto-stacks (generic record form) when wider than the terminal"
```

---

### Task 3: Refactor `help` onto width-fit `ui_table`

**Files:**
- Modify: `src/bin/help` (delete the bespoke width helpers; call `ui_table` directly)
- Modify: `tests/help_test.sh` (replace the bespoke "width-aware settings layout" block)

**Interfaces:**
- Consumes: `ui_table` (now width-fit, Task 2), `settings_rows`, `commands_rows` (pre-exist in `help`).

- [ ] **Step 1: Update the tests first (they will fail)**

In `tests/help_test.sh`, DELETE the whole block that starts with the comment
`# --- width-aware settings layout ---` and ends at the line
`assert_contains "$mn" "server.host = 10.0.0.7" "main: narrow styled stacks settings (live value)"`
(everything that referenced `table_width`, `settings_stack`, `settings_render`,
`commands_render`, and the bespoke `main` narrow assertion). Replace it with:

```bash
# --- help renders via the width-fit ui_table (stacking lives in the library now) ---
unset NO_COLOR; export TERM=xterm-256color   # let UI_ASSUME_TTY reach styled
# shellcheck disable=SC2034
SNAPCTL_server_host="10.0.0.7"
mn="$(export UI_ASSUME_TTY=1 UI_COLS=40; plugs_connected() { :; }; main)"
assert_contains "$mn" "server.host"            "main: narrow styled shows the setting"
assert_contains "$mn" "    value: 10.0.0.7"    "main: narrow styled uses the generic stacked form"
mw="$(export UI_ASSUME_TTY=1 UI_COLS=999; plugs_connected() { :; }; main)"
assert_contains "$mw" "[table]"                "main: wide styled uses the gum table"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/help_test.sh`
Expected: FAIL — `table_width`/`settings_render` no longer referenced but the new
`    value: 10.0.0.7` assertion fails because `help` still calls its own
`settings_render` (which uses the old bespoke `key = value [default]` format).

- [ ] **Step 3: Delete the bespoke helpers from `src/bin/help`**

Remove these five functions in full: `table_width`, `settings_stack`,
`commands_stack`, `settings_render`, `commands_render` (the block added between
`commands_rows` and `main`).

- [ ] **Step 4: Point `main` at `ui_table` directly**

In `main()`, replace:

```bash
    settings_rows | settings_render
```

with:

```bash
    settings_rows | ui_table "setting" "value" "default" "description"
```

and replace:

```bash
    commands_rows | commands_render
```

with:

```bash
    commands_rows | ui_table "command" "description"
```

- [ ] **Step 5: Run to verify pass**

Run: `bash tests/help_test.sh`
Expected: `... passed, 0 failed`.

- [ ] **Step 6: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/help tests/help_test.sh`
Expected: no output.

```bash
git add src/bin/help tests/help_test.sh
git commit -m "refactor(help): use width-fit ui_table; drop bespoke stacking helpers"
```

---

### Task 4: `ui_pager` — scroll output taller than the screen

**Files:**
- Modify: `src/helper/ui` (add `ui_pager`)
- Modify: `tests/fixtures/bin/gum` (handle the `pager` subcommand)
- Test: `tests/ui_test.sh` (append before `finish`)

**Interfaces:**
- Consumes: `ui_ctx`, `ui_lines` (Task 1), `UI_GUM`.
- Produces: `ui_pager` (stdin: content) → `gum pager` when `styled` AND content is taller than `ui_lines`; otherwise passes content straight through. Gates on stdout (`ui_ctx`), not stdin.

- [ ] **Step 1: Teach the gum stub the `pager` subcommand**

In `tests/fixtures/bin/gum`, inside the `case "$cmd" in` block, add a `pager` arm
next to the existing `table)` arm:

```bash
    pager)   sed 's/^/[pager] /' ;;
```

- [ ] **Step 2: Write the failing tests**

In `tests/ui_test.sh`, insert before `finish`:

```bash
# --- ui_pager: scroll only when styled AND taller than the screen --------------
big="$(seq 1 50)"
assert_contains "$(printf '%s\n' "$big" | UI_ASSUME_TTY=1 UI_LINES=10 ui_pager)" "[pager]" "pager: styled + overflow -> gum pager"
# fits -> passthrough (no pager)
fits="$(printf 'a\nb\n' | UI_ASSUME_TTY=1 UI_LINES=10 ui_pager)"
assert_eq "$fits" "$(printf 'a\nb')" "pager: fits -> passthrough"
case "$fits" in *'[pager]'*) FAIL=$((FAIL+1)); echo "FAIL: paged content that fit" >&2 ;; *) PASS=$((PASS+1)) ;; esac
# plain ctx -> passthrough even when tall
plain="$(printf '%s\n' "$big" | NO_COLOR=1 UI_LINES=10 ui_pager)"
case "$plain" in *'[pager]'*) FAIL=$((FAIL+1)); echo "FAIL: plain ctx paged" >&2 ;; *) PASS=$((PASS+1)) ;; esac
assert_contains "$plain" "50" "pager: plain passthrough keeps content"
# gates on stdout: content arrives on a pipe (stdin not a tty) yet styled -> still pages
assert_contains "$(printf '%s\n' "$big" | UI_ASSUME_TTY=1 UI_LINES=10 ui_pager)" "[pager]" "pager: piped stdin + styled still pages"
```

- [ ] **Step 3: Run to verify failure**

Run: `bash tests/ui_test.sh`
Expected: FAIL / `ui_pager: command not found`.

- [ ] **Step 4: Implement `ui_pager`**

In `src/helper/ui`, after `ui_usage`, add:

```bash
ui_pager() {                   # stdin: content -> scrollable viewport when it overflows the screen.
                               # Gates on stdout (ui_ctx), NOT stdin: gum pager reads content from
                               # stdin and keystrokes from /dev/tty, so the content can be a pipe.
    local content; content="$(cat)"
    if [ "$(ui_ctx)" = styled ] && [ "$(printf '%s\n' "$content" | wc -l)" -gt "$(ui_lines)" ]; then
        printf '%s\n' "$content" | "$UI_GUM" pager
    else
        printf '%s\n' "$content"
    fi
}
```

- [ ] **Step 5: Run to verify pass**

Run: `bash tests/ui_test.sh`
Expected: `... passed, 0 failed`.

- [ ] **Step 6: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/ui tests/ui_test.sh tests/fixtures/bin/gum`
Expected: no output.

```bash
git add src/helper/ui tests/ui_test.sh tests/fixtures/bin/gum
git commit -m "feat(ui): ui_pager scrolls output taller than the terminal (styled only)"
```

---

### Task 5: Route `help`, `backup status`, `backup list` through `ui_pager`

**Files:**
- Modify: `src/bin/help` (page in the exec guard)
- Modify: `src/bin/backup` (`status` / `list` cases)
- Test: `tests/backup_test.sh` (append before `finish`)

**Interfaces:**
- Consumes: `ui_pager` (Task 4).

- [ ] **Step 1: Write the failing test — `backup status` pages via the command path**

In `tests/backup_test.sh`, insert before `finish` (this drives the real `status)`
case, so it fails until Step 3 wires it):

```bash
# --- status routes through ui_pager (passthrough in plain ctx) -----------------
# main status on a tiny styled screen must go through the gum pager stub.
sp="$(SNAPCTL_backup_target="sftp://nas/zui" GNUPGHOME="$SNAP_COMMON/.gnupg" \
     UI_ASSUME_TTY=1 UI_COLS=999 UI_LINES=2 main status 2>/dev/null)"
assert_contains "$sp" "[pager]" "main status: pages through ui_pager on a tiny styled screen"
# plain ctx: no pager, content intact
spp="$(SNAPCTL_backup_target="sftp://nas/zui" GNUPGHOME="$SNAP_COMMON/.gnupg" \
      NO_COLOR=1 UI_LINES=2 main status 2>/dev/null)"
assert_contains "$spp" "sftp://nas/zui" "main status: plain ctx keeps content"
case "$spp" in *'[pager]'*) FAIL=$((FAIL+1)); echo "FAIL: plain ctx paged status" >&2 ;; *) PASS=$((PASS+1)) ;; esac
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/backup_test.sh`
Expected: FAIL on "main status: pages…" — the `status)` case still runs bare
`cmd_status`, so no `[pager]` marker appears.

- [ ] **Step 3: Page `help` at the entry point and wire the backup cases**

In `src/bin/help`, replace the exec guard:

```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

with:

```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # main renders styled (UI_TTY1 is cached at source time, so the internal pipe to
    # ui_pager does not flip the context to plain); ui_pager scrolls only on overflow.
    main "$@" | ui_pager
fi
```

(Sourcing in tests still calls `main` directly, so `help`'s unit tests are unaffected; the
guard is one-line glue exercised by manual smoke + the `ui_pager` unit tests.)

Then in `src/bin/backup`'s `main()` `case "$sub" in`, replace:

```bash
        status) cmd_status ;;
```

with:

```bash
        status) cmd_status | ui_pager ;;
```

and replace the entire `list)` arm:

```bash
        list)
            [ -n "$target" ] || { ui_err "backup.target not set."; exit 1; }
            if ! encryption_args >/dev/null 2>&1; then
                ui_err "Set 'backup.encrypt-key=<gpg-fpr>' or opt out with 'backup.encrypt=false'."
                exit 1
            fi
            local raw rows
            # shellcheck disable=SC2294
            raw="$(eval "$(build_list_cmd)")" || { ui_err "Listing failed (duplicity exited non-zero)."; exit 1; }
            rows="$(printf '%s\n' "$raw" | parse_collection_status)"
            if [ -n "$rows" ]; then
                printf '%s\n' "$rows" | ui_table "type" "time" "volumes"
            else
                printf '%s\n' "$raw"     # nothing parsed — show duplicity's own words
            fi
            ;;
```

with (compute output FIRST so error `exit`s stay at top level, THEN page):

```bash
        list)
            [ -n "$target" ] || { ui_err "backup.target not set."; exit 1; }
            if ! encryption_args >/dev/null 2>&1; then
                ui_err "Set 'backup.encrypt-key=<gpg-fpr>' or opt out with 'backup.encrypt=false'."
                exit 1
            fi
            local raw rows out
            # shellcheck disable=SC2294
            raw="$(eval "$(build_list_cmd)")" || { ui_err "Listing failed (duplicity exited non-zero)."; exit 1; }
            rows="$(printf '%s\n' "$raw" | parse_collection_status)"
            if [ -n "$rows" ]; then
                out="$(printf '%s\n' "$rows" | ui_table "type" "time" "volumes")"
            else
                out="$raw"               # nothing parsed — show duplicity's own words
            fi
            printf '%s\n' "$out" | ui_pager
            ;;
```

- [ ] **Step 4: Run all suites to verify pass**

Run: `bash tests/backup_test.sh && bash tests/help_test.sh`
Expected: both end `... passed, 0 failed`.

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/help src/bin/backup tests/backup_test.sh`
Expected: no output.

```bash
git add src/bin/help src/bin/backup tests/backup_test.sh
git commit -m "feat(help,backup): page status/list/help output when it overflows the screen"
```

---

### Task 6: Full verification + CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (extend the `src/helper/ui` description)

- [ ] **Step 1: Run the complete check suite**

```bash
shellcheck --severity=warning -x src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh
for t in tests/*_test.sh; do echo "== $t"; bash "$t" || exit 1; done
```

Expected: shellcheck silent; every suite ends `... passed, 0 failed`.

- [ ] **Step 2: Update CLAUDE.md**

In the `src/helper/ui` bullet (Config translation layer section), after the existing
sentence about `ui_cols`/width-aware help, append:

```markdown
`ui_table` auto-stacks into a generic record form (col-1 title + indented `header: value` lines) whenever a table is wider than `ui_cols`, so every caller (`help`, `backup status`/`list`) fits a narrow terminal; `ui_lines` (terminal height, same fd discipline as `ui_cols`) and `ui_pager` give bounded commands a scrollable viewport when output is taller than the screen (styled TTY only — plain/syslog pass straight through). The live-log scrollable viewer is tracked separately (`docs/superpowers/specs/2026-06-21-responsive-ui-design.md`).
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document width-fit ui_table, ui_lines and ui_pager in CLAUDE.md"
```

---

## Spec coverage map (self-review)

| Spec item (Part A) | Task |
|---|---|
| `ui_lines` primitive (twin of `ui_cols`) | 1 |
| `ui_table` width-fit globally; generic stacked form; `ui_kv` stacking | 2 |
| help refactor onto width-fit `ui_table`; remove bespoke helpers | 3 |
| `ui_pager` (page-on-overflow, gates on stdout) | 4 |
| Route `help` / `backup status` / `backup list` through `ui_pager` | 5 |
| Context-matrix degradation (styled only; plain/syslog passthrough) | 2,4 (tested) |
| CLAUDE.md updated; full sweep green | 6 |

Part B (live `logs` reshape via `less +F -R`, stage `less`) is intentionally a
separate plan: `2026-06-21-responsive-logs-viewer.md`.
