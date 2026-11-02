#!/usr/bin/env python3
"""Disposable macOS fixture for the actual embed script; no app/build/signing execution."""
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

DEFAULT_SCRIPT = Path(__file__).resolve().parents[2] / "scripts/embed-aether-frameworks.sh"
SCRIPT = Path(os.environ.get("VORTX_EMBED_AETHER_SCRIPT", DEFAULT_SCRIPT)).resolve()
NAMES = ("AetherLibavcodec", "AetherLibavfilter", "AetherLibavformat", "AetherLibavutil",
         "AetherLibdav1d", "AetherLibswresample", "AetherLibswscale", "AetherLibzimg", "AetherLibzvbi")


def xattrs(path):
    names = subprocess.run(["/usr/bin/xattr", str(path)], check=True, capture_output=True, text=True).stdout.splitlines()
    return tuple((name, bytes.fromhex(subprocess.run(
        ["/usr/bin/xattr", "-px", name, str(path)], check=True, capture_output=True, text=True).stdout))
        for name in sorted(names))


def set_quarantine(path):
    subprocess.run(["/usr/bin/xattr", "-wx", "com.apple.quarantine",
                    b"synthetic-fixture-only".hex(), str(path)], check=True, capture_output=True)


def snapshot(root):
    result = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            result[relative] = ("link", os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            result[relative] = ("file", stat.S_IMODE(info.st_mode), hashlib.sha256(path.read_bytes()).hexdigest(),
                                xattrs(path))
        elif stat.S_ISDIR(info.st_mode):
            result[relative] = ("directory", stat.S_IMODE(info.st_mode))
    return result


@unittest.skipUnless(sys.platform == "darwin", "actual ditto/xattr regression requires macOS")
class EmbedAetherPermissionTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "select the actual maintained embed script")
        build = SCRIPT.parent.parent / "app/build"
        build.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="aether-permissions-", dir=build)
        self.root = Path(self.temp.name)
        self.addCleanup(self.cleanup)
        self.source = self.root / "source"
        self.target = self.root / "target"
        self.source.mkdir()
        self.target.mkdir()
        self.outside = self.root / "outside-sentinel"
        self.outside.write_bytes(b"outside the copied framework")
        self.outside.chmod(0o444)
        for name in NAMES:
            framework = self.source / (name + ".framework")
            version = framework / "Versions/A"
            resources = version / "Resources"
            resources.mkdir(parents=True)
            for path, data, mode in ((version / name, b"synthetic dylib payload", 0o555),
                                     (resources / "Info.plist", b"synthetic plist payload", 0o444),
                                     (resources / "PrivacyInfo.xcprivacy", b"synthetic privacy payload", 0o444)):
                path.write_bytes(data)
                set_quarantine(path)
                path.chmod(mode)
            for folder in ("Headers", "Modules", "_CodeSignature"):
                directory = version / folder
                directory.mkdir()
                (directory / "synthetic").write_bytes(b"removed from copied embed only")
            (framework / "Versions/Current").symlink_to("A")
            (framework / name).symlink_to("Versions/Current/" + name)
            for folder in ("Resources", "Headers", "Modules"):
                (framework / folder).symlink_to("Versions/Current/" + folder)
            # Synthetic traversal tripwire. This is never signed or packaged as an app.
            (resources / "outside-link").symlink_to(self.outside)
            resources.chmod(0o555)
        self.original = snapshot(self.source)
        self.outside_mode = stat.S_IMODE(self.outside.stat().st_mode)
        self.outside_bytes = self.outside.read_bytes()

    def cleanup(self):
        # Retire only this test-owned temporary tree. Do not follow its traversal tripwire.
        for directory, children, _files in os.walk(self.root, followlinks=False):
            path = Path(directory)
            path.chmod(stat.S_IMODE(path.stat().st_mode) | stat.S_IWUSR)
        self.temp.cleanup()

    def run_embed(self, signed=False):
        env = os.environ.copy()
        env.update(TARGET_BUILD_DIR=str(self.target), FRAMEWORKS_FOLDER_PATH="Frameworks",
                   BUILT_PRODUCTS_DIR=str(self.source), CODE_SIGNING_ALLOWED="YES" if signed else "NO",
                   EXPANDED_CODE_SIGN_IDENTITY="synthetic-test-identity" if signed else "")
        if signed:
            # Records sign-order admission only; no real signing or signature success is claimed.
            tools = self.root / "tools"
            tools.mkdir()
            signer = tools / "codesign"
            signer.write_text("#!/usr/bin/env python3\nimport os, pathlib, stat, sys\n"
                              "root=pathlib.Path(sys.argv[-1])\n"
                              "for p in root.rglob('*'):\n"
                              " if not p.is_symlink() and (p.is_file() or p.is_dir()):\n"
                              "  assert p.stat().st_mode & stat.S_IWUSR, str(p)\n"
                              "with open(os.environ['SYNTHETIC_SIGN_LOG'],'a') as f: f.write(str(root)+'\\n')\n")
            signer.chmod(0o755)
            env["PATH"] = str(tools) + os.pathsep + env["PATH"]
            env["SYNTHETIC_SIGN_LOG"] = str(self.root / "signed.log")
        subprocess.run(["bash", str(SCRIPT)], env=env, check=True, capture_output=True, text=True)
        return self.target / "Frameworks"

    def assert_source_and_outside_unchanged(self):
        self.assertEqual(snapshot(self.source), self.original)
        self.assertEqual(stat.S_IMODE(self.outside.stat().st_mode), self.outside_mode)
        self.assertEqual(self.outside.read_bytes(), self.outside_bytes)

    def test_copied_modes_allow_owner_xattr_edit_without_content_or_symlink_changes(self):
        destination = self.run_embed()
        for name in NAMES:
            original = self.source / (name + ".framework")
            copied = destination / (name + ".framework")
            for relative in (f"Versions/A/{name}", "Versions/A/Resources/Info.plist",
                             "Versions/A/Resources/PrivacyInfo.xcprivacy"):
                source = original / relative
                target = copied / relative
                self.assertEqual(target.read_bytes(), source.read_bytes())
                self.assertEqual(stat.S_IMODE(target.stat().st_mode),
                                 stat.S_IMODE(source.stat().st_mode) | stat.S_IWUSR)
                self.assertIn("com.apple.quarantine", dict(xattrs(target)))
                subprocess.run(["/usr/bin/xattr", "-d", "com.apple.quarantine", str(target)], check=True, capture_output=True)
                self.assertNotIn("com.apple.quarantine", dict(xattrs(target)))
            for relative in ("Versions/Current", name, "Resources", "Versions/A/Resources/outside-link"):
                self.assertTrue((copied / relative).is_symlink())
                self.assertEqual(os.readlink(copied / relative), os.readlink(original / relative))
            self.assertEqual(stat.S_IMODE((copied / "Versions/A/Resources").stat().st_mode), 0o755)
            self.assertFalse((copied / "Headers").exists())
            self.assertFalse((copied / "Modules").exists())
            self.assertFalse((copied / "Versions/A/_CodeSignature").exists())
        self.assert_source_and_outside_unchanged()

    def test_normalization_precedes_signing_boundary(self):
        self.run_embed(signed=True)
        records = (self.root / "signed.log").read_text().splitlines()
        self.assertEqual(len(records), len(NAMES))
        self.assertEqual({Path(item).name for item in records}, {name + ".framework" for name in NAMES})
        self.assert_source_and_outside_unchanged()


if __name__ == "__main__":
    unittest.main()
