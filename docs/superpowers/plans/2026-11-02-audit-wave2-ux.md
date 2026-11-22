# Package audit wave 2 (UX) — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the snap's commands catch mistakes at `snap set` time, tell the truth about state, and stop making users retype, guess or dig in journals (audit findings C4, C5, C9, C10, C12–C23 and polish).

**Architecture:** Every new rule lives in the catalog (`validate_config`, a new `validate_cross_config`, a new `unknown_config_keys`) and is applied by the `configure` hook, the navigator and the refresh sanitizer alike. `backup` gains one piece of state (`$SNAP_COMMON/backup.last`) and a fresh restore directory. The UI library decouples colour from interactivity and learns in-place editing (`--value`/`--selected`). `help`/`enable` get `web_ui_url`. Two seeds are dropped (`timezone`, `session.cookie-secure`) with one-time refresh migrations. Docs follow.

**Tech Stack:** bash 5, snapd `snapctl` (`get -d` = nested JSON), yq (Go v4), gum v0.17.0 (`input --value`, `choose --selected --height`), duplicity, `tests/lib/assert.sh` suites.

**Spec:** `docs/superpowers/specs/2026-11-02-audit-wave2-ux-design.md`

## Global Constraints

- Branch `feat/audit-wave2-ux` in `.claude/worktrees/ci+store-pip-compile` (base: `main` a4da794 merged); one commit per task, subject names the decision/finding (`feat(hook): … (D1/C4)`).
- `shellcheck --severity=warning -x src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh` clean after every task; suites `bash tests/<name>_test.sh` under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`, each ending `N passed, 0 failed`, pristine output.
- CI is ubuntu-26.04 (bash 5.3, newer shellcheck): write `_rc=0; <cond> || _rc=1; assert_status "$_rc"`, never `[ … ]; assert_status "$?"`; never rely on a `VAR=x func` prefix leaking out of a function; every test block sets up its own variables.
- Temp trees the yq snap reads live under `$ROOT/tests/.tmp.*` (gitignored), never `/tmp`.
- Hooks run `DAEMONIZED=1`; `lprint` never receives a secret or a config VALUE from a sanitizer/migration (keys only).
- Hook messages keep the `!! ` prefix; all user-facing texts are the spec's, verbatim.
- Fixture `tests/fixtures/bin/snapctl` stays backward compatible (default behaviour unchanged for `env_wrapper_test.sh`); new behaviour is opt-in via env.
- No change to the SSL env logic beyond D6; no change to duplicity command builders beyond D2's destination and D8's recording.

## Review Focus

1. `snapctl get -d` returning `{}` or garbage (fresh install, snapd hiccup) → `unknown_config_keys` prints nothing and the hook proceeds → Task 2 (U4).
2. A stored VALUE containing dots, `=` or spaces (`mqtt.name=a.b=c d`) must never be reported as an unknown KEY → Task 2 (U5).
3. `server.host` of `::`/`[::]`/an IPv6 address in `web_ui_url` → `<this-machine>` for the any-address forms, `[addr]` otherwise → Task 7 (W4).
4. `$SNAP_COMMON/backup.last` unwritable must not turn a successful backup into a failure → Task 8 (B6).
5. `restore` when the destination cannot be created → one clear error, rc 1, duplicity never invoked → Task 9 (R5).

## File structure

- `src/helper/catalog` — rows (D5/D6 placeholders, shorter descriptions), `validate_config` (+`backup.target`), new `validate_cross_config`, `unknown_config_keys`, `sanitize_config` (+unknown keys, +cross rule).
- `src/helper/functions` — `test_default_config` (−timezone, −cookie-secure), new `migrate_cookie_secure`, `web_ui_url`, `require_root`, plug messages.
- `src/helper/env-wrapper` — cookie follows effective HTTPS when unset.
- `src/hooks/configure`, `src/hooks/post-refresh` — unknown-key rejection, cross rule, cookie migration.
- `src/helper/ui` — `ui_ctx` (NO_COLOR), `ui_ok/warn/err/header` colour flags, `ui_input --value`, `ui_choose --selected/--height`, `ui_pager -RX`, `ui_pause` text.
- `src/bin/ui` — in-place edits, Back-first lists, MQTT warn/restart only when active, plug text, TERM=dumb message, cross rule.
- `src/bin/help`, `src/bin/daemonize` — state line, URL, command rows.
- `src/bin/logs` — legend, usage, picker Back.
- `src/bin/backup` — `backup.last`, status rows, Shipped line, restore destination/`--into`, usage, gpg-public-keys guard, agent message.
- `snap/snapcraft.yaml` (timer 03:00, title, typos), `README.md`, `CLAUDE.md`.
- Tests: `catalog_test`, `hooks_test`, `env_wrapper_test`, `functions_test`, `ui_test`, `ui_nav_test`, `help_test`, `service_cmds_test`, `logs_test`, `backup_test`, `packaging_test`; fixture `snapctl` gains `get -d`, `is-connected` opt-in.

---

### Task 1: Catalog — `backup.target` rule and shorter descriptions (D7, polish)

**Files:** Modify `src/helper/catalog:15,19,44-66`; Test `tests/catalog_test.sh`.

**Interfaces:** `validate_config backup.target <v>`: rc 1 with `!! backup.target must be a duplicity URL like sftp://user@nas/zui, s3://bucket/path or file:///mnt/usb/zui, got <v>` unless `<v>` matches `^[A-Za-z][A-Za-z0-9+.-]*://.+`. Row 15 description becomes `Session secret; unset = the app keeps its own (recommended)`. `backup.full-if-older-than` stays unchecked.

