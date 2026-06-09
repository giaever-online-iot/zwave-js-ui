# Snap CI: build → track → release pipeline

- **Date:** 2026-06-09
- **Status:** Draft (awaiting user review)
- **Repo:** `giaever-online-iot/zwave-js-ui` (snap packaging wrapper)

## 1. Problem & context

This repo packages upstream Z-Wave JS UI as a snap. CI should take every PR,
build the snap on all architectures, publish it to a **per-PR channel** in the
Snap Store, and—when the PR merges—promote those exact bits forward to the
release channels.

### Current state (audited 2026-06-09)

| File | State |
|------|-------|
| `block-fork-prs.yml` | ✅ Mature. `pull_request_target` → auto-closes + labels fork / wrong-target PRs. |
| `pr-build-snap.yml` | ⚠️ Builds multi-arch via Launchpad `remote-build`, but **only uploads to GitHub artifacts — never the Snap Store.** 371 lines, 3 tangled jobs, `DEV`/`run_id` artifact-reuse mode, `workflow_run` chaining. |
| `snap-create-track.yml` | ❌ Attempts track creation via the dashboard API + buggy `yq` default-track math. Never releases a snap. Success guard is commented out. |

### Gaps vs. intent

1. PR push → build — *exists (overbuilt)*
2. On success → create `v<major.minor>` track if missing — *attempted, broken*
3. Release to per-PR channel `v<MM>/edge/<PR>` — **missing**
4. On merge → `v<MM>/stable` + `latest/candidate`|`latest/stable` — **missing**

## 2. Goals / non-goals

**Goals**
- PR push builds all archs and publishes to `v<MM>/edge/<PR>` in the store.
- The `v<MM>` track is auto-created when missing.
- PR merge promotes the PR's revisions to release channels (no rebuild).
- Default track follows the newest `v<MM>`.
- All fragile version/channel math lives in one tested helper.

**Non-goals**
- Changing the build mechanism (Launchpad `remote-build` stays).
- Re-architecting `block-fork-prs.yml`.
- Provisioning Track-Creation-Guardrails or the dashboard session cookie
  (assumed already set up; see §8).
- Backport/non-forward-moving version handling beyond a safe no-op.

## 3. Decisions (locked with maintainer)

| # | Decision | Choice |
|---|----------|--------|
| D1 | Build mechanism | **Launchpad `remote-build`** (keep). |
| D2 | Track creation | **Dashboard `create-track` API + `SNAPCRAFT_SESSION` cookie** (TCG assumed approved). |
| D3 | Merge release | **Promote the PR's revisions** (`snapcraft promote`), no rebuild. |
| D4 | Default track | **Newest `v<MM>` track** — set on merge. |
| D5 | Merge extras | **Also push to `latest/edge`** + **close `v<MM>/edge/<PR>`** after promoting. |
| D6 | Partial-arch build failure | **Upload the archs that built, report failures, mark PR check failed.** |

## 4. Architecture

Four workflow files + one helper script.

```
.github/
  workflows/
    block-fork-prs.yml      # unchanged — gatekeeper
    pr-build-snap.yml       # rewritten — build + ensure-track + release to v<MM>/edge/<PR>
    release-on-merge.yml    # new — promote PR revisions on merge
  scripts/
    snap-release.sh         # all version/track/channel math + table parsing (tested)
    snap-release.test.sh    # fixture-based assertions, runnable locally
```

`snap-create-track.yml` is **deleted**; its responsibilities move into
`pr-build-snap.yml` (track creation) and `release-on-merge.yml` (default track).

### Why the helper exists

`snapcraft status` and `snapcraft list-tracks` only emit human tables (no JSON).
Every prior branch broke on ad-hoc `awk`/`yq` against them. The helper is the
**single** place that parses those tables and does version math, so it can be
unit-tested with captured fixtures and the YAML stays declarative.

### Security model that makes this possible

