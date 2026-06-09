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