- [ ] **Step 1: Failing tests** (`tests/catalog_test.sh`, before `finish`; `v()` helper exists):
```bash
assert_eq "$(v backup.target sftp://user@nas/zui)" 0 "D7: sftp URL ok"; assert_eq "$(v backup.target file:///mnt/usb/zui)" 0 "D7: file URL ok"
assert_eq "$(v backup.target S3://bucket/x)" 0 "D7: upper-case scheme ok (duplicity accepts)"
assert_eq "$(v backup.target sftp:/nas/zui)" 1 "D7: missing slash rejected"; assert_contains "$(cat "$SNAP_COMMON/err")" "!! backup.target must be a duplicity URL like sftp://user@nas/zui, s3://bucket/path or file:///mnt/usb/zui, got sftp:/nas/zui" "D7: message"
assert_eq "$(v backup.target /mnt/usb/zui)" 1 "D7: bare path rejected"; assert_eq "$(v backup.full-if-older-than 1D12h)" 0 "D7: full-if-older-than unchecked"
_rc=0; [ "$(catalog_field session.secret 4 | wc -c)" -le 64 ] || _rc=1; assert_status "$_rc" 0 "polish: session.secret description ≤ 63 chars"
```
- [ ] **Step 2:** `bash tests/catalog_test.sh` → the four D7 asserts and the length guard FAIL.
- [ ] **Step 3:** add the `backup.target)` case to `validate_config`; shorten row 15's description.
- [ ] **Step 4:** `bash tests/catalog_test.sh && bash tests/help_test.sh && bash tests/hooks_test.sh` → green. Mutation: drop the `://` from the regex → "missing slash rejected" FAILs; restore.
- [ ] **Step 5:** `git commit -am "feat(catalog): validate backup.target as a duplicity URL; shorter session.secret text (D7)"`

---

### Task 2: Unknown keys rejected at `snap set`, removed at refresh (D1/C4)

**Files:** Modify `src/helper/catalog` (new `unknown_config_keys`; `sanitize_config`), `src/hooks/configure`, `tests/fixtures/bin/snapctl`; Test `tests/catalog_test.sh`, `tests/hooks_test.sh`.

**Interfaces:**
- `unknown_config_keys` (catalog): runs `snapctl get -d`, flattens the JSON to dotted leaf paths with yq (e.g. `yq -p=json '.. | select(tag != "!!map" and tag != "!!seq") | path | join(".")'`), prints every path not in `catalog_keys`, one per line; prints nothing and returns 0 when the output is empty, `{}` or not JSON.
- `configure`, after the validation loop: `bad="$(unknown_config_keys | head -n1)"`; when non-empty → stderr `!! unknown setting "<key>" — remove it with: sudo snap unset zwave-js-ui <key>. Known settings: zwave-js-ui.help` and, when the key starts with `mqtt.`, a second line `MQTT broker settings live in settings.json — sudo zwave-js-ui.ui → MQTT broker`; exit 1. (`zwave-js-ui` is `$SNAP_NAME`.)
- `sanitize_config`: after the catalog loop, `for k in $(unknown_config_keys); do snapctl unset "$k" && lprint "$k: removed unknown setting"; done`.
- Fixture `snapctl get -d` (no key argument): prints nested JSON built from every file in `$SNAPCTL_STATE` (key `a.b` → `{"a":{"b":"<content>"}}`, strings only) or `{}`; `SNAPCTL_GET_D_RAW` when set is printed verbatim instead (for the garbage case). Keep `get <key>` as is.

