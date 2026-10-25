"""Offline unit tests for snap-create-track.py. Fakes the store over httpx; no network."""

import base64
import contextlib
import importlib.util
import io
import json
import pathlib
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

import httpx
from pymacaroons import Macaroon

spec = importlib.util.spec_from_file_location(
    "snap_create_track", pathlib.Path(__file__).with_name("snap-create-track.py")
)
sct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sct)

NOW = datetime(2026, 10, 25, 0, 0, tzinfo=timezone.utc)


def make_blob(expires="2027-10-24T22:04:54.745950Z", t="macaroon"):
    """A gateway credential as store-gateway-login.py writes it: base64 of {"t", "v": v2 macaroon}.

    `expires` is one time-before timestamp, None for no caveat, or a sequence for several caveats.
    """
    macaroon = Macaroon(location="api.snapcraft.io", identifier="zui", key="k", version=2)
    for stamp in () if expires is None else (expires,) if isinstance(expires, str) else expires:
        macaroon.add_first_party_caveat(f"time-before {stamp}")
    return base64.b64encode(json.dumps({"t": t, "v": macaroon.serialize()}).encode()).decode()


SNAP = "zwave-js-ui"
TRACKS = f"/v1/snap/{SNAP}/tracks"
WHOAMI = "/v1/tokens/whoami"
CREATED = httpx.Response(201, json={"num-tracks-created": 1})
WHOAMI_OK = httpx.Response(200, json={"account": {"username": "giaever-online"}})
HTML_502 = httpx.Response(502, text="<html>Bad Gateway</html>")
check_argv = ["snap-create-track.py", "--check"]


def store_error(status, message):
    return httpx.Response(status, json={"error-list": [{"code": "x", "message": message}]})


def _no_network(*_args, **_kwargs):
    raise AssertionError("a request bypassed the fake store")


def run(track="v11.20", creds=make_blob(), tracks_resp=CREATED, whoami_resp=WHOAMI_OK, argv=None):
    """Run main() against a fake store; return (rc, stdout+stderr, requests made).

    A response may be an exception instance, which the fake transport raises instead.
    The clock is pinned to NOW.
    """
    requests = []

    def handler(request):
        requests.append(request)
        answer = {TRACKS: tracks_resp, WHOAMI: whoami_resp}[request.url.path]
        if isinstance(answer, Exception):
            raise answer
        return answer

    real_client = httpx.Client
    env = {} if creds is None else {"SNAPCRAFT_GATEWAY_CREDENTIALS": creds}
    out = io.StringIO()
    with (
        mock.patch.object(httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(handler), **kw)),
        # If craft-store ever builds its client another way, fail instead of reaching the real store.
        mock.patch.object(httpx.HTTPTransport, "handle_request", _no_network),
        mock.patch.object(sct, "utcnow", lambda: NOW),
        mock.patch.dict("os.environ", env, clear=True),
        contextlib.redirect_stdout(out),
        contextlib.redirect_stderr(out),
    ):
        rc = sct.main(argv or ["snap-create-track.py", SNAP, track])
    return rc, out.getvalue(), requests


