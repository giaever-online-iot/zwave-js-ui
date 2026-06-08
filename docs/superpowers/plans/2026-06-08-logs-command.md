# `zwave-js-ui.logs` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `zwave-js-ui.logs` command that shows a single, terminal-friendly, live-follow view of the ZUI app and Z-Wave JS driver logs, auto-selecting file-vs-journal per stream, with an optional filter to one stream.

**Architecture:** One bash script `src/bin/logs` decomposed into small pure functions (arg parsing, settings read, source resolution, labeling, prefixing, follower-command building) plus a `main` that launches one backgrounded follower per active source through a label-prefixer and tears them down on exit. Pure functions are unit-tested by a zero-dependency bash harness; execution/cleanup and the three verification items are covered by an integration task on a built snap.

**Tech Stack:** Bash, `yq` (already staged in the snap), `journalctl`/`tail`, snapcraft `core24`. Tests: plain bash + `shellcheck`.

---

## File structure

| File | Responsibility |
|------|----------------|
| `src/bin/logs` (new) | The command. Sources `helper/functions`; defines pure helpers + `main`; runs `main` only when executed, not when sourced. |
| `tests/lib/assert.sh` (new) | Tiny assertion helpers (`assert_eq`, `assert_contains`, `assert_status`). |
| `tests/fixtures/helper/functions` (new) | Stub of the shared lib so `src/bin/logs` can be sourced under test without the snap runtime. |
| `tests/logs_test.sh` (new) | Sources `src/bin/logs` with `SNAP`/`SNAP_DATA` pointed at fixtures/temp dirs; runs unit tests. |
| `snap/snapcraft.yaml` (modify) | Add the `logs` app entry plugging `log-observe`. |
| `src/bin/logs-observe` (delete) | Broken predecessor, superseded. |
| `src/helper/env-wrapper` (modify) | Update `--help` text to mention `zwave-js-ui.logs`. |
| `CLAUDE.md` (modify) | Add `zwave-js-ui.logs` to the command list; drop the `logs-observe` mention. |
| `.github/workflows/lint-test.yml` (new) | `shellcheck` + run the bash tests (audit item #10). |

**Script skeleton** (every task adds functions into this shape; `main` runs only when executed directly so tests can source it):

```bash
#!/usr/bin/env bash
# logs — unified, terminal-friendly log follower for zwave-js-ui
: "${SNAP:?SNAP must be set}"
source "$SNAP/helper/functions"

# ---- pure helpers (unit-tested) added by Tasks 3-7 ----

main() {
    : # assembled in Task 8
}

# run main only when executed, not when sourced (enables unit tests)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

---

## Task 1: Confirm upstream defaults and log filenames

**Files:** none yet — this resolves values used by later tasks (VERIFY #1, #2 from the spec).

- [ ] **Step 1: Find the ZUI gateway + ZWJS driver `logToFile` defaults and on-disk filenames**

Fetch the upstream config to confirm (a) the default of `gateway.logToFile` and `zwave.logToFile`, and (b) the exact log filenames written to disk.

Run (engineer): use WebFetch on these, or `git clone --depth 1 https://github.com/zwave-js/zwave-js-ui` and grep:
- Settings/defaults: search the repo for `logToFile`, `logToFile:` defaults, and the gateway/zwave settings schema.
- Filenames: search for `nestedTransports`, `fileTransport`, `_current.log`, `getLogFileName`, `DATE` patterns. zwave-js driver uses `ZWAVEJS_LOGS_DIR`; confirm it writes `zwavejs_%DATE%.log` + a `zwavejs_current.log`.

Expected outcome (confirm or correct): both default to `false` (console → journal); ZWJS file is `${ZWAVEJS_LOGS_DIR}/zwavejs_current.log`; ZUI gateway file under `$SNAP_DATA/logs/` (record the exact pattern).

- [ ] **Step 2: Record findings**

Edit the spec's verification section (`docs/superpowers/specs/2026-06-08-logs-command-design.md`) to replace VERIFY #1/#2 with the confirmed values. Set the `canonical_log_path` ZUI filename used in Task 5 to the confirmed name (this plan uses `zwave-js-ui_current.log` as the working assumption — change it if upstream differs).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-06-08-logs-command-design.md
git commit -m "docs(spec): confirm upstream logToFile defaults and log filenames"
```

---

## Task 2: Test harness + fixtures

**Files:**
- Create: `tests/lib/assert.sh`, `tests/fixtures/helper/functions`, `tests/logs_test.sh`
- Create: `src/bin/logs` (skeleton from File structure above)

- [ ] **Step 1: Write the assertion helper**

`tests/lib/assert.sh`:
```bash
#!/usr/bin/env bash
# Minimal zero-dependency assertions. Each increments PASS/FAIL counters.
: "${PASS:=0}"; : "${FAIL:=0}"

assert_eq() { # $1 actual $2 expected $3 msg
    if [ "$1" = "$2" ]; then PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$2" "$1" >&2; fi
}
assert_contains() { # $1 haystack $2 needle $3 msg
    case "$1" in *"$2"*) PASS=$((PASS+1));;
        *) FAIL=$((FAIL+1)); printf 'FAIL: %s\n  %q does not contain %q\n' "$3" "$1" "$2" >&2;; esac
}
assert_status() { # $1 actual_status $2 expected_status $3 msg
    if [ "$1" = "$2" ]; then PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected status %s, got %s\n' "$3" "$2" "$1" >&2; fi
}
finish() { printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }
```

- [ ] **Step 2: Write the functions stub**

`tests/fixtures/helper/functions` (only what `src/bin/logs` references at source time + the helpers it calls):
```bash
#!/usr/bin/env bash
SNAP_NAME="zwave-js-ui"
lprint() { echo "$*"; }
require_root() { :; }   # no-op under test
```

- [ ] **Step 3: Write the script skeleton**

Create `src/bin/logs` exactly as the "Script skeleton" block in the File structure section. Make it executable:
```bash
chmod +x src/bin/logs
```

- [ ] **Step 4: Write the test runner bootstrap**

`tests/logs_test.sh`:
```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