- [ ] **Step 1: Failing tests.** `tests/catalog_test.sh` (stub: `snapctl() { case "$1 ${2:-}" in "get -d") printf '%s' "${SNAPCTL_D:-{}}" ;; get*) …existing… ;; esac; }`):
```bash
SNAPCTL_D='{"server":{"host":"x","prot":"1"},"mqtt":{"host":"y","name":"a.b=c d"},"timezone":"Europe/Oslo"}'
assert_eq "$(unknown_config_keys | sort | tr '\n' ' ')" "mqtt.host server.prot " "U1: unknown leaf paths only"
assert_eq "$(SNAPCTL_D='{}' unknown_config_keys)" "" "U4: empty config -> nothing"; assert_eq "$(SNAPCTL_D='not json' unknown_config_keys 2>/dev/null; echo "rc=$?")" "rc=0" "U4: garbage -> nothing, rc 0"
assert_eq "$(SNAPCTL_D='{"mqtt":{"name":"a.b=c d"}}' unknown_config_keys)" "" "U5: dotted VALUE is not a key"
```
`tests/hooks_test.sh` (append; `reset_state` writes `$SNAPCTL_STATE/<key>` files, so `server.prot=SEKRIT` is a stray key):
```bash
reset_state "${VALID[@]}" server.prot=SEKRIT; run_hook configure; assert_status "$?" 1 "U2: unknown key rejected"
assert_contains "$(cat "$T/stderr")" '!! unknown setting "server.prot" — remove it with: sudo snap unset zwave-js-ui server.prot. Known settings: zwave-js-ui.help' "U2: message"
assert_not_contains "$(cat "$T/stderr")$(cat "$LOGGER_LOG")" "SEKRIT" "U2: value never shown"; assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "U2: no restart"
reset_state "${VALID[@]}" mqtt.host=broker; run_hook configure; assert_contains "$(cat "$T/stderr")" "MQTT broker settings live in settings.json — sudo zwave-js-ui.ui → MQTT broker" "U3: mqtt hint"
reset_state "${VALID[@]}" server.prot=SEKRIT; run_hook post-refresh; assert_status "$?" 0 "U6: post-refresh rc 0"
assert_contains "$(cat "$SNAPCTL_LOG")" "unset server.prot" "U6: stray key unset at refresh"; assert_contains "$(cat "$LOGGER_LOG")" "server.prot: removed unknown setting" "U6: notice"; assert_not_contains "$(cat "$LOGGER_LOG")" "SEKRIT" "U6: value not logged"
: > "$SNAPCTL_LOG"; run_hook configure; assert_status "$?" 0 "U6: configure passes after the refresh cleaned up"
reset_state "${VALID[@]}"; SNAPCTL_GET_D_RAW='garbage' run_hook configure; assert_status "$?" 0 "U4: unreadable get -d does not fail the hook"
```
- [ ] **Step 2:** run both suites → U1–U6 FAIL (`unknown_config_keys: command not found`; configure rc 0 on the stray key).
- [ ] **Step 3:** implement the fixture `get -d`, `unknown_config_keys`, the hook block, the sanitizer loop.
- [ ] **Step 4:** `catalog`, `hooks`, `env_wrapper` suites green; shellcheck clean. Mutation: make `unknown_config_keys` print nothing → U2 FAILs; restore.
- [ ] **Step 5:** `git commit -am "feat(hook): reject unknown snap set keys with the fix, drop them at refresh (D1/C4)"`

---

### Task 3: No seeded `timezone`/`cookie-secure`; cookie follows HTTPS; cross rule (D5, D6)

**Files:** Modify `src/helper/functions` (`test_default_config`, new `migrate_cookie_secure`), `src/helper/catalog` (rows 16, 18; new `validate_cross_config`; `sanitize_config`), `src/helper/env-wrapper:23-31`, `src/hooks/configure`, `src/hooks/post-refresh`, `src/bin/help:11-16`, `tests/help_test.sh:69` (drift list −timezone); Test `catalog`, `functions`, `env_wrapper`, `hooks`, `help` suites.

**Interfaces:**
- Rows: `session.cookie-secure	bool	(follows server.ssl)	Secure session cookie; unset = follows server.ssl	common	daemon`; `timezone	string	(host time)	Timezone for the app (TZ), e.g. America/New_York; unset = the host's zone	common	daemon`.
- `validate_cross_config [key value]`: reads `server.ssl` and `session.cookie-secure` via `snapctl get`, the pending pair overriding; when cookie-secure is `true` and ssl is not `true` → stderr `!! session.cookie-secure=true needs server.ssl=true (secure cookies only work over HTTPS)`, rc 1; else 0.
- `sanitize_config`: when `validate_cross_config` fails → `snapctl unset session.cookie-secure && lprint "session.cookie-secure: removed (needs server.ssl=true)"`.
- `migrate_cookie_secure` (functions): marker `$SNAP_COMMON/.cookie-secure-migrated`; when absent and `session.cookie-secure` equals the current `server.ssl` value (both non-empty) → `snapctl unset session.cookie-secure && lprint "session.cookie-secure: now follows server.ssl (was the install-time copy)"`; marker always written; rc 0.
- `env-wrapper`: `COOKIE_CFG=$(snapctl get session.cookie-secure)`; HTTPS effective = `server.ssl=true` and not force-disabled; when effective: export `USE_SECURE_COOKIE=true` if `COOKIE_CFG` is `true` or empty, unset when `false`; when not effective: unset (as today).
- `configure`: `validate_cross_config || exit 1` after the key loop. `post-refresh`: `migrate_cookie_secure` after `migrate_session_secret`.
- `help settings_rows`: for `session.cookie-secure` with an empty value show `(follows server.ssl: <ssl value>)`.

