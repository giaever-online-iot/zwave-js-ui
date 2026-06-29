# CLI Navigator Phase 2b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the Z-Wave serial port + S2/S0 security keys as snap config (editable via the existing navigator Settings), and add a guided `settings.json` editor for the MQTT broker.

**Architecture:** Part A extends the snap-config catalog + `env-wrapper` so the env-var-backed `zwave.*` keys flow through the existing `snap set` → `configure` hook → navigator §2 path; a catalog `scope` keeps `help` lean and a `secret` type generalizes masking. Part B adds a `nav_mqtt` section that reads/writes `$SNAP_DATA/settings.json` `mqtt.*` via `yq` with an atomic write.

**Tech Stack:** Bash; `yq` (mikefarah, already used); `snapctl`; `gum` via `helper/ui`; the source-the-script + stub harness in `tests/`.

## Global Constraints

- Builds on the merged navigator `src/bin/ui` (#228). All user output via `ui_*`; never hardcode `zwave-js-ui` (use `$SNAP_NAME`); section loops return to the menu, never `exit`.
- Catalog rows are TAB-separated `key  type  default  description  scope`. `type` ∈ `{string,int,bool,secret}`; `scope` ∈ `{common,advanced}`. Descriptions for the new `zwave.*` keys are intentionally empty.
- `secret`-typed keys are masked in display (`(hidden)`) and entered with `ui_input --password`, everywhere.
- `help`'s settings table shows ONLY `scope=common`; the navigator shows all keys.
- Part A keys are real snap config: changes go through `snapctl set/unset` → the `configure` hook (the only validator); `env-wrapper` maps them to ZUI env vars, omitting an export when the snap value is empty (the `MQTT_NAME` pattern).
- Part B edits ZUI's own `settings.json` (NOT snap config): write atomically (tempfile + `yq` parses + `mv`); warn (don't block) if the daemon is running; offer a restart after a successful change. No `configure` hook involved.
- No new stage-packages; no `nano`.
- Tests pass under a normal env AND `TERM=dumb`; `shellcheck --severity=warning -x` clean.
- Spec: `docs/superpowers/specs/2026-06-29-cli-navigator-phase2b-design.md`.

---

## File Structure

- **Modify `src/helper/catalog`** — add the `scope` 5th column to every row, change `session.secret` to `type=secret`, add the 7 `zwave.*` rows, add `catalog_is_secret`.
- **Modify `src/bin/help`** — `settings_rows` reads 5 fields, filters `scope=common`, masks `type=secret`.
- **Modify `tests/help_test.sh`** — drift/shape guards for 5 fields + scope; assert advanced keys are omitted from `settings_rows`.
- **Modify `src/helper/env-wrapper`** — map the 7 `zwave.*` keys to `ZWAVE_PORT`/`KEY_*`.
- **Create `tests/env_wrapper_test.sh`** + **`tests/fixtures/bin/snapctl`** — behavioral test of the mapping.
- **Modify `src/bin/ui`** — generalize §2 masking to `type=secret`; add the `MQTT broker` menu item + `nav_mqtt` + `mqtt_set`.
- **Modify `tests/ui_nav_test.sh`** — §2 secret-masking for a `zwave.*` key; `nav_mqtt` flow.
- **Modify `CLAUDE.md`** — document the 2b additions.

---

## Task 1: Catalog `scope` + `secret` type + 7 advanced keys; `help` filters common

**Files:**
- Modify: `src/helper/catalog`, `src/bin/help` (`settings_rows`)
- Test: `tests/help_test.sh`

**Interfaces:**
- Produces: `settings_catalog` rows now have 5 TAB fields (`key type default description scope`); `session.secret` is `type=secret`; new keys `zwave.serial-port` (string), `zwave.s2-unauthenticated`/`-authenticated`/`-access-control`/`-lr-authenticated`/`-lr-access-control`/`zwave.s0-legacy` (secret), all `scope=advanced`, empty description. `catalog_is_secret <key>` → exit 0 iff that key's `type=secret`. `settings_rows` emits only `scope=common` keys and masks `secret` values.

- [ ] **Step 1: Update the guards in `tests/help_test.sh` (failing test)**

Replace the 4-field assertion (lines ~26-27) and add scope/secret/omission checks:

