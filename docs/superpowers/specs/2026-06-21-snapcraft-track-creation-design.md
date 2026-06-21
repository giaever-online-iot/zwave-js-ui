# Snapcraft Track-Creation Fix & Hardening Design

**Status:** Approved (design) — 2026-06-21
**Touches:** `.github/workflows/pr-build-snap.yml`, new `.github/scripts/snap-create-track.sh` + `.github/scripts/snap-create-track.test.sh`, `.github/workflows/helper-tests.yml`, and the repo secret `SNAPCRAFT_SESSION_COOKIE` (value refresh).

**Goal:** Restore automatic creation of the `v<major.minor>` version track during the PR
build (broken since Nov 2025, surfaced as a hard failure Jun 2026), and make the failure
mode **loud, specific, and unit-tested** so the same silent breakage cannot recur.

**Architecture:** Keep the existing, *correct* mechanism — a `POST` to the snapcraft.io
storefront `create-track` endpoint authenticated by the publisher **session cookie** — but
(1) fix the workflow so it references the secret that actually exists, (2) refresh that
cookie value, and (3) move the create-track logic out of inline YAML into a small,
unit-tested bash helper that fails fast and legibly. This mirrors the repo's existing
tested-helper pattern (`snap-release.sh` + `snap-release.test.sh`, run by `helper-tests.yml`).

**Tech stack:** bash, `curl`, GitHub Actions, `snapcraft` CLI (for the existing track
pre-check), and the repo's zero-dependency bash test convention.

---

## Background: the root cause (empirically verified)

The PR build's **"Ensure version track exists"** step fails with `create-track failed (HTTP 302)`.
A 302 from `snapcraft.io/<snap>/create-track` is a redirect to `/login?next=…` — i.e. the
request is **unauthenticated**. Investigation established *why* the request is unauthenticated:

1. **Secret-name mismatch → the cookie is empty.** The only relevant repo secret is
   **`SNAPCRAFT_SESSION_COOKIE`** (no org/environment secret exists — confirmed with the
   maintainer). The workflow references **`secrets.SNAPCRAFT_SESSION`**, which resolves to
   the empty string, so the step sends `Cookie: session=;` → 302 → `/login`.