- [ ] **Step 1: Failing tests.**
`catalog_test`: stub `get` returns `$SNAPCTL_*`; `assert_eq "$(SNAPCTL_server_ssl=false SNAPCTL_session_cookie_secure=true validate_cross_config 2>"$SNAP_COMMON/err"; echo $?)" 1 "X1: cookie true + ssl false rejected"; assert_contains "$(cat "$SNAP_COMMON/err")" "!! session.cookie-secure=true needs server.ssl=true (secure cookies only work over HTTPS)" "X1: message"; assert_eq "$(SNAPCTL_server_ssl=true SNAPCTL_session_cookie_secure=true validate_cross_config; echo $?)" 0 "X1: both true ok"; assert_eq "$(SNAPCTL_server_ssl=false validate_cross_config session.cookie-secure true; echo $?)" 1 "X1: pending pair overrides"; assert_eq "$(catalog_field timezone 3)" "(host time)" "D5 row"; assert_eq "$(catalog_field session.cookie-secure 3)" "(follows server.ssl)" "D6 row"`.
`functions_test`: with the suite's logging stub, `test_default_config` logs no `set timezone` and no `set session.cookie-secure`, still `set server.port=8091`; `migrate_cookie_secure` matrix (equal → unset + notice + marker; differing → no unset, marker; marker present → nothing; `SNAP_COMMON` temp dir).
`env_wrapper_test` (DAEMONIZED unset is fine): `SNAPCTL_server_ssl=true run_wrapper` contains `USE_SECURE_COOKIE=true` (E6 follows); `SNAPCTL_server_ssl=true SNAPCTL_session_cookie_secure=false` → absent (E7 opt-out); `SNAPCTL_server_ssl=false` → absent (E8); `SNAPCTL_server_ssl=true SNAPCTL_server_force_disable_ssl=true` → absent (E9).
`hooks_test`: `reset_state server.port=8091 server.ssl=false session.cookie-secure=true; run_hook configure` → rc 1, stderr has the X1 message (P5); post-refresh with `server.ssl=false session.cookie-secure=false` → `unset session.cookie-secure` logged, marker exists (P6a); with `server.ssl=false session.cookie-secure=true` → the sanitizer unsets it (P6b, notice `session.cookie-secure: removed (needs server.ssl=true)`); second post-refresh run with the marker and `cookie-secure=false` again → no unset (P6c); `set timezone` never logged by configure or post-refresh (P7).
`help_test`: `SNAPCTL_server_ssl=true SNAPCTL_session_cookie_secure='' settings_rows` contains `(follows server.ssl: true)`; drift list drops `timezone`.
- [ ] **Step 2:** run the five suites → new asserts FAIL.
- [ ] **Step 3:** implement per the Interfaces block (VALID in hooks_test keeps `session.cookie-secure=false` — fine, it is now a stored explicit value).
- [ ] **Step 4:** all five suites + `ui_nav` green; shellcheck clean. Mutation: remove the `validate_cross_config` call from `configure` → P5 FAILs; restore.
- [ ] **Step 5:** `git commit -am "feat(config): stop seeding timezone and cookie-secure; cookie follows HTTPS; cross-key rule (D5, D6)"`

---

### Task 4: UI library — colour vs widgets, in-place inputs, pager, pause (D3, D4-lib, D9, polish)

**Files:** Modify `src/helper/ui` (`ui_ctx`, `ui_header/ok/warn/err`, `ui_pager`, `ui_pause`, `ui_choose`, `ui_input`); Test `tests/ui_test.sh:40,103,214-244`.

**Interfaces:**
- `ui_ctx`: `NO_COLOR` no longer forces plain (TTY + gum → `styled`); `TERM=dumb` still plain. Header comment updated.
- `ui_header/ui_ok/ui_warn/ui_err`: when `NO_COLOR` is set, omit `--foreground N` / `--border-foreground N` from the gum call (glyphs stay).
- `ui_pager`: `less -RX`.
- `ui_pause`: text `  — press Enter to continue —` (still `read -rsn1`).
- `ui_input [--password] [--value <v>] <prompt>`: passes `--value "$v"` to gum; non-interactive path unchanged.
- `ui_choose [--selected <v>] <prompt> <hint> <items…>`: passes `--selected "$v"` when given and always `--height H` where `H = ui_lines − 6`, minimum 5.
- `ui_ctx`'s doc block and the file header reflect: plain = no TTY / `TERM=dumb` / no gum; `NO_COLOR` = no colour.

