#!/usr/bin/env bash
set -u
# Pin a clean rendering baseline: GitHub Actions runners export no TERM, and
# bash then defaults TERM=dumb — which forces plain ctx and overrides
# UI_ASSUME_TTY, failing every styled assertion. The per-assertion
# NO_COLOR=1 / TERM=dumb matrix checks below set their own values inline.
export TERM=xterm-256color
unset NO_COLOR
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

# Deterministic baseline regardless of where the suite runs: the library caches
# TTY-ness at source time (UI_TTY1/UI_TTY2), which would be 1 on a developer's
# terminal — pin both to 0 so "no TTY" assertions hold everywhere.
# shellcheck disable=SC2034  # read by ui_ctx in the sourced library
UI_TTY1=0
# shellcheck disable=SC2034
UI_TTY2=0

# --- context resolution -------------------------------------------------
# Baseline is plain (flags pinned above); UI_ASSUME_TTY=1 simulates a TTY.
assert_eq "$(ui_ctx)"                                  "plain"  "no TTY -> plain"
assert_eq "$(UI_TTY1=1 ui_ctx)"                        "styled" "cached fd1 TTY flag -> styled"
assert_eq "$(UI_TTY1=1 ui_ctx 2)"                      "plain"  "fd2 keyed: fd1 flag alone is not enough"
assert_eq "$(UI_TTY2=1 ui_ctx 2)"                      "styled" "cached fd2 TTY flag -> styled for fd2"
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

# --- ui_align / ui_table / ui_kv -----------------------------------------
assert_eq "$(printf 'a\tbb\nccc\td\n' | ui_align)" "$(printf 'a    bb\nccc  d')" "align pads columns"

out="$(printf 'k1\tv1\nk2\tv2\n' | ui_table key value)"
assert_contains "$out" "key"   "table plain: header row"
assert_contains "$out" "k2"    "table plain: data row"
printf '%s' "$out" | grep -q "$(printf '\033')"
assert_status "$?" "1" "table plain: zero ANSI"

# Header must be TAB-joined so ui_align sees N columns: with data wider than
# the header, the header's second column must align with the data's second.
assert_eq "$(printf 'wide-key\tv\n' | ui_table k h)" "$(printf 'k         h\nwide-key  v')" "table plain: header is tab-joined and aligned"

assert_contains "$(printf 'k\tv\n' | UI_ASSUME_TTY=1 ui_table key value)" "[table]" "table styled via gum"

out="$(ui_kv alpha 1 beta 2)"
assert_contains "$out" "alpha" "kv: first key"
assert_contains "$out" "2"     "kv: last value"

# --- ui_usage --------------------------------------------------------------
assert_eq "$(printf 'Usage: x\n' | ui_usage)" "Usage: x" "usage plain: cat"
assert_contains "$(printf 'Usage: x\n' | UI_ASSUME_TTY=1 ui_usage)" "[format] Usage: x" "usage styled via gum format"

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
ui_spin 'W' false >/dev/null; assert_status "$?" "1" "spin propagates command status"

# --- ui_interactive: UI_TTY_FDS must list fd 0 for widgets -------------------
assert_eq "$(UI_TTY_FDS='0 1' ui_interactive; echo $?)" "0" "UI_TTY_FDS with fd 0 -> interactive"
assert_eq "$(UI_TTY_FDS='1' ui_interactive; echo $?)" "1" "UI_TTY_FDS without fd 0 -> not interactive"

# --- Ctrl-C (gum exit 130) is normalized to the library's "2 = cannot ask/aborted"
GUM_ABORT=1 UI_ASSUME_TTY=1 ui_choose 'P' 'hint' a b >/dev/null 2>&1; assert_status "$?" "2" "choose: ctrl-c -> 2"
GUM_ABORT=1 UI_ASSUME_TTY=1 ui_input 'P' >/dev/null 2>&1;            assert_status "$?" "2" "input: ctrl-c -> 2"
GUM_ABORT=1 UI_ASSUME_TTY=1 ui_confirm 'P' >/dev/null 2>&1;          assert_status "$?" "2" "confirm: ctrl-c -> 2"
GUM_CONFIRM=1 UI_ASSUME_TTY=1 ui_confirm 'P'; assert_status "$?" "1" "confirm: plain no still 1"

# --- real-pty integration (the rev-881 field bug) -----------------------------
# Every ui_* body resolves its context via `case "$(ui_ctx)" in`; a live
# [ -t 1 ] inside that $( ) is ALWAYS false (fd 1 is the capture pipe), so
# styled mode could never engage on a real terminal — only the source-time
# UI_TTY1/UI_TTY2 capture makes it reachable. Run on an actual pty via
# script(1), with no test overrides, and demand the styled path.
if command -v script >/dev/null 2>&1; then
    pty_out="$(SNAP="$SNAP" ROOT="$ROOT" script -qec 'bash -c "source \"$SNAP/helper/functions\"; source \"$ROOT/src/helper/ui\"; ui_ok pty-styled"' /dev/null)"
    assert_contains "$pty_out" "[style] ✓ pty-styled" "real pty -> styled (rev-881 regression)"
else
    echo "skip: script(1) unavailable — pty regression not run" >&2
fi

# --- ui_cols: terminal width detection ----------------------------------------
# UI_COLS is the test/override hatch; the auto path reads the real winsize off a
# fd that command substitution does NOT rebind (controlling tty, then fd2/fd0).
assert_eq "$(UI_COLS=137 ui_cols)" "137" "ui_cols honors UI_COLS override"
# With no override it must still yield a positive integer (failed reads -> 80).
cols_auto="$(UI_COLS='' ui_cols)"
case "$cols_auto" in
    ''|0|*[!0-9]*) FAIL=$((FAIL+1)); printf 'FAIL: ui_cols not a positive int: %q\n' "$cols_auto" >&2 ;;
    *) PASS=$((PASS+1)) ;;
esac
# Auto-detect reads the actual terminal winsize on a real pty (set via stty).
if command -v script >/dev/null 2>&1; then
    cw="$(ROOT="$ROOT" script -qec 'stty cols 91 2>/dev/null; bash -c "source \"$ROOT/src/helper/ui\"; ui_cols"' /dev/null | tr -d '\r')"
    assert_contains "$cw" "91" "ui_cols reads real pty winsize"
fi
# Regression: inside `settings_rows | settings_render`, ui_cols runs with fd 0 = a
# pipe, so the width must come off fd 2. Emulate with setsid (no controlling tty,
# so /dev/tty is unavailable) + stdin closed. The redirect order must dup fd 2
# BEFORE redirecting it to /dev/null — `2>/dev/null <&2` silently reads /dev/null.
if command -v script >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1; then
    cw2="$(ROOT="$ROOT" script -qec 'stty cols 77 2>/dev/null; setsid bash -c "source \"$ROOT/src/helper/ui\"; ui_cols" </dev/null' /dev/null | tr -d '\r')"
    assert_contains "$cw2" "77" "ui_cols reads fd2 winsize with no controlling tty / piped stdin"
fi

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

finish
