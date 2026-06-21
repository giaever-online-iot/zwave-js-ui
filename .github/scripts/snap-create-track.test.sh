#!/usr/bin/env bash
# Offline unit tests for snap-create-track.sh. Mocks curl; no network.
set -uo pipefail  # no -e: keep all tests running even if earlier ones fail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/snap-create-track.sh"
fail=0

# Put a fake `curl` first on PATH. It ignores its args and prints a canned
# response in the marker format the script parses, driven by MOCK_* env vars.
MOCKDIR="$(mktemp -d)"
trap 'rm -rf "$MOCKDIR"' EXIT
cat >"$MOCKDIR/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n@@CODE@@%s\n@@REDIRECT@@%s' "${MOCK_BODY:-}" "${MOCK_CODE:-000}" "${MOCK_REDIRECT:-}"
MOCK
chmod +x "$MOCKDIR/curl"
PATH="$MOCKDIR:$PATH"

# run <desc> <cookie> <body> <code> <redirect> <exp_rc> <exp_substr>
run() {
  local desc="$1" cookie="$2" body="$3" code="$4" redirect="$5" exp_rc="$6" exp_sub="$7"
  local out rc
  out="$(SNAPCRAFT_SESSION_COOKIE="$cookie" MOCK_BODY="$body" MOCK_CODE="$code" MOCK_REDIRECT="$redirect" \
        bash "$SCRIPT" zwave-js-ui v11.20 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$out" | grep -qF "$exp_sub"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       rc=%s (want %s)\n       out=[%s]\n' "$desc" "$rc" "$exp_rc" "$out"
    fail=1
  fi
}

run "empty cookie fails fast"    ""    ""                          ""    ""                                                          1 "SNAPCRAFT_SESSION_COOKIE is empty"
run "whitespace cookie fails"    $'\n' ""                          ""    ""                                                          1 "SNAPCRAFT_SESSION_COOKIE is empty"
run "201 creates track"          "c"   '{"num-tracks-created": 1}' "201" ""                                                          0 "num-tracks-created=1"
run "2xx but zero created"       "c"   '{"num-tracks-created": 0}' "200" ""                                                          1 "created no track"
run "302 -> login = expired"     "c"   ""                          "302" "https://snapcraft.io/login?next=/zwave-js-ui/create-track" 1 "invalid or expired"
run "403 unauthorized"           "c"   '{"error":"nope"}'          "403" ""                                                          1 "unauthorized"
run "500 generic failure"        "c"   "oops"                      "500" ""                                                          1 "create-track failed (HTTP 500)"

exit "$fail"
