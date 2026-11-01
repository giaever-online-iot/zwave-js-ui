# Package audit wave 1 (defects) — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the audit's confirmed defects in the snap wrapper: config changes reach the daemon again (hook and navigator), unset means default, no seeded session secret, no journal plug on the daemon, a working backup key flow, and docs that match the code.

**Architecture:** The settings catalog (`src/helper/catalog`) becomes the single source for *type*, *default* and *who consumes a key* (`applies`), and grows the validator and the daemon-config digest both the `configure` hook and the navigator use. `env-wrapper` records the digest of what the daemon started with; the hook restarts only on a difference. The backup key subcommands move every secret-key operation to loopback pinentry with the passphrase on a file descriptor and make `export-key` pipe-only. Hooks get their first process-level test suite, driven by a stateful fixture `snapctl`.

**Tech Stack:** bash 5, snapd `snapctl`, yq (snap), GnuPG 2.4, gum (stubbed in tests), shellcheck. Tests are the repo's zero-dependency `tests/lib/assert.sh` suites.

**Spec:** `docs/superpowers/specs/2026-11-01-audit-wave1-defects-design.md`

## Global Constraints

- Branch `fix/audit-wave1-defects` in the worktree `.claude/worktrees/ci+store-pip-compile`; one commit per finding, subject carries the finding id, e.g. `fix(hook): … (A1, A3)`.
- `shellcheck --severity=warning -x src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh` must stay clean after every task.
- Run suites as `bash tests/<name>_test.sh` under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`; a suite ends with `finish` and prints `N passed, 0 failed`.
- The fixture `tests/fixtures/bin/snapctl` keeps today's default behaviour (`get` echoes `$SNAPCTL_<key>`, everything else a quiet no-op) unless a test opts in via the new env vars; `env_wrapper_test.sh` must pass unchanged by Task 3.
- Temp files that the **yq snap** must read live under `$ROOT/tests/.tmp.XXXXXX` (gitignored by Task 3), never `/tmp`.
- Hooks run with `DAEMONIZED=1`: no secret value may reach `lprint`.
- Validation message format, verbatim: `!! <key> must be <rule>, got <value>` on stderr; rules: `a whole number`, `true or false`, `a port number 1-65535`, `an absolute path`.
- Do not touch: the SSL/secure-cookie logic in `env-wrapper`, the duplicity command builders, `src/bin/logs`, the June spec documents.
- Digest file: `$SNAP_COMMON/.daemon-config.sha256`, mode 0600, content = 64 hex chars + newline.

## Review Focus

1. A value with spaces or `=` (`mqtt.name=my client=1`) must pass the hook unchanged and unrejected → test in Task 3 (C7).
2. `snapctl services` failing inside the hook (`service_state` → `unknown`) must mean "no restart", not a `set -e` abort → Task 3 (C8).
3. An unwritable `$SNAP_COMMON` must not stop the daemon from starting; a garbage digest file must read as "differs" → Task 2 (E4) and Task 3 (C9).
4. Resetting `session.cookie-secure` must re-seed it from the *current* `server.ssl`, not a literal → Task 6 (N7).
5. `export-key` on a public-only key must exit 0 with "nothing to export" before asking for a passphrase → Task 8 (X5).

## File structure

- `src/helper/catalog` — TSV catalog (now 6 columns) + `catalog_field`, `catalog_keys_for`, `validate_config`, `daemon_config_digest`, `daemon_digest_file`.
- `src/helper/functions` — `plugs_connected` (quiet buffering), `test_device_priority_dir` (null-safe), `test_default_config` (no session.secret), new `migrate_session_secret`.
- `src/helper/env-wrapper` — conditional `SESSION_SECRET`, writes the digest.
- `src/hooks/configure` — seed → validate → restart-on-change. `src/hooks/post-refresh` — migration, fixed-path `rm`.
- `src/bin/ui` — `nav_settings`/`nav_set_apply` per D3. `src/helper/ui` — `ui_stack` tolerant of empty fields. `src/bin/help` — 6-field rows.
- `src/bin/backup` — `cmd_create_key`, `cmd_export_key`, `cmd_import_key`, `cmd_status`, new `secret_key_on_disk`.
- `snap/snapcraft.yaml`, `.github/workflows/lint-test.yml`, `README.md`, `CLAUDE.md`.
- Tests: new `tests/catalog_test.sh`, `tests/hooks_test.sh`, `tests/packaging_test.sh`; extended `tests/env_wrapper_test.sh`, `tests/functions_test.sh`, `tests/ui_nav_test.sh`, `tests/ui_test.sh`, `tests/backup_test.sh`, `tests/help_test.sh`; extended fixture `tests/fixtures/bin/snapctl`.

---

### Task 1: Catalog — `applies` column, field helpers, validator, digest

**Files:**
- Modify: `src/helper/catalog`
- Modify: `src/bin/help:8-16` (`settings_rows`)
- Modify: `tests/help_test.sh:22-25` (field-count guard)
- Create: `tests/catalog_test.sh`

**Interfaces:**
- Produces (all in `src/helper/catalog`, sourced after `functions`; they call `snapctl` and nothing else):
  - `settings_catalog` rows: `key	type	default	description	scope	applies`, `applies ∈ {daemon, backup}`; no field is ever empty.
  - `catalog_field <key> <n>` → prints field `n` (1 key, 2 type, 3 default, 4 description, 5 scope, 6 applies), empty for an unknown key. Implemented with `awk -F'\t'`, never `read`.
  - `catalog_keys_for <daemon|backup>` → newline-separated keys with that `applies`.
  - `validate_config <key> <value>` → rc 0 when valid, rc 1 and the message on stderr otherwise. Empty value → 0. Unknown key → 0. `int` → `^[0-9]+$` else `a whole number`; `bool` → `true|false` else `true or false`; then per key: `server.port` must be 1..65535 else `a port number 1-65535`; `backup.dir` must start with `/` else `an absolute path`.
  - `daemon_config_digest` → sha256 (64 hex) of `printf '%s=%s\n' key value` for every `daemon` key in catalog order, values from `snapctl get <key>`.
  - `daemon_digest_file` → prints `${SNAP_COMMON}/.daemon-config.sha256`.

- [ ] **Step 1: Write `tests/catalog_test.sh` (failing)**

Harness like `tests/functions_test.sh`: `set -u`, `HERE`/`ROOT`, `source "$HERE/lib/assert.sh"`, `export SNAP="$HERE/fixtures"`, `SNAP_COMMON="$(mktemp -d)"; export SNAP_COMMON`, `snapctl() { case "$1" in get) local k="${2//[.-]/_}"; eval "printf '%s' \"\${SNAPCTL_${k}:-}\"" ;; *) : ;; esac; }`, then `source "$ROOT/src/helper/catalog"`. Assertions:

```bash
settings_catalog | awk -F'\t' 'NF != 6 { exit 1 }';                       assert_status "$?" 0 "every row has 6 fields"
settings_catalog | awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i=="") exit 1 }'; assert_status "$?" 0 "no empty field in any row"
settings_catalog | awk -F'\t' '$6!="daemon" && $6!="backup" { exit 1 }';   assert_status "$?" 0 "applies is daemon|backup"
assert_eq "$(catalog_field server.port 2)" "int"      "catalog_field: type"
assert_eq "$(catalog_field server.port 6)" "daemon"   "catalog_field: server.port applies daemon"
assert_eq "$(catalog_field backup.target 6)" "backup" "catalog_field: backup.target applies backup"
assert_eq "$(catalog_field backup.dir 6)" "daemon"    "catalog_field: backup.dir applies daemon (BACKUPS_DIR)"
assert_eq "$(catalog_field zwave.serial-port 5)" "advanced" "catalog_field: scope survives (A6)"
[ -n "$(catalog_field zwave.serial-port 4)" ]; assert_status "$?" 0 "zwave.serial-port has a description (A6)"
assert_eq "$(catalog_field nope 2)" "" "catalog_field: unknown key -> empty"
assert_eq "$(catalog_keys_for backup)" "$(printf 'backup.target\nbackup.encrypt\nbackup.encrypt-key\nbackup.full-if-older-than\nbackup.retention')" "keys_for backup"
assert_eq "$(catalog_keys_for daemon | grep -c .)" "16" "keys_for daemon: 8 common + backup.dir + 7 zwave"
v() { validate_config "$1" "$2" 2>"$SNAP_COMMON/err"; echo "$?"; }   # prints rc; message in err
assert_eq "$(v server.port 8091)" 0 "port ok";   assert_eq "$(v server.port 65535)" 0 "port max ok"
assert_eq "$(v server.port abc)" 1 "port abc";   assert_contains "$(cat "$SNAP_COMMON/err")" "!! server.port must be a whole number, got abc" "port abc message"
assert_eq "$(v server.port 0)" 1 "port 0";       assert_contains "$(cat "$SNAP_COMMON/err")" "a port number 1-65535" "port range message"
assert_eq "$(v server.port 70000)" 1 "port 70000"
assert_eq "$(v server.ssl yes)" 1 "bool yes";    assert_contains "$(cat "$SNAP_COMMON/err")" "!! server.ssl must be true or false, got yes" "bool message"
assert_eq "$(v server.ssl false)" 0 "bool ok";   assert_eq "$(v backup.encrypt false)" 0 "backup.encrypt bool ok"
assert_eq "$(v backup.retention 3)" 0 "retention ok"; assert_eq "$(v backup.retention x)" 1 "retention x"
assert_eq "$(v backup.dir relative/x)" 1 "dir rel"; assert_contains "$(cat "$SNAP_COMMON/err")" "!! backup.dir must be an absolute path, got relative/x" "dir message"
assert_eq "$(v backup.dir /srv/x)" 0 "dir abs ok"; assert_eq "$(v server.port '')" 0 "empty = default";  assert_eq "$(v timezone 'Any/Thing')" 0 "string ok"; assert_eq "$(v not.a.key 1)" 0 "unknown key passes"
d1="$(SNAPCTL_server_host=10.0.0.7 daemon_config_digest)"
[[ "$d1" =~ ^[0-9a-f]{64}$ ]]; assert_status "$?" 0 "digest is sha256 hex"
assert_eq "$(SNAPCTL_server_host=10.0.0.7 daemon_config_digest)" "$d1" "digest deterministic"
[ "$(SNAPCTL_server_host=10.0.0.8 daemon_config_digest)" != "$d1" ]; assert_status "$?" 0 "digest changes with a daemon key"
assert_eq "$(SNAPCTL_server_host=10.0.0.7 SNAPCTL_backup_target=file:///x daemon_config_digest)" "$d1" "digest ignores backup-only keys"
assert_eq "$(daemon_digest_file)" "$SNAP_COMMON/.daemon-config.sha256" "digest file path"
finish
```

- [ ] **Step 2: Run it, expect failure**

Run: `bash tests/catalog_test.sh`
Expected: FAIL lines (`NF != 6`, `catalog_field: command not found`, …), non-zero exit.

- [ ] **Step 3: Implement the catalog**

In `src/helper/catalog`: update the header comment (6 columns; `applies: daemon | backup — who reads the key: daemon = env-wrapper exports it, backup = bin/backup reads it at run time`). Append `	daemon` to every row except the five `backup.*` keys other than `backup.dir`, which get `	backup`. Replace the empty descriptions of the seven `zwave.*` rows with, in order: `Serial device of the Z-Wave controller (ZWAVE_PORT)`, `S2 Unauthenticated network key (KEY_S2_Unauthenticated)`, `S2 Authenticated network key (KEY_S2_Authenticated)`, `S2 Access Control network key (KEY_S2_AccessControl)`, `S2 Long Range Authenticated key (KEY_LR_S2_Authenticated)`, `S2 Long Range Access Control key (KEY_LR_S2_AccessControl)`, `S0 Legacy network key (KEY_S0_Legacy)`. Add the five functions with the signatures above (`validate_config` reads the type via `catalog_field`; `daemon_config_digest` pipes into `sha256sum | cut -d' ' -f1`).

- [ ] **Step 4: Six-field rows in `help`, guard in `help_test`**

`src/bin/help:10`: `while IFS=$'\t' read -r key type def desc scope applies; do` (the catalog guarantees no empty field, so `read` is safe here; `applies` unused — add `# shellcheck disable=SC2034` on that line). `tests/help_test.sh:24-25`: `NF != 6` and message `every catalog row has exactly 6 fields`.

