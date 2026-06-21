# Snapcraft Track-Creation Fix & Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore automatic creation of the `v<major.minor>` track in the PR build by fixing the secret reference, and harden the path into a unit-tested helper that fails loudly.

**Architecture:** Keep the working mechanism (a `POST` to the snapcraft.io storefront `create-track`, authenticated by the publisher session cookie). Move it from inline YAML into a tested bash helper with an empty-cookie guard and explicit status handling; point the workflow at it using the secret name that actually exists.

**Tech Stack:** bash, `curl`, GitHub Actions, `shellcheck`, the repo's zero-dependency bash test convention (mirrors `snap-release.test.sh`).

**Design spec:** `docs/superpowers/specs/2026-06-21-snapcraft-track-creation-design.md`

## Global Constraints

- The CI secret is named **`SNAPCRAFT_SESSION_COOKIE`** — use this exact name everywhere (the bare `SNAPCRAFT_SESSION` does not exist and is the bug).
- Track creation authenticates with the **session cookie only** — never a macaroon (`SNAPCRAFT_STORE_CREDENTIALS`), which the storefront endpoint rejects.
- **No new dependencies.** The helper uses only `curl`, `sed`, `grep`, `printf`, `tail` (all present on `ubuntu-latest`). No `jq`/`python`.
- **Every script must pass `shellcheck`** — it is a CI gate in `helper-tests.yml`.
- Tests must be **offline** (mock `curl`); follow the `snap-release.test.sh` style (`ok   - ` / `FAIL - ` lines, `exit "$fail"`).
- TDD, frequent commits.

> **Tooling note:** `shellcheck` is required locally to mirror CI. If missing: `sudo snap install shellcheck` (or `sudo apt-get install -y shellcheck`).

---

## File Structure

- `.github/scripts/snap-create-track.sh` *(new)* — the hardened helper. One responsibility: create one track, exit non-zero with a precise `::error::` on any failure.
- `.github/scripts/snap-create-track.test.sh` *(new)* — offline unit tests; mocks `curl`.
- `.github/workflows/helper-tests.yml` *(modify)* — shellcheck + run the new test.
- `.github/workflows/pr-build-snap.yml` *(modify)* — fix the secret name; call the helper instead of inline `curl`.

---

### Task 1: Hardened, unit-tested `snap-create-track.sh` helper

**Files:**
- Create: `.github/scripts/snap-create-track.sh`
- Test: `.github/scripts/snap-create-track.test.sh`
- Modify: `.github/workflows/helper-tests.yml`

**Interfaces:**
- Consumes: nothing from earlier tasks. Reads env var `SNAPCRAFT_SESSION_COOKIE`.
- Produces: an executable-by-`bash` script `snap-create-track.sh <snap-name> <track>` that Task 2 calls as `bash .github/scripts/snap-create-track.sh "$SNAP_NAME" "$TRACK"`. Exit `0` = track created; exit `1` = failure (with `::error::`).

- [ ] **Step 1: Write the failing test**

Create `.github/scripts/snap-create-track.test.sh`:

```bash
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

run "empty cookie fails fast"   ""  ""                          ""    ""                                                          1 "SNAPCRAFT_SESSION_COOKIE is empty"
run "201 creates track"         "c" '{"num-tracks-created": 1}' "201" ""                                                          0 "num-tracks-created=1"
run "2xx but zero created"      "c" '{"num-tracks-created": 0}' "200" ""                                                          1 "created no track"
run "302 -> login = expired"    "c" ""                          "302" "https://snapcraft.io/login?next=/zwave-js-ui/create-track" 1 "invalid or expired"
run "403 unauthorized"          "c" '{"error":"nope"}'          "403" ""                                                          1 "unauthorized"
run "500 generic failure"       "c" "oops"                      "500" ""                                                          1 "create-track failed (HTTP 500)"

exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash .github/scripts/snap-create-track.test.sh`
Expected: every line is `FAIL - …` (the script doesn't exist yet, so `bash "$SCRIPT"` exits 127), and the command exits non-zero.

- [ ] **Step 3: Write the helper**

Create `.github/scripts/snap-create-track.sh`:

```bash
#!/usr/bin/env bash
# Create a Snap Store version track via the snapcraft.io storefront.
#
# Auth: the publisher web SESSION COOKIE in $SNAPCRAFT_SESSION_COOKIE. The storefront
# create-track endpoint accepts ONLY this cookie — NOT a snapcraft macaroon
# (SNAPCRAFT_STORE_CREDENTIALS), which lives in a different auth realm and is rejected
# here. `snapcraft` has no create-track command, hence this raw POST.
#
# Usage: snap-create-track.sh <snap-name> <track>
# Exit:  0 = track created; 1 = failure, with a ::error:: explaining the cause.
set -euo pipefail

snap="${1:?usage: snap-create-track.sh <snap-name> <track>}"
track="${2:?usage: snap-create-track.sh <snap-name> <track>}"
cookie="${SNAPCRAFT_SESSION_COOKIE:-}"

if [ -z "$cookie" ]; then
  echo "::error::SNAPCRAFT_SESSION_COOKIE is empty or unset — cannot authenticate to create track ${track}. Set the repo secret to a current snapcraft.io session cookie." >&2
  exit 1
fi

resp="$(curl -sS \
  -w $'\n@@CODE@@%{http_code}\n@@REDIRECT@@%{redirect_url}' \
  -X POST "https://snapcraft.io/${snap}/create-track" \
  -H "Cookie: session=${cookie};" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Origin: https://snapcraft.io" \
  -H "Referer: https://snapcraft.io/${snap}/releases" \
  --data-urlencode "track-name=${track}")" \
  || { echo "::error::create-track: curl could not reach snapcraft.io." >&2; exit 1; }

code="$(printf '%s\n' "$resp" | sed -n 's/^@@CODE@@//p' | tail -n1)"
redirect="$(printf '%s\n' "$resp" | sed -n 's/^@@REDIRECT@@//p' | tail -n1)"
body="$(printf '%s\n' "$resp" | sed '/^@@CODE@@/,$d')"

echo "create-track ${snap}/${track}: HTTP ${code:-none}"

case "$code" in
  2*)
    created="$(printf '%s' "$body" | grep -oE '"num-tracks-created": *[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
    if [ "${created:-0}" -ge 1 ]; then
      echo "Track ${track} created (num-tracks-created=${created})."
    else
      echo "::error::create-track returned HTTP ${code} but created no track (body: ${body})." >&2
      exit 1
    fi
    ;;
  3*)
    echo "::error::create-track redirected to login (${redirect:-?}) — SNAPCRAFT_SESSION_COOKIE is invalid or expired; refresh the repo secret." >&2
    exit 1
    ;;
  401|403)
    echo "::error::create-track unauthorized (HTTP ${code}) — refresh SNAPCRAFT_SESSION_COOKIE, or verify track-creation guardrails for ${snap} (body: ${body})." >&2
    exit 1
    ;;
  *)
    echo "::error::create-track failed (HTTP ${code:-none}) for ${track} (body: ${body})." >&2
    exit 1
    ;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash .github/scripts/snap-create-track.test.sh`
Expected output (exit 0):
```
ok   - empty cookie fails fast
ok   - 201 creates track
ok   - 2xx but zero created
ok   - 302 -> login = expired
ok   - 403 unauthorized
ok   - 500 generic failure
```

- [ ] **Step 5: Shellcheck both files**

Run: `shellcheck .github/scripts/snap-create-track.sh .github/scripts/snap-create-track.test.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Wire the test into `helper-tests.yml`**

Edit `.github/workflows/helper-tests.yml` — extend the shellcheck line (line 24). Replace:

```yaml
        run: shellcheck .github/scripts/snap-release.sh .github/scripts/snap-release.test.sh
```

with:

```yaml
        run: shellcheck .github/scripts/snap-release.sh .github/scripts/snap-release.test.sh .github/scripts/snap-create-track.sh .github/scripts/snap-create-track.test.sh
```

Then add a run step at the end of the file. Replace:

```yaml
      - name: Run helper unit tests
        run: bash .github/scripts/snap-release.test.sh
```

with:

```yaml
      - name: Run helper unit tests
        run: bash .github/scripts/snap-release.test.sh

      - name: Run create-track unit tests
        run: bash .github/scripts/snap-create-track.test.sh
```

- [ ] **Step 7: Commit**

```bash
git add .github/scripts/snap-create-track.sh .github/scripts/snap-create-track.test.sh .github/workflows/helper-tests.yml
git commit -m "ci(track): hardened, unit-tested snap-create-track helper"
```

---

### Task 2: Point the PR build at the helper with the correct secret

**Files:**
- Modify: `.github/workflows/pr-build-snap.yml` (the "Ensure version track exists" step, lines ~97-124)

**Interfaces:**
- Consumes: `bash .github/scripts/snap-create-track.sh "$SNAP_NAME" "$TRACK"` from Task 1.
- Produces: a workflow step that references `secrets.SNAPCRAFT_SESSION_COOKIE` and delegates to the helper.

- [ ] **Step 1: Replace the inline step with the corrected, delegating step**

Edit `.github/workflows/pr-build-snap.yml`. Replace this exact block:

```yaml
      - name: Ensure version track exists
        if: ${{ steps.build.outputs.snaps != '0' && github.event_name == 'pull_request' }}
        env:
          SNAPCRAFT_STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
          SNAPCRAFT_SESSION: ${{ secrets.SNAPCRAFT_SESSION }}
        run: |
          set -euo pipefail
          TRACK="${{ steps.meta.outputs.track }}"
          if snapcraft tracks "$SNAP_NAME" | awk 'NR>1{print $1}' | grep -qx "$TRACK"; then
            echo "Track $TRACK already exists."
            exit 0
          fi
          echo "Creating track $TRACK via dashboard API ..."
          resp="$(curl -sS -w $'\n%{http_code}' \
            -X POST "https://snapcraft.io/${SNAP_NAME}/create-track" \
            -H "Cookie: session=${SNAPCRAFT_SESSION};" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -H "Origin: https://snapcraft.io" \
            -H "Referer: https://snapcraft.io/${SNAP_NAME}/releases" \
            --data-urlencode "track-name=${TRACK}")"
          code="$(printf '%s' "$resp" | tail -n1)"
          body="$(printf '%s' "$resp" | sed '$d')"
          echo "HTTP $code"; echo "$body"
          case "$code" in
            2*) echo "Track $TRACK created." ;;
            401|403) echo "::error::create-track unauthorized — refresh the SNAPCRAFT_SESSION secret or verify Track-Creation-Guardrails for $SNAP_NAME."; exit 1 ;;
            *) echo "::error::create-track failed (HTTP $code)."; exit 1 ;;
          esac
