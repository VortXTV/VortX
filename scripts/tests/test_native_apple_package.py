#!/usr/bin/env python3
"""Negative artifact cases for the production native linker-map acceptance check."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("native_package", Path(__file__).parents[1] / "verify-native-apple-package.py")
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)


class LinkMapProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vortx-linkmap-contract-")
        self.root = Path(self.temporary.name)
        self.entries = []
        self.lines = []
        names = ["libvortx_ffi.a", "Libmpv", "Libavcodec", "Libavformat", "Libplacebo"]
        for index, name in enumerate(names):
            path = self.root / name
            path.write_bytes(f"approved input {index}".encode())
            entry = NATIVE.record(path, "engine" if index == 0 else "mpv",
                                  "macos-arm64" if index == 0 else "macos-arm64_x86_64",
                                  None if index == 0 else next(key for key, value in NATIVE.MPV_TARGETS.items() if value == name))
            self.entries.append(entry)
            self.lines.append(f"[{index + 1:3}] {path}(member.o)")
        self.manifest = {"schema": 1, "engineSourceRevision": "e" * 40, "inputs": self.entries}
        self.map = self.root / "native.map"
        self.map.write_text("\n".join(self.lines))

    def tearDown(self):
        self.temporary.cleanup()

    def test_exact_loaded_archives_pass(self):
        NATIVE.verify_inputs(self.manifest)
        self.assertEqual(len(NATIVE.verify_link_map(self.manifest, "macos", self.map)), 5)

    def test_changed_build_input_fails(self):
        Path(self.entries[0]["path"]).write_bytes(b"same ABI, different native build")
        with self.assertRaisesRegex(ValueError, "changed after capture"):
            NATIVE.verify_inputs(self.manifest)

    def test_same_name_stale_archive_from_another_directory_fails(self):
        stale = self.root / "stale" / "libvortx_ffi.a"
        stale.parent.mkdir()
        stale.write_bytes(b"old native build with the same exported symbols")
        self.map.write_text("\n".join([f"[1] {stale}(member.o)"] + self.lines[1:]))
        with self.assertRaisesRegex(ValueError, "unapproved archive"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_legacy_core_contribution_fails(self):
        self.map.write_text("\n".join(self.lines + ["[6] /a/StremioXCore.framework/StremioXCore(member.o)"]))
        with self.assertRaisesRegex(ValueError, "legacy engine/runtime"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_incomplete_link_map_fails(self):
        self.map.write_text("\n".join(self.lines[:-1]))
        with self.assertRaisesRegex(ValueError, "lacks required"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_packaged_copy_rejects_changed_resources(self):
        app = self.root / "VortX.app"
        app.mkdir()
        resource = app / "resource.txt"
        resource.write_text("accepted bundle content")
        receipt = {"schema": 1, "platform": "ios", "bundlePayload": NATIVE.bundle_payload(app),
                   "engineSourceRevision": "e" * 40, "bundleIdentifier": "com.stremiox.app.native",
                   "version": "0.5.0", "build": "260"}
        NATIVE.verify_packaged_copy(receipt, app, "ios")
        resource.write_text("different package content")
        with self.assertRaisesRegex(ValueError, "payload differs"):
            NATIVE.verify_packaged_copy(receipt, app, "ios")

    def test_ipa_path_traversal_is_rejected(self):
        artifact = self.root / "native.ipa"
        with NATIVE.zipfile.ZipFile(artifact, "w") as archive:
            archive.writestr("../outside.txt", "untrusted archive path")
        with self.assertRaisesRegex(ValueError, "escapes"):
            NATIVE.verify_archive({}, artifact, "ios")


if __name__ == "__main__":
    unittest.main()