- [ ] **Step 5: Run, expect pass; then mutation-check**

Run: `bash tests/catalog_test.sh && bash tests/help_test.sh && bash tests/ui_nav_test.sh`
Expected: all `… 0 failed`.
Mutation: comment out the `server.port` range check in `validate_config`, run `bash tests/catalog_test.sh` → the `port 0`/`port 70000` asserts FAIL; restore; green again.

- [ ] **Step 6: Commit**

```bash
git add src/helper/catalog src/bin/help tests/catalog_test.sh tests/help_test.sh
git commit -m "feat(catalog): applies column, shared validate_config and daemon config digest (A2/A3 groundwork, A6)"
```

---

### Task 2: `env-wrapper` records the daemon's config digest

**Files:**
- Modify: `src/helper/env-wrapper:3` (source catalog), `:59-67` (digest before `exec`)
- Modify: `tests/env_wrapper_test.sh`

**Interfaces:**
- Consumes: `daemon_config_digest`, `daemon_digest_file` (Task 1). `env-wrapper` must `source "$SNAP/helper/catalog"` right after `functions` (the fixture shim `tests/fixtures/helper/catalog` already loads the real one).
- Produces: the digest file, written on every start, 0600, in a subshell so the daemon's umask is untouched; a write failure only `lprint`s `Could not record the config digest in <path>` and the `exec` still happens.

- [ ] **Step 1: Extend `tests/env_wrapper_test.sh` (failing)**

After the existing setup add `SNAP_COMMON="$(mktemp -d)"; export SNAP_COMMON` (and it to the `trap`), then:

```bash
DF="$SNAP_COMMON/.daemon-config.sha256"
SNAPCTL_server_host=10.0.0.7 run_wrapper >/dev/null
[ -f "$DF" ]; assert_status "$?" 0 "E1: digest file written at start"
assert_eq "$(stat -c %a "$DF")" "600" "E2: digest file is 0600"
[[ "$(cat "$DF")" =~ ^[0-9a-f]{64}$ ]]; assert_status "$?" 0 "E2: digest is sha256 hex"
assert_not_contains "$(cat "$DF")" "10.0.0.7" "E2: no config value in the file"
d7="$(cat "$DF")"; SNAPCTL_server_host=10.0.0.8 run_wrapper >/dev/null
[ "$(cat "$DF")" != "$d7" ]; assert_status "$?" 0 "E3: daemon key change -> new digest"
SNAPCTL_server_host=10.0.0.7 SNAPCTL_backup_target=file:///x run_wrapper >/dev/null
assert_eq "$(cat "$DF")" "$d7" "E3: backup-only key does not change the digest"
out="$(SNAP_COMMON=/nonexistent/no-such-dir run_wrapper)"
assert_contains "$out" "HOST=" "E4: unwritable SNAP_COMMON still execs the app"
```

- [ ] **Step 2: Run, expect failure**

Run: `bash tests/env_wrapper_test.sh` — Expected: E1 FAIL (no file).

- [ ] **Step 3: Implement**

`env-wrapper`: after `source "$SNAP/helper/functions"` add `source "$SNAP/helper/catalog"`. After the `BACKUPS_DIR` export, before the `npm` branch:

```bash
# Record the config this daemon starts with; the configure hook restarts the
# service only when the digest changes (not on refresh, not for backup-only keys).
DIGEST_FILE="$(daemon_digest_file)"
if ! ( umask 077; daemon_config_digest > "$DIGEST_FILE" ) 2>/dev/null || ! chmod 600 "$DIGEST_FILE" 2>/dev/null; then
    lprint "Could not record the config digest in ${DIGEST_FILE}"
fi
```

- [ ] **Step 4: Run, expect pass**

