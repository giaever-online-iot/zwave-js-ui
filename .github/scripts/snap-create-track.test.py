"""Offline unit tests for snap-create-track.py. Fakes the store over httpx; no network."""

import base64
import contextlib
import importlib.util
import io
import json
import pathlib
import unittest
from unittest import mock

import httpx
from pymacaroons import Macaroon

spec = importlib.util.spec_from_file_location(
    "snap_create_track", pathlib.Path(__file__).with_name("snap-create-track.py")
)
sct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sct)

_root = Macaroon(location="dashboard.snapcraft.io", identifier="root", key="root-key")
_root.add_third_party_caveat("login.ubuntu.com", "caveat-key", "caveat-id")
_discharge = Macaroon(location="login.ubuntu.com", identifier="caveat-id", key="caveat-key")
CREDS = base64.b64encode(
    json.dumps({"t": "u1-macaroon", "v": {"r": _root.serialize(), "d": _discharge.serialize()}}).encode()
).decode()
BOUND_DISCHARGE = _root.prepare_for_request(_discharge).serialize()

EXCHANGE = "/v1/tokens/dashboard/exchange"
TRACKS = "/v1/snap/zwave-js-ui/tracks"
EX_OK = httpx.Response(200, json={"macaroon": "tok"})
CREATED = httpx.Response(201, json={"num-tracks-created": 1})
HTML_502 = httpx.Response(502, text="<html>Bad Gateway</html>")


def store_error(status, message):
    return httpx.Response(status, json={"error-list": [{"code": "x", "message": message}]})


def _no_network(*_args, **_kwargs):
    raise AssertionError("a request bypassed the fake store")


