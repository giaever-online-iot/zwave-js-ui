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
