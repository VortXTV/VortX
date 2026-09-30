import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-android-release-version.sh"


class AndroidReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("full.apk", "play.apk", "play.aab", "bundletool.jar"):
            (self.root / name).write_bytes(b"fixture")
        aapt = self.root / "aapt2"
        aapt.write_text("#!/bin/sh\nprintf '%s\\n' \"package: name='${FIXTURE_PACKAGE:-com.vortx.android}' versionCode='${FIXTURE_CODE:-238}' versionName='${FIXTURE_NAME:-0.4.0}' platformBuildVersionName='fixture'\"\n")
        aapt.chmod(0o755)
        java = self.root / "java"
        java.write_text("#!/bin/sh\ncase \"$*\" in\n*versionCode*) printf '%s\\n' \"${FIXTURE_BUNDLE_CODE:-238}\";;\n*versionName*) printf '%s\\n' \"${FIXTURE_BUNDLE_NAME:-0.4.0}\";;\n*package*) printf '%s\\n' \"${FIXTURE_BUNDLE_PACKAGE:-com.vortx.android}\";;\n*) exit 1;;\nesac\n")
        java.chmod(0o755)
        self.env = {**os.environ, "AAPT2_BIN": str(aapt), "JAVA_BIN": str(java), "BUNDLETOOL_JAR": str(self.root / "bundletool.jar")}

    def run_verifier(self, code="238", name="0.4.0", files=None, **env):
        paths = files if files is not None else ["full.apk", "play.apk", "play.aab"]
        return subprocess.run(["bash", str(SCRIPT), code, name, *[str(self.root / path) for path in paths]], env={**self.env, **env}, text=True, capture_output=True)

    def test_exact_packaged_identity_emits_android_not_apple_build(self):
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Android versionCode: 238\nAndroid versionName: 0.4.0\n")

    def test_previous_apk_version_is_rejected(self):
        self.assertNotEqual(self.run_verifier(FIXTURE_CODE="237").returncode, 0)

    def test_aab_cannot_differ_from_apks(self):
        self.assertNotEqual(self.run_verifier(FIXTURE_BUNDLE_CODE="253").returncode, 0)
        self.assertNotEqual(self.run_verifier(FIXTURE_BUNDLE_NAME="0.3.15").returncode, 0)

    def test_package_identity_is_bound_for_apk_and_aab(self):
        self.assertNotEqual(self.run_verifier(FIXTURE_PACKAGE="com.other.app").returncode, 0)
        self.assertNotEqual(self.run_verifier(FIXTURE_BUNDLE_PACKAGE="com.other.app").returncode, 0)

    def test_invalid_versions_do_not_emit_evidence(self):
        for code in ("", "0", "-1", "238\n239", "2.38", "0238", "2100000001", "999999999999"):
            with self.subTest(code=code):
                result = self.run_verifier(code=code)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.assertNotEqual(self.run_verifier(name="0.4.0-beta.17").returncode, 0)

    def test_incomplete_artifact_set_cannot_emit_evidence(self):
        self.assertNotEqual(self.run_verifier(files=["full.apk", "play.apk"]).returncode, 0)
        self.assertNotEqual(self.run_verifier(files=["full.apk", "play.aab", "missing.apk"]).returncode, 0)

    def test_missing_bundle_inspector_fails_closed(self):
        self.assertNotEqual(self.run_verifier(BUNDLETOOL_JAR=str(self.root / "missing.jar")).returncode, 0)


if __name__ == "__main__":
    unittest.main()
