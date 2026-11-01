# Package audit, wave 1: defects — design

Date: 2026-11-01. Status: draft for review. Wave 1 of 3 from the 2026-10-31 package
audit (wave 2: UX, wave 3: KISS/DRY). Baseline: `main` at 6a868a7, all 8 unit suites
green (294 tests), shellcheck clean.

Finding ids (A1…, C3, D2…) refer to the audit report; the reviewers' write-ups are not in
the repo, so every finding this wave fixes is restated here with its evidence.

## Intent

Fix the defects the audit confirmed in the snap's own code and docs, so that:

- a config change made with `snap set` or the navigator actually reaches the running
  daemon (today the hook's restart never fires, and navigator edits skip the hook
  entirely);
- `snap unset` and the navigator's "Reset to default" put a key back to its default
  instead of rejecting the call or leaving the key empty;
- the snap stops overriding upstream's 256-bit session secret with a time/MAC-based v1
  UUID that any local account can read;
- the daemon serving the LAN-facing web UI no longer carries a journal-reading plug it
  never uses;
- the backup key tooling can actually move the only decryption key off the device, and
  never puts a passphrase on a command line;
- the docs stop contradicting the code (plugs "optional" vs. a daemon that refuses to
  start; hooks attributed to the wrong file; a channel nothing publishes to).

Classification: **bounded**. Every item has a verified root cause and a small fix; no new
abstraction beyond one shared validator.

## Findings in scope (what is wrong today)