# Source the script under test with a stubbed snap runtime.
export SNAP="$HERE/fixtures"
export SNAP_DATA="$(mktemp -d)"
trap 'rm -rf "$SNAP_DATA"' EXIT
# shellcheck source=/dev/null
source "$ROOT/src/bin/logs"

# --- tests appended by later tasks ---

finish
```

- [ ] **Step 5: Run the harness (sanity)**

Run: `bash tests/logs_test.sh`
Expected: `0 passed, 0 failed` and exit 0 (script sources cleanly, `main` does not run).

- [ ] **Step 6: Commit**

```bash
git add tests src/bin/logs
git commit -m "test: bash test harness + logs script skeleton"
```

---

## Task 3: Argument parsing

**Files:** Modify `src/bin/logs` (add helpers), `tests/logs_test.sh` (add tests).

- [ ] **Step 1: Write the failing tests**

Append to `tests/logs_test.sh` (before `finish`):
```bash
assert_eq "$(normalize_target '')"      "both" "empty -> both"
assert_eq "$(normalize_target 'zui')"   "zui"  "zui -> zui"
assert_eq "$(normalize_target '--zui')" "zui"  "--zui -> zui"
assert_eq "$(normalize_target 'zwjs')"  "zwjs" "zwjs -> zwjs"
assert_eq "$(normalize_target '--zwjs')" "zwjs" "--zwjs -> zwjs"
normalize_target 'nope' >/dev/null 2>&1; assert_status "$?" "2" "unknown -> status 2"
parse_args a b >/dev/null 2>&1; assert_status "$?" "2" "two args -> status 2"
assert_eq "$(parse_args --zwjs)" "zwjs" "parse_args passes through"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/logs_test.sh`
Expected: FAIL lines ("normalize_target: command not found" surfaced as failed asserts).

- [ ] **Step 3: Implement**

Add to `src/bin/logs` (in the pure-helpers section):
```bash
usage() {
    cat <<EOF
Usage: ${SNAP_NAME}.logs [zui|--zui|zwjs|--zwjs]

  (no arg)        follow both streams, merged
  zui  | --zui    follow the Z-Wave JS UI application log only
  zwjs | --zwjs   follow the Z-Wave JS driver log only
  -h   | --help   show this help
EOF
}

