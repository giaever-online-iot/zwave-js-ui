# CI build/release split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `pr-build-snap.yml` so a failed release retries without rebuilding, with per-arch build/upload, and retry-harden `release-on-merge.yml`.

**Architecture:** Five jobs — `meta` → (`ensure-track` ∥ `build[arch]`) → `upload[arch]` → `report`. Snaps move between `build` and `upload` as per-arch artifacts; `report` derives the published set from `uploaded-<arch>` marker artifacts. The only new, unit-testable code is a pure comment renderer (`pr-comment.sh`); the workflows are verified with `actionlint` + a real PR run.

**Tech Stack:** GitHub Actions, bash, `yq`, `snapcraft`, existing helpers (`remote-build.sh`, `snap-create-track.sh`, `retry.sh`, `snap-release.sh`).

Spec: `docs/superpowers/specs/2026-06-22-ci-build-release-split-design.md`.

---

## File structure

- **Create** `.github/scripts/pr-comment.sh` — pure renderer: `(channel, wanted-csv, published-csv) → markdown`. One responsibility: the install/availability comment body.
- **Create** `.github/scripts/pr-comment.test.sh` — unit tests (auto-run by `helper-tests.yml`).
- **Rewrite** `.github/workflows/pr-build-snap.yml` — single job → five jobs.
- **Modify** `.github/workflows/release-on-merge.yml` — wrap the three store mutations in `retry.sh`.

---

## Task 1: Pure PR-comment renderer (`pr-comment.sh`)

**Files:**
- Create: `.github/scripts/pr-comment.sh`
- Test: `.github/scripts/pr-comment.test.sh`

- [ ] **Step 1: Write the failing test**

Create `.github/scripts/pr-comment.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for pr-comment.sh. Pure: no network. Asserts the three renderings.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC="$HERE/pr-comment.sh"
export SNAP_NAME=zwave-js-ui
fail=0
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then printf 'ok   - %s\n' "$1"; else printf 'FAIL - %s\n       missing: [%s]\n       in:      [%s]\n' "$1" "$3" "$2"; fail=1; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then printf 'FAIL - %s\n       unexpected: [%s]\n' "$1" "$3"; fail=1; else printf 'ok   - %s\n' "$1"; fi; }

CH="v11.21/edge/210"

all="$("$PC" "$CH" "amd64,arm64,armhf" "amd64,arm64,armhf")"
has   "all: success header"      "$all" "✅ Published to \`$CH\`"
has   "all: lists every arch"    "$all" "Architectures: amd64, arm64, armhf"
has   "all: install command"     "$all" "sudo snap install zwave-js-ui --channel=$CH"
has   "all: auto-selects note"   "$all" "auto-selects your arch"
hasnt "all: no failed line"      "$all" "❌ Failed:"

part="$("$PC" "$CH" "amd64,arm64,armhf" "amd64,arm64")"
has   "partial: warn header"     "$part" "⚠️ Partial publish to \`$CH\` — 2 of 3"
has   "partial: available list"  "$part" "Available for: amd64, arm64"
has   "partial: works-on note"   "$part" "works on: amd64, arm64"
has   "partial: failed arch"     "$part" "❌ Failed: armhf"
hasnt "partial: armhf not avail" "$part" "Available for: amd64, arm64, armhf"

none="$("$PC" "$CH" "amd64,arm64,armhf" "")"
has   "none: nothing published"  "$none" "❌ No architectures were published"

[ "$fail" -eq 0 ] && echo "All pr-comment tests passed." || echo "Some pr-comment tests FAILED."
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash .github/scripts/pr-comment.test.sh`
Expected: FAIL — `pr-comment.sh` does not exist yet (`bash: .../pr-comment.sh: No such file or directory`).

- [ ] **Step 3: Write the renderer**

Create `.github/scripts/pr-comment.sh`:

