# Package audit, wave 2: UX — design

Date: 2026-11-02. Status: draft for review. Wave 2 of 3 from the 2026-10-31 package audit
(wave 1, defects, shipped as #257 / d95695a, revision 1063; wave 3, KISS/DRY, follows this one).
Baseline: `main` at d95695a, 11 suites / 502 tests green, shellcheck clean.

Finding ids (C4…, "polish") refer to the audit's UX report (`C-ux.md`, not in the repo); each
item is restated below. Wave 1 already fixed C1 (docs part), C2, C3, C6, C7, C8 and C11.

## Intent

Make the snap's own commands tell the truth and catch mistakes at the moment the user is
watching. Today a typo in `snap set` is accepted silently, `backup restore` fails in its
normal case with a traceback, `help` says the daemon is disabled while it runs, the
navigator makes the user retype long values, `backup status` cannot say whether last
night's backup worked, and several messages send the user the wrong way.

Classification: **bounded**. About twenty independent, small UX changes on existing
commands; one new piece of state (`$SNAP_COMMON/backup.last`). No new commands, no new
dependencies.

## Findings in scope

| Id | Defect today |
|---|---|
| C4 | Unknown `snap set` keys (`server.prot`, `mqtt.host`) are accepted silently; `mqtt.host`/`port`/`username`/`password` live in settings.json (navigator → MQTT broker), only `mqtt.name` is snap config, and nothing says so. |
| C5 | `backup restore` restores into the live backup dir; with ZUI's backups still there duplicity refuses (traceback, `AssertionError`); `<time>` is undocumented. |
| C9 | `NO_COLOR=1` (or `TERM=dumb`) makes `zwave-js-ui.ui` refuse to run, claiming there is no interactive terminal. |
| C10 | Navigator edits: no prefill (retype a whole URL to fix one character), bool edit does not mark the current value, header promises "type to filter" that `gum choose` cannot do, `← Back` sits below the 10-row fold. |
| C12 | `timezone=Europe/Oslo` is seeded on every install and re-seeded after `snap unset`; the maintainer's zone is not a sensible Store default and "empty" cannot mean "host time". |
| C13 | `session.cookie-secure` is seeded once from `server.ssl` at install; enabling HTTPS later leaves cookies insecure while `help` shows `(= server.ssl)`; `cookie-secure=true` with `ssl=false` is silently dropped. |
| C14 | Still unchecked after wave 1: `backup.target` (a typo fails only at 00:00 in the journal) and `backup.full-if-older-than`. |
| C15 | `backup status` shows no last run or outcome, renders the timer as "enabled/inactive", and says "private key on this device: no" to users who deliberately imported only a public key. |
| C16 | `help`, `backup status`, `backup list` vanish when the pager closes (less without `-X`). |
| C17 | Without the `gpg-public-keys` plug, `list-keys`/`pick-key` say "No host GPG keyring" and tell the user to generate a new key. |
| C18 | `logs` legend says `q quit`; in follow mode less ignores `q` until Ctrl-C. |
| C19 | `require_root` prints half its message on stderr and half on stdout. |
| C20 + C1 | `help` always says "The daemon is DISABLED by default…", even when the header shows it running; neither `help` nor `enable` shows the web UI address. |
| C21 | `help`'s command table does not mark which commands need sudo and says "daemonize". |
| C22 | A successful manual `backup` prints only duplicity's statistics block. |
| C23 | README "Snap-Specific Features" lists two of the snap's commands; no configuration section; `gpg-public-keys`/`log-observe` missing from the connect examples. |
| Polish | Listed under D15. |

## Goals

- Every `snap set` mistake the catalog can recognise is rejected at `snap set` time with a
  message that names the key, the rule, and where the setting really lives.
- `help` and `enable` show the true state and the address of the web UI.
- `backup` tells the user what it did and when it last ran, and `restore` works with a
  populated backup dir.
- The navigator edits values in place.
- Refreshes never fail because a stored value became invalid (the wave-1 sanitizer covers
  every new rule).

## Non-goals

- KISS/DRY refactors (wave 3), including any restructuring of `help`/`ui`/`backup`.
- Security items D9/D10/D12/D13/D15 and the GitHub admin appendix (unchanged from wave 1).
- A configurable backup schedule (still descoped; D8 only moves the fixed time).
- Changing the hook's `!! ` message prefix (tests and docs quote it; snapd wraps it anyway).
- The live `logs` viewer's own screen handling (keeps the alternate screen).

## Anti-goals

- No setting changes value on existing installs except where a decision below says so.
- No command that worked non-interactively before stops working without a terminal.
- No second table of keys, types or defaults outside the catalog.

## Constraints (carried from wave 1, verified)

- snapd runs `configure` after `start-snap-services` on install and refresh; a failing
  `configure` must never be possible from stored values (post-refresh `sanitize_config`
  runs first and unsets anything `validate_config` rejects).
- The hook's stderr reaches the user only when it fails; there is no way to warn on success.
- `snapctl get -d` prints the whole snap config as nested JSON; snapd stores `server.host` as
  `{"server":{"host":…}}`.
- Strict snaps see the host's `/etc` (so `/etc/localtime` and `/etc/timezone` are readable);
  the `help` app has no plugs.
- gum v0.17.0: `input --value`, `choose --selected`, `choose --height` exist; `choose` has no
  filtering (`gum filter` does).
- CI runs on ubuntu-26.04 (bash 5.3, newer shellcheck): write `_rc=0; [ … ] || _rc=1` instead
  of `[ … ]; assert_status "$?"`, and never rely on a prefix assignment leaking out of a function.

## Decisions

### D1. Unknown keys are rejected; refresh removes them (C4)
`validate_config` gains a companion `unknown_config_keys`: it flattens `snapctl get -d` to
dotted leaf paths (yq) and prints every path that is not a catalog key. `configure` fails on
the first one: `!! unknown setting "<key>". Known settings: zwave-js-ui.help`, with one extra
line for `mqtt.*` keys: `MQTT broker settings live in settings.json — sudo zwave-js-ui.ui →
MQTT broker` (only `mqtt.name` is snap config). `sanitize_config` (post-refresh) also unsets
unknown keys, logging the key, never the value.
**Why:** the user is watching at `snap set`; a typo that "works" is the worst outcome.
Unsetting on refresh is the only way a stray key from the past cannot fail every future
refresh; such keys never had any effect, so nothing that worked stops working.
*Flagged for Joachim:* this removes stray keys from existing installs.

### D2. `restore` writes into a fresh directory (C5)
`restore [<time>]` restores into `$(backup_dir)/restored-<UTC YYYYMMDD-HHMMSS>` (created
empty) and ends with `✓ Restored into <dir> — pick the files in ZUI → Settings → Backup →
Restore (or the store browser).` A new `--into <empty dir>` option overrides the target and
refuses a non-empty dir with `<dir> is not empty — choose an empty directory`. Usage
documents `<time>` as `e.g. 2026-10-30, 2026-10-30T02:00, 3D (three days ago)`.
**Why:** restoring an older backup while current ones exist is the normal recovery case;
never overwriting the live dir needs no `--force` and cannot destroy anything.
*To verify on device:* that ZUI's restore UI can reach files in the sub-directory (if not,
the message points to the store browser, which can).

