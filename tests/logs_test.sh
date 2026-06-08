#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

# Source the script under test with a stubbed snap runtime.
export SNAP="$HERE/fixtures"
export SNAP_DATA="$(mktemp -d)"
trap 'rm -rf "$SNAP_DATA"' EXIT
# shellcheck source=/dev/null
source "$ROOT/src/bin/logs"

# --- tests appended by later tasks ---

finish