Run: `bash tests/env_wrapper_test.sh` — Expected: `… 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/helper/env-wrapper tests/env_wrapper_test.sh
git commit -m "feat(env-wrapper): record the daemon's config digest at start (A1)"
```

---

### Task 3: `configure` hook — seed, validate, restart only on change

**Files:**
- Modify: `src/hooks/configure` (whole file)
- Modify: `tests/fixtures/bin/snapctl`
- Modify: `.gitignore` (add `tests/.tmp.*`)
- Create: `tests/hooks_test.sh`

**Interfaces:**
- Consumes: `test_default_config`, `service_state` (`functions`); `catalog_keys`, `validate_config`, `daemon_config_digest`, `daemon_digest_file` (Task 1).
- Produces: fixture `snapctl` contract (used by Tasks 4, 5):
  - `get <k>`: if `SNAPCTL_STATE` is set and `$SNAPCTL_STATE/<k>` exists, print that file's content; else `$SNAPCTL_<k with . and - as _>`.
  - `set <k>=<v>` / `unset <k>`: when `SNAPCTL_STATE` is set, write/remove `$SNAPCTL_STATE/<k>`; when `SNAPCTL_LOG` is set, append `set <k>=<v>` / `unset <k>`.
  - `restart|start|stop <args>`: append `<verb> <args>` to `SNAPCTL_LOG` when set.
  - `services [name]`: with `SNAPCTL_SERVICES_FAIL=1` print nothing and exit 1; else the header line, then `zwave-js-ui.zwave-js-ui  enabled  ${SNAPCTL_MAIN_STATE:-active}  -` and `zwave-js-ui.backup-timer  enabled  inactive  timer-activated` (only the matching row when `name` is given; `SNAP_NAME` defaults to `zwave-js-ui`).
  - `is-connected <plug>`: when `SNAPCTL_CONNECTED` is set, exit 0 iff the plug is listed in it (space-separated); else exit 0.
  - Everything else: quiet no-op (today's behaviour).
- Produces: `tests/hooks_test.sh` harness helpers `reset_state k=v…`, `run_hook <name>` (runs `bash "$ROOT/src/hooks/<name>"`, stderr to `$T/stderr`, returns its rc), `digest_now` (prints the digest for the current state), reused by Tasks 4 and 5.

- [ ] **Step 1: Extend the fixture `snapctl`** per the contract above (keep the file a plain `case`, ~30 lines).

- [ ] **Step 2: Write `tests/hooks_test.sh` (failing)**

Harness (the hooks `source $SNAP/helper/*`, so point `SNAP` at the real `src/`):

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
export SNAP="$ROOT/src" SNAP_NAME=zwave-js-ui
T="$(mktemp -d "$ROOT/tests/.tmp.XXXXXX")"; trap 'rm -rf "$T"' EXIT     # under the checkout: the yq snap cannot read /tmp
export SNAP_DATA="$T/data" SNAP_COMMON="$T/common" SNAPCTL_STATE="$T/state" SNAPCTL_LOG="$T/snapctl.log" LOGGER_LOG="$T/logger.log"
mkdir -p "$SNAP_DATA" "$SNAP_COMMON" "$SNAPCTL_STATE" "$T/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$LOGGER_LOG"\n' > "$T/bin/logger"; chmod +x "$T/bin/logger"   # hooks run DAEMONIZED: lprint -> logger
export PATH="$T/bin:$HERE/fixtures/bin:$PATH"
reset_state() { rm -rf "$SNAPCTL_STATE"; mkdir -p "$SNAPCTL_STATE"; : > "$SNAPCTL_LOG"; : > "$LOGGER_LOG"; rm -f "$SNAP_COMMON/.daemon-config.sha256"
                for kv in "$@"; do printf '%s' "${kv#*=}" > "$SNAPCTL_STATE/${kv%%=*}"; done; }
run_hook()   { bash "$ROOT/src/hooks/$1" >"$T/stdout" 2>"$T/stderr"; }
digest_now() { ( source "$ROOT/src/helper/catalog"; daemon_config_digest ); }
VALID=(server.port=8091 server.ssl=false session.cookie-secure=false)
```

Configure cases:

```bash
reset_state "${VALID[@]}"; run_hook configure; assert_status "$?" 0 "C1: valid config -> rc 0"
assert_contains "$(cat "$SNAPCTL_LOG")" "restart zwave-js-ui.zwave-js-ui" "C1: active + no digest file -> restart (timer line is inactive)"
reset_state "${VALID[@]}"; SNAPCTL_MAIN_STATE=inactive run_hook configure
assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C2: inactive daemon -> no restart"
reset_state "${VALID[@]}"; run_hook configure; digest_now > "$SNAP_COMMON/.daemon-config.sha256"; : > "$SNAPCTL_LOG"
run_hook configure; assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C3: equal digest (refresh case) -> no restart"
printf 'file:///x' > "$SNAPCTL_STATE/backup.target"; run_hook configure; assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C3: backup-only change -> no restart"
printf '10.0.0.9' > "$SNAPCTL_STATE/server.host"; run_hook configure; assert_contains "$(cat "$SNAPCTL_LOG")" "restart zwave-js-ui.zwave-js-ui" "C3: daemon key change -> restart"
reset_state server.ssl=false session.cookie-secure=false; run_hook configure; assert_status "$?" 0 "C4: unset server.port -> rc 0 (seeded, A3)"
assert_eq "$(cat "$SNAPCTL_STATE/server.port")" "8091" "C4: server.port seeded to 8091"
for bad in "server.port=abc|!! server.port must be a whole number, got abc" "server.port=70000|a port number 1-65535" "server.ssl=yes|!! server.ssl must be true or false, got yes" "backup.dir=relative|an absolute path" "backup.retention=x|a whole number"; do
    kv="${bad%%|*}"; msg="${bad#*|}"; reset_state "${VALID[@]}" "$kv"; run_hook configure; rc=$?
    assert_status "$rc" 1 "C5: $kv rejected"; assert_contains "$(cat "$T/stderr")" "$msg" "C5: $kv message"
    assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C5: $kv -> no restart"
done
reset_state "${VALID[@]}" session.secret=SUPERSECRETVALUE; run_hook configure
assert_not_contains "$(cat "$LOGGER_LOG")$(cat "$T/stdout")$(cat "$T/stderr")" "SUPERSECRETVALUE" "C6: secret never logged"
reset_state "${VALID[@]}" "mqtt.name=my client=1"; run_hook configure; assert_status "$?" 0 "C7: value with space and = passes"
assert_eq "$(cat "$SNAPCTL_STATE/mqtt.name")" "my client=1" "C7: value untouched"
reset_state "${VALID[@]}"; SNAPCTL_SERVICES_FAIL=1 run_hook configure; assert_status "$?" 0 "C8: services unknown -> rc 0"
assert_not_contains "$(cat "$SNAPCTL_LOG")" "restart" "C8: services unknown -> no restart"
reset_state "${VALID[@]}"; printf 'garbage\n' > "$SNAP_COMMON/.daemon-config.sha256"; run_hook configure
assert_contains "$(cat "$SNAPCTL_LOG")" "restart zwave-js-ui.zwave-js-ui" "C9: corrupt digest file reads as changed -> restart"
finish
```

- [ ] **Step 3: Run, expect failure**

Run: `bash tests/hooks_test.sh` — Expected: C1 FAIL (old gate counts the timer line), C4 FAIL (rc 1), C5 range cases FAIL.

- [ ] **Step 4: Rewrite `src/hooks/configure`**

```bash
#!/usr/bin/env bash
set -e
source $SNAP/helper/functions
source $SNAP/helper/catalog

# Seed first: an unset key means "use the default" (snap unset, navigator reset).
test_default_config

for key in $(catalog_keys); do
    validate_config "${key}" "$(snapctl get "${key}")" || exit 1
done

# Restart only when the running daemon's inputs changed. env-wrapper writes the digest
# of what the daemon started with; snapd runs this hook after start-snap-services on
# every refresh, so an equal digest (or a backup-only change) must not bounce the driver.
DIGEST_FILE="$(daemon_digest_file)"
if [ "$(daemon_config_digest)" != "$(cat "${DIGEST_FILE}" 2>/dev/null || true)" ]; then
    case "$(service_state)" in
        *" active") echo "Restarting ${SNAP_NAME}.${SNAP_NAME}"; snapctl restart "${SNAP_NAME}.${SNAP_NAME}" ;;
    esac