```bash
# every catalog row has exactly 5 TAB fields (key type default description scope)
settings_catalog | awk -F'\t' 'NF != 5 { exit 1 }'
assert_status "$?" "0" "every catalog row has exactly 5 fields"
# scope is common|advanced; type includes the secret pseudo-type
settings_catalog | awk -F'\t' '$5 != "common" && $5 != "advanced" { exit 1 }'
assert_status "$?" "0" "every row scope is common|advanced"
assert_eq "$(catalog_row session.secret | cut -f2)" "secret" "session.secret is type=secret"
assert_contains "$(catalog_keys)" "zwave.serial-port" "catalog has zwave.serial-port"
# help table shows ONLY common keys — advanced zwave keys are omitted
assert_contains "$(settings_rows)" "server.port"        "help table includes a common key"
case "$(settings_rows)" in *zwave.serial-port*) FAIL=$((FAIL+1)); echo "FAIL: advanced key leaked into help" >&2 ;; *) PASS=$((PASS+1)) ;; esac
# catalog_is_secret
( catalog_is_secret session.secret ); assert_status "$?" "0" "catalog_is_secret: session.secret -> yes"
( catalog_is_secret server.port );    assert_status "$?" "1" "catalog_is_secret: server.port -> no"
```

- [ ] **Step 2: Run — expect FAIL**

Run: `bash tests/help_test.sh` → FAIL (rows still have 4 fields; `catalog_is_secret` undefined).

- [ ] **Step 3: Rewrite `src/helper/catalog`**

```bash
#!/usr/bin/env bash
# catalog — single source of truth for user-settable snap config.
# TAB-separated rows: key, type, default, description, scope.
#   type:  string | int | bool | secret   (secret => masked + --password everywhere)
#   scope: common | advanced              (help shows common only; the ui navigator shows all)
# Defaults must stay in sync with test_default_config (helper/functions) and bin/backup.
settings_catalog() {
	cat <<'EOF'
server.host	string	0.0.0.0	IP address the web UI binds to	common
server.port	int	8091	Port for the web UI	common
server.ssl	bool	false	Serve the web UI over HTTPS	common
server.force-disable-ssl	bool	false	Force-disable SSL even when enabled	common
session.secret	secret	(generated)	Session secret (a UUID is generated on install)	common
session.cookie-secure	bool	(= server.ssl)	Secure session cookie (see expressjs/session#cookiesecure)	common
mqtt.name	string	(unset)	Client name when connecting to the MQTT broker	common
timezone	string	Europe/Oslo	Timezone exported to the app as TZ	common
backup.target	string	(unset)	Duplicity target URL for off-box backups	common
backup.dir	string	$SNAP_DATA/backups	Directory shipped by the backup command	common
backup.encrypt	bool	(unset)	Set false to opt out of backup encryption	common
backup.encrypt-key	string	(unset)	GPG fingerprint backups are encrypted to	common
backup.full-if-older-than	string	7D	Force a full backup after this age	common
backup.retention	int	3	Full backup chains kept on the target	common
zwave.serial-port	string	(unset)		advanced
zwave.s2-unauthenticated	secret	(unset)		advanced
zwave.s2-authenticated	secret	(unset)		advanced
zwave.s2-access-control	secret	(unset)		advanced
zwave.s2-lr-authenticated	secret	(unset)		advanced
zwave.s2-lr-access-control	secret	(unset)		advanced
zwave.s0-legacy	secret	(unset)		advanced
EOF
}

catalog_keys() { settings_catalog | cut -f1; }
catalog_row()  { settings_catalog | awk -F'\t' -v k="$1" '$1==k'; }   # the TSV row for one key
catalog_is_secret() { [ "$(catalog_row "$1" | cut -f2)" = secret ]; } # exit 0 iff type=secret
```

(The empty description fields are two adjacent TABs before `advanced` — keep them.)

- [ ] **Step 4: Update `settings_rows` in `src/bin/help`**

```bash
settings_rows() {              # catalog (common only) + live values -> TSV: key, value, default, description
    local key type def desc scope cur
    while IFS=$'\t' read -r key type def desc scope; do
        [ "$scope" = common ] || continue           # advanced keys stay out of the help table
        cur="$(snapctl get "$key" 2>/dev/null)"
        [ "$type" = secret ] && [ -n "$cur" ] && cur="(hidden)"
        printf '%s\t%s\t%s\t%s\n' "$key" "${cur:-(unset)}" "$def" "$desc"
    done < <(settings_catalog)
}
```

