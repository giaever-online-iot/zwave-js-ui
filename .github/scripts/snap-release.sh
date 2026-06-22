#!/usr/bin/env bash
#
# snap-release.sh — version/channel math + `snapcraft status` parsing for the snap
# release workflows. Pure functions: read args/stdin, write stdout, no network.
#
# Subcommands:
#   version-to-track <ver>             v11.19.1|11.19.1 -> v11.19    (""->"")
#   major <ver>                        v12.0.0 -> 12                 (""->"")
#   channel-version <channel>          (stdin: `snapcraft status`) -> version or "" (^/--/- -> "")
#   branch-has-revisions <track> <pr>  (stdin: `snapcraft status`) -> yes|no
#   needs-stable-bump <new> <cand>     yes iff cand set & major(new)>major(cand)
#   is-at-least <ver> <floor>          yes iff ver>=floor  (floor "" -> yes)
#   latest-targets <new> <cand> <edge> latest/* channels <new> may land on, each gated by
#                                      new >= that channel's own ver (no downgrade); space-sep
set -euo pipefail

# numeric major.minor.patch compare; echoes -1|0|1 (leading 'v' stripped)
_vercmp() {
  local a="${1#v}" b="${2#v}" i x y
  local -a A B
  IFS=. read -ra A <<<"$a"
  IFS=. read -ra B <<<"$b"
  for i in 0 1 2; do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    if (( 10#$x > 10#$y )); then echo 1; return; fi
    if (( 10#$x < 10#$y )); then echo -1; return; fi
  done
  echo 0
}

# true (exit 0) iff ver >= floor; empty floor => true. Leading 'v' optional.
_at_least() {
  [ -z "${2:-}" ] && return 0
  [ "$(_vercmp "${1:-}" "$2")" -ge 0 ]
}

cmd="${1:-}"; shift || true
case "$cmd" in
  version-to-track)
    in="${1:-}"
    if [ -z "$in" ]; then echo ""; exit 0; fi
    in="${in#v}"
    IFS=. read -ra parts <<<"$in"
    printf 'v%s.%s\n' "${parts[0]}" "${parts[1]:-0}"
    ;;
  major)
    in="${1:-}"
    if [ -z "$in" ]; then echo ""; exit 0; fi
    in="${in#v}"
    printf '%s\n' "${in%%.*}"
    ;;
  channel-version)
    # stdin = `snapcraft status`; arg = channel like latest/candidate or v11.20/edge/204.
    # Columns: Track Arch Channel Version Revision Progress Expires-at. Robust to BOTH
    # layouts snapcraft emits: captured non-interactively (CI: `$(...)` => no TTY) it
    # repeats Track+Arch on every row; in a terminal it blanks them on continuation rows.
    # So: carry the last Track token forward, find the Version field (`^v[0-9]`) on each
    # row, and read the Channel as the field immediately before it.
    ch="${1:-}"
    awk -v t="${ch%%/*}" -v c="${ch#*/}" '
      $1 ~ /^(latest|v[0-9][0-9.]*)$/ { tr = $1 }
      { for (i = 2; i <= NF; i++) if ($i ~ /^v[0-9]/) { if (tr == t && $(i-1) == c) { print $i; exit } break } }'
    ;;
  branch-has-revisions)
    # stdin = `snapcraft status`; args = track pr. Re-use channel-version via `bash "$0"`
    # so this works whether or not the script's exec bit is set.
    info="$(cat)"
    ver="$(bash "$0" channel-version "${1:-}/edge/${2:-}" <<<"$info")"
    if [ -n "$ver" ]; then echo yes; else echo no; fi
    ;;
  needs-stable-bump)
    new="${1:-}"; cand="${2:-}"
    if [ -z "$cand" ]; then echo no; exit 0; fi
    if [ -z "$new" ]; then echo no; exit 0; fi
    mn="${new#v}"; mn="${mn%%.*}"
    mc="${cand#v}"; mc="${mc%%.*}"
    if (( 10#$mn > 10#$mc )); then echo yes; else echo no; fi
    ;;
  is-at-least)
    if _at_least "${1:-}" "${2:-}"; then echo yes; else echo no; fi
    ;;
  latest-targets)
    # args: <new-ver> <latest/candidate ver> <latest/edge ver>.
    # Echo the latest/* channels <new-ver> may land on — each gated independently by
    # <new-ver> >= that channel's OWN current version, so a backport can never downgrade
    # a shared channel already ahead. Empty floor (channel currently empty) => qualifies.
    v="${1:-}"; out=""
    if _at_least "$v" "${2:-}"; then out="$out latest/candidate"; fi
    if _at_least "$v" "${3:-}"; then out="$out latest/edge"; fi
    echo "${out# }"
    ;;
  *)
    echo "snap-release.sh: unknown subcommand: ${cmd:-<none>}" >&2
    exit 2
    ;;
esac