fi
```

Add `tests/.tmp.*` under the "Local on-device test scripts" block of `.gitignore`.

- [ ] **Step 5: Run, expect pass; mutation-check; keep the other suites green**

Run: `bash tests/hooks_test.sh && bash tests/env_wrapper_test.sh` — Expected: `… 0 failed` twice.
Mutation 1: replace the gate with the old `snapctl services | grep "${SNAP_NAME}" | grep inactive | wc -l` logic → C1 FAILs. Mutation 2: move `test_default_config` below the loop → C4 FAILs. Restore both.

- [ ] **Step 6: Commit**

```bash
git add src/hooks/configure tests/fixtures/bin/snapctl tests/hooks_test.sh .gitignore
git commit -m "fix(hook): seed before validating and restart only when the daemon's inputs changed (A1, A3)"
```

---

### Task 4: `session.secret` — stop seeding, export only when set, migrate v1 UUIDs

**Files:**
- Modify: `src/helper/functions:132-145` (drop the `session.secret` line; add `migrate_session_secret`)
- Modify: `src/helper/env-wrapper:32`
- Modify: `src/helper/catalog` (session.secret row)
- Modify: `src/hooks/post-refresh` (call `migrate_session_secret` after `test_default_config`)
- Test: `tests/functions_test.sh`, `tests/env_wrapper_test.sh`, `tests/hooks_test.sh`, `tests/catalog_test.sh`

**Interfaces:**
- Produces: `migrate_session_secret` in `functions`: reads `snapctl get session.secret`; when the value is 36 chars of `[0-9a-fA-F-]` with `1` at offset 14 (a v1 UUID, what the snap used to seed) it runs `snapctl unset session.secret` and `lprint "session.secret: removed the generated v1 UUID; the app now keeps its own secret in ${SNAP_DATA}/.session-secret (one re-login)"`; otherwise does nothing. Never prints the value.
- Catalog row, exact: `session.secret	secret	(unset)	Session secret; leave unset and the app keeps its own 256-bit secret in the store (recommended)	common	daemon`.

- [ ] **Step 1: Tests (failing)**

`tests/functions_test.sh` (append before `finish`; the suite's `snapctl` stub returns 1 on `get`, so define a local one):

```bash
SLOG="$(mktemp)"; snapctl() { case "$1" in get) printf '%s' "${SECRET_VALUE:-}" ;; unset|set) printf '%s %s\n' "$1" "$2" >> "$SLOG" ;; *) : ;; esac; }
out="$(SECRET_VALUE=6ba7b810-9dad-11d1-80b4-00c04fd430c8 migrate_session_secret)"
assert_contains "$(cat "$SLOG")" "unset session.secret" "migrate: v1 UUID is removed"
assert_contains "$out" "one re-login" "migrate: notice logged"; assert_not_contains "$out" "6ba7b810" "migrate: value not logged"
: > "$SLOG"; SECRET_VALUE=123e4567-e89b-42d3-a456-426614174000 migrate_session_secret >/dev/null; assert_eq "$(cat "$SLOG")" "" "migrate: v4 UUID kept"
: > "$SLOG"; SECRET_VALUE=my-own-secret migrate_session_secret >/dev/null;                       assert_eq "$(cat "$SLOG")" "" "migrate: custom value kept"
: > "$SLOG"; SECRET_VALUE= migrate_session_secret >/dev/null;                                    assert_eq "$(cat "$SLOG")" "" "migrate: unset stays unset"
: > "$SLOG"; snapctl() { case "$1" in get) printf '' ;; set) printf 'set %s\n' "$2" >> "$SLOG" ;; *) : ;; esac; }
test_default_config >/dev/null; assert_not_contains "$(cat "$SLOG")" "session.secret" "test_default_config no longer seeds session.secret"
assert_contains "$(cat "$SLOG")" "set server.port=8091" "test_default_config still seeds server.port"
```

`tests/env_wrapper_test.sh`: `assert_not_contains "$(run_wrapper)" "SESSION_SECRET=" "unset secret -> not exported"`; `assert_contains "$(SNAPCTL_session_secret=abc run_wrapper)" "SESSION_SECRET=abc" "set secret -> exported"`.
`tests/hooks_test.sh` (post-refresh, process level): `reset_state "${VALID[@]}" session.secret=6ba7b810-9dad-11d1-80b4-00c04fd430c8; run_hook post-refresh; assert_contains "$(cat "$SNAPCTL_LOG")" "unset session.secret" "P1: post-refresh removes the seeded v1 UUID"; assert_not_contains "$(cat "$SNAPCTL_LOG")" "set session.secret" "P1: nothing re-seeds it"; assert_not_contains "$(cat "$LOGGER_LOG")" "6ba7b810" "P1: value not in syslog"`.
`tests/catalog_test.sh`: `assert_eq "$(catalog_field session.secret 3)" "(unset)" "session.secret default is unset (D4)"`.

- [ ] **Step 2: Run, expect failure** — `bash tests/functions_test.sh` (migrate undefined), `bash tests/env_wrapper_test.sh` (`SESSION_SECRET=` present), `bash tests/catalog_test.sh` (`(generated)`).

- [ ] **Step 3: Implement** — delete `testnset_config "session.secret" "$(uuid)"`; add `migrate_session_secret` to `functions`; in `env-wrapper` replace line 32 with the `MQTT_NAME` pattern (`SESSION_SECRET=$(snapctl get session.secret); if [ -n "$SESSION_SECRET" ]; then export SESSION_SECRET; else unset SESSION_SECRET; fi`); catalog row as above; `post-refresh`: add `migrate_session_secret` on the line after `test_default_config`.

- [ ] **Step 4: Run, expect pass** — `for t in functions env_wrapper hooks catalog help ui_nav; do bash tests/${t}_test.sh; done` → all `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/helper/functions src/helper/env-wrapper src/helper/catalog src/hooks/post-refresh tests/functions_test.sh tests/env_wrapper_test.sh tests/hooks_test.sh tests/catalog_test.sh
git commit -m "fix(config): stop seeding session.secret and drop the seeded v1 UUID at refresh (D2)"
```

---

### Task 5: Quiet plug check, null-safe priority-dir migration, no `find` in post-refresh (A7, A8, A9)

**Files:**
- Modify: `src/helper/functions:31-55` (`plugs_connected`), `:99-130` (`test_device_priority_dir`)
- Modify: `src/hooks/post-refresh:9-12`
- Test: `tests/functions_test.sh`, `tests/hooks_test.sh`

**Interfaces:**
- `plugs_connected` captures `RAW_OUT=$(DAEMONIZED=0 plug_connected "raw-usb")` and `SERIAL_OUT=$(DAEMONIZED=0 plug_connected "serial-port")`, so nothing is logged unless both are missing; the re-emission through `lprint` is unchanged.
- `test_device_priority_dir`: `DEV_DIR=$(yq -r '.zwave.deviceConfigPriorityDir // ""' "${ZUI_SETTINGS}" 2>&-)`; `[ -n "${DEV_DIR}" ] || return 0`; the "not writable" `lprint` only when `NDEV_DIR` is non-empty.
- `post-refresh`: `rm -f "${SNAP_DATA}/.ext-config/devices/index.json"` replaces the `find … -print0` capture.

- [ ] **Step 1: Tests (failing)**

`tests/functions_test.sh`:

```bash
PLOG="$(mktemp)"; logger() { printf '%s\n' "$*" >> "$PLOG"; }
snapctl() { case "$1" in is-connected) [ "$2" != raw-usb ] ;; *) : ;; esac; }     # only raw-usb missing
( DAEMONIZED=1 plugs_connected ); assert_status "$?" 0 "A7: serial-port + hardware-observe -> connected"
assert_eq "$(cat "$PLOG")" "" "A7: nothing logged when the alternative plug is present"
snapctl() { case "$1" in is-connected) [ "$2" = hardware-observe ] ;; *) : ;; esac; } # both alternatives missing
( DAEMONIZED=1 plugs_connected ); assert_status "$?" 1 "A7: both missing -> fail"
assert_contains "$(cat "$PLOG")" "Missing plug: «raw-usb»" "A7: raw-usb message logged"; assert_contains "$(cat "$PLOG")" "----- OR -----" "A7: OR line"; assert_contains "$(cat "$PLOG")" "serial-port" "A7: serial-port alternative logged"
```

`tests/hooks_test.sh` (post-refresh; real yq):

```bash
reset_state "${VALID[@]}"; mkdir -p "$SNAP_DATA/.ext-config/devices"; : > "$SNAP_DATA/.ext-config/devices/index.json"
run_hook post-refresh; [ ! -e "$SNAP_DATA/.ext-config/devices/index.json" ]; assert_status "$?" 0 "A9: index.json removed"
assert_not_contains "$(cat "$T/stderr")" "null byte" "A9: no bash warning"
printf '{"mqtt":{"host":"x"}}' > "$SNAP_DATA/settings.json"; cp "$SNAP_DATA/settings.json" "$T/ref.json"; : > "$LOGGER_LOG"
run_hook post-refresh; cmp -s "$SNAP_DATA/settings.json" "$T/ref.json"; assert_status "$?" 0 "A8: settings.json without the key is untouched"
assert_not_contains "$(cat "$LOGGER_LOG")" "not writable" "A8: no misleading log line"
mkdir -p "$T/x43/prio"; printf '{"zwave":{"deviceConfigPriorityDir":"%s/x42/prio"}}' "$T" > "$T/x43/settings.json"
SNAP_DATA="$T/x43" run_hook post-refresh; assert_eq "$(yq -r '.zwave.deviceConfigPriorityDir' "$T/x43/settings.json")" "$T/x43/prio" "A8: stale revision path still rewritten"
```

- [ ] **Step 2: Run, expect failure** — functions: `A7: nothing logged` FAILs; hooks: `A9: no bash warning` and `A8: untouched` FAIL.

- [ ] **Step 3: Implement** the three changes above.

- [ ] **Step 4: Run, expect pass** — `bash tests/functions_test.sh && bash tests/hooks_test.sh`.

- [ ] **Step 5: Commit**

```bash
git add src/helper/functions src/hooks/post-refresh tests/functions_test.sh tests/hooks_test.sh
git commit -m "fix(hooks): quiet plug check, null-safe priority-dir migration, fixed-path index.json removal (A7, A8, A9)"
```

---

### Task 6: Navigator validates, re-seeds and offers a restart; robust rows (A2, A6)

**Files:**
- Modify: `src/bin/ui:9-60` (`nav_settings`, `nav_set_apply`)
- Modify: `src/helper/ui:147-165` (`ui_stack`)
- Modify: `tests/ui_nav_test.sh:19-25,73-104` (stub + Settings block)
- Modify: `tests/ui_test.sh` (ui_stack empty-field case)

**Interfaces:**
- Consumes: `catalog_field`, `validate_config` (Task 1); `test_default_config`, `service_state` (`functions`); `${NAV_BIN:-$SNAP/bin}/restart`.
- `nav_set_apply <key> <value> <set|unset>`: empty value with `set` → treated as `unset`. `set`: `validate_config` first; on failure `ui_err "Rejected — $key unchanged"`, `ui_print` the message, `ui_pause`, return (no `snapctl`). `unset`: `snapctl unset "$key"` then `( test_default_config ) >/dev/null 2>&1`, banner `ui_ok "$key reset to default: <snapctl get value or (unset), (hidden) if secret>"`. After a successful write: `applies=$(catalog_field "$key" 6)`; `daemon` → `case "$(service_state)" in *" active") if ui_confirm "Restart $SNAP_NAME to apply?"; then "${NAV_BIN:-$SNAP/bin}/restart"; fi ;; *) ui_print "Takes effect when the service starts." ;; esac`; `backup` → `ui_print "Used by the next backup run."`. Then `ui_pause`.
- `nav_settings`: fields via `catalog_field "$key" 2|3|4`; header comment no longer claims the hook validates.
- `ui_stack`: splits each row with a loop (`fields=(); while IFS= read -r -d $'\t' f; do fields+=("$f"); done <<< "${line}"$'\t'`) so an empty middle field is kept.

- [ ] **Step 1: Tests (failing)**

`tests/ui_nav_test.sh`: in the Settings stub (line 73-81) make `services` print `zwave-js-ui.zwave-js-ui  enabled  ${SNAPCTL_MAIN_STATE:-active}  -` and drop the `SNAPCTL_SET_FAIL` branch. Replace the "rejection" and "reset" cases (lines 94-104) with:

```bash
: > "$SET_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '99999\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "a port number 1-65535" "N1: client-side validation message"; assert_contains "$out" "Rejected" "N1: rejected banner"
assert_not_contains "$(cat "$SET_LOG")" "set server.port" "N1: nothing written on rejection"
: > "$SET_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "set server.port=8092" "N2: valid int written"
: > "$SET_LOG"; printf '%s\n' "server.port" "Reset to default" "← Back" > "$CQ"
UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "unset server.port" "N3: reset unsets"; assert_contains "$(cat "$SET_LOG")" "set server.port=8091" "N3: reset re-seeds the default"
: > "$GUM_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CONFIRM=0 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "RAN_restart" "N4: restart accepted -> restart bin runs"
printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 NAV_BIN="$SVC" GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_not_contains "$out" "RAN_restart" "N4: restart declined -> no restart"; assert_contains "$(cat "$GUM_LOG")" "confirm" "N4: restart was offered"
: > "$GUM_LOG"; printf '%s\n' "server.port" "Edit" "← Back" > "$CQ"; printf '8092\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 SNAPCTL_MAIN_STATE=inactive GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "Takes effect when the service starts." "N5: inactive -> no offer, hint"; assert_not_contains "$(cat "$GUM_LOG")" "confirm" "N5: no confirm when inactive"
: > "$GUM_LOG"; printf '%s\n' "backup.target" "Edit" "← Back" > "$CQ"; printf 'file:///x\n' > "$INQ"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings 2>&1)"
assert_contains "$out" "Used by the next backup run." "N6: backup key -> no restart talk"; assert_not_contains "$(cat "$GUM_LOG")" "confirm" "N6: no confirm for backup keys"
: > "$SET_LOG"; printf '%s\n' "session.cookie-secure" "Reset to default" "← Back" > "$CQ"
SNAPCTL_server_ssl=true UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "set session.cookie-secure=true" "N7: dependent default follows server.ssl"
: > "$SET_LOG"; printf '%s\n' "mqtt.name" "Edit" "← Back" > "$CQ"; printf '\n' > "$INQ"
UI_ASSUME_TTY=1 GUM_CONFIRM=1 GUM_CHOOSE_QUEUE="$CQ" GUM_INPUT_QUEUE="$INQ" nav_settings >/dev/null 2>&1
assert_contains "$(cat "$SET_LOG")" "unset mqtt.name" "N8: empty edit = reset"
printf '%s\n' "zwave.serial-port" "← Back" > "$CQ"
out="$(UI_ASSUME_TTY=1 GUM_CHOOSE_QUEUE="$CQ" nav_settings 2>&1)"
assert_contains "$out" "Serial device of the Z-Wave controller" "A6: real description shown"; assert_not_contains "$out" "advanced" "A6: scope no longer leaks into the description"
```

Keep the existing bool-edit and secret-masking cases; add `GUM_CONFIRM=1` to any Settings call that now reaches the restart offer. `tests/ui_test.sh` (ui_stack section): `es="$(printf 'a\t\tc\n' | ui_stack h1 h2 h3)"; assert_contains "$es" "    h3: c" "stack: empty middle field keeps later columns aligned"; assert_eq "$(printf '%s\n' "$es" | wc -l)" "3" "stack: three lines for three fields"`.

- [ ] **Step 2: Run, expect failure** — `bash tests/ui_nav_test.sh` (N1 shows `set server.port=99999`), `bash tests/ui_test.sh` (stack has 2 lines).

- [ ] **Step 3: Implement** per the Interfaces block.

- [ ] **Step 4: Run, expect pass; mutation-check** — both suites green. Mutation: remove the `validate_config` call → N1 FAILs; restore.

- [ ] **Step 5: Commit**

```bash
git add src/bin/ui src/helper/ui tests/ui_nav_test.sh tests/ui_test.sh
git commit -m "fix(ui): navigator validates, re-seeds on reset and offers a restart; robust catalog rows (A2, A6)"
```

---

### Task 7: `create-key` — confirmed passphrase, never on argv (C8, D11)

**Files:**
- Modify: `src/bin/backup:271-321` (`cmd_create_key`)
- Test: `tests/backup_test.sh`

**Interfaces:**
- After the UID prompts: `ui_print "This passphrase is needed to restore — there is no recovery if it is lost." >&2`; `pass=$(ui_input --password 'Passphrase for the new private key')`; `pass2=$(ui_input --password 'Repeat passphrase')`; mismatch → `ui_err "Passphrases do not match — nothing created."`, return 1 before any gpg call. Both gpg calls: `printf '%s\n' "$pass" | gpg_snap --batch --pinentry-mode loopback --passphrase-fd 0 …`.

- [ ] **Step 1: Tests (failing)** — append to `tests/backup_test.sh` before `finish`:

```bash
GPG_LOG="$SNAP_COMMON/gpg.log"; GPG_IN="$SNAP_COMMON/gpg.stdin"
gpg() { printf '%s\n' "$*" >> "$GPG_LOG"; case "$*" in *--passphrase-fd*) cat > "$GPG_IN" ;; esac
        case "$*" in *--list-keys*) printf 'fpr:::::::::ABCDEF0123456789ABCDEF0123456789ABCDEF01:\n' ;; esac; }