GitHub withholds secrets from `pull_request` runs **only for fork PRs**.
`block-fork-prs.yml` auto-closes every fork PR, so every PR that reaches the
build is same-repo and **does** receive `SNAPCRAFT_STORE_CREDENTIALS`,
`LAUNCHPAD_CREDENTIALS`, and `SNAPCRAFT_SESSION`. This removes the need for the
old `workflow_run` indirection.

## 5. Helper contract — `.github/scripts/snap-release.sh`

Pure functions (no network). Subcommand dispatch; reads args/stdin, writes
stdout; non-zero exit on bad input.

| Subcommand | Input | Output | Notes |
|-----------|-------|--------|-------|
| `version-to-track <ver>` | `v11.19.1` or `11.19.1` | `v11.19` | strip leading `v`; first two dotted fields, re-prefixed `v`. |
| `major <ver>` | `v12.0.0` | `12` | numeric. |
| `channel-version <channel>` | `snap info` text on **stdin** | version string (incl. `v` prefix) or empty | `latest/candidate` → `v11.19.1`; empty if the channel is absent or shows `^` (inherits the channel above). |
| `branch-has-revisions <track> <branch>` | `snap info` text on **stdin** | `yes`/`no` | `yes` iff channel `<track>/edge/<branch>` has a concrete version (thin wrapper over `channel-version`). |
| `needs-stable-bump <new-ver> <cand-ver>` | two versions | `yes`/`no` | `yes` iff `cand-ver` non-empty and `major(new) > major(cand)`. |
| `is-at-least <ver> <floor>` | two versions | `yes`/`no` | numeric major.minor.patch compare; `yes` iff `ver >= floor`; `yes` if `floor` empty. Strips a leading `v` from either side. Guards `latest/*` + default track against regression on backports. |

**Data source = `snap info zwave-js-ui` (public, no auth, host-arch view).** Chosen
over `snapcraft status` because its channel block is one `track/risk[/branch]: version …`
per line — robustly parseable — whereas `snapcraft status` is column-aligned with
sparse carry-forward cells. Real format (captured 2026-06-09):

```
channels:
  latest/candidate: v11.19.1 2026-06-07 (850) 75.4MB -
  latest/beta:      ^
  v11.19/stable:    v11.19.1 2026-06-07 (850) 75.4MB -
  v11.19/edge/42:   v11.19.2 2026-06-09 (856) 75.4MB -
```

A captured fixture is committed under `.github/scripts/fixtures/` and drives
`snap-release.test.sh`.

> **No `newest-track` helper.** Real store data contains a stray `v20.0` track
> (created in error, 2024-10). A numeric-max "newest track" would pick it. Instead
> the default track is derived from the **release line actually being merged** vs.
> the current `latest/candidate` line (see §7 step 10) — stray future tracks are
> never considered.

> **Tracks command:** `snapcraft list-tracks` is deprecated → use `snapcraft tracks`.

## 6. Flow — `pr-build-snap.yml`

**Triggers:** `pull_request` `[opened, synchronize, reopened]` → `main`,
`paths-ignore: [.github/**, **/*.md, **/*.txt, renovate.json, .vscode/**]`;
plus `workflow_dispatch`.
**Concurrency:** `group: pr-build-${{ pr.number }}`, `cancel-in-progress: true`.
**Permissions:** `contents: read`, `pull-requests: write`.

Single job `build-and-release`:

1. Checkout; install `snapcraft --classic`; export `SNAPCRAFT_STORE_CREDENTIALS`;
   write `LAUNCHPAD_CREDENTIALS` to `~/.local/share/snapcraft/launchpad-credentials`.
2. `ARCHS=$(yq '.platforms | keys | join(",")' snap/snapcraft.yaml)`.
3. **Build (tolerant of partial failure, per D6):**
   ```bash
   set +e
   snapcraft remote-build -v --launchpad-accept-public-upload --build-for="$ARCHS"
   set -e
   ```
   Collect `*.snap` actually produced; compute the set of missing archs.
4. `V=$(yq '.version' snap/snapcraft.yaml)`; `TRACK=$(snap-release.sh version-to-track "$V")`;
   `PR=${{ github.event.pull_request.number }}`.
