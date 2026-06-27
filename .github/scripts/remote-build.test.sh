#!/usr/bin/env bash
# Stub-driven unit tests for remote-build.sh. No network: fake `snapcraft` and
# `unsquashfs` on PATH simulate a truncated amd64 fetch.
#
# remote-build.sh recovers a truncated FETCH by re-running a FRESH `snapcraft
# remote-build` — NOT `--recover`, which is a proven no-op (snapcraft deletes the
# temporary Launchpad repo after each run, so --recover finds nothing to re-fetch).
# The truncation is intermittent ACROSS runs, so a fresh build clears it.
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
# mode=flaky:   amd64 truncated on attempt 1, intact from attempt 2 (a fresh build clears it)
# mode=always:  amd64 truncated on EVERY attempt (exercises the retry cap)
# mode=partial: amd64 never produces an artifact (a genuine build failure)
# Any `--recover` in the snapcraft args is recorded to $work/recover_used so a test
# can assert the script never uses it.
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
archs=""
for a in "\$@"; do
  [ "\$a" = "--recover" ] && touch "$work/recover_used"
  case "\$a" in --build-for=*) archs="\${a#--build-for=}" ;; esac
done
case ",\$archs," in *,arm64,*) printf 'OK' > zwave-js-ui_v1_arm64.snap ;; esac
case ",\$archs," in *,armhf,*) printf 'OK' > zwave-js-ui_v1_armhf.snap ;; esac
case ",\$archs," in *,amd64,*)
  case "$mode" in
    flaky)   if [ "\$n" -le 1 ]; then printf 'CORRUPT' > zwave-js-ui_v1_amd64.snap; exit 1; else printf 'OK' > zwave-js-ui_v1_amd64.snap; fi ;;
    always)  printf 'CORRUPT' > zwave-js-ui_v1_amd64.snap; exit 1 ;;
    partial) exit 1 ;;
  esac ;;
esac
EOF
  chmod +x "$bin/unsquashfs" "$bin/snapcraft"
  echo "$work"
}

snaps_line() { printf '%s\n' "$1" | grep -oE 'snaps=[0-9]+' | tail -1; }
recover_used() { [ -e "$1/recover_used" ] && echo yes || echo no; }

# --- flaky fetch: a fresh rebuild recovers it; 3 valid, retried ONCE, no --recover ---
work="$(setup flaky)"
out="$( cd "$work" && PATH="$work/bin:$PATH" RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf )"
check "flaky: reports 3 valid snaps"    "snaps=3" "$(snaps_line "$out")"
check "flaky: 3 snap files on disk"     "3"       "$(find "$work" -maxdepth 1 -name '*.snap' | wc -l | tr -d ' ')"
check "flaky: no corrupt file remains"  "0"       "$(grep -l CORRUPT "$work"/*.snap 2>/dev/null | wc -l | tr -d ' ')"
check "flaky: retried once (2 builds)"  "2"       "$(cat "$work/attempts")"
check "flaky: never used --recover"     "no"      "$(recover_used "$work")"
rm -rf "$work"

# --- single arch (the matrix's real call shape): same fresh-rebuild recovery ---
work="$(setup flaky)"
out="$( cd "$work" && PATH="$work/bin:$PATH" RETRY_DELAY=0 bash "$RB" amd64 )"
check "single: reports 1 valid snap"    "snaps=1" "$(snaps_line "$out")"
check "single: retried once (2 builds)" "2"       "$(cat "$work/attempts")"
rm -rf "$work"

# --- perpetual truncation: retry is CAPPED at the default (2 attempts), then yields ---
work="$(setup always)"
out="$( cd "$work" && PATH="$work/bin:$PATH" RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf )"
check "always: reports 2 valid snaps"   "snaps=2" "$(snaps_line "$out")"
check "always: capped at 2 attempts"    "2"       "$(cat "$work/attempts")"
rm -rf "$work"

# --- genuine partial failure: tolerated, returns the 2 that built, exit 0 ---
work="$(setup partial)"
out="$( cd "$work" && PATH="$work/bin:$PATH" RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf )"
check "partial: reports 2 valid snaps"  "snaps=2" "$(snaps_line "$out")"
( cd "$work" && PATH="$work/bin:$PATH" RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf ) >/dev/null 2>&1
check "partial: exit 0 (tolerant)"      "0"       "$?"
rm -rf "$work"

# --- GITHUB_OUTPUT receives the count ---
work="$(setup flaky)"; gho="$work/gho"
( cd "$work" && PATH="$work/bin:$PATH" RETRY_DELAY=0 GITHUB_OUTPUT="$gho" bash "$RB" amd64,arm64,armhf ) >/dev/null 2>&1
check "writes snaps= to GITHUB_OUTPUT"  "snaps=3" "$(grep -oE 'snaps=[0-9]+' "$gho" | tail -1)"
rm -rf "$work"

[ "$fail" -eq 0 ] && echo "All remote-build tests passed." || echo "Some remote-build tests FAILED."
exit "$fail"
