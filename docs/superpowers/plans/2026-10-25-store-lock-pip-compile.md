# Store-client lock via Renovate's pip-compile manager — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Renovate's `pip-compile` manager owns `.github/scripts/requirements-store.txt`, so uv (not hashin) writes every lock change, and a helper test keeps the lock header in the form Renovate can re-run.

**Architecture:** The lock header becomes the D3 command (long options, `--opt=value`, `--exclude-newer=P7D`). A bash guard test (`requirements-store.test.sh`) checks that header against Renovate's parser rules and against the recipe in `requirements-store.in`. `renovate.json` hands the file to `pip-compile`, disables `pip_requirements` for it, ages direct updates 7 days and automerges minor/patch plus the weekly lock-file maintenance.

**Tech Stack:** bash + awk + shellcheck 0.9 (the `.github/scripts/*.test.sh` style of `retry.test.sh`), uv ≥ 0.11.16 (laptop: 0.12.9 at `~/.local/bin/uv`), Renovate 44.181.5 for local checks (cached at `/home/joachimmgg/.npm/_npx/59c0475bfd22776c/node_modules/renovate`), Node for the rule check.

**Spec:** `docs/superpowers/specs/2026-10-25-store-lock-pip-compile-design.md` (decisions D1–D9; read D3, D5 and D7 before Task 1).

## Global Constraints

- The D3 command, verbatim, everywhere it appears (lock header line 2 after `#    `, the `.in` recipe, test fixtures):
  `uv pip compile --universal --python-version=3.12 --exclude-newer=P7D --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in`
- This PR changes **only header line 2** of `requirements-store.txt`; every pin and hash stays. The first weekly refresh after merge is the acceptance test (D9), so do not commit a refreshed lock.
- No change to the duplicity, gum, Node or zwave-js-ui rules, `requirements-duplicity.txt` or any workflow logic.
- Renovate config passes `renovate-config-validator --strict` (44.181.5).
- `shellcheck .github/scripts/*.sh` is clean (the new test matches that glob).
- Heavy runs (validator, Renovate dry run, venv install + tests, uv resolves) go under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`, one at a time. Stop processes by PID only. Never print tokens.
- Run everything from the worktree `/home/joachimmgg/Development/giaever-online-iot/zwave-js-ui/.claude/worktrees/ci+store-pip-compile`. Scratch files go in `/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-zwave-js-ui/b6aac98f-29f9-4751-95b6-604d95e6ff74/scratchpad` (`$S` below). `.venv-store/` must never be committed: `echo .venv-store/ >> "$(git rev-parse --git-common-dir)/info/exclude"`.
- Commit style: `test(ci): …`, `ci(renovate): …`; one commit per task.

## Review Focus

1. **The weekly refresh must leave the header byte-identical.** Renovate deletes the lock and re-runs the header's argv; if uv wrote it back differently, the guard test would fail every refresh and nothing would merge. Task 3, step 2.
2. **A craft-store bump in the `.in` must leave the header unchanged.** Renovate re-runs the same argv with the lock kept. Task 3, step 3.
3. **A human re-wrapping the `.in` recipe** (different line breaks, extra spaces) must still pass. Task 1 case `same recipe wrapped elsewhere, extra spaces`.
4. **Lock-file maintenance must not inherit the 7-day age rule.** It has no release timestamp, so Renovate would mark it pending forever (spec D5, corrected). Task 2 rule check `refresh`.
5. **Disabling `pip_requirements` for the store lock must not touch the duplicity rule.** Task 2 rule check `duplicity patch`.

---

### Task 1: Guard test, then the lock header and `.in` recipe it demands

**Files:**
- Create: `.github/scripts/requirements-store.test.sh`
- Modify: `.github/scripts/requirements-store.txt` (line 2 only, written by uv)
- Modify: `.github/scripts/requirements-store.in` (recipe comment)
- Modify: `.github/workflows/helper-tests.yml:3-4` (header comment only)

**Interfaces:**
- Produces: `header_problem LOCK IN` (bash function inside the test). It prints the first problem as one line and returns 1, or prints nothing and returns 0. Task 3 runs the whole test file.

- [ ] **Step 1: Write the test**

Same skeleton as `retry.test.sh`: shebang, a header comment, `set -uo pipefail`, `HERE`, `fail=0`, the same `check desc expected actual` helper, and the same closing lines (`All requirements-store tests passed.` / `Some requirements-store tests FAILED.`, `exit "$fail"`). Header comment: Renovate's pip-compile manager re-runs the command it reads from the lock's header, and when it cannot parse it, it stops updating the lock and only logs why.

`header_problem LOCK IN` applies these checks in this order and reports the first that fails, with these exact messages:

1. Line 1 of LOCK starts with `#` and line 2 starts with `#    uv pip compile ` (exactly four spaces, as in Renovate's `constraintLineRegex`). Otherwise: `line 2 of the lock is not uv's '#    uv pip compile ...' header`.
2. For each whitespace-separated token after `uv pip compile`:
   - `-x...` (a single dash): `<tok> is a short option; Renovate parses only long ones`.
   - `--name=value`: `--name` must be in WITH_ARG or FLAGS.
   - bare `--name` in WITH_ARG: `<name> needs its value as <name>=VALUE`.
   - bare `--name` in neither list: `<name> is not an option Renovate's pip-compile manager accepts for uv`. With `=`, use the same message, naming only the part before `=`.
   - anything else is a positional (source file) and is fine.
   The lists come from Renovate 44.181.5 `lib/modules/manager/pip-compile/common.ts` (uv). Put a comment saying so above them:
   - WITH_ARG: `--constraints --constraint --python-version --no-emit-package --prerelease --format --resolution --fork-strategy --exclude-newer --exclude-newer-package --group --override --overrides --output-file --extra --extra-index-url`
   - FLAGS: `--no-strip-extras --universal --generate-hashes --emit-index-url --index-url --all-extras`