- [ ] **Step 5: Run — expect PASS** (normal + `TERM=dumb`)

Run: `bash tests/help_test.sh` and `TERM=dumb bash tests/help_test.sh` → PASS. (The existing drift guard for `server.host/port/ssl/timezone` still holds — those rows' fields 1-3 are unchanged.)

- [ ] **Step 6: shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/catalog src/bin/help tests/help_test.sh` → clean.

```bash
git add src/helper/catalog src/bin/help tests/help_test.sh
git commit -m "feat(catalog): scope + secret columns; zwave.* advanced keys; help shows common only"
```

**Sequencing note (same PR):** `src/bin/ui` `nav_settings` currently reads `catalog_row` with **4** vars; against the new 5-field rows its detail line shows a harmless trailing `scope` token until **Task 3** updates the read to 5 vars. This does not break any test (the description text is not asserted) and is corrected within this PR. Do not "fix" it here — Task 3 owns the `src/bin/ui` read + masking change together.

---

## Task 2: `env-wrapper` maps the `zwave.*` keys to ZUI env vars

**Files:**
- Modify: `src/helper/env-wrapper`
- Create: `tests/env_wrapper_test.sh`, `tests/fixtures/bin/snapctl`

**Interfaces:**
- Consumes: catalog keys `zwave.serial-port`, `zwave.s2-*`, `zwave.s0-legacy` (Task 1).
- Produces: `env-wrapper` exports `ZWAVE_PORT`, `KEY_S2_Unauthenticated`, `KEY_S2_Authenticated`, `KEY_S2_AccessControl`, `KEY_LR_S2_Authenticated`, `KEY_LR_S2_AccessControl`, `KEY_S0_Legacy` from the matching `snapctl get`, omitting each when empty.

- [ ] **Step 1: Add a `snapctl` exec-stub fixture** — `tests/fixtures/bin/snapctl`

```bash
#!/usr/bin/env bash
# Fake snapctl for process-level tests (env-wrapper). `get <key>` echoes
# $SNAPCTL_<key with . and - as _>; everything else is a quiet no-op.
case "${1:-}" in
    get) k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;;
    *)   : ;;
esac
```

Make it executable: `chmod +x tests/fixtures/bin/snapctl`.

- [ ] **Step 2: Write the failing test** — `tests/env_wrapper_test.sh`

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
export SNAP="$HERE/fixtures"
SNAP_DATA="$(mktemp -d)"; export SNAP_DATA
trap 'rm -rf "$SNAP_DATA"' EXIT
export PATH="$HERE/fixtures/bin:$PATH"     # snapctl exec-stub on PATH

# env-wrapper sets env from snapctl then exec's its argument; run `env` to observe.
run_wrapper() { bash "$ROOT/src/helper/env-wrapper" env 2>/dev/null; }

# serial port present -> ZWAVE_PORT exported
out="$(SNAPCTL_zwave_serial_port=/dev/ttyACM0 run_wrapper)"
assert_contains "$out" "ZWAVE_PORT=/dev/ttyACM0" "serial-port -> ZWAVE_PORT"
# a security key present -> KEY_* exported
out="$(SNAPCTL_zwave_s2_unauthenticated=DEADBEEF run_wrapper)"
assert_contains "$out" "KEY_S2_Unauthenticated=DEADBEEF" "s2-unauthenticated -> KEY_S2_Unauthenticated"
# empty -> NOT exported (no blank override)
out="$(run_wrapper)"
case "$out" in *$'\n'ZWAVE_PORT=*|ZWAVE_PORT=*) FAIL=$((FAIL+1)); echo "FAIL: empty serial-port exported ZWAVE_PORT" >&2 ;; *) PASS=$((PASS+1)) ;; esac
finish
```

- [ ] **Step 3: Run — expect FAIL**