class LoadCredentialTest(unittest.TestCase):
    def test_decodes_v2_blob_and_expiry(self):
        cred = sct.load_credential(make_blob())
        self.assertTrue(cred.token.startswith("Ag"))
        self.assertEqual(cred.expires, datetime(2027, 10, 24, 22, 4, 54, 745950, tzinfo=timezone.utc))

    def test_missing_time_before_is_unknown(self):
        self.assertIsNone(sct.load_credential(make_blob(expires=None)).expires)

    def test_expiry_is_normalised_to_utc(self):
        offset = sct.load_credential(make_blob(expires="2027-10-24T23:30:00+02:00")).expires
        self.assertEqual(offset, datetime(2027, 10, 24, 21, 30, tzinfo=timezone.utc))
        self.assertEqual(offset.utcoffset(), timedelta(0))
        naive = sct.load_credential(make_blob(expires="2027-10-24T23:30:00")).expires
        self.assertEqual(naive, datetime(2027, 10, 24, 23, 30, tzinfo=timezone.utc))

    def test_earliest_time_before_governs_in_either_order(self):
        early, late = "2027-01-01T00:00:00Z", "2027-06-01T00:00:00Z"
        for order in ((early, late), (late, early)):
            with self.subTest(order=order):
                self.assertEqual(
                    sct.load_credential(make_blob(expires=order)).expires,
                    datetime(2027, 1, 1, tzinfo=timezone.utc),
                )

    def test_binary_third_party_caveat_does_not_hide_expiry(self):
        macaroon = Macaroon(location="api.snapcraft.io", identifier="zui", key="k", version=2)
        macaroon.add_third_party_caveat("login.example", "caveat-key", b"\xff\xfe-binary-id")
        macaroon.add_first_party_caveat("time-before 2027-10-24T22:04:54.745950Z")
        blob = base64.b64encode(json.dumps({"t": "macaroon", "v": macaroon.serialize()}).encode()).decode()
        self.assertEqual(
            sct.load_credential(blob).expires, datetime(2027, 10, 24, 22, 4, 54, 745950, tzinfo=timezone.utc)
        )

    def test_u1_blob_is_rejected_without_leak(self):
        u1 = base64.b64encode(
            json.dumps({"t": "u1-macaroon", "v": {"r": "secret-r", "d": "secret-d"}}).encode()
        ).decode()
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(u1)
        self.assertIn("expected the file written by store-gateway-login.py", str(cm.exception))
        self.assertNotIn("secret-r", str(cm.exception))

    def test_wrong_type_tag_is_rejected_even_with_a_valid_macaroon(self):
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(make_blob(t="u1-macaroon"))
        self.assertIn("could not read SNAPCRAFT_GATEWAY_CREDENTIALS", str(cm.exception))

    def test_non_string_macaroon_is_rejected_without_leak(self):
        blob = base64.b64encode(json.dumps({"t": "macaroon", "v": {"r": "secret-r"}}).encode()).decode()
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(blob)
        self.assertIn("could not read SNAPCRAFT_GATEWAY_CREDENTIALS", str(cm.exception))
        self.assertNotIn("secret-r", str(cm.exception))

    def test_undecodable_hides_content(self):
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(base64.b64encode(b"\xffsecret-macaroon").decode())
        self.assertIn("could not read SNAPCRAFT_GATEWAY_CREDENTIALS", str(cm.exception))
        self.assertNotIn("secret-macaroon", str(cm.exception))

    def test_malformed_macaroon_reports_type_only(self):
        blob = base64.b64encode(json.dumps({"t": "macaroon", "v": "!!secret-v!!"}).encode()).decode()
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(blob)
        self.assertRegex(str(cm.exception), r"store-gateway-login\.py \(\w+\)\.$")
        self.assertNotIn("secret-v", str(cm.exception))

    def test_blank_is_empty_error(self):
        with self.assertRaises(sct.TrackError) as cm:
            sct.load_credential(" \n")
        self.assertEqual(
            str(cm.exception), "SNAPCRAFT_GATEWAY_CREDENTIALS is empty or unset — cannot authenticate."
        )


class ExpiryStatusTest(unittest.TestCase):
    def test_ok(self):
        level, msg = sct.expiry_status(datetime(2027, 10, 24, tzinfo=timezone.utc), NOW)
        self.assertEqual((level, msg), ("ok", "SNAPCRAFT_GATEWAY_CREDENTIALS expires in 364 days (2027-10-24)"))

    def test_exactly_warn_days_left_is_ok(self):
        self.assertEqual(sct.expiry_status(NOW + timedelta(days=30), NOW)[0], "ok")

    def test_just_under_warn_days_is_warning(self):
        level, msg = sct.expiry_status(NOW + timedelta(days=30) - timedelta(seconds=1), NOW)
        self.assertEqual(level, "warning")
        self.assertIn("expires in 29 days (2026-11-23)", msg)

    def test_warn_days_is_configurable(self):
        self.assertEqual(sct.expiry_status(NOW + timedelta(days=10), NOW, warn_days=7)[0], "ok")
        self.assertEqual(sct.expiry_status(NOW + timedelta(days=10), NOW, warn_days=11)[0], "warning")

    def test_warning_under_30_days(self):
        level, msg = sct.expiry_status(NOW + timedelta(days=12, hours=5), NOW)
        self.assertEqual(level, "warning")
        self.assertEqual(msg, f"SNAPCRAFT_GATEWAY_CREDENTIALS expires in 12 days (2026-11-06) — {sct.RENEW}")

    def test_zero_days_left_is_warning(self):
        level, msg = sct.expiry_status(NOW + timedelta(hours=3), NOW)
        self.assertEqual(level, "warning")
        self.assertIn("expires in 0 days (2026-10-25)", msg)

    def test_expired(self):
        level, msg = sct.expiry_status(NOW - timedelta(seconds=1), NOW)
        self.assertEqual(
            (level, msg), ("error", f"SNAPCRAFT_GATEWAY_CREDENTIALS expired on 2026-10-24 — {sct.RENEW}")
        )

    def test_expiring_exactly_now_is_expired(self):
        self.assertEqual(sct.expiry_status(NOW, NOW)[0], "error")

    def test_unknown(self):
        level, msg = sct.expiry_status(None, NOW)
        self.assertEqual(
            (level, msg),
            ("warning", f"SNAPCRAFT_GATEWAY_CREDENTIALS has no time-before caveat; expiry unknown — {sct.RENEW}"),
        )

    def test_renew_hint_text(self):
        self.assertEqual(
            sct.RENEW,
            "renew: run `.github/scripts/store-gateway-login.py gateway.creds` locally with the venv from its header "
            "(tap the Candid link on your phone), "
            "then `gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS < gateway.creds`",
        )

    def test_utcnow_is_timezone_aware(self):
        self.assertEqual(sct.utcnow().utcoffset(), timedelta(0))