| Id | Where | Defect |
|---|---|---|
| A1 | `src/hooks/configure:35-39` | Restart gate counts "inactive" lines in the no-argument `snapctl services` listing. Since #193 (2026-06-10) the `backup-timer` oneshot is always listed inactive between its midnight runs, so the count is never 0 and `snapctl restart` never runs. Every `snap set` since then has silently not applied until a manual restart. Before #193 the gate fired on *every* `snap set` and, because snapd runs `configure` after `start-snap-services` on install and refresh, also restarted the freshly started daemon on every refresh; the `backup.*` keys (added after the gate died) were never exercised with a live restart. |
| A2 | `src/bin/ui:44-60` | The navigator writes with `snapctl set/unset` from the `ui` app. snapd commits an app-context ("ephemeral") `snapctl set` directly in `Context.Done()` and schedules **no** configure hook (snapd `daemon/api_snapctl.go`). So navigator edits are unvalidated, never restart the daemon, and "Reset to default" leaves the key unset. The June navigator spec assumed the opposite. |
| A3 | `src/hooks/configure:6-31` | The hook validates `server.port`, `server.ssl`, `session.cookie-secure` **before** `test_default_config` seeds them, and `snapctl get` of an unset key prints an empty string. `snap unset` of those keys is therefore always rejected, and an unset key (A2's reset) wedges every later `snap set`. The port regex also accepts `-5` and `99999`. |
| A4 | `src/bin/backup:345` | `export-key` runs plain `--export-secret-keys`; gpg-agent then needs a pinentry, which the snap does not stage (`/usr/bin/pinentry` is an alternatives symlink no package provides) and `GPG_TTY` is never set. Result: "No pinentry", nothing exported. `create-key` already uses loopback. |
| A5 | `src/bin/backup:86-92` | `status` probes the secret key with `--no-autostart`; after a reboot no agent runs and the probe fails, so "private key on this device: no" is shown for a key that is there. |
| A6 | `src/bin/ui:22`, `src/helper/ui:151`, `src/helper/catalog:23-29` | `IFS=$'\t' read` treats consecutive TABs as one delimiter; the advanced rows have an empty description, so the navigator shows `description: advanced` and loses the scope column. |
| A7 | `src/helper/functions:34-46` | `plugs_connected` buffers `plug_connected` output in `$( )`, but under `DAEMONIZED=1` `lprint` calls `logger` immediately inside the subshell. A serial-port user gets "Missing plug: «raw-usb» … snap connect …" in the journal on every daemon start although nothing is missing. |
| A8 | `src/helper/functions:110-127` | `yq -re` prints the literal `null` for a missing `deviceConfigPriorityDir` (exit status ignored); the function treats `null` as a stale path and rewrites settings.json to `""` on every refresh, logging "not writable: ". |
| A9 | `src/hooks/post-refresh:11-12` | `find … -print0` captured in `$( )` makes bash warn "ignored null byte in input" on every refresh. |
| D2 (+ D1 part 1) | `src/helper/functions:140`, `src/helper/env-wrapper:32`, `snap/snapcraft.yaml:210` | `session.secret` is seeded with `uuid` (OSSP, defaults to **v1**: timestamp + clock sequence + MAC) and always exported, so upstream's `resolveSessionSecret()` (v11.25.2: `randomBytes(32)` persisted 0600 as `$STORE_DIR/.session-secret`) never runs. `snapctl get` is allowed for non-root callers inside `snap run --shell`, so any local account can read the value. |
| D8 | `snap/snapcraft.yaml:92` | The `zwave-js-ui` daemon app plugs `log-observe`. Only `logs` and `ui` read the journal. Upstream exposes server-side "driver functions" to web users (no auth by default, bound to 0.0.0.0), so the plug extends what a LAN user can read to the whole system journal. |
| D11 | `src/bin/backup:299-300,310-311` | `create-key` passes the prompted passphrase as `--passphrase "$pass"`: visible in `/proc/<pid>/cmdline` to every local account while gpg runs, contradicting the comment above it. |
| C6 | `src/bin/backup:339-352` | `export-key` prints the private key to a terminal and then offers to delete it; `pick-key` refuses exactly this bare-TTY run, the dangerous command does not. |
| C7 | `src/bin/backup:215-219` | `import-key` typed without a pipe blocks on `cat > "$tmp"` with no prompt. |
| C8 | `src/bin/backup:290-293` | `create-key` asks the passphrase once, masked; a typo is discovered at restore time. |
| C3 | `README.md:95`, `snap/snapcraft.yaml:46-47` | Docs say the auto-connected plugs are optional; `env-wrapper:7` exits 1 without `hardware-observe` and one of `raw-usb`/`serial-port`, and the daemon crash-loops. |
| B2 | `CLAUDE.md:36,80-81`, `README.md:28` | Node pin literal is stale (22.20.0 vs 22.23.4, Renovate-moved); `pre-refresh`/`post-refresh` duties are attributed to the wrong hook; `latest/edge/dev` is a channel nothing publishes to. |
| C1 (docs part) | `README.md`, store description | Nothing a user reads says the service is disabled after install, how to enable it, or where the UI is. |
| D7 (workflow part) | `.github/workflows/lint-test.yml` | The only workflow without a `permissions:` block; inherits the repo default (write-all, may approve PRs). |

## Goals

- After this wave, every path that changes snap config (hook, navigator) validates the
  same way, re-seeds defaults the same way, and restarts (or offers to restart) the daemon.
- Secrets: the snap seeds no secret; upstream owns the session secret; no passphrase on argv.
- Backup key management works end to end inside the snap: create → export (to a file) →
  import, with the passphrase confirmed and never on a command line.
- The daemon's interface grants are exactly what it uses.
- README, store description and CLAUDE.md describe the code as it is.
- Every behavioural change has a unit test that fails on the old code (mutation-checked
  in the plan).

## Non-goals (deferred, with their wave)

- UX items C4–C5, C9–C23 (wave 2), including the `daemonize`/`help` "Web UI: http://…"
  lines proposed under C1; only C1's doc part is in this wave.
- KISS/DRY items B1, B3–B17 (wave 3), including deleting `pre-refresh` (B2d).
- Security items that are features or need a device to verify, not yet slotted:
  D9 (backend credentials out of `backup.target` into a root-only env file), D10
  (`chmod 700 $SNAP_DATA`), D12 (CI `${{ }}` interpolation), D13 (attenuate the Candid
  credential and rotate), D15 (SHA-pin actions, `source-commit` for gum). Proposed as a
  short "security hardening" wave after wave 1; Joachim decides.
- D4 (`minimumReleaseAge` for the zwave-js-ui and Node automerge rules) is a release-policy
  choice the maintainers made deliberately in #236; not changed here, listed for Joachim.
- GitHub settings D3, D5, D6, D7 (org/repo side), D14: admin actions, see the appendix.
  Only D7's workflow line is in the PR.
- No change to how `snap set` keys map to env vars, to the SSL/cookie logic, or to the
  backup/restore duplicity commands.
- The June navigator spec (`2026-06-28-cli-navigator-design.md`) is history and is not
  rewritten; this document supersedes its §2 "Apply" paragraph and its "Open item".

## Anti-goals

- No new config keys, no new commands, no new stage packages.
- No "restart unconditionally": a daemon the user disabled must stay disabled.
- No second table of defaults or validation rules anywhere; the catalog is the only source.
- No change that forces users to reconfigure anything other than the one documented
  re-login (D4 below).

## Constraints

- Hooks run as root with `DAEMONIZED=1` (output → syslog); never log secret values.
- Inside a snap app, `snapctl set/unset` commits without running the configure hook
  (verified in snapd source; this is why the navigator must validate itself).
- snapd runs the `configure` hook after `start-snap-services` on install and on every
  refresh, and gives the hook no way to learn why it runs or which key changed. Anything
  the hook decides must be derived from the current config plus state the snap keeps.
- `snapctl get` of an unset key prints an empty string with rc 0.
- The UI library captures TTY-ness of fd 1 at source time; widgets (`ui_input`,
  `ui_confirm`) are only interactive when stdout is a terminal. A command whose stdout is
  deliberately redirected (`export-key > file`) cannot use them.
- gpg inside the snap has no pinentry; all secret-key operations must use
  `--pinentry-mode loopback` with the passphrase on a file descriptor.
- The fixture `snapctl` on `tests/fixtures/bin` must stay backward compatible: `get`
  echoes `$SNAPCTL_<key>`, everything else is a quiet no-op unless a test opts in.
- One Launchpad build per PR; keep the wave in one PR.

## Decisions

### D1. The configure hook restarts the daemon only when the daemon's inputs changed and it is running
The catalog gains a sixth column, `applies`: `daemon` for every key `env-wrapper` turns
into an environment variable (`server.*`, `session.*`, `mqtt.name`, `timezone`,
`zwave.*`, `backup.dir`), `backup` for the keys only `bin/backup` reads at run time
(`backup.target`, `backup.encrypt`, `backup.encrypt-key`, `backup.full-if-older-than`,
`backup.retention`). `daemon_config_digest` (in `catalog`) prints the sha256 of
`key=value` lines for the `daemon` keys, read with `snapctl get`.
`env-wrapper` writes that digest to `$SNAP_COMMON/.daemon-config.sha256` (mode 0600)
every time the daemon starts: the file means "the config the running daemon was started
with". The hook computes the digest, and when it differs from the file **and**
`service_state` (already in `functions`, parses the `snapctl services
zwave-js-ui.zwave-js-ui` row) reports `active`, it runs
`snapctl restart "$SNAP_NAME.$SNAP_NAME"`; the restarted daemon rewrites the file. The
hook never writes the file itself; an equal digest, a missing file with an inactive
service, or a changed `backup`-only key means no restart.
**Why:** the no-argument listing includes `backup-timer`, inactive between runs since
#193, so the old count was never 0. Restarting only the main service, only when it is
running, keeps a disabled daemon disabled (install disables it by default) and does not
touch the timer. Comparing against what the daemon actually started with removes two
disruptions the old gate had or would have: a second Z-Wave driver init on every refresh
(the hook runs after the services are up; the digest is then equal), and up to five
restarts while a user sets up `backup.*` keys the daemon never reads. Letting
`env-wrapper` write the file keeps one writer, so a manual `zwave-js-ui.restart` or
`enable` after a declined navigator restart is also "current". The `applies` column is
new information in the single source of truth, not a second table; `help_test.sh`'s
field-count guard moves from 5 to 6 and `bin/help`'s row parser reads by field name.
Digest file holds a hash that includes secrets, hence 0600 and `$SNAP_COMMON` (root,
not in the store browser, survives refresh and revert).

### D2. The hook seeds defaults first, then validates every catalog key with a shared, catalog-driven validator
Order in `configure`: `test_default_config`, then `validate_config <key> <value>` for each
catalog key with a non-empty value; first failure prints `!! <key> <rule>, got <value>` to
stderr and exits 1 (snapd rolls the transaction back and `snap set` shows the line).
`validate_config` lives in `src/helper/catalog` (the hook sources it) and derives the rule
from the catalog type: `int` → `^[0-9]+$`; `bool` → `true|false`; `string`/`secret` →
anything; per-key extras: `server.port` 1–65535, `backup.dir` absolute path. Empty is
valid (means "default"). Keys not in the catalog are not checked.
**Why:** seeding first turns `snap unset` into "back to the default" (A3) and un-wedges a
key the navigator left empty (A2). Deriving rules from the catalog type means the keys the
hook already checked (`server.port`, `server.ssl`, `session.cookie-secure`, `backup.dir`)
are covered without a per-key table, and the navigator can call the same function.
Consequence to document: `server.force-disable-ssl`, `backup.encrypt` (bool) and
`backup.retention` (int) are now checked too; an existing bad value makes the next
`snap set` fail with the key named, and `snap unset <key>` is always the recovery.

### D3. The navigator does what the hook would have done: validate, write, re-seed on reset, offer a restart
`nav_set_apply` calls `validate_config` before `snapctl set`; on failure it shows the
message with `ui_err` and writes nothing. An empty edit is treated as "Reset to default".
Reset = `snapctl unset "$key"` followed by `test_default_config` run quietly (output
discarded, in a subshell so its `exit 1` cannot kill the navigator), then the banner shows
the resulting value (`(unset)` for keys whose default is unset). After any successful
write of a key with `applies=daemon`: if `service_state` reports `active`, ask
`Restart $SNAP_NAME to apply?` and run `${NAV_BIN:-$SNAP/bin}/restart` on yes (the
pattern `nav_mqtt` already uses); otherwise print "Takes effect when the service
starts." For `applies=backup` keys print "Used by the next backup run." A declined
restart is not lost: the daemon's digest file (D1) is now stale, so the next `snap set`
of any daemon key restarts it, which is correct.
**Why:** snapd gives app-context writes no hook, so parity has to be built in. Reusing
`test_default_config` for reset means the navigator and the hook seed by construction
the same values; a catalog-default-to-`snapctl set` translation would be a second table.
`snapctl` stays the writer (no `snap set` is available inside the sandbox).

### D4. The snap stops seeding `session.secret`; existing seeded values are removed once at refresh
`test_default_config` drops the `session.secret` line; `env-wrapper` exports
`SESSION_SECRET` only when the key is non-empty (the `MQTT_NAME` pattern); the catalog
row becomes `session.secret  secret  (unset)  Session secret; leave unset and the app
keeps its own 256-bit secret in the store (recommended)`; the `uuid` stage package goes
(sole consumer). `post-refresh` migrates: if the current value is a v1 UUID
(36 chars, hex and dashes, version nibble `1` at offset 14) it runs
`snapctl unset session.secret` and logs
`session.secret: removed the generated v1 UUID; the app now keeps its own secret in
$SNAP_DATA/.session-secret (one re-login)`. Any other value is kept as user-set.
**Why:** upstream v11.25.2 generates `randomBytes(32)` and persists it 0600 only when
`SESSION_SECRET` is absent; the seeded v1 UUID (60-bit timestamp + 14-bit clock sequence
+ MAC) is brute-forceable from a captured cookie, and `snapctl get` makes it readable by
any local account. Migrating at refresh rather than only for new installs fixes exactly
the installs that exist. Cost, verified in upstream `api/app.ts`: sessions live in a
`session-file-store` and API tokens are JWTs signed with the same secret, so the refresh
that lands this change logs every user out once and invalidates issued API tokens
(users re-create them in the UI). Alternative rejected: keep existing installs on their
UUID — leaves the weak, readable key on every current install forever.
*This is the one decision Joachim may want to reverse; it is flagged in the review.*

### D5. `log-observe` is removed from the daemon app
Delete it from the `zwave-js-ui` app's plug list in `snapcraft.yaml`; `ui` and `logs`
keep it. **Why:** the daemon never reads the journal; with upstream's driver functions
reachable by LAN users, the plug widens what they can read to every unit's logs. The
snap-level connection (`snap connect zwave-js-ui:log-observe`) is unaffected, so the
`logs` command keeps working.

### D6. Backup key flow: pipe-only export with a loopback passphrase, confirmed passphrase on a descriptor, honest status
- `export-key` refuses when stdout is a terminal (mirror `pick-key`), printing:
  `export-key writes the PRIVATE key to stdout — redirect it:
  sudo zwave-js-ui.backup export-key > zui-backup-key.asc` plus the import/offline hint.
  It prompts the passphrase with `IFS= read -rs -p 'Passphrase of the backup private
  key: ' pass` (prompt on stderr, echo off; `-s` only when stdin is a terminal; a pipe
  on stdin supplies the line), exports with `--batch --pinentry-mode loopback
  --passphrase-fd 0 --export-secret-keys --armor`, and asks the delete question with
  `read -rp` the same way (default No; no deletion when stdin is not a terminal).
  **Why:** the UI widgets are structurally non-interactive once stdout is redirected,
  and the snap has no pinentry; `pick-key` already prompts this way for the same reason.
- `create-key` prompts twice (`Passphrase for the new private key`, `Repeat passphrase`),
  refuses a mismatch with `Passphrases do not match — nothing created.`, says once that
  the passphrase is needed to restore and cannot be recovered, and feeds it to both gpg
  calls via `printf '%s\n' "$pass" | gpg … --passphrase-fd 0`. **Why:** C8 and D11; the
  `ui_input` non-interactive path reads one stdin line per call, so tests feed two lines.
- `import-key` prints `Paste the ARMORED PUBLIC key, then press Ctrl-D — or pipe it:
  zwave-js-ui.backup pick-key | sudo zwave-js-ui.backup import-key` to stderr before
  reading when stdin is a terminal. **Why:** C7; pasting interactively is legitimate.
- `status` decides "private key on this device" from the keyring on disk, not the agent:
  `gpg --with-colons --with-keygrip --list-keys <fpr>` gives the primary key's keygrip
  (`grp` record, field 10; works without an agent), and the secret key is present iff
  `$GNUPGHOME/private-keys-v1.d/<grip>.key` exists. **Why:** A5; the agent is down after
  every reboot, and `status` must stay read-only (it must not start a daemon).

### D7. Small correctness fixes as found
- A7: `plugs_connected` buffers with `RAW_OUT=$(DAEMONIZED=0 plug_connected raw-usb)`
  (same for serial-port) and re-emits through `lprint` only when both are missing.
- A8: `DEV_DIR=$(yq -r '.zwave.deviceConfigPriorityDir // ""' …)`; return 0 when empty;
  log "not writable" only for a non-empty path. A settings.json without the key is left
  byte-identical.
- A9: `rm -f "${SNAP_DATA}/.ext-config/devices/index.json"` (the path is fixed by
  `ZWAVEJS_EXTERNAL_CONFIG`); no `find`.
- A6: `catalog_field <key> <n>` (awk `-F'\t'`) replaces `IFS=$'\t' read` in the
  navigator; `ui_stack` splits rows the same way; the seven `zwave.*` rows
  (`serial-port` plus six keys) get real descriptions (device path / which network key,
  with the env var name).
- D7 (workflow): `permissions: contents: read` at the top of `lint-test.yml`.

### D8. Docs say what the code does
- README: "Auto-Connections" becomes "Interfaces": `hardware-observe` plus one of
  `raw-usb`/`serial-port` are **required**, the service will not start without them, and
  `zwave-js-ui.enable` names the missing one; keep the manual connect commands, drop the
  "disconnect for tighter isolation" advice; drop `latest/edge/dev`; add a "Getting
  started" block before the features (`sudo snap install zwave-js-ui`,
  `sudo zwave-js-ui.enable`, `http://<host>:8091`, `zwave-js-ui.help` / `.ui`).
