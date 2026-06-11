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
assert_eq "$(ui_ok 'done')"          "OK: done"     "ok plain"
assert_eq "$(ui_warn careful 2>&1)"  "WARN: careful" "warn plain -> stderr"
assert_eq "$(ui_err broken 2>&1)"    "ERROR: broken" "err plain -> stderr"

# warn/err go to stderr, not stdout
assert_eq "$(ui_err broken 2>/dev/null)" "" "err writes nothing to stdout"

# --- status output: styled goes through gum ------------------------------
assert_contains "$(UI_ASSUME_TTY=1 ui_ok 'done')"    "[style] ✓ done"   "ok styled via gum"
assert_contains "$(UI_ASSUME_TTY=1 ui_err broken 2>&1)" "[style] ✗ broken" "err styled via gum"
assert_contains "$(UI_ASSUME_TTY=1 ui_header T)"     "[style] T"        "header styled via gum"

# --- zero ANSI bytes in plain mode ---------------------------------------
out="$(ui_header T; ui_ok a; ui_warn b 2>&1; ui_err c 2>&1)"
printf '%s' "$out" | grep -q "$(printf '\033')"
assert_status "$?" "1" "plain mode emits zero ANSI bytes"

# Real fd-2 regression: UI_TTY_FDS=1 says ONLY fd 1 is a TTY. Buggy code keying
# ui_err on fd 1 would emit styled output here; correct code sees fd 2 is not a
# TTY and stays plain.
assert_eq "$(UI_TTY_FDS=1 ui_err leak 2>&1 1>/dev/null)" "ERROR: leak" "err keys context on fd 2"
assert_contains "$(UI_TTY_FDS='1 2' ui_err leak 2>&1 1>/dev/null)" "[style] ✗ leak" "err styles when fd 2 is a TTY"

finish
