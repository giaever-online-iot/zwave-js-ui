# Release-on-Merge Branch-Revision Detection Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `release-on-merge` detect per-PR branch revisions via authenticated `snapcraft status` (which lists `v<MM>/edge/<PR>`), so merged version bumps actually promote — and warn (with recovery steps) instead of silently skipping.

**Architecture:** Swap the `snap info` channel source for `snapcraft status` in `release-on-merge.yml`; re-base `snap-release.sh`'s `channel-version` parser (and the test fixture) on the real `snapcraft status` table; turn the silent no-revisions `exit 0` into a `::warning::` with copy-paste recovery commands.

**Tech Stack:** bash, `awk`, GitHub Actions, `snapcraft` CLI, the repo's `snap-release.test.sh` harness.

**Spec:** `docs/superpowers/specs/2026-06-22-release-promote-detection-design.md`

## Global Constraints

- Branch/channel detection sources from **`snapcraft status`** (authenticated; the job already exports `SNAPCRAFT_STORE_CREDENTIALS`). Never `snap info` for this.
- `channel-version` / `branch-has-revisions` keep their **existing signatures + stdin contract** (stdin = the channel data; args unchanged). Only the parser + doc comments change.
- **No new dependencies** — bash + `awk` only.
- All scripts pass `shellcheck` (CI gate in `helper-tests.yml`).
- The test fixture must be **real `snapcraft status` output** (a representative subset), never fabricated.
- No-revisions on a buildable merge → non-blocking `::warning::` + recovery commands, then `exit 0`.
- TDD; frequent commits.

---

## File Structure

- `.github/scripts/snap-release.sh` *(modify)* — rewrite `channel-version` parser; fix doc comments.
- `.github/scripts/fixtures/snapcraft-status.txt` *(create)* — real `snapcraft status` subset.
- `.github/scripts/fixtures/snap-info.txt` *(delete)* — obsolete fabricated fixture.
- `.github/scripts/snap-release.test.sh` *(modify)* — point at new fixture; update channel/branch cases.
- `.github/workflows/release-on-merge.yml` *(modify)* — source `snapcraft status`; warn+recovery.

---

### Task 1: Re-base `channel-version` on `snapcraft status` (helper + fixture + tests)

**Files:**
- Create: `.github/scripts/fixtures/snapcraft-status.txt`
- Delete: `.github/scripts/fixtures/snap-info.txt`
- Modify: `.github/scripts/snap-release.sh`
- Modify: `.github/scripts/snap-release.test.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `snap-release.sh channel-version <channel>` (stdin = `snapcraft status` output) → version string or `""`; `branch-has-revisions <track> <pr>` → `yes`/`no`. Task 2 calls both with `INFO="$(snapcraft status …)"`.

- [ ] **Step 1: Create the realistic fixture (real `snapcraft status` rows)**

Create `.github/scripts/fixtures/snapcraft-status.txt` with exactly:

```
Track    Arch    Channel    Version    Revision    Progress    Expires at
latest   amd64   stable     v11.14.0   847         -           -
latest   amd64   candidate  v11.20.0   921         -           -
latest   amd64   beta       ↑          ↑           -           -
latest   amd64   edge       v11.20.0   927         -           -
latest   arm64   stable     v11.14.0   849         -           -
latest   arm64   candidate  v11.20.0   922         -           -
v11.20   amd64   stable     v11.20.0   921         -           -
v11.20   amd64   candidate  ↑          ↑           -           -
v11.20   amd64   beta       ↑          ↑           -           -
v11.20   amd64   edge       ↑          ↑           -           -
v11.20   amd64   edge/204   v11.20.0   921         -           2026-07-21T00:00:00Z
v11.19   amd64   stable     v11.19.1   850         -           -
v11.19   amd64   edge/209   v11.19.1   924         -           2026-07-21T00:00:00Z
```

(The `↑` is U+2191, exactly as `snapcraft status` prints inherited channels.)

- [ ] **Step 2: Update the tests to the new fixture + format (still failing)**

In `.github/scripts/snap-release.test.sh`, change the fixture path (line 7):

```bash
INFO="$HERE/fixtures/snapcraft-status.txt"
```

and replace the channel-version + branch-has-revisions block (the 5 `channel-version` checks and 2 `branch-has-revisions` checks) with:

```bash
check "channel-version candidate"  "v11.20.0" "$("$SR" channel-version latest/candidate <"$INFO")"
check "channel-version stable"     "v11.14.0" "$("$SR" channel-version latest/stable <"$INFO")"
check "channel-version inherited"  ""         "$("$SR" channel-version latest/beta <"$INFO")"
check "channel-version branch"     "v11.20.0" "$("$SR" channel-version v11.20/edge/204 <"$INFO")"
check "channel-version absent"     ""         "$("$SR" channel-version v99.9/stable <"$INFO")"