class CreateTrackTest(unittest.TestCase):
    def assertFails(self, result, message, expected_paths):
        rc, out, requests = result
        self.assertEqual(rc, 1, out)
        self.assertIn(f"::error::{message}", out)
        self.assertEqual([r.url.path for r in requests], expected_paths)
        return out

    def test_creates_track(self):
        rc, out, requests = run()
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.url.path for r in requests], [TRACKS])
        # The expected header is derived from the raw blob, not from the code under test.
        raw_token = json.loads(base64.b64decode(make_blob()))["v"]
        self.assertEqual(requests[0].headers["Authorization"], "Macaroon " + raw_token)
        self.assertEqual(json.loads(requests[0].content), [{"name": "v11.20"}])
        self.assertIn("num-tracks-created=1", out)
        self.assertNotIn("::add-mask::", out)

    def test_existing_track_409_is_success(self):
        conflict = {"error-list": [{"code": "conflicting-tracks", "message": "Conflicting track exists: v11.20"}]}
        rc, out, requests = run(tracks_resp=httpx.Response(409, json=conflict))
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.url.path for r in requests], [TRACKS])
        self.assertIn("Track v11.20 already exists.", out)

    def test_conflicting_tracks_code_with_other_status_is_success(self):
        rc, out, _ = run(
            tracks_resp=httpx.Response(400, json={"error-list": [{"code": "conflicting-tracks", "message": "exists"}]})
        )
        self.assertEqual(rc, 0, out)
        self.assertIn("already exists", out)

    def test_conflicting_code_is_read_from_a_body_that_arrives_unread(self):
        # Unlike a canned Response, a real one is streamed: .json() only works once the auth flow
        # has been told to wait for the body (MacaroonAuth.requires_response_body).
        body = json.dumps({"error-list": [{"code": "conflicting-tracks", "message": "exists"}]}).encode()
        rc, out, _ = run(tracks_resp=httpx.Response(400, stream=httpx.ByteStream(body)))
        self.assertEqual(rc, 0, out)
        self.assertIn("already exists", out)

    def test_other_error_code_with_other_status_is_failure(self):
        self.assertFails(
            run(tracks_resp=httpx.Response(400, json={"error-list": [{"code": "api-error", "message": "bad"}]})),
            f"create-track {SNAP}/v11.20 failed:",
            [TRACKS],
        )

    def test_existing_track_with_odd_body_is_success(self):
        rc, out, _ = run(tracks_resp=httpx.Response(409, json=[1]))
        self.assertEqual(rc, 0, out)
        self.assertIn("already exists", out)

    def test_usage(self):
        rc, out, requests = run(argv=["snap-create-track.py"])
        self.assertEqual((rc, requests), (1, []))
        self.assertIn("usage: snap-create-track.py <snap-name> <track> | --check", out)

    def test_dash_arguments_other_than_exact_check_are_usage(self):
        for args in (["--check", "extra"], ["extra", "--check"], ["--bogus", "v11.20"], [SNAP, "-v"], ["--check=1"]):
            with self.subTest(args=args):
                rc, out, requests = run(argv=["snap-create-track.py", *args])
                self.assertEqual((rc, requests), (1, []))
                self.assertIn("usage:", out)
                self.assertNotIn("Track ", out)

    def test_expired_fails_fast_without_request(self):
        out = self.assertFails(
            run(creds=make_blob(expires="2026-10-01T00:00:00Z")),
            f"create-track {SNAP}/v11.20: SNAPCRAFT_GATEWAY_CREDENTIALS expired on 2026-10-01",
            [],
        )
        self.assertIn(sct.RENEW, out)

    def test_near_expiry_warns_and_creates(self):
        rc, out, requests = run(creds=make_blob(expires="2026-11-06T05:00:00Z"))
        self.assertEqual((rc, [r.url.path for r in requests]), (0, [TRACKS]))
        self.assertIn("::warning::SNAPCRAFT_GATEWAY_CREDENTIALS expires in 12 days", out)

    def test_healthy_credential_prints_no_expiry_line(self):
        rc, out, _ = run()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("expires in", out)
        self.assertNotIn("::warning::", out)

    def test_unknown_expiry_still_creates(self):
        rc, out, requests = run(creds=make_blob(expires=None))
        self.assertEqual((rc, [r.url.path for r in requests]), (0, [TRACKS]))
        self.assertIn("::warning::SNAPCRAFT_GATEWAY_CREDENTIALS has no time-before caveat", out)

    def test_store_name_rule_400_is_reported(self):
        out = self.assertFails(
            run(tracks_resp=store_error(400, "'v1_' does not match '^[a-zA-Z0-9](?:[_.-]?[a-zA-Z0-9])*$' at /0/name")),
            f"create-track {SNAP}/v11.20 failed:",
            [TRACKS],
        )
        self.assertIn("does not match", out)

    def test_create_forbidden_gets_hint(self):
        out = self.assertFails(
            run(tracks_resp=store_error(403, "nope")), f"create-track {SNAP}/v11.20 failed:", [TRACKS]
        )
        self.assertIn("can't manage this snap's tracks", out)

    def test_unset_creds_fail_fast(self):
        self.assertFails(run(creds=None), "SNAPCRAFT_GATEWAY_CREDENTIALS is empty or unset", [])

    def test_blank_creds_fail_fast(self):
        self.assertFails(run(creds=" \n"), "SNAPCRAFT_GATEWAY_CREDENTIALS is empty or unset", [])

    def test_undecodable_creds_hide_content(self):
        out = self.assertFails(
            run(creds=base64.b64encode(b"\xffsecret-macaroon").decode()),
            "could not read SNAPCRAFT_GATEWAY_CREDENTIALS",
            [],
        )
        self.assertNotIn("secret-macaroon", out)

    def test_create_unreachable(self):
        self.assertFails(
            run(tracks_resp=httpx.ReadTimeout("slow")),
            f"create-track {SNAP}/v11.20: store unreachable (ReadTimeout)",
            [TRACKS],
        )

    def test_create_html_502(self):
        out = self.assertFails(run(tracks_resp=HTML_502), f"create-track {SNAP}/v11.20 failed:", [TRACKS])
        self.assertNotIn("can't manage", out)

    def test_invalid_track_name_skips_tracks_post(self):
        self.assertFails(run(track="v1-" + "x" * 30), f"create-track {SNAP}/v1-", [])

    def test_zero_created(self):
        self.assertFails(
            run(tracks_resp=httpx.Response(200, json={"num-tracks-created": 0})),
            f"create-track {SNAP}/v11.20 returned success but created no track",
            [TRACKS],
        )

    def test_create_null_error_list(self):
        out = self.assertFails(
            run(tracks_resp=httpx.Response(422, json={"error-list": None})),
            f"create-track {SNAP}/v11.20 failed: HTTP 422, unparseable error body",
            [TRACKS],
        )
        self.assertNotIn("Traceback", out)

    def test_multiline_store_error_stays_one_annotation(self):
        two = httpx.Response(
            500,
            json={"error-list": [{"code": "a", "message": "first"}, {"code": "b", "message": "second"}]},
        )
        rc, out, _ = run(tracks_resp=two)
        self.assertEqual(rc, 1, out)
        annotations = [line for line in out.splitlines() if line.startswith("::error::")]
        self.assertEqual(len(annotations), 1, out)
        self.assertIn("%0A- b: second", annotations[0])

    def test_server_error_has_no_auth_hint(self):
        out = self.assertFails(
            run(tracks_resp=store_error(500, "oops")), f"create-track {SNAP}/v11.20 failed:", [TRACKS]
        )
        self.assertNotIn("can't manage", out)

    def test_create_never_prints_the_macaroon(self):
        raw_token = json.loads(base64.b64decode(make_blob()))["v"]
        variants = (
            {},
            {"tracks_resp": store_error(403, "nope")},
            {"tracks_resp": HTML_502},
            {"creds": make_blob(expires="2026-10-01T00:00:00Z")},
            {"creds": make_blob(expires="2026-11-06T05:00:00Z")},
        )
        for kwargs in variants:
            with self.subTest(kwargs=sorted(kwargs)):
                _, out, _ = run(**kwargs)
                self.assertNotIn(raw_token, out)
                self.assertNotIn(kwargs.get("creds", make_blob()), out)