3. A token equal to `--exclude-newer=P7D`. Otherwise: `missing --exclude-newer=P7D`.
4. The recipe in IN is the comment lines after the line `# Lock into requirements-store.txt with:`, continuing while a line ends in `\`. Strip the leading `#` and trailing `\`, join with spaces and squeeze whitespace (awk). If the recipe is empty: `requirements-store.in has no recipe under '# Lock into requirements-store.txt with:'`. If it differs from the squeezed header command: `lock header differs from the recipe in requirements-store.in`.

Cases. Write them exactly; the fixture helpers are part of the test:

```bash
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
D3='uv pip compile --universal --python-version=3.12 --exclude-newer=P7D --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in'
OLD='uv pip compile --universal --python-version 3.12 --generate-hashes .github/scripts/requirements-store.in -o .github/scripts/requirements-store.txt'
# pair NAME HEADER_COMMAND [RECIPE_LINE...]: $work/NAME.txt is a uv lock with that
# header and one entry; $work/NAME.in holds the recipe comment and one pin.
pair() {
  local name="$1" cmd="$2"; shift 2
  printf '# This file was autogenerated by uv via the following command:\n#    %s\nhttpx==0.28.1 \\\n    --hash=sha256:%064d\n' "$cmd" 0 >"$work/$name.txt"
  { echo '# Lock into requirements-store.txt with:'; [ $# -gt 0 ] && printf '%s\n' "$@"; echo 'craft-store==3.4.0'; } >"$work/$name.in"
}
run() { local out; out="$(header_problem "$work/$1.txt" "$work/$1.in")"; echo "$?:$out"; }

out="$(header_problem "$HERE/requirements-store.txt" "$HERE/requirements-store.in")"
check "repo lock: header in Renovate's form, same as the .in recipe" "0:" "$?:$out"

pair ok "$D3" \
  '#   uv pip compile --universal --python-version=3.12 --exclude-newer=P7D \' \
  '#     --generate-hashes --output-file=.github/scripts/requirements-store.txt \' \
  '#     .github/scripts/requirements-store.in'
check "D3 command, recipe wrapped over three lines" "0:" "$(run ok)"

pair rewrapped "$D3" \
  '#   uv pip compile  --universal \' \
  '#       --python-version=3.12 --exclude-newer=P7D --generate-hashes \' \
  '#  --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in'
check "same recipe wrapped elsewhere, extra spaces" "0:" "$(run rewrapped)"

pair old "$OLD" "#   $OLD"
check "main's header before this change: value split from option" \
  "1:--python-version needs its value as --python-version=VALUE" "$(run old)"

SHORT="${D3/--output-file=/-o }"; pair short "$SHORT" "#   $SHORT"
check "short option" "1:-o is a short option; Renovate parses only long ones" "$(run short)"

pair unknown "$D3 --no-annotate" "#   $D3 --no-annotate"
check "option Renovate does not accept" \
  "1:--no-annotate is not an option Renovate's pip-compile manager accepts for uv" "$(run unknown)"

NOCUT="${D3/ --exclude-newer=P7D/}"; pair nocut "$NOCUT" "#   $NOCUT"
check "no --exclude-newer" "1:missing --exclude-newer=P7D" "$(run nocut)"

P1D="${D3/P7D/P1D}"; pair p1d "$P1D" "#   $P1D"
check "a different cutoff" "1:missing --exclude-newer=P7D" "$(run p1d)"

pair drift "$D3" "#   ${D3/3.12/3.13}"
check "header differs from the .in recipe" \
  "1:lock header differs from the recipe in requirements-store.in" "$(run drift)"

pair norecipe "$D3"
check "no recipe in the .in" \
  "1:requirements-store.in has no recipe under '# Lock into requirements-store.txt with:'" "$(run norecipe)"

printf 'httpx==0.28.1\n' >"$work/bare.txt"; cp "$work/ok.in" "$work/bare.in"
check "lock without uv's header" \
  "1:line 2 of the lock is not uv's '#    uv pip compile ...' header" "$(run bare)"
```

