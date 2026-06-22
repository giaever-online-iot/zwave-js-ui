# CI build/release split — design

**Status:** approved (brainstorm) — 2026-06-22
**Scope:** `.github/workflows/pr-build-snap.yml` (restructure) and `.github/workflows/release-on-merge.yml` (retry-hardening). Helper scripts unchanged.

## Goal

Make a failed *release* (store upload / track creation) retryable **without** re-running the ~39-minute Launchpad build, and make each architecture independently buildable, publishable, and re-runnable.

## Motivation

`pr-build-snap.yml` is today a single `build-and-release` job: the expensive `remote-build` step and the `ensure-track` + `upload` steps share one job. GitHub's "Re-run failed jobs" works at job granularity, so any release-side failure forces a full rebuild.

This is not hypothetical. PR #210's run failed after a **successful 39-minute build** at `Ensure version track exists`:

```
create-track zwave-js-ui/v11.21: HTTP 401
create-track unauthorized — refresh SNAPCRAFT_SESSION_COOKIE
```

The build was fine; only the storefront session cookie had expired. Re-running re-does the whole build. The split below turns that into a ~10-second re-run of one tiny job.

## Architecture

Split `pr-build-snap.yml` into five jobs. `build` and `upload` are per-arch matrices; `ensure-track` runs in parallel with the builds (it needs only the track name).

```
        ┌─► ensure-track ─────────────────────────────┐
meta ───┤                                              ├─► report (always)
        └─► build(arch)[matrix] ──► upload(arch)[matrix] ┘
                                    (needs build + ensure-track)
```

| Job | `needs` | Matrix | Purpose |
|---|---|---|---|
| `meta` | — | — | Resolve `version`, `track`, `archs` (JSON array) from `snap/snapcraft.yaml`. |
| `ensure-track` | `meta` | — | Create the `v<MM>` track once if missing (session cookie). Idempotent. |
| `build` | `meta` | `arch` | `remote-build.sh <arch>`; on success upload artifact `snap-<arch>`. |
| `upload` | `build`, `ensure-track` | `arch` | Download `snap-<arch>`, `snapcraft upload --release=<chan>` via `retry.sh`; on success emit marker artifact `uploaded-<arch>`. |
| `report` | `build`, `ensure-track`, `upload` | — | Aggregate published archs from `uploaded-*`; post sticky PR comment; fail-gate. |

`meta` exposes `archs` as a JSON array so `build`/`upload` set `strategy.matrix.arch: ${{ fromJSON(needs.meta.outputs.archs) }}`.

### Why these boundaries

Each job is one **distinct failure cause / credential / per-arch unit**:

- `remote-build` (expensive, Launchpad) vs `upload` (store macaroon `SNAPCRAFT_STORE_CREDENTIALS`) vs `ensure-track` (storefront cookie `SNAPCRAFT_SESSION_COOKIE`) are independent failure domains with different credentials.
- Per-arch matrices let one arch fail and recover alone.
- Setup steps (`checkout`, `install snapcraft`, credentials, `meta`) are *not* isolated further: every job already repeats checkout + `snap install snapcraft` (~30–60 s), so more jobs means more repeated setup. Four functional jobs + `report` is the sweet spot.

## Gating (the load-bearing part)

A matrix counts as **one** job for `needs`: if any leg fails, the matrix job's result is `failure`, and a plain `needs:` dependent is **skipped**. Partial-arch tolerance therefore depends on explicit conditions.

| Job | `if:` | Rationale |
|---|---|---|
| `ensure-track` | `${{ github.event_name == 'pull_request' }}` | Independent of builds — runs regardless of any build outcome. |
| `build` | (default) + `strategy.fail-fast: false` | A dead arch must not cancel its siblings. |
| `upload` | `${{ !cancelled() && needs.ensure-track.result == 'success' }}` + `fail-fast: false` | Run even though the `build` matrix reports `failure` from a sibling, but **only if the track exists**. |
| `report` | `${{ always() }}` | Always post the comment + run the fail-gate, even on failure/cancellation. |

Two hard rules that make selective re-run correct:

1. **`upload (arch)` must FAIL when its own `snap-<arch>` artifact is absent** (not silently no-op). Otherwise "Re-run failed jobs" would rebuild the arch but skip its upload, leaving a silent gap.
2. **`upload` depends on `build`** (for ordering) so a re-run waits for the rebuilt arch's artifact before uploading.

### Re-run truth table

"Re-run failed jobs" reruns only still-failed legs + jobs skipped because of them + `report`; **successful legs are reused** (verified against GitHub matrix semantics).

| First-run failure | What reruns on "Re-run failed jobs" | Reused (not rerun) |
|---|---|---|
| `ensure-track` (expired cookie) | `ensure-track`, all `upload` legs (were skipped via the `result=='success'` gate), `report` | all `build` legs → **no rebuild** |
| one `build (armhf)` | `build-armhf`, `upload-armhf` (failed: artifact missing), `report` | `build-amd64/arm64`, `upload-amd64/arm64` → **no rebuild, no duplicate revisions** |
| one `upload (armhf)` (transient, survived `retry.sh`) | `upload-armhf`, `report` | all builds + other uploads |

