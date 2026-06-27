# CLI Navigator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interactive, root-only TUI app `zwave-js-ui.ui` that lets an operator browse and act on the snap's settings, service, plugs, and logs.

**Architecture:** A thin orchestrator (`src/bin/ui`) that sources the existing `helper/functions`, `helper/ui`, `helper/catalog`, runs a `ui_choose` menu loop, and per section *browses* via the existing catalog/`ui_*` widgets and *acts* by calling what already exists (`snapctl`, the service bins, `logs`, `help`). The `configure` hook stays the only config validator; the catalog stays the only settings source. No validation/settings/service logic is reimplemented.

**Tech Stack:** Bash; `gum` (via the `ui_*` chokepoint); `snapctl`; `yq`; the zero-dependency test harness in `tests/` (source-the-script, stub `gum`/`snapctl`, `script(1)` for PTY).

## Global Constraints

- App name is exactly `zwave-js-ui.ui`; bin is `src/bin/ui`; it is a **plain** app (NOT through `helper/env-wrapper`).
- **Root-only**: `main` calls `require_root` (which `exit 1`s non-root) before anything else.
- **No-TTY**: when `ui_interactive` is false, print a pointer to `$SNAP_NAME.help` on stderr and return 2 (never block).
- All user-facing output goes through `ui_*` (no raw `echo`/`gum`); interactive widgets are `ui_choose`/`ui_input`/`ui_confirm`, which already return 2 on no-TTY/Ctrl-C/abort.
- **Reuse, never duplicate**: settings come from `settings_catalog` (helper/catalog); config changes go through `snapctl set`/`unset` so the `configure` hook validates; service actions call the existing `daemonize`/`de-daemonize`/`restart` bins; logs/help call the existing `logs`/`help` bins.
- **No new stage-packages.** No raw text editor (`nano`) — `settings.json` editing is out of scope (Phase 2b).
- `$SNAP_NAME` is set by snapd at runtime and by the test harness; use it, never hardcode `zwave-js-ui`.
- Tests must pass under a normal env **and** `TERM=dumb` (CI parity); `shellcheck --severity=warning -x` clean.
- Spec: `docs/superpowers/specs/2026-06-28-cli-navigator-design.md`.

---

## File Structure

- **Create `src/bin/ui`** — the navigator: `main` loop + `nav_settings`/`nav_service`/`nav_plugs`/`nav_logs`/`nav_help` (+ small helpers). One focused file (~150 lines).
- **Modify `snap/snapcraft.yaml`** — add `apps.ui: { command: bin/ui }`.
- **Modify `src/helper/functions`** — move `snap_version`/`service_state` here from `bin/help` (both `help` and `ui` need them; DRY).
- **Modify `src/bin/help`** — drop its local `snap_version`/`service_state` (now in `functions`).
- **Modify `src/helper/catalog`** — add `catalog_row <key>` (the TSV row for one key).
- **Create `tests/ui_nav_test.sh`** — unit tests for the navigator.
- **Modify `tests/fixtures/bin/gum`** — queued `choose`/`input` responses so a menu *loop* can be driven.

---

## Task 1: Shell, app registration, shared helpers, gum-stub queue

**Files:**
- Create: `src/bin/ui`
- Modify: `snap/snapcraft.yaml` (apps block), `src/helper/functions`, `src/bin/help`, `tests/fixtures/bin/gum`
- Test: `tests/ui_nav_test.sh`

**Interfaces:**
- Consumes: `require_root` (functions, `exit 1` non-root), `ui_interactive` (ui, 0/1), `ui_header "$title" "$subtitle"` (ui), `ui_choose "$prompt" "$hint" item...` (ui → echoes selection; status 2 on no-TTY/Ctrl-C), `ui_warn`/`ui_print` (ui), `snapctl services`.
- Produces: `src/bin/ui` with `main`; `snap_version`/`service_state` now in `functions`; `catalog_row` (added Task 3); `nav_settings`/`nav_service`/`nav_plugs`/`nav_logs`/`nav_help` (stubbed here, real in Tasks 2-5). gum stub honors `GUM_CHOOSE_QUEUE`/`GUM_INPUT_QUEUE` (a file path; one line consumed per call; empty/missing → exit 130).

