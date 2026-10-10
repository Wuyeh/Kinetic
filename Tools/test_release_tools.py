"""Release command regression checks; no signing keys, network or user data."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class ReleaseToolsTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="release-tools-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.tools = self.root / "Tools" / "UpdateRelease"
        self.tools.mkdir(parents=True)
        self.script = self.tools / "build_release.sh"
        shutil.copy2(ROOT / "Tools/UpdateRelease/build_release.sh", self.script)
        (self.root / "Kinetic.xcodeproj").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.record = self.root / "arguments.json"
        mock = self.bin / "xcodebuild"
        mock.write_text("#!/usr/bin/python3\nimport json,os,sys\n"
                        "with open(os.environ['KINETIC_QA_ARGUMENTS'], 'w') as f: json.dump(sys.argv[1:], f)\n"
                        "sys.exit(1)\n")
        mock.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        KINETIC_QA_ARGUMENTS=str(self.record))

    def run_build(self, *arguments):
        return subprocess.run(["/bin/zsh", str(self.script), str(self.root / "output"), *arguments],
                              env=self.env, text=True, capture_output=True)

    def test_missing_option_values_are_rejected_before_build(self):
        for option in ("--feed", "--notary-profile", "--derived-data"):
            with self.subTest(option=option):
                result = self.run_build(option)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertFalse(self.record.exists())

    def test_invalid_feed_and_notary_without_developer_id_do_not_build(self):
        for arguments in (("--feed", "http://example.invalid/appcast.xml"),
                          ("--notary-profile", "test-profile")):
            with self.subTest(arguments=arguments):
                result = self.run_build(*arguments)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertFalse(self.record.exists())

    def test_checkout_project_is_used_without_private_workspace(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 1)  # Deliberate mock failure must stop packaging.
        arguments = json.loads(self.record.read_text())
        self.assertEqual(arguments[arguments.index("-project") + 1], str(self.root / "Kinetic.xcodeproj"))
        self.assertNotIn("-workspace", arguments)
        self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1],
                         str(self.root / ".build/DerivedData-Merged"))
        self.assertIn("ARCHS=arm64", arguments)
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", arguments)
        self.assertFalse((self.root / "output/Kinetic.app").exists())

    def test_explicit_cache_and_developer_id_are_passed_to_build(self):
        cache = self.root / "alternate-cache"
        result = self.run_build("--derived-data", str(cache), "--developer-id")
        self.assertEqual(result.returncode, 1)
        arguments = json.loads(self.record.read_text())
        self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1], str(cache))
        self.assertIn("CODE_SIGN_IDENTITY=Developer ID Application", arguments)
        self.assertIn("OTHER_CODE_SIGN_FLAGS=--timestamp", arguments)

    def test_release_check_without_app_has_clear_usage(self):
        result = subprocess.run(["/bin/zsh", str(ROOT / "Tools/release_check.sh")],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 64)
        self.assertIn("用法", result.stderr)


if __name__ == "__main__":
    unittest.main()