5. **Ensure track:** if `TRACK` ∉ `snapcraft tracks zwave-js-ui` (first column),
   POST `create-track` (see §8). On non-2xx, fail with a message naming the
   likely cause (TCG not approved / cookie expired).
6. **Release each built arch:** `snapcraft upload "<file>" --release="$TRACK/edge/$PR"`.
   (Branch `<PR>` is auto-created; PR number is a valid branch name.)
7. **Sticky PR comment** (one comment, updated each push) listing per-arch
   status and the install line:
   `sudo snap refresh zwave-js-ui --channel=$TRACK/edge/$PR` (or `install`).
8. If any arch failed in step 3, `exit 1` **after** uploading the good ones, so
   the PR check is red but partial bits are available.

## 7. Flow — `release-on-merge.yml`

**Trigger:** `pull_request` `[closed]` → `main`, guarded by
`if: github.event.pull_request.merged == true`.
**Permissions:** `contents: read`, `pull-requests: read`.

Single job `promote`:

1. Checkout; install snapcraft; export store creds.
2. `V`, `TRACK`, `PR` as in §6.
3. `INFO=$(snap info zwave-js-ui)`.
4. **Guard:** if `branch-has-revisions "$TRACK" "$PR" <<<"$INFO"` is `no`,
   log "nothing to promote (docs-only merge / build failed / branch expired)"
   and exit 0.