- [ ] **Step 1: Extend the gum stub for queued responses**

Modify `tests/fixtures/bin/gum` — replace the `choose)` and `input)` arms so a queue file (one response per line, consumed front-to-back; empty → abort) is used when set, else the existing single-value env:

```bash
#!/usr/bin/env bash
# Fake gum for unit tests: records argv to $GUM_LOG, emits canned results via GUM_* env.
[ -n "${GUM_LOG:-}" ] && printf '%s\n' "$*" >> "$GUM_LOG"
[ -n "${GUM_ABORT:-}" ] && exit 130
# Pop the next line from a queue file ($1); exit 130 (abort) when drained/missing.
_pop() {
    local q="$1" line
    { [ -n "$q" ] && [ -s "$q" ]; } || exit 130
    line="$(head -n1 "$q")"; tail -n +2 "$q" > "$q.r" && mv "$q.r" "$q"
    printf '%s\n' "$line"
}
cmd="${1:-}"; shift || true
case "$cmd" in
    choose)  if [ -n "${GUM_CHOOSE_QUEUE:-}" ]; then _pop "$GUM_CHOOSE_QUEUE"; else printf '%s\n' "${GUM_CHOOSE:?GUM_CHOOSE not set}"; fi ;;
    input)   if [ -n "${GUM_INPUT_QUEUE:-}" ];  then _pop "$GUM_INPUT_QUEUE";  else printf '%s\n' "${GUM_INPUT:?GUM_INPUT not set}"; fi ;;
    confirm) exit "${GUM_CONFIRM:-0}" ;;
    spin)    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift; "$@" ;;
    table)   sed 's/^/[table] /' ;;
    pager)   sed 's/^/[pager] /' ;;
    format)  sed 's/^/[format] /' ;;
    style)   printf '[style] %s\n' "${*: -1}" ;;
    *)       exit 64 ;;
esac
```

- [ ] **Step 2: Move `snap_version`/`service_state` into `functions`**

In `src/helper/functions`, add (near the other helpers):

```bash
snap_version() { yq eval '.version' "$SNAP/meta/snap.yaml"; }

service_state() {              # "enabled active", "disabled inactive", or "unknown"
    local line
    line="$(snapctl services "$SNAP_NAME.$SNAP_NAME" 2>/dev/null | awk 'NR==2 { print $2 " " $3 }')"
    echo "${line:-unknown}"
}
```

Then in `src/bin/help` **delete** its local `snap_version()` (line ~8) and `service_state()` (lines ~10-14) — they now come from `functions` (already sourced).

- [ ] **Step 3: Write the failing shell test** — `tests/ui_nav_test.sh`

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
export SNAP="$HERE/fixtures"
: "${SNAP_NAME:=zwave-js-ui}"; export SNAP_NAME   # snapd sets this at runtime; pin it for tests
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT
export PATH="$HERE/fixtures/bin:$PATH"     # stub gum/less on PATH
export GUM_LOG="$SNAP_DATA/gum.log"; : > "$GUM_LOG"

snapctl() {
    case "$1" in
        services) printf 'Service  Startup  Current  Notes\nzwave-js-ui.zwave-js-ui  enabled  active  -\n' ;;
        get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
        *) : ;;
    esac
}
# shellcheck source=/dev/null
source "$ROOT/src/bin/ui"

# root guard: require_root calls `exit 1` (would kill the harness), so assert main
# CALLS it first by overriding it as a spy instead of running the real non-root path.
R="$SNAP_DATA/root.flag"; rm -f "$R"
require_root() { : > "$R"; }                  # spy
printf '%s\n' "Quit" > "$SNAP_DATA/q0"
UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$SNAP_DATA/q0" main >/dev/null 2>&1
assert_status "$([ -f "$R" ] && echo 0 || echo 1)" "0" "main calls require_root first"

# no-TTY -> pointer + status 2 (ui_interactive false because stdout is a pipe here)
out="$(UI_ASSUME_TTY= main </dev/null 2>&1)"; st=$?
assert_status "$st" "2" "no-TTY -> returns 2"
assert_contains "$out" "$SNAP_NAME.help" "no-TTY -> points at help"

