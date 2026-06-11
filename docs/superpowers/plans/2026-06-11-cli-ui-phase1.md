# Uniform CLI UI — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A gum-backed UI library (`src/helper/ui`) and a uniform restyle of every command endpoint (`help`, `enable`, `disable`, `restart`, `logs`, `backup`), per the approved spec `docs/superpowers/specs/2026-06-11-cli-ui-design.md` (phase 1 only — the interactive navigator is phase 2, a separate plan).

**Architecture:** gum is built from a pinned source tag as a new snapcraft part and invoked ONLY from `src/helper/ui`. Every `ui_*` function resolves an output context — `syslog` (`DAEMONIZED=1` → `lprint`), `plain` (no TTY / `NO_COLOR` / `TERM=dumb` / gum missing → zero ANSI bytes), or `styled` (TTY + gum). Interactive widgets are additive: every command keeps its argument-driven path, and widgets exit 2 with a hint when there is no TTY.

**Tech Stack:** bash, gum v0.17.0 (Go ≥1.23, snapcraft `go` plugin), yq, the existing zero-dependency test harness in `tests/` (assert.sh + source-the-script + `$SNAP` pointed at `tests/fixtures`).

**Conventions you must know (read before starting):**
- Scripts are sourced by tests with `export SNAP="$HERE/fixtures"`; `tests/fixtures/helper/functions` is a stub defining `SNAP_NAME`, `lprint`, `require_root`. Real `src/bin/*` scripts guard execution with `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi` so sourcing is side-effect free.
- CI (`.github/workflows/lint-test.yml`) runs `shellcheck --severity=warning -x` over `src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh` — keep new code shellcheck-clean (quote expansions, no unused vars).
- `lprint` routes to syslog when `DAEMONIZED=1`; the backup timer and hooks run daemonized. Never emit ANSI on those paths.
- Run all commands from the repo root (this worktree). Run tests with `bash tests/<file>_test.sh`; success output ends with `N passed, 0 failed`.

---

### Task 1: gum snapcraft part + Renovate tracking

**Files:**
- Modify: `snap/snapcraft.yaml` (parts section, after the `backup-deps` part)
- Modify: `renovate.json`

- [ ] **Step 1: Add the gum part**

In `snap/snapcraft.yaml`, append to the `parts:` section (after `backup-deps`):

```yaml
  gum:
    plugin: go
    source: https://github.com/charmbracelet/gum.git
    # renovate: depName=charmbracelet/gum
    source-tag: v0.17.0
    build-snaps:
      - go/1.24/stable
    build-environment:
      - CGO_ENABLED: "0"
```

The `go` plugin runs `go install ./...`, landing the binary at `bin/gum` → `$SNAP/bin/gum` at runtime. `CGO_ENABLED=0` keeps it static (no base-lib coupling on armhf).

- [ ] **Step 2: Add the Renovate rule**

In `renovate.json`, add a second object to the existing `customManagers` array (keep the first one unchanged):

```json
    {
      "customType": "regex",
      "managerFilePatterns": [
        "/^snap/snapcraft\\.yaml$/"
      ],
      "matchStrings": [
        "# renovate: depName=(?<depName>[^\\s]+)\\n\\s+source-tag: (?<currentValue>v[\\d.]+)"
      ],
      "datasourceTemplate": "github-releases"
    }
```

- [ ] **Step 3: Verify both files parse**

Run: `yq eval '.parts.gum.source-tag' snap/snapcraft.yaml && yq eval -o=j '.customManagers | length' renovate.json`
Expected: `v0.17.0` and `2`

- [ ] **Step 4: Commit**

```bash
git add snap/snapcraft.yaml renovate.json
git commit -m "build(snap): add gum part (v0.17.0, go plugin) with renovate tracking"
```

---

### Task 2: ui library core — context resolution + status output

**Files:**
- Create: `src/helper/ui`
- Create: `tests/ui_test.sh`
- Create: `tests/fixtures/bin/gum` (executable stub)
- Create: `tests/fixtures/helper/ui` (shim so bin scripts can `source "$SNAP/helper/ui"` under test)
- Modify: `.github/workflows/lint-test.yml` (run all `tests/*_test.sh`)

- [ ] **Step 1: Create the gum stub fixture**

Create `tests/fixtures/bin/gum`:

```bash
#!/usr/bin/env bash
# Fake gum for unit tests: records argv to $GUM_LOG, emits canned results via GUM_* env.
[ -n "${GUM_LOG:-}" ] && printf '%s\n' "$*" >> "$GUM_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
    choose)  printf '%s\n' "${GUM_CHOOSE:?GUM_CHOOSE not set}" ;;
    input)   printf '%s\n' "${GUM_INPUT:?GUM_INPUT not set}" ;;
    confirm) exit "${GUM_CONFIRM:-0}" ;;
    spin)    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift; "$@" ;;
    table)   sed 's/^/[table] /' ;;
    format)  sed 's/^/[format] /' ;;
    style)   for a in "$@"; do :; done; printf '[style] %s\n' "${a:-}" ;;
    *)       exit 64 ;;
esac
```

Run: `chmod +x tests/fixtures/bin/gum`

- [ ] **Step 2: Create the ui shim fixture**

Create `tests/fixtures/helper/ui`:

```bash
#!/usr/bin/env bash
# Test shim: bin scripts `source "$SNAP/helper/ui"`; under test $SNAP is tests/fixtures,
# so load the REAL library from src/.
source "$(dirname "${BASH_SOURCE[0]}")/../../../src/helper/ui"
```

- [ ] **Step 3: Write the failing tests**