normalize_target() {           # $1 raw token; echoes both|zui|zwjs; status 2 if unknown
    case "${1#--}" in
        "")   echo both ;;
        zui)  echo zui ;;
        zwjs) echo zwjs ;;
        *)    return 2 ;;
    esac
}

parse_args() {                 # echoes target or status 2; accepts 0 or 1 token
    [ "$#" -le 1 ] || return 2
    normalize_target "${1:-}"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/logs_test.sh`
Expected: all asserts pass.

- [ ] **Step 5: Commit**

```bash
git add src/bin/logs tests/logs_test.sh
git commit -m "feat(logs): argument parsing (zui/zwjs, bare or --flag)"
```

---

## Task 4: Settings read + stream→key mapping

**Files:** Modify `src/bin/logs`, `tests/logs_test.sh`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/logs_test.sh`:
```bash
assert_eq "$(setting_key zui)"  ".gateway.logToFile" "zui key"
assert_eq "$(setting_key zwjs)" ".zwave.logToFile"   "zwjs key"

# read_log_setting: file path + yq path -> true|false|""
_sf="$SNAP_DATA/settings.json"
printf '%s' '{"gateway":{"logToFile":true},"zwave":{"logToFile":false}}' > "$_sf"
assert_eq "$(read_log_setting "$_sf" .gateway.logToFile)" "true"  "reads true"
assert_eq "$(read_log_setting "$_sf" .zwave.logToFile)"   "false" "reads false"
assert_eq "$(read_log_setting "$_sf" .missing.key)"       ""      "missing key -> empty"
assert_eq "$(read_log_setting "/no/such/file" .gateway.logToFile)" "" "no file -> empty"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/logs_test.sh`
Expected: new asserts FAIL ("setting_key: command not found", etc.). Requires `yq` on PATH — confirm with `yq --version`.

- [ ] **Step 3: Implement**

Add to `src/bin/logs`:
```bash
setting_key() {                # $1 stream -> yq path
    case "$1" in
        zui)  echo ".gateway.logToFile" ;;
        zwjs) echo ".zwave.logToFile" ;;
    esac
}

settings_file() { echo "$SNAP_DATA/settings.json"; }

read_log_setting() {           # $1 settings file, $2 yq path -> true|false|""
    local sf="$1" key="$2" v
    [ -n "$sf" ] && [ -e "$sf" ] || { echo ""; return 0; }
    # Feed via stdin redirect (shell opens the file) rather than passing the path
    # to yq: yq is a confined snap that cannot open arbitrary paths (e.g. /tmp under
    # test). Do NOT use `// ""` — that alternative operator treats `false` as empty,
    # collapsing an explicit "log to file OFF" into the unset/infer path.
    v=$(yq -r "$key" - < "$sf" 2>/dev/null)
    case "$v" in
        true)  echo true ;;
        false) echo false ;;
        *)     echo "" ;;   # null / missing / anything else
    esac
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/logs_test.sh`
Expected: all asserts pass.

- [ ] **Step 5: Commit**

```bash
git add src/bin/logs tests/logs_test.sh
git commit -m "feat(logs): read logToFile settings via yq"
```

---

## Task 5: Source resolution

**Files:** Modify `src/bin/logs`, `tests/logs_test.sh`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/logs_test.sh`:
```bash
# canonical paths (logs_dir defaults to $SNAP_DATA/logs/zwavejs — the dir env-wrapper
# sets for the daemon; ZUI current file is z-ui_current.log, NOT zwave-js-ui_current.log)
assert_eq "$(canonical_log_path zwjs)" "$SNAP_DATA/logs/zwavejs/zwavejs_current.log" "zwjs canonical"
assert_eq "$(canonical_log_path zui)"  "$SNAP_DATA/logs/zwavejs/z-ui_current.log"    "zui canonical"

# resolve_source: explicit false -> journal
assert_eq "$(resolve_source zui false)" "journal" "false -> journal"

# explicit true, no file yet -> file:<canonical>
assert_eq "$(resolve_source zwjs true)" "file:$SNAP_DATA/logs/zwavejs/zwavejs_current.log" "true,no file -> canonical"

# unset, no file -> journal
assert_eq "$(resolve_source zui '')" "journal" "unset,no file -> journal"

# unset, file exists in logs_dir -> file:<existing>
mkdir -p "$SNAP_DATA/logs/zwavejs"
: > "$SNAP_DATA/logs/zwavejs/zwavejs_current.log"
assert_eq "$(resolve_source zwjs '')" "file:$SNAP_DATA/logs/zwavejs/zwavejs_current.log" "unset,file -> file"

# tolerant: ZUI file in the parent $SNAP_DATA/logs is also found
: > "$SNAP_DATA/logs/z-ui_current.log"
assert_eq "$(resolve_source zui '')" "file:$SNAP_DATA/logs/z-ui_current.log" "unset,zui file in parent -> file"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/logs_test.sh`
Expected: new asserts FAIL.

