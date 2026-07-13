#!/usr/bin/env bash
# Unit tests for src/helper/functions (the shared bash library sourced by every
# hook and bin script). Same harness as the other suites: stub snapctl, source
# the real library, assert on rendered output.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

export SNAP="$HERE/fixtures"
export SNAP_NAME="zwave-js-ui"

# snapctl stub: `get` always misses so testnset_config takes its `set` branch;
# `set` succeeds silently.
snapctl() { case "$1" in get) return 1 ;; *) : ;; esac; }

# shellcheck source=/dev/null
source "$ROOT/src/helper/functions"

# --- testnset_config: hooks run DAEMONIZED, so its lprints land in syslog.
# Secret values must be redacted there; everything else stays verbatim.

out="$(testnset_config "session.secret" "SUPERSECRET")"
assert_contains     "$out" "session.secret=(redacted)" "secret: value redacted in log line"
assert_not_contains "$out" "SUPERSECRET"               "secret: raw value absent from log output"

out="$(testnset_config "server.port" "8091")"
assert_contains "$out" "Setting server.port=8091" "non-secret: value logged verbatim"

finish