Create `tests/ui_test.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT
GUM_LOG="$SNAP_DATA/gum.log"; export GUM_LOG

# shellcheck source=/dev/null
source "$SNAP/helper/functions"     # fixture stub: SNAP_NAME, lprint, require_root
# shellcheck source=/dev/null
source "$ROOT/src/helper/ui"

# --- context resolution -------------------------------------------------
# CI has no TTY, so the bare context is plain; UI_ASSUME_TTY=1 simulates a TTY.
assert_eq "$(ui_ctx)"                                  "plain"  "no TTY -> plain"
assert_eq "$(DAEMONIZED=1 ui_ctx)"                     "syslog" "daemonized -> syslog"
assert_eq "$(DAEMONIZED=1 UI_ASSUME_TTY=1 ui_ctx)"     "syslog" "daemonized wins over TTY"
assert_eq "$(UI_ASSUME_TTY=1 ui_ctx)"                  "styled" "TTY + stub gum -> styled"
assert_eq "$(UI_ASSUME_TTY=1 NO_COLOR=1 ui_ctx)"       "plain"  "NO_COLOR -> plain"
assert_eq "$(UI_ASSUME_TTY=1 TERM=dumb ui_ctx)"        "plain"  "TERM=dumb -> plain"
assert_eq "$(UI_ASSUME_TTY=1 UI_GUM=/nonexistent ui_ctx)" "plain" "gum missing -> plain"

# Wrap in $() so stdout is a pipe — keeps the assertion deterministic when the
# test file itself is run on a real terminal.
assert_eq "$(ui_interactive >/dev/null 2>&1; echo $?)" "1" "no TTY -> not interactive"
assert_eq "$(UI_ASSUME_TTY=1 ui_interactive; echo $?)" "0" "TTY -> interactive"

# --- status output: plain wording ----------------------------------------
assert_eq "$(ui_print hello)"        "hello"        "ui_print plain"
assert_eq "$(ui_header T sub)"       "== T · sub ==" "header plain"
assert_eq "$(ui_header T)"           "== T =="      "header plain, no subtitle"
assert_eq "$(ui_ok done)"            "OK: done"     "ok plain"
assert_eq "$(ui_warn careful 2>&1)"  "WARN: careful" "warn plain -> stderr"
assert_eq "$(ui_err broken 2>&1)"    "ERROR: broken" "err plain -> stderr"

# warn/err go to stderr, not stdout
assert_eq "$(ui_err broken 2>/dev/null)" "" "err writes nothing to stdout"

# --- status output: styled goes through gum ------------------------------
assert_contains "$(UI_ASSUME_TTY=1 ui_ok done)"      "[style] ✓ done"   "ok styled via gum"
assert_contains "$(UI_ASSUME_TTY=1 ui_err broken 2>&1)" "[style] ✗ broken" "err styled via gum"
assert_contains "$(UI_ASSUME_TTY=1 ui_header T)"     "[style] T"        "header styled via gum"

# --- zero ANSI bytes in plain mode ---------------------------------------
out="$(ui_header T; ui_ok a; ui_warn b 2>&1; ui_err c 2>&1)"
printf '%s' "$out" | grep -q "$(printf '\033')"
assert_status "$?" "1" "plain mode emits zero ANSI bytes"

finish
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bash tests/ui_test.sh`
Expected: error — `src/helper/ui: No such file or directory` (the source line fails)

- [ ] **Step 5: Create `src/helper/ui` (core)**

```bash
#!/usr/bin/env bash
# ui — gum-backed uniform terminal UI library. The ONLY place gum is invoked.
# Source AFTER helper/functions (needs lprint). Rendering degrades by context:
#   syslog: DAEMONIZED=1                           -> lprint only, never styled
#   plain:  no TTY / NO_COLOR / TERM=dumb / no gum -> plain text, zero ANSI bytes
#   styled: TTY + gum                              -> gum rendering, widgets allowed
# Wording is identical across contexts; only the prefix glyphs differ
# (styled ✓/!/✗ vs plain OK:/WARN:/ERROR:) so docs can quote one canonical text.
# Test overrides: UI_GUM (gum path), UI_ASSUME_TTY=1 (treat stdin+stdout as TTY).

UI_GUM="${UI_GUM:-${SNAP:-}/bin/gum}"

ui_ctx() {                     # -> syslog | plain | styled
    if [ "${DAEMONIZED:-0}" -eq 1 ]; then echo syslog; return; fi
    if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ]; then echo plain; return; fi
    if [ "${UI_ASSUME_TTY:-0}" -ne 1 ] && [ ! -t 1 ]; then echo plain; return; fi
    if [ ! -x "$UI_GUM" ]; then echo plain; return; fi
    echo styled
}

ui_interactive() {             # widgets additionally need stdin to be a terminal
    [ "$(ui_ctx)" = styled ] && { [ "${UI_ASSUME_TTY:-0}" -eq 1 ] || [ -t 0 ]; }
}

ui_print() {                   # one plain line, routed per context
    if [ "$(ui_ctx)" = syslog ]; then lprint "$*"; else printf '%s\n' "$*"; fi
}

ui_header() {                  # $1 title, $2 optional subtitle
    local text="$1${2:+ · $2}"
    case "$(ui_ctx)" in
        styled) "$UI_GUM" style --border rounded --padding "0 2" --border-foreground 6 "$text" ;;
        *)      ui_print "== $text ==" ;;
    esac
}

ui_ok() {
    case "$(ui_ctx)" in
        styled) "$UI_GUM" style --foreground 2 "✓ $*" ;;
        *)      ui_print "OK: $*" ;;
    esac
}

ui_warn() {
    case "$(ui_ctx)" in
        styled) "$UI_GUM" style --foreground 3 "! $*" >&2 ;;
        *)      ui_print "WARN: $*" >&2 ;;
    esac
}

ui_err() {
    case "$(ui_ctx)" in
        styled) "$UI_GUM" style --foreground 1 "✗ $*" >&2 ;;
        *)      ui_print "ERROR: $*" >&2 ;;
    esac
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/ui_test.sh`
Expected: `... passed, 0 failed` (about 20 assertions)

- [ ] **Step 7: Make CI run every test file**

In `.github/workflows/lint-test.yml`, replace:

```yaml
      - name: Unit tests
        run: |
          bash tests/logs_test.sh
          bash tests/backup_test.sh
```

with:

```yaml
      - name: Unit tests
        run: |
          for t in tests/*_test.sh; do
            echo "== $t"
            bash "$t" || exit 1
          done
```

- [ ] **Step 8: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/ui tests/ui_test.sh`
Expected: no output

```bash
git add src/helper/ui tests/ui_test.sh tests/fixtures/bin/gum tests/fixtures/helper/ui .github/workflows/lint-test.yml
git commit -m "feat(ui): gum-backed UI library core — context resolution + status output"
```

---

### Task 3: ui library — tables and usage rendering

**Files:**
- Modify: `src/helper/ui` (append)
- Modify: `tests/ui_test.sh` (append before `finish`)

- [ ] **Step 1: Write the failing tests**

In `tests/ui_test.sh`, insert before the final `finish` line:

```bash
# --- ui_align / ui_table / ui_kv -----------------------------------------
assert_eq "$(printf 'a\tbb\nccc\td\n' | ui_align)" "$(printf 'a    bb\nccc  d')" "align pads columns"

out="$(printf 'k1\tv1\nk2\tv2\n' | ui_table key value)"
assert_contains "$out" "key"   "table plain: header row"
assert_contains "$out" "k2"    "table plain: data row"
printf '%s' "$out" | grep -q "$(printf '\033')"
assert_status "$?" "1" "table plain: zero ANSI"

assert_contains "$(printf 'k\tv\n' | UI_ASSUME_TTY=1 ui_table key value)" "[table]" "table styled via gum"

out="$(ui_kv alpha 1 beta 2)"
assert_contains "$out" "alpha" "kv: first key"
assert_contains "$out" "2"     "kv: last value"

# --- ui_usage --------------------------------------------------------------
assert_eq "$(printf 'Usage: x\n' | ui_usage)" "Usage: x" "usage plain: cat"
assert_contains "$(printf 'Usage: x\n' | UI_ASSUME_TTY=1 ui_usage)" "[format] Usage: x" "usage styled via gum format"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/ui_test.sh`
Expected: FAIL / `command not found` for `ui_align`, `ui_table`, `ui_kv`, `ui_usage`

- [ ] **Step 3: Append the implementations to `src/helper/ui`**

```bash
ui_align() {                   # stdin: TAB-separated rows -> two-space aligned columns (pure)
    awk -F'\t' '
        { for (i=1; i<=NF; i++) { if (length($i) > w[i]) w[i] = length($i); c[NR,i] = $i } n[NR] = NF }
        END { for (r=1; r<=NR; r++) { line = ""
                for (i=1; i<=n[r]; i++) line = line sprintf("%-*s", (i < n[r] ? w[i]+2 : 0), c[r,i])
                sub(/[ \t]+$/, "", line); print line } }'
}

ui_table() {                   # stdin: TAB-separated rows; args: optional column headers
    local cols
    case "$(ui_ctx)" in
        styled)
            if [ "$#" -gt 0 ]; then
                cols="$(IFS=,; printf '%s' "$*")"
                "$UI_GUM" table --print --separator "$(printf '\t')" --columns "$cols"
            else
                "$UI_GUM" table --print --separator "$(printf '\t')"
            fi ;;
        *)
            {
                if [ "$#" -gt 0 ]; then local IFS=$'\t'; printf '%s\n' "$*"; fi
                cat
            } | ui_align ;;
    esac
}

ui_kv() {                      # args: key value [key value]... -> 2-column table
    local out="" k v
    while [ "$#" -ge 2 ]; do k="$1"; v="$2"; shift 2; out+="${k}"$'\t'"${v}"$'\n'; done
    printf '%s' "$out" | ui_table
}

ui_usage() {                   # stdin: usage text (readable raw; light markdown when styled)
    case "$(ui_ctx)" in
        styled) "$UI_GUM" format ;;
        *)      cat ;;
    esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/ui_test.sh`
Expected: `... passed, 0 failed`

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/ui tests/ui_test.sh`
Expected: no output

```bash
git add src/helper/ui tests/ui_test.sh
git commit -m "feat(ui): tables, key-value rendering and usage formatting"
```

---

### Task 4: ui library — interactive widgets

**Files:**
- Modify: `src/helper/ui` (append)
- Modify: `tests/ui_test.sh` (append before `finish`)

- [ ] **Step 1: Write the failing tests**

In `tests/ui_test.sh`, insert before `finish`:

```bash
# --- ui_choose --------------------------------------------------------------
export GUM_CHOOSE=zui      # exported: the stub gum runs as a child process
sel="$(UI_ASSUME_TTY=1 ui_choose 'Follow which logs?' 'pass a stream' all zui zwjs)"
assert_eq "$sel" "zui" "choose returns gum selection"
assert_contains "$(tail -1 "$GUM_LOG")" "choose --header Follow which logs? all zui zwjs" "choose argv recorded"

ui_choose 'P' 'pass a stream: x.logs zui' a b >/dev/null 2>&1
assert_status "$?" "2" "choose without TTY -> exit 2"
assert_contains "$(ui_choose 'P' 'pass a stream: x.logs zui' a b 2>&1 >/dev/null)" "pass a stream: x.logs zui" "choose no-TTY hint"

# --- ui_input ----------------------------------------------------------------
export GUM_INPUT=Joachim   # exported: the stub gum runs as a child process
assert_eq "$(UI_ASSUME_TTY=1 ui_input 'Real name')" "Joachim" "input via gum"
assert_eq "$(printf 'piped-val\n' | ui_input 'Real name')" "piped-val" "input reads piped stdin without TTY"
assert_eq "$(printf 'sec\n' | ui_input --password 'Passphrase')" "sec" "password input reads piped stdin"

# --- ui_confirm ----------------------------------------------------------------
GUM_CONFIRM=0 UI_ASSUME_TTY=1 ui_confirm 'Sure?'; assert_status "$?" "0" "confirm yes via gum"
GUM_CONFIRM=1 UI_ASSUME_TTY=1 ui_confirm 'Sure?'; assert_status "$?" "1" "confirm no via gum"
printf 'y\n' | ui_confirm 'Sure?'; assert_status "$?" "0" "piped y -> yes"
printf 'nah\n' | ui_confirm 'Sure?'; assert_status "$?" "1" "piped other -> no"
ui_confirm 'Sure?' < /dev/null; assert_status "$?" "1" "EOF stdin -> no (safe default)"

# --- ui_spin ----------------------------------------------------------------
out="$(ui_spin 'Working…' echo ran)"
assert_contains "$out" "Working…" "spin plain prints title"
assert_contains "$out" "ran"      "spin plain runs command"
assert_eq "$(UI_ASSUME_TTY=1 ui_spin 'W' echo ran)" "ran" "spin styled execs via stub"
ui_spin 'W' false; assert_status "$?" "1" "spin propagates command status"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/ui_test.sh`
Expected: FAIL / `command not found` for `ui_choose`, `ui_input`, `ui_confirm`, `ui_spin`