# interactive: pick Service then Quit -> dispatches nav_service, then exits cleanly
Q="$SNAP_DATA/choose.q"; printf '%s\n' "Service" "Quit" > "$Q"
nav_service() { echo "NAV_SERVICE_RAN"; }     # spy
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$Q" main 2>&1)"; st=$?
assert_status "$st" "0" "interactive loop exits 0 on Quit"
assert_contains "$out" "NAV_SERVICE_RAN" "Service menu entry dispatches nav_service"
assert_contains "$out" "$SNAP_NAME" "header shows the snap name"

finish
```

- [ ] **Step 4: Run the test — expect FAIL**

Run: `bash tests/ui_nav_test.sh`
Expected: FAIL — `src/bin/ui` does not exist yet (source error / `main` undefined).

- [ ] **Step 5: Write `src/bin/ui`**

```bash
#!/usr/bin/env bash
# ui — interactive navigator: browse & act on settings, service, plugs, logs.
: "${SNAP:?SNAP must be set}"
source "$SNAP/helper/functions"
source "$SNAP/helper/ui"
source "$SNAP/helper/catalog"

# --- section stubs (replaced in Tasks 2-5) ---
nav_settings() { ui_warn "Settings: not implemented yet."; }
nav_service()  { ui_warn "Service: not implemented yet."; }
nav_plugs()    { ui_warn "Plugs: not implemented yet."; }
nav_logs()     { ui_warn "Live logs: not implemented yet."; }
nav_help()     { ui_warn "Help: not implemented yet."; }

main() {
    require_root
    if ! ui_interactive; then
        ui_print "$SNAP_NAME.ui needs an interactive terminal — see $SNAP_NAME.help" >&2
        return 2
    fi
    local choice
    while true; do
        ui_header "$SNAP_NAME" "$(snap_version) · $(service_state)"
        choice="$(ui_choose "What do you want to do?" \
            "this menu needs a terminal; use the other $SNAP_NAME.* commands non-interactively" \
            "Settings" "Service" "Plugs" "Live logs" "Help" "Quit")" || break
        case "$choice" in
            Settings)    nav_settings ;;
            Service)     nav_service ;;
            Plugs)       nav_plugs ;;
            "Live logs") nav_logs ;;
            Help)        nav_help ;;
            Quit|"")     break ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

- [ ] **Step 6: Register the app** in `snap/snapcraft.yaml` — add under `apps:` (next to `help`):

```yaml
  ui:
    command: bin/ui
```

- [ ] **Step 7: Run the test — expect PASS**

Run: `bash tests/ui_nav_test.sh` then `TERM=dumb bash tests/ui_nav_test.sh`
Expected: PASS both. Also run `bash tests/help_test.sh` (the `snap_version`/`service_state` move must not break it) — PASS.

