#!/usr/bin/env bash
# Unit tests for pr-comment.sh. Pure: no network. Asserts the three renderings.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC="$HERE/pr-comment.sh"
export SNAP_NAME=zwave-js-ui
fail=0
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then printf 'ok   - %s\n' "$1"; else printf 'FAIL - %s\n       missing: [%s]\n       in:      [%s]\n' "$1" "$3" "$2"; fail=1; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then printf 'FAIL - %s\n       unexpected: [%s]\n' "$1" "$3"; fail=1; else printf 'ok   - %s\n' "$1"; fi; }

CH="v11.21/edge/210"

all="$("$PC" "$CH" "amd64,arm64,armhf" "amd64,arm64,armhf")"
has   "all: success header"      "$all" "✅ Published to \`$CH\`"
has   "all: lists every arch"    "$all" "Architectures: amd64, arm64, armhf"
has   "all: install command"     "$all" "sudo snap install zwave-js-ui --channel=$CH"
has   "all: auto-selects note"   "$all" "auto-selects your arch"
hasnt "all: no failed line"      "$all" "❌ Failed:"

part="$("$PC" "$CH" "amd64,arm64,armhf" "amd64,arm64")"
has   "partial: warn header"     "$part" "⚠️ Partial publish to \`$CH\` — 2 of 3"
has   "partial: available list"  "$part" "Available for: amd64, arm64"
has   "partial: works-on note"   "$part" "works on: amd64, arm64"
has   "partial: failed arch"     "$part" "❌ Failed: armhf"
hasnt "partial: armhf not avail" "$part" "Available for: amd64, arm64, armhf"

none="$("$PC" "$CH" "amd64,arm64,armhf" "")"
has   "none: nothing published"  "$none" "❌ No architectures were published"

[ "$fail" -eq 0 ] && echo "All pr-comment tests passed." || echo "Some pr-comment tests FAILED."
exit "$fail"