### D3. `NO_COLOR` means no colour, not no widgets (C9)
`ui_ctx` stops treating `NO_COLOR` as "plain": with a TTY and gum the context stays
`styled`, gum inherits `NO_COLOR` (it honours it), and the library's own colour escapes
(`ui_ok`/`ui_warn`/`ui_err` glyph colours, the logs hint) check `NO_COLOR`. `TERM=dumb`
stays plain, and `ui` then says `zwave-js-ui.ui needs a terminal that can draw menus
(TERM=dumb) — use the zwave-js-ui.* commands, or run with a different TERM`.
**Why:** NO_COLOR (no-color.org) is a colour preference; `TERM=dumb` genuinely cannot draw.

### D4. Navigator edits in place (C10)
`ui_input` gains `--value <initial>`; Settings edits pass the current value for non-secret
keys (never for secrets). Bool edits pass `--selected "$cur"`. Every `ui_choose` list puts
`← Back` first and passes `--height` = `ui_lines` − 6 (minimum 5). The header loses "(type to
filter)" and its comment.
**Why:** retyping long values is where typos come from; a header must not teach a key that
does nothing. `gum filter` was considered and rejected: a different widget with different
keys for one list.

### D5. `timezone` is no longer seeded; empty means host time (C12)
`test_default_config` stops seeding `timezone`; `env-wrapper` exports `TZ` only when the key
is set (already the code); the catalog default becomes `(host time)` with description
`Timezone for the app (TZ), e.g. America/New_York; unset = the host's zone`. Existing
installs keep whatever they have (including Europe/Oslo); `snap unset zwave-js-ui timezone`
now means host time.
**Why:** strict snaps already see the host's `/etc/localtime`, so not exporting `TZ` is
"host time" with no detection code; the seeded value was the maintainer's zone.
*Flagged for Joachim:* new installs no longer default to Europe/Oslo.

