"""Offline unit tests for store-gateway-login.py. Fakes craft-store's StoreClient; no network, no browser."""

import contextlib
import importlib.util
import io
import os
import pathlib
import stat
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "store_gateway_login", pathlib.Path(__file__).with_name("store-gateway-login.py")
)
sgl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sgl)


class LoginHelperTest(unittest.TestCase):
    def test_login_reproduces_verified_parameters_and_writes_0600(self):
        calls = {}

        class FakeClient:
            def __init__(self, **kw):
                calls["init"] = kw

            def login(self, **kw):
                calls["login"] = kw
                return "BLOB-NEVER-PRINTED"

        out = io.StringIO()
        with tempfile.TemporaryDirectory() as d, mock.patch.object(sgl, "StoreClient", FakeClient), contextlib.redirect_stdout(out):
            path = os.path.join(d, "gateway.creds")
            self.assertEqual(sgl.main(["store-gateway-login.py", path]), 0)
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
        self.assertIn("gh secret set SNAPCRAFT_GATEWAY_CREDENTIALS --repo giaever-online-iot/zwave-js-ui < ", out.getvalue())
        self.assertNotIn("BLOB-NEVER-PRINTED", out.getvalue())

    def test_overwrite_replaces_content_and_tightens_mode(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "gateway.creds")
            pathlib.Path(path).write_text("OLD-CONTENT-LONGER-THAN-THE-NEW-BLOB")
            os.chmod(path, 0o644)
            sgl.write_credential(path, "NEW")
            self.assertEqual(pathlib.Path(path).read_text(), "NEW")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_file_is_created_owner_only(self):
        # With the chmod disabled, only the mode passed at creation protects the blob.
        with tempfile.TemporaryDirectory() as d, mock.patch.object(sgl.os, "fchmod"):
            path = os.path.join(d, "gateway.creds")
            old_umask = os.umask(0)
            try:
                sgl.write_credential(path, "BLOB")
            finally:
                os.umask(old_umask)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_usage(self):
        out = io.StringIO()
        with contextlib.redirect_stderr(out):
            self.assertEqual(sgl.main(["store-gateway-login.py"]), 2)
        self.assertIn("usage:", out.getvalue())


if __name__ == "__main__":
    unittest.main()