def run(track="v11.20", creds=CREDS, exchange_resp=EX_OK, tracks_resp=CREATED, argv=None):
    """Run main() against a fake store; return (rc, stdout+stderr, requests made).

    A response may be an exception instance, which the fake transport raises instead.
    """
    requests = []

    def handler(request):
        requests.append(request)
        answer = {EXCHANGE: exchange_resp, TRACKS: tracks_resp}[request.url.path]
        if isinstance(answer, Exception):
            raise answer
        return answer

    real_client = httpx.Client
    env = {} if creds is None else {"SNAPCRAFT_STORE_CREDENTIALS": creds}
    out = io.StringIO()
    with (
        mock.patch.object(httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(handler), **kw)),
        # If craft-store ever builds its client another way, fail instead of reaching the real store.
        mock.patch.object(httpx.HTTPTransport, "handle_request", _no_network),
        mock.patch.dict("os.environ", env, clear=True),
        contextlib.redirect_stdout(out),
        contextlib.redirect_stderr(out),
    ):
        rc = sct.main(argv or ["snap-create-track.py", "zwave-js-ui", track])
    return rc, out.getvalue(), requests


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
        self.assertEqual([r.url.path for r in requests], [EXCHANGE, TRACKS])
        self.assertIn("::add-mask::tok", out)
        self.assertIn("num-tracks-created=1", out)
        ex, post = requests
        self.assertEqual(ex.headers["Authorization"], f"macaroon root={_root.serialize()}, discharge={BOUND_DISCHARGE}")
        self.assertEqual(post.headers["Authorization"], "Macaroon tok")
        self.assertEqual(json.loads(post.content), [{"name": "v11.20"}])

    def test_existing_track_is_success(self):
        rc, out, requests = run(tracks_resp=store_error(409, "exists"))
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(requests), 2)
        self.assertIn("already exists", out)

    def test_usage(self):
        rc, out, requests = run(argv=["snap-create-track.py"])
        self.assertEqual((rc, requests), (1, []))
        self.assertIn("usage:", out)

    def test_unset_creds_fail_fast(self):
        self.assertFails(run(creds=None), "SNAPCRAFT_STORE_CREDENTIALS is empty", [])

    def test_blank_creds_fail_fast(self):
        self.assertFails(run(creds=" \n"), "SNAPCRAFT_STORE_CREDENTIALS is empty", [])

    def test_undecodable_creds_hide_content(self):
        out = self.assertFails(
            run(creds=base64.b64encode(b"\xffsecret-macaroon").decode()),
            "could not read SNAPCRAFT_STORE_CREDENTIALS",
            [],
        )
        self.assertNotIn("secret-macaroon", out)

    def test_malformed_macaroon(self):
        creds = base64.b64encode(json.dumps({"v": {"r": "!!!!", "d": "!!!!"}}).encode()).decode()
        self.assertFails(
            run(creds=creds),
            "could not read SNAPCRAFT_STORE_CREDENTIALS — expected the output of `snapcraft export-login` (IndexError)",
            [],
        )

    def test_exchange_rejected_blames_credentials(self):
        self.assertFails(
            run(exchange_resp=store_error(401, "bad macaroon")),
            "token exchange rejected (HTTP 401: bad macaroon) — SNAPCRAFT_STORE_CREDENTIALS is invalid",
            [EXCHANGE],
        )

    def test_exchange_outage_does_not_blame_credentials(self):
        out = self.assertFails(
            run(exchange_resp=HTML_502), "token exchange: store error (HTTP 502: unparseable body)", [EXCHANGE]
        )
        self.assertNotIn("SNAPCRAFT_STORE_CREDENTIALS", out)

    def test_exchange_null_error_list(self):
        self.assertFails(
            run(exchange_resp=httpx.Response(503, json={"error-list": None})),
            "token exchange: store error (HTTP 503: no error-list)",
            [EXCHANGE],
        )

    def test_exchange_without_token_hides_body(self):
        out = self.assertFails(
            run(exchange_resp=httpx.Response(200, json={"token": "leak-me"})),
            "token exchange returned no token (HTTP 200)",
            [EXCHANGE],
        )
        self.assertNotIn("leak-me", out)

    def test_exchange_non_json(self):
        self.assertFails(
            run(exchange_resp=httpx.Response(200, text="<html>")),
            "token exchange: unparseable response (HTTP 200)",
            [EXCHANGE],
        )

    def test_exchange_unreachable(self):
        self.assertFails(
            run(exchange_resp=httpx.ConnectError("down")),
            "token exchange: store unreachable (ConnectError)",
            [EXCHANGE],
        )

    def test_create_unreachable(self):
        self.assertFails(
            run(tracks_resp=httpx.ReadTimeout("slow")),
            "create-track zwave-js-ui/v11.20: store unreachable (ReadTimeout)",
            [EXCHANGE, TRACKS],
        )

    def test_create_html_502(self):
        out = self.assertFails(run(tracks_resp=HTML_502), "create-track zwave-js-ui/v11.20 failed:", [EXCHANGE, TRACKS])
        self.assertNotIn("can't manage", out)

    def test_invalid_track_name_never_posts(self):
        self.assertFails(run(track="v1-" + "x" * 30), "create-track zwave-js-ui/v1-", [EXCHANGE])

    def test_zero_created(self):
        self.assertFails(
            run(tracks_resp=httpx.Response(200, json={"num-tracks-created": 0})),
            "create-track zwave-js-ui/v11.20 returned success but created no track",
            [EXCHANGE, TRACKS],
        )

    def test_unauthorized_gets_hint(self):
        out = self.assertFails(
            run(tracks_resp=store_error(403, "nope")), "create-track zwave-js-ui/v11.20 failed:", [EXCHANGE, TRACKS]
        )
        self.assertIn("can't manage this snap's tracks", out)

    def test_server_error_has_no_auth_hint(self):
        out = self.assertFails(
            run(tracks_resp=store_error(500, "oops")), "create-track zwave-js-ui/v11.20 failed:", [EXCHANGE, TRACKS]
        )
        self.assertNotIn("can't manage", out)


if __name__ == "__main__":
    unittest.main()