- `snapcraft.yaml` description: same plug truth and the same three getting-started lines.
- CLAUDE.md: Node line → "Node 22.x (Renovate-tracked, `allowedVersions <23`)"; hooks
  section rewritten per D1/D2/D4/D7 (`configure`: seed, validate via the catalog, restart
  the daemon only when it is active and its inputs changed since it started, per the
  digest `env-wrapper` writes; `pre-refresh`: seeds; `post-refresh`: seeds, migrates
  `deviceConfigPriorityDir`, clears `devices/index.json`, removes a seeded v1 session
  secret); navigator sentence: validates with the same `validate_config` and offers a
  restart; `env-wrapper` mapping: `session.secret` exported only when set; backup
  paragraph: `export-key` is pipe-only and prompts on the terminal.
**Why:** C3 sends users into a crash loop; B2 sends the next agent to the wrong hook.

### D9. One PR, one commit per finding, Joachim merges
Branch `fix/audit-wave1-defects`; commits titled by finding (`fix(hook): … (A1)`), docs
last. **Why:** one Launchpad build and one release for the wave; per-finding commits keep
the review and any revert scoped. Merge of `main` into the branch before review, per the
house rule.

### D10. Tests: a hook suite, process-level, with an opt-in logging snapctl fixture
New `tests/hooks_test.sh` runs the hooks as processes (`bash src/hooks/configure`) with
`tests/fixtures/bin` on PATH. The fixture `snapctl` gains: `services` prints a
two-service listing whose main-service state comes from `$SNAPCTL_MAIN_STATE`
(default `active`); `set`/`unset`/`restart` append `<verb> <args>` to `$SNAPCTL_LOG` when
it is set; `is-connected` honours `$SNAPCTL_CONNECTED` (space-separated plug names) when
set. Default behaviour (no env) is unchanged for `env_wrapper_test.sh`.
The hooks suite gets its own fixture tree whose `helper/functions` loads the real
library (the existing `tests/fixtures/helper/functions` is a stub that
`env_wrapper_test.sh` depends on); the A8 case keeps its `SNAP_DATA` under the checkout,
because the yq snap cannot read `/tmp`.
Cases: with the timer line inactive and the main service `active`, restart is logged
when the digest file is missing or differs and **not** when it equals the current
digest (the refresh case) nor when only `backup.target` changed (A1); the main service
inactive → never a restart; `env-wrapper` writes the digest file 0600 and the file
contains no config value (`env_wrapper_test.sh`);
unset `server.port` → `set server.port=8091` logged, rc 0 (A3); `server.port=abc`,
`0`, `70000` → rc 1 with the key named; `backup.dir=relative` → rc 1; post-refresh:
v1 UUID → `unset session.secret` logged and the notice (value absent from output);
v4 or custom value → no unset; `index.json` removed with no bash warning on stderr;
settings.json without `deviceConfigPriorityDir` unchanged (A8).
Navigator (`ui_nav_test.sh`): rejection now comes from `validate_config` with no
`snapctl set` logged; reset logs `unset` then `set server.port=8091`; restart offer calls
the `NAV_BIN` shim on yes, is skipped when the state is inactive, and is not made for a
`backup`-only key (`backup.target` → "Used by the next backup run").
Backup (`backup_test.sh`): export-key refuses on a TTY (`script -qec`); passphrase
reaches gpg on fd 0 (stub gpg records argv and stdin; argv must not contain the
passphrase); create-key mismatch → nothing created; import-key hint on a TTY; status
on-disk probe yes/no/unknown. Functions: `validate_config` matrix; A7 (logger stub
receives nothing when only raw-usb is missing); A8.
**Why:** the suites were green with A1–A3 present because nothing ran the hooks and the
navigator test modelled a hook verdict snapd never produces (its "rejection surfaces
the hook message" case is replaced, not kept).

## Out of CI: device verification before merge (per-PR channel)

Install `v11.25/edge/pr-<N>` on a device with the daemon enabled and check:
1. `sudo snap set zwave-js-ui server.port=8092` → `snap changes` shows the configure
   hook and the daemon restarts (journal), the UI answers on 8092; `snap unset` → 8091;
   `sudo snap set zwave-js-ui backup.retention=4` → no restart in the journal; the
   refresh itself shows one daemon start, not two.
2. `sudo zwave-js-ui.ui` → Settings → `server.port` → `abc` is rejected in place; Reset
   to default shows 8091 and offers the restart.
3. After the refresh: `snap get zwave-js-ui session.secret` is unset,
   `/var/snap/zwave-js-ui/current/.session-secret` exists with mode 0600, the UI login
   works (once more).
4. `snap connections zwave-js-ui | grep log-observe` still lists the connection; the
   daemon starts; `zwave-js-ui.logs` works.
5. `sudo zwave-js-ui.backup create-key` (two prompts) → `sudo zwave-js-ui.backup
   export-key > k.asc` (passphrase prompt on the terminal, file non-empty) → `status`
   shows "private key on this device: yes" after a reboot.

## Appendix: admin actions (GitHub), not in the PR

These need the org owner. Items marked *gh* can be run by the orchestrator on Joachim's
go; the others are quickest in the web UI.

- **D6, dead secrets** (*gh*): `gh secret delete REPO_WRITE_TOKEN -R giaever-online-iot/zwave-js-ui`,
  `gh secret delete ZUI_PAT_TOKEN -R giaever-online-iot/zwave-js-ui`,
  `gh secret delete SNAPCRAFT_SESSION --org giaever-online-iot`,
  `gh secret delete SNAPCRAFT_SESSION_COOKIE --org giaever-online-iot`; then revoke the
  two PATs at github.com/settings/tokens (deleting a secret does not invalidate the token).
- **D7, default token** (*gh*): `gh api -X PUT repos/giaever-online-iot/zwave-js-ui/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false`
  and the same on `orgs/giaever-online-iot/actions/permissions/workflow`. Every workflow
  already declares what it needs (after this PR, `lint-test` too).
- **D5, org secret visibility** (web): Organization settings → Secrets and variables →
  Actions → `SNAPCRAFT_STORE_CREDENTIALS` and `LAUNCHPAD_CREDENTIALS` → Repository
  access: *Selected repositories* → only the snap repos that build and publish.
- **D3, review requirement** (web): Settings → Rules → Rulesets → New branch ruleset:
  target `main`; "Require a pull request before merging" with 1 approval and "Dismiss
  stale approvals"; Bypass list: the Renovate app and the Repository admin role; keep the
  existing required status checks. Result: the outside collaborator's merges need a
  second human; Renovate automerge and the solo-maintainer flow are unchanged.
- **D14, Greptile** (web): the app's installation → Repository access: only the repos
  that use it (or uninstall).
- **D15, scanning** (*gh*): `gh api -X PATCH repos/giaever-online-iot/zwave-js-ui -f 'security_and_analysis[secret_scanning][status]=enabled' -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'`.
- **D4, automerge cooldown** (decision, repo change if yes): add
  `"minimumReleaseAge": "3 days"` to the zwave-js-ui and Node package rules and limit
  automerge to minor/patch. Not done in this wave; say yes/no.
