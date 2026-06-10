#!/usr/bin/env bash
#
# snap-release.sh — version/channel math + `snap info` parsing for the snap
# release workflows. Pure functions: read args/stdin, write stdout, no network.
#
# Subcommands:
#   version-to-track <ver>             v11.19.1|11.19.1 -> v11.19    (""->"")
#   major <ver>                        v12.0.0 -> 12                 (""->"")
#   channel-version <channel>          (stdin: `snap info`) -> version or "" (^/--/- -> "")
#   branch-has-revisions <track> <pr>  (stdin: `snap info`) -> yes|no
#   needs-stable-bump <new> <cand>     yes iff cand set & major(new)>major(cand)
#   is-at-least <ver> <floor>          yes iff ver>=floor  (floor "" -> yes)
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
    # stdin = `snap info`; arg = channel like latest/candidate or v11.19/edge/42
    awk -v ch="${1:-}" '
      /^channels:/ { inblk=1; next }
      inblk && NF==0 { inblk=0 }
      inblk {
        line=$0; sub(/^[ \t]+/, "", line)
        ci=index(line, ":"); if (ci==0) next
        name=substr(line, 1, ci-1)
        rest=substr(line, ci+1); sub(/^[ \t]+/, "", rest)
        split(rest, a, /[ \t]+/); ver=a[1]
        if (name==ch) {
          if (ver=="^" || ver=="--" || ver=="-") ver=""
          print ver; exit
        }
      }'
    ;;
  branch-has-revisions)
    # stdin = `snap info`; args = track pr. Re-use channel-version via `bash "$0"`
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
    ver="${1:-}"; floor="${2:-}"
    if [ -z "$floor" ]; then echo yes; exit 0; fi
    c="$(_vercmp "$ver" "$floor")"
    if [ "$c" -ge 0 ]; then echo yes; else echo no; fi
    ;;
  *)
    echo "snap-release.sh: unknown subcommand: ${cmd:-<none>}" >&2
    exit 2
    ;;
esac