### D6. `session.cookie-secure` follows HTTPS unless set (C13)
Stop seeding `session.cookie-secure`. `env-wrapper`: when the key is empty,
`USE_SECURE_COOKIE` follows effective HTTPS (ssl on and not force-disabled); when set, as
today. `configure` rejects `session.cookie-secure=true` while `server.ssl=false`:
`!! session.cookie-secure=true needs server.ssl=true (secure cookies only work over HTTPS)`;
`sanitize_config` unsets it in that combination on refresh. Catalog default becomes
`(follows server.ssl)`; `help` shows the effective value for an unset key as
`(follows server.ssl: true)`.
**Why:** the one-time copy at install is what makes enabling HTTPS later insecure; existing
installs keep their stored value, which equals what they had.

### D7. Backup keys are validated (C14)
`backup.target` must match `^[a-z][a-z0-9+.-]*://.+` (rule: `a duplicity URL like
sftp://user@nas/zui, s3://bucket/path or file:///mnt/usb/zui`); `backup.full-if-older-than`
must match `^[0-9]+[smhDWMY]$` (rule: `a duplicity interval like 7D or 2W`). Both go through
`validate_config`, so `snap set`, the navigator and `sanitize_config` apply them.
**Why:** the failure otherwise surfaces at 00:00 in a journal the user was never pointed at.

### D8. `backup status` answers "did it run" (C15)
Every backup run (manual and timer) writes `$SNAP_COMMON/backup.last` (0600, one line:
`<ISO-8601 UTC> ok|failed <rc> full|incremental|-`). `status` shows
`last run   2026-11-02 03:00 UTC  OK (incremental)` or
`last run   … FAILED (rc 23) — see: sudo snap logs zwave-js-ui.backup-timer`, or `never`.
The timer row reads `enabled — runs daily at 03:00 (idle between runs)` /
`disabled`; the key row reads `private key in snap keyring  yes` or
`no (public key only — restore needs the private key)`. The timer moves from `00:00` to
`03:00`.
**Why:** silent nightly failures go unnoticed for weeks. 03:00 runs after ZUI's own
scheduled backup (its default schedule is midnight — not verified, hence a margin) instead
of racing it.
*Flagged for Joachim:* the timer time change.

### D9. Pagers keep their output on screen (C16)
`ui_pager` uses `less -RX`. The live logs viewer is unchanged.

### D10. Missing `gpg-public-keys` is named (C17)
`require_host_keyring` checks `snapctl is-connected gpg-public-keys` first (allowed for
non-root) and, when it is not connected, says `The gpg-public-keys interface is not
connected, so your ~/.gnupg is not visible to the snap. Run: sudo snap connect
zwave-js-ui:gpg-public-keys`. `backup --help` and README's Interfaces section mention it.

### D11. `logs` legend tells the truth about `q` (C18)
Usage and the hint line: `Ctrl-C pause following (then scroll, search…) · F resume · q quit
(after Ctrl-C)`.

### D12. `require_root` is one line on stderr (C19)
`<command> must run as root — re-run with sudo.` on stderr, exit 1 (unchanged exit code, so
nothing that tests for 1 breaks). `<command>` is `$SNAP_NAME.<app>` from
`SNAP_COMMAND_NAME`/`$0`.