- [ ] **Step 2: Run it and see the right case fail**

Run: `bash .github/scripts/requirements-store.test.sh; echo "exit=$?"` and `shellcheck .github/scripts/*.sh`
Expected: only `repo lock: …` FAILs, with actual `1:--python-version needs its value as --python-version=VALUE`. Every fixture case is `ok`, `exit=1`, and shellcheck prints nothing. A fixture failing here is a bug in `header_problem`; fix it before going on.

- [ ] **Step 3: Rewrite the `.in` recipe comment and regenerate the header**

Replace the comment's last three lines (`# Lock into …` and the two recipe lines) in `requirements-store.in` with exactly this. The first four comment lines and the three pins stay:

```
# Renovate's pip-compile manager re-runs the command in the lock's header, so it
# must stay in the form Renovate parses: long options, --opt=value, no -o
# (requirements-store.test.sh checks it). --exclude-newer=P7D makes uv skip
# anything uploaded in the last 7 days, for Renovate and manual runs alike.
# Lock into requirements-store.txt with:
#   uv pip compile --universal --python-version=3.12 --exclude-newer=P7D \
#     --generate-hashes --output-file=.github/scripts/requirements-store.txt \
#     .github/scripts/requirements-store.in
```

Then, with the lock kept so uv keeps every pin:

```bash
flock -w 3600 /tmp/claude-1000/chim-suites.lock uv pip compile --universal --python-version=3.12 --exclude-newer=P7D --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in
git diff --stat -- .github/scripts/requirements-store.txt
```
Expected: `1 file changed, 1 insertion(+), 1 deletion(-)`, and `git diff` shows only line 2.

