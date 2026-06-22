# Release-on-Merge Promotion: Branch-Revision Detection Fix

**Status:** Approved (design) — 2026-06-22
**Builds on:** the #191 build/release pipeline and `2026-06-21-snapcraft-track-creation-design.md`.

**Goal:** Make `release-on-merge` reliably detect the per-PR branch revisions it must promote, so a merged version bump actually reaches `v<MM>/stable` + `latest/*` — and make a *missed* promotion **loud and recoverable** instead of a silent green no-op.

**Architecture:** Replace the unauthenticated, branch-blind `snap info` channel source with the authenticated **`snapcraft status`**, which lists per-PR branch channels (`v<MM>/edge/<PR>`) and is not CDN-lagged. Re-base `snap-release.sh`'s `channel-version`/`branch-has-revisions` parsing — and the test fixture — on **real** `snapcraft status` output. When a buildable merge still finds nothing to promote, emit a `::warning::` with copy-paste recovery commands.

**Tech stack:** bash, `awk`, GitHub Actions, the `snapcraft` CLI (authenticated via the existing `SNAPCRAFT_STORE_CREDENTIALS`), the repo's zero-dependency bash test harness.

---

## Background: the confirmed bug

`release-on-merge` decides what to promote via `INFO="$(snap info "$SNAP")"` then `branch-has-revisions <track> <pr>` (which greps INFO's `channels:` block for `v<MM>/edge/<PR>`). Empirically verified:

1. **`snap info` never lists per-PR branch channels.** Its `channels:` block shows only `track/risk` rows (stable/candidate/beta/edge) — never `track/risk/<branch>`. So `branch-has-revisions` returns `no` for every branch → **every version-bump merge's promotion silently `exit 0`s** ("Nothing to promote"). Confirmed on PR #204: the build uploaded revs 921/922/923 to `v11.20/edge/204`, but `release-on-merge` printed "No revisions in v11.20/edge/204" and promoted nothing; `v11.20/stable` + `latest/*` stayed on v11.19.1 until a manual `snapcraft release`.
2. **The unit test gave false confidence.** `fixtures/snap-info.txt` *fabricates* a `v11.19/edge/42` branch row that real `snap info` never emits, so `branch-has-revisions … 42 → yes` passed in tests but never in reality.

`snapcraft status zwave-js-ui` (authenticated) lists branches directly and authoritatively (no CDN lag):
```
v11.20   amd64   edge/204   v11.20.0   921   -   2026-07-21T00:00:00Z
```

## Affected vs unaffected

- **Affected (fix here):** `release-on-merge.yml` (the `snap info` source), `.github/scripts/snap-release.sh` (`channel-version`, `branch-has-revisions`), `.github/scripts/snap-release.test.sh` + its fixture.
- **Unaffected (leave):** `pr-build-snap.yml`'s "Ensure version track exists" uses `snapcraft tracks` (authenticated track list), not `snap info`/branch detection.

## Design

### 1. Source: `snapcraft status` (authenticated)

In `release-on-merge.yml`, change `INFO="$(snap info "$SNAP")"` → `INFO="$(snapcraft status "$SNAP")"`. The job already exports `SNAPCRAFT_STORE_CREDENTIALS`, so `snapcraft status` authenticates.

*Chosen over `snapcraft revisions`:* both show branches, but `status` is the channel→state map both helpers query directly; `revisions` is the inverse (revision→channels) — fine for a branch substring-grep, awkward for `channel-version`.

### 2. `snap-release.sh`: parse `snapcraft status`

`snapcraft status` columns: `Track  Arch  Channel  Version  Revision  Progress  Expires-at`, with **Track+Arch on every row** and `↑` marking inheritance.

- **`channel-version <channel>`** — `<channel>` is `track/risk` (e.g. `latest/candidate`) or `track/risk/branch` (e.g. `v11.20/edge/204`). Split into `track=${ch%%/*}` and `chan=${ch#*/}`. From stdin, print the `Version` of the first row where `$1==track && $3==chan` **and** the Version looks like a version (`^v?[0-9]`); else print `""` (covers `↑`, `-`, the header row, and absent channels). Multi-arch rows carry the same version, so first-match is correct.
- **`branch-has-revisions <track> <pr>`** — contract unchanged: `channel-version "<track>/edge/<pr>"` non-empty → `yes`, else `no`.

Function signatures and the stdin contract are unchanged; only the parsing (and the doc comments that say `snap info`) change.

### 3. `release-on-merge.yml`: warn + recovery instead of silent skip

`release-on-merge` only runs on buildable merges (`paths: snap/**`, `src/**`, `requirements-duplicity.txt`), so finding no branch revisions is anomalous (build failed, or detection regressed). Replace the silent `echo …; exit 0` with a non-blocking `::warning::` that prints exact recovery commands, then `exit 0`:

```
::warning::release-on-merge: no revisions in <BRANCH> to promote. If the build uploaded (see the PR's "PR Build Snap" run), release manually:
  snapcraft promote <SNAP> --from-channel <BRANCH> --to-channel <TRACK>/stable --yes
  snapcraft promote <SNAP> --from-channel <BRANCH> --to-channel latest/candidate --yes   # if this is the newest release
  snapcraft promote <SNAP> --from-channel <BRANCH> --to-channel latest/edge --yes
  # or by revision:  snapcraft revisions <SNAP>  →  snapcraft release <SNAP> <rev> <TRACK>/stable,latest/candidate,latest/edge
  snapcraft set-default-track <SNAP> <TRACK>
```

*Warn, not fail* (per decision): the merge already happened, a red job wouldn't un-merge anything, and branch-expiry on a long-delayed merge is a legitimate empty case. The annotation is visible in the run and on the PR, and tells the maintainer exactly how to recover.

### 4. Tests + realistic fixture

- Replace `fixtures/snap-info.txt` with **`fixtures/snapcraft-status.txt`**, captured from **real** `snapcraft status zwave-js-ui` (read-only) and trimmed to a representative subset: `latest/{stable, candidate, beta (↑), edge}`, a `v<MM>/stable`, and a real `v<MM>/edge/<PR>` branch row, across ≥1 arch.
- Update `snap-release.test.sh` cases to the new fixture/format:
  - `channel-version latest/candidate` → fixture's candidate version
  - `channel-version latest/stable` → fixture's stable version
  - `channel-version <inherited ↑ channel>` → `""`
  - `channel-version <vMM/edge/PR present>` → branch version
  - `channel-version <absent channel>` → `""`
  - `branch-has-revisions <MM> <PR present>` → `yes`; `<PR absent>` → `no`
- The version-math tests (`version-to-track`, `major`, `is-at-least`, `needs-stable-bump`) are unchanged (no snap-info dependency).

`helper-tests.yml` already shellchecks + runs `snap-release.test.sh` via globs — no workflow change there.

## Error handling / edge cases

- **Auth:** `snapcraft status` requires creds (present in the job); slightly slower than `snap info`, acceptable.
- **`↑` / `-`:** non-version Version fields make `channel-version` return `""` (consistent with the old `^`/`--`/`-` handling).
- **Multi-arch:** same version across arches → first-match correct; any-arch presence ⇒ branch has revisions.

## Out of scope

- `pr-build-snap.yml` track pre-check (`snapcraft tracks`) — unaffected.
- `snapcraft revisions` as the source — considered; `status` chosen (§1).
- Auto-promoting from the warning path (self-healing) — deferred; warn-with-instructions is the agreed behavior.
