# Store-client lock updated by Renovate's pip-compile manager — design

Date: 2026-10-25. Status: draft for review. Size: bounded (Renovate config, one
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

Joachim chose (2026-10-25, option 2) to let Renovate re-run uv itself instead.

## What was verified (2026-10-25, laptop, Renovate 44.181.5 `--platform=local` dry run, uv 0.12.9)

| Check | Result |
|---|---|
| hashin 1.0.5 replay of #251 on main's lock | Reproduces #251's file (duplicate `pydantic_core==2.50.1` at the end, stale hashes on line 440); `pip install --require-hashes` fails the same way. |
| Renovate's header parser (`lib/modules/manager/pip-compile/common.ts`) on today's header | Would throw: `--python-version 3.12` → "must have equal sign"; `-o` → "not supported (yet)". |
| `uv pip compile --universal --python-version=3.12 --generate-hashes --output-file=… .in` on main | Only header line 2 changes; uv echoes the arguments verbatim and keeps every pin. |
| Dry run, pip-compile on the lock, `pip_requirements` disabled for it, indirect deps enabled | Header parsed; 3 direct + 33 indirect deps extracted; all 36 `pip_requirements` deps `skip=disabled`; **no updates proposed**. |
| Same plus `rangeStrategy: update-lockfile` | more-itertools 11.2.1, pycparser 3.11, pydantic 2.14.1, pydantic-core 2.50.1 → `renovate/store-client` as lock updates; certifi 2026.10.23 **pending** (7-day age); pyrfc3339 2.1.1 → own major branch; a 7th flattened update (lock-file maintenance, on by default for this manager). |
| The command Renovate builds for that branch (header argv + `--upgrade-package=name==version` ×4) | Exactly those 4 entries change, 36 entries, env markers kept; `pip install --require-hashes` OK; store tests 63 + 6 pass. |
| macaroonbakery 1.3.4 (latest) `requires_dist` | `pyRFC3339 (<2.0,>=1.0)` — #252 can never resolve. |

Not verified locally: the hosted Mend app running uv (artifacts are not generated in a
local dry run), and an out-of-range bump of the pinned `craft-store==3.4.0` (none is
available today). Both are covered by the acceptance check after merge (D10).

## Goals

- Store-client lock bumps (direct and transitive) are produced by uv, so names,
  hashes and environment markers stay consistent.
- Keep #247's policy: minor/patch grouped into one "store client" PR, 7-day release
  age, automerge after the required checks; majors manual.
- A manual regeneration with the wrong command form is caught by a test, not by a
  silently stalled Renovate.

## Non-goals / anti-goals

- No change to duplicity, gum, Node or zwave-js-ui rules. `requirements-duplicity.txt`
  is a hand-hashed `--no-deps` pin list, not a compiled lock, and stays on
  `pip_requirements`.
- No upstream hashin fix, no `AUTOMERGE_TOKEN`, no pyrfc3339 v2 adoption.
- Anti-goals: a broken lock merging; a weekly refresh PR nobody asked for; losing the
  7-day buffer on transitive packages.

## Decisions

**D1. Renovate's `pip-compile` manager owns `.github/scripts/requirements-store.txt`.**
`"pip-compile": {"managerFilePatterns": ["/^\\.github/scripts/requirements-store\\.txt$/"]}`.
The manager matches the output lock and reads its header to find the `.in`. Reason:
uv regenerates names, hashes and markers itself; the spike changed exactly the four
intended entries and the result installed and passed the store tests.

**D2. `pip_requirements` is disabled for that one file by a packageRule**
(`matchManagers: ["pip_requirements"]`, `matchFileNames: [".github/scripts/requirements-store.txt"]`,
`enabled: false`). Reason: Renovate's docs say to stop the source manager running
twice; `pip_requirements` must keep handling `requirements-duplicity.txt`, and
`ignorePaths` would hide the lock from `pip-compile` too. Spike: all 36 entries
`skip=disabled`.

**D3. The lock header and the `.in` recipe use Renovate's accepted form:**
`uv pip compile --universal --python-version=3.12 --generate-hashes --output-file=.github/scripts/requirements-store.txt .github/scripts/requirements-store.in`.
Reason: Renovate's parser requires `=` between an option and its value and only knows
long options; today's header makes extraction throw. Regenerating changes header line 2
only.

**D4. Indirect deps are enabled, and all pip-compile deps use `rangeStrategy: "update-lockfile"`.**
Reason: the manager extracts transitive packages as `depType: indirect` with
`enabled: false`, and proposes lock-only updates only under `update-lockfile` (spike: zero
updates without it). Each update is then an ordinary update — Renovate runs uv with
`--upgrade-package=name==version` — so the 7-day release age applies per package
(spike: certifi held as pending). For the exact pin `craft-store==3.4.0`, Renovate's
`update-lockfile` falls back to replacing the pin in the `.in` for out-of-range versions.

**D5. The "store client" group rule is retargeted, not redesigned:** `matchManagers:
["pip-compile"]`, `matchFileNames: [".github/scripts/requirements-store.in"]`,
`matchUpdateTypes: ["minor", "patch"]`, `groupName: "store client"`,
`minimumReleaseAge: "7 days"`, `automerge: true`, label `dependencies`. Reason: same
policy as #247. For this manager the package file is the `.in` (spike: the rule matched —
branch `renovate/store-client`, certifi pending).

