# Store-client lock updated by Renovate's pip-compile manager — design

Date: 2026-10-25. Status: approved by Joachim 2026-10-25. Size: bounded (Renovate config, one
lock-header rewrite, one helper test, docs). Follows #247 (store-client automerge)
and fixes the failure seen on its first group PR, #251.

## Intent

`.github/scripts/requirements-store.txt` is a hash-locked `uv pip compile` output
(36 packages, 33 of them transitive) for the CI store client. Since #247, Renovate
groups its minor/patch bumps into one "store client" PR that automerges once the
required `test` check passes and each release is 7 days old.

The first such PR, #251, failed `test` with a hash mismatch. Renovate's
`pip_requirements` manager refreshes hashes with **hashin**, which looks a package
up by PyPI's spelling and only treats a hyphen in that spelling as `[-_]`. Four lock
entries are spelled differently by uv: `pydantic-core` (PyPI `pydantic_core`) and
`jaraco-classes|context|functools` (PyPI `jaraco.*`). For those, hashin leaves the
bumped line with its old hashes and appends a second entry. The gate held (auto-merge
was armed, GitHub refused to merge), but every pydantic release would repeat it and
block the whole group.

Joachim chose (2026-10-25, option 2) to let Renovate re-run uv itself, with transitive
packages coming through a weekly lock refresh.

## What was verified (2026-10-25, laptop, Renovate 44.181.5 `--platform=local` dry runs, uv 0.12.9)

