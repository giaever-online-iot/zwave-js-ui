# Snap CI build/track/release pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PR pushes build the snap on all archs and publish to `v<MM>/edge/<PR>`, and make merges promote those exact revisions to `v<MM>/stable` + `latest/candidate` (+ `latest/stable` on a major bump), close the PR branch, and set the newest `v<MM>` as default track.

**Architecture:** Two PR-driven workflows (`pr-build-snap.yml`, `release-on-merge.yml`) orchestrate `snapcraft`; all version math and `snap info` parsing live in one tested helper (`.github/scripts/snap-release.sh`). The old `snap-create-track.yml` is deleted; track creation folds into the build workflow. Forks are already blocked by `block-fork-prs.yml`, so same-repo PRs have the store secrets needed to publish.

**Tech Stack:** GitHub Actions, bash, `yq` (mikefarah v4), `snapcraft` (Launchpad `remote-build`, `promote`, `close`, `set-default-track`, dashboard `create-track` API), `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-06-09-snap-ci-build-release-pipeline-design.md`

---

## File structure

| Path | Responsibility |
|------|----------------|
| `.github/scripts/snap-release.sh` | **Create.** Pure version/channel math + `snap info` parsing. Subcommands: `version-to-track`, `major`, `channel-version`, `branch-has-revisions`, `needs-stable-bump`, `is-at-least`. |
| `.github/scripts/snap-release.test.sh` | **Create.** Self-contained bash assertions over a fixture. |
| `.github/scripts/fixtures/snap-info.txt` | **Create.** Real `snap info zwave-js-ui` capture (+ a synthetic `edge/42` branch) anchoring the parser. |
| `.github/workflows/pr-build-snap.yml` | **Replace.** Build → ensure track → upload to `v<MM>/edge/<PR>` → sticky PR comment. |
| `.github/workflows/release-on-merge.yml` | **Create.** On merged PR: promote revisions → release channels, close branch, set default track. |
| `.github/workflows/snap-create-track.yml` | **Delete.** Logic absorbed. |
| `.github/workflows/block-fork-prs.yml` | Untouched. |
| `CLAUDE.md` | **Modify.** CI bullets now describe the new flow. |

**Conventions to match:** existing workflows use `actions/checkout@v6` and `actions/github-script@v9` with the `github.rest.issues || github.issues` compatibility shim (see `block-fork-prs.yml`). Reuse both. Scripts use `#!/usr/bin/env bash` (see `src/helper/functions`).

---

## Task 1: Helper test harness + fixture (TDD red)

**Files:**
- Create: `.github/scripts/fixtures/snap-info.txt`
- Create: `.github/scripts/snap-release.test.sh`

- [ ] **Step 1: Create the fixture** `.github/scripts/fixtures/snap-info.txt`

Exact content (spaces only, no tabs; keep the trailing blank line):

```text
name:      zwave-js-ui
summary:   Full-featured Z-Wave Control Panel and MQTT Gateway.
store-url: https://snapcraft.io/zwave-js-ui
license:   MIT
channels:
  latest/stable:    v11.14.0 2026-06-07 (847)  107MB -
  latest/candidate: v11.19.1 2026-06-07 (850) 75.4MB -
  latest/beta:      ^
  latest/edge:      v11.19.1 2026-06-09 (856) 75.4MB -
  v11.19/stable:    v11.19.1 2026-06-07 (850) 75.4MB -
  v11.19/candidate: ^
  v11.19/beta:      ^
  v11.19/edge:      ^
  v11.19/edge/42:   v11.19.2 2026-06-09 (856) 75.4MB 2026-07-09T00:00:00Z
  v11.8/stable:     v11.8.2  2025-12-02 (829)  105MB -

```

- [ ] **Step 2: Write the test script** `.github/scripts/snap-release.test.sh`