**D6. Lock-file maintenance is disabled for `pip-compile`.** Reason: it is on by default
for this manager (spike: the 7th flattened update), it re-resolves every package to
latest and so bypasses the 7-day wait, and D4 already updates the whole tree package by
package.

**D7. Majors stay separate manual PRs (direct and indirect), as today; pyrfc3339 is
capped with `allowedVersions: "<2"`.** The cap's `description` records why:
macaroonbakery 1.3.4, the latest, requires pyRFC3339 < 2. Remove it when macaroonbakery
allows 2.x. Reason: keeps resolvable transitive majors visible (e.g. cryptography),
while a known-unresolvable one is held with a written reason, like the Node ceiling.
The cap makes Renovate close #252. Alternative considered: disabling all indirect majors —
fewer PRs, but it hides majors that would resolve.

**D8. A helper test guards the header.** It fails when the lock's header command is
not the recipe in `requirements-store.in`, or is not in the D3 form (an option and its
value split by a space, or a short option such as `-o`). Reason: a regeneration with the
old command would make Renovate stop updating the lock without any PR-visible signal;
the hosted app only logs the extraction error. Mutation-tested: restoring today's header
must make it fail. It runs in `helper-tests` (the required `test` check), which already
runs every `.github/scripts/*.test.sh`.

**D9. Docs follow the change.** The recipe comment in `requirements-store.in` and the
Renovate paragraph in `CLAUDE.md` (no longer "Renovate edits only the `.txt` lock … run
`uv pip compile` by hand"; transitive packages now come from Renovate via uv, with the
7-day wait; majors manual; pyrfc3339 capped).

**D10. Acceptance after merge (the deploy step).** Renovate rebuilds `renovate/store-client`
(#251) with uv on its next run. Pass = the PR diff changes only the intended entries
with no duplicate, the lock header is unchanged, `test` passes, and the PR auto-merges;
#252 closes. If the hosted app reports an artifact error instead, nothing merges (the
`test` gate still applies), and the result comes back to Joachim before any further
change.

## Constraints

- One branch and PR from `origin/main`; Joachim merges.
- Renovate config validated with Renovate's own validator in strict mode, plus a
  `--platform=local` dry run on the final config showing the D4/D5/D6/D7 outcome.
- Heavy local runs under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`.

## Left to the builder

- The test's file name and form (bash `.test.sh` next to the others is the default),
  and how it reads the recipe out of the `.in` comment.
- Rule order and `description` wording in `renovate.json`, and whether D6 lives in the
  `pip-compile` manager block or a packageRule.

## Related

- #247 (store-client automerge), #251 (failed group PR), #252 (pyrfc3339 v2).
- Renovate docs: `docs.renovatebot.com/modules/manager/pip-compile/`.