5. `CAND=$(snap-release.sh channel-version latest/candidate <<<"$INFO")` (e.g. `v11.19.1`).
6. **Stable bump (major rule):** if `needs-stable-bump "$V" "$CAND"` == `yes`:
   `snapcraft promote zwave-js-ui --from-channel latest/candidate --to-channel latest/stable --yes`
   *(moves the previous major's final to stable before candidate is overwritten).*
7. `snapcraft promote zwave-js-ui --from-channel "$TRACK/edge/$PR" --to-channel "$TRACK/stable" --yes`
   *(the track's own line — always runs, even for a backport).*
8. **Only if `is-at-least "$V" "$CAND"` == `yes`** (don't let a backport move
   the shared `latest/*` channels backwards):
   - `snapcraft promote zwave-js-ui --from-channel "$TRACK/edge/$PR" --to-channel latest/candidate --yes`
   - `snapcraft promote zwave-js-ui --from-channel "$TRACK/edge/$PR" --to-channel latest/edge --yes`
9. `snapcraft close zwave-js-ui "$TRACK/edge/$PR" --yes`
10. **Default track (D4), regression-safe & stray-track-proof:** the new default
    is the merged version's own track, set only when it advances past the current
    candidate's line:
    ```bash
    CAND_TRACK=$(snap-release.sh version-to-track "$CAND")   # "" if CAND empty
    if [ "$TRACK" != "$CAND_TRACK" ] && [ "$(snap-release.sh is-at-least "$TRACK" "$CAND_TRACK")" = yes ]; then
      snapcraft set-default-track zwave-js-ui "$TRACK"
    fi
    ```
    This sets default to `v<MM>` of the release (matching "newest `v<MM>`"), never
    regresses on a backport, and ignores the stray `v20.0` track because only
    `$TRACK` and the candidate line are ever compared.

### Channel semantics (derived from README §"Release Channels")

- `latest/edge` — every mainline build.
- `latest/candidate` — latest minor/patch of the **current** major (rolling).
- `latest/stable` — latest version of the **previous** major; only advances when
  a new major appears.
- `v<MM>` tracks — let users pin a major.minor and receive patches.

### Worked examples

| Scenario | `latest/candidate` before | Merge version | Actions |
|----------|---------------------------|---------------|---------|
| First ever | (empty) | v11.19.1 | create `v11.19`; promote branch → `v11.19/stable`, `latest/candidate`, `latest/edge`; close branch; default → `v11.19`. |
| Patch | 11.19.0 | v11.19.1 | promote branch → `v11.19/stable`, `latest/candidate`, `latest/edge`; default stays `v11.19`. |
| Minor | 11.19.1 | v11.20.0 | create `v11.20`; promote branch → `v11.20/stable`, `latest/candidate`, `latest/edge`; default → `v11.20`. |
| **Major** | 11.20.3 | v12.0.0 | promote `latest/candidate`(11.20.3) → `latest/stable`; create `v12.0`; promote branch → `v12.0/stable`, `latest/candidate`, `latest/edge`; default → `v12.0`. |

## 8. Store prerequisites & secrets

| Secret | Used by | Purpose |
|--------|---------|---------|
| `SNAPCRAFT_STORE_CREDENTIALS` | both | `snapcraft upload/release/promote/tracks/close/set-default-track`. |
| `LAUNCHPAD_CREDENTIALS` | build | `remote-build` on Launchpad. |
| `SNAPCRAFT_SESSION` | build (ensure-track) | dashboard `create-track` cookie. **Expires periodically — known fragility; refresh when create-track 401/403s.** |

**Track-Creation-Guardrails** must be approved for `zwave-js-ui` with a pattern
matching `v\d+\.\d+`, or `create-track` is rejected. `create-track` call:

```bash
curl -sS -w '\n%{http_code}' \
  -X POST "https://snapcraft.io/zwave-js-ui/create-track" \
  -H "Cookie: session=${SNAPCRAFT_SESSION};" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Origin: https://snapcraft.io" \
  -H "Referer: https://snapcraft.io/zwave-js-ui/releases" \
  --data-urlencode "track-name=${TRACK}"
```

## 9. Error handling & edge cases

- **Partial arch (D6):** build continues, good archs upload, missing archs
  reported, job exits non-zero. Merge promotes whatever archs are present.
- **Docs-only merge / failed build / expired branch:** §7 step-4 guard → no-op.
- **First release:** no `latest/candidate`; stable-bump skipped; default set to
  the only track.
- **Backport to an older `v<MM>`:** branch still promotes to its own
  `v<MM>/stable`, but the `is-at-least` guard skips `latest/candidate` and
  `latest/edge` so the shared channels don't regress, and the default-track step
  (§7.10) leaves the default unchanged. (Safe no-op for the global channels —
  full backport support is a non-goal.)
- **Stray `v20.0` track:** ignored — default-track logic only compares the merged
  version's track against the candidate line, never a numeric max over all tracks.
- **`promote --from-channel <branch>` validity:** channel grammar allows
  `[<track>/]<risk>[/<branch>]`; this is the one assumption to confirm in the
  first live run. Fallback: `snapcraft release <snap> <rev> <channel>` per arch
  using revisions from `snapcraft status`.

## 10. Testing & validation

- **Helper unit tests** (`snap-release.test.sh`): fixture-driven cases for
  `version-to-track`, `major`, `channel-version`, `branch-has-revisions`,
  `needs-stable-bump`, `is-at-least`, incl. empty-candidate, `^`-inheritance,
  and major-bump cases. Written **before** the helper (TDD). `shellcheck` is
  available and run on the helper + test.
- **Fixture** (`.github/scripts/fixtures/snap-info.txt`) is a real
  `snap info zwave-js-ui` capture (taken 2026-06-09), so the parser matches
  actual output incl. the `v` prefix and `^` rows.
- **Live validation:** open a throwaway PR → confirm `v<MM>/edge/<PR>` appears
  in `snap info`; merge → confirm promotion + branch closed + default track.
- Optional later: a tiny workflow that runs `snap-release.test.sh` on PRs
  touching `.github/scripts/**` (out of scope here).

## 11. Risks

- Dashboard session cookie expiry (mitigated by a clear failure message).
- `remote-build` queue latency / flaky armhf (mitigated by D6).
- `snap info` channel-block format drift (mitigated by isolating parsing + a real fixture).
- Promote-from-branch behavior (mitigated by documented fallback).
- `actionlint` is not installed here; workflow YAML is validated with `yq` syntax
  parse + manual review, and confirmed live on the first PR.