```bash
#!/usr/bin/env bash
# Fixture-driven unit tests for snap-release.sh. No network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$HERE/snap-release.sh"
INFO="$HERE/fixtures/snap-info.txt"
fail=0

check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

check "version-to-track v-prefixed" "v11.19" "$("$SR" version-to-track v11.19.1)"
check "version-to-track bare"       "v11.19" "$("$SR" version-to-track 11.19.1)"
check "version-to-track x.0"        "v12.0"  "$("$SR" version-to-track v12.0.0)"
check "version-to-track empty"      ""       "$("$SR" version-to-track "")"

check "major v-prefixed" "12" "$("$SR" major v12.0.0)"
check "major bare"       "11" "$("$SR" major 11.19.1)"
check "major empty"      ""   "$("$SR" major "")"

check "channel-version candidate" "v11.19.1" "$("$SR" channel-version latest/candidate <"$INFO")"
check "channel-version stable"    "v11.14.0" "$("$SR" channel-version latest/stable <"$INFO")"
check "channel-version caret"     ""         "$("$SR" channel-version latest/beta <"$INFO")"
check "channel-version branch"    "v11.19.2" "$("$SR" channel-version v11.19/edge/42 <"$INFO")"
check "channel-version absent"    ""         "$("$SR" channel-version v99.9/stable <"$INFO")"

check "branch-has-revisions yes" "yes" "$("$SR" branch-has-revisions v11.19 42 <"$INFO")"
check "branch-has-revisions no"  "no"  "$("$SR" branch-has-revisions v11.19 99 <"$INFO")"

check "needs-stable-bump major" "yes" "$("$SR" needs-stable-bump v12.0.0 v11.20.3)"
check "needs-stable-bump minor" "no"  "$("$SR" needs-stable-bump v11.20.0 v11.19.1)"
check "needs-stable-bump empty" "no"  "$("$SR" needs-stable-bump v11.19.1 "")"

check "is-at-least equal"        "yes" "$("$SR" is-at-least v11.19.1 v11.19.1)"
check "is-at-least greater"      "yes" "$("$SR" is-at-least v11.20.0 v11.19.9)"
check "is-at-least lesser"       "no"  "$("$SR" is-at-least v11.5.0 v11.19.0)"
check "is-at-least empty-floor"  "yes" "$("$SR" is-at-least v11.0.0 "")"
check "is-at-least minor-numeric" "yes" "$("$SR" is-at-least v11.20.0 v11.9.0)"

exit "$fail"
```

- [ ] **Step 3: Make the test executable and run it (expect red)**

Run:
```bash
chmod +x .github/scripts/snap-release.test.sh
bash .github/scripts/snap-release.test.sh; echo "exit=$?"
```
Expected: every line `FAIL` (helper missing → empty actual), `exit=1`.

- [ ] **Step 4: Commit**

```bash
git add .github/scripts/snap-release.test.sh .github/scripts/fixtures/snap-info.txt
git commit -m "test: add snap-release helper tests + snap info fixture (red)"
```

---

## Task 2: Implement the helper (TDD green)

**Files:**
- Create: `.github/scripts/snap-release.sh`

- [ ] **Step 1: Write the helper** `.github/scripts/snap-release.sh`

