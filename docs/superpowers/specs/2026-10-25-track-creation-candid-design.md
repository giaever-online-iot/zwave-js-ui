# Snap Store track creation from CI via a Candid gateway credential — design

Date: 2026-10-25. Status: draft for review. Supersedes the auth part of
`2026-06-21-snapcraft-track-creation-design.md` and reworks PR #244 (robertsLando).
Fixes #243 (automated PRs stuck since July 2026).

## Intent

Every upstream **minor** bump needs a new `v<major.minor>` track in the Snap Store before
`pr-build-snap.yml` can publish to `v<MM>/edge/pr-<PR#>`. Since July 2026 the `ensure-track`
job failed on every minor bump, so tracks v11.22–v11.25 were never created and users on
`latest/candidate` stayed on 11.21.x while upstream reached 11.25.1. The job must create
tracks unattended for at least a year per credential, fail loudly (not silently) when the
credential is about to expire, and be renewable without a terminal password prompt.

## What was verified (2026-10-24/25, from the maintainer's laptop)

| Approach | Result |
|---|---|
| Storefront session cookie (`SNAPCRAFT_SESSION_COOKIE`, current `main`) | Expires/invalidated within weeks; root cause of #243. |
| `snapcraft export-login` macaroons exchanged at `api.charmhub.io/v1/tokens/dashboard/exchange` (PR #244 as written) | `401 Exchange window expired` for every stored login tried: an 11‑month-old export and a 4‑month-old keyring login whose discharge had just been refreshed. The exchange only works right after a real authentication; snapcraft.io and Launchpad exchange once at login and keep the token. A stored export-login can never pass it. |
| `/v1/tokens/usso/exchange`, `/v1/tokens/exchange` with the U1 pair | 401 "Unrecognized macaroon location" / HTTP 500. |
| `SNAPCRAFT_STORE_AUTH=candid snapcraft export-login` | Removed in snapcraft 9.x ("no longer supported"). |
| **Charmhub Candid login driven by craft-store** (`StoreClient` with `endpoints.CHARMHUB`, `ephemeral=True`, `login(permissions=[package-manage, package-view], ttl=1y)`): user taps the Candid URL (works from a phone), craft-store exchanges immediately | **Works.** `GET api.charmhub.io/v1/tokens/whoami` → 200 as `giaever-online`; `POST /v1/snap/zwave-js-ui/tracks [{"name":"v11.25"}]` → **201**. Credential: base64 `{"t":"macaroon","v":"<serialized>"}`, caveats `time-before <now+1y>`, `declared userid usso:…`, `extra {"permissions":[…]}`. Rejected by `dashboard.snapcraft.io` (401), so it cannot replace the snapcraft CLI's credential. |

v11.25 was created this way on 2026-10-25 and PR #238 was re-run against it.

## Goals

- `ensure-track` creates a missing `v<MM>` track with no human in the loop, using a
  credential that lives ≥ 1 year.
- The pipeline warns on **every** build PR when the credential has < 30 days left, and
  errors with renewal instructions when it has expired — never "green on patch bumps, red
  on the next minor bump" again.
- Renewal takes one command on any machine plus one tap on a phone; no terminal password.
- Keep PR #244's structure and tests (Python script, hash-locked `requirements-store.txt`,
  offline unit tests run by `helper-tests.yml`), credited to its author.

## Non-goals / anti-goals

- No change to how snaps are uploaded, released, promoted or how the default track is set:
  `snapcraft` keeps using `SNAPCRAFT_STORE_CREDENTIALS` (Ubuntu One export-login).
- No attempt to collapse to a single secret (see D2).
- No back-filling of tracks v11.22/v11.23 (nothing will ever be published there). v11.24
  appeared in the store tonight (empty); leave it.
- No change to Renovate automerge, `auto-merge.yml` or `release-on-merge.yml`.
- Do not rewrite the dated June design/plan docs; they are history (link from here).

## Decisions

- **D1 — Credential type: Charmhub Candid token obtained through craft-store.**
  Reason: it is the only credential type verified to be accepted by the publisher gateway
  (`api.charmhub.io`) for `POST /v1/snap/<snap>/tracks` beyond the exchange window. The
  cookie expires in weeks; export-login macaroons cannot be exchanged from CI.
