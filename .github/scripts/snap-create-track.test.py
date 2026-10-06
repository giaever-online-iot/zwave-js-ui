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

EXCHANGE = "/v1/tokens/dashboard/exchange"
TRACKS = "/v1/snap/zwave-js-ui/tracks"
EX_OK = httpx.Response(200, json={"macaroon": "tok"})
CREATED = httpx.Response(201, json={"num-tracks-created": 1})


def run(track="v11.20", creds=CREDS, exchange=EX_OK, tracks=CREATED, argv=None):
    """Run main() against a fake store; return (rc, stdout+stderr, paths requested).

    A response may be an exception instance, which the fake transport raises instead.
    """
    seen = []

    def handler(request):
        seen.append(request.url.path)
        answer = {EXCHANGE: exchange, TRACKS: tracks}[request.url.path]
        if isinstance(answer, Exception):
            raise answer
        return answer

    real_client = httpx.Client
    env = {} if creds is None else {"SNAPCRAFT_STORE_CREDENTIALS": creds}
    out = io.StringIO()
    with (
        mock.patch.object(httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(handler), **kw)),
        mock.patch.dict("os.environ", env, clear=True),
        contextlib.redirect_stdout(out),
        contextlib.redirect_stderr(out),
    ):
        rc = sct.main(argv or ["snap-create-track.py", "zwave-js-ui", track])
    return rc, out.getvalue(), seen


class CreateTrackTest(unittest.TestCase):
    def assertFails(self, result, message, seen):
        rc, out, paths = result
        self.assertEqual(rc, 1, out)
        self.assertIn(f"::error::{message}", out)
        self.assertEqual(paths, seen)

    def test_creates_track(self):
        requests = []
        real_handler = httpx.MockTransport.handle_request

        def spy(transport, request):
            requests.append(request)
            return real_handler(transport, request)

        with mock.patch.object(httpx.MockTransport, "handle_request", spy):
            rc, out, seen = run()
        self.assertEqual(rc, 0, out)
        self.assertEqual(seen, [EXCHANGE, TRACKS])
        self.assertIn("::add-mask::tok", out)
        self.assertIn("num-tracks-created=1", out)
        ex, post = requests
        self.assertTrue(ex.headers["Authorization"].startswith("macaroon root="))
        self.assertEqual(post.headers["Authorization"], "Macaroon tok")
        self.assertEqual(json.loads(post.content), [{"name": "v11.20"}])

    def test_existing_track_is_success(self):
        rc, out, seen = run(tracks=httpx.Response(409, json={"error-list": [{"code": "x", "message": "exists"}]}))
        self.assertEqual((rc, seen), (0, [EXCHANGE, TRACKS]), out)
        self.assertIn("already exists", out)

    def test_usage(self):
        rc, out, seen = run(argv=["snap-create-track.py"])
        self.assertEqual((rc, seen), (1, []))
        self.assertIn("usage:", out)

    def test_unset_creds_fail_fast(self):
        self.assertFails(run(creds=None), "SNAPCRAFT_STORE_CREDENTIALS is empty", [])

    def test_blank_creds_fail_fast(self):
        self.assertFails(run(creds=" \n"), "SNAPCRAFT_STORE_CREDENTIALS is empty", [])

    def test_unreadable_creds_hide_content(self):
        secret = base64.b64encode(b"\xffsecret-macaroon").decode()
        rc, out, seen = run(creds=secret)
        self.assertFails((rc, out, seen), "could not read SNAPCRAFT_STORE_CREDENTIALS", [])
        self.assertNotIn("secret-macaroon", out)

    def test_exchange_rejected(self):
        rc, out, seen = run(
            exchange=httpx.Response(401, json={"error-list": [{"code": "x", "message": "bad macaroon"}]})
        )
        self.assertFails((rc, out, seen), "token exchange failed (HTTP 401: bad macaroon)", [EXCHANGE])

    def test_exchange_without_token_hides_body(self):
        rc, out, seen = run(exchange=httpx.Response(200, json={"token": "leak-me"}))
        self.assertFails((rc, out, seen), "token exchange failed (HTTP 200", [EXCHANGE])
        self.assertNotIn("leak-me", out)

    def test_exchange_non_json(self):
        self.assertFails(
            run(exchange=httpx.Response(200, text="<html>")), "token exchange: unparseable response", [EXCHANGE]
        )

    def test_exchange_unreachable(self):
        self.assertFails(
            run(exchange=httpx.ConnectError("down")), "token exchange: store unreachable (ConnectError)", [EXCHANGE]
        )

    def test_create_unreachable(self):
        self.assertFails(
            run(tracks=httpx.ReadTimeout("slow")),
            "create-track zwave-js-ui/v11.20: store unreachable",
            [EXCHANGE, TRACKS],
        )

    def test_invalid_track_name_never_posts(self):
        self.assertFails(run(track="v1-" + "x" * 30), "create-track zwave-js-ui/v1-", [EXCHANGE])

    def test_zero_created(self):
        rc, out, seen = run(tracks=httpx.Response(200, json={"num-tracks-created": 0}))
        self.assertFails(
            (rc, out, seen), "create-track zwave-js-ui/v11.20 returned success but created no track", [EXCHANGE, TRACKS]
        )

    def test_unauthorized_gets_hint(self):
        rc, out, seen = run(tracks=httpx.Response(403, json={"error-list": [{"code": "x", "message": "nope"}]}))
        self.assertFails((rc, out, seen), "create-track zwave-js-ui/v11.20 failed:", [EXCHANGE, TRACKS])
        self.assertIn("can't manage this snap's tracks", out)

    def test_server_error_has_no_auth_hint(self):
        rc, out, seen = run(tracks=httpx.Response(500, json={"error-list": [{"code": "x", "message": "oops"}]}))
        self.assertFails((rc, out, seen), "create-track zwave-js-ui/v11.20 failed:", [EXCHANGE, TRACKS])
        self.assertNotIn("can't manage", out)


if __name__ == "__main__":
    unittest.main()
