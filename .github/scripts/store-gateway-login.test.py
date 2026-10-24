"""Offline unit tests for store-gateway-login.py. Fakes craft-store's StoreClient; no network, no browser."""

import contextlib
import importlib.util
import io
import os
import pathlib
import shlex
import stat
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "store_gateway_login", pathlib.Path(__file__).with_name("store-gateway-login.py")
)
sgl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sgl)

GH_SET = "  gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS --repo giaever-online-iot/zwave-js-ui < "


def fake_client(calls):
    class FakeClient:
        def __init__(self, **kw):
            calls["init"] = kw

        def login(self, **kw):
            calls["login"] = kw
            return "BLOB-NEVER-PRINTED"

    return FakeClient


def run_main(path, calls):
    """Run main() against the fake client; returns (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.object(sgl, "StoreClient", fake_client(calls)), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = sgl.main(["store-gateway-login.py", path])
    return code, out.getvalue(), err.getvalue()


class LoginHelperTest(unittest.TestCase):
    def test_login_reproduces_verified_parameters_and_writes_0600(self):
        calls = {}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "gateway.creds")
            code, out, _ = run_main(path, calls)
            self.assertEqual(code, 0)
            self.assertEqual(pathlib.Path(path).read_text(), "BLOB-NEVER-PRINTED")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(
            calls["init"],
            {
                "base_url": "https://api.charmhub.io",
                "storage_base_url": "https://storage.snapcraftcontent.com",
                "endpoints": sgl.endpoints.CHARMHUB,
                "application_name": "zwave-js-ui-ci",
                "user_agent": "zwave-js-ui-ci/1.0",
                "ephemeral": True,
            },
        )
        self.assertEqual(
            calls["login"],
            {
                "permissions": ["package-manage", "package-view"],
                "description": "zwave-js-ui CI: create version tracks",
                "ttl": 31536000,
            },
        )
        lines = out.splitlines()
        self.assertEqual(lines[0], "Starting the Candid login; craft-store prints the URL to open (tap it on your phone and sign in with Ubuntu One).")
        self.assertEqual(lines[1], f"Credential written to {path} (0600; valid 365 days). Set the repo secret with:")
        self.assertEqual(lines[2], GH_SET + shlex.quote(path))
        self.assertEqual(len(lines), 3)
        self.assertNotIn("BLOB-NEVER-PRINTED", out)

    def test_printed_command_quotes_a_path_with_spaces(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "gateway creds")
            self.assertNotEqual(shlex.quote(path), path)  # the case that makes quoting matter
            code, out, _ = run_main(path, {})
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines()[2], GH_SET + shlex.quote(path))

    def test_overwrite_replaces_content_and_tightens_mode(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "gateway.creds")
            pathlib.Path(path).write_text("OLD-CONTENT-LONGER-THAN-THE-NEW-BLOB")
            os.chmod(path, 0o644)
            with sgl.open_credential(path) as f:
                f.write("NEW")
            self.assertEqual(pathlib.Path(path).read_text(), "NEW")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_file_is_created_owner_only(self):
        # With the chmod disabled, only the mode passed at creation protects the blob.
        with tempfile.TemporaryDirectory() as d, mock.patch.object(sgl.os, "fchmod"):
            path = os.path.join(d, "gateway.creds")
            old_umask = os.umask(0)
            try:
                with sgl.open_credential(path) as f:
                    f.write("BLOB")
            finally:
                os.umask(old_umask)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_unwritable_path_fails_before_the_login(self):
        calls = {}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "missing-dir", "gateway.creds")
            code, out, err = run_main(path, calls)
        self.assertEqual(code, 1)
        self.assertNotIn("init", calls)  # the client was never built, so no login prompt
        self.assertEqual(out, "")
        self.assertIn(path, err)

    def test_usage(self):
        out = io.StringIO()
        with contextlib.redirect_stderr(out):
            self.assertEqual(sgl.main(["store-gateway-login.py"]), 2)
        self.assertIn("usage:", out.getvalue())


if __name__ == "__main__":
    unittest.main()