- **D2 — A second secret, `SNAPCRAFT_GATEWAY_CREDENTIALS`, used only by `ensure-track`.**
  Reason: the snapcraft CLI (upload/release/promote/tracks/set-default-track) accepts only
  Ubuntu One macaroons and snapcraft 9 removed Candid; the Candid token is rejected by
  `dashboard.snapcraft.io`. Replacing snapcraft's upload/release path with raw gateway calls
  to get down to one secret would be a large, risky rewrite with no user-visible gain.
  The secret was set on the repo on 2026-10-25 (expires 2027-10-24).
- **D3 — No exchange in CI. The script sends `Authorization: Macaroon <v>` straight to the
  gateway through craft-store's `PublisherGateway("https://api.charmhub.io", "snap", auth)`
  `.create_tracks()`; HTTP 409 (track exists) is success.**
  Reason: the token is already exchanged; craft-store owns name validation, error parsing
  and the `num-tracks-created` check (PR #244's rationale, kept). 409 = success keeps the
  `retry.sh` wrapper safe.
- **D4 — Expiry pre-check on every PR build, before the "track already exists" early exit.**
  The script (or a `--check` mode of it) decodes the credential, reads the `time-before`
  caveat, and: < 30 days → `::warning::` naming the expiry date and the renewal steps;
  expired/unparseable → `::error::` and exit 1 only when a track actually has to be created
  (a missing credential must not block patch bumps that need no new track). Reason: the
  old failure was invisible until the next minor bump; a warning on every build PR gives
  weeks of notice on the PRs the maintainer already looks at. The build jobs and the
  sticky PR comment are unchanged.
- **D5 — Renewal helper `.github/scripts/store-gateway-login.py`.** Runs locally with the
  same hash-locked venv (`requirements-store.txt`), performs the craft-store Candid login
  (`ephemeral=True`, no keyring writes), prints the Candid URL (and honours `$BROWSER`; a
  stand-in script can capture the URL instead of opening a tab), writes the blob to a
  0600 file and prints the exact `gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS` command.
  Reason: renewal must not depend on remembering tonight's probe; one command + one tap.
- **D6 — Keep PR #244's layout: `snap-create-track.py`, `requirements-store.in/.txt`
  (`craft-store==3.4.0`, `httpx`, `pymacaroons` — pymacaroons now only for caveat
  parsing in D4), `snap-create-track.test.py` rewritten for the new flow (offline, httpx
  mocked), `helper-tests.yml` as in #244.** Reason: the structure is sound and reviewed;
  only the auth model was wrong.
- **D7 — Decommission `SNAPCRAFT_SESSION_COOKIE`.** Remove from the workflow and docs;
  the maintainer deletes the repo secret after merge. Reason: dead credential, confusing
  error paths.
- **D8 — Docs:** update the create-track sentence in `CLAUDE.md`, add a short "Renewing
  the gateway credential" paragraph there (command, phone tap, expiry warning), and keep
  this spec as the record. Reason: the renewal runbook must survive without this chat.
- **D9 — Land on PR #244's branch** (`ci/create-track-store-credentials`) as follow-up
  commits, with the findings posted as a PR comment and #243 updated. Reason: credit the
  author's investigation and keep one PR; the maintainer merges.
- **D10 — Verification before merge:** unit tests + shellcheck/py_compile in
  `helper-tests`; a local live run of the final script against the live gateway with the
  real credential for an *existing* track (`v11.25` → 409 → exit 0) proves auth + endpoint
  without creating anything; the 201 path is proven by tonight's v11.25 creation and will
  be exercised by the next minor bump. The 0600 local copy of the credential is shredded
  after that local run.

## Constraints

- CI runner `ubuntu-latest` (Python ≥ 3.12); `pip --require-hashes`.
- No secret may be printed: `::add-mask::` is unnecessary once there is no exchange;
  error messages must never include the blob or the macaroon.
- `ensure-track` keeps `snapcraft tracks` (Ubuntu One credential) for the existence check.

## Left to the builder

- Exact split between `--check` mode and the create path (one script, two entry points is
  fine). Warning threshold is 30 days.
- Test fixtures: a synthetic Candid-style macaroon with a `time-before` caveat.
- Whether `retry.sh` wraps the pip install (keep as in #244).

## Related

- `docs/superpowers/specs/2026-06-21-snapcraft-track-creation-design.md` (cookie era; why
  macaroons were ruled out then — the exchange step was unknown).
- PR #244, issue #243, PR #238 (first minor bump through the new track).