check "branch-has-revisions yes"   "yes" "$("$SR" branch-has-revisions v11.20 204 <"$INFO")"
check "branch-has-revisions no"    "no"  "$("$SR" branch-has-revisions v11.20 999 <"$INFO")"
```

Leave the `version-to-track`, `major`, `is-at-least`, `needs-stable-bump` checks unchanged.

- [ ] **Step 3: Run the tests — verify they FAIL (red)**

Run: `bash .github/scripts/snap-release.test.sh`
Expected: the `channel-version`/`branch-has-revisions` checks **FAIL** (the current parser scans a `snap info` `channels:` block, which the new fixture lacks, so it returns `""` for everything). Exit non-zero.

- [ ] **Step 4: Rewrite the `channel-version` parser for `snapcraft status`**

In `.github/scripts/snap-release.sh`, replace the `channel-version)` case body (the `awk` that parses the `channels:` block) with:

```bash
  channel-version)
    # stdin = `snapcraft status`; arg = channel like latest/candidate or v11.20/edge/204.
    # snapcraft status columns: Track Arch Channel Version Revision Progress Expires-at
    # (Track+Arch repeat on every row; `↑` marks an inherited channel.)
    ch="${1:-}"
    awk -v t="${ch%%/*}" -v c="${ch#*/}" '
      $1==t && $3==c && $4 ~ /^v?[0-9]/ { print $4; exit }'
    ;;
```

Then fix the now-stale doc comments (replace `snap info` with `snapcraft status`):
- the `branch-has-revisions)` comment `# stdin = \`snap info\`; args = track pr.` → `# stdin = \`snapcraft status\`; args = track pr.`
- the file-header lines that mention `\`snap info\` parsing` and the two usage lines `(stdin: \`snap info\`)` → `\`snapcraft status\``.

(`branch-has-revisions` logic is unchanged — it still delegates to `channel-version "<track>/edge/<pr>"`.)

- [ ] **Step 5: Delete the obsolete fixture, run tests — verify PASS (green)**

```bash
git rm .github/scripts/fixtures/snap-info.txt
bash .github/scripts/snap-release.test.sh
```
Expected: every line `ok   - …`, exit 0 (all version-math + the 7 updated channel/branch checks pass).

- [ ] **Step 6: Shellcheck**

Run: `shellcheck --severity=warning -x .github/scripts/snap-release.sh .github/scripts/snap-release.test.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add .github/scripts/snap-release.sh .github/scripts/snap-release.test.sh .github/scripts/fixtures/snapcraft-status.txt
git rm --cached .github/scripts/fixtures/snap-info.txt 2>/dev/null || true
git commit -m "fix(release): detect branch revisions from snapcraft status (not branch-blind snap info)"
```

---

### Task 2: Point `release-on-merge` at `snapcraft status` + warn-with-recovery

**Files:**
- Modify: `.github/workflows/release-on-merge.yml` (the "Promote PR revisions to release channels" step)