```bash
#!/usr/bin/env bash
#
# snap-release.sh — version/channel math + `snap info` parsing for the snap
# release workflows. Pure functions: read args/stdin, write stdout, no network.
#
# Subcommands:
#   version-to-track <ver>             v11.19.1|11.19.1 -> v11.19    (""->"")
#   major <ver>                        v12.0.0 -> 12                 (""->"")
#   channel-version <channel>          (stdin: `snap info`) -> version or ""
#   branch-has-revisions <track> <pr>  (stdin: `snap info`) -> yes|no
#   needs-stable-bump <new> <cand>     yes iff cand set & major(new)>major(cand)
#   is-at-least <ver> <floor>          yes iff ver>=floor  (floor "" -> yes)
set -euo pipefail

# numeric major.minor.patch compare; echoes -1|0|1 (leading 'v' stripped)
_vercmp() {
  local a="${1#v}" b="${2#v}" i x y
  local -a A B
  IFS=. read -ra A <<<"$a"
  IFS=. read -ra B <<<"$b"
  for i in 0 1 2; do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    if (( 10#$x > 10#$y )); then echo 1; return; fi
    if (( 10#$x < 10#$y )); then echo -1; return; fi
  done
  echo 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  version-to-track)
    in="${1:-}"
    if [ -z "$in" ]; then echo ""; exit 0; fi
    in="${in#v}"
    IFS=. read -ra parts <<<"$in"
    printf 'v%s.%s\n' "${parts[0]}" "${parts[1]:-0}"
    ;;
  major)
    in="${1:-}"
    if [ -z "$in" ]; then echo ""; exit 0; fi
    in="${in#v}"
    printf '%s\n' "${in%%.*}"
    ;;
  channel-version)
    # stdin = `snap info`; arg = channel like latest/candidate or v11.19/edge/42
    awk -v ch="${1:-}" '
      /^channels:/ { inblk=1; next }
      inblk && NF==0 { inblk=0 }
      inblk {
        line=$0; sub(/^[ \t]+/, "", line)
        ci=index(line, ":"); if (ci==0) next
        name=substr(line, 1, ci-1)
        rest=substr(line, ci+1); sub(/^[ \t]+/, "", rest)
        split(rest, a, /[ \t]+/); ver=a[1]
        if (name==ch) {
          if (ver=="^" || ver=="--" || ver=="-") ver=""
          print ver; exit
        }
      }'
    ;;
  branch-has-revisions)
    # stdin = `snap info`; args = track pr. Re-use channel-version via `bash "$0"`
    # so this works whether or not the script's exec bit is set.
    info="$(cat)"
    ver="$(printf '%s\n' "$info" | bash "$0" channel-version "${1:-}/edge/${2:-}")"
    if [ -n "$ver" ]; then echo yes; else echo no; fi
    ;;
  needs-stable-bump)
    new="${1:-}"; cand="${2:-}"
    if [ -z "$cand" ]; then echo no; exit 0; fi
    mn="${new#v}"; mn="${mn%%.*}"
    mc="${cand#v}"; mc="${mc%%.*}"
    if (( 10#$mn > 10#$mc )); then echo yes; else echo no; fi
    ;;
  is-at-least)
    ver="${1:-}"; floor="${2:-}"
    if [ -z "$floor" ]; then echo yes; exit 0; fi
    c="$(_vercmp "$ver" "$floor")"
    if [ "$c" -ge 0 ]; then echo yes; else echo no; fi
    ;;
  *)
    echo "snap-release.sh: unknown subcommand: ${cmd:-<none>}" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 2: Make executable and run tests (expect green)**

Run:
```bash
chmod +x .github/scripts/snap-release.sh
bash .github/scripts/snap-release.test.sh; echo "exit=$?"
```
Expected: every line `ok`, `exit=0`.

- [ ] **Step 3: Lint with shellcheck**

Run:
```bash
shellcheck .github/scripts/snap-release.sh .github/scripts/snap-release.test.sh
```
Expected: no output (clean). If any warning appears, fix it and re-run Step 2.

- [ ] **Step 4: Commit**

```bash
git add .github/scripts/snap-release.sh
git commit -m "feat: snap-release helper for version/channel math (green)"
```

---

## Task 3: Rewrite `pr-build-snap.yml`

**Files:**
- Modify (full replace): `.github/workflows/pr-build-snap.yml`

- [ ] **Step 1: Replace the file** with exactly:

```yaml
name: PR Build Snap