- [ ] **Step 3: Append the implementations to `src/helper/ui`**

```bash
ui_choose() {                  # $1 prompt, $2 no-TTY hint, $3.. items -> echoes selection; 2 if not interactive
    local prompt="$1" hint="$2"; shift 2
    if ui_interactive; then
        "$UI_GUM" choose --header "$prompt" "$@"
    else
        ui_err "no TTY — $hint"
        return 2
    fi
}

ui_input() {                   # [--password] $1 prompt -> echoes value; piped stdin honored; 2 if nothing to read
    local pw=()
    if [ "${1:-}" = "--password" ]; then pw=(--password); shift; fi
    if ui_interactive; then
        "$UI_GUM" input "${pw[@]}" --header "$1"
    elif [ ! -t 0 ]; then
        local v; IFS= read -r v || return 2
        printf '%s\n' "$v"
    else
        return 2
    fi
}

ui_confirm() {                 # $1 question -> 0 yes / 1 no / 2 cannot ask. Default is NO everywhere.
    if ui_interactive; then
        "$UI_GUM" confirm --default=false "$1"
    elif [ ! -t 0 ]; then
        local a; IFS= read -r a || a=""
        case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
    else
        return 2
    fi
}

ui_spin() {                    # $1 title, rest: command — spinner when styled, plain title otherwise
    local title="$1"; shift
    if [ "$(ui_ctx)" = styled ]; then
        "$UI_GUM" spin --spinner dot --title "$title" --show-output -- "$@"
    else
        ui_print "$title"
        "$@"
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/ui_test.sh`
Expected: `... passed, 0 failed`

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/ui tests/ui_test.sh`
Expected: no output

```bash
git add src/helper/ui tests/ui_test.sh
git commit -m "feat(ui): interactive widgets (choose/input/confirm/spin) with non-TTY fallbacks"
```

---

### Task 5: settings catalog + new `help` command

**Files:**
- Create: `src/helper/catalog`
- Create: `src/bin/help`
- Create: `tests/help_test.sh`
- Create: `tests/fixtures/helper/catalog` (shim like the ui one)
- Create: `tests/fixtures/meta/snap.yaml`
- Modify: `src/helper/env-wrapper` (delete the `--help` branch)
- Modify: `snap/snapcraft.yaml` (`help` app command)

- [ ] **Step 1: Create the fixtures**

`tests/fixtures/meta/snap.yaml`:

```yaml
version: v0.0.0-test
```

`tests/fixtures/helper/catalog`:

```bash
#!/usr/bin/env bash
# Test shim: load the REAL catalog from src/ (see helper/ui shim).
source "$(dirname "${BASH_SOURCE[0]}")/../../../src/helper/catalog"
```

- [ ] **Step 2: Write the failing tests**

Create `tests/help_test.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT

# snapctl stub: `snapctl get k` reads $SNAPCTL_<k with . and - as _>; `services` is canned.
snapctl() {
    case "$1" in
        get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
        services) printf 'Service  Startup  Current  Notes\nzwave-js-ui.zwave-js-ui  enabled  active  -\n' ;;
        *) : ;;
    esac
}

# shellcheck source=/dev/null
source "$ROOT/src/bin/help"     # sources stub functions + real ui/catalog via $SNAP shims

# --- catalog -----------------------------------------------------------------
assert_contains "$(catalog_keys)" "server.port"   "catalog has server.port"
assert_contains "$(catalog_keys)" "backup.target" "catalog has backup.target"
settings_catalog | awk -F'\t' 'NF != 4 { exit 1 }'
assert_status "$?" "0" "every catalog row has exactly 4 fields"

# --- help helpers --------------------------------------------------------------
assert_eq "$(snap_version)" "v0.0.0-test" "version from meta/snap.yaml"
assert_eq "$(service_state)" "enabled active" "service state parsed"

SNAPCTL_server_host="10.0.0.7"
assert_contains "$(settings_rows)" "$(printf 'server.host\t10.0.0.7')" "row shows current value"
SNAPCTL_session_secret="topsecret"
rows="$(settings_rows)"
assert_contains "$rows" "(hidden)" "session.secret is masked"
case "$rows" in *topsecret*) FAIL=$((FAIL+1)); echo "FAIL: secret leaked" >&2 ;; *) PASS=$((PASS+1)) ;; esac
assert_contains "$(SNAPCTL_server_port='' settings_rows)" "(unset)" "unset value rendered as (unset)"

# --- main renders (plain ctx) ---------------------------------------------------
out="$(plugs_connected() { :; }; main)"
assert_contains "$out" "== zwave-js-ui · v0.0.0-test · enabled active ==" "header line"
assert_contains "$out" "server.host" "settings table present"
assert_contains "$out" "snap set zwave-js-ui" "set-hint present"
assert_contains "$out" "zwave-js-ui.logs" "commands table present"
assert_contains "$out" "serial-port" "serial footnote present"