**Interfaces:**
- Consumes: `snap-release.sh branch-has-revisions` / `channel-version` from Task 1 (now parsing `snapcraft status`).
- Produces: a promote step that sources `snapcraft status` and warns (non-blocking) with recovery steps when nothing is found.

- [ ] **Step 1: Swap the channel source**

In `.github/workflows/release-on-merge.yml`, change:

```yaml
          INFO="$(snap info "$SNAP")"
```
to:
```yaml
          INFO="$(snapcraft status "$SNAP")"
```

- [ ] **Step 2: Replace the silent skip with a warning + recovery instructions**

Replace this block:

```yaml
          if [ "$("$SR" branch-has-revisions "$TRACK" "$PR" <<<"$INFO")" != "yes" ]; then
            echo "No revisions in $BRANCH (docs-only merge / build failed / branch expired). Nothing to promote."
            exit 0
          fi
```

with:

```yaml
          if [ "$("$SR" branch-has-revisions "$TRACK" "$PR" <<<"$INFO")" != "yes" ]; then
            echo "::warning::release-on-merge: no revisions in $BRANCH to promote. If the build uploaded (see this PR's 'PR Build Snap' run), release them manually:"
            echo "  snapcraft promote $SNAP --from-channel $BRANCH --to-channel $TRACK/stable --yes"
            echo "  snapcraft promote $SNAP --from-channel $BRANCH --to-channel latest/candidate --yes   # if this is the newest release"
            echo "  snapcraft promote $SNAP --from-channel $BRANCH --to-channel latest/edge --yes"
            echo "  # or by revision: snapcraft revisions $SNAP  ->  snapcraft release $SNAP <rev> $TRACK/stable,latest/candidate,latest/edge"
            echo "  snapcraft set-default-track $SNAP $TRACK"
            exit 0
          fi
```

- [ ] **Step 3: Validate YAML + the swap**

Run:
```bash
yq '.' .github/workflows/release-on-merge.yml >/dev/null && echo "YAML OK"
grep -n 'snapcraft status' .github/workflows/release-on-merge.yml
grep -n 'snap info' .github/workflows/release-on-merge.yml || echo "no 'snap info' left (good)"
grep -n '::warning::release-on-merge' .github/workflows/release-on-merge.yml
```
Expected: `YAML OK`; `snapcraft status` present; **no** `snap info` remaining; the warning line present.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release-on-merge.yml
git commit -m "fix(ci): release-on-merge sources snapcraft status; warns with recovery steps on no-promote"
```

---

## Manual verification (post-merge — not automatable here)

The parser is fully covered by `snap-release.test.sh` (runs in `helper-tests` CI). The end-to-end promotion can only be confirmed on a real version-bump merge:

1. Merge this PR.
2. On the next version-bump merge (e.g., a renovate `vX.Y.Z`), confirm the `release-on-merge` run prints `>> v<MM>/edge/<PR> -> v<MM>/stable` (not the warning) and that `snapcraft status zwave-js-ui` shows the new version in `v<MM>/stable` + `latest/candidate`.
3. If the warning fires on a real build, follow its printed `snapcraft promote …` commands.

---

## Self-Review

- **Spec coverage:** §1 source swap → Task 2 Step 1. §2 parser rewrite → Task 1 Step 4 (+ comments). §3 warn+recovery → Task 2 Step 2. §4 realistic fixture + tests → Task 1 Steps 1-2, 5. "Unaffected pr-build" → not touched. ✓ all covered.
- **Placeholder scan:** none — every step has exact content; the `<rev>`/`<MM>`/`<PR>` tokens are inside echoed recovery text / manual-verification prose, not code to fill in.
- **Type/name consistency:** `channel-version`/`branch-has-revisions` names + stdin contract unchanged; fixture path `fixtures/snapcraft-status.txt` consistent across the test edit and Task 1; `snapcraft status` consistent across helper, tests, and workflow. Test expectations match the fixture rows exactly (candidate=v11.20.0, stable=v11.14.0, beta=↑→"", v11.20/edge/204=v11.20.0, branch 204→yes / 999→no).
