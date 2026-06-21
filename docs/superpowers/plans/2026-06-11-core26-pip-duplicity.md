# core24 → core26 with pip-sourced duplicity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the snap base from `core24` to `core26` and source duplicity from PyPI (pinned + hash-locked, `--no-deps`) running on a snap-staged Python, so all three architectures ship the same duplicity version with no reliance on the (removed) base interpreter.

**Architecture:** core26 no longer bundles Python, so the `backup-deps` part stages `python3` (interpreter + stdlib) from the resolute archive and pip-installs *only* the `duplicity` package into `$SNAP/usr/lib/python3/dist-packages` — its runtime dependencies stay as archive debs (parity with the resolute duplicity deb's `Depends`). The backup script invokes duplicity as `"$SNAP/usr/bin/python3" -m duplicity <action>`, which consults no shebang and finds `dist-packages` via the staged interpreter's own prefix. The backup action switches from duplicity's implicit form to the explicit `backup` verb (2.0+ CLI, 3.x-proof).

**Tech Stack:** snapcraft (core26, `nil` plugin + `override-build`), pip 25 (`--no-deps --no-build-isolation --require-hashes --break-system-packages --target`), duplicity 3.0.7 (PyPI), bash, existing `tests/` harness + shellcheck.

> **As-built deviations (2026-06-11):** three review-driven fixes landed after this plan was written — `422d7c7` (pip must run via the build VM's `/usr/bin/python3`: stage-packages unpack into `CRAFT_PART_INSTALL` before `override-build` and its `usr/bin` shadows PATH, so bare `python3` is the staged, pip-less interpreter — do NOT copy Task 2's original snippet verbatim), `9fbfac7` (strip pip's broken-shebang `dist-packages/bin` console script + dead `share/` data_files), `2189497` (`export PYTHONSAFEPATH=1`: `-m` puts the caller's cwd on `sys.path`; plus interpreter-pinned test needles). The suite is 43 tests after the fixes (not 42), the built amd64 snap measured 101 MB (not ~110 MB), and both CI workflows' `paths:` filters gained `requirements-duplicity.txt` so Renovate bump PRs actually build.

---

## Context (research findings — verified 2026-06-11)

- **core26** is in `latest/stable` for amd64/arm64/armhf (and more) since 2026-04-29. Snapcraft `latest/stable` (8.14.5) builds core26 snaps; Launchpad remote-build supports core22+. **No CI workflow changes are required** (PyPI is reachable from LP builders through the same proxy the npm plugin already uses to fetch Node).
- **core26 ships no Python.** Today's setup works only because core24's base interpreter ran the deb-staged duplicity.
- **duplicity 3.0.7 on PyPI**: `requires_python <3.15` (resolute has 3.14); manylinux wheels for x86_64/aarch64 (cp314 included); **no armhf wheel** → armhf compiles the sdist's `_librsync` C extension at build time (needs `librsync-dev`, `python3-dev`, `build-essential`).
- **duplicity's PyPI metadata declares every backend as a hard dependency** (azure, dropbox, google-api, …) — a plain `pip install duplicity` pulls ~250 MB of unwanted backends. Hence `--no-deps` + curated deb deps.
- **Resolute duplicity deb (3.0.6.3) `Depends`** (authoritative runtime list, read from the .deb): `librsync2t64`, `python3 (>=3.14~,<3.15)`, `python3-fasteners`, `python3-httplib2`, `python3-lxml`, `python3-paramiko`, `python3-pexpect`, `python3-psutil`, `python3-requests`, `python3-setuptools`, `gnupg`. Note: **`librsync2` was renamed `librsync2t64`** on resolute. `python-gettext` (new in 3.0.7's metadata) has **no resolute deb** → it rides in the pip requirements file (pure Python).
- **Resolute toolchain**: `python3-setuptools 78.1.1` satisfies duplicity's `>=78.1.0`, so `--no-build-isolation` is safe; pip 25 enforces PEP 668 even for `--target` → `--break-system-packages` is required (harmless: the target is the part install dir).
- **Baseline:** `bash tests/backup_test.sh` → `42 passed, 0 failed`; `shellcheck -S warning -x src/bin/backup` → silent (plain `-x` shows only an SC1091 *info* about the runtime-resolved `$SNAP` source path).

**Branch strategy:** The current `src/bin/backup` tip (gpg-agent fixes, `bbdf6b8`) is on `feat/backup-key-management`, not yet on `main`. Create the worktree/branch (via superpowers:using-git-worktrees) **off `feat/backup-key-management`**, e.g. `feat/core26-pip-duplicity`. Before opening the PR (Task 7), check whether the backup-key-management PR has merged: if yes, rebase onto `main`; if not, open as draft and mark it stacked. PRs must target `main` from an in-repo branch (repo rule).

## File structure

- Create: `requirements-duplicity.txt` — pinned, hash-locked pip input (repo root = `CRAFT_PROJECT_DIR`; the `requirements-*.txt` name is matched by Renovate's `pip_requirements` manager for version-bump PRs).
- Modify: `snap/snapcraft.yaml` — `base:` (line 3) and the whole `parts.backup-deps` block.
- Modify: `src/bin/backup` — `DUP_PY` declaration, 4 duplicity call sites, 2 stale core24 comments.
- Modify: `tests/backup_test.sh` — 3 command-string assertions.
- Modify: `CLAUDE.md`, `.github/workflows/pr-build-snap.yml` — stale core24 references.

---

### Task 1: Pin duplicity from PyPI (`requirements-duplicity.txt`)

**Files:**
- Create: `requirements-duplicity.txt`

- [ ] **Step 1: Create the requirements file**

Create `requirements-duplicity.txt` at the repo root with exactly:

```text
# Duplicity, pinned + hash-locked. Installed by snap/snapcraft.yaml (backup-deps part)
# with `pip install --no-deps`: runtime deps come from deb stage-packages instead
# (the resolute duplicity deb's Depends is the authoritative list). python-gettext has
# no resolute deb, so it rides here. Hashes cover the sdist (armhf builds from source)
# plus the cp314 manylinux wheels (amd64, arm64).
#
# To bump: change the version, then list the new artifacts + hashes with
#   curl -s https://pypi.org/pypi/duplicity/<version>/json | python3 -c \
#     "import json,sys; [print(u['filename'], u['digests']['sha256']) for u in json.load(sys.stdin)['urls']]"
# and keep: the .tar.gz hash + the cp3XX (= resolute python) x86_64 and aarch64 wheel hashes.
duplicity==3.0.7 \
    --hash=sha256:464245217285012e8e0c74ad3edf16be7ff4801caa5272745f10d93a2a7de44e \
    --hash=sha256:874b8496dda49eb755eca9230dd73b03ff52e0d1bb316b1b189d2af0da4b3751 \
    --hash=sha256:7ddfa3902b43e7fd4dab268a49aad8c321b4853f9122000691a1be636a2fcc5d
python-gettext==5.0 \
    --hash=sha256:083d4c72c5e72a6bd83b0570770792b9a1e572d8ab3e9cba554e0cd4781aa84a \
    --hash=sha256:869af1ea45e3dab6180557259824c2a62f1800e1286226af912431fe75c5084c
```

- [ ] **Step 2: Verify the hashes against PyPI**

Run:
```bash
for p in duplicity/3.0.7 python-gettext/5.0; do \
  curl -s "https://pypi.org/pypi/$p/json" | python3 -c \
    "import json,sys; [print(u['filename'], u['digests']['sha256']) for u in json.load(sys.stdin)['urls']]"; \
done
```
Expected: the listing includes `duplicity-3.0.7.tar.gz` = `4642…e44e`, the two `cp314…manylinux…(x86_64|aarch64)` wheels = `874b…3751` / `7ddf…cc5d`, and `python_gettext-5.0-py3-none-any.whl` = `083d…a84a`, `python-gettext-5.0.tar.gz` = `869a…084c` — i.e. every `--hash` in the file appears in the output.

- [ ] **Step 3: Commit**

```bash
git add requirements-duplicity.txt
git commit -m "feat(backup): pin duplicity 3.0.7 from PyPI (hash-locked requirements)"
```

---

### Task 2: snapcraft.yaml — core26 base + pip-wired backup-deps

**Files:**
- Modify: `snap/snapcraft.yaml:3` (`base:`) and the `parts.backup-deps` block (currently the last part in the file)

- [ ] **Step 1: Bump the base**

Change line 3:
```yaml
base: core26
```

- [ ] **Step 2: Replace the `backup-deps` part**

Replace the current block
```yaml
  backup-deps:
    plugin: nil
    stage-packages:
      - duplicity
      - gnupg
      - python3-boto3
      - python3-b2sdk
      - python3-paramiko
      - python3-requests
```
with:
```yaml
  backup-deps:
    plugin: nil
    # Tooling to pip-install duplicity at build time (and, on armhf — which has no
    # prebuilt wheel — compile its _librsync C extension against librsync-dev).
    build-packages:
      - build-essential
      - librsync-dev
      - python3-dev
      - python3-pip
      - python3-setuptools
      - python3-wheel
    # Runtime: the snap-staged interpreter (the core26 base ships no Python) plus
    # duplicity's runtime deps as archive debs — parity with the resolute duplicity
    # deb's Depends — and our supported backends (boto3/b2sdk).
    stage-packages:
      - python3
      - gnupg
      - librsync2t64
      - python3-fasteners
      - python3-httplib2
      - python3-lxml
      - python3-paramiko
      - python3-pexpect
      - python3-psutil
      - python3-requests
      - python3-setuptools
      - python3-boto3
      - python3-b2sdk
    override-build: | # shell
      craftctl default
      # duplicity itself comes from PyPI, pinned + hash-locked, so every architecture
      # ships the SAME version (the archive deb would drift per-release and the
      # duplicity-team PPA builds amd64 only). --no-deps: its PyPI metadata hard-depends
      # on EVERY backend (~250 MB) — runtime deps are the curated debs above instead.
      # --no-build-isolation: the armhf sdist build uses the deb toolchain (resolute
      # setuptools 78.1.1 satisfies duplicity's >=78.1.0). --break-system-packages:
      # pip 25 applies PEP 668 even to --target installs into the part dir.
      python3 -m pip install \
        --no-deps --no-build-isolation --require-hashes --break-system-packages \
        --target "${CRAFT_PART_INSTALL}/usr/lib/python3/dist-packages" \
        --requirement "${CRAFT_PROJECT_DIR}/requirements-duplicity.txt"
```

- [ ] **Step 3: Sanity-check the YAML with yq**

Run:
```bash
yq '.base, (.parts.backup-deps.build-packages | length), (.parts.backup-deps.stage-packages | length)' snap/snapcraft.yaml
```
Expected output:
```
core26
6
13
```

- [ ] **Step 4: Commit**

```bash
git add snap/snapcraft.yaml
git commit -m "feat!: switch base to core26; pip-install duplicity, stage python3 + deb deps"
```

---

### Task 3: backup script — staged interpreter, explicit `backup` action (TDD)

**Files:**
- Test: `tests/backup_test.sh` (3 assertion needles)
- Modify: `src/bin/backup` (new `DUP_PY`, 4 call sites, 2 comments)

- [ ] **Step 1: Update the command-string assertions (failing first)**

In `tests/backup_test.sh`, change exactly these three assertions (leave every other line as-is):

`backup` (currently `assert_contains "$b" "duplicity"               "backup: duplicity"`):
```bash
assert_contains "$b" "$SNAP/usr/bin/python3 -m duplicity backup " "backup: staged python -m, explicit action"
```

`restore` (currently `assert_contains "$r" "duplicity restore"       "restore: verb"`):
```bash
assert_contains "$r" "-m duplicity restore "       "restore: staged python -m, restore verb"
```

`list` (currently `assert_contains "$l" "collection-status"       "list: verb"`):
```bash
assert_contains "$l" "-m duplicity collection-status " "list: staged python -m, collection-status verb"
```

- [ ] **Step 2: Run the tests — expect exactly 3 failures**

Run: `bash tests/backup_test.sh`
Expected: three `FAIL:` blocks (`backup: staged python -m, explicit action`, `restore: staged python -m, restore verb`, `list: staged python -m, collection-status verb`) and the summary `39 passed, 3 failed`, exit code 1.

- [ ] **Step 3: Implement in `src/bin/backup`**

3a. Directly below `ARCHIVE_DIR="${SNAP_COMMON:-/tmp}/duplicity-cache"` add:
```bash
# core26 ships no Python in the base: duplicity is pip-installed into the snap and runs
# on the snap-staged interpreter, invoked explicitly with -m so no shebang is consulted.
DUP_PY="$SNAP/usr/bin/python3"
```

3b. In `build_backup_cmd`, replace the `printf` (keep the `--allow-source-mismatch` comment above it) with:
```bash
    printf '%q -m duplicity backup %s --allow-source-mismatch --full-if-older-than %s --archive-dir %q %q %q' \
        "$DUP_PY" "$(encryption_args)" "$(full_if_older)" "$ARCHIVE_DIR" "$1" "$(cfg target)"
```

3c. In `build_restore_cmd`, replace the `printf` (keep the `--gpg-options` comment) with:
```bash
    printf '%q -m duplicity restore %s %s --gpg-options=--no-autostart --archive-dir %q %q %q' \
        "$DUP_PY" "$timearg" "$(encryption_args)" "$ARCHIVE_DIR" "$(cfg target)" "$1"
```

3d. In `build_list_cmd`, replace the `printf` with:
```bash
    printf '%q -m duplicity collection-status %s --archive-dir %q %q' \
        "$DUP_PY" "$(encryption_args)" "$ARCHIVE_DIR" "$(cfg target)"
```

3e. In `main()`'s `backup)` branch, replace the retention line
`duplicity remove-all-but-n-full "$keep" --force --archive-dir "$ARCHIVE_DIR" "$target" || true` with:
```bash
            "$DUP_PY" -m duplicity remove-all-but-n-full "$keep" --force --archive-dir "$ARCHIVE_DIR" "$target" || true
```

3f. Replace the stale `PYTHONPATH` comment (the three lines starting `# duplicity is a Python app staged under $SNAP; core24's interpreter…`) with — the `export` line itself is unchanged:
```bash
    # duplicity is pip-installed (--no-deps) into $SNAP/usr/lib/python3/dist-packages,
    # next to its deb-staged runtime deps. The staged interpreter finds that path via
    # its own prefix; keep PYTHONPATH as belt-and-braces for any other entry point.
```

3g. In the comment above `ensure_agent`, change `(gpgconf reports bindir=/usr/bin — the core24 base, no agent there — not $SNAP)` to `(gpgconf reports bindir=/usr/bin — the base, no agent there — not $SNAP)`.

- [ ] **Step 4: Run the tests — all green**

Run: `bash tests/backup_test.sh`
Expected: `42 passed, 0 failed`, exit code 0.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning -x src/bin/backup`
Expected: no output, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add src/bin/backup tests/backup_test.sh
git commit -m "feat(backup): run duplicity via staged python3 -m; explicit backup action"
```

---

### Task 4: Documentation touch-ups

**Files:**
- Modify: `CLAUDE.md` (base mention + backup section)
- Modify: `.github/workflows/pr-build-snap.yml` (stale comment)

- [ ] **Step 1: CLAUDE.md**

Change `The build pins Node \`22.20.0\` and \`core24\` as the snap base.` to `The build pins Node \`22.20.0\` and \`core26\` as the snap base.`

In the backup bullet under "User commands", after the sentence ending `…configured via \`snap set zwave-js-ui backup.*\` (\`backup.target\`, \`backup.dir\`, \`backup.encrypt-key\`, …).`, insert:
```text
duplicity itself is pip-installed at build time from `requirements-duplicity.txt` (pinned + hash-locked, `--no-deps` — bump version AND hashes together) and runs on the snap-staged Python (`$SNAP/usr/bin/python3 -m duplicity`); its runtime deps are archive debs in the `backup-deps` part.
```

- [ ] **Step 2: workflow comment**

In `.github/workflows/pr-build-snap.yml`, change the comment
`# Matches name_version_arch.snap (snapcraft 8.x / core24) — '*' also tolerates name_arch.snap.` to
`# Matches name_version_arch.snap (snapcraft 8.14+ / core26) — '*' also tolerates name_arch.snap.`

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md .github/workflows/pr-build-snap.yml
git commit -m "docs: core26 base + pip-sourced duplicity"
```

---

### Task 5: Local build + artifact inspection (amd64)

**Files:** none (build verification)

- [ ] **Step 1: Toolchain check**

Run: `snapcraft version`
Expected: `snapcraft 8.14.5` or newer (core26 support). If older: `sudo snap refresh snapcraft`.

- [ ] **Step 2: Build**

Run from the repo root: `snapcraft`
Expected (10–25 min): ends with `Created snap package zwave-js-ui_v11.19.1_amd64.snap` (exact version per `snapcraft.yaml`). On failure, dump the part's build log it points at; the likely first-run issues are a missing stage-package name or pip hash mismatch — both fail loudly with the offending name.

- [ ] **Step 3: Inspect the artifact**

```bash
unsquashfs -l zwave-js-ui_*_amd64.snap | grep -E \
  'usr/bin/python3\.14$|usr/lib/python3\.14/os\.py$|dist-packages/duplicity/__main__\.py$|dist-packages/python_gettext' | head
unsquashfs -l zwave-js-ui_*_amd64.snap | grep -c 'squashfs-root/usr/bin/duplicity$'
ls -lh zwave-js-ui_*_amd64.snap
```
Expected: first grep prints all four matches (staged interpreter, its stdlib, pip-installed duplicity, python_gettext); second prints `0` (the deb's `/usr/bin/duplicity` is gone — invocation is `-m` only); size ≈ 110 MB (was 102 MB).

- [ ] **Step 4: Commit any build fixes**

Only if Steps 2–3 forced changes: `git add -u && git commit -m "fix(snap): core26 build fixes (<what>)"`.

---

### Task 6: On-device verification

**Files:** none (manual verification; optionally script it under `.test/` — gitignored)

- [ ] **Step 1: Install and connect**

```bash
sudo snap install --dangerous ./zwave-js-ui_*_amd64.snap
sudo snap connect zwave-js-ui:raw-usb; sudo snap connect zwave-js-ui:hardware-observe
```

- [ ] **Step 2: Interpreter + duplicity sanity**

```bash
sudo snap run --shell zwave-js-ui.backup <<'EOF'
"$SNAP/usr/bin/python3" --version
"$SNAP/usr/bin/python3" -m duplicity --version
EOF
```
Expected: `Python 3.14.x` and `duplicity 3.0.7`. An `ImportError` here means a missing runtime deb — add it to `stage-packages` (Task 2 list), rebuild, note it in the commit.

- [ ] **Step 3: Unencrypted round-trip (isolates the Python wiring from gpg)**

```bash
sudo snap set zwave-js-ui backup.encrypt=false backup.target=file:///var/snap/zwave-js-ui/common/dup-test
sudo mkdir -p /var/snap/zwave-js-ui/current/backups
echo probe | sudo tee /var/snap/zwave-js-ui/current/backups/probe.txt
sudo zwave-js-ui.backup            # expect duplicity stats output, exit 0
sudo zwave-js-ui.backup list       # expect a collection-status with 1 full set
sudo rm /var/snap/zwave-js-ui/current/backups/probe.txt
sudo zwave-js-ui.backup restore    # expect probe.txt restored with content "probe"
cat /var/snap/zwave-js-ui/current/backups/probe.txt
```
Contingency: if `restore` aborts with a "directory already exists" error, that is duplicity 3.x requiring `--force` where 2.x didn't — add `--force` to `build_restore_cmd`'s printf (after `restore`), assert it in the restore test, rerun Task 3 steps 4–6.

- [ ] **Step 4: Encrypted path**

```bash
sudo zwave-js-ui.backup create-key "Test Backup" test@example.invalid
sudo zwave-js-ui.backup            # encrypted backup, exit 0
sudo zwave-js-ui.backup restore    # prompts for the passphrase, restores
```
Known limitation (pre-existing, not core26): on kernels with AF_UNIX AppArmor mediation (e.g. 6.17), `create-key` degrades with the documented guidance message — then verify the message and run the encrypted *backup* (not restore) with an imported public key instead: `zwave-js-ui.backup pick-key <fpr> | sudo zwave-js-ui.backup import-key && sudo zwave-js-ui.backup`.

- [ ] **Step 5: Main app smoke (base switch affects every app)**

```bash
sudo zwave-js-ui.help                 # prints usage + config
sudo zwave-js-ui.exec                 # boots in foreground; Ctrl+C after "Listening on…"
```

- [ ] **Step 6: Cleanup + record**

```bash
sudo snap remove zwave-js-ui   # dev box; reinstall from the store afterwards if it was in use
```
Record results (incl. the restore `--force` outcome) in the PR body. Commit any fixes made along the way.

---

### Task 7: PR, CI (arm builds), finish

- [ ] **Step 1: Stacking check**

Run: `gh pr list --head feat/backup-key-management --state all --json number,state,mergedAt`
If merged → `git rebase origin/main` (resolve nothing or trivial). If open → the PR below goes up as **draft** with a "stacked on #<n>" note.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/core26-pip-duplicity
gh pr create --base main \
  --title "feat!: core24 → core26 — duplicity via pinned pip on staged Python" \
  --body "$(cat <<'EOF'
## What
- `base: core26` (Ubuntu 26.04). core26 ships no Python, so:
- duplicity 3.0.7 is pip-installed at build time — pinned + hash-locked in `requirements-duplicity.txt`, `--no-deps` (its PyPI metadata hard-depends on every backend); runtime deps are archive debs mirroring the resolute deb's `Depends` (`librsync2` → `librsync2t64` rename included).
- The backup script runs `"$SNAP/usr/bin/python3" -m duplicity <action>` (no shebangs, no base interpreter) and uses the explicit `backup` action (3.x-proof).
- Same duplicity version on amd64/arm64/armhf (archive deb would drift; duplicity-team PPA is amd64-only).

## Test plan
- [x] `bash tests/backup_test.sh` — 42 passed
- [x] `shellcheck -S warning -x src/bin/backup`
- [x] Local amd64 build; artifact contains staged python3.14 + pip duplicity, no deb duplicity
- [x] On-device: `-m duplicity --version`, unencrypted + encrypted backup/list/restore round-trip, `exec` boots
- [ ] Per-PR channel install on arm device (from CI comment)
EOF
)"
```

- [ ] **Step 3: Watch CI — this is the first arm validation**

Run: `gh pr checks --watch`
Expected: Launchpad remote-build succeeds for amd64/arm64/armhf and the sticky comment shows the `v11.19/edge/<PR#>` channel. The armhf build exercises the sdist compile path (`_librsync` against `librsync-dev`); if it fails there, the log names the missing header/tool — extend `build-packages` accordingly.

- [ ] **Step 4: arm on-device check**

On an arm device: `sudo snap install zwave-js-ui --channel=v11.19/edge/<PR#>` (or `refresh`), then repeat Task 6 Steps 2–3.
Expected: `duplicity 3.0.7` on arm too — confirming version uniformity, the point of the pip route.

- [ ] **Step 5: Finish**

Use superpowers:finishing-a-development-branch (merge choice is the user's; release-on-merge promotes the per-PR revisions).

---

## Out of scope (explicitly)

- No change to backup UX, config keys, archive format, or the asymmetric-GPG model — duplicity stays duplicity.
- No CI workflow changes (snapcraft stable already builds core26; revisit only if LP builds surprise us).
- No chisel-slice size optimization of the staged Python (possible later; ~110 MB total is acceptable).
- The duplicity-team PPA is **not** added (amd64-only → would fragment versions; pip supersedes it).