Run: `bash tests/env_wrapper_test.sh` → FAIL (env-wrapper doesn't export `ZWAVE_PORT`/`KEY_*` yet). If env-wrapper errors before `exec` (e.g. an unstubbed helper like `backup_dir`), add the minimal stub to `tests/fixtures/helper/functions` so it runs to `exec`; the failure under test must be the missing exports, not a setup error.

- [ ] **Step 4: Add the mappings to `src/helper/env-wrapper`** (after the `MQTT_NAME` block, before the `timezone` block)

```bash
# zwave.* (advanced snap config) -> ZUI env vars. Omit when empty so an unset
# snap key never force-blanks a value configured elsewhere (the MQTT_NAME pattern).
zwave_env() {                  # $1 snap key, $2 env var name
    local v; v="$(snapctl get "$1")"
    [ -n "$v" ] && export "$2"="$v"
}
zwave_env zwave.serial-port            ZWAVE_PORT
zwave_env zwave.s2-unauthenticated     KEY_S2_Unauthenticated
zwave_env zwave.s2-authenticated       KEY_S2_Authenticated
zwave_env zwave.s2-access-control      KEY_S2_AccessControl
zwave_env zwave.s2-lr-authenticated    KEY_LR_S2_Authenticated
zwave_env zwave.s2-lr-access-control   KEY_LR_S2_AccessControl
zwave_env zwave.s0-legacy              KEY_S0_Legacy
```

- [ ] **Step 5: Run — expect PASS** (normal + `TERM=dumb`)

Run: `bash tests/env_wrapper_test.sh` and `TERM=dumb bash tests/env_wrapper_test.sh` → PASS.

- [ ] **Step 6: shellcheck + commit**

Run: `shellcheck --severity=warning -x src/helper/env-wrapper tests/env_wrapper_test.sh tests/fixtures/bin/snapctl` → clean.

```bash
git add src/helper/env-wrapper tests/env_wrapper_test.sh tests/fixtures/bin/snapctl
git commit -m "feat(env-wrapper): map zwave.serial-port + S2/S0 keys to ZUI env vars"
```

---

## Task 3: Navigator §2 — generalize secret masking to `type=secret`

**Files:**
- Modify: `src/bin/ui` (`nav_settings`, `nav_set_apply`)
- Test: `tests/ui_nav_test.sh`

**Interfaces:**
- Consumes: `catalog_is_secret <key>` (Task 1); `catalog_row` now returns 5 fields.
- Produces: §2 masks/`--password`s any `type=secret` key (not just `session.secret`), and lists the `advanced` keys.

- [ ] **Step 1: Write the failing test** (append to `tests/ui_nav_test.sh` before `finish`)

```bash
# secret-typed zwave key is masked in the banner and never leaked (type=secret, not by name)
SKQ="$SNAP_DATA/sk.q"; printf '%s\n' "zwave.s2-unauthenticated" "Edit" "← Back" > "$SKQ"
SKI="$SNAP_DATA/sk.in"; printf 'AABBCCDD\n' > "$SKI"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$SKQ" GUM_INPUT_QUEUE="$SKI" nav_settings 2>&1)"
case "$out" in *AABBCCDD*) FAIL=$((FAIL+1)); echo "FAIL: secret zwave key leaked" >&2 ;; *) PASS=$((PASS+1)) ;; esac
assert_contains "$out" "(hidden)" "secret zwave key shows (hidden) in banner"
```

(`zwave.s2-unauthenticated` is `type=secret` → the value comes from `ui_input --password`/`GUM_INPUT_QUEUE`. The test reuses the `snapctl` set-logging stub already defined earlier in the file; re-`source "$ROOT/src/bin/ui"` first if a prior test left a spy.)

- [ ] **Step 2: Run — expect FAIL** (only `session.secret` is masked today).

- [ ] **Step 3: Generalize the masking in `src/bin/ui`**

In `nav_settings`, replace the three `[ "$key" = session.secret ]` / `[ "$k" = session.secret ]` checks and read the 5th field:
```bash
        while IFS= read -r k; do
            v="$(snapctl get "$k" 2>/dev/null)"; catalog_is_secret "$k" && [ -n "$v" ] && v="(hidden)"
            items+=("$k = ${v:-(unset)}")
        done < <(catalog_keys)
```
```bash
        IFS=$'\t' read -r _ type def desc _ < <(catalog_row "$key")   # 5 fields now (trailing scope ignored)
        cur="$(snapctl get "$key" 2>/dev/null)"; catalog_is_secret "$key" && [ -n "$cur" ] && cur="(hidden)"
```
```bash
                else
                    if catalog_is_secret "$key"; then
                        new="$(ui_input --password "$key = ")" || continue
                    else
                        new="$(ui_input "$key = ")" || continue
                    fi
                fi
```
In `nav_set_apply`, replace the banner mask:
```bash
            local shown="$val"; catalog_is_secret "$key" && [ -n "$val" ] && shown="(hidden)"
            ui_ok "$key set to $shown"
```

- [ ] **Step 4: Run — expect PASS** (normal + `TERM=dumb`); the existing `session.secret` masking test still passes (it's now `type=secret`).

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/ui tests/ui_nav_test.sh` → clean.

```bash
git add src/bin/ui tests/ui_nav_test.sh
git commit -m "feat(ui): mask any type=secret key in Settings (covers the new zwave keys)"
```

---

## Task 4: Part B — `nav_mqtt` MQTT broker `settings.json` editor

**Files:**
- Modify: `src/bin/ui` (add `nav_mqtt` + `mqtt_set` + the menu item)
- Test: `tests/ui_nav_test.sh`

**Interfaces:**
- Consumes: `ui_choose`/`ui_input`/`ui_kv`/`ui_ok`/`ui_err`/`ui_confirm`/`ui_clear`/`ui_pause`; `yq`; `${NAV_BIN:-$SNAP/bin}/restart`.
- Produces: a `MQTT broker` main-menu entry → `nav_mqtt`, editing `$SNAP_DATA/settings.json` `mqtt.host/port/auth/username/password` via `mqtt_set <field> <value> <type>` (atomic `yq` write).

- [ ] **Step 1: Write the failing test** (append before `finish`)

```bash
# --- nav_mqtt: edits settings.json mqtt.* via yq (stubbed) ---
SF="$SNAP_DATA/settings.json"; printf '%s' '{"mqtt":{"host":"old"}}' > "$SF"
YQ_LOG="$SNAP_DATA/yq.log"; : > "$YQ_LOG"
# stub yq: log the expression+file; for reads (-e '.mqtt.host') echo a canned current value; writes succeed
yq() { printf '%s\n' "$*" >> "$YQ_LOG"; case "$*" in *'-o=json'*|*' = '*) cat "${@: -1}" 2>/dev/null || true ;; *) printf 'old\n' ;; esac; }
export -f yq 2>/dev/null || true
MQ="$SNAP_DATA/mqtt.q"; printf '%s\n' "mqtt.host" "← Back" > "$MQ"
MI="$SNAP_DATA/mqtt.in"; printf 'broker.local\n' > "$MI"
# decline the restart prompt
GUM_CONFIRM=1 UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$MQ" GUM_INPUT_QUEUE="$MI" SNAP_DATA="$SNAP_DATA" nav_mqtt >/dev/null 2>&1
assert_contains "$(cat "$YQ_LOG")" ".mqtt.host" "nav_mqtt writes mqtt.host via yq"
```

(Reuse the file's existing harness; re-`source "$ROOT/src/bin/ui"` first if needed. The stub models `yq` enough to exercise the write path; real-yq behavior is verified by the implementer in Step 4's note.)

- [ ] **Step 2: Run — expect FAIL** (`nav_mqtt` undefined).

- [ ] **Step 3: Implement `nav_mqtt` + `mqtt_set` and wire the menu** in `src/bin/ui`

```bash
mqtt_file() { printf '%s\n' "${SNAP_DATA}/settings.json"; }