- [ ] **Step 8: shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/ui src/bin/help src/helper/functions tests/ui_nav_test.sh` → clean.

```bash
git add src/bin/ui snap/snapcraft.yaml src/helper/functions src/bin/help tests/ui_nav_test.sh tests/fixtures/bin/gum
git commit -m "feat(ui): navigator shell (menu loop, root/no-TTY guards, app registration)"
```

---

## Task 2: Service section

**Files:**
- Modify: `src/bin/ui` (replace `nav_service`)
- Test: `tests/ui_nav_test.sh`

**Interfaces:**
- Consumes: `service_state` (functions), `ui_choose`, `ui_kv` (ui), the bins `$SNAP/bin/daemonize`/`de-daemonize`/`restart` (each `require_root` + acts + prints).
- Produces: `nav_service` — shows status, offers Enable/Disable/Restart/Back, runs the matching bin, returns to the loop.

- [ ] **Step 1: Write the failing test** (append to `tests/ui_nav_test.sh`, before `finish`)

```bash
# --- Service section ---
# Shim the service bins under $SNAP_DATA and point nav_service at them via NAV_BIN
# (no writing into $SNAP/fixtures). nav_service loops; a single choice then a drained
# queue (exit 130 -> ui_choose returns 2 -> `|| return`) backs out cleanly.
SVC="$SNAP_DATA/svcbin"; mkdir -p "$SVC"
for b in daemonize de-daemonize restart; do printf '#!/usr/bin/env bash\necho "RAN_%s"\n' "$b" > "$SVC/$b"; chmod +x "$SVC/$b"; done
QS="$SNAP_DATA/svc.q"; printf '%s\n' "Enable" > "$QS"
out="$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$QS" nav_service 2>&1)"
assert_contains "$out" "RAN_daemonize" "Service > Enable runs daemonize"
printf '%s\n' "Restart" > "$QS"
assert_contains "$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$QS" nav_service 2>&1)" "RAN_restart" "Service > Restart runs restart"
```

- [ ] **Step 2: Run — expect FAIL** (`nav_service` is the stub).

Run: `bash tests/ui_nav_test.sh` → FAIL (`RAN_daemonize` absent).

- [ ] **Step 3: Implement `nav_service`** (replace the stub in `src/bin/ui`)

```bash
nav_service() {                # browse status; act via the existing service bins
    local bindir="${NAV_BIN:-$SNAP/bin}" choice
    while true; do
        ui_kv "service" "$SNAP_NAME" "state" "$(service_state)"
        choice="$(ui_choose "Service action" "" "Enable" "Disable" "Restart" "← Back")" || return
        case "$choice" in
            Enable)  "$bindir/daemonize" ;;
            Disable) "$bindir/de-daemonize" ;;
            Restart) "$bindir/restart" ;;
            *)       return ;;
        esac
    done
}
```

- [ ] **Step 4: Run — expect PASS** (normal + `TERM=dumb`).

- [ ] **Step 5: shellcheck + commit**

```bash
git add src/bin/ui tests/ui_nav_test.sh
git commit -m "feat(ui): Service section — status + enable/disable/restart"
```

---

## Task 3: Settings section (browse + act)

**Files:**
- Modify: `src/bin/ui` (replace `nav_settings`, add edit/apply helpers), `src/helper/catalog` (add `catalog_row`)
- Test: `tests/ui_nav_test.sh`

**Interfaces:**
- Consumes: `settings_catalog`/`catalog_keys`/`catalog_row` (catalog), `snapctl get`/`set`/`unset`, `ui_choose`/`ui_input`/`ui_kv`/`ui_ok`/`ui_err`/`ui_print`.
- Produces: `nav_settings` (browse keys → detail → Edit/Reset/Back); `nav_set_apply <key> <value|""> <set|unset>` (runs snapctl, surfaces the `configure` hook verdict). Catalog: `catalog_row <key>` → the key's `key\ttype\tdefault\tdescription` row.

- [ ] **Step 1: Add `catalog_row` (with its own failing test first)**

Append to `tests/ui_nav_test.sh`:

```bash
# --- catalog_row ---
assert_eq "$(catalog_row server.port | cut -f2)" "int" "catalog_row server.port type"
assert_eq "$(catalog_row server.ssl | cut -f3)" "false" "catalog_row server.ssl default"
assert_eq "$(catalog_row nope)" "" "catalog_row unknown -> empty"
```

Run → FAIL. Then add to `src/helper/catalog` (after `catalog_keys`):

```bash
catalog_row() { settings_catalog | awk -F'\t' -v k="$1" '$1==k'; }   # the TSV row for one key
```

Run → PASS.

- [ ] **Step 2: Write the failing Settings tests** (append, before `finish`)

```bash
# --- Settings: edit a bool, apply via snapctl set ---
SET_LOG="$SNAP_DATA/set.log"; : > "$SET_LOG"
snapctl() {
    case "$1" in
        services) printf 'Service  Startup  Current  Notes\nzwave-js-ui.zwave-js-ui  enabled  active  -\n' ;;
        get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
        set)   printf 'set %s\n' "$2" >> "$SET_LOG"; [ -n "${SNAPCTL_SET_FAIL:-}" ] && { echo "configure: bad value" >&2; return 1; }; return 0 ;;
        unset) printf 'unset %s\n' "$2" >> "$SET_LOG"; return 0 ;;
        *) : ;;
    esac
}
# browse server.ssl -> Edit -> choose "true" -> Back; then Back out of settings
CQ="$SNAP_DATA/setc.q"; printf '%s\n' "server.ssl" "Edit" "true" "← Back" > "$CQ"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings 2>&1)"
assert_contains "$(cat "$SET_LOG")" "set server.ssl=true" "Edit bool -> snapctl set key=value"
assert_contains "$out" "set" "success surfaced"