`upload` re-uploading an already-published arch would mint a **new store revision** (`snapcraft upload` always creates one); reusing successful legs is what prevents that churn.

## Data flow

- **Snaps:** `build (arch)` → `actions/upload-artifact` `snap-<arch>` (retention 1 day — throwaway per-PR). `upload (arch)` → `actions/download-artifact` `snap-<arch>`.
- **Published set:** `upload (arch)` on success → marker artifact `uploaded-<arch>`. `report` globs `uploaded-*` to learn exactly which archs reached the channel. (Matrix job *outputs* are unreliable — last-writer-wins — so artifacts are the source of truth.)
- **Build-failure log:** the existing snapcraft-log capture moves into `build`; on failure it uploads the log as an artifact for `report` to fold into the comment.
- **Meta:** `meta` job outputs (`version`, `track`, `archs`) consumed via `needs.meta.outputs.*`.

## `report` comment

The channel is `v<MM>/edge/<PR>`; `snap install` is arch-agnostic (snapd resolves the running arch), so per-arch information is expressed as the **availability list** bound to the command. Three renderings:

**All archs published**
```
✅ Published to `v11.21/edge/210` — available to install & test:

  Architectures: amd64, arm64, armhf
  sudo snap install zwave-js-ui --channel=v11.21/edge/210      # auto-selects your arch
  # or: sudo snap refresh zwave-js-ui --channel=v11.21/edge/210
```

**Partial (≥1 arch failed)** — notify, and the command carries the arch list it works on
```
⚠️ Partial publish to `v11.21/edge/210` — 2 of 3 architectures.

  Available for: amd64, arm64
  sudo snap install zwave-js-ui --channel=v11.21/edge/210      # works on: amd64, arm64
  # or: sudo snap refresh zwave-js-ui --channel=v11.21/edge/210

  ❌ Failed: armhf — use "Re-run failed jobs" to retry just that arch (no rebuild of amd64/arm64).
```

**None published**
```
❌ No architectures were published for this PR. (snapcraft log folded below.)
```

`Available for` = the `uploaded-<arch>` set. `❌ Failed` = `wanted − published`. The sticky comment keeps the existing `<!-- pr-build-snap -->` marker so it updates in place. The fail-gate (`exit 1` when any wanted arch is unpublished) still reds the check on a partial — the red status is what drives "Re-run failed jobs".

**Event scope:** release (`ensure-track`, `upload`) and the fail-gate apply to `pull_request` events only, matching today's `github.event_name == 'pull_request'` guards. A `workflow_dispatch` run is **build-only** and passes when the builds succeed (nothing is published, so the fail-gate does not red it). `report` still posts a comment only on `pull_request`.

## `release-on-merge.yml` — retry-hardening only

No job split (no expensive build; promotions are idempotent). Wrap each store mutation in the existing helper:

```
.github/scripts/retry.sh 3 15 -- snapcraft promote  … --yes
.github/scripts/retry.sh 3 15 -- snapcraft close    …
.github/scripts/retry.sh 3 15 -- snapcraft set-default-track …
```

This gives the same transient-401/disconnect resilience the PR upload already has.

## Per-arch build matrix — notes & risk

Splitting `remote-build` per arch means `remote-build.sh <single-arch>` (it already accepts a comma-list; one element is valid) invoked in N parallel jobs instead of one `--build-for=a,b,c` call.

- **Benefit:** independent per-arch retry; wall-clock ≈ slowest single arch instead of the sum.
- **Risk:** N concurrent Launchpad remote-builds instead of one request. The account has previously hit a Launchpad-side scanner wedge; more concurrent requests could change queueing behavior. Acceptance criterion: the first real PR run must show all archs building in parallel and producing artifacts. If Launchpad concurrency proves problematic, the fallback is a single `build` job that builds all archs and emits per-arch artifacts (keeps the per-arch *upload* benefit, drops per-arch *build* parallelism).

## Testing

This is workflow-YAML restructuring; `remote-build.sh`, `snap-create-track.sh`, `retry.sh`, and `snap-release.sh` are unchanged, so their existing `*.test.sh` continue to apply. Any new bash extracted into a script (e.g. the `report` comment renderer, if pulled out for testability) gets unit tests following the repo pattern. The only true integration test is a real PR run; acceptance:

1. Clean PR: all archs build in parallel, track ensured, all archs upload, comment lists all archs, check green.
2. Forced release failure (e.g. stale cookie): build succeeds, `ensure-track` fails, uploads skip, comment shows none/partial, check red. Then "Re-run failed jobs" → only `ensure-track` + uploads + report rerun, **no rebuild**, check green.
3. Forced single-arch build failure: other archs publish; comment notifies + lists available archs; "Re-run failed jobs" rebuilds + uploads only the failed arch; successful archs not re-uploaded (no new revisions).

## Out of scope

- `remote-build.sh` / `snap-release.sh` / `snap-create-track.sh` / `retry.sh` logic changes (used as-is).
- Any change to which paths trigger the workflow, the per-PR channel scheme, or `release-on-merge`'s promotion logic.
- Refreshing the `SNAPCRAFT_SESSION_COOKIE` secret (operational; required to unblock #210, independent of this work).
