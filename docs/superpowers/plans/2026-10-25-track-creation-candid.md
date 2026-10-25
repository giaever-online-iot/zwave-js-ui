# Track creation via Candid gateway credential — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ensure-track` creates a missing `v<MM>` Snap Store track with a long-lived Candid gateway credential, warns on every PR before that credential dies, and ships a renewal helper.

**Architecture:** One Python script (`snap-create-track.py`) with two entry points: `--check` (non-blocking credential health: offline expiry from the macaroon's `time-before` caveat + an authenticated `whoami`) and `<snap> <track>` (strict create through craft-store's `PublisherGateway`, 409/`conflicting-tracks` = success). A sibling helper (`store-gateway-login.py`) performs the craft-store Candid login that produced the verified credential. A tiny shell helper warns when the Ubuntu One credential snapcraft uses is near expiry. Workflows wire `--check` into `helper-tests` (every PR) and `ensure-track` (build PRs).

**Tech Stack:** Python 3.12 (`ubuntu-latest`), `craft-store==3.4.0`, `httpx`, `pymacaroons` (all already hash-locked in `.github/scripts/requirements-store.txt`; no new packages), bash + shellcheck, `unittest` with `httpx.MockTransport` (the harness PR #244 established in `snap-create-track.test.py`).

**Spec:** `docs/superpowers/specs/2026-10-25-track-creation-candid-design.md` (read it first; decisions D1–D10).

## Global Constraints

- Gateway base URL `https://api.charmhub.io`, namespace `snap`, snap name from `$SNAP_NAME` (`zwave-js-ui`).
- Credential env var and repo secret: `SNAPCRAFT_GATEWAY_CREDENTIALS`. Blob format: base64 of `{"t": "macaroon", "v": "<pymacaroons v2 serialization>"}`; `v` starts with `Ag`, `json.loads(v)` fails, `Macaroon.deserialize(v)` works, caveat ids are `bytes`. Expiry caveat literal: `time-before 2027-10-24T22:04:54.745950Z` (RFC 3339, microseconds, `Z`).
- Existing track → HTTP 409 with error code `conflicting-tracks`; invalid name → HTTP 400 `api-error` quoting `^[a-zA-Z0-9](?:[_.-]?[a-zA-Z0-9])*$`.
- Warning threshold: 30 days. `--check` always exits 0 (annotations only) except on usage error; the create path is strict.
- Never print the blob, `v`, or any macaroon; error messages carry exception *type names* only when decoding fails. GitHub annotations are one line: escape `%`→`%25`, `\r`→`%0D`, `\n`→`%0A` (keep PR #244's `main()` escaping).
- Renewal hint text (exact, reused everywhere): ``renew: run .github/scripts/store-gateway-login.py locally (tap the Candid link on your phone), then `gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS < gateway.creds` ``.
- No exchange call anywhere; no `::add-mask::` needed.
- Dependencies stay as locked: `requirements-store.in`/`.txt` unchanged.
- `shellcheck .github/scripts/*.sh` clean; `yq '.' <workflow> >/dev/null` passes for every edited workflow.
- Commit style: `fix(ci): …`, `test(ci): …`, `docs(ci): …`, `feat(ci): …`; one commit per task.
- Run tests from the worktree with the hash-locked venv: `python3 -m venv .venv-store && .venv-store/bin/pip install -q --require-hashes -r .github/scripts/requirements-store.txt` (or `uv venv .venv-store && uv pip install --python .venv-store/bin/python --require-hashes -r …`). `.venv-store/` must not be committed: `echo .venv-store/ >> "$(git rev-parse --git-common-dir)/info/exclude"` (worktrees share that file), never `.gitignore`. `uv` lives at `~/.local/bin/uv`.

## Review Focus

1. A pasted **Ubuntu One** blob (`{"t":"u1-macaroon","v":{"r":…,"d":…}}`) in `SNAPCRAFT_GATEWAY_CREDENTIALS` must fail with a message naming the helper and must not echo any of it — Task 1 `test_u1_blob_is_rejected_without_leak`.
2. A credential **without** a `time-before` caveat: `--check` warns "expiry unknown"; create still proceeds — Task 1 `test_missing_time_before_is_unknown`, Task 3 `test_unknown_expiry_still_creates`.
3. A credential with **< 30 days left but not expired**: warning, and create still succeeds — Task 3 `test_near_expiry_warns_and_creates`.
4. `--check` with the secret **unset** (a context without secrets) must warn and exit 0, never error — Task 2 `test_check_unset_is_warning_exit_zero`.
5. The gateway **rejects** an unexpired credential (revoked, 401/403): `--check` errors with the renewal hint; create fails before `num-tracks-created` logic — Task 2 `test_check_whoami_401_is_error`, Task 3 `test_create_forbidden_gets_hint`.

---

### Task 1: Credential decoding and expiry status (pure functions)

**Files:**
- Modify: `.github/scripts/snap-create-track.py` (replace the exchange code; keep `TrackError`, `MacaroonAuth`, `error_messages`, `main()` escaping)
- Modify: `.github/scripts/snap-create-track.test.py` (replace fixtures + tests; keep the `run()` harness shape)

**Interfaces:**
- Produces:
  - `RENEW: str` — the exact renewal hint from Global Constraints.
  - `class Credential(NamedTuple): token: str; expires: datetime | None` (`expires` tz-aware UTC or `None` when no `time-before` caveat).
  - `load_credential(blob: str) -> Credential` — raises `TrackError("could not read SNAPCRAFT_GATEWAY_CREDENTIALS — expected the file written by store-gateway-login.py (<ExcTypeName>).")` on any decode failure (base64/JSON/`t != "macaroon"`/`Macaroon.deserialize`), never including content; raises `TrackError("SNAPCRAFT_GATEWAY_CREDENTIALS is empty or unset — cannot authenticate.")` for blank input.
  - `expiry_status(expires: datetime | None, now: datetime, warn_days: int = 30) -> tuple[str, str]` — `("error", "SNAPCRAFT_GATEWAY_CREDENTIALS expired on YYYY-MM-DD — <RENEW>")`, `("warning", "SNAPCRAFT_GATEWAY_CREDENTIALS expires in N days (YYYY-MM-DD) — <RENEW>")`, `("warning", "SNAPCRAFT_GATEWAY_CREDENTIALS has no time-before caveat; expiry unknown — <RENEW>")`, or `("ok", "SNAPCRAFT_GATEWAY_CREDENTIALS expires in N days (YYYY-MM-DD)")`. N = whole days floor; "expires in 0 days" is a warning, not an error, while `now < expires`.
  - `utcnow() -> datetime` — tz-aware; tests patch it.
- Test fixtures (module level in the test file, reused by Tasks 2–3): `make_blob(expires: str | None = "2027-10-24T22:04:54.745950Z", t: str = "macaroon") -> str` building a `Macaroon(location="api.snapcraft.io", identifier="zui", key="k", version=2)` with `add_first_party_caveat(f"time-before {expires}")` when `expires` is not None; `NOW = datetime(2026, 10, 25, 0, 0, tzinfo=timezone.utc)`.

- [ ] **Step 1: Write the failing tests** in `snap-create-track.test.py` (delete the U1 fixtures, `EXCHANGE`, and every `test_exchange_*`; keep `run()` but drop its `exchange_resp` parameter and map only `TRACKS` and `WHOAMI = "/v1/tokens/whoami"` paths, default whoami response `httpx.Response(200, json={"account": {"username": "giaever-online"}})`; env var becomes `SNAPCRAFT_GATEWAY_CREDENTIALS`):

```python
class LoadCredentialTest(unittest.TestCase):
    def test_decodes_v2_blob_and_expiry(self):
        cred = sct.load_credential(make_blob())
        self.assertTrue(cred.token.startswith("Ag"))
        self.assertEqual(cred.expires, datetime(2027, 10, 24, 22, 4, 54, 745950, tzinfo=timezone.utc))

    def test_missing_time_before_is_unknown(self):
        self.assertIsNone(sct.load_credential(make_blob(expires=None)).expires)

    def test_u1_blob_is_rejected_without_leak(self):
        u1 = base64.b64encode(json.dumps({"t": "u1-macaroon", "v": {"r": "secret-r", "d": "secret-d"}}).encode()).decode()
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(u1)
        self.assertIn("expected the file written by store-gateway-login.py", str(cm.exception))
        self.assertNotIn("secret-r", str(cm.exception))

    def test_undecodable_hides_content(self):
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(base64.b64encode(b"\xffsecret-macaroon").decode())
        self.assertNotIn("secret-macaroon", str(cm.exception))

    def test_blank_is_empty_error(self):
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(" \n")
        self.assertIn("is empty or unset", str(cm.exception))


class ExpiryStatusTest(unittest.TestCase):
    def test_ok(self):
        level, msg = sct.expiry_status(datetime(2027, 10, 24, tzinfo=timezone.utc), NOW)
        self.assertEqual((level, msg), ("ok", "SNAPCRAFT_GATEWAY_CREDENTIALS expires in 364 days (2027-10-24)"))

    def test_warning_under_30_days(self):
        level, msg = sct.expiry_status(NOW + timedelta(days=12, hours=5), NOW)
        self.assertEqual(level, "warning")
        self.assertEqual(msg, f"SNAPCRAFT_GATEWAY_CREDENTIALS expires in 12 days (2026-11-06) — {sct.RENEW}")

    def test_zero_days_left_is_warning(self):
        self.assertEqual(sct.expiry_status(NOW + timedelta(hours=3), NOW)[0], "warning")

    def test_expired(self):
        level, msg = sct.expiry_status(NOW - timedelta(seconds=1), NOW)
        self.assertEqual((level, msg), ("error", f"SNAPCRAFT_GATEWAY_CREDENTIALS expired on 2026-10-24 — {sct.RENEW}"))

    def test_unknown(self):
        level, msg = sct.expiry_status(None, NOW)
        self.assertEqual((level, msg), ("warning", f"SNAPCRAFT_GATEWAY_CREDENTIALS has no time-before caveat; expiry unknown — {sct.RENEW}"))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-store/bin/python .github/scripts/snap-create-track.test.py -v 2>&1 | tail -15`
Expected: FAIL/ERROR with `AttributeError: module 'snap_create_track' has no attribute 'load_credential'` (and the deleted exchange tests gone).

- [ ] **Step 3: Implement `RENEW`, `Credential`, `utcnow()`, `load_credential(blob)`, `expiry_status(expires, now, warn_days=30)` in `snap-create-track.py`**, deleting `exchange_header()` and `exchange()`. `load_credential`: strip → blank check → `json.loads(base64.b64decode(blob))` → require `obj["t"] == "macaroon"` and `str` `v` → `Macaroon.deserialize(v)` → scan `m.caveats`, normalising `caveat_id` bytes→str, for one starting with `"time-before "` → `datetime.fromisoformat(rest)`; anything raising inside that block becomes the type-only `TrackError`. Leave `create_track` temporarily calling `load_credential(creds).token` in place of `exchange(creds)` so the module still imports (Task 3 finishes it).

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv-store/bin/python .github/scripts/snap-create-track.test.py -v 2>&1 | tail -5`
Expected: `OK` for `LoadCredentialTest` and `ExpiryStatusTest`; any still-failing `CreateTrackTest` cases are Task 3's (note them, do not fix here).

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/snap-create-track.py .github/scripts/snap-create-track.test.py
git commit -m "fix(ci): decode the Candid gateway credential and compute its expiry (no exchange)"
```

---

### Task 2: `--check` health entry point (expiry + whoami, annotations only)

**Files:**
- Modify: `.github/scripts/snap-create-track.py`
- Modify: `.github/scripts/snap-create-track.test.py`

**Interfaces:**
- Consumes: Task 1's `load_credential`, `expiry_status`, `utcnow`, `RENEW`, `MacaroonAuth`, `error_messages`.
- Produces:
  - `whoami(token: str) -> tuple[str, str]` — GET `{GATEWAY}/v1/tokens/whoami` with `Authorization: Macaroon <token>` via `httpx.Client(timeout=TIMEOUT_S)`: 200 → `("ok", "gateway accepts the credential (account <username>)")`; 401/403 → `("error", "gateway rejected SNAPCRAFT_GATEWAY_CREDENTIALS (HTTP <n>: <error_messages>) — <RENEW>")`; any other status → `("warning", "gateway whoami failed (HTTP <n>: <error_messages>); credential not verified — not a credentials problem")`; `httpx.HTTPError` → `("warning", "gateway whoami failed (<ExcTypeName>); credential not verified — not a credentials problem")`. `<username>` = `resp.json()["account"]["username"]`, or `?` when absent.
  - `check(creds: str) -> int` — always returns 0. Prints, in order: expiry line and whoami line, each as `::warning::…` / `::error::…` (escaped like `main()` does) or a plain line for `ok`. When `creds` is blank: prints `::warning::SNAPCRAFT_GATEWAY_CREDENTIALS is not set in this context; skipping the gateway credential check` and returns 0 with no request. When `load_credential` raises: prints the `TrackError` as `::error::` and returns 0 with no request. An expired credential still runs whoami (two annotations).
  - `main(argv)` gains: `argv == [prog, "--check"]` → `return check(os.environ.get("SNAPCRAFT_GATEWAY_CREDENTIALS", ""))`.

- [ ] **Step 1: Write the failing tests** (add `WHOAMI` to the `run()` handler map with a `whoami_resp` parameter; add `check_argv = ["snap-create-track.py", "--check"]`; patch `sct.utcnow` to `lambda: NOW` inside `run()`):

```python
class CheckTest(unittest.TestCase):
    def test_check_ok_prints_plain_lines(self):
        rc, out, requests = run(argv=check_argv)
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.url.path for r in requests], [WHOAMI])
        self.assertEqual(requests[0].headers["Authorization"], "Macaroon " + sct.load_credential(make_blob()).token)
        self.assertIn("SNAPCRAFT_GATEWAY_CREDENTIALS expires in 364 days (2027-10-24)", out)
        self.assertIn("gateway accepts the credential (account giaever-online)", out)
        self.assertNotIn("::warning::", out); self.assertNotIn("::error::", out)

    def test_check_near_expiry_warns(self):
        rc, out, _ = run(argv=check_argv, creds=make_blob(expires="2026-11-06T05:00:00Z"))
        self.assertEqual(rc, 0)
        self.assertIn(f"::warning::SNAPCRAFT_GATEWAY_CREDENTIALS expires in 12 days (2026-11-06) — {sct.RENEW}", out)

    def test_check_expired_is_error_but_exit_zero(self):
        rc, out, requests = run(argv=check_argv, creds=make_blob(expires="2026-10-01T00:00:00Z"))
        self.assertEqual(rc, 0)
        self.assertIn("::error::SNAPCRAFT_GATEWAY_CREDENTIALS expired on 2026-10-01", out)
        self.assertEqual(len(requests), 1)

    def test_check_whoami_401_is_error(self):
        rc, out, _ = run(argv=check_argv, whoami_resp=store_error(401, "macaroon expired"))
        self.assertEqual(rc, 0)
        self.assertIn(f"::error::gateway rejected SNAPCRAFT_GATEWAY_CREDENTIALS (HTTP 401: macaroon expired) — {sct.RENEW}", out)

    def test_check_whoami_outage_is_warning(self):
        rc, out, _ = run(argv=check_argv, whoami_resp=httpx.ConnectError("down"))
        self.assertEqual(rc, 0)
        self.assertIn("::warning::gateway whoami failed (ConnectError); credential not verified — not a credentials problem", out)

    def test_check_whoami_503_is_warning(self):
        rc, out, _ = run(argv=check_argv, whoami_resp=HTML_502)
        self.assertIn("::warning::gateway whoami failed (HTTP 502: unparseable body); credential not verified", out)

    def test_check_unset_is_warning_exit_zero(self):
        rc, out, requests = run(argv=check_argv, creds=None)
        self.assertEqual((rc, requests), (0, []))
        self.assertIn("::warning::SNAPCRAFT_GATEWAY_CREDENTIALS is not set in this context", out)

    def test_check_undecodable_is_error_exit_zero(self):
        rc, out, requests = run(argv=check_argv, creds=base64.b64encode(b"\xffsecret").decode())
        self.assertEqual((rc, requests), (0, []))
        self.assertIn("::error::could not read SNAPCRAFT_GATEWAY_CREDENTIALS", out)
        self.assertNotIn("secret", out)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-store/bin/python .github/scripts/snap-create-track.test.py CheckTest -v 2>&1 | tail -12`
Expected: FAIL — `--check` falls into the usage branch (`rc == 1`, "usage:").

- [ ] **Step 3: Implement `whoami(token)` and `check(creds)`; route `--check` in `main()`** (usage line becomes `usage: snap-create-track.py <snap-name> <track> | --check`). Factor the annotation escaping out of `main()` into `annotate(level: str, message: str) -> None` so `check()` and `main()` share it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv-store/bin/python .github/scripts/snap-create-track.test.py CheckTest LoadCredentialTest ExpiryStatusTest -v 2>&1 | tail -4`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/snap-create-track.py .github/scripts/snap-create-track.test.py
git commit -m "feat(ci): snap-create-track --check — non-blocking credential expiry + whoami annotations"
```

---

### Task 3: Strict create path (direct gateway POST, fail-fast on a dead credential)

**Files:**
- Modify: `.github/scripts/snap-create-track.py`
- Modify: `.github/scripts/snap-create-track.test.py`

**Interfaces:**
- Consumes: Task 1/2 functions; craft-store `PublisherGateway(GATEWAY, "snap", auth).create_tracks(snap, {"name": track}) -> int`.
- Produces: `create_track(snap: str, track: str, creds: str) -> None` and the unchanged CLI `snap-create-track.py <snap> <track>` (exit 0 created/exists, 1 otherwise). Behaviour:
  - `load_credential` errors propagate (exit 1, no request).
  - `expiry_status(...)[0] == "error"` → `TrackError("create-track <snap>/<track>: " + message)` before any request; `"warning"` → print `::warning::` line, continue.
  - `MacaroonAuth` gains `requires_response_body = True` and records `self.status` and `self.codes: list[str]` (error codes from the body's `error-list`, `[]` when unparseable).
  - Existing track = `auth.status == 409 or "conflicting-tracks" in auth.codes` → print `Track <track> already exists.`; otherwise keep PR #244's error mapping (`CraftStoreError`/`TypeError`/`AttributeError` → `create-track <snap>/<track> failed: <detail>` with the 401/403 hint `The credentials can't manage this snap's tracks, or the name misses its track-creation guardrails.`; `httpx.HTTPError` → `store unreachable (<ExcType>)`; `created < 1` → `returned success but created no track`).

- [ ] **Step 1: Write the failing tests** (rewrite `CreateTrackTest`: default `creds=make_blob()`, requests now `[TRACKS]` only; keep the `assertFails` helper):

```python
    def test_creates_track(self):
        rc, out, requests = run()
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.url.path for r in requests], [TRACKS])
        self.assertEqual(requests[0].headers["Authorization"], "Macaroon " + sct.load_credential(make_blob()).token)
        self.assertEqual(json.loads(requests[0].content), [{"name": "v11.20"}])
        self.assertIn("num-tracks-created=1", out)
        self.assertNotIn("::add-mask::", out)

    def test_existing_track_409_is_success(self):
        rc, out, _ = run(tracks_resp=httpx.Response(409, json={"error-list": [{"code": "conflicting-tracks", "message": "Conflicting track exists: v11.20"}]}))
        self.assertEqual(rc, 0, out); self.assertIn("already exists", out)

    def test_conflicting_tracks_code_with_other_status_is_success(self):
        rc, out, _ = run(tracks_resp=httpx.Response(400, json={"error-list": [{"code": "conflicting-tracks", "message": "exists"}]}))
        self.assertEqual(rc, 0, out)

    def test_existing_track_with_odd_body_is_success(self):   # keep from #244
        rc, out, _ = run(tracks_resp=httpx.Response(409, json=[1]))
        self.assertEqual(rc, 0, out)

    def test_expired_fails_fast_without_request(self):
        out = self.assertFails(run(creds=make_blob(expires="2026-10-01T00:00:00Z")),
                               f"create-track {SNAP}/v11.20: SNAPCRAFT_GATEWAY_CREDENTIALS expired on 2026-10-01", [])
        self.assertIn(sct.RENEW, out)

    def test_near_expiry_warns_and_creates(self):
        rc, out, requests = run(creds=make_blob(expires="2026-11-06T05:00:00Z"))
        self.assertEqual((rc, [r.url.path for r in requests]), (0, [TRACKS]))
        self.assertIn("::warning::SNAPCRAFT_GATEWAY_CREDENTIALS expires in 12 days", out)

    def test_unknown_expiry_still_creates(self):
        rc, out, requests = run(creds=make_blob(expires=None))
        self.assertEqual((rc, [r.url.path for r in requests]), (0, [TRACKS]))
        self.assertIn("::warning::SNAPCRAFT_GATEWAY_CREDENTIALS has no time-before caveat", out)

    def test_store_name_rule_400_is_reported(self):
        out = self.assertFails(run(tracks_resp=store_error(400, "'v1_' does not match '^[a-zA-Z0-9](?:[_.-]?[a-zA-Z0-9])*$' at /0/name")),
                               f"create-track {SNAP}/v11.20 failed:", [TRACKS])
        self.assertIn("does not match", out)

    def test_create_forbidden_gets_hint(self):
        out = self.assertFails(run(tracks_resp=store_error(403, "nope")), f"create-track {SNAP}/v11.20 failed:", [TRACKS])
        self.assertIn("can't manage this snap's tracks", out)

    def test_unset_creds_fail_fast(self):
        self.assertFails(run(creds=None), "SNAPCRAFT_GATEWAY_CREDENTIALS is empty or unset", [])
```
Keep, adapted to `[TRACKS]` and the new env name: `test_usage` (usage text now mentions `--check`), `test_blank_creds_fail_fast`, `test_undecodable_creds_hide_content`, `test_create_unreachable`, `test_create_html_502`, `test_invalid_track_name_skips_tracks_post` (expects `[]`), `test_zero_created`, `test_create_null_error_list`, `test_multiline_store_error_stays_one_annotation`, `test_server_error_has_no_auth_hint`. Delete `test_malformed_macaroon` and `test_unauthorized_gets_hint` (superseded).

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv-store/bin/python .github/scripts/snap-create-track.test.py CreateTrackTest -v 2>&1 | tail -12`
Expected: FAIL — `test_expired_fails_fast_without_request`, `test_near_expiry_warns_and_creates`, `test_conflicting_tracks_code_with_other_status_is_success` fail (no expiry gate, no `codes`).

- [ ] **Step 3: Implement the create path**: `MacaroonAuth.requires_response_body = True` + `codes` capture (`error_messages`-style parse of `error-list[*].code`), expiry gate + warning in `create_track`, existing-track rule. Update the module docstring to describe the Candid credential and the two entry points (drop every mention of exchange/dashboard).

- [ ] **Step 4: Run the whole file**

Run: `.venv-store/bin/python .github/scripts/snap-create-track.test.py 2>&1 | tail -4`
Expected: `OK` (≈35 tests), and `grep -n "exchange\|add-mask" .github/scripts/snap-create-track.py` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/snap-create-track.py .github/scripts/snap-create-track.test.py
git commit -m "fix(ci): create tracks with the Candid gateway credential directly; 409/conflicting-tracks = exists"
```

---

### Task 4: Renewal helper `store-gateway-login.py`

**Files:**
- Create: `.github/scripts/store-gateway-login.py`
- Create: `.github/scripts/store-gateway-login.test.py`

**Interfaces:**
- Consumes: `craft_store.StoreClient`, `craft_store.endpoints.CHARMHUB`, `craft_store.attenuations.PACKAGE_MANAGE`/`PACKAGE_VIEW`.
- Produces: CLI `store-gateway-login.py <out-file>` (exit 0; 2 on usage). Module constants `GATEWAY = "https://api.charmhub.io"`, `STORAGE = "https://storage.snapcraftcontent.com"`, `PERMISSIONS = ["package-manage", "package-view"]`, `DESCRIPTION = "zwave-js-ui CI: create version tracks"`, `TTL_SECONDS = 365 * 24 * 3600`, `SECRET = "SNAPCRAFT_GATEWAY_CREDENTIALS"`. Functions: `login() -> str` (builds `StoreClient(base_url=GATEWAY, storage_base_url=STORAGE, endpoints=endpoints.CHARMHUB, application_name="zwave-js-ui-ci", user_agent="zwave-js-ui-ci/1.0", ephemeral=True)` and returns `client.login(permissions=PERMISSIONS, description=DESCRIPTION, ttl=TTL_SECONDS)`); `write_credential(path: str, blob: str) -> None` (0600 via `os.open(..., 0o600)`, overwrite); `main(argv) -> int` prints before login: `Starting the Candid login; craft-store prints the URL to open (tap it on your phone and sign in with Ubuntu One).` and after: `Credential written to <path> (0600; valid 365 days). Set the repo secret with:` + newline + `  gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS --repo giaever-online-iot/zwave-js-ui < <path>` — never the blob.

- [ ] **Step 1: Write the failing test**

```python
class LoginHelperTest(unittest.TestCase):
    def test_login_reproduces_verified_parameters_and_writes_0600(self):
        calls = {}
        class FakeClient:
            def __init__(self, **kw): calls["init"] = kw
            def login(self, **kw): calls["login"] = kw; return "BLOB-NEVER-PRINTED"
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as d, mock.patch.object(sgl, "StoreClient", FakeClient), contextlib.redirect_stdout(out):
            path = os.path.join(d, "gateway.creds")
            self.assertEqual(sgl.main(["store-gateway-login.py", path]), 0)
            self.assertEqual(open(path).read(), "BLOB-NEVER-PRINTED")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(calls["init"], {"base_url": "https://api.charmhub.io", "storage_base_url": "https://storage.snapcraftcontent.com",
                                         "endpoints": sgl.endpoints.CHARMHUB, "application_name": "zwave-js-ui-ci",
                                         "user_agent": "zwave-js-ui-ci/1.0", "ephemeral": True})
        self.assertEqual(calls["login"], {"permissions": ["package-manage", "package-view"],
                                          "description": "zwave-js-ui CI: create version tracks", "ttl": 31536000})
        self.assertIn("gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS --repo giaever-online-iot/zwave-js-ui < ", out.getvalue())
        self.assertNotIn("BLOB-NEVER-PRINTED", out.getvalue())

    def test_usage(self):
        out = io.StringIO()
        with contextlib.redirect_stderr(out):
            self.assertEqual(sgl.main(["store-gateway-login.py"]), 2)
        self.assertIn("usage:", out.getvalue())
```
Load the module the same way `snap-create-track.test.py` does (`importlib.util.spec_from_file_location`).

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv-store/bin/python .github/scripts/store-gateway-login.test.py -v 2>&1 | tail -5`
Expected: ERROR — file not found / module has no `main`.

- [ ] **Step 3: Implement `store-gateway-login.py`** (module docstring: what it does, that renewal = run it, tap the link, set the secret; that `$BROWSER` is honoured by craft-store and the URL is also printed).

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv-store/bin/python .github/scripts/store-gateway-login.test.py -v 2>&1 | tail -4`
Expected: `OK` (2 tests)

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/store-gateway-login.py .github/scripts/store-gateway-login.test.py
git commit -m "feat(ci): store-gateway-login.py — craft-store Candid login that mints the gateway credential"
```

---

### Task 5: `store-login-expiry.sh` — warn when snapcraft's Ubuntu One login is near expiry

**Files:**
- Create: `.github/scripts/store-login-expiry.sh`
- Create: `.github/scripts/store-login-expiry.test.sh` (follow the harness style of `.github/scripts/retry.test.sh`)

**Interfaces:**
- Produces: `store-login-expiry.sh <label> <warn-days>` reading `snapcraft whoami` output on stdin; env `NOW_EPOCH` overrides the current time (tests). Parses the `expires:` line (ISO 8601, e.g. `expires: 2026-11-30T09:13:19.000Z`) with `date -u -d`. Prints exactly one line and always exits 0: `::warning::<label> expires in N days (YYYY-MM-DD) — refresh it with \`snapcraft export-login\`` when `N < warn-days` (N may be negative → `::error::<label> expired on YYYY-MM-DD — refresh it with \`snapcraft export-login\``, still exit 0); `<label> expires in N days (YYYY-MM-DD)` otherwise; `::warning::<label>: could not read the expiry from snapcraft whoami` when the line is missing or unparseable.

- [ ] **Step 1: Write the failing test** with four cases (ok at 364 days, warning at 12 days, expired, missing line) feeding heredoc stdin and `NOW_EPOCH=$(date -u -d 2026-10-25T00:00:00Z +%s)`, asserting the exact line and exit 0.

- [ ] **Step 2: Run it to verify it fails**: `bash .github/scripts/store-login-expiry.test.sh` → Expected: fails (script missing).

- [ ] **Step 3: Implement the script** (`set -euo pipefail`, `shellcheck` clean, no bashisms beyond bash 5).

- [ ] **Step 4: Verify**: `bash .github/scripts/store-login-expiry.test.sh && shellcheck .github/scripts/*.sh` → Expected: all cases pass, shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/store-login-expiry.sh .github/scripts/store-login-expiry.test.sh
git commit -m "feat(ci): store-login-expiry.sh — warn when SNAPCRAFT_STORE_CREDENTIALS is near expiry"
```

---

### Task 6: Wire the workflows

**Files:**
- Modify: `.github/workflows/pr-build-snap.yml:78-101` (ensure-track) and the report comment at `:244-250`
- Modify: `.github/workflows/helper-tests.yml`

**Interfaces:**
- Consumes: Tasks 2–5 CLIs.
- Produces: the jobs below. No new secrets besides `SNAPCRAFT_GATEWAY_CREDENTIALS`.

- [ ] **Step 1: Edit `helper-tests.yml`**: rename the last step to `Run store-client helper unit tests` looping `for t in .github/scripts/*.test.py` (same `== $t` echo pattern as the shell loop); add a final step `Store gateway credential health (annotations only)` with `env: SNAPCRAFT_GATEWAY_CREDENTIALS: ${{ secrets.SNAPCRAFT_GATEWAY_CREDENTIALS }}` running `"$RUNNER_TEMP/store-venv/bin/python" .github/scripts/snap-create-track.py --check`. Update the header comment ("store track creation + credential health").

- [ ] **Step 2: Edit `ensure-track` in `pr-build-snap.yml`**: `env` gains `SNAPCRAFT_GATEWAY_CREDENTIALS: ${{ secrets.SNAPCRAFT_GATEWAY_CREDENTIALS }}`; steps become (1) checkout, (2) install snapcraft, (3) `Install store client` = the venv + `retry.sh 3 15 -- pip install --require-hashes` lines moved up, (4) `Credential health (annotations only)` = `python snap-create-track.py --check` then `snapcraft whoami 2>/dev/null | bash .github/scripts/store-login-expiry.sh SNAPCRAFT_STORE_CREDENTIALS 30`, (5) `Ensure version track exists` = the `snapcraft tracks` early exit then `retry.sh 3 15 -- python snap-create-track.py "$SNAP_NAME" "$TRACK"`. Replace the comment above the create with: `# "track exists" (409/conflicting-tracks) exits 0, so retrying a half-done create is safe.` In the report step change both `SNAPCRAFT_STORE_CREDENTIALS` mentions (comment + ⚠️ line) to `SNAPCRAFT_GATEWAY_CREDENTIALS` and add `; run \`.github/scripts/store-gateway-login.py\` to renew` to the ⚠️ line.

- [ ] **Step 3: Validate**

Run: `for f in .github/workflows/pr-build-snap.yml .github/workflows/helper-tests.yml; do yq '.' "$f" >/dev/null && echo "$f OK"; done; grep -n 'SNAPCRAFT_SESSION' .github/workflows/*.yml || echo "no cookie refs"; grep -c 'SNAPCRAFT_GATEWAY_CREDENTIALS' .github/workflows/pr-build-snap.yml .github/workflows/helper-tests.yml`
Expected: both `OK`, `no cookie refs`, counts ≥ 3 and ≥ 1.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-build-snap.yml .github/workflows/helper-tests.yml
git commit -m "ci(track): ensure-track + helper-tests use the Candid gateway credential with a health check"
```

---

### Task 7: Docs

**Files:**
- Modify: `CLAUDE.md` (the `pr-build-snap.yml` bullet under "CI / contribution rules"; the Renovate paragraph's `requirements-store.txt` sentence)
- Modify: `docs/superpowers/specs/2026-10-25-track-creation-candid-design.md` (Status line → `implemented on PR #244`)

- [ ] **Step 1: Edit `CLAUDE.md`**: in the `pr-build-snap.yml` bullet replace the parenthetical about exchanging `SNAPCRAFT_STORE_CREDENTIALS` with: `(publisher-gateway tracks API, authenticated with the Candid credential in the \`SNAPCRAFT_GATEWAY_CREDENTIALS\` secret — see \`.github/scripts/snap-create-track.py\`; it is separate from \`SNAPCRAFT_STORE_CREDENTIALS\`, which the snapcraft CLI needs and which cannot create tracks)`. Add one sentence after it: `**Renewing the gateway credential** (yearly; \`helper-tests\` and \`ensure-track\` warn 30 days ahead on every PR): run \`.github/scripts/store-gateway-login.py gateway.creds\` locally with the hash-locked venv, tap the printed Candid link on any device and sign in with Ubuntu One, then \`gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS < gateway.creds\`; the old session-cookie route is gone.` Mention `store-gateway-login.py` in the Renovate `requirements-store.txt` sentence as a second user of the lock.

- [ ] **Step 2: Verify**: `grep -n 'SNAPCRAFT_GATEWAY_CREDENTIALS\|store-gateway-login' CLAUDE.md | wc -l` → Expected: ≥ 3; `grep -n 'SNAPCRAFT_SESSION' CLAUDE.md README.md || echo none` → `none`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-10-25-track-creation-candid-design.md
git commit -m "docs(ci): gateway credential, renewal runbook; spec status"
```

---

### Task 8: Live verification and secret rotation (orchestrator + maintainer; not a subagent task)

**Files:** none committed. Uses the real credential (local 0600 copy / repo secret).

- [ ] **Step 1: Local live run of the final script** from the worktree with the hash-locked venv and the local credential file:
  `SNAPCRAFT_GATEWAY_CREDENTIALS="$(cat <creds>)" .venv-store/bin/python .github/scripts/snap-create-track.py --check` → Expected: two plain lines, `expires in 36x days (2027-10-24)` and `gateway accepts the credential (account giaever-online)`, exit 0.
  `… snap-create-track.py zwave-js-ui v11.25` → Expected: `Track v11.25 already exists.`, exit 0 (409 path, creates nothing).
- [ ] **Step 2: Push the branch; confirm `helper-tests` on the PR is green and its health step prints the two plain lines** (`gh run view --log`), proving the secret works from CI.
- [ ] **Step 3: D5 rotation**: run `.venv-store/bin/python .github/scripts/store-gateway-login.py <new-file>` (with `BROWSER` pointed at a capture stand-in so no laptop tab opens), relay the URL to Joachim's phone, wait for the login, then `gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS --repo giaever-online-iot/zwave-js-ui < <new-file>`; re-run Step 1 `--check` with the new file; `shred -u` both local credential files.
- [ ] **Step 4: Whole-branch review, fix wave, scoped re-review; then push the commits onto `origin/ci/create-track-store-credentials` (PR #244) for Joachim to merge.** After merge Joachim deletes the org secret `SNAPCRAFT_SESSION`.