# rejection: configure hook says no -> ui_err, message shown, value not claimed applied
# server.port is int -> the value comes from ui_input (GUM_INPUT_QUEUE), NOT the choose queue.
: > "$SET_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"
INQ="$SNAP_DATA/in.q"; printf '99999\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 SNAPCTL_SET_FAIL=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "configure: bad value" "rejection surfaces the hook message"

# reset to default -> snapctl unset
: > "$SET_LOG"; printf '%s\n' "mqtt.name" "Reset to default" "← Back" > "$CQ"
UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "unset mqtt.name" "Reset -> snapctl unset"
```

Note: a `bool` value is chosen with `ui_choose` (so it comes from `GUM_CHOOSE_QUEUE`); a non-bool value is typed with `ui_input` (from `GUM_INPUT_QUEUE`). The port test uses `GUM_INPUT_QUEUE` for the `99999` value and `GUM_CHOOSE_QUEUE` for the key/action/back selections.

- [ ] **Step 3: Run — expect FAIL** (`nav_settings` is the stub).

- [ ] **Step 4: Implement `nav_settings` + `nav_set_apply`** (replace the stub)

```bash
nav_settings() {               # browse the catalog; edit via snapctl (configure hook validates)
    local choice key type def desc cur act new
    while true; do
        # build the key list with current values inline (gum choose filters as you type)
        local items=() k v
        while IFS= read -r k; do
            v="$(snapctl get "$k" 2>/dev/null)"; [ "$k" = session.secret ] && [ -n "$v" ] && v="(hidden)"
            items+=("$k = ${v:-(unset)}")
        done < <(catalog_keys)
        choice="$(ui_choose "Setting (type to filter)" "" "${items[@]}" "← Back")" || return
        [ "$choice" = "← Back" ] && return
        key="${choice%% = *}"
        IFS=$'\t' read -r _ type def desc < <(catalog_row "$key")
        cur="$(snapctl get "$key" 2>/dev/null)"; [ "$key" = session.secret ] && [ -n "$cur" ] && cur="(hidden)"
        ui_kv "key" "$key" "current" "${cur:-(unset)}" "default" "$def" "type" "$type" "description" "$desc"
        act="$(ui_choose "Action for $key" "" "Edit" "Reset to default" "← Back")" || continue
        case "$act" in
            Edit)
                if [ "$type" = bool ]; then
                    new="$(ui_choose "$key =" "" "true" "false")" || continue
                else
                    new="$(ui_input "$key = ")" || continue
                fi
                nav_set_apply "$key" "$new" set ;;
            "Reset to default") nav_set_apply "$key" "" unset ;;
            *) : ;;
        esac
    done
}

