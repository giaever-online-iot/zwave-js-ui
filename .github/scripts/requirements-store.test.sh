#!/usr/bin/env bash
# Guard for requirements-store.txt's header. Renovate's pip-compile manager re-runs
# the command it reads from line 2 of the lock; when it cannot parse that command it
# stops updating the lock and only logs why. This test fails when the header is not
# in a form Renovate parses, or is not the recipe in requirements-store.in, or when an
# exact pin in requirements-store.in did not make it into the lock.
set -uo pipefail
shopt -s extglob

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# Options Renovate's pip-compile manager accepts for uv. Copied from Renovate
# 44.181.5, lib/modules/manager/pip-compile/common.ts (the uv lists).
WITH_ARG="--constraints --constraint --python-version --no-emit-package --prerelease --format --resolution --fork-strategy --exclude-newer --exclude-newer-package --group --override --overrides --output-file --extra --extra-index-url"
FLAGS="--no-strip-extras --universal --generate-hashes --emit-index-url --index-url --all-extras"

# norm_name NAME: NAME in PEP 503 form (lowercase; runs of - _ . become one -).
norm_name() { local n="${1,,}"; printf '%s' "${n//+([-_.])/-}"; }

# header_problem LOCK IN: print the first problem with LOCK's header as one line and
# return 1, or print nothing and return 0.
header_problem() {
  local lock="$1" recipe_file="$2" line1 line2 cmd tok name recipe entries l pin
  local pin_re='^[A-Za-z0-9][A-Za-z0-9._-]*==[^[:space:]]+$'
  local -a toks
  line1="$(sed -n 1p "$lock")"
  line2="$(sed -n 2p "$lock")"
  case "$line1" in '#'*) ;; *) echo "line 2 of the lock is not uv's '#    uv pip compile ...' header"; return 1 ;; esac
  case "$line2" in
    '#    uv pip compile '*) ;;
    *) echo "line 2 of the lock is not uv's '#    uv pip compile ...' header"; return 1 ;;
  esac

  cmd="${line2#'#    uv pip compile '}"
  read -ra toks <<<"$cmd"
  for tok in "${toks[@]}"; do
    case "$tok" in
      -[!-]*)
        echo "$tok is a short option; Renovate parses only long ones"; return 1 ;;
      --*)
        name="${tok%%=*}"
        if [[ "$tok" == *=* ]]; then
          case " $WITH_ARG $FLAGS " in
            *" $name "*) ;;
            *) echo "$name is not an option Renovate's pip-compile manager accepts for uv"; return 1 ;;
          esac
        else
          case " $WITH_ARG " in
            *" $name "*) echo "$name needs its value as $name=VALUE"; return 1 ;;
          esac
          case " $FLAGS " in
            *" $name "*) ;;
            *) echo "$name is not an option Renovate's pip-compile manager accepts for uv"; return 1 ;;
          esac
        fi ;;
    esac
  done

  case " ${toks[*]} " in
    *" --exclude-newer=P7D "*) ;;
    *) echo "missing --exclude-newer=P7D"; return 1 ;;
  esac

  # The recipe: the comment lines after the marker, continuing while a line ends in
  # a backslash. Backslashes and the leading '#' are stripped, whitespace squeezed.
  recipe="$(awk '
    found {
      if ($0 !~ /^#/) exit
      sub(/^#/, "")
      more = ($0 ~ /\\$/)
      sub(/\\$/, "")
      r = r " " $0
      if (!more) exit
      next
    }
    $0 == "# Lock into requirements-store.txt with:" { found = 1 }
    END { $0 = r; $1 = $1; print }
  ' "$recipe_file")"
  if [ -z "$recipe" ]; then
    echo "requirements-store.in has no recipe under '# Lock into requirements-store.txt with:'"
    return 1
  fi
  if [ "$recipe" != "uv pip compile ${toks[*]}" ]; then
    echo "lock header differs from the recipe in requirements-store.in"
    return 1
  fi

  # Every exact pin (name==version) in the .in must be an entry in the lock. Renovate
  # opens a craft-store PR and arms auto-merge even when its uv run fails, so without
  # this a failed run would merge a bumped .in beside an unchanged lock.
  entries=$'\n'
  while IFS= read -r l; do
    case "$l" in
      [A-Za-z0-9]*==*) l="${l%% *}"; entries+="$(norm_name "${l%%==*}")==${l#*==}"$'\n' ;;
    esac
  done <"$lock"
  while IFS= read -r pin; do
    [[ "$pin" =~ $pin_re ]] || continue
    case "$entries" in
      *$'\n'"$(norm_name "${pin%%==*}")==${pin#*==}"$'\n'*) ;;
      *) echo "$pin is pinned in requirements-store.in but not in the lock"; return 1 ;;
    esac
  done <"$recipe_file"
  return 0
}

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
D3='uv pip compile --universal --python-version=3.12 --exclude-newer=P7D --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in'
OLD='uv pip compile --universal --python-version 3.12 --generate-hashes .github/scripts/requirements-store.in -o .github/scripts/requirements-store.txt'
# pair NAME HEADER_COMMAND [RECIPE_LINE...]: $work/NAME.txt is a uv lock with that
# header and two entries; $work/NAME.in holds the recipe comment and one pin.
pair() {
  local name="$1" cmd="$2"; shift 2
  printf '# This file was autogenerated by uv via the following command:\n#    %s\ncraft-store==3.4.0 \\\n    --hash=sha256:%064d\nhttpx==0.28.1 \\\n    --hash=sha256:%064d\n' "$cmd" 0 0 >"$work/$name.txt"
  { echo '# Lock into requirements-store.txt with:'; [ $# -gt 0 ] && printf '%s\n' "$@"; echo 'craft-store==3.4.0'; } >"$work/$name.in"
}
run() { local out; out="$(header_problem "$work/$1.txt" "$work/$1.in")"; echo "$?:$out"; }

out="$(header_problem "$HERE/requirements-store.txt" "$HERE/requirements-store.in")"
check "repo lock: header in Renovate's form, same as the .in recipe" "0:" "$?:$out"

# shellcheck disable=SC1003  # the trailing backslashes are literal recipe text
pair ok "$D3" \
  '#   uv pip compile --universal --python-version=3.12 --exclude-newer=P7D \' \
  '#     --generate-hashes --output-file=.github/scripts/requirements-store.txt \' \
  '#     .github/scripts/requirements-store.in'
check "D3 command, recipe wrapped over three lines" "0:" "$(run ok)"

# shellcheck disable=SC1003  # the trailing backslashes are literal recipe text
pair rewrapped "$D3" \
  '#   uv pip compile  --universal \' \
  '#       --python-version=3.12 --exclude-newer=P7D --generate-hashes \' \
  '#  --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in'
check "same recipe wrapped elsewhere, extra spaces" "0:" "$(run rewrapped)"

pair old "$OLD" "#   $OLD"
check "main's header before this change: value split from option" \
  "1:--python-version needs its value as --python-version=VALUE" "$(run old)"

SHORT="${D3/--output-file=/-o }"; pair short "$SHORT" "#   $SHORT"
check "short option" "1:-o is a short option; Renovate parses only long ones" "$(run short)"

pair unknown "$D3 --no-annotate" "#   $D3 --no-annotate"
check "option Renovate does not accept" \
  "1:--no-annotate is not an option Renovate's pip-compile manager accepts for uv" "$(run unknown)"

pair unknown2 "$D3 --annotation-style=line" "#   $D3 --annotation-style=line"
check "option Renovate does not accept, given as --name=value" \
  "1:--annotation-style is not an option Renovate's pip-compile manager accepts for uv" "$(run unknown2)"

NOCUT="${D3/ --exclude-newer=P7D/}"; pair nocut "$NOCUT" "#   $NOCUT"
check "no --exclude-newer" "1:missing --exclude-newer=P7D" "$(run nocut)"

P1D="${D3/P7D/P1D}"; pair p1d "$P1D" "#   $P1D"
check "a different cutoff" "1:missing --exclude-newer=P7D" "$(run p1d)"

OVERRIDE="$D3 --exclude-newer-package=certifi=2026-10-26T00:00:00Z"; pair override "$OVERRIDE" "#   $OVERRIDE"
check "per-package --exclude-newer-package override" "0:" "$(run override)"

pair drift "$D3" "#   ${D3/3.12/3.13}"
check "header differs from the .in recipe" \
  "1:lock header differs from the recipe in requirements-store.in" "$(run drift)"

pair norecipe "$D3"
check "no recipe in the .in" \
  "1:requirements-store.in has no recipe under '# Lock into requirements-store.txt with:'" "$(run norecipe)"

pair stale "$D3" "#   $D3"; sed -i 's/^craft-store==3.4.0$/craft-store==3.5.0/' "$work/stale.in"
check "the .in pins a version the lock does not have" \
  "1:craft-store==3.5.0 is pinned in requirements-store.in but not in the lock" "$(run stale)"

pair spelling "$D3" "#   $D3"; sed -i 's/^craft-store==3.4.0$/Craft_Store==3.4.0/' "$work/spelling.in"
check "the .in spells the pinned name differently" "0:" "$(run spelling)"

printf 'httpx==0.28.1\n' >"$work/bare.txt"; cp "$work/ok.in" "$work/bare.in"
check "lock without uv's header" \
  "1:line 2 of the lock is not uv's '#    uv pip compile ...' header" "$(run bare)"

[ "$fail" -eq 0 ] && echo "All requirements-store tests passed." || echo "Some requirements-store tests FAILED."
exit "$fail"