| Check | Result |
|---|---|
| hashin 1.0.5 replay of #251 on main's lock | Reproduces #251's file (duplicate `pydantic_core==2.50.1` at the end, stale hashes on line 440); `pip install --require-hashes` fails the same way. |
| Renovate's header parser (`lib/modules/manager/pip-compile/common.ts`) on today's header | Would throw: `--python-version 3.12` → "must have equal sign"; `-o` → "not supported (yet)". `--exclude-newer` is on its uv allow-list. |
| D3 command on main's lock (lock kept) | Only header line 2 changes; uv echoes the arguments verbatim (including `--exclude-newer=P7D`) and keeps every pin. |
| D3 command with the lock deleted first (what Renovate's lock-file maintenance does) | more-itertools 11.2.1, pycparser 3.11, pydantic 2.14.1, pydantic-core 2.50.1 move; certifi stays (its 2026.10.23 is under 7 days old); pyrfc3339 stays 1.1 (macaroonbakery caps it); 36 entries, env markers kept, **0 pre-release pins**. `pip install --require-hashes` OK; store tests 63 + 6 pass. |
| Dry run of the D1–D7 config | Header parsed (argv includes `--exclude-newer=P7D`); 36 pip-compile deps, no per-package updates; all 36 `pip_requirements` deps for the lock `skip=disabled`; a `renovate/pip-compile-refresh` branch planned (lock-file maintenance). |
| Earlier alternative dry run: indirect deps enabled + `rangeStrategy: update-lockfile` | Works, but rejected — see "Alternative rejected" below. |
| macaroonbakery 1.3.4 (latest) `requires_dist` | `pyRFC3339 (<2.0,>=1.0)` — #252 can never resolve. |
| uv changelog | Relative `exclude-newer` durations since 0.9.17; documented and tested for `uv pip` in 0.11.16. |
| Renovate's rule engine (`applyPackageRules`, 44.181.5) on the refresh update (2026-10-26) | Manager-wide age rule: the refresh gets `minimumReleaseAge: 7 days`, and the branch worker (`update/branch/index.js`) sets an update without a `releaseTimestamp` to stability `yellow` under the default `timestamp-required`. Age rule scoped to major/minor/patch: refresh gets `automerge: true` and no age; a craft-store minor gets both; a major gets the age only. |
| Renovate's `updateArtifacts` / `constructPipCompileCmd` | Direct and lock-file-maintenance updates run the header's argv verbatim (maintenance deletes the lock first); `--upgrade-package=` is appended only for indirect lock updates, which stay disabled (D4). So the header survives every update this design produces. |

Not verified locally: the hosted Mend app running uv (artifacts are not generated in a
local dry run), and an out-of-range bump of the pinned `craft-store==3.4.0` (none is
available today). Both are covered by the acceptance check after merge (D9).

## Goals

- Every store-client lock change is produced by uv, so names, hashes and environment
  markers stay consistent.
- Every package in the lock — direct, transitive, moved along by another package, or
  newly pulled in — is at least 7 days old when it lands.
- Minor/patch changes and the weekly refresh merge themselves after the required
  `test` check; craft-store majors stay manual.
- A manual regeneration with the wrong command form is caught by a test, not by a
  silently stalled Renovate.

## Non-goals / anti-goals

- No change to duplicity, gum, Node or zwave-js-ui rules. `requirements-duplicity.txt`
  is a hand-hashed `--no-deps` pin list, not a compiled lock, and stays on
  `pip_requirements`.
- No upstream hashin fix, no `AUTOMERGE_TOKEN`, no pyrfc3339 v2 adoption.
- Anti-goals: a broken lock merging; a pre-release landing on `main` unasked; one
  unresolvable package blocking every other update (the #251 shape).

## Decisions

**D1. Renovate's `pip-compile` manager owns `.github/scripts/requirements-store.txt`.**
`"pip-compile": {"managerFilePatterns": ["/^\\.github/scripts/requirements-store\\.txt$/"]}`.
The manager matches the output lock and reads its header to find the `.in`. Reason:
uv regenerates names, hashes and markers itself, so hashin is out of the picture.

**D2. `pip_requirements` is disabled for that one file by a packageRule**
(`matchManagers: ["pip_requirements"]`, `matchFileNames: [".github/scripts/requirements-store.txt"]`,
`enabled: false`). Reason: Renovate's docs say to stop the source manager running
twice; `pip_requirements` must keep handling `requirements-duplicity.txt`, and
`ignorePaths` would hide the lock from `pip-compile` too. Spike: all 36 entries
`skip=disabled`. Effect: Renovate closes #251 and #252, whose updates no longer exist.

**D3. The lock header and the `.in` recipe become:**
`uv pip compile --universal --python-version=3.12 --exclude-newer=P7D --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in`.
Reasons: Renovate's parser needs `=` between an option and its value and only knows
long options. `--exclude-newer=P7D` makes uv ignore every distribution uploaded in the
last 7 days at resolution time, so the 7-day buffer holds for every package, including
ones uv moves along or pulls in that Renovate never listed. It applies to manual
regenerations too. Regenerating with this command changes header line 2 only.

**D4. Transitive packages come only through Renovate's lock-file maintenance (the
weekly "Refresh pip-compile outputs" PR), which automerges after the required checks.**
Indirect deps stay disabled (the manager's default), so Renovate never forces a single
transitive version with `--upgrade-package`. Renovate's default for this manager is
enabled, weekly ("before 4am on monday", UTC), and a PR opens only when the lock would
change. Reasons:
- Nothing is forced, so uv never needs a pre-release; its default only takes one when
  no stable version fits. A forced update can pull one in: pydantic-core 2.47–2.49
  shipped as ordinary minors on the same days as pydantic 2.14.0a1/b1/b2 (PyPI upload
  dates; 2.14.0b2 pins `pydantic-core==2.49.0`), and forcing 2.49.0 wrote
  `pydantic==2.14.0b2` in the builder check's replay.
- uv resolves a consistent set, so a capped package (pyrfc3339 under macaroonbakery)
  simply stays put instead of blocking the PR.
- Spike: the refresh moved exactly the four packages the old group PR wanted.
- The refresh automerges even when it moves a transitive package to a new major
  (Joachim, 2026-10-25, option 1 of 2). That needs every package depending on it to
  allow the major, the release to be 7 days old and `test` to pass; the alternative,
  merging every weekly refresh by hand, was declined. Before this change every major
  in the lock was manual.

**D5. Direct updates (the `craft-store==` pin in the `.in`) wait 7 days, for every
update type; minor/patch automerge, majors stay manual.** Rules, all
`matchManagers: ["pip-compile"]`: label `dependencies`; `minimumReleaseAge: "7 days"`
for `matchUpdateTypes: ["major", "minor", "patch"]`; `automerge: true` for `minor`,
`patch` and `lockFileMaintenance`. Reasons: the 7 days match uv's cutoff (a younger
version is invisible to uv and would only produce an artifact error); `httpx` and
`pymacaroons` are unpinned in the `.in` and move with the weekly refresh. The age rule
names its update types because a manager-wide one also reaches the weekly refresh,
which has no release timestamp: Renovate's default
`minimumReleaseAgeBehaviour: "timestamp-required"` then marks it pending
(`renovate/stability-days` yellow) on every run. uv's cutoff (D3) ages the refresh.
*Corrected 2026-10-26, after approval: the approved text applied the age to the whole
manager, which would have left every refresh PR pending; see "What was verified".*

**D6. Renovate constrains uv to `>=0.11.16`** (`"constraints": {"uv": ">=0.11.16"}`).
Reason: relative `exclude-newer` needs uv 0.9.17+, and 0.11.16 is where `uv pip`
support was documented and tested. Renovate otherwise installs the latest uv, so this is
a floor, not a pin.

**D7. A helper test guards the header.** It fails when the lock's header command is
not the recipe in `requirements-store.in`, or is not in the D3 form: an option and its
value split by a space, a short option such as `-o`, or a missing `--exclude-newer=P7D`.
Reason: a regeneration with the old command would make Renovate stop updating the lock
without any PR-visible signal, because the hosted app only logs the extraction error.
Mutation-tested: restoring today's header must make it fail. It runs in `helper-tests`
(the required `test` check), which already runs every `.github/scripts/*.test.sh`.
It also rejects any option Renovate's parser does not accept for uv (the lists in
`lib/modules/manager/pip-compile/common.ts`, 44.181.5), because those stall Renovate
the same way (planner's call, 2026-10-26).

**D8. Docs follow the change.**
- The recipe comment in `requirements-store.in`.
- The Renovate paragraph in `CLAUDE.md`, which today says Renovate edits only the
  `.txt` and the `.in` pin must be brought up by hand. It will say:
  - The lock is pip-compile-managed and refreshed weekly by uv.
  - Every package must be 7 days old, manual regenerations included.
  - An urgent fix younger than 7 days needs a deliberate header change.
  - craft-store bumps edit the `.in`, and its majors are manual.

**D9. Acceptance after merge (the deploy step).**
- Renovate closes #251 and #252.
- The Dependency Dashboard lists the pip-compile refresh, awaiting schedule.
- At the next Monday window, or earlier if the dashboard checkbox is ticked, the refresh
  PR changes only package entries (header unchanged, no duplicates, no pre-release),
  `test` passes, and it merges itself.
- If the hosted app reports an artifact error instead, nothing merges (the `test` gate
  still applies), and the result goes back to Joachim before any further change.

## Alternative rejected: per-package indirect updates

Enabling indirect deps with `rangeStrategy: update-lockfile` also worked in a dry run:
the same four packages went to `renovate/store-client`, and certifi was held for its age.
The builder check found three problems with it:
- A forced `--upgrade-package` can make uv pick a pre-release (the pydantic-core case
  in D4).
- Packages uv moves along, or pulls in, get no age check.
- One unresolvable package (pyrfc3339 2.x; any version a parent caps) stops the whole
  group, the #251 shape again.

D3 + D4 remove all three without per-package caps.

## Constraints

- One branch and PR from `origin/main`; Joachim merges.
- Renovate config validated with Renovate's own validator in strict mode, plus a
  `--platform=local` dry run of the final config showing the D1–D5 outcome.
- Heavy local runs under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`.

## Left to the builder

- The test's file name and form (bash `.test.sh` next to the others is the default),
  and how it reads the recipe out of the `.in` comment.
- Rule order and `description` wording in `renovate.json`, and whether the
  lock-maintenance automerge lives in a packageRule or the `pip-compile` block.

## Related

- #247 (store-client automerge), #251 (failed group PR), #252 (pyrfc3339 v2).
- Renovate docs: `docs.renovatebot.com/modules/manager/pip-compile/`.
