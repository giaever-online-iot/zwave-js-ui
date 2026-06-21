#!/usr/bin/env bash
# Stub-driven unit tests for remote-build.sh. No network: fake `snapcraft` and
# `unsquashfs` on PATH simulate a truncated amd64 fetch that recovers on retry.
set -uo pipefail  # no -e: keep all tests running even if one fails

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RB="$HERE/remote-build.sh"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# Build a throwaway workspace with stub snapcraft + unsquashfs on PATH.
# mode=flaky:   amd64 download truncated on the first fetch, intact once recovered.
# mode=partial: amd64 never produces an artifact (a genuine build failure).
setup() { # $1 = mode -> echoes workdir
  local mode="$1" work bin
  work="$(mktemp -d)"; bin="$work/bin"; mkdir -p "$bin"
  cat > "$bin/unsquashfs" <<'EOF'
#!/usr/bin/env bash
# stub: `unsquashfs -l <file>` succeeds unless the file is marked CORRUPT
f=""; for f; do :; done
grep -q CORRUPT "$f" 2>/dev/null && exit 1
exit 0
EOF
  cat > "$bin/snapcraft" <<EOF
#!/usr/bin/env bash
state="$work/attempts"; n=0; [ -f "\$state" ] && n="\$(cat "\$state")"; n=\$((n+1)); echo "\$n" > "\$state"
recover=0; for a in "\$@"; do [ "\$a" = "--recover" ] && recover=1; done
printf 'OK' > zwave-js-ui_v1_arm64.snap
printf 'OK' > zwave-js-ui_v1_armhf.snap
case "$mode" in
  flaky)
    if [ "\$recover" -eq 1 ]; then printf 'OK' > zwave-js-ui_v1_amd64.snap
    else printf 'CORRUPT' > zwave-js-ui_v1_amd64.snap; exit 1; fi ;;
  partial)
    exit 1 ;;
esac
EOF
  chmod +x "$bin/unsquashfs" "$bin/snapcraft"
  echo "$work"
}

snaps_line() { printf '%s\n' "$1" | grep -oE 'snaps=[0-9]+' | tail -1; }

# --- flaky download: retries via --recover, ends with all 3 valid, none corrupt ---
work="$(setup flaky)"
out="$( cd "$work" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf )"
check "flaky: reports 3 valid snaps"   "snaps=3" "$(snaps_line "$out")"
check "flaky: 3 snap files on disk"    "3"       "$(find "$work" -maxdepth 1 -name '*.snap' | wc -l | tr -d ' ')"
check "flaky: no corrupt file remains" "0"       "$(grep -l CORRUPT "$work"/*.snap 2>/dev/null | wc -l | tr -d ' ')"
check "flaky: retried once (2 builds)" "2"       "$(cat "$work/attempts")"
rm -rf "$work"

# --- genuine partial failure: tolerated, returns the 2 that built, exit 0 ---
work="$(setup partial)"
out="$( cd "$work" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf )"
check "partial: reports 2 valid snaps" "snaps=2" "$(snaps_line "$out")"
check "partial: exhausts 3 attempts"   "3"       "$(cat "$work/attempts")"
( cd "$work" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf ) >/dev/null 2>&1
check "partial: exit 0 (tolerant)"     "0"       "$?"
rm -rf "$work"

# --- GITHUB_OUTPUT receives the count ---
work="$(setup flaky)"; gho="$work/gho"
( cd "$work" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 GITHUB_OUTPUT="$gho" bash "$RB" amd64,arm64,armhf ) >/dev/null 2>&1
check "writes snaps= to GITHUB_OUTPUT" "snaps=3" "$(grep -oE 'snaps=[0-9]+' "$gho" | tail -1)"
rm -rf "$work"

[ "$fail" -eq 0 ] && echo "All remote-build tests passed." || echo "Some remote-build tests FAILED."
exit "$fail"