finish
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/help_test.sh`
Expected: error — `src/bin/help: No such file or directory`

- [ ] **Step 4: Create `src/helper/catalog`**

```bash
#!/usr/bin/env bash
# catalog — single source of truth for user-settable snap config.
# TAB-separated rows: key, type, default, description. Drives the help settings
# table now and the phase-2 navigator later. Defaults must stay in sync with
# test_default_config (helper/functions) and the backup defaults (bin/backup).
settings_catalog() {
    cat <<'EOF'
server.host	string	0.0.0.0	IP address the web UI binds to
server.port	int	8091	Port for the web UI
server.ssl	bool	false	Serve the web UI over HTTPS
server.force-disable-ssl	bool	false	Force-disable SSL even when enabled
session.secret	string	(generated)	Session secret (a UUID is generated on install)
session.cookie-secure	bool	(= server.ssl)	Secure session cookie (see expressjs/session#cookiesecure)
mqtt.name	string	(empty)	Client name when connecting to the MQTT broker
timezone	string	Europe/Oslo	Timezone exported to the app as TZ
backup.target	string	(unset)	Duplicity target URL for off-box backups
backup.dir	string	$SNAP_DATA/backups	Directory shipped by the backup command
backup.encrypt	bool	(unset)	Set false to opt out of backup encryption
backup.encrypt-key	string	(unset)	GPG fingerprint backups are encrypted to
backup.full-if-older-than	string	7D	Force a full backup after this age
backup.retention	int	3	Full backup chains kept on the target
EOF
}

catalog_keys() { settings_catalog | cut -f1; }
```

- [ ] **Step 5: Create `src/bin/help`**

```bash
#!/usr/bin/env bash
# help — uniform overview: status, settings, commands. Replaces env-wrapper --help.
: "${SNAP:?SNAP must be set}"
source "$SNAP/helper/functions"
source "$SNAP/helper/ui"
source "$SNAP/helper/catalog"

snap_version() { yq eval '.version' "$SNAP/meta/snap.yaml"; }

service_state() {              # "enabled active", "disabled inactive", or "unknown"
    local line
    line="$(snapctl services "$SNAP_NAME.$SNAP_NAME" 2>/dev/null | awk 'NR==2 { print $2 " " $3 }')"
    echo "${line:-unknown}"
}

settings_rows() {              # catalog + live values -> TSV: key, value, default, description
    local key type def desc cur
    while IFS=$'\t' read -r key type def desc; do
        cur="$(snapctl get "$key" 2>/dev/null)"
        [ "$key" = "session.secret" ] && [ -n "$cur" ] && cur="(hidden)"
        printf '%s\t%s\t%s\t%s\n' "$key" "${cur:-(unset)}" "$def" "$desc"
    done < <(settings_catalog)
}

commands_rows() {
    printf '%s\n' \
        "$SNAP_NAME.enable	daemonize the service (autostart)" \
        "$SNAP_NAME.disable	stop + de-daemonize the service" \
        "$SNAP_NAME.restart	restart the service" \
        "$SNAP_NAME.exec	run the app in the foreground (debug boot issues)" \
        "$SNAP_NAME.logs [zui|zwjs]	follow live logs (merged by default)" \
        "$SNAP_NAME.backup …	ship backups off-box; see $SNAP_NAME.backup --help" \
        "$SNAP_NAME.help	this overview"
}

main() {
    plugs_connected || ui_warn "Required interfaces are not connected — see the commands above."
    ui_header "$SNAP_NAME" "$(snap_version) · $(service_state)"
    echo
    ui_print "The daemon is DISABLED by default after install. Enable it with:"
    ui_print "  sudo $SNAP_NAME.enable"
    echo
    settings_rows | ui_table "setting" "value" "default" "description"
    echo
    ui_print "Set options with:  sudo snap set $SNAP_NAME <key>=<value>"
    ui_print "Other settings live in the web UI after start."
    echo
    commands_rows | ui_table "command" "description"
    echo
    ui_print "serial-port plug (needs snapd's experimental hotplug):"
    ui_print "  sudo snap set system experimental.hotplug=true && sudo systemctl restart snapd"
    ui_print "  sudo snap interface serial-port            # list available slots"
    ui_print "  sudo snap connect $SNAP_NAME:serial-port <slot name>"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

Run: `chmod +x src/bin/help`

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/help_test.sh`
Expected: `... passed, 0 failed`

- [ ] **Step 7: Point the `help` app at the new script and strip env-wrapper**

In `snap/snapcraft.yaml`, change:

```yaml
  help:
    command: helper/env-wrapper --help
```

to:

```yaml
  help:
    command: bin/help
```

In `src/helper/env-wrapper`, delete lines 5–71 (the whole `OPT_HELP` block: from `OPT_HELP=false` through the `exit 0` and closing `fi` of `if [ "${OPT_HELP}" = true ]; then`). The file then starts:

```bash
#!/usr/bin/env bash

source $SNAP/helper/functions

require_root

plugs_connected || exit 1
```

(everything from `require_root` down is unchanged).

- [ ] **Step 8: Verify, shellcheck, run all tests**

Run: `yq eval '.apps.help.command' snap/snapcraft.yaml`
Expected: `bin/help`

Run: `shellcheck --severity=warning -x src/bin/help src/helper/catalog src/helper/env-wrapper tests/help_test.sh && for t in tests/*_test.sh; do bash "$t" || exit 1; done`
Expected: shellcheck silent; every test file ends `... passed, 0 failed`

- [ ] **Step 9: Commit**

```bash
git add src/helper/catalog src/bin/help src/helper/env-wrapper snap/snapcraft.yaml tests/help_test.sh tests/fixtures/helper/catalog tests/fixtures/meta/snap.yaml
git commit -m "feat(help): settings-catalog-driven help command; slim env-wrapper to env translation"
```

---

### Task 6: restyle enable / disable / restart

**Files:**
- Modify: `src/bin/daemonize` (rewrite)
- Modify: `src/bin/de-daemonize` (rewrite)
- Modify: `src/bin/restart` (rewrite)
- Create: `tests/service_cmds_test.sh`

- [ ] **Step 1: Write the failing tests**

Create `tests/service_cmds_test.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"

# Sourcing must be side-effect free (main guarded) and define main().
for s in daemonize de-daemonize restart; do
    out="$(bash -c "export SNAP='$SNAP'; source '$ROOT/src/bin/$s' && declare -F main >/dev/null && echo guarded")"
    assert_eq "$out" "guarded" "$s: source is silent and defines main"
done

# daemonize happy path (stubs: plugs ok, snapctl ok) — plain ctx in CI.
out="$(
    source "$ROOT/src/bin/daemonize"
    plugs_connected() { :; }
    snapctl() { :; }
    main
)"
assert_contains "$out" "OK: Service enabled" "daemonize: success message"
assert_contains "$out" "sudo zwave-js-ui.logs" "daemonize: next-steps table"

# daemonize failure path: plugs missing.
(
    source "$ROOT/src/bin/daemonize"
    plugs_connected() { return 1; }
    snapctl() { :; }
    main
) >/dev/null 2>&1
assert_status "$?" "1" "daemonize: missing plugs -> exit 1"

# de-daemonize happy path.
out="$(
    source "$ROOT/src/bin/de-daemonize"
    snapctl() { :; }
    main
)"
assert_contains "$out" "OK: Service disabled" "de-daemonize: success message"

# restart: spinner title + success in plain ctx.
out="$(
    source "$ROOT/src/bin/restart"
    plugs_connected() { :; }
    snapctl() { :; }
    main
)"
assert_contains "$out" "Restarting zwave-js-ui" "restart: announces"
assert_contains "$out" "OK: Service restarted" "restart: success message"

# restart failure propagates.
(
    source "$ROOT/src/bin/restart"
    plugs_connected() { :; }
    snapctl() { return 1; }
    main
) >/dev/null 2>&1
assert_status "$?" "1" "restart: snapctl failure -> exit 1"

finish
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/service_cmds_test.sh`
Expected: FAILs — current scripts execute on source (no main guard), so the "guarded" assertions fail

- [ ] **Step 3: Rewrite `src/bin/daemonize`**

```bash
#!/usr/bin/env bash
# daemonize — enable + start the service (zwave-js-ui.enable)
: "${SNAP:?SNAP must be set}"
source "$SNAP/helper/functions"
source "$SNAP/helper/ui"

main() {
    require_root
    if ! plugs_connected; then
        ui_err "Cannot enable the $SNAP_NAME service — required interfaces are missing (see above)."
        ui_print "Connect them, then verify the app boots with: sudo $SNAP_NAME.exec"
        ui_print "More info: $SNAP_NAME.help"
        return 1
    fi
    if ui_spin "Enabling $SNAP_NAME service…" snapctl start --enable "$SNAP_NAME.$SNAP_NAME"; then
        ui_ok "Service enabled"
        printf '%s\n' \
            "follow all logs	sudo $SNAP_NAME.logs" \
            "app log only	sudo $SNAP_NAME.logs zui" \
            "driver log only	sudo $SNAP_NAME.logs zwjs" | ui_table
        return 0
    fi
    ui_err "Failed enabling service"
    return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

(Note: the next-steps rows embed real TAB characters between the columns.)

- [ ] **Step 4: Rewrite `src/bin/de-daemonize`**

```bash
#!/usr/bin/env bash
# de-daemonize — stop + disable the service (zwave-js-ui.disable)
: "${SNAP:?SNAP must be set}"
source "$SNAP/helper/functions"
source "$SNAP/helper/ui"

main() {
    require_root
    if ui_spin "Disabling $SNAP_NAME service…" snapctl stop --disable "$SNAP_NAME.$SNAP_NAME"; then
        ui_ok "Service disabled"
        return 0
    fi
    ui_err "Failed disabling $SNAP_NAME service"
    return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

- [ ] **Step 5: Rewrite `src/bin/restart`**

```bash
#!/usr/bin/env bash
# restart — restart the service (zwave-js-ui.restart)
: "${SNAP:?SNAP must be set}"
source "$SNAP/helper/functions"
source "$SNAP/helper/ui"

main() {
    require_root
    plugs_connected || return 1
    if ui_spin "Restarting $SNAP_NAME…" snapctl restart "$SNAP_NAME.$SNAP_NAME"; then
        ui_ok "Service restarted"
        return 0
    fi
    ui_err "Failed restarting service"
    return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/service_cmds_test.sh`
Expected: `... passed, 0 failed`

- [ ] **Step 7: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/daemonize src/bin/de-daemonize src/bin/restart tests/service_cmds_test.sh`
Expected: no output

```bash
git add src/bin/daemonize src/bin/de-daemonize src/bin/restart tests/service_cmds_test.sh
git commit -m "feat(service-cmds): uniform ui output for enable/disable/restart"
```

---

### Task 7: logs — styled usage + interactive stream picker

**Files:**
- Modify: `src/bin/logs`
- Modify: `tests/logs_test.sh` (append before `finish`)

- [ ] **Step 1: Write the failing tests**

In `tests/logs_test.sh`, insert before `finish`:

```bash
# sel_to_target maps the interactive picker's labels onto follower targets
assert_eq "$(sel_to_target all)"  "both" "picker: all -> both"
assert_eq "$(sel_to_target zui)"  "zui"  "picker: zui"
assert_eq "$(sel_to_target zwjs)" "zwjs" "picker: zwjs"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/logs_test.sh`
Expected: FAIL — `sel_to_target: command not found`

- [ ] **Step 3: Wire the ui library into `src/bin/logs`**

After the existing `source "$SNAP/helper/functions"` line add:

```bash
source "$SNAP/helper/ui"
```

Replace the `usage()` function with (same wording, rendered via `ui_usage`):

```bash
usage() {
    ui_usage <<EOF
Usage: ${SNAP_NAME}.logs [zui|--zui|zwjs|--zwjs]

  (no arg)        follow both streams, merged (interactive terminals get a picker)
  zui  | --zui    follow the Z-Wave JS UI application log only
  zwjs | --zwjs   follow the Z-Wave JS driver log only
  -h   | --help   show this help
EOF
}
```

Next to `normalize_target()`, add:

```bash
sel_to_target() {              # picker label -> follower target
    case "$1" in all) echo both ;; *) normalize_target "$1" ;; esac
}
```

In `main()`, replace:

```bash
    local target; target="$(parse_args "$@")" || { usage >&2; exit 2; }
```

with:

```bash
    local target
    if [ "$#" -eq 0 ] && ui_interactive; then
        local sel
        sel="$(ui_choose 'Follow which logs?' "pass a stream: ${SNAP_NAME}.logs [zui|zwjs]" all zui zwjs)" || exit 2
        target="$(sel_to_target "$sel")"
    else
        target="$(parse_args "$@")" || { usage >&2; exit 2; }
    fi
```

(Non-TTY no-arg runs never reach `ui_choose` — `ui_interactive` is false, so `parse_args` keeps today's merged-both default and `sudo zwave-js-ui.logs | grep …` is unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/logs_test.sh`
Expected: `... passed, 0 failed` (existing assertions plus the three new ones)

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/logs tests/logs_test.sh`
Expected: no output

```bash
git add src/bin/logs tests/logs_test.sh
git commit -m "feat(logs): styled usage + interactive stream picker on TTY"
```

---

### Task 8: backup — humanized status/list + uniform messages

**Files:**
- Modify: `src/bin/backup`
- Modify: `tests/backup_test.sh` (append before `finish`)

- [ ] **Step 1: Write the failing tests**

In `tests/backup_test.sh`, insert before `finish`:

```bash
# parse_collection_status: duplicity output -> TSV rows (awk collapses runs of spaces)
raw=' Type of backup set:                            Time:      Num volumes:
                Full         Mon Jun  9 00:00:01 2026                 2
         Incremental         Tue Jun 10 00:00:01 2026                 1'
assert_eq "$(printf '%s\n' "$raw" | parse_collection_status)" \
    "$(printf 'Full\tMon Jun 9 00:00:01 2026\t2\nIncremental\tTue Jun 10 00:00:01 2026\t1')" \
    "collection-status rows parsed"
assert_eq "$(printf 'No backup chains found\n' | parse_collection_status)" "" "no sets -> empty"

# cmd_status renders a table (plain ctx in CI); gpg absent -> private key "no"
out="$(SNAPCTL_backup_target="sftp://nas/zui" GNUPGHOME="$SNAP_COMMON/.gnupg" cmd_status)"
assert_contains "$out" "target" "status: target row"
assert_contains "$out" "sftp://nas/zui" "status: target value"
assert_contains "$out" "(unset)" "status: unset encrypt-key"
assert_contains "$out" "$SNAP_DATA/backups" "status: dir row"
assert_contains "$out" "3" "status: default retention"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/backup_test.sh`
Expected: FAIL — `parse_collection_status: command not found`, `cmd_status: command not found`

- [ ] **Step 3: Wire ui into `src/bin/backup` and add the new helpers**

After the existing `source "$SNAP/helper/functions"` line add:

```bash
source "$SNAP/helper/ui"
```

Add next to the other pure helpers (e.g. after `first_fpr`):

```bash
# Reads `duplicity collection-status` on stdin, emits one "Type<TAB>date<TAB>volumes"
# line per backup set. awk's field splitting collapses runs of spaces in the date.
# Pure: stdin -> stdout, unit-tested.
parse_collection_status() {
    awk '
        /^[[:space:]]+(Full|Incremental)[[:space:]]/ {
            type = $1; vol = $NF; date = ""
            for (i = 2; i < NF; i++) date = date (date == "" ? "" : " ") $i
            print type "\t" date "\t" vol
        }'
}

cmd_status() {                 # render current backup config as a table
    local target key onbox="no" retention timer
    target="$(cfg target)"
    key="$(cfg encrypt-key)"
    if [ -n "$key" ] && gpg --no-autostart --homedir "$GNUPGHOME" --list-secret-keys "$key" >/dev/null 2>&1; then
        onbox="yes"
    fi
    retention="$(cfg retention)"
    timer="$(snapctl services "$SNAP_NAME.backup-timer" 2>/dev/null | awk 'NR==2 { print $3 }')"
    ui_kv \
        "target"                     "${target:-(unset)}" \
        "dir"                        "$(backup_dir)" \
        "encrypt-key"                "${key:-(unset)}" \
        "private key on this device" "$onbox" \
        "retention (full chains)"    "${retention:-3}" \
        "full backup if older than"  "$(full_if_older)" \
        "timer"                      "${timer:-unknown} (daily @ 00:00)"
}
```

- [ ] **Step 4: Switch the `status` and `list` cases over**

In `main()`'s `case "$sub" in`, replace:

```bash
        status)
            lprint "target=$(cfg target) dir=$(backup_dir) encrypt-key=$(cfg encrypt-key)"
            ;;
```

with:

```bash
        status) cmd_status ;;
```

and replace:

```bash
        list)
            [ -n "$target" ] || { lprint "backup.target not set." >&2; exit 1; }
            if ! encryption_args >/dev/null 2>&1; then
                lprint "Set 'backup.encrypt-key=<gpg-fpr>' or opt out with 'backup.encrypt=false'." >&2
                exit 1
            fi
            # shellcheck disable=SC2294
            eval "$(build_list_cmd)"
            ;;
```

with:

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

- [ ] **Step 5: Convert the remaining user messages to ui calls**

Throughout `src/bin/backup`, apply these mechanical conversions (wording unchanged unless noted; the `DAEMONIZED=1` timer path automatically degrades to `lprint` via `ui_ctx`):

- Error messages currently `lprint "…" >&2` followed by failure/exit → `ui_err "…"` (drop the explicit `>&2`; `ui_err` writes stderr itself). This covers: the `backup`/`restore` unconfigured-target and missing-encryption messages, "Backup failed…", "Restore failed…", "Key import failed…", `cmd_pick_key`'s root-refusal and missing-keyring errors, `ensure_agent`'s socket error, `cmd_create_key`'s validation/generation errors, and `cmd_export_key`'s not-set/export-failed errors.
- Informational notes (`"Nothing to back up…"`, `"Restoring into …"`, `"Done. Now use ZUI's in-app restore…"`, pick-key's listing hint, export-key's host-import instructions, create-key's "private key lives ONLY in this snap" note) → `ui_print "…" >&2` (keep stderr so stdout stays machine-clean for pipes).
- Success confirmations (`"Imported … and set backup.encrypt-key=…"`, `"Created … and set backup.encrypt-key=…"`, "Private key deleted…", "Kept the private key…") → `ui_ok "…"` (stdout is fine here; import-key/create-key emit nothing else on stdout).
- In `cmd_create_key`, replace the interactive prompts:

```bash
        read -rp "Real name: " name
        read -rp "Email: " email
        read -rp "Comment (optional): " comment
```

with:

```bash
        name="$(ui_input 'Real name')" || { ui_err "Cannot prompt without a terminal — pass name/email as arguments."; return 1; }
        email="$(ui_input 'Email')" || { ui_err "Cannot prompt without a terminal — pass name/email as arguments."; return 1; }
        comment="$(ui_input 'Comment (optional)')" || comment=""
```

and replace:

```bash
    read -rsp "Passphrase for the new private key: " pass; echo >&2
```

with:

```bash
    pass="$(ui_input --password 'Passphrase for the new private key')" || { ui_err "Cannot prompt for a passphrase without a terminal."; return 1; }
```

- In `cmd_export_key`, replace:

```bash
    local ans
    read -rp "Delete the private key from THIS device now? [y/N] " ans
    case "${ans:-N}" in
        y|Y|yes|YES)
```

with:

```bash
    ui_confirm "Delete the private key from THIS device now?"
    case "$?" in
        0)
```

and change the final `*)` branch's message call to `ui_print "Kept the private key in the snap keyring." >&2` (statuses 1 *and* 2 — "no" and "cannot ask" — both safely keep the key).

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/backup_test.sh`
Expected: `... passed, 0 failed` (existing assertions plus the new ones)

- [ ] **Step 7: Shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/backup tests/backup_test.sh`
Expected: no output

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "feat(backup): humanized status/list tables + uniform ui messages"
```

---

### Task 9: full verification + docs

**Files:**
- Modify: `CLAUDE.md` (architecture notes)

- [ ] **Step 1: Run the complete check suite**

```bash
shellcheck --severity=warning -x src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh
for t in tests/*_test.sh; do echo "== $t"; bash "$t" || exit 1; done
```

Expected: shellcheck silent; all five test files end `... passed, 0 failed`.

- [ ] **Step 2: Update CLAUDE.md**

In the "Config translation layer" section, after the `src/helper/functions` bullet, add:

```markdown
- `src/helper/ui` is the gum-backed UI library — the ONLY place gum is invoked. Every `ui_*` call resolves a context: `syslog` (`DAEMONIZED=1` → `lprint`), `plain` (no TTY / `NO_COLOR` / `TERM=dumb` / no gum → zero ANSI), or `styled` (TTY + gum). Interactive widgets (`ui_choose`/`ui_input`/`ui_confirm`) exit 2 without a TTY — commands always keep an argument-driven path. `src/helper/catalog` is the settings catalog (key/type/default/description) driving the `help` settings table. gum is built from a pinned tag by the `gum` part in `snapcraft.yaml` (Renovate tracks it).
```

In the "User commands" section, update the first sentence to mention that `help` lives in `src/bin/help` (no longer `env-wrapper --help`) and that all bin commands render through `src/helper/ui`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the ui library and settings catalog in CLAUDE.md"
```

- [ ] **Step 4: Push and open the PR (snap build verification happens in CI)**

The gum part and the restyled commands can only be exercised end-to-end by an installed snap. The PR build (`pr-build-snap.yml`) builds all three arches via Launchpad and publishes to the per-PR channel — install from there and manually spot-check:

```bash
git push -u origin feat/cli-ui
gh pr create --title "feat: uniform gum-based CLI UI (phase 1)" --body "Implements phase 1 of docs/superpowers/specs/2026-06-11-cli-ui-design.md: gum part, src/helper/ui library, restyled help/enable/disable/restart/logs/backup. Phase 2 (interactive navigator) follows separately."
```

Manual smoke checks on a device once the PR channel build lands (record results in the PR):

```bash
sudo snap refresh zwave-js-ui --channel=v<MM>/edge/<PR#>
zwave-js-ui.help                          # styled header + settings table on a TTY
zwave-js-ui.help | cat                    # plain text, zero ANSI
sudo zwave-js-ui.logs                     # interactive picker appears on a TTY
sudo zwave-js-ui.logs zui                 # argument path unchanged
sudo zwave-js-ui.backup status            # table render
sudo zwave-js-ui.backup --help            # styled usage
```

---

## Spec coverage map (self-review)

| Spec item (phase 1) | Task |
|---|---|
| gum part, pinned tag, Renovate | 1 |
| `ui` library: context matrix, status/table/usage, widgets, exit-2 rule | 2–4 |
| help → `src/bin/help`, env-wrapper slimmed, settings table, catalog | 5 |
| enable/disable plug-failure `ui_err` + next-steps; restart spinner | 6 |
| logs: `ui_usage` + interactive no-arg picker, non-TTY default unchanged | 7 |
| backup: status table, list parser, message conversion, key-subcommand prompts, timer path plain | 8 |
| gum stub on PATH-equivalent (`UI_GUM` fixture), zero-ANSI assertions, existing tests keep passing | 2–8 |
| CI runs new tests; CLAUDE.md updated | 2, 9 |

Phase 2 items (navigator, nano staging, settings.json editing) are intentionally absent — separate plan.
