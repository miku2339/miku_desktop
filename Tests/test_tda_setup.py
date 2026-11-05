import contextlib
from importlib.util import module_from_spec, spec_from_file_location
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs


SPEC = spec_from_file_location("tda_setup", Path(__file__).resolve().parents[1] / "scripts/import-tda-model.py")
setup = module_from_spec(SPEC)
SPEC.loader.exec_module(setup)
AUTHOR_ARCHIVE = Path(os.environ.get("MIKU_TDA_ARCHIVE", Path.home() / "Downloads" / setup.ARCHIVE_NAME))


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return io.BytesIO(response)


def author_page(control="permission", key="false"):
    return f'<div id="initialize" data-download_control="{control}" data-download_key="{key}" data-csrf_token="temporary-csrf">'.encode()


class TdaSetupTests(unittest.TestCase):
    def test_network_flow_uses_author_form_and_escapes_unicode_path(self):
        fake = FakeOpener([
            author_page(),
            json.dumps({"status": "success", "url": "https://bowlroll.net/download/初音.zip"}).encode(),
            b"archive fixture",
        ])
        with patch.object(setup, "checked_archive", side_effect=lambda value: value):
            self.assertEqual(setup.download_archive(fake), b"archive fixture")
        self.assertEqual(fake.requests[1].full_url, setup.DOWNLOAD_CHECK_URL)
        self.assertEqual(parse_qs(fake.requests[1].data.decode()), {
            "download_key": ["bowlroll_download_control_mischievous"], "csrf_token": ["temporary-csrf"],
        })
        self.assertNotIn("初音", fake.requests[2].full_url)
        self.assertEqual(fake.requests[1].get_header("Origin"), "https://bowlroll.net")

    def test_page_requiring_password_does_not_submit_download_check(self):
        fake = FakeOpener([author_page(key="true")])
        with self.assertRaises(setup.ModelSetupError):
            setup.download_archive(fake)
        self.assertEqual(len(fake.requests), 1)

    def test_changed_page_does_not_guess_download_details(self):
        fake = FakeOpener([b"<html>Sign in</html>"])
        with self.assertRaises(setup.ModelSetupError):
            setup.download_archive(fake)
        self.assertEqual(len(fake.requests), 1)

    def test_non_object_author_response_is_rejected(self):
        fake = FakeOpener([author_page(), b"[]"])
        with self.assertRaises(setup.ModelSetupError):
            setup.download_archive(fake)
        self.assertEqual(len(fake.requests), 2)

    def test_unofficial_download_host_is_never_requested(self):
        fake = FakeOpener([
            author_page(), json.dumps({"status": "success", "url": "https://example.org/model.zip"}).encode(),
        ])
        with self.assertRaises(setup.ModelSetupError):
            setup.download_archive(fake)
        self.assertEqual(len(fake.requests), 2)

    def test_redirects_reject_http_credentials_and_unofficial_hosts(self):
        for value in ["http://bowlroll.net/file", "https://other.bowlroll.net/file", "https://user:secret@bowlroll.net/file"]:
            with self.subTest(value=value), self.assertRaises(setup.ModelSetupError):
                setup.official_url(value)
        self.assertEqual(setup.official_url("https://storage-file-download-common.bowlroll.cloud/storage/valid"),
                         "https://storage-file-download-common.bowlroll.cloud/storage/valid")

    def test_access_failure_does_not_log_signed_download_url(self):
        secret = "https://storage-file-download-common.bowlroll.cloud/storage/private-session-token"
        fake = FakeOpener([author_page(), HTTPError(secret, 403, "forbidden", {}, None)])
        with self.assertRaises(setup.ModelSetupError) as failure:
            setup.download_archive(fake)
        self.assertIn("HTTP 403", str(failure.exception))
        self.assertNotIn("private-session-token", str(failure.exception))
        self.assertNotIn("temporary-csrf", str(failure.exception))

    def test_download_bound_and_bad_hash_are_rejected(self):
        with self.assertRaises(setup.ModelSetupError):
            setup.read_bounded(io.BytesIO(b"12345"), 4)
        with self.assertRaises(setup.ModelSetupError):
            setup.checked_archive(b"not the original zip")

    def test_wrong_archive_preserves_existing_model_and_leaves_no_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "tda"
            destination.mkdir()
            (destination / "existing").write_bytes(b"keep")
            invalid = root / "bad.zip"
            invalid.write_bytes(b"invalid")
            with self.assertRaises(setup.ModelSetupError):
                setup.import_archive(invalid, destination)
            self.assertEqual((destination / "existing").read_bytes(), b"keep")
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["bad.zip", "tda"])

    @unittest.skipUnless(AUTHOR_ARCHIVE.is_file(), "author original ZIP not supplied")
    def test_original_import_reuse_and_repair(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            root = Path(temporary)
            destination = root / "models" / "tda"
            setup.import_archive(AUTHOR_ARCHIVE, destination)
            self.assertTrue(setup.is_ready(destination))
            self.assertEqual(set(path.name for path in destination.iterdir()), set(setup.ASSET_SHA256))
            with patch.object(setup, "download_archive", side_effect=AssertionError("unexpected network")):
                setup.configure(destination, downloads=root / "absent")
            self.assertEqual(list(destination.parent.iterdir()), [destination])
            (destination / "hair_MikuAp.png").write_bytes(b"corrupt")
            self.assertFalse(setup.is_ready(destination))
            setup.import_archive(AUTHOR_ARCHIVE, destination)
            self.assertTrue(setup.is_ready(destination))

    @unittest.skipUnless(AUTHOR_ARCHIVE.is_file(), "author original ZIP not supplied")
    def test_downloads_original_reused_without_network(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()):
            root = Path(temporary)
            downloads = root / "Downloads"
            downloads.mkdir()
            (downloads / setup.ARCHIVE_NAME).symlink_to(AUTHOR_ARCHIVE)
            with patch.object(setup, "download_archive", side_effect=AssertionError("unexpected network")):
                setup.configure(root / "tda", downloads=downloads)
            self.assertTrue(setup.is_ready(root / "tda"))

    @unittest.skipUnless(AUTHOR_ARCHIVE.is_file(), "author original ZIP not supplied")
    def test_failed_replacement_restores_previous_model(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "tda"
            setup.import_archive(AUTHOR_ARCHIVE, destination)
            original_replace = setup.os.replace

            def fail_new_model(source, target):
                if Path(source).name == "model":
                    raise OSError("simulated replacement failure")
                return original_replace(source, target)

            with patch.object(setup.os, "replace", side_effect=fail_new_model), self.assertRaises(OSError):
                setup.import_archive(AUTHOR_ARCHIVE, destination)
            self.assertTrue(setup.is_ready(destination))
            self.assertEqual(list(destination.parent.iterdir()), [destination])

    @unittest.skipUnless(AUTHOR_ARCHIVE.is_file(), "author original ZIP not supplied")
    def test_rollback_failure_preserves_the_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "tda"
            setup.import_archive(AUTHOR_ARCHIVE, destination)
            original_replace = setup.os.replace

            def fail_after_backup(source, target):
                if Path(target) == destination:
                    raise OSError("simulated destination failure")
                return original_replace(source, target)

            with patch.object(setup.os, "replace", side_effect=fail_after_backup), self.assertRaises(OSError):
                setup.import_archive(AUTHOR_ARCHIVE, destination)
            backups = list(Path(temporary).glob(".tda-import-*-previous"))
            self.assertEqual(len(backups), 1)
            self.assertTrue(setup.is_ready(backups[0]))


if __name__ == "__main__":
    unittest.main()