- [ ] **Step 3: Implement**

Add to `src/bin/logs`:
```bash
# Both ZUI and ZWJS write to one shared logs dir. The daemon's env-wrapper sets
# ZWAVEJS_LOGS_DIR=$SNAP_DATA/logs/zwavejs; the logs command does NOT run through
# env-wrapper, so it falls back to that same path and also searches the parent
# $SNAP_DATA/logs for tolerance. Filenames confirmed in Task 1:
#   ZUI -> z-ui_current.log / z-ui_*.log     ZWJS -> zwavejs_current.log / zwavejs_*.log
logs_dir() { echo "${ZWAVEJS_LOGS_DIR:-$SNAP_DATA/logs/zwavejs}"; }

log_basename() {               # $1 stream -> filename stem
    case "$1" in zui) echo "z-ui" ;; zwjs) echo "zwavejs" ;; esac
}

canonical_log_path() {         # $1 stream -> path the app writes when logging to file
    echo "$(logs_dir)/$(log_basename "$1")_current.log"
}

existing_log_file() {          # $1 stream -> newest existing file, or empty
    local base; base="$(log_basename "$1")"
    local f
    f=$(ls -t \
        "$(logs_dir)/${base}_current.log" "$SNAP_DATA/logs/${base}_current.log" \
        "$(logs_dir)/${base}_"*.log "$SNAP_DATA/logs/${base}_"*.log \
        2>/dev/null | head -1)
    [ -n "${f:-}" ] && [ -e "$f" ] && echo "$f"
}

resolve_source() {             # $1 stream, $2 setting(true|false|"") -> file:<path> | journal
    local stream="$1" setting="$2" f
    case "$setting" in
        true)
            f=$(existing_log_file "$stream"); [ -n "$f" ] || f=$(canonical_log_path "$stream")
            echo "file:$f" ;;
        false)
            echo journal ;;
        *)
            f=$(existing_log_file "$stream")
            if [ -n "$f" ]; then echo "file:$f"; else echo journal; fi ;;
    esac
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/logs_test.sh`
Expected: all asserts pass.

- [ ] **Step 5: Commit**

```bash
git add src/bin/logs tests/logs_test.sh
git commit -m "feat(logs): file-vs-journal source resolution with inference"
```

---

## Task 6: Labels and color