nav_set_apply() {              # $1 key, $2 value, $3 set|unset — run snapctl, surface configure's verdict
    local key="$1" val="$2" mode="$3" out rc
    if [ "$mode" = unset ]; then out="$(snapctl unset "$key" 2>&1)"; rc=$?
    else out="$(snapctl set "$key=$val" 2>&1)"; rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        if [ "$mode" = unset ]; then ui_ok "$key reset to default"; else ui_ok "$key set to $val"; fi
    else
        ui_err "Rejected — $key unchanged"
        [ -n "$out" ] && ui_print "$out"
    fi
}
```

- [ ] **Step 5: Run — expect PASS** (normal + `TERM=dumb`). **Spike to confirm during this task** (Global Constraints / spec "open item"): on a real install, `snapctl set <key>=<value>` from the `ui` app must trigger the `configure` hook and return non-zero with its stderr on rejection. If it does not, change `nav_set_apply` to invoke the validation explicitly; note the finding in the task report.

- [ ] **Step 6: shellcheck + commit**

```bash
git add src/bin/ui src/helper/catalog tests/ui_nav_test.sh
git commit -m "feat(ui): Settings section — catalog browse + typed edit, configure-hook validated"
```

---

## Task 4: Plugs section (browse + guide)

**Files:**
- Modify: `src/bin/ui` (replace `nav_plugs`, add a plug catalog)
- Test: `tests/ui_nav_test.sh`

**Interfaces:**
- Consumes: `snapctl is-connected <plug>` (rc 0 connected), `ui_choose`/`ui_kv`/`ui_print`/`ui_ok`/`ui_warn`.
- Produces: `nav_plugs` — lists plugs with status; for a disconnected plug, shows the exact `snap connect $SNAP_NAME:<plug>` command (and the serial-port hotplug note). Never runs `snap connect`.

- [ ] **Step 1: Write the failing test** (append)

```bash
# --- Plugs section ---
snapctl() { case "$1" in is-connected) [ "$2" = hardware-observe ] && return 0 || return 1 ;; *) : ;; esac; }
PQ="$SNAP_DATA/plug.q"; printf '%s\n' "raw-usb" "← Back" > "$PQ"     # pick a disconnected plug
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$PQ" nav_plugs 2>&1)"
assert_contains "$out" "snap connect $SNAP_NAME:raw-usb" "disconnected plug shows the connect command"
printf '%s\n' "hardware-observe" "← Back" > "$PQ"                    # connected plug
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$PQ" nav_plugs 2>&1)"
case "$out" in *"snap connect $SNAP_NAME:hardware-observe"*) FAIL=$((FAIL+1)); echo "FAIL: connected plug should not show connect cmd" >&2 ;; *) PASS=$((PASS+1)) ;; esac
```

- [ ] **Step 2: Run — expect FAIL** (stub).

- [ ] **Step 3: Implement `nav_plugs`** (replace the stub)

```bash
nav_plugs() {                  # browse interface status; guide the connect commands (never auto-connect)
    # plug -> purpose (the connect-relevant interfaces)
    local catalog="hardware-observe	the Z-Wave controller (required, with raw-usb or serial-port)
raw-usb	USB Z-Wave stick access
serial-port	serial Z-Wave stick (needs experimental hotplug)
log-observe	read journald logs when 'log to file' is off
gpg-public-keys	the backup key picker"
    local choice plug purpose
    while true; do
        local items=() p rest mark
        while IFS=$'\t' read -r p rest; do
            snapctl is-connected "$p" 2>/dev/null && mark="✓" || mark="✗"
            items+=("$mark $p")
        done <<< "$catalog"
        choice="$(ui_choose "Interface (✓ connected)" "" "${items[@]}" "← Back")" || return
        [ "$choice" = "← Back" ] && return
        plug="${choice#* }"
        purpose="$(printf '%s\n' "$catalog" | awk -F'\t' -v k="$plug" '$1==k{print $2}')"
        ui_kv "plug" "$plug" "purpose" "$purpose"
        if snapctl is-connected "$plug" 2>/dev/null; then
            ui_ok "$plug is connected."
        else
            ui_warn "$plug is not connected. Connect it from the host:"
            ui_print "  sudo snap connect $SNAP_NAME:$plug"
            [ "$plug" = serial-port ] && ui_print "  (first: sudo snap set system experimental.hotplug=true && sudo systemctl restart snapd)"
        fi
    done
}
```

- [ ] **Step 4: Run — expect PASS** (normal + `TERM=dumb`).

- [ ] **Step 5: shellcheck + commit**

```bash
git add src/bin/ui tests/ui_nav_test.sh
git commit -m "feat(ui): Plugs section — interface status + connect guidance"
```

---

## Task 5: Live logs + Help

**Files:**
- Modify: `src/bin/ui` (replace `nav_logs`, `nav_help`)
- Test: `tests/ui_nav_test.sh`

**Interfaces:**
- Consumes: `ui_choose`; the existing `$SNAP/bin/logs` and `$SNAP/bin/help` (via the `${NAV_BIN:-$SNAP/bin}` indirection from Task 2 so tests can shim them).
- Produces: `nav_logs` (choose all/zui/zwjs → run `logs <target>`), `nav_help` (run `help`).

- [ ] **Step 1: Write the failing test** (append)

```bash
# --- Live logs + Help ---
mkdir -p "$SVC"; printf '#!/usr/bin/env bash\necho "RAN_logs $*"\n' > "$SVC/logs"; chmod +x "$SVC/logs"
printf '#!/usr/bin/env bash\necho "RAN_help"\n' > "$SVC/help"; chmod +x "$SVC/help"
LQ="$SNAP_DATA/logs.q"; printf '%s\n' "zui" > "$LQ"
assert_contains "$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$LQ" nav_logs 2>&1)" "RAN_logs zui" "Live logs > zui runs logs zui"
printf '%s\n' "all" > "$LQ"
assert_contains "$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CHOOSE_QUEUE="$LQ" nav_logs 2>&1)" "RAN_logs" "Live logs > all runs logs (no target)"
assert_contains "$(NAV_BIN="$SVC" nav_help 2>&1)" "RAN_help" "Help runs help"
```

- [ ] **Step 2: Run — expect FAIL** (stubs).

- [ ] **Step 3: Implement `nav_logs` + `nav_help`** (replace the stubs)

```bash
nav_logs() {                   # choose a stream, hand off to the existing logs viewer
    local bindir="${NAV_BIN:-$SNAP/bin}" sel
    sel="$(ui_choose "Follow which logs?" "" "all" "zui" "zwjs")" || return
    case "$sel" in
        all) "$bindir/logs" ;;
        *)   "$bindir/logs" "$sel" ;;
    esac
}