mqtt_get() {                   # $1 mqtt.<field> -> current value or empty
    local f; f="$(mqtt_file)"; [ -f "$f" ] || { echo ""; return; }
    yq -p=json -r ".$1 // \"\"" "$f" 2>/dev/null
}

mqtt_set() {                   # $1 mqtt.<field>, $2 value, $3 type -> atomic write; rc 1 on failure
    local path="$1" val="$2" type="$3" f tmp expr
    f="$(mqtt_file)"; [ -f "$f" ] || echo '{}' > "$f"
    case "$type" in
        int)  expr=".$path = (strenv(V) | tonumber)" ;;
        bool) expr=".$path = (strenv(V) == \"true\")" ;;
        *)    expr=".$path = strenv(V)" ;;
    esac
    tmp="$(mktemp "${f}.XXXX")"
    if V="$val" yq -p=json -o=json "$expr" "$f" > "$tmp" 2>/dev/null && yq -p=json '.' "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$f"; return 0
    fi
    rm -f "$tmp"; return 1
}

nav_mqtt() {                   # edit the MQTT broker connection in settings.json (no env var for these)
    local fields="mqtt.host	string
mqtt.port	int
mqtt.auth	bool
mqtt.username	string
mqtt.password	secret"
    local choice path type cur new
    while true; do
        ui_clear
        ui_warn "Editing settings.json. If the daemon is running it may overwrite changes on its own saves."
        local items=() p t v
        while IFS=$'\t' read -r p t; do
            v="$(mqtt_get "$p")"; [ "$t" = secret ] && [ -n "$v" ] && v="(hidden)"
            items+=("$p = ${v:-(unset)}")
        done <<< "$fields"
        choice="$(ui_choose "MQTT broker (settings.json)" "" "${items[@]}" "← Back")" || return
        [ "$choice" = "← Back" ] && return
        path="${choice%% = *}"
        type="$(printf '%s\n' "$fields" | awk -F'\t' -v k="$path" '$1==k{print $2}')"
        if [ "$type" = bool ]; then new="$(ui_choose "$path =" "" "true" "false")" || continue
        elif [ "$type" = secret ]; then new="$(ui_input --password "$path = ")" || continue
        else new="$(ui_input "$path = ")" || continue; fi
        if mqtt_set "$path" "$new" "$type"; then
            local shown="$new"; [ "$type" = secret ] && [ -n "$new" ] && shown="(hidden)"
            ui_ok "$path set to $shown"
            if ui_confirm "Restart $SNAP_NAME to apply?"; then "${NAV_BIN:-$SNAP/bin}/restart"; fi
        else
            ui_err "Could not write $path — settings.json unchanged"
        fi
        ui_pause
    done
}
```

Wire it into `main`'s menu (add `"MQTT broker"` to the `ui_choose` list and a `case` arm):
```bash
        choice="$(ui_choose "What do you want to do?" \
            "this menu needs a terminal; use the other $SNAP_NAME.* commands non-interactively" \
            "Settings" "Service" "Plugs" "Live logs" "MQTT broker" "Help" "Quit")" || break
        case "$choice" in
            Settings)      nav_settings ;;
            Service)       nav_service ;;
            Plugs)         nav_plugs ;;
            "Live logs")   nav_logs ;;
            "MQTT broker") nav_mqtt ;;
            Help)          nav_help ;;
            Quit|"")       break ;;
        esac