**Files:** Modify `src/bin/logs`, `tests/logs_test.sh`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/logs_test.sh`:
```bash
assert_eq "$(stream_upper zui)"  "ZUI"  "upper zui"
assert_eq "$(stream_upper zwjs)" "ZWJS" "upper zwjs"
assert_eq "$(stream_color zui)"  "cyan" "color zui"
assert_eq "$(journal_label zwjs)" "ZWJS" "journal label single"
assert_eq "$(journal_label zui zwjs)" "ZUI/ZWJS" "journal label combined"

# no-color prefix is plain
assert_eq "$(make_prefix ZUI cyan 0)" "[ZUI] " "plain prefix"
# colored prefix contains the escape and the label
assert_contains "$(make_prefix ZUI cyan 1)" "[ZUI]" "color prefix has label"
assert_contains "$(make_prefix ZUI cyan 1)" "$(printf '\033[36m')" "color prefix has cyan"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/logs_test.sh`
Expected: new asserts FAIL.

- [ ] **Step 3: Implement**

Add to `src/bin/logs`:
```bash
stream_upper() { case "$1" in zui) echo ZUI ;; zwjs) echo ZWJS ;; esac; }
stream_color() { case "$1" in zui) echo cyan ;; zwjs) echo green ;; esac; }

journal_label() {              # $@ streams -> "ZUI", "ZWJS", or "ZUI/ZWJS"
    local out="" s
    for s in "$@"; do out="${out:+$out/}$(stream_upper "$s")"; done
    echo "$out"
}

ansi() { case "$1" in cyan) printf '\033[36m' ;; green) printf '\033[32m' ;; yellow) printf '\033[33m' ;; esac; }