In `helper-tests.yml`, extend the header comment's list of what it guards (lines 3-4) with `the store lock's header, which Renovate re-runs`. Change nothing else in the workflow.

- [ ] **Step 4: Run it and see it pass**

Run: `bash .github/scripts/requirements-store.test.sh; echo "exit=$?"; shellcheck .github/scripts/*.sh; echo "sc=$?"`
Expected: all `ok`, `All requirements-store tests passed.`, `exit=0`, `sc=0`.

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/requirements-store.test.sh .github/scripts/requirements-store.in .github/scripts/requirements-store.txt .github/workflows/helper-tests.yml
git commit -m "test(ci): guard the store lock header Renovate's pip-compile manager re-runs"
```

- [ ] **Step 6: Mutation-test, then restore**

Apply each mutation alone, run the test, record the FAILing case(s), then restore with `git checkout -- <file>`. Every mutation must turn at least the named case red:

| Mutation | Must FAIL |
|---|---|
| `git show origin/main:.github/scripts/requirements-store.txt > .github/scripts/requirements-store.txt` | `repo lock: …` |
| `git show origin/main:.github/scripts/requirements-store.in > .github/scripts/requirements-store.in` | `repo lock: …` |
| delete the `--exclude-newer=P7D` check in `header_problem` | `no --exclude-newer`, `a different cutoff` |
| delete the short-option branch | `short option` |
| delete the not-accepted-option branch | `option Renovate does not accept` |
| join recipe lines without squeezing whitespace | `same recipe wrapped elsewhere, extra spaces` |

Finish with `git status --porcelain` empty. Report the table with the actual FAIL lines.

---

### Task 2: Renovate config hands the lock to pip-compile; docs follow

**Files:**
- Modify: `renovate.json` (top-level keys; replace the "Store client lock" packageRule)
- Modify: `CLAUDE.md:63` (the Renovate sentences on the store lock)
- Test (scratch, not committed): `$S/rulecheck/assert.mjs`

**Interfaces:**
- Consumes: Task 1's header (the dry run must parse it).

- [ ] **Step 1: Write the rule check**

`$S/rulecheck/assert.mjs` runs Renovate's own rule engine over the repo's `packageRules`:

```js
// usage: node assert.mjs <renovate.json>  (Renovate 44.181.5 from the npx cache)
import { readFileSync } from 'node:fs';
import { applyPackageRules } from '/home/joachimmgg/.npm/_npx/59c0475bfd22776c/node_modules/renovate/dist/util/package-rules/index.js';
const { packageRules } = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const lock = '.github/scripts/requirements-store.txt';
const cases = [
  ['refresh', { manager: 'pip-compile', packageFile: lock, updateType: 'lockFileMaintenance', isLockFileMaintenance: true },
    { automerge: true, minimumReleaseAge: undefined, labels: ['dependencies'] }],
  ['craft-store minor', { manager: 'pip-compile', packageFile: lock, depName: 'craft-store', packageName: 'craft-store', datasource: 'pypi', updateType: 'minor' },
    { automerge: true, minimumReleaseAge: '7 days', labels: ['dependencies'] }],
  ['craft-store major', { manager: 'pip-compile', packageFile: lock, depName: 'craft-store', packageName: 'craft-store', datasource: 'pypi', updateType: 'major' },
    { automerge: undefined, minimumReleaseAge: '7 days' }],
  ['pip_requirements on the store lock', { manager: 'pip_requirements', packageFile: lock, depName: 'pydantic', packageName: 'pydantic', datasource: 'pypi', updateType: 'minor' },
    { enabled: false }],
  ['duplicity patch', { manager: 'pip_requirements', packageFile: 'requirements-duplicity.txt', depName: 'duplicity', packageName: 'duplicity', datasource: 'pypi', updateType: 'patch' },
    { enabled: undefined, automerge: true, minimumReleaseAge: '7 days' }],
];
let fail = 0;
for (const [name, input, want] of cases) {
  const got = await applyPackageRules({ ...input, packageRules });
  for (const [k, v] of Object.entries(want)) {
    const ok = JSON.stringify(got[k]) === JSON.stringify(v);
    if (!ok) fail = 1;
    console.log(`${ok ? 'ok  ' : 'FAIL'} - ${name}: ${k} = ${JSON.stringify(got[k])}${ok ? '' : ` (want ${JSON.stringify(v)})`}`);
  }
}
process.exit(fail);
```

- [ ] **Step 2: Run it on main's config and see it fail**

Run: `node $S/rulecheck/assert.mjs renovate.json; echo "exit=$?"`
Expected: `exit=1`. FAILs on `refresh: automerge`, `refresh: labels`, the `craft-store` cases and `pip_requirements on the store lock: enabled`. `duplicity patch` is all `ok`. Ignore the logger-not-initialised notice.

- [ ] **Step 3: Edit `renovate.json`**

Add after `extends`:

```json
  "constraints": {
    "uv": ">=0.11.16"
  },
  "pip-compile": {
    "managerFilePatterns": [
      "/^\\.github/scripts/requirements-store\\.txt$/"
    ]
  },
```

Replace the packageRule whose description starts `Store client lock:` with these four, in this order and in the file's existing one-item-per-line style:
1. `matchManagers: ["pip_requirements"]`, `matchFileNames: [".github/scripts/requirements-store.txt"]`, `enabled: false`. Description: the pip-compile manager owns this lock; `pip_requirements`' hash refresher (hashin) mangles entries uv spells differently from PyPI (pydantic-core, jaraco-*), #251.
2. `matchManagers: ["pip-compile"]`, `labels: ["dependencies"]`. Description: the store client lock is CI-only but runs next to the live store credentials, and uv re-runs the header command for every change.
3. `matchManagers: ["pip-compile"]`, `matchUpdateTypes: ["major", "minor", "patch"]`, `minimumReleaseAge: "7 days"`. Description: a craft-store release (the `.in` pin) is taken once it is 7 days old, the header's `--exclude-newer=P7D` cutoff. The rule is not on lockFileMaintenance: that update has no release timestamp, so an age rule would leave the weekly refresh pending forever; uv's cutoff ages it instead.
4. `matchManagers: ["pip-compile"]`, `matchUpdateTypes: ["minor", "patch", "lockFileMaintenance"]`, `automerge: true`. Description: craft-store minor/patch and the weekly lock refresh automerge once the required `test` check passes (`--require-hashes` install + unit tests). The refresh re-resolves every transitive package, majors included (Joachim, 2026-10-25). craft-store majors stay manual.

- [ ] **Step 4: Run the rule check, the validator and the dry run, and see them pass**

```bash
node $S/rulecheck/assert.mjs renovate.json; echo "rules exit=$?"
flock -w 3600 /tmp/claude-1000/chim-suites.lock npx --yes --package renovate@44.181.5 -- renovate-config-validator --strict > $S/validate-final.log 2>&1; echo "validator exit=$?"; grep -E ' INFO: | ERROR: | WARN: ' $S/validate-final.log | grep -v re2 | tail -4
flock -w 3600 /tmp/claude-1000/chim-suites.lock env LOG_LEVEL=debug LOG_FORMAT=json RENOVATE_PLATFORM=local RENOVATE_ENABLED_MANAGERS='["pip-compile","pip_requirements"]' timeout 900 /home/joachimmgg/.npm/_npx/59c0475bfd22776c/node_modules/.bin/renovate > $S/dryrun-final.log 2>&1; echo "dryrun exit=$?"
```
Expected: `rules exit=0`, all lines `ok`. `validator exit=0`, with `Config validated successfully` and no WARN or ERROR besides re2. `dryrun exit=0`. Then confirm from `$S/dryrun-final.log` (JSON lines; parse with `python3 -I`):
- `pip-compile: extracted command from header` has an `argv` equal to the D3 command split on spaces;
- `Dependency extraction complete` shows `pip-compile` `fileCount: 1, depCount: 36`;
- in `packageFiles with updates`, every `pip_requirements` dep of `.github/scripts/requirements-store.txt` has `skipReason: "disabled"`, while `requirements-duplicity.txt` deps are not disabled;
- `renovate/pip-compile-refresh` appears in the log;
- no log line has `"level": 50` (error).

- [ ] **Step 5: Update `CLAUDE.md:63`**

Edit only these three passages of that paragraph:
- `…opens bump PRs for \`requirements-duplicity.txt\` (…include it) and \`.github/scripts/requirements-store.txt\`, and refreshes their \`--hash\` lines itself.` becomes `…opens bump PRs for \`requirements-duplicity.txt\` (…include it) and refreshes its \`--hash\` lines itself.`
- Replace the sentence starting `The store client lock (` with:
  `The store client lock (\`.github/scripts/requirements-store.txt\`, used by \`snap-create-track.py\` and \`store-gateway-login.py\` next to the live store credentials) belongs to Renovate's \`pip-compile\` manager instead (\`pip_requirements\` is disabled for it: its hash refresher mangled names uv spells differently from PyPI, #251). Renovate re-runs the \`uv pip compile\` command in the lock's header, so uv writes every name, hash and marker. A craft-store release (the \`.in\` pin) is taken once it is 7 days old; minor/patch automerge, majors stay manual. Every other package moves only through the weekly lock-file maintenance PR (before 04:00 UTC on Mondays), which re-resolves the whole lock and automerges, transitive majors included, once the required \`test\` check passes (\`helper-tests\`: \`--require-hashes\` install + unit tests). The header's \`--exclude-newer=P7D\` makes uv ignore anything uploaded in the last 7 days, in Renovate's runs and manual ones alike, so a fix younger than that needs a deliberate header change. Keep the header in the form Renovate parses (long options, \`--opt=value\`, no \`-o\`): \`requirements-store.test.sh\` fails otherwise, because Renovate would stop updating the lock and only log why.`
- Replace the last sentence (`To bump the store client on purpose, … before regenerating.`) with:
  `To bump the store client on purpose, edit \`requirements-store.in\` and re-run the command in the lock's header (the same recipe as in the \`.in\`).`

Run: `git diff --stat` 
Expected: `CLAUDE.md` and `renovate.json` only.

- [ ] **Step 6: Commit**

```bash
git add renovate.json CLAUDE.md
git commit -m "ci(renovate): hand the store client lock to the pip-compile manager"
```

---

### Task 3: Pre-merge rehearsal (verification only, no commit)

**Files:** none changed at the end. Every step restores with `git checkout --`.

**Interfaces:**
- Consumes: Task 1's test file and header; Task 2's config.

- [ ] **Step 1: Run the full `helper-tests` job locally**

```bash
flock -w 3600 /tmp/claude-1000/chim-suites.lock bash -c '
  shellcheck .github/scripts/*.sh &&
  for t in .github/scripts/*.test.sh; do echo "== $t"; bash "$t" || exit 1; done &&
  python3 -m venv --clear .venv-store &&
  .venv-store/bin/pip install -q --require-hashes -r .github/scripts/requirements-store.txt &&
  for t in .github/scripts/*.test.py; do echo "== $t"; .venv-store/bin/python "$t" || exit 1; done'; echo "exit=$?"
```
Expected: `exit=0`, every `.test.sh` passes, and the two `.test.py` files report `OK` (63 and 6 tests).

- [ ] **Step 2: Rehearse the weekly refresh (Review Focus 1)**

```bash
rm .github/scripts/requirements-store.txt
flock -w 3600 /tmp/claude-1000/chim-suites.lock uv pip compile --universal --python-version=3.12 --exclude-newer=P7D --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in
git diff -U0 -- .github/scripts/requirements-store.txt | grep -E '^[-+]#' ; echo "header lines changed: $(git diff -U0 -- .github/scripts/requirements-store.txt | grep -cE '^[-+]#')"
git diff -- .github/scripts/requirements-store.txt | grep -E '^\+[a-z]' 
bash .github/scripts/requirements-store.test.sh | tail -1
flock -w 3600 /tmp/claude-1000/chim-suites.lock bash -c '.venv-store/bin/pip install -q --require-hashes -r .github/scripts/requirements-store.txt && for t in .github/scripts/*.test.py; do .venv-store/bin/python "$t" || exit 1; done'; echo "exit=$?"
git checkout -- .github/scripts/requirements-store.txt
```
Expected: `header lines changed: 0`. The `+` package lines are newer pins with no `a`, `b` or `rc` pre-release tags and no duplicate names (on 2026-10-25 these were more-itertools, pycparser, pydantic and pydantic-core). The guard test says `All requirements-store tests passed.` and `exit=0`. Report the moved packages with their versions.

- [ ] **Step 3: Rehearse a craft-store bump (Review Focus 2)**

```bash
sed -i 's/^craft-store==3.4.0$/craft-store==3.3.0/' .github/scripts/requirements-store.in
flock -w 3600 /tmp/claude-1000/chim-suites.lock uv pip compile --universal --python-version=3.12 --exclude-newer=P7D --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in
echo "header lines changed: $(git diff -U0 -- .github/scripts/requirements-store.txt | grep -cE '^[-+]#')"; grep -n '^craft-store==' .github/scripts/requirements-store.txt
bash .github/scripts/requirements-store.test.sh | tail -1
git checkout -- .github/scripts/requirements-store.in .github/scripts/requirements-store.txt
```
Expected: `header lines changed: 0`, `craft-store==3.3.0` in the lock, and `All requirements-store tests passed.`.

- [ ] **Step 4: Leave the tree clean**

Run: `git status --porcelain; git log --oneline origin/main..HEAD`
Expected: no output from status. The log shows the spec commits plus the two task commits.

---

## After merge (orchestrator, not a task)

The spec's D9 acceptance runs after Joachim merges. Renovate closes #251 and #252. The
Dependency Dashboard (#16) shows the pip-compile refresh awaiting schedule. The first
refresh PR changes only package entries (header unchanged, no duplicates, no
pre-releases), passes `test` and merges itself. On an artifact error nothing merges, and
the result goes back to Joachim.