: > "$GPG_LOG"; : > "$GPG_IN"
ck="$( (ensure_agent() { :; }; printf 'pw1\npw1\n' | cmd_create_key Name mail@example.com) 2>&1 )"; rc=$?
assert_status "$rc" 0 "K1: confirmed passphrase -> created"; assert_contains "$ck" "needed to restore" "K1: explains irrecoverability"
assert_contains "$(cat "$GPG_LOG")" "--passphrase-fd 0" "K1: passphrase on fd 0"; assert_not_contains "$(cat "$GPG_LOG")" "pw1" "K1: passphrase never on argv (D11)"
assert_eq "$(cat "$GPG_IN")" "pw1" "K1: passphrase delivered on stdin"
: > "$GPG_LOG"; ck="$( (ensure_agent() { :; }; printf 'pw1\npw2\n' | cmd_create_key Name mail@example.com) 2>&1 )"; rc=$?
assert_status "$rc" 1 "K2: mismatch -> rc 1"; assert_contains "$ck" "Passphrases do not match — nothing created." "K2: message"; assert_eq "$(cat "$GPG_LOG")" "" "K2: gpg never called"
```

- [ ] **Step 2: Run, expect failure** — `bash tests/backup_test.sh`: K1 `never on argv` FAILs (`--passphrase pw1` logged), K2 FAILs.

- [ ] **Step 3: Implement**; fix the stale comment at `:281-282` to say the passphrase travels on fd 0.

- [ ] **Step 4: Run, expect pass; mutation** — revert one gpg call to `--passphrase "$pass"` → K1 `never on argv` FAILs; restore.

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "fix(backup): confirm the new key's passphrase and pass it on a descriptor (C8, D11)"
```