```bash
#!/usr/bin/env bash
# pr-comment.sh — render the sticky PR-build comment body for pr-build-snap.yml.
# Pure: args in, markdown on stdout, no network. Unit-tested by pr-comment.test.sh.
#
# Usage:  pr-comment.sh <channel> <wanted-csv> <published-csv>
#   <wanted-csv>    archs the build targeted, e.g. "amd64,arm64,armhf"
#   <published-csv> archs that reached the channel (may be empty)
# Env:    SNAP_NAME (default zwave-js-ui)
set -euo pipefail

chan="${1:?usage: pr-comment.sh <channel> <wanted-csv> <published-csv>}"
wanted="${2:-}"
published="${3:-}"
snap="${SNAP_NAME:-zwave-js-ui}"

# csv -> sorted-unique newline list (empties dropped)
to_lines() { printf '%s' "${1:-}" | tr ',' '\n' | sed '/^$/d' | sort -u; }
w="$(to_lines "$wanted")"
p="$(to_lines "$published")"
count() { printf '%s\n' "${1}" | sed '/^$/d' | wc -l | tr -d ' '; }
nw="$(count "$w")"
np="$(count "$p")"

avail="$(printf '%s' "$p" | paste -sd', ' -)"
failed="$(comm -23 <(printf '%s\n' "$w" | sed '/^$/d') <(printf '%s\n' "$p" | sed '/^$/d') | paste -sd', ' -)"

if [ "$np" -eq 0 ]; then
    printf '❌ No architectures were published for this PR.\n'
    exit 0
fi

if [ -z "$failed" ]; then
    printf '✅ Published to `%s` — available to install & test:\n\n' "$chan"
    printf '  Architectures: %s\n' "$avail"
    note="auto-selects your arch"
else
    printf '⚠️ Partial publish to `%s` — %s of %s architectures.\n\n' "$chan" "$np" "$nw"
    printf '  Available for: %s\n' "$avail"
    note="works on: $avail"
fi
printf '  sudo snap install %s --channel=%s      # %s\n' "$snap" "$chan" "$note"
printf '  # or: sudo snap refresh %s --channel=%s\n' "$snap" "$chan"
if [ -n "$failed" ]; then
    printf '\n  ❌ Failed: %s — use "Re-run failed jobs" to retry just that arch (no rebuild of the published archs).\n' "$failed"
fi
```

- [ ] **Step 4: Make it executable**

Run: `chmod 755 .github/scripts/pr-comment.sh`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash .github/scripts/pr-comment.test.sh`
Expected: PASS — `All pr-comment tests passed.`

- [ ] **Step 6: Shellcheck (matches helper-tests.yml gate)**

Run: `shellcheck .github/scripts/pr-comment.sh .github/scripts/pr-comment.test.sh`
Expected: no output (clean).

- [ ] **Step 7: Commit**

```bash
git add .github/scripts/pr-comment.sh .github/scripts/pr-comment.test.sh
git commit -m "feat(ci): pure PR-build comment renderer (per-arch availability)"
```

---

## Task 2: Rewrite `pr-build-snap.yml` into five jobs

**Files:**
- Modify (full rewrite): `.github/workflows/pr-build-snap.yml`

- [ ] **Step 1: Replace the file with the five-job workflow**

Write `.github/workflows/pr-build-snap.yml`:

```yaml
name: PR Build Snap

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]
    # Only the snap recipe and its bundled inputs affect the built artifact, so
    # build + publish ONLY when those change. Docs/config edits must not mint a
    # store revision. requirements-duplicity.txt IS a build input (pip-installed).
    paths:
      - 'snap/**'
      - 'src/**'
      - 'requirements-duplicity.txt'
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

concurrency:
  group: pr-build-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

env:
  SNAP_NAME: zwave-js-ui