2. **It is a latent regression, unmasked by a refactor:**
   - `656ca7a` (2025-10-26) *Add track creation* — referenced `secrets.SNAPCRAFT_SESSION_COOKIE`; the matching secret was created the same day. **Correct and matched.**
   - `7502220` (2025-11-07) *"Fix session cookie reference in workflow file" (#115)* — changed the reference to `secrets.SNAPCRAFT_SESSION`. Despite the title, this **broke** it (no secret by that bare name). Because the old `snap-create-track.yml` never checked the HTTP status, the resulting 302 was silently swallowed for ~7 months; new tracks were created manually instead.
   - `1a43c20` (2026-06-10) *(#191)* — folded create-track inline into `pr-build-snap.yml`, **carried the broken `secrets.SNAPCRAFT_SESSION` reference**, and added strict status checking (`exit 1` on non-2xx). This converted the dormant failure into a hard build failure, first hit on PR #204 (`v11.20`, the first PR since #191 that needed a brand-new track).

3. **The storefront session cookie is the only viable credential for this endpoint.**
   Verified by elimination:
   - A fresh session cookie creates a track: `POST snapcraft.io/<snap>/create-track` →
     **`201 {"num-tracks-created":1}`** (maintainer ran this manually).
   - `snapcraft` has **no** `create-track` command (only `tracks` / `set-default-track`).
   - Snap track creation lives on the unified API (`api.snapcraft.io/v1/snap/<snap>/tracks`,
     `POST`), which is a **different auth realm**: a valid `snapcraft export-login` macaroon
     authenticates against `dashboard.snapcraft.io/api/v2` (returns `200`) but is rejected
     by the unified tracks endpoint (`400 Invalid macaroon` / `401`). The documented
     macaroon track API is charm-only; `zwave-js-ui` is a snap, not a charm.

**Conclusion:** the mechanism in the workflow is right; the bug is a one-token secret name
and a stale cookie value. The remaining risk is that the cookie *expires* and fails the same
opaque way — which the hardening addresses.

---

## Credentials in play (reference)

Three distinct CI secrets, each with one purpose. Only track **creation** uses the cookie;
everything else (including track **listing**) uses the macaroon.

| Secret | Consumed by | Auth → endpoint |
|---|---|---|
| `LAUNCHPAD_CREDENTIALS` | `snapcraft remote-build` | Launchpad credentials → Launchpad |
| `SNAPCRAFT_STORE_CREDENTIALS` | `snapcraft tracks`, `snapcraft upload --release`, `snapcraft set-default-track` | macaroon → `dashboard.snapcraft.io` |
| `SNAPCRAFT_SESSION_COOKIE` | the `create-track` `curl` (only) | session cookie → `snapcraft.io` storefront |

Track creation has no `snapcraft` CLI command, which is why it is a raw `curl` with a
separate credential — and why this one path can break while build/upload/release keep working.

---

## Design

### Part 1 — Correct the secret reference (the bug fix)

In `pr-build-snap.yml`, standardize on the real secret name **`SNAPCRAFT_SESSION_COOKIE`**
everywhere, eliminating the two-name drift that caused this:

- `env:` (line ~101): `SNAPCRAFT_SESSION_COOKIE: ${{ secrets.SNAPCRAFT_SESSION_COOKIE }}`
- the cookie usage and any error text reference the same `SNAPCRAFT_SESSION_COOKIE` name.

### Part 2 — Refresh the cookie value (maintainer action, documented)

The stored cookie dates from 2025-10-26 and is presumed stale. After Part 1 merges (or
alongside it), set the fresh value:

```
gh secret set SNAPCRAFT_SESSION_COOKIE --repo giaever-online-iot/zwave-js-ui
```

(Paste only the `session=` value — no `session=` prefix.) Source: log in to snapcraft.io as
a publisher of the snap, copy the `session` cookie.

### Part 3 — Extract a hardened, tested helper

New **`.github/scripts/snap-create-track.sh <snap> <track>`**, reading the cookie from
`$SNAPCRAFT_SESSION_COOKIE`:

1. **Empty-cookie guard (the key safeguard).** If `$SNAPCRAFT_SESSION_COOKIE` is empty/unset:
   `::error::SNAPCRAFT_SESSION_COOKIE is empty or unset — cannot authenticate to create
   track <track>` and `exit 1`. *(This alone would have caught the regression immediately,
   instead of an opaque 302.)*
2. `POST https://snapcraft.io/<snap>/create-track` with the headers proven to work
   (`Cookie: session=…`, `Content-Type: application/x-www-form-urlencoded`,
   `Origin`, `Referer`) and `--data-urlencode "track-name=<track>"`. Capture body, status,
   and `redirect_url`; **do not** follow redirects.
3. Branch on status:

   | Status | Action |
   |---|---|
   | `2xx` | Parse `num-tracks-created`; require `≥ 1`, else `::error::` with the body + `exit 1`. On success print `Track <track> created (num-tracks-created=N)`. |
   | `30x` | `::error:: redirected to login (<redirect_url>) — SNAPCRAFT_SESSION_COOKIE is invalid or expired; refresh it.` + `exit 1`. |
   | `401`/`403` | `::error:: unauthorized (HTTP <code>) — refresh SNAPCRAFT_SESSION_COOKIE or check track guardrails for <snap>.` + body + `exit 1`. |
   | `*` | `::error:: create-track failed (HTTP <code>)` + body + `exit 1`. |

The **workflow step** keeps its existing pre-check (skip when the track already exists) and
then calls the helper:

```yaml
- name: Ensure version track exists
  if: ${{ steps.build.outputs.snaps != '0' && github.event_name == 'pull_request' }}
  env:
    SNAPCRAFT_STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
    SNAPCRAFT_SESSION_COOKIE: ${{ secrets.SNAPCRAFT_SESSION_COOKIE }}
  run: |
    set -euo pipefail
    TRACK="${{ steps.meta.outputs.track }}"
    if snapcraft tracks "$SNAP_NAME" | awk 'NR>1{print $1}' | grep -qx "$TRACK"; then
      echo "Track $TRACK already exists."; exit 0
    fi
    .github/scripts/snap-create-track.sh "$SNAP_NAME" "$TRACK"
```

### Part 4 — Tests

New **`.github/scripts/snap-create-track.test.sh`**, following `snap-release.test.sh`. It
puts a fake `curl` on `PATH` that emits a canned `body` + status + redirect, then asserts the
script's exit code and message for:

- empty `SNAPCRAFT_SESSION_COOKIE` → exit 1 (never calls curl)
- `201` + `{"num-tracks-created":1}` → exit 0, success message
- `200` + `{"num-tracks-created":0}` → exit 1
- `302` (+ login redirect URL) → exit 1, login/refresh message
- `403` → exit 1, unauthorized message
- `500` → exit 1, generic failure

Wire it into `helper-tests.yml` next to the existing `snap-release.test.sh` invocation.

---

## Error-handling & observability

Every failure path emits a GitHub `::error::` annotation that names **the exact secret to
fix** and the symptom (empty / expired-redirect / unauthorized / other). The previous design
funneled a 302 into a generic "failed (HTTP 302)" with no remedy; the new messages are
self-diagnosing.

## Out of scope (considered, rejected)

- **Macaroon-based auth** (`SNAPCRAFT_STORE_CREDENTIALS`): proven non-viable — the storefront
  create-track endpoint accepts only the session cookie, and the unified macaroon API rejects
  `snapcraft export-login` credentials (different realm).
- **Decoupling** (remove create-track from CI; create tracks manually): viable but explicitly
  declined; we keep automation.
- **Automatic cookie minting in CI:** the cookie comes from an interactive SSO login; scripting
  it headlessly is brittle and out of scope.

## Residual risk / follow-ups

- The session cookie still **expires** periodically. This design does not eliminate that, but
  the hardened `30x` message makes the next expiry a one-glance fix (refresh the secret).
- **Credential hygiene:** rotate credentials exposed during investigation (the session cookie,
  the `package_manage` macaroon, the un-scoped export-login token) at login.ubuntu.com →
  Applications.
- A throwaway test track may have been created on `home-assistant-snap` during investigation;
  tracks cannot be self-deleted (Store admin required) if cleanup is wanted.