---

### Task 8: `export-key` — pipe-only, terminal prompt, loopback export (A4, C6)

**Files:**
- Modify: `src/bin/backup:326-365` (`cmd_export_key`)
- Test: `tests/backup_test.sh`

**Interfaces:**
- Order inside `cmd_export_key`: (1) `if [ -t 1 ]` → `ui_err "export-key writes the PRIVATE key to stdout — redirect it:"`, `ui_print "  sudo ${SNAP_NAME}.backup export-key > zui-backup-key.asc" >&2`, `ui_print "  then on your workstation: gpg --import zui-backup-key.asc   (keep a copy offline)" >&2`, `exit 1`; (2) `ensure_agent` (unchanged: secret-key export still goes through the agent); (3) key checks unchanged — a public-only key still exits 0 with "nothing to export" and reads nothing; (4) `printf '%s' "Passphrase of the backup private key: " >&2; IFS= read -rs pass; printf '\n' >&2` (an explicit prompt, not `read -p`: bash shows `-p` only when stdin is a terminal, and the tests feed stdin from a pipe); empty → `ui_err "Cannot read the passphrase — run from a terminal with stdout redirected to a file."`, exit 1; (5) `exported="$(printf '%s\n' "$pass" | gpg_snap --batch --pinentry-mode loopback --passphrase-fd 0 --export-secret-keys --armor "$fpr" 2>"$gpgerr")"`; (6) the delete question the same way: `printf '%s' "Delete the private key from THIS device now? [y/N] " >&2; IFS= read -r answer || answer=""` (stdin EOF → kept); `y|Y|yes|YES` deletes as today. `ui_confirm`/`ui_input` are not used here: the UI library gates widgets on a terminal on stdout, which this command forbids — say so in a comment.

- [ ] **Step 1: Tests (failing)**

```bash
# X1: terminal on stdout is refused before anything else (pty via script, as logs_test does)
if command -v script >/dev/null 2>&1; then
  cat > "$SNAP_COMMON/export_tty.sh" <<EOF
export SNAP="$SNAP" SNAP_COMMON="$SNAP_COMMON"
snapctl() { case "\$1" in get) printf 'F0F0' ;; *) : ;; esac; }
source "$ROOT/src/bin/backup"; require_root() { :; }; ensure_agent() { echo AGENT_CALLED; }
( cmd_export_key ); echo "rc=\$?"
EOF
  pty="$(timeout 10 script -qec "bash $SNAP_COMMON/export_tty.sh" /dev/null 2>&1 </dev/null)"
  assert_contains "$pty" "redirect it" "X1: TTY stdout refused with the redirect hint"; assert_contains "$pty" "rc=1" "X1: rc 1"; assert_not_contains "$pty" "AGENT_CALLED" "X1: refused before the agent is touched"
fi
gpg() { printf '%s\n' "$*" >> "$GPG_LOG"; case "$*" in
    *--list-secret-keys*) return "${GPG_NO_SECRET:-0}" ;;
    *--export-secret-keys*) cat > "$GPG_IN"; printf -- '-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc\n-----END PGP PRIVATE KEY BLOCK-----\n' ;;
    esac; }
: > "$GPG_LOG"; : > "$GPG_IN"
xo="$( (ensure_agent() { :; }; SNAPCTL_backup_encrypt_key=F0F0 cmd_export_key < <(printf 'pw\nn\n')) 2>"$SNAP_COMMON/xerr" )"; rc=$?
assert_status "$rc" 0 "X2: export ok"; assert_contains "$xo" "BEGIN PGP PRIVATE KEY BLOCK" "X2: key on stdout only"
assert_contains "$(cat "$GPG_LOG")" "--pinentry-mode loopback" "X2: loopback (no pinentry in the snap, A4)"; assert_contains "$(cat "$GPG_LOG")" "--passphrase-fd 0" "X2: passphrase on fd 0"
assert_not_contains "$(cat "$GPG_LOG")" "pw" "X2: passphrase not on argv"; assert_eq "$(cat "$GPG_IN")" "pw" "X2: passphrase delivered"
assert_contains "$(cat "$SNAP_COMMON/xerr")" "Passphrase of the backup private key" "X2: prompt on stderr"; assert_not_contains "$(cat "$GPG_LOG")" "--delete-secret-keys" "X2: 'n' keeps the key"
: > "$GPG_LOG"; (ensure_agent() { :; }; SNAPCTL_backup_encrypt_key=F0F0 cmd_export_key < <(printf 'pw\ny\n')) >/dev/null 2>&1
assert_contains "$(cat "$GPG_LOG")" "--delete-secret-keys" "X3: 'y' deletes after a verified export"
(ensure_agent() { :; }; SNAPCTL_backup_encrypt_key=F0F0 cmd_export_key </dev/null) >/dev/null 2>"$SNAP_COMMON/xerr"; assert_status "$?" 1 "X4: no passphrase -> rc 1"
assert_contains "$(cat "$SNAP_COMMON/xerr")" "passphrase" "X4: says what is missing"
: > "$GPG_LOG"; (ensure_agent() { :; }; GPG_NO_SECRET=1 SNAPCTL_backup_encrypt_key=F0F0 cmd_export_key < <(printf 'pw\n')) >/dev/null 2>"$SNAP_COMMON/xerr"; assert_status "$?" 0 "X5: public-only key -> rc 0"
assert_contains "$(cat "$SNAP_COMMON/xerr")" "nothing to export" "X5: explains"; assert_not_contains "$(cat "$SNAP_COMMON/xerr")" "Passphrase of" "X5: no passphrase prompt"
```