class CheckTest(unittest.TestCase):
    def test_check_ok_prints_plain_lines(self):
        rc, out, requests = run(argv=check_argv)
        self.assertEqual(rc, 0, out)
        self.assertEqual([r.url.path for r in requests], [WHOAMI])
        # The expected header is derived from the raw blob, not from the code under test.
        raw_token = json.loads(base64.b64decode(make_blob()))["v"]
        self.assertEqual(requests[0].headers["Authorization"], "Macaroon " + raw_token)
        self.assertIn("SNAPCRAFT_GATEWAY_CREDENTIALS expires in 364 days (2027-10-24)", out)
        self.assertIn("gateway accepts the credential (account giaever-online)", out)
        # Expiry first, so a slow gateway can't hide it.
        self.assertLess(out.index("expires in"), out.index("gateway accepts"))
        self.assertNotIn("::warning::", out)
        self.assertNotIn("::error::", out)

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
        self.assertIn(
            f"::error::gateway rejected SNAPCRAFT_GATEWAY_CREDENTIALS (HTTP 401: macaroon expired) — {sct.RENEW}", out
        )

    def test_check_whoami_403_is_error(self):
        rc, out, _ = run(argv=check_argv, whoami_resp=store_error(403, "forbidden"))
        self.assertEqual(rc, 0)
        self.assertIn(
            f"::error::gateway rejected SNAPCRAFT_GATEWAY_CREDENTIALS (HTTP 403: forbidden) — {sct.RENEW}", out
        )

    def test_check_whoami_without_username_still_ok(self):
        for body in (httpx.Response(200, json={}), httpx.Response(200, text="not json"), httpx.Response(200, json=[1])):
            rc, out, _ = run(argv=check_argv, whoami_resp=body)
            self.assertEqual(rc, 0, out)
            self.assertIn("gateway accepts the credential (account ?)", out)
            self.assertNotIn("::", out)

    def test_check_whoami_odd_username_is_question_mark(self):
        for username in (None, 42, "", ["a"], "line one\nline two", "cr\rhere"):
            with self.subTest(username=username):
                body = httpx.Response(200, json={"account": {"username": username}})
                rc, out, _ = run(argv=check_argv, whoami_resp=body)
                self.assertEqual(rc, 0, out)
                self.assertIn("gateway accepts the credential (account ?)", out)
                self.assertEqual(len([line for line in out.splitlines() if "gateway accepts" in line]), 1, out)

    def test_check_annotations_stay_one_line(self):
        rc, out, _ = run(argv=check_argv, whoami_resp=store_error(401, "line one\nline two 100%"))
        self.assertEqual(rc, 0)
        annotations = [line for line in out.splitlines() if line.startswith("::")]
        self.assertEqual(len(annotations), 1, out)
        self.assertIn("HTTP 401: line one%0Aline two 100%25)", annotations[0])

    def test_check_never_prints_the_macaroon(self):
        raw_token = json.loads(base64.b64decode(make_blob()))["v"]
        for kwargs in ({}, {"whoami_resp": store_error(401, "no")}, {"whoami_resp": HTML_502}):
            rc, out, _ = run(argv=check_argv, **kwargs)
            self.assertNotIn(raw_token, out)
            self.assertNotIn(make_blob(), out)

    def test_check_without_expiry_caveat_warns_and_still_asks_gateway(self):
        rc, out, requests = run(argv=check_argv, creds=make_blob(expires=None))
        self.assertEqual((rc, len(requests)), (0, 1))
        self.assertIn("::warning::SNAPCRAFT_GATEWAY_CREDENTIALS has no time-before caveat", out)

    def test_check_blank_is_warning_exit_zero(self):
        rc, out, requests = run(argv=check_argv, creds=" \n")
        self.assertEqual((rc, requests), (0, []))
        self.assertIn("::warning::SNAPCRAFT_GATEWAY_CREDENTIALS is not set in this context", out)

    def test_check_with_extra_args_is_usage(self):
        rc, out, requests = run(argv=["snap-create-track.py", "--check", "extra", "more"])
        self.assertEqual((rc, requests), (1, []))
        self.assertIn("usage: snap-create-track.py <snap-name> <track> | --check", out)

    def test_check_whoami_outage_is_warning(self):
        rc, out, _ = run(argv=check_argv, whoami_resp=httpx.ConnectError("down"))
        self.assertEqual(rc, 0)
        self.assertIn(
            "::warning::gateway whoami failed (ConnectError); credential not verified — not a credentials problem",
            out,
        )

    def test_check_whoami_502_is_warning(self):
        rc, out, _ = run(argv=check_argv, whoami_resp=HTML_502)
        self.assertEqual(rc, 0)
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


if __name__ == "__main__":
    unittest.main()
