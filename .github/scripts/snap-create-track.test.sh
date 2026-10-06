#!/usr/bin/env bash
# Offline unit tests for snap-create-track.sh. Mocks curl and the macaroon binder; no network.
set -uo pipefail  # no -e: keep all tests running even if earlier ones fail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/snap-create-track.sh"
fail=0

# A fake `curl` first on PATH. It answers the token exchange with MOCK_EX_* and the
# tracks POST with MOCK_*, in the marker format the script parses.
MOCKDIR="$(mktemp -d)"
trap 'rm -rf "$MOCKDIR"' EXIT
cat >"$MOCKDIR/curl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  */tokens/dashboard/exchange*) printf '%s\n@@CODE@@%s' "${MOCK_EX_BODY:-}" "${MOCK_EX_CODE:-000}" ;;
  *)                            printf '%s\n@@CODE@@%s' "${MOCK_BODY:-}" "${MOCK_CODE:-000}" ;;
esac
MOCK
# A fake $PYTHON: binding succeeds unless MOCK_BIND_FAIL is set.
cat >"$MOCKDIR/python" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
[ -n "${MOCK_BIND_FAIL:-}" ] && exit 1
echo "macaroon root=r, discharge=d"
MOCK
chmod +x "$MOCKDIR/curl" "$MOCKDIR/python"
PATH="$MOCKDIR:$PATH"
export PYTHON="$MOCKDIR/python"

EX_OK='{"macaroon": "tok"}'

# run <desc> <creds> <bind_fail> <ex_code> <ex_body> <code> <body> <exp_rc> <exp_substr> [track]
run() {
  local desc="$1" creds="$2" bind_fail="$3" ex_code="$4" ex_body="$5" code="$6" body="$7" exp_rc="$8" exp_sub="$9"
  local track="${10:-v11.20}" out rc
  out="$(SNAPCRAFT_STORE_CREDENTIALS="$creds" MOCK_BIND_FAIL="$bind_fail" \
        MOCK_EX_CODE="$ex_code" MOCK_EX_BODY="$ex_body" MOCK_CODE="$code" MOCK_BODY="$body" \
        bash "$SCRIPT" zwave-js-ui "$track" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$out" | grep -qF "$exp_sub"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       rc=%s (want %s)\n       out=[%s]\n' "$desc" "$rc" "$exp_rc" "$out"
    fail=1
  fi
}

run "empty creds fail fast"       ""  "" ""    ""                   ""    ""                          1 "SNAPCRAFT_STORE_CREDENTIALS is empty"
run "invalid track name"          "c" "" ""    ""                   ""    ""                          1 "invalid track name" 'v1"]'
run "unreadable creds"            "c" 1  ""    ""                   ""    ""                          1 "could not read SNAPCRAFT_STORE_CREDENTIALS"
run "exchange 401 = expired"      "c" "" "401" '{"error-list":[]}'  ""    ""                          1 "token exchange failed (HTTP 401)"
run "exchange 200 without token"  "c" "" "200" '{}'                 ""    ""                          1 "token exchange failed (HTTP 200)"
run "201 creates track"           "c" "" "200" "$EX_OK"             "201" '{"num-tracks-created": 1}' 0 "num-tracks-created=1"
run "2xx but zero created"        "c" "" "200" "$EX_OK"             "200" '{"num-tracks-created": 0}' 1 "created no track"
run "409 already exists"          "c" "" "200" "$EX_OK"             "409" '{"error-list":[]}'         0 "already exists"
run "403 unauthorized"            "c" "" "200" "$EX_OK"             "403" '{"error":"nope"}'          1 "unauthorized"
run "500 generic failure"         "c" "" "200" "$EX_OK"             "500" "oops"                      1 "create-track failed (HTTP 500)"

exit "$fail"