on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]
    paths-ignore:
      - '.github/**'
      - '**/*.md'
      - '**/*.txt'
      - 'renovate.json'
      - '.vscode/**'
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
  build-and-release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Install snapcraft
        run: sudo snap install snapcraft --classic

      - name: Configure Launchpad credentials
        run: |
          set -euo pipefail
          mkdir -p ~/.local/share/snapcraft
          printf '%s' "${{ secrets.LAUNCHPAD_CREDENTIALS }}" > ~/.local/share/snapcraft/launchpad-credentials

      - name: Resolve version / track / archs
        id: meta
        run: |
          set -euo pipefail
          V="$(yq '.version' snap/snapcraft.yaml)"
          TRACK="$(.github/scripts/snap-release.sh version-to-track "$V")"
          ARCHS="$(yq '.platforms | keys | join(",")' snap/snapcraft.yaml)"
          {
            echo "version=$V"
            echo "track=$TRACK"
            echo "archs=$ARCHS"
          } >> "$GITHUB_OUTPUT"

      - name: Remote-build all archs (tolerant of partial failure)
        id: build
        run: |
          # Deliberately NOT 'set -e': a partial-arch build must not abort the step.
          set -uo pipefail
          echo "Building: ${{ steps.meta.outputs.archs }}"
          snapcraft remote-build -v --launchpad-accept-public-upload --build-for="${{ steps.meta.outputs.archs }}" || true
          ls -1 ./*.snap 2>/dev/null || echo "(no .snap files produced)"
          count=$(ls -1 ./*.snap 2>/dev/null | wc -l | tr -d ' ')
          echo "snaps=$count" >> "$GITHUB_OUTPUT"

      - name: Ensure version track exists
        if: ${{ steps.build.outputs.snaps != '0' }}
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

      - name: Upload built archs to v<MM>/edge/<PR>
        id: release
        if: ${{ steps.build.outputs.snaps != '0' && github.event_name == 'pull_request' }}
        env:
          SNAPCRAFT_STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
        run: |
          set -uo pipefail
          TRACK="${{ steps.meta.outputs.track }}"
          PR="${{ github.event.pull_request.number }}"
          CHAN="$TRACK/edge/$PR"
          IFS=',' read -ra WANT <<< "${{ steps.meta.outputs.archs }}"
          uploaded=(); missing=()
          for arch in "${WANT[@]}"; do
            f="$(ls -1 "${SNAP_NAME}"_*_"${arch}".snap 2>/dev/null | head -n1 || true)"
            if [ -z "$f" ]; then echo "missing snap for $arch"; missing+=("$arch"); continue; fi
            echo "Uploading $f -> $CHAN"
            if snapcraft upload "$f" --release="$CHAN"; then uploaded+=("$arch"); else echo "upload failed for $arch"; missing+=("$arch"); fi
          done
          {
            echo "channel=$CHAN"
            echo "missing=${missing[*]:-}"
          } >> "$GITHUB_OUTPUT"
          {
            echo "comment<<EOF"
            if [ "${#uploaded[@]}" -gt 0 ]; then
              printf '✅ Snap for this PR published to `%s`\n\n' "$CHAN"
              printf '```bash\nsudo snap install %s --channel=%s   # or: sudo snap refresh %s --channel=%s\n```\n\n' "$SNAP_NAME" "$CHAN" "$SNAP_NAME" "$CHAN"
              printf 'Built: %s\n' "${uploaded[*]}"
            else
              printf '❌ No architectures were published for this PR.\n'
            fi
            if [ "${#missing[@]}" -gt 0 ]; then printf '\n⚠️ Failed/missing arch(es): %s\n' "${missing[*]}"; fi
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Sticky PR comment
        if: ${{ always() && github.event_name == 'pull_request' }}
        uses: actions/github-script@v9
        env:
          BODY: ${{ steps.release.outputs.comment }}
          BUILT: ${{ steps.build.outputs.snaps }}
        with:
          script: |
            const marker = '<!-- pr-build-snap -->';
            const text = (process.env.BUILT === '0' || !process.env.BODY)
              ? '❌ Build produced no snaps. Check the Action logs.'
              : process.env.BODY;
            const body = `${marker}\n${text}`;
            const { owner, repo } = context.repo;
            const issue_number = context.payload.pull_request.number;
            const issuesApi = (github.rest && github.rest.issues) ? github.rest.issues : github.issues;
            const { data: comments } = await issuesApi.listComments({ owner, repo, issue_number, per_page: 100 });
            const existing = comments.find(c => c.body && c.body.includes(marker));
            if (existing) {
              await issuesApi.updateComment({ owner, repo, comment_id: existing.id, body });
            } else {
              await issuesApi.createComment({ owner, repo, issue_number, body });
            }

      - name: Fail if build/upload incomplete
        if: ${{ steps.build.outputs.snaps == '0' || steps.release.outputs.missing != '' }}
        run: |
          echo "::error::Incomplete: snaps=${{ steps.build.outputs.snaps }} missing=[${{ steps.release.outputs.missing }}]"
          exit 1
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
yq '.' .github/workflows/pr-build-snap.yml > /dev/null && echo "YAML OK"
```
Expected: `YAML OK` (non-zero exit + parse error means a syntax problem to fix).

- [ ] **Step 3: Sanity-check key wiring**

Run:
```bash
yq '.on | keys' .github/workflows/pr-build-snap.yml
yq '.jobs.build-and-release.steps | map(.name)' .github/workflows/pr-build-snap.yml
```
Expected: triggers include `pull_request` and `workflow_dispatch`; step list ends with `Fail if build/upload incomplete`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-build-snap.yml
git commit -m "feat(ci): build + publish PR snaps to v<MM>/edge/<PR>"
```

---

## Task 4: Create `release-on-merge.yml`

**Files:**
- Create: `.github/workflows/release-on-merge.yml`

- [ ] **Step 1: Create the file** with exactly:

```yaml
name: Release on merge

on:
  pull_request:
    types: [closed]
    branches: [main]

permissions:
  contents: read

env:
  SNAP_NAME: zwave-js-ui

jobs:
  promote:
    if: ${{ github.event.pull_request.merged == true }}
    runs-on: ubuntu-latest
    env:
      SNAPCRAFT_STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Install snapcraft
        run: sudo snap install snapcraft --classic

      - name: Resolve version / track
        id: meta
        run: |
          set -euo pipefail
          V="$(yq '.version' snap/snapcraft.yaml)"
          TRACK="$(.github/scripts/snap-release.sh version-to-track "$V")"
          {
            echo "version=$V"
            echo "track=$TRACK"
            echo "pr=${{ github.event.pull_request.number }}"
          } >> "$GITHUB_OUTPUT"

      - name: Promote PR revisions to release channels
        run: |
          set -euo pipefail
          SR=.github/scripts/snap-release.sh
          SNAP="$SNAP_NAME"
          V="${{ steps.meta.outputs.version }}"
          TRACK="${{ steps.meta.outputs.track }}"
          PR="${{ steps.meta.outputs.pr }}"
          BRANCH="$TRACK/edge/$PR"

          INFO="$(snap info "$SNAP")"

          if [ "$("$SR" branch-has-revisions "$TRACK" "$PR" <<<"$INFO")" != "yes" ]; then
            echo "No revisions in $BRANCH (docs-only merge / build failed / branch expired). Nothing to promote."
            exit 0
          fi

          CAND="$("$SR" channel-version latest/candidate <<<"$INFO")"
          echo "Merged $V; current latest/candidate=${CAND:-<none>}"

          # 1) Major bump: move previous major's final to latest/stable BEFORE candidate is overwritten.
          if [ "$("$SR" needs-stable-bump "$V" "$CAND")" = "yes" ]; then
            echo ">> major bump: latest/candidate -> latest/stable"
            snapcraft promote "$SNAP" --from-channel latest/candidate --to-channel latest/stable --yes
          fi

          # 2) The version track's own stable line (always; safe for backports).
          echo ">> $BRANCH -> $TRACK/stable"
          snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel "$TRACK/stable" --yes

          # 3) Shared latest/* only if this isn't a backport.
          if [ "$("$SR" is-at-least "$V" "$CAND")" = "yes" ]; then
            echo ">> $BRANCH -> latest/candidate, latest/edge"
            snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel latest/candidate --yes
            snapcraft promote "$SNAP" --from-channel "$BRANCH" --to-channel latest/edge --yes
          else
            echo ">> backport ($V < $CAND): leaving latest/* unchanged"
          fi

          # 4) Close the PR branch (auto-expires anyway; this is tidy-up).
          echo ">> closing $BRANCH"
          snapcraft close "$SNAP" "$BRANCH" --yes || echo "close failed (already gone?); ignoring"

          # 5) Default track follows the merged line; never regresses or jumps to stray tracks.
          CAND_TRACK=""
          if [ -n "$CAND" ]; then CAND_TRACK="$("$SR" version-to-track "$CAND")"; fi
          if [ "$TRACK" != "$CAND_TRACK" ] && [ "$("$SR" is-at-least "$TRACK" "$CAND_TRACK")" = "yes" ]; then
            echo ">> set default track -> $TRACK"
            snapcraft set-default-track "$SNAP" "$TRACK"
          else
            echo ">> default track unchanged (line=${CAND_TRACK:-<none>})"
          fi
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
yq '.' .github/workflows/release-on-merge.yml > /dev/null && echo "YAML OK"
yq '.jobs.promote.if' .github/workflows/release-on-merge.yml
```
Expected: `YAML OK`, and the `if` prints `${{ github.event.pull_request.merged == true }}`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-on-merge.yml
git commit -m "feat(ci): promote PR revisions to release channels on merge"
```

---

## Task 5: Delete the obsolete track workflow

**Files:**
- Delete: `.github/workflows/snap-create-track.yml`

- [ ] **Step 1: Confirm nothing else references it**

Run:
```bash
grep -rn "snap-create-track\|Create Snap Track" .github CLAUDE.md README.md || echo "no refs except CLAUDE.md (fixed next task)"
```
Expected: only the CLAUDE.md bullet (handled in Task 6) — no workflow `workflow_run` references it.

- [ ] **Step 2: Remove the file and commit**

```bash
git rm .github/workflows/snap-create-track.yml
git commit -m "chore(ci): remove snap-create-track.yml (folded into build/merge workflows)"
```

---

## Task 6: Update CLAUDE.md CI section

**Files:**
- Modify: `CLAUDE.md` (the two bullets at lines ~90–91)

- [ ] **Step 1: Replace the two stale bullets**

Find:
```markdown
- `pr-build-snap.yml` builds the snap via Launchpad remote-build on PRs (skips doc/config-only changes), then uploads per-arch artifacts. It can be run manually via `workflow_dispatch` with platform selection or by reusing a prior run's artifacts (`run_id`).
- `snap-create-track.yml` runs after a successful build to create version tracks and set the default track in the Snap Store.
```

Replace with:
```markdown
- `pr-build-snap.yml` builds the snap via Launchpad remote-build on PRs (skips doc/config-only changes), then **publishes each arch to the per-PR channel `v<major.minor>/edge/<PR#>`** in the Snap Store, creating the `v<MM>` track first if missing (dashboard `create-track` API via the `SNAPCRAFT_SESSION` secret). Partial-arch builds upload what succeeded and mark the check failed. A sticky PR comment shows the channel + install command.
- `release-on-merge.yml` runs when a PR merges: it **promotes the PR's revisions** from `v<MM>/edge/<PR#>` to `v<MM>/stable` and `latest/candidate` + `latest/edge` (and bumps the previous major's final to `latest/stable` on a major release), closes the PR branch, and sets the newest `v<MM>` as the default track. All version/channel math lives in `.github/scripts/snap-release.sh` (unit-tested via `snap-release.test.sh`).
```

- [ ] **Step 2: Verify the edit applied and nothing stale remains**

Run:
```bash
grep -n "release-on-merge\|snap-create-track" CLAUDE.md
```
Expected: a line mentioning `release-on-merge`; **no** mention of `snap-create-track`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md CI section for new build/release pipeline"
```

---

## Task 7: Final verification & self-review

**Files:** none (verification only)

- [ ] **Step 1: Re-run the full helper test suite + lint**

Run:
```bash
bash .github/scripts/snap-release.test.sh && echo "TESTS PASS"
shellcheck .github/scripts/snap-release.sh .github/scripts/snap-release.test.sh && echo "LINT CLEAN"
```
Expected: `TESTS PASS` and `LINT CLEAN`.

- [ ] **Step 2: Validate every workflow parses**

Run:
```bash
for f in .github/workflows/*.yml; do yq '.' "$f" > /dev/null && echo "OK $f"; done
```
Expected: `OK` for `block-fork-prs.yml`, `pr-build-snap.yml`, `release-on-merge.yml`; `snap-create-track.yml` absent.

- [ ] **Step 3: Confirm the tree state**

Run:
```bash
git status --short
git log --oneline -7
ls .github/workflows .github/scripts
```
Expected: clean working tree; commits for tasks 1–6 present; `snap-create-track.yml` gone; helper + tests + fixture present.

- [ ] **Step 4 (optional, if `actionlint` is later installed): lint workflows**

Run:
```bash
command -v actionlint >/dev/null && actionlint .github/workflows/*.yml || echo "actionlint not installed; skipped (yq parse + live run cover it)"
```

---

## Ops notes (not code — surface to maintainer before/at merge)

1. **Secrets must exist** in the repo: `SNAPCRAFT_STORE_CREDENTIALS`, `LAUNCHPAD_CREDENTIALS`, `SNAPCRAFT_SESSION`. The first PR exercises all three.
2. **Track-Creation-Guardrails** for `zwave-js-ui` must allow `v\d+\.\d+`, or `create-track` returns 4xx (the workflow fails with a clear message).
3. **Branch-protection required checks:** the build job is now `build-and-release` (was `build`). Update any required-status-check config to the new job/workflow name, or merges may block/allow incorrectly.
4. **First live PR is the acceptance test:** confirm `v<MM>/edge/<PR>` shows in `snap info zwave-js-ui`; then confirm `snapcraft promote --from-channel <branch>` works on merge (the one unverified mechanic). Fallback if not: `snapcraft release <snap> <rev> <channel>` per arch using revisions from `snapcraft status`.
5. The stray **`v20.0` track** is intentionally ignored by the default-track logic; no action needed, but you may want to ask Canonical to remove it.
```