```

- [ ] **Step 4: Run — expect PASS** (normal + `TERM=dumb`). **Verify against real `yq`** during this task: run `mqtt_set mqtt.port 1883 int` against a scratch `{}` file and confirm `yq -p=json '.mqtt.port'` returns the integer `1883` (not `"1883"`), and `mqtt.auth true bool` yields boolean `true` — adjust the `expr` forms if your `yq` version coerces differently; note the result in the report.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck --severity=warning -x src/bin/ui tests/ui_nav_test.sh` → clean.

```bash
git add src/bin/ui tests/ui_nav_test.sh
git commit -m "feat(ui): MQTT broker settings.json editor (yq atomic write + restart offer)"
```

---

## Task 5: Docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1:** In `CLAUDE.md`, under the navigator description, add a sentence: Phase 2b added `zwave.serial-port` + the S2/S0 security keys as snap config (advanced; `help` shows common keys only, the navigator shows all; secrets masked), and a `MQTT broker` navigator section that edits `settings.json` `mqtt.*` via `yq` (atomic write + restart offer). Reference `docs/superpowers/specs/2026-06-29-cli-navigator-phase2b-design.md`.

- [ ] **Step 2: commit**

```bash
git add CLAUDE.md
git commit -m "docs(navigator-2b): document zwave snap-config keys + MQTT settings.json editor"
```

---

## Notes for the implementer

- The catalog's empty description fields (rows 15-21) are intentional — two adjacent TABs before `advanced`. Keep `awk -F'\t'` field counting at 5.
- `nav_mqtt`/`mqtt_set` use `yq` directly (not `snapctl`) because `settings.json` is ZUI's file, not snap config — there is no `configure` hook here; the atomic tempfile + `yq`-parses check is the safety net.
- Never add `set -e` to `src/bin/ui`. Keep all output through `ui_*`.
- The `yq` expression forms (`strenv`/`tonumber`/bool coercion) are the one place real-`yq` behavior matters — verify them on a scratch file (Task 4 Step 4) before relying on the stubbed unit test.