jobs:
  meta:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.meta.outputs.version }}
      track: ${{ steps.meta.outputs.track }}
      archs: ${{ steps.meta.outputs.archs }}
      archs_csv: ${{ steps.meta.outputs.archs_csv }}
    steps:
      - uses: actions/checkout@v7
      - name: Resolve version / track / archs
        id: meta
        run: |
          set -euo pipefail
          V="$(yq '.version' snap/snapcraft.yaml)"
          TRACK="$(.github/scripts/snap-release.sh version-to-track "$V")"
          ARCHS_JSON="$(yq -o=json -I=0 '.platforms | keys' snap/snapcraft.yaml)"
          ARCHS_CSV="$(yq '.platforms | keys | join(",")' snap/snapcraft.yaml)"
          {
            echo "version=$V"
            echo "track=$TRACK"
            echo "archs=$ARCHS_JSON"
            echo "archs_csv=$ARCHS_CSV"
          } >> "$GITHUB_OUTPUT"

  # Runs in parallel with the builds: it only needs the track NAME, so a failed
  # build never blocks or skips it. Idempotent (the script checks existence first).
  ensure-track:
    needs: meta
    if: ${{ github.event_name == 'pull_request' }}
    runs-on: ubuntu-latest
    env:
      SNAPCRAFT_STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
      SNAPCRAFT_SESSION_COOKIE: ${{ secrets.SNAPCRAFT_SESSION_COOKIE }}
    steps:
      - uses: actions/checkout@v7
      - name: Install snapcraft
        run: sudo snap install snapcraft --classic
      - name: Ensure version track exists
        run: |
          set -euo pipefail
          TRACK="${{ needs.meta.outputs.track }}"
          # Listing tracks uses the macaroon; skip create if it already exists.
          if snapcraft tracks "$SNAP_NAME" | awk 'NR>1{print $1}' | grep -qx "$TRACK"; then
            echo "Track $TRACK already exists."
            exit 0
          fi
          bash .github/scripts/snap-create-track.sh "$SNAP_NAME" "$TRACK"

  build:
    needs: meta
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false           # a dead arch must not cancel its siblings
      matrix:
        arch: ${{ fromJSON(needs.meta.outputs.archs) }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0         # snapcraft remote-build refuses shallow clones
      - name: Install snapcraft
        run: sudo snap install snapcraft --classic
      - name: Configure Launchpad credentials
        run: |
          set -euo pipefail
          mkdir -p ~/.local/share/snapcraft
          printf '%s\n' "${{ secrets.LAUNCHPAD_CREDENTIALS }}" > ~/.local/share/snapcraft/launchpad-credentials
      - name: Remote-build ${{ matrix.arch }}
        id: build
        run: .github/scripts/remote-build.sh "${{ matrix.arch }}"
      - name: Upload snap artifact
        if: ${{ steps.build.outputs.snaps != '0' }}
        uses: actions/upload-artifact@v4
        with:
          name: snap-${{ matrix.arch }}
          path: ${{ env.SNAP_NAME }}*${{ matrix.arch }}.snap
          retention-days: 1
          if-no-files-found: error
      - name: Capture snapcraft log on failure
        if: ${{ always() && steps.build.outputs.snaps == '0' }}
        run: |
          shopt -s nullglob
          logs=( ~/.local/state/snapcraft/log/*.log ~/.cache/snapcraft/log/*.log )
          out="${RUNNER_TEMP}/buildlog-${{ matrix.arch }}.txt"; : > "$out"
          if [ ${#logs[@]} -eq 0 ]; then
            echo "(no snapcraft log files found for ${{ matrix.arch }})" >> "$out"
          else
            for f in "${logs[@]}"; do { echo "===== $f ====="; cat "$f"; } >> "$out"; done
          fi
          tail -c 50000 "$out" > "$out.cut" && mv "$out.cut" "$out"
          echo "BUILDLOG=$out" >> "$GITHUB_ENV"
      - name: Upload snapcraft log artifact
        if: ${{ always() && steps.build.outputs.snaps == '0' }}
        uses: actions/upload-artifact@v4
        with:
          name: buildlog-${{ matrix.arch }}
          path: ${{ env.BUILDLOG }}
          retention-days: 1
          if-no-files-found: ignore

  upload:
    needs: [meta, build, ensure-track]
    # Run even though `build` reports failure from a sibling arch (!cancelled),
    # but only once the track exists.
    if: ${{ !cancelled() && needs.ensure-track.result == 'success' }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        arch: ${{ fromJSON(needs.meta.outputs.archs) }}
    env:
      SNAPCRAFT_STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
    steps:
      - uses: actions/checkout@v7
      - name: Install snapcraft
        run: sudo snap install snapcraft --classic
      - name: Download snap artifact
        uses: actions/download-artifact@v4
        with:
          name: snap-${{ matrix.arch }}
          path: .
        continue-on-error: true   # missing => this arch's build failed; handled below
      - name: Upload to v<MM>/edge/<PR>
        run: |
          set -uo pipefail
          TRACK="${{ needs.meta.outputs.track }}"
          PR="${{ github.event.pull_request.number }}"
          CHAN="$TRACK/edge/$PR"
          ARCH="${{ matrix.arch }}"
          f="$(ls -1 "${SNAP_NAME}"*"${ARCH}".snap 2>/dev/null | head -n1 || true)"
          # FAIL (not no-op) when the artifact is missing, so "Re-run failed jobs"
          # re-pairs a rebuilt arch with its upload instead of silently skipping it.
          if [ -z "$f" ]; then
            echo "::error::No snap artifact for ${ARCH} — its build did not succeed."
            exit 1
          fi
          echo "Uploading $f -> $CHAN"
          .github/scripts/retry.sh 3 15 -- snapcraft upload "$f" --release="$CHAN"
      - name: Mark published
        run: mkdir -p out && : > "out/uploaded-${{ matrix.arch }}"
      - name: Upload published marker
        uses: actions/upload-artifact@v4
        with:
          name: uploaded-${{ matrix.arch }}
          path: out/uploaded-${{ matrix.arch }}
          retention-days: 1
          if-no-files-found: error

  report:
    needs: [meta, build, ensure-track, upload]
    if: ${{ always() && github.event_name == 'pull_request' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Download published markers
        uses: actions/download-artifact@v4
        with:
          pattern: uploaded-*
          path: markers
          merge-multiple: true
        continue-on-error: true
      - name: Download build logs
        uses: actions/download-artifact@v4
        with:
          pattern: buildlog-*
          path: buildlogs
          merge-multiple: true
        continue-on-error: true
      - name: Render comment + completeness
        id: r
        run: |
          set -uo pipefail
          TRACK="${{ needs.meta.outputs.track }}"
          PR="${{ github.event.pull_request.number }}"
          CHAN="$TRACK/edge/$PR"
          WANTED="${{ needs.meta.outputs.archs_csv }}"
          PUBLISHED="$(ls markers/ 2>/dev/null | sed -n 's/^uploaded-//p' | paste -sd, - || true)"
          BODY="${RUNNER_TEMP}/comment.md"
          SNAP_NAME="$SNAP_NAME" .github/scripts/pr-comment.sh "$CHAN" "$WANTED" "$PUBLISHED" > "$BODY"
          # Fold the build log into the comment only when nothing was published.
          if [ -z "$PUBLISHED" ] && ls buildlogs/* >/dev/null 2>&1; then
            {
              echo
              echo '<details><summary>snapcraft log (last 50 KB)</summary>'
              echo
              echo '```text'
              cat buildlogs/*
              echo '```'
              echo
              echo '</details>'
            } >> "$BODY"
          fi
          echo "body=$BODY" >> "$GITHUB_OUTPUT"
          w="$(printf '%s' "$WANTED"    | tr ',' '\n' | sed '/^$/d' | sort -u)"
          p="$(printf '%s' "$PUBLISHED" | tr ',' '\n' | sed '/^$/d' | sort -u)"
          if [ "$w" = "$p" ]; then echo "complete=yes" >> "$GITHUB_OUTPUT"; else echo "complete=no" >> "$GITHUB_OUTPUT"; fi
      - name: Sticky PR comment
        uses: actions/github-script@v9
        env:
          BODY: ${{ steps.r.outputs.body }}
        with:
          script: |
            const fs = require('fs');
            const marker = '<!-- pr-build-snap -->';
            const text = fs.readFileSync(process.env.BODY, 'utf8');
            const body = `${marker}\n${text}`;
            const { owner, repo } = context.repo;
            const issue_number = context.payload.pull_request.number;
            const api = github.rest.issues;
            const { data: comments } = await api.listComments({ owner, repo, issue_number, per_page: 100 });
            const existing = comments.find(c => c.body && c.body.includes(marker));
            if (existing) await api.updateComment({ owner, repo, comment_id: existing.id, body });
            else await api.createComment({ owner, repo, issue_number, body });
      - name: Fail if any wanted arch is unpublished
        if: ${{ steps.r.outputs.complete != 'yes' }}
        run: |
          echo "::error::Incomplete publish: wanted=[${{ needs.meta.outputs.archs_csv }}]"
          exit 1
```

- [ ] **Step 2: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/pr-build-snap.yml')); print('yaml ok')"`
Expected: `yaml ok`

- [ ] **Step 3: Lint with actionlint (the repo's chosen linter — note `.gitignore` ships the binary)**

Run: `command -v actionlint && actionlint .github/workflows/pr-build-snap.yml || echo "actionlint not installed — skipping (CI/PR run will catch issues)"`
Expected: no findings (or the skip notice if the binary isn't present locally).

- [ ] **Step 4: Confirm the job graph + key gates with a grep sanity check**

Run:
```bash
grep -nE 'fail-fast: false|fromJSON\(needs.meta.outputs.archs\)|needs.ensure-track.result == .success.|!cancelled\(\)|always\(\)' .github/workflows/pr-build-snap.yml
```
Expected: matches for both matrices (`fail-fast: false` ×2, `fromJSON` ×2), the upload gate (`!cancelled()` + `ensure-track.result == 'success'`), and `always()` on report.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/pr-build-snap.yml
git commit -m "ci(build): split pr-build-snap into meta/ensure-track/build/upload/report (per-arch, selective re-run)"
```

---

## Task 3: Retry-harden `release-on-merge.yml`

**Files:**
- Modify: `.github/workflows/release-on-merge.yml` (the `Promote PR revisions to release channels` step)

- [ ] **Step 1: Wrap each store mutation in `retry.sh`**

In `.github/workflows/release-on-merge.yml`, inside the `Promote PR revisions to release channels` step, prefix each `snapcraft promote` / `snapcraft close` / `snapcraft set-default-track` invocation with `.github/scripts/retry.sh 3 15 --`. Apply these exact replacements:

Replace:
```bash
            snapcraft promote "$SNAP" --from-channel latest/candidate --to-channel latest/stable --yes
```
with:
```bash
            .github/scripts/retry.sh 3 15 -- snapcraft promote "$SNAP" --from-channel latest/candidate --to-channel latest/stable --yes
```

Replace:
```bash
          snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel "$TRACK/stable" --yes
```
with:
```bash
          .github/scripts/retry.sh 3 15 -- snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel "$TRACK/stable" --yes
```

Replace:
```bash
            snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel latest/candidate --yes
            snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel latest/edge --yes
```
with:
```bash
            .github/scripts/retry.sh 3 15 -- snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel latest/candidate --yes
            .github/scripts/retry.sh 3 15 -- snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel latest/edge --yes
```

Replace:
```bash
          snapcraft close "$SNAP" "$BRANCH" --yes || echo "close failed (already gone?); ignoring"
```
with:
```bash
          .github/scripts/retry.sh 3 15 -- snapcraft close "$SNAP" "$BRANCH" --yes || echo "close failed (already gone?); ignoring"
```

Replace:
```bash
            snapcraft set-default-track "$SNAP" "$TRACK"
```
with:
```bash
            .github/scripts/retry.sh 3 15 -- snapcraft set-default-track "$SNAP" "$TRACK"
```

- [ ] **Step 2: Validate the YAML parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-on-merge.yml')); print('yaml ok')"`
Expected: `yaml ok`

- [ ] **Step 3: Confirm every mutation is wrapped (and none missed)**

Run:
```bash
grep -nE 'snapcraft (promote|close|set-default-track)' .github/workflows/release-on-merge.yml
```
Expected: every matching line is prefixed with `.github/scripts/retry.sh 3 15 --` (5 invocations total).

- [ ] **Step 4: actionlint (if present)**

Run: `command -v actionlint && actionlint .github/workflows/release-on-merge.yml || echo "actionlint not installed — skipping"`
Expected: no findings (or skip notice).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release-on-merge.yml
git commit -m "ci(release): retry-harden merge promotions (transient 401/disconnect)"
```

---

## Task 4: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full helper test suite (the helper-tests.yml gate)**

Run:
```bash
shellcheck .github/scripts/*.sh && for t in .github/scripts/*.test.sh; do echo "== $t"; bash "$t" || exit 1; done
```
Expected: shellcheck clean; every `*.test.sh` ends with its "All … tests passed." line and exit 0 (includes the new `pr-comment.test.sh`).

- [ ] **Step 2: Parse all workflows**

Run:
```bash
for f in .github/workflows/*.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f')); print('ok', '$f')"; done
```
Expected: `ok` for every workflow file.

- [ ] **Step 3: Push the branch and open a PR (integration test is the real run)**

The workflow's true behavior can only be verified on GitHub. Push and open the PR, then check on the PR's Actions run:

```bash
git push -u origin feat/ci-build-release-split
gh pr create --base main --head feat/ci-build-release-split \
  --title "ci: split build/release for selective re-run (per-arch)" \
  --body-file docs/superpowers/specs/2026-06-22-ci-build-release-split-design.md
```

- [ ] **Step 4: Acceptance checks on the PR run** (from the spec's Testing section)

Confirm on the Actions run:
1. **Clean PR:** `meta` → `ensure-track` runs in parallel with `build` (3 arch jobs) → `upload` (3 arch jobs) → `report`; the sticky comment lists all archs; the overall check is green.
2. **Selective re-run (release):** if `ensure-track` ever fails (e.g. stale `SNAPCRAFT_SESSION_COOKIE`), the `build` jobs stay green; clicking **Re-run failed jobs** reruns only `ensure-track` + `upload` + `report` — **no rebuild**.
3. **Selective re-run (arch):** if one `build-<arch>` fails, the others publish, the comment notifies + lists the available archs, and **Re-run failed jobs** rebuilds + uploads only the failed arch (no new revisions for the already-published archs).

---

## Notes

- `SNAPCRAFT_SESSION_COOKIE` is currently expired (it broke PR #210). That refresh is an operational prerequisite, **out of scope** for this code change — but acceptance check #2 above is exactly the scenario it causes, so this PR is the natural place to confirm the selective re-run once the secret is refreshed.
- If per-arch parallel `remote-build` overloads Launchpad (the account has previously hit a scanner wedge), the fallback in the spec is a single `build` job that builds all archs and emits per-arch artifacts — keeping per-arch *upload* while dropping per-arch *build*. Decide based on acceptance check #1.