(`cmd_export_key` calls `exit`; every invocation above runs in a subshell, so the suite survives.)

- [ ] **Step 2: Run, expect failure** — X1 (`redirect it` absent), X2 (`--pinentry-mode loopback` absent, no prompt).

- [ ] **Step 3: Implement** per the Interfaces block.

- [ ] **Step 4: Run, expect pass; mutation** — drop `--pinentry-mode loopback` → X2 FAILs; restore.

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "fix(backup): export-key is pipe-only and exports with a loopback passphrase (A4, C6)"
```

---

### Task 9: `status` reads the keyring on disk; `import-key` says what it waits for (A5, C7)

**Files:**
- Modify: `src/bin/backup:86-105` (`cmd_status`), `:213-220` (`cmd_import_key`), new `secret_key_on_disk` next to `gpg_snap`
- Test: `tests/backup_test.sh`

**Interfaces:**
- `secret_key_on_disk <fpr>` → rc 0 iff `gpg_snap --with-colons --with-keygrip --list-keys "$fpr"` yields a `grp` record (field 10 of the first one) and `$GNUPGHOME/private-keys-v1.d/<grip>.key` exists. No agent involved.
- `cmd_status`: `if [ -n "$key" ] && secret_key_on_disk "$key"; then onbox=yes; fi`.
- `cmd_import_key`: before `cat > "$tmp"`: `if [ -t 0 ]; then ui_print "Paste the ARMORED PUBLIC key, then press Ctrl-D — or pipe it: ${SNAP_NAME}.backup pick-key | sudo ${SNAP_NAME}.backup import-key" >&2; fi`.

- [ ] **Step 1: Tests (failing)**

```bash
export GNUPGHOME="$SNAP_COMMON/.gnupg"; mkdir -p "$GNUPGHOME/private-keys-v1.d"
gpg() { case "$*" in *--with-keygrip*) printf 'grp:::::::::1234GRIP:\n' ;; esac; }
: > "$GNUPGHOME/private-keys-v1.d/1234GRIP.key"; secret_key_on_disk F0F0; assert_status "$?" 0 "S1: keygrip file present -> secret key on disk"
printf '%s\n' "$(SNAPCTL_backup_encrypt_key=F0F0 cmd_status)" | grep -Eq 'private key on this device[[:space:]]+yes'; assert_status "$?" 0 "S1: status says yes without an agent (A5)"
rm "$GNUPGHOME/private-keys-v1.d/1234GRIP.key"; secret_key_on_disk F0F0; assert_status "$?" 1 "S2: no keygrip file -> no"
printf '%s\n' "$(SNAPCTL_backup_encrypt_key=F0F0 cmd_status)" | grep -Eq 'private key on this device[[:space:]]+no'; assert_status "$?" 0 "S2: status says no"
gpg() { :; }; secret_key_on_disk F0F0; assert_status "$?" 1 "S3: key not in the keyring -> no"
ih="$( (gpg() { return 1; }; printf 'junk' | cmd_import_key) 2>&1 )"; assert_not_contains "$ih" "Paste the ARMORED" "I1: piped stdin -> no paste hint"
if command -v script >/dev/null 2>&1; then
  cat > "$SNAP_COMMON/import_tty.sh" <<EOF
export SNAP="$SNAP" SNAP_COMMON="$SNAP_COMMON" GNUPGHOME="$GNUPGHOME"
snapctl() { :; }; source "$ROOT/src/bin/backup"; require_root() { :; }; gpg() { return 1; }
cmd_import_key
EOF
  ip="$(timeout 10 script -qec "bash $SNAP_COMMON/import_tty.sh" /dev/null 2>&1 </dev/null)"
  assert_contains "$ip" "Paste the ARMORED PUBLIC key" "I2: terminal stdin -> paste hint before reading (C7)"
fi
unset GNUPGHOME
```

(The existing "gpg absent -> private key no" assertion at `:128` keeps passing: no `grp` record means no.)

- [ ] **Step 2: Run, expect failure** — S1 (`secret_key_on_disk: command not found`), I2.

- [ ] **Step 3: Implement** the three changes.

- [ ] **Step 4: Run, expect pass** — `bash tests/backup_test.sh`.

- [ ] **Step 5: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "fix(backup): status reads the keyring on disk; import-key explains what it waits for (A5, C7)"
```

---

### Task 10: Packaging and CI — daemon plugs, `uuid`, store text, lint-test token (D8, D7, C3, C1)

**Files:**
- Modify: `snap/snapcraft.yaml:38-47` (description tail), `:86-92` (daemon plugs), `:209-211` (stage-packages)
- Modify: `.github/workflows/lint-test.yml:1-9`
- Create: `tests/packaging_test.sh` (yq + grep guards; Task 11 appends to it)

**Interfaces:**
- Description replacement for lines 42-47, exact:

```
  # Interfaces
  - `hardware-observe` (auto-connected) plus one of `raw-usb` (auto-connected) or `serial-port`
    are **required**: the service refuses to start without them, and `zwave-js-ui.enable`
    names the missing one.
  - `log-observe` (connect manually) lets `zwave-js-ui.logs` read journald when the app does not log to file.

  # Getting started
      sudo snap install zwave-js-ui
      sudo zwave-js-ui.enable        # the service is disabled until you enable it
  Then open http://<host>:8091 — `zwave-js-ui.help` lists the settings, `sudo zwave-js-ui.ui` edits them.
```
- `lint-test.yml`: add `permissions:` with `contents: read` between `on:` and `jobs:`.

