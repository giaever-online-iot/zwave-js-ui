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

EX_OK = (200, {"macaroon": "tok"})


def run(track="v11.20", creds=CREDS, exchange=EX_OK, tracks=(201, {"num-tracks-created": 1})):
    """Run main() against a fake store; return (rc, stdout+stderr, requests seen)."""
    seen = []

    def handler(request):
        seen.append(request)
        code, body = exchange if request.url.path.endswith("/dashboard/exchange") else tracks
        return httpx.Response(code, json=body)

    real_client = httpx.Client
    out = io.StringIO()
    with mock.patch.object(
        httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(handler), **kw)
    ), mock.patch.dict("os.environ", {"SNAPCRAFT_STORE_CREDENTIALS": creds}), contextlib.redirect_stdout(
        out
    ), contextlib.redirect_stderr(out):
        rc = sct.main(["snap-create-track.py", "zwave-js-ui", track])
    return rc, out.getvalue(), seen


class CreateTrackTest(unittest.TestCase):
    def test_creates_track(self):
        rc, out, seen = run()
        self.assertEqual(rc, 0, out)
        self.assertIn("num-tracks-created=1", out)
        ex, post = seen
        self.assertTrue(ex.headers["Authorization"].startswith("macaroon root="))
        self.assertEqual(post.url.path, "/v1/snap/zwave-js-ui/tracks")
        self.assertEqual(post.headers["Authorization"], "Macaroon tok")
        self.assertEqual(json.loads(post.content), [{"name": "v11.20"}])

    def test_empty_creds_fail_fast(self):
        rc, out, seen = run(creds=" \n")
        self.assertEqual((rc, seen), (1, []))
        self.assertIn("SNAPCRAFT_STORE_CREDENTIALS is empty", out)

    def test_unreadable_creds(self):
        rc, out, seen = run(creds="not-base64-json")
        self.assertEqual((rc, seen), (1, []))
        self.assertIn("could not read SNAPCRAFT_STORE_CREDENTIALS", out)

    def test_exchange_rejected(self):
        rc, out, _ = run(exchange=(401, {"error-list": []}))
        self.assertEqual(rc, 1)
        self.assertIn("token exchange failed (HTTP 401)", out)

    def test_exchange_without_token(self):
        rc, out, _ = run(exchange=(200, {}))
        self.assertEqual(rc, 1)
        self.assertIn("token exchange failed (HTTP 200)", out)

    def test_invalid_track_name_never_posts(self):
        rc, out, seen = run(track="v1-" + "x" * 30)
        self.assertEqual(rc, 1)
        self.assertIn("track names are invalid", out)
        self.assertEqual(len(seen), 1)  # exchange only

    def test_zero_created(self):
        rc, out, _ = run(tracks=(200, {"num-tracks-created": 0}))
        self.assertEqual(rc, 1)
        self.assertIn("created no track", out)

    def test_unauthorized(self):
        rc, out, _ = run(tracks=(403, {"error-list": [{"code": "forbidden", "message": "nope"}]}))
        self.assertEqual(rc, 1)
        self.assertIn("Error 403 returned from store: nope", out)

    def test_server_error(self):
        rc, out, _ = run(tracks=(500, {"error-list": [{"code": "boom", "message": "oops"}]}))
        self.assertEqual(rc, 1)
        self.assertIn("Store had an error (500): oops", out)


if __name__ == "__main__":
    unittest.main()