make_prefix() {                # $1 text, $2 color, $3 use_color(0|1) -> "[TEXT] " maybe colored
    if [ "$3" = "1" ] && [ -n "$2" ]; then
        printf '%b[%s]%b ' "$(ansi "$2")" "$1" '\033[0m'
    else
        printf '[%s] ' "$1"
    fi
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/logs_test.sh`
Expected: all asserts pass.

- [ ] **Step 5: Commit**

```bash
git add src/bin/logs tests/logs_test.sh
git commit -m "feat(logs): stream labels and TTY-aware color prefixes"
```

---

## Task 7: Prefixer + follower command builder

**Files:** Modify `src/bin/logs`, `tests/logs_test.sh`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/logs_test.sh`:
```bash
# prefix_lines prepends to each line
out="$(printf 'a\nb\n' | prefix_lines '[X] ')"
assert_eq "$out" "$(printf '[X] a\n[X] b')" "prefix_lines per line"

# follower_cmd builds tail / journalctl invocations
assert_contains "$(follower_cmd 'file:/var/log/zui_current.log' 20)" "tail -n 20 -F" "file -> tail"
assert_contains "$(follower_cmd 'file:/var/log/zui_current.log' 20)" "zui_current.log" "file -> path"
assert_contains "$(follower_cmd journal 20)" "journalctl -u" "journal -> journalctl"
assert_contains "$(follower_cmd journal 20)" "snap.zwave-js-ui.zwave-js-ui.service" "journal -> unit"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/logs_test.sh`
Expected: new asserts FAIL.

- [ ] **Step 3: Implement**

Add to `src/bin/logs`:
```bash
prefix_lines() {               # $1 prefix; prepends to each stdin line
    local prefix="$1" line
    while IFS= read -r line; do printf '%s%s\n' "$prefix" "$line"; done
}

journal_unit() { echo "snap.${SNAP_NAME}.${SNAP_NAME}.service"; }

follower_cmd() {               # $1 source spec, $2 backlog -> a %q-quoted command string
    local spec="$1" n="$2"
    case "$spec" in
        file:*)  printf 'tail -n %s -F %q' "$n" "${spec#file:}" ;;
        journal) printf 'journalctl -u %q -n %s -f' "$(journal_unit)" "$n" ;;
    esac
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/logs_test.sh`
Expected: all asserts pass.

- [ ] **Step 5: Commit**

```bash
git add src/bin/logs tests/logs_test.sh
git commit -m "feat(logs): line prefixer and follower command builder"
```

---

## Task 8: Assemble `main` (launch, dedupe journal, cleanup)

**Files:** Modify `src/bin/logs`. No unit test (process orchestration — covered by Task 11 integration). Verified here only by `shellcheck` + a no-op dry path.

- [ ] **Step 1: Implement `main` and the launcher**

Replace the placeholder `main()` in `src/bin/logs` with:
```bash
launch_follower() {            # $1 source spec, $2 prefix — backgrounds a subshell pipeline
    # Wrap the pipeline in a subshell so $! is the subshell. Use `exec` inside the eval
    # so the follower (tail/journalctl) REPLACES the intermediate shell and becomes a
    # DIRECT child of the subshell — otherwise `pkill -P` only reaches the intermediate
    # shell and tail/journalctl orphans (keeps running, root-owned) on Ctrl-C.
    # follower_cmd always emits a single external-command invocation, so exec is safe.
    # shellcheck disable=SC2294
    ( eval "exec $(follower_cmd "$1" "$BACKLOG")" 2>&1 | prefix_lines "$2" ) &
}

main() {
    # Help works without root and before arg validation. (Only -h/--help; no bare alias.)
    case "${1:-}" in -h|--help) usage; exit 0 ;; esac

    require_root

    local target; target="$(parse_args "$@")" || { usage >&2; exit 2; }

    local use_color=0; [ -t 1 ] && use_color=1

    local streams=()
    case "$target" in
        both) streams=(zui zwjs) ;;
        zui)  streams=(zui) ;;
        zwjs) streams=(zwjs) ;;
    esac

    local sf; sf="$(settings_file)"
    local BACKLOG=20
    local pids=() journal_streams=() s setting src p

    # Register cleanup BEFORE launching anything, so a Ctrl-C mid-launch still reaps every
    # follower subshell AND its children (tail/journalctl + prefixer). Empty pids = no-op.
    trap 'for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done' EXIT INT TERM

    for s in "${streams[@]}"; do
        setting="$(read_log_setting "$sf" "$(setting_key "$s")")"
        src="$(resolve_source "$s" "$setting")"
        if [ "$src" = journal ]; then
            journal_streams+=("$s")
        else
            launch_follower "$src" "$(make_prefix "$(stream_upper "$s")" "$(stream_color "$s")" "$use_color")"
            pids+=("$!")
        fi
    done

    if [ "${#journal_streams[@]}" -gt 0 ]; then
        # Honesty notice: a filtered (single-stream) journal view can include the other component.
        if [ "$target" != both ]; then
            lprint "Note: ${target} is logging to the journal, a shared process stream; other components may appear." >&2
        fi
        launch_follower journal "$(make_prefix "$(journal_label "${journal_streams[@]}")" yellow "$use_color")"
        pids+=("$!")
    fi

    if [ "${#pids[@]}" -eq 0 ]; then
        lprint "No logs to follow yet. Start/configure ${SNAP_NAME} first (see ${SNAP_NAME}.help)." >&2
        exit 1
    fi

    wait
}
```

- [ ] **Step 2: Lint**

Run: `shellcheck src/bin/logs`
Expected: no errors. (If `shellcheck` is absent: `sudo snap install shellcheck` or `sudo apt-get install -y shellcheck`.)

- [ ] **Step 3: Verify the no-source path without root/runtime**

Run:
```bash
SNAP="$PWD/tests/fixtures" SNAP_DATA="$(mktemp -d)" bash src/bin/logs --zui; echo "exit=$?"
```
Expected: prints the "No logs to follow yet" message and `exit=1` (no settings, no files → journal resolution, but we don't reach `wait` because... actually journal IS a source). 

> NOTE for implementer: with no settings, `--zui` resolves to **journal**, so `pids` is non-empty and `main` proceeds to launch `journalctl` and `wait`. To exercise the "No logs" branch you must force both streams to a missing *file* source. The real behavior here (attempting journalctl) is correct and is validated in Task 11 on a snap. For this step, instead confirm `main` reaches the launch path without syntax errors:
```bash
SNAP="$PWD/tests/fixtures" SNAP_DATA="$(mktemp -d)" timeout 2 bash -x src/bin/logs --zui 2>&1 | grep -q journalctl && echo "reaches journalctl"
```
Expected: `reaches journalctl` (journalctl may then error on a dev box lacking the unit — fine; cleanup via trap).

- [ ] **Step 4: Re-run unit tests (no regressions)**

Run: `bash tests/logs_test.sh`
Expected: all asserts still pass (sourcing `src/bin/logs` does not run `main`).

- [ ] **Step 5: Commit**

```bash
git add src/bin/logs
git commit -m "feat(logs): assemble main — launch, dedupe journal, trap cleanup"
```

---

## Task 9: Wire into the snap; remove predecessor; update docs

**Files:** Modify `snap/snapcraft.yaml`; delete `src/bin/logs-observe`; modify `src/helper/env-wrapper`; modify `CLAUDE.md`.

- [ ] **Step 1: Add the app entry**

In `snap/snapcraft.yaml`, inside `apps:`, after the `restart:` entry (around line 113-114), add:
```yaml
  logs:
    command: bin/logs
    plugs:
      - log-observe
```

- [ ] **Step 2: Delete the broken predecessor**

```bash
git rm src/bin/logs-observe
```

- [ ] **Step 3: Update `--help` text**

In `src/helper/env-wrapper`, replace the two manual-log hints (lines ~49-53) so they point at the new command. Change the block that currently reads:
```bash
    echo "If you have turned OFF «log to file», follow the log(s) with"
    echo "  $ sudo snap logs ${SNAP_NAME} -f"
    echo ""
    echo "OR if you have turned ON «log to file», tail the logs with"
    echo "  $ tail -f ${SNAP_DATA}/*.log"
```
to:
```bash
    echo "Follow the logs (auto-detects file vs journal) with:"
    echo "  $ sudo ${SNAP_NAME}.logs            # both ZUI + driver, merged"
    echo "  $ sudo ${SNAP_NAME}.logs zui        # app only"
    echo "  $ sudo ${SNAP_NAME}.logs zwjs       # driver only"
```

- [ ] **Step 4: Update `CLAUDE.md`**

In the "Inspecting / running the installed snap" command list, add a line and remove any `logs-observe` reference:
```
zwave-js-ui.logs       # unified, terminal-friendly live log view (zui | zwjs to filter)
```
Also update the "User commands (`src/bin/`)" paragraph: replace the mention of `logs-observe` (minimal/WIP) with `logs` (the unified follower), and note `backup` remains WIP.

- [ ] **Step 5: Commit**

```bash
git add snap/snapcraft.yaml src/helper/env-wrapper CLAUDE.md
git rm --cached src/bin/logs-observe 2>/dev/null || true
git commit -m "feat(logs): expose logs app, retire logs-observe, update help/docs"
```

---

## Task 10: shellcheck + test CI gate (audit #10)

**Files:** Create `.github/workflows/lint-test.yml`.

- [ ] **Step 1: Add the workflow**

`.github/workflows/lint-test.yml`:
```yaml
name: Lint & test
on:
  pull_request:
    branches: [main]
    paths:
      - 'src/**'
      - 'tests/**'
      - '.github/workflows/lint-test.yml'
  workflow_dispatch:

jobs:
  lint-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: shellcheck
        run: |
          sudo apt-get update && sudo apt-get install -y shellcheck
          shellcheck src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh
      - name: Install yq
        run: sudo snap install yq
      - name: Unit tests
        run: bash tests/logs_test.sh
```

- [ ] **Step 2: Run shellcheck locally over everything it will gate**

Run: `shellcheck src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh`
Expected: no errors. (Pre-existing scripts may surface warnings — fix only what blocks; broader cleanup is the separate audit batch #3-9.)

> NOTE: existing scripts have known issues from the audit (unquoted vars, `test_perm`). If shellcheck errors on them block CI, either fix inline here or scope the lint step to `src/bin/logs tests/**` for now and widen it in the audit-cleanup PR. Prefer fixing if quick.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint-test.yml
git commit -m "ci: shellcheck + bash unit tests for src scripts (audit #10)"
```

---

## Task 11: Integration verification on a built snap

**Files:** none (validation). Resolves VERIFY #1 (filenames) and #3 (root requirement); confirms Ctrl-C cleanup, color/TTY, and filter behavior.

- [ ] **Step 1: Build and install**

```bash
snapcraft
sudo snap install --dangerous ./zwave-js-ui_*_amd64.snap
sudo snap connect zwave-js-ui:log-observe
sudo snap connect zwave-js-ui:raw-usb
sudo snap connect zwave-js-ui:hardware-observe
```

- [ ] **Step 2: Confirm filenames (VERIFY #1)**

With the daemon enabled and "log to file" toggled on in the UI for each component, inspect:
```bash
sudo ls -la /var/snap/zwave-js-ui/current/logs/ /var/snap/zwave-js-ui/current/logs/zwavejs/
```
Confirm the ZUI file matches `canonical_log_path zui` (`zwave-js-ui_current.log`). If not, fix `canonical_log_path`/`existing_log_file` patterns in `src/bin/logs` and re-run unit tests.

- [ ] **Step 3: Confirm root requirement (VERIFY #3)**

Try without sudo:
```bash
zwave-js-ui.logs zui
```
If it reads file + journal fine unprivileged, remove `require_root` from `main` (and update the help text to drop `sudo`). If it's denied, keep `require_root`. Re-run unit tests after any change.

- [ ] **Step 4: Behavioral checks**

- Both-merged: `sudo zwave-js-ui.logs` shows `[ZUI]`/`[ZWJS]` (or `[ZUI/ZWJS]` for journal) interleaved, colored in a terminal.
- Filter: `sudo zwave-js-ui.logs zwjs` shows only the driver; if journal-backed with ZUI also journal-backed, the one-time stderr notice appears.
- Plain when piped: `sudo zwave-js-ui.logs | head` has no ANSI escapes.
- Cleanup: Ctrl-C returns the prompt with no orphaned `tail`/`journalctl` (`pgrep -af 'tail -F\|journalctl -u snap.zwave-js-ui'` is empty afterward).

- [ ] **Step 5: Commit any fixes; open the PR**

```bash
git add -A && git commit -m "fix(logs): align log paths / root handling with on-device behavior" || echo "no fixes needed"
git push -u origin feat/logs-command
gh pr create --base main --title "feat: unified zwave-js-ui.logs command" --body "Implements docs/superpowers/specs/2026-06-08-logs-command-design.md"
```

---

## Self-review

- **Spec coverage:** command surface (T3), both/zui/zwjs filter (T3/T8), file-vs-journal inference (T5), shared-journal dedupe + honesty notice (T8), backlog-then-follow (T7 `-n 20`), labels/color TTY-aware (T6/T8), `log-observe` app wiring (T9), error handling (T4/T5/T8), delete logs-observe + help/CLAUDE.md (T9), verification items (T1, T11), shellcheck CI (T10). All covered.
- **Placeholder scan:** no TBD/TODO; the only deferred concretes are the upstream-confirmed filename (T1) and root requirement (T11), both with explicit resolution steps and tolerant fallbacks — not placeholders in code.
- **Type/name consistency:** function names used in `main` (T8) — `parse_args`, `read_log_setting`, `setting_key`, `resolve_source`, `make_prefix`, `stream_upper`, `stream_color`, `journal_label`, `follower_cmd`, `prefix_lines`, `settings_file` — all defined in T3–T7. `BACKLOG`/`-n 20` consistent between T7 tests and T8.