- [ ] **Step 1: Failing tests** (`ui_test.sh`): change line 40 to expect `styled`; add `assert_not_contains "$(UI_ASSUME_TTY=1 NO_COLOR=1 ui_ok x; tail -1 "$GUM_LOG")" "--foreground" "NO_COLOR: no colour flag to gum"`; `assert_contains "$(UI_ASSUME_TTY=1 ui_ok x; tail -1 "$GUM_LOG")" "--foreground 2" "colour flag without NO_COLOR"`; `UI_ASSUME_TTY=1 UI_LINES=20 ui_choose --selected b 'P' '' a b >/dev/null; assert_contains "$(tail -1 "$GUM_LOG")" "--selected b" …; assert_contains … "--height 14"`; `UI_LINES=8` → `--height 5`; `UI_ASSUME_TTY=1 ui_input --value cur 'P' >/dev/null; tail -1 "$GUM_LOG"` contains `--value cur`; `--password` without `--value` has no `--value`; pager test asserts `-RX` in `LESS_LOG`; `ui_pause` text under `UI_ASSUME_TTY=1` with `UI_NO_PAUSE` unset and stdin `</dev/null`… (keep: assert the new wording appears via `UI_ASSUME_TTY=1 ui_pause 2>&1 </dev/null` — `read` fails immediately on EOF, `|| true` keeps rc 0). Update line 103's exact-argv assertion to `assert_contains … "choose --header Follow which logs?"` and `… "all zui zwjs"`.
- [ ] **Step 2:** `bash tests/ui_test.sh` → new/changed asserts FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** `ui`, `ui_nav`, `help`, `backup`, `logs` suites green; shellcheck clean.
- [ ] **Step 5:** `git commit -am "feat(ui): NO_COLOR keeps widgets, in-place input/choose, pager keeps output, Enter to continue (D3, D4, D9)"`

---

### Task 5: Navigator — in-place edits, Back first, honest MQTT section, TERM=dumb text (D4, D15, D6 parity)

**Files:** Modify `src/bin/ui` (`nav_settings`, `nav_set_apply`, `nav_service`, `nav_plugs`, `nav_logs`, `nav_mqtt`, `main`); Test `tests/ui_nav_test.sh`.

**Interfaces:**
- `nav_settings`: header `Setting`; items list starts with `← Back`; Edit of a bool → `ui_choose --selected "$cur" "$key =" "" true false`; string/int → `ui_input --value "$cur" "$key = "` (secret → `ui_input --password "$key = "`, no value). `nav_set_apply` runs `validate_cross_config "$key" "$val"` after `validate_config` (same rejection banner).
- `nav_service`, `nav_plugs`, `nav_mqtt`: `← Back` first in every `ui_choose` list. `nav_logs`: items `← Back all zui zwjs`; Back returns.
- `nav_mqtt`: the `ui_warn "Editing settings.json…"` and the restart offer only when `service_state` ends in ` active`; otherwise `ui_print "Takes effect when the service starts."` after a write.
- `nav_plugs` purpose for `hardware-observe`: `required — detects the controller; pair with raw-usb or serial-port`.
- `main`: before the interactivity check, `if [ "${TERM:-}" = dumb ]; then ui_print "$SNAP_NAME.ui needs a terminal that can draw menus (TERM=dumb) — use the $SNAP_NAME.* commands, or run with a different TERM" >&2; return 2; fi`.

- [ ] **Step 1: Failing tests** (`ui_nav_test.sh`, Settings stub section): edit `server.host` with `SNAPCTL_server_host=10.0.0.7` → GUM_LOG line contains `input --value 10.0.0.7 --header server.host = ` (N10); secret edit → no `--value` (N11); bool edit with `SNAPCTL_server_ssl=false` → `choose --selected false` (N12); first item after `--header Setting` is `← Back` (N13); `SNAPCTL_server_ssl=false` + edit `session.cookie-secure` → `true` → rejected with the cross message, no `set` logged (N14); `nav_mqtt` with `SNAPCTL_MAIN_STATE=inactive` → output lacks `Editing settings.json`, GUM_LOG lacks `confirm`, contains `Takes effect when the service starts.` (N15); `TERM=dumb main` → rc 2 and the new message (N16); `nav_logs` choosing `← Back` → no `RAN_logs` (N17). Keep existing N1–N9.
- [ ] **Step 2:** run → FAIL.  - [ ] **Step 3:** implement.  - [ ] **Step 4:** `ui_nav`, `ui` green; shellcheck. Mutation: drop `--value` → N10 FAILs.
- [ ] **Step 5:** `git commit -am "feat(ui): navigator edits in place, Back first, MQTT section honest about state (D4, D15)"`

---

### Task 6: Messages — root, plugs, logs legend and picker (D12, D11, D15)

**Files:** Modify `src/helper/functions` (`require_root`, `plug_connected`, `plugs_connected`), `src/bin/logs:13,20-22,202,215`; Test `tests/functions_test.sh`, `tests/logs_test.sh`.