### D13. `help` and `enable` show the state and the address (C20, C1)
`web_ui_url` (functions): scheme `https` when HTTPS is effective, else `http`; host
`server.host` unless it is `0.0.0.0`/empty, then the literal `<this-machine>`; port
`server.port`. `help` opens with, by `service_state`: active →
`Running — web UI: <url>   stop: sudo zwave-js-ui.disable`; enabled-inactive →
`Enabled but not running — see: sudo zwave-js-ui.logs`; disabled → today's text. `enable`
prints `Web UI: <url>` after `Service enabled`, and its next-steps table adds
`sudo zwave-js-ui.ui`.
**Why:** the most common first-run question is "where is the UI".

### D14. `help`'s command table: sudo and plain words (C21)
Rows become `sudo zwave-js-ui.enable  start the service now and at every boot`,
`sudo zwave-js-ui.disable  stop it and do not start at boot`, `sudo zwave-js-ui.restart`,
`sudo zwave-js-ui.exec  run in the foreground (debug start-up)`, `sudo zwave-js-ui.ui`,
`sudo zwave-js-ui.logs [zui|zwjs]`, `zwave-js-ui.backup ...  (see --help; most need sudo)`
(ASCII `...`, fixing the misaligned `…` row), `zwave-js-ui.help  this overview (no sudo)`.

### D15. Small fixes (C22, C23, polish)
- C22: after a successful run `backup` prints `✓ Shipped <dir> to <target, credentials
  redacted> (<full|incremental>)` and logs the same line for the timer.
- C23: README "Snap-Specific Features" becomes a command table (same rows as `help`) plus a
  "Configuration" subsection (namespaces, one `snap set` example each, the `mqtt.*` split);
  connect examples gain `gpg-public-keys` and `log-observe`.
- Plug messages: `Missing interface: raw-usb` (no guillemets), connect commands without a
  `$ ` prefix, one header `Connect raw-usb (USB stick) OR serial-port (see zwave-js-ui.help):`
  instead of `----- OR -----`.
- Navigator MQTT section warns about the daemon overwriting settings and offers a restart
  only when `service_state` is active.
- Log-stream pickers (`ui` and `logs`) get a `← Back` item.
- Plug purpose text: `required — detects the controller; pair with raw-usb or serial-port`.
- `ensure_agent` failure: `could not start gpg-agent — on kernel 6.17+ this is snap
  confinement's AF_UNIX mediation; otherwise see: sudo snap logs zwave-js-ui`.
- `ui_pause` says `press Enter to continue` and accepts Enter.
- `logs` usage: `(no arg)  follow both streams (on a terminal: asks which)`.
- Catalog: shorten the two longest descriptions so the `help` table fits 100 columns.
- `snapcraft.yaml`: title `Z-Wave JS UI`; typos `MQTT apis`, `integation`, `full-fledge`,
  `«store-folder»`, `Z-wave`.

### D16. Tests and verification
Each decision gets tests that fail on today's code (process-level for hooks, the stateful
fixture `snapctl` — which gains `get -d` returning nested JSON built from its state dir).
Mutation checks on the D1 rejection, the D6 cross-key rule and the D8 status line.
One PR, one commit per decision, Joachim merges.

## Device verification (per-PR channel)

1. `sudo snap set zwave-js-ui server.prot=1` → rejected naming the key; `mqtt.host=x` →
   rejected with the navigator hint.
2. `sudo zwave-js-ui.backup restore` with backups present → `restored-<stamp>` created; ZUI
   can restore from it (or the message's fallback works).
3. `NO_COLOR=1 sudo zwave-js-ui.ui` opens the menus.
4. `sudo snap unset zwave-js-ui timezone` → ZUI logs show host time.
5. `sudo snap set zwave-js-ui server.ssl=true` (with certificates) → secure cookie set
   without touching `session.cookie-secure`.
6. After a timer run: `sudo zwave-js-ui.backup status` shows the last run.
7. `zwave-js-ui.help` with the daemon running shows `Running — web UI: …`.