- [ ] **Step 1: Write `tests/packaging_test.sh` (failing)**

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
Y="$ROOT/snap/snapcraft.yaml"
assert_not_contains "$(yq '.apps.zwave-js-ui.plugs[]' "$Y")" "log-observe" "D8: daemon app has no log-observe"
assert_contains "$(yq '.apps.ui.plugs[]' "$Y")" "log-observe" "ui keeps log-observe"; assert_contains "$(yq '.apps.logs.plugs[]' "$Y")" "log-observe" "logs keeps log-observe"
assert_not_contains "$(yq '.parts.local.stage-packages[]' "$Y")" "uuid" "uuid stage package removed (sole consumer gone)"
assert_eq "$(grep -rl '\buuid\b' "$ROOT/src" | wc -l)" "0" "nothing in src/ calls uuid"
assert_contains "$(yq '.description' "$Y")" "sudo zwave-js-ui.enable" "C1: store text has getting started"
assert_contains "$(yq '.description' "$Y")" "required" "C3: store text says plugs are required"
assert_not_contains "$(yq '.description' "$Y")" "None of these connections are necessary" "C3: contradiction gone"
assert_eq "$(yq '.permissions.contents' "$ROOT/.github/workflows/lint-test.yml")" "read" "D7: lint-test token is read-only"
finish
```

- [ ] **Step 2: Run, expect failure** — `bash tests/packaging_test.sh`: D8, uuid, C1, C3, D7 FAIL.

- [ ] **Step 3: Implement** — delete `- log-observe` at `:92`; delete `- uuid` at `:210`; replace the description tail; add the `permissions` block; run `yq '.' snap/snapcraft.yaml >/dev/null` to prove it still parses.

- [ ] **Step 4: Run, expect pass** — `bash tests/packaging_test.sh`.

- [ ] **Step 5: Commit (two commits, per finding)**

```bash
git add snap/snapcraft.yaml tests/packaging_test.sh
git commit -m "fix(snap): drop log-observe from the daemon and the unused uuid package; truthful store text (D8, C3, C1)"
git add .github/workflows/lint-test.yml tests/packaging_test.sh
git commit -m "ci(lint-test): least-privilege GITHUB_TOKEN (D7)"
```

---

### Task 11: Docs — README and CLAUDE.md say what the code does (C3, B2, C1)

**Files:**
- Modify: `README.md:28` (channels), after `:19` (new "Getting started" section), `:88-113` ("Auto-Connections" → "Interfaces")
- Modify: `CLAUDE.md:36`, `:62-66`, `:76-81`, `:84` (navigator sentence), backup paragraph (`export-key`)
- Modify: `tests/packaging_test.sh`

**Interfaces:** exact copy below; everything else in those files stays.

README, insert after the "About This Package" bullets (`:19`):

````markdown
## Getting started

```bash
sudo snap install zwave-js-ui
sudo zwave-js-ui.enable          # the service is disabled until you enable it
```

Then open `http://<host>:8091`. `zwave-js-ui.help` shows the settings and commands;
`sudo zwave-js-ui.ui` is an interactive navigator for settings, service, interfaces and logs.
Settings are snap config: `sudo snap set zwave-js-ui server.port=8092` (the service restarts
itself when a setting it uses changes; `sudo snap unset zwave-js-ui <key>` restores the default).
````

README `:28` becomes: ``- **`latest/edge`** — Development builds. Every build, including experimental and test versions, may be pushed to this channel. It is intended for maintainers and testers only.``

README `:88-113`, replace the section with:

````markdown
## Interfaces

The service needs `hardware-observe` **and one of** `raw-usb` or `serial-port`. It refuses to
start without them: `sudo zwave-js-ui.enable` and `zwave-js-ui.restart` print which interface
is missing and the command that connects it.

- `raw-usb` (auto-connected from the Snap Store) — USB Z-Wave controller sticks.
- `hardware-observe` (auto-connected) — lets the UI discover devices on the host.
- `serial-port` (manual; needs snapd's experimental hotplug) — a serial controller instead of `raw-usb`.
- `log-observe` (manual) — `zwave-js-ui.logs` reads journald for any log not written to file;
  without it the command exits with the fix: `sudo snap connect zwave-js-ui:log-observe`.

Manual connections (needed after `snap install --dangerous` of a local build):
```bash
sudo snap connect zwave-js-ui:raw-usb
sudo snap connect zwave-js-ui:hardware-observe
```

Notes:
- Depending on your distribution you may need to adjust USB device permissions for the controller.
- `raw-usb` grants broad USB access; connect it only if you trust the snap source.
````

CLAUDE.md:
- `:36` → ``yq` is used pervasively (build step, CI, helper scripts). The build pins Node 22.x (`npm-node-version`, Renovate-tracked with `allowedVersions <23`; see the comment in `snapcraft.yaml`) and `core26` as the snap base.``
- `:62` (`env-wrapper` bullet): change `session.secret`→`SESSION_SECRET` to `session.secret`→`SESSION_SECRET` *(only when set; unset lets the app keep its own 256-bit secret in `$STORE_DIR/.session-secret`)*, and append: `At every start it writes the sha256 of the daemon-relevant config (catalog `applies=daemon`) to `$SNAP_COMMON/.daemon-config.sha256`; the `configure` hook restarts the service only when that digest changes.`
- `:63` (`functions` bullet): append `migrate_session_secret` (post-refresh: drops a seeded v1 UUID once).
- `:66` (`catalog` sentence): `src/helper/catalog` is the settings catalog (key/type/default/description/scope/**applies**) driving the `help` settings table **and the shared validator `validate_config` (used by the `configure` hook and the navigator) and `daemon_config_digest`**; a test guards its defaults against drifting from `test_default_config`.
- `:78-81` hooks list, replace with:

```markdown
- `configure` — seeds defaults first (so `snap unset` means "back to the default"), then validates every catalog key with `validate_config`, then restarts the daemon **only if it is active and `daemon_config_digest` differs from the digest `env-wrapper` recorded at its last start**. Runs on every `snap set` and, courtesy of snapd, after the services start on install/refresh — the digest keeps that from being a second restart.
- `install` — seeds defaults, then disables the daemon (the user enables it explicitly with `zwave-js-ui.enable`).
- `pre-refresh` — seeds defaults.
- `post-refresh` — seeds defaults, runs `migrate_session_secret`, runs `test_device_priority_dir` (rewrites a stale `deviceConfigPriorityDir` that embedded the old revision number; a missing key is left alone) and removes the external-config `devices/index.json` so it rebuilds.
```
- `:84`: replace `the `configure` hook remains the validator for `snap set` edits` with `snapd runs no hook for an app's `snapctl set`, so the navigator validates with the same `validate_config`, re-seeds via `test_default_config` on reset, and offers a restart for `applies=daemon` keys`.
- Backup paragraph: after `export-key` (root: export the private key …) add `— pipe-only: stdout must be redirected to a file, the passphrase is prompted on the terminal and passed to gpg over a descriptor (loopback; the snap has no pinentry)`.

- [ ] **Step 1: Guards in `tests/packaging_test.sh` (failing)** — before `finish`:

```bash
R="$ROOT/README.md"; C="$ROOT/CLAUDE.md"
assert_not_contains "$(cat "$R")" "edge/dev" "B2: no latest/edge/dev"
assert_contains "$(cat "$R")" "sudo zwave-js-ui.enable" "C1: README getting started"; assert_contains "$(cat "$R")" "http://<host>:8091" "C1: README URL"
assert_not_contains "$(cat "$R")" "not strictly required" "C3: README no longer calls plugs optional"; assert_contains "$(cat "$R")" "refuses to start" "C3: README says required"
assert_not_contains "$(cat "$C")" "22.20.0" "B2: no stale Node literal"
assert_not_contains "$(cat "$C")" '`pre-refresh` — runs `test_device_priority_dir`' "B2: hooks attributed correctly"
assert_contains "$(cat "$C")" "daemon_config_digest" "CLAUDE.md documents the digest gate"
```

- [ ] **Step 2: Run, expect failure** — `bash tests/packaging_test.sh`.
- [ ] **Step 3: Apply the edits** above.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md tests/packaging_test.sh
git commit -m "docs: plugs are required, hooks attributed correctly, getting started, no latest/edge/dev (C3, B2, C1)"
```

---

### Task 12: Whole-branch verification

- [ ] **Step 1: All suites and shellcheck under the lock**

Run: `flock -w 3600 /tmp/claude-1000/chim-suites.lock bash -c 'for t in tests/*_test.sh; do printf "%-26s " "$t"; bash "$t" 2>&1 | tail -1; done; shellcheck --severity=warning -x src/bin/* src/hooks/* src/helper/* tests/*.sh tests/lib/*.sh && echo "shellcheck: clean"'`
Expected: eleven suites, each `… 0 failed` (backup, catalog, env_wrapper, functions, help, hooks, logs, packaging, service_cmds, ui_nav, ui), then `shellcheck: clean`.

- [ ] **Step 2: Packaging sanity**

Run: `yq '.apps.zwave-js-ui.plugs, .parts.local.stage-packages' snap/snapcraft.yaml && git status --short`
Expected: five plugs without `log-observe`; stage packages `less` only; clean tree.

- [ ] **Step 3: Bring `main` in**

Run: `git fetch -q origin && git merge --no-edit origin/main && bash tests/hooks_test.sh | tail -1`
Expected: `Already up to date.` or a clean merge; suite still green. Nothing to commit here beyond the merge.
