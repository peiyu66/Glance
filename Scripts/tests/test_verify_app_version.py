import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-app-version.py"
spec = importlib.util.spec_from_file_location("verify_app_version", SCRIPT)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class VersionMetadataTests(unittest.TestCase):
    def valid_info(self):
        return {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}

    def check(self, info):
        verifier.validate_info(info, "0.1.0", "1")

    def test_accepts_current_and_later_builds(self):
        self.check(self.valid_info())
        verifier.validate_info(
            {"CFBundleShortVersionString": "0.2.3", "CFBundleVersion": "12"},
            "0.2.3", "12",
        )

    def test_rejects_each_missing_key_including_original_artifact(self):
        for removed in [("CFBundleVersion",), ("CFBundleShortVersionString",),
                        ("CFBundleVersion", "CFBundleShortVersionString")]:
            with self.subTest(removed=removed):
                info = self.valid_info()
                for key in removed:
                    del info[key]
                with self.assertRaises(ValueError):
                    self.check(info)

    def test_rejects_empty_nonstring_and_unexpanded_values(self):
        for key in self.valid_info():
            for value in ["", " ", 1, True, None, "$(MARKETING_VERSION)"]:
                with self.subTest(key=key, value=value):
                    info = self.valid_info()
                    info[key] = value
                    with self.assertRaises(ValueError):
                        self.check(info)

    def test_rejects_invalid_formats(self):
        for key, values in {
            "CFBundleShortVersionString": ["0.1", "0.1.0.1", "v0.1.0", "00.1.0", "０.1.0"],
            "CFBundleVersion": ["0", "-1", "01", "1.0", "1b1", "1\n"],
        }.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    info = self.valid_info()
                    info[key] = value
                    with self.assertRaises(ValueError):
                        self.check(info)

    def test_rejects_valid_but_mismatched_values(self):
        for key, value in [("CFBundleShortVersionString", "0.1.1"), ("CFBundleVersion", "2")]:
            with self.subTest(key=key):
                info = self.valid_info()
                info[key] = value
                with self.assertRaises(ValueError):
                    self.check(info)

    def test_rejects_invalid_expected_settings_and_plist_root(self):
        for version, build in [("", "1"), ("0.1.0", ""), ("0.1", "1"), ("0.1.0", "0")]:
            with self.subTest(version=version, build=build):
                with self.assertRaises(ValueError):
                    verifier.validate_info(self.valid_info(), version, build)
        with self.assertRaises(ValueError):
            self.check([])

    def test_cli_reads_xml_and_binary_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "Info.plist"
            command = [sys.executable, "-B", str(SCRIPT), str(path),
                       "--expected-version", "0.1.0", "--expected-build", "1"]
            for fmt in [plistlib.FMT_XML, plistlib.FMT_BINARY]:
                with self.subTest(format=fmt):
                    path.write_bytes(plistlib.dumps(self.valid_info(), fmt=fmt))
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
            for content in [b"not a plist", plistlib.dumps({}), None]:
                with self.subTest(content=content):
                    if content is None:
                        path.unlink()
                    else:
                        path.write_bytes(content)
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("error: Glance version metadata:", result.stderr)


if __name__ == "__main__":
    unittest.main()