**Interfaces:**
- `require_root`: one line on stderr, exit 1: `$SNAP_NAME: this command must run as root — re-run with sudo.` *(Ruling: the spec's `<command>` needs an app name snapd does not export and bin names differ from app names, so the generic form is used.)*
- `plug_connected`: `Missing interface: <plug>` / `Connect with:` / `sudo snap connect <snap>:<plug>` (serial-port keeps ` <slot name>`); no `$ `, no guillemets.
- `plugs_connected` when both alternatives are missing: `Connect raw-usb (USB stick) OR serial-port (see <snap>.help):` then `$RAW_OUT`, then `$SERIAL_OUT`; no `----- OR -----`, no trailing "See … help" line.
- `logs` usage: `(no arg)        follow both streams (on a terminal: asks which)`; legend `Ctrl-C  pause following (then scroll, search…)` / `F       resume live following` / `q       quit (after Ctrl-C)`; hint line `──── live logs · Ctrl-C: pause · F: resume · q: quit (after Ctrl-C) ────`; picker items `← Back all zui zwjs`, Back → exit 0 quietly.

- [ ] **Step 1: Failing tests.** `functions_test`: `out="$( (require_root) 2>&1 >/dev/null )"; rc=$?` as the non-root test user → rc 1, `out` = `zwave-js-ui: this command must run as root — re-run with sudo.`, stdout empty; A7 block updated: `Missing interface: raw-usb`, header `Connect raw-usb (USB stick) OR serial-port (see zwave-js-ui.help):`, not contains `----- OR` nor `$ sudo` nor `«`. `logs_test`: usage contains `q       quit (after Ctrl-C)` and `(on a terminal: asks which)`; hint contains `q: quit (after Ctrl-C)`; bare run on a stubbed TTY choosing `← Back` → rc 0, no follower (reuse the suite's existing picker harness).
- [ ] **Step 2:** FAIL.  - [ ] **Step 3:** implement.  - [ ] **Step 4:** `functions`, `logs`, `service_cmds`, `env_wrapper` green; shellcheck.
- [ ] **Step 5:** `git commit -am "fix(messages): one-line root error, plain interface messages, truthful logs legend (D11, D12, D15)"`

---

### Task 7: `help` and `enable` show state and URL; sudo in the command table (D13, D14)

**Files:** Modify `src/helper/functions` (new `web_ui_url`), `src/bin/help:19-36`, `src/bin/daemonize:15-21`; Test `tests/functions_test.sh`, `tests/help_test.sh`, `tests/service_cmds_test.sh`.

**Interfaces:**
- `web_ui_url`: scheme `https` when `server.ssl=true` and `server.force-disable-ssl` is not `true`, else `http`; host = `server.host` unless empty, `0.0.0.0`, `::` or `[::]` → `<this-machine>`; an IPv6 literal (contains `:`) is bracketed; port = `server.port` or `8091`. Prints `scheme://host:port`.
- `help` opening block by `service_state`: `*" active"` → `Running — web UI: <url>   stop: sudo <snap>.disable`; `enabled inactive` → `Enabled but not running — see: sudo <snap>.logs`; otherwise today's two lines.
- `commands_rows` exactly: `sudo <snap>.enable	start the service now and at every boot` / `sudo <snap>.disable	stop it and do not start at boot` / `sudo <snap>.restart	restart the service` / `sudo <snap>.exec	run in the foreground (debug start-up)` / `sudo <snap>.ui	interactive navigator — settings, service, interfaces, logs` / `sudo <snap>.logs [zui|zwjs]	follow live logs (merged by default)` / `<snap>.backup ...	ship backups off-box (see --help; most need sudo)` / `<snap>.help	this overview (no sudo)`.
- `daemonize`: after `ui_ok "Service enabled"`, `ui_print "Web UI: $(web_ui_url)"`; next-steps table gains `interactive navigator	sudo <snap>.ui`.

- [ ] **Step 1: Failing tests.** `functions_test` (stub `get` from env): `SNAPCTL_server_host=0.0.0.0 SNAPCTL_server_port=8091 web_ui_url` = `http://<this-machine>:8091` (W1); `SNAPCTL_server_host=10.0.0.7 SNAPCTL_server_ssl=true` → `https://10.0.0.7:8091` (W2); `…ssl=true force_disable_ssl=true` → `http://…` (W3); `SNAPCTL_server_host=::` → `<this-machine>`; `SNAPCTL_server_host=fd00::1` → `http://[fd00::1]:8091` (W4). `help_test`: default stub (`enabled active`) → `main` contains `Running — web UI: http://<this-machine>:8091   stop: sudo zwave-js-ui.disable` and not `DISABLED`; stub with `disabled inactive` → contains `DISABLED`; `enabled inactive` → `Enabled but not running — see: sudo zwave-js-ui.logs`; `commands_rows` contains `sudo zwave-js-ui.enable	start the service now and at every boot` and `zwave-js-ui.help	this overview (no sudo)` and no `…` (U+2026). `service_cmds_test`: daemonize output contains `Web UI: http://` and `sudo zwave-js-ui.ui`.
- [ ] **Step 2:** FAIL.  - [ ] **Step 3:** implement.  - [ ] **Step 4:** `functions`, `help`, `service_cmds`, `ui_nav` green; shellcheck.
- [ ] **Step 5:** `git commit -am "feat(help): show running state and web UI address; sudo-marked command table (D13, D14)"`

---

### Task 8: `backup status` answers "did it run"; timer 03:00; Shipped line (D8, C22)

**Files:** Modify `src/bin/backup` (new `record_last_run`, `last_run_row`, `redact_url`; `cmd_status`; main `backup` branch), `snap/snapcraft.yaml:136`; Test `tests/backup_test.sh`, `tests/packaging_test.sh`.

**Interfaces:**
- `record_last_run <ok|failed|skipped> <detail>` → writes `$SNAP_COMMON/backup.last` as `<UTC ISO-8601> <state> <detail>` with mode 0600 (`umask 077` subshell, then `chmod 600`); failure to write only `ui_print`s a notice to stderr, rc 0.
- Main `backup`: nothing to back up → `record_last_run skipped nothing-to-back-up` then the existing message, exit 0; after the duplicity eval: success → `record_last_run ok 0`, then `ui_ok "Shipped $(backup_dir) to $(redact_url "$target")"`; failure → `record_last_run failed <rc>` then the existing error. *(Ruling: the Shipped line carries no full/incremental type — D8 records the outcome from the exit status alone.)* `redact_url` replaces `//user[:pass]@` with `//<redacted>@`.
- `cmd_status` rows: `last run` → `not configured` when `backup.target` is empty; `never` when the file is missing; else `YYYY-MM-DD HH:MM UTC  OK` / `… FAILED (rc N) — see: sudo snap logs <snap>.backup-timer` / `… skipped (nothing in <dir> — enable ZUI's scheduled backups)`. Timer row: Startup `enabled` → `enabled — runs daily at 03:00 (idle between runs)`, else `disabled`. Key row label `private key in snap keyring`: `yes` / `no (public key only — restore needs the private key)` when a key is set / `-` when none.
- `snapcraft.yaml` `backup-timer.timer: "03:00"`.

- [ ] **Step 1: Failing tests** (`backup_test.sh`; `DUP_PY` stub script under `$SNAP_COMMON/dup.sh` that exits `${DUP_RC:-0}` and prints a statistics line; set `DUP_PY="$SNAP_COMMON/dup.sh"`, backup dir with one file, `SNAPCTL_backup_target=sftp://u:p@nas/zui SNAPCTL_backup_encrypt=false`): `main backup` → `backup.last` matches `^[0-9T:-]+Z ok 0$`, mode 600, output contains `Shipped … to sftp://<redacted>@nas/zui` and not `u:p@` (B1); `DUP_RC=23` → `failed 23` and rc 1 (B2); empty dir → `skipped nothing-to-back-up`, rc 0 (B3); `cmd_status` renders each of the three states and `never`/`not configured` (B4); timer row and key row texts (B5); `SNAP_COMMON=/nonexistent` → backup still rc 0 (B6). `packaging_test`: `yq '.apps.backup-timer.timer' = "03:00"`. Update the two existing `private key on this device` greps to the new label.
- [ ] **Step 2:** FAIL.  - [ ] **Step 3:** implement.  - [ ] **Step 4:** `backup`, `packaging` green; shellcheck. Mutation: skip `record_last_run ok` → B1 FAILs.
- [ ] **Step 5:** `git commit -am "feat(backup): record and show the last run, timer at 03:00, Shipped summary (D8, C22)"`

---

### Task 9: `restore` into a fresh directory, `--into`, documented `<time>` (D2/C5)

**Files:** Modify `src/bin/backup` (usage, `main` restore branch, new `restore_dest`); Test `tests/backup_test.sh`.

**Interfaces:**
- Args after `restore`: `--into <dir>` anywhere; the remaining positional is `<time>`.
- `restore_dest [--into dir]`: default `$SNAP_DATA/restored/<UTC YYYYMMDD-HHMMSS>`; when `$(backup_dir)` equals `$SNAP_DATA`, `$SNAP_COMMON/restored/<stamp>` instead (and the final message says so). With `--into`: `mkdir -p`; refuse when non-empty: `<dir> is not empty — choose an empty directory`, exit 1. If the destination cannot be created: `Cannot create <dir>`, exit 1, duplicity not invoked.
- Success message (default destination): `✓ Restored into <dir> — the files are in ZUI's store browser under restored/; download the one you need and use ZUI's restore (NVM or store).`; with `--into` or the `$SNAP_COMMON` fallback: `✓ Restored into <dir>.`
- Usage: `restore [<time>] [--into <dir>]   fetch+decrypt a backup into a fresh folder (default: \$SNAP_DATA/restored/<stamp>)` and a line `<time>      e.g. 2026-10-30, 2026-10-30T02:00, 3D (three days ago)`.

- [ ] **Step 1: Failing tests** (`DUP_PY` stub records argv to `$SNAP_COMMON/dup.argv`): `main restore` → last argv word matches `/restored/[0-9]{8}-[0-9]{6}$` under `$SNAP_DATA` and the dir exists (R1); `main restore 3D` → argv contains `--time 3D` (R2); `main restore --into "$SNAP_COMMON/empty"` → argv ends with that dir (R3); `--into` on a non-empty dir → rc 1, message, `dup.argv` untouched (R4); `SNAP_DATA=/proc/none` → `Cannot create`, rc 1, duplicity not invoked (R5); `SNAPCTL_backup_dir="$SNAP_DATA"` → destination under `$SNAP_COMMON/restored/` (R6); usage contains `3D (three days ago)`.
- [ ] **Step 2:** FAIL.  - [ ] **Step 3:** implement.  - [ ] **Step 4:** `backup` green; shellcheck.
- [ ] **Step 5:** `git commit -am "feat(backup): restore into a fresh restored/<stamp> folder, --into, documented <time> (D2/C5)"`

---

### Task 10: Name the missing `gpg-public-keys` interface; honest agent error (D10, D15)

**Files:** Modify `src/bin/backup` (`require_host_keyring`, `ensure_agent` message, usage); Test `tests/backup_test.sh`.

**Interfaces:**
- `require_host_keyring`: before the directory check, `snapctl is-connected gpg-public-keys` (non-root allowed); on failure `ui_err "The gpg-public-keys interface is not connected, so your ~/.gnupg is not visible to the snap. Run: sudo snap connect <snap>:gpg-public-keys"`, exit 1.
- `ensure_agent` failure text: `could not start gpg-agent — on kernel 6.17+ this is snap confinement's AF_UNIX mediation; otherwise see: sudo snap logs <snap>`.
- Usage: under `list-keys`/`pick-key` add `(needs: sudo snap connect <snap>:gpg-public-keys)`.
- Fixture/suite stubs: `is-connected` → rc from `SNAPCTL_CONNECTED` when set (space-separated plugs), else 0.

- [ ] **Step 1: Failing tests:** suite stub `snapctl() { case "$1" in is-connected) [ -z "${SNAPCTL_CONNECTED+x}" ] || case " $SNAPCTL_CONNECTED " in *" $2 "*) return 0;; *) return 1;; esac ;; … esac; }`; `SNAPCTL_CONNECTED='' (require_host_keyring list-keys)` → rc 1 and the message (G1); connected but no `~/.gnupg` → existing message (G2); `ensure_agent` with `gpg-agent`/`gpg-connect-agent` stubs failing → new text (G3); usage contains `gpg-public-keys` (G4).
- [ ] **Step 2:** FAIL.  - [ ] **Step 3:** implement.  - [ ] **Step 4:** `backup` green; shellcheck.
- [ ] **Step 5:** `git commit -am "fix(backup): say when gpg-public-keys is not connected; honest gpg-agent error (D10, D15)"`

---

### Task 11: Docs and packaging text (C23, D10, D15, CLAUDE.md)

**Files:** Modify `README.md` (Snap-Specific Features → command table + Configuration; Interfaces + connect examples), `snap/snapcraft.yaml:2,20,30,40,43`, `CLAUDE.md`; Test `tests/packaging_test.sh`.

**Interfaces:**
- README "Snap-Specific Features" → `## Commands` with a table of the eight `help` rows (D14 wording) and `## Configuration`: namespaces `server.*`, `session.*`, `mqtt.name`, `timezone`, `backup.*`, `zwave.*` with one `sudo snap set zwave-js-ui <key>=<value>` example each, the sentence `Only mqtt.name is snap config; the broker (host, port, user, password) lives in settings.json — edit it with sudo zwave-js-ui.ui → MQTT broker`, and `Unknown keys are rejected; sudo snap unset zwave-js-ui <key> restores a default.`
- Interfaces: bullet `gpg-public-keys (manual) — lets zwave-js-ui.backup list-keys/pick-key read your ~/.gnupg; without it they say so and print the connect command.`; connect examples add `sudo snap connect zwave-js-ui:log-observe` and `sudo snap connect zwave-js-ui:gpg-public-keys`.
- `snapcraft.yaml`: `title: Z-Wave JS UI`; `MQTT apis`→`MQTT APIs`; `integation`→`integration`; `full-fledge`→`full-fledged`; `«store-folder»`→`"store folder"`; `Z-wave`→`Z-Wave`.
- CLAUDE.md: timer `03:00`; `timezone`/`session.cookie-secure` no longer seeded (cookie follows HTTPS, one-time migration marker); unknown keys rejected by `configure` and removed by `sanitize_config`; `restore` destination; `backup.last`; `NO_COLOR` keeps widgets; `web_ui_url`; `help`'s state line.

- [ ] **Step 1: Failing guards** (`packaging_test`): every `zwave-js-ui.<cmd>` for cmd in enable disable restart exec ui logs backup help appears in README; README contains `gpg-public-keys`, `snap unset zwave-js-ui <key>`; `yq '.title' = "Z-Wave JS UI"`; description lacks `integation`, `full-fledge`, `MQTT apis`, `«`; CLAUDE.md contains `03:00`, `restored/`, `unknown_config_keys`.
- [ ] **Step 2:** FAIL.  - [ ] **Step 3:** edit.  - [ ] **Step 4:** `packaging` green.
- [ ] **Step 5:** `git commit -am "docs: commands and configuration in README, gpg-public-keys, store title and typos, CLAUDE.md for wave 2 (C23, D15)"`

---

### Task 12: Whole-branch verification

- [ ] Run all suites under the lock and shellcheck: eleven suites `0 failed`, `shellcheck: clean`; `yq '.' snap/snapcraft.yaml >/dev/null`; `git status --short` empty; no `tests/.tmp.*` left.
- [ ] `git fetch -q origin && git merge --no-edit origin/main` → clean; re-run `hooks` and `backup` suites.