```

with:

```yaml
      - name: Ensure version track exists
        if: ${{ steps.build.outputs.snaps != '0' && github.event_name == 'pull_request' }}
        env:
          SNAPCRAFT_STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
          SNAPCRAFT_SESSION_COOKIE: ${{ secrets.SNAPCRAFT_SESSION_COOKIE }}
        run: |
          set -euo pipefail
          TRACK="${{ steps.meta.outputs.track }}"
          # Listing tracks uses the macaroon (SNAPCRAFT_STORE_CREDENTIALS); skip if it exists.
          if snapcraft tracks "$SNAP_NAME" | awk 'NR>1{print $1}' | grep -qx "$TRACK"; then
            echo "Track $TRACK already exists."
            exit 0
          fi
          # Creating a track has no snapcraft command — it needs the storefront session cookie.
          bash .github/scripts/snap-create-track.sh "$SNAP_NAME" "$TRACK"
```

- [ ] **Step 2: Validate the workflow YAML and the secret name**

Run:
```bash
yq '.' .github/workflows/pr-build-snap.yml >/dev/null && echo "YAML OK"
grep -n 'SNAPCRAFT_SESSION' .github/workflows/pr-build-snap.yml
grep -n 'snap-create-track.sh' .github/workflows/pr-build-snap.yml
```
Expected: `YAML OK`; the only `SNAPCRAFT_SESSION` match is `SNAPCRAFT_SESSION_COOKIE: ${{ secrets.SNAPCRAFT_SESSION_COOKIE }}` (no bare `secrets.SNAPCRAFT_SESSION`); and the `snap-create-track.sh` call is present.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/pr-build-snap.yml
git commit -m "fix(ci): create-track uses SNAPCRAFT_SESSION_COOKIE via tested helper"
```

---

## Manual verification (post-merge — cannot be automated here)

These require Store credentials and a real PR run, so they are the maintainer's steps:

1. **Refresh the cookie secret** with a current value (the stored one is from Oct 2025):
   ```bash
   gh secret set SNAPCRAFT_SESSION_COOKIE --repo giaever-online-iot/zwave-js-ui
   ```
   (Paste only the `session=` cookie value; obtain it by logging in to snapcraft.io as a publisher.)
2. **Merge this fix** to `main`.
3. **Re-run PR #204** (or rebase it on `main`). The `Ensure version track exists` step should now print `Track v11.20 created (num-tracks-created=1)` and the upload step should proceed.
4. If it instead prints `…redirected to login… invalid or expired`, the cookie value is stale — repeat step 1 with a fresh cookie.

> **Note:** editing `.github/workflows/pr-build-snap.yml` does **not** trigger the PR-build workflow (it is path-filtered to `snap/**` and `src/**`), so this fix PR will not exercise create-track itself. The `helper-tests` workflow **does** run (it triggers on `.github/scripts/**`) and gates the helper + tests via shellcheck and the unit tests.

---

## Self-Review

- **Spec coverage:** Part 1 (correct secret reference) → Task 2. Part 2 (cookie refresh) → Manual verification step 1. Part 3 (extract hardened helper: empty-cookie guard, redirect detection, success assertion) → Task 1 (script) + Task 2 (call site). Part 4 (tests + helper-tests wiring) → Task 1 Steps 1-6. Rejected alternatives — n/a (no code). Residual risk (cookie expiry) → Manual verification step 4. ✓ all covered.
- **Placeholder scan:** none — all steps contain complete code/commands and expected output.
- **Type/name consistency:** helper path `.github/scripts/snap-create-track.sh`, invocation `bash .github/scripts/snap-create-track.sh "$SNAP_NAME" "$TRACK"`, secret `SNAPCRAFT_SESSION_COOKIE`, env var `SNAPCRAFT_SESSION_COOKIE`, and the `@@CODE@@`/`@@REDIRECT@@` markers are identical across the helper, the test mock, and the workflow. ✓