nav_help() { "${NAV_BIN:-$SNAP/bin}/help"; }
```

- [ ] **Step 4: Run the FULL suite — expect PASS** (normal + `TERM=dumb`):

```bash
for t in tests/*_test.sh; do echo "$t"; bash "$t" | tail -1; TERM=dumb bash "$t" | tail -1; done
```

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck --severity=warning -x src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh
git add src/bin/ui tests/ui_nav_test.sh
git commit -m "feat(ui): Live logs + Help sections"
```

---

## Task 6: Docs

**Files:**
- Modify: `CLAUDE.md` (document the `ui` app), `src/bin/help` `commands_rows` (list `zwave-js-ui.ui`)

- [ ] **Step 1:** Add `"$SNAP_NAME.ui	interactive navigator — browse & change settings, service, plugs, logs"` to `commands_rows` in `src/bin/help` (so the command table lists it). Run `bash tests/help_test.sh` — PASS (the table is content-agnostic; add an assertion `assert_contains "$(commands_rows)" "$SNAP_NAME.ui" "help lists the ui command"`).

- [ ] **Step 2:** In `CLAUDE.md`, under "User commands (`src/bin/`)", add a sentence describing `zwave-js-ui.ui`: root-only interactive navigator (menu → Settings/Service/Plugs/Live logs/Help), a thin orchestrator over the catalog + existing bins, `configure` hook stays the validator; `settings.json` editing is deferred (Phase 2b). Reference `docs/superpowers/specs/2026-06-28-cli-navigator-design.md`.

- [ ] **Step 3: commit**

```bash
git add CLAUDE.md src/bin/help tests/help_test.sh
git commit -m "docs(ui): document the navigator app + list it in help"
```

---

## Notes for the implementer

- **`NAV_BIN` indirection:** `nav_service`/`nav_logs`/`nav_help` resolve sibling bins via `${NAV_BIN:-$SNAP/bin}` so tests can point at shims without writing into `$SNAP`. Introduce it in Task 2 and reuse it.
- **`ui_choose` returns 2** on no-TTY/Ctrl-C/abort; every `nav_*` loop uses `choice="$(ui_choose …)" || return` so Esc/Ctrl-C backs out one level, and the main loop's `|| break` quits. The gum stub's drained queue → exit 130 simulates this.
- **Never** add `set -e` to `src/bin/ui` — a failing section command must return to the menu, not kill the navigator.
- Keep every user string going through `ui_*`; no raw `echo` to stdout in section code (tests assert on `ui_*` output, which is plain under `TERM=dumb`).
