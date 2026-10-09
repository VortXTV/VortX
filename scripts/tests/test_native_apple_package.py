#!/usr/bin/env python3
"""Production native input/linker proofs and real IPA extraction admission cases."""
import importlib.util
import stat
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("native_package", Path(__file__).parents[1] / "verify-native-apple-package.py")
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)
TEMPORARY_DIRECTORY = tempfile.TemporaryDirectory


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
        self.write_map(self.lines)

    def write_map(self, lines, tail=b"# Symbols:\n# Address Size File Name\n"):
        self.map.write_bytes(b"# Path: /fixture/VortX\n# Arch: arm64\n# Object files:\n" +
                             "\n".join(lines).encode("utf-8") + b"\n# Sections:\n" + tail)

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
        self.write_map([f"[1] {stale}(member.o)"] + self.lines[1:])
        with self.assertRaisesRegex(ValueError, "unapproved archive"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_legacy_core_contribution_fails(self):
        self.write_map(self.lines + ["[6] /a/StremioXCore.framework/StremioXCore(member.o)"])
        with self.assertRaisesRegex(ValueError, "legacy engine/runtime"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_incomplete_link_map_fails(self):
        self.write_map(self.lines[:-1])
        with self.assertRaisesRegex(ValueError, "lacks required"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_raw_non_utf8_symbol_tail_does_not_change_archive_proof(self):
        # Apple linker maps may preserve arbitrary symbol bytes after Object files.
        # Their bytes remain part of the complete map hash, never path-decoded.
        self.write_map(self.lines, b"# Symbols:\n0x1000 0x10 [1] _symbol_\xff\n")
        original_hash = NATIVE.sha256(self.map)
        self.assertEqual(len(NATIVE.verify_link_map(self.manifest, "macos", self.map)), 5)
        self.write_map(self.lines, b"# Symbols:\n0x1000 0x10 [1] _symbol_\xfe\n")
        self.assertNotEqual(NATIVE.sha256(self.map), original_hash)

    def test_crlf_object_rows_and_linker_synthesized_entry_pass(self):
        self.write_map(["[0] linker synthesized"] + self.lines)
        self.map.write_bytes(self.map.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(len(NATIVE.verify_link_map(self.manifest, "macos", self.map)), 5)

    def test_bracketed_symbol_tail_is_not_an_object_path(self):
        self.write_map(self.lines, b"# Symbols:\n[8] /a/NodeMobile(symbol_\xff)\n")
        self.assertEqual(len(NATIVE.verify_link_map(self.manifest, "macos", self.map)), 5)

    def test_non_utf8_object_path_fails_closed(self):
        self.write_map(self.lines)
        self.map.write_bytes(self.map.read_bytes().replace(b"(member.o)", b"(member_\xff.o)", 1))
        with self.assertRaisesRegex(ValueError, "object path.*UTF-8"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_missing_object_section_fails_closed(self):
        self.map.write_text("\n".join(self.lines))
        with self.assertRaisesRegex(ValueError, "Object files section"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_unterminated_object_section_fails_closed(self):
        self.map.write_text("# Object files:\n" + "\n".join(self.lines))
        with self.assertRaisesRegex(ValueError, "Sections boundary"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_duplicate_object_section_fails_closed(self):
        self.write_map(self.lines, b"# Object files:\n# Sections:\n")
        with self.assertRaisesRegex(ValueError, "Object files section"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_duplicate_sections_boundary_fails_closed(self):
        self.write_map(self.lines, b"# Sections:\n# Symbols:\n")
        with self.assertRaisesRegex(ValueError, "Sections boundary"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_reversed_sections_boundary_fails_closed(self):
        self.map.write_text("# Sections:\n# Object files:\n" + "\n".join(self.lines))
        with self.assertRaisesRegex(ValueError, "Sections boundary"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_malformed_object_row_fails_closed(self):
        self.write_map(self.lines + ["[not-an-index] /a/unparsed.a(member.o)"])
        with self.assertRaisesRegex(ValueError, "malformed object row"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_duplicate_object_index_fails_closed(self):
        self.write_map(self.lines + ["[1] /a/another.o"])
        with self.assertRaisesRegex(ValueError, "duplicate object index"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_malformed_native_archive_member_fails_closed(self):
        for suffix in ("", "(member.o", "()"):
            with self.subTest(suffix=suffix):
                self.write_map([f"[1] {self.entries[0]['path']}{suffix}"] + self.lines[1:])
                with self.assertRaisesRegex(ValueError, "malformed archive member"):
                    NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_nul_in_object_path_fails_closed(self):
        self.write_map(self.lines)
        self.map.write_bytes(self.map.read_bytes().replace(b"(member.o)", b"(member_\x00.o)", 1))
        with self.assertRaisesRegex(ValueError, "malformed object path"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_legacy_core_before_non_utf8_symbol_tail_still_fails(self):
        self.write_map(self.lines + ["[6] /a/StremioXCore.framework/StremioXCore(member.o)"],
                       b"# Symbols:\n_symbol_\xff\n")
        with self.assertRaisesRegex(ValueError, "legacy engine/runtime"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_stale_archive_before_non_utf8_symbol_tail_still_fails(self):
        stale = self.root / "stale" / "libvortx_ffi.a"
        stale.parent.mkdir()
        stale.write_bytes(b"same ABI, unapproved engine build")
        self.write_map([f"[1] {stale}(member.o)"] + self.lines[1:], b"# Symbols:\n_symbol_\xff\n")
        with self.assertRaisesRegex(ValueError, "unapproved archive"):
            NATIVE.verify_link_map(self.manifest, "macos", self.map)

    def test_unavailable_archive_still_fails(self):
        Path(self.entries[0]["path"]).unlink()
        with self.assertRaisesRegex(ValueError, "unavailable archive"):
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


class IPAExtractionRootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TEMPORARY_DIRECTORY(prefix="vortx-ipa-root-contract-")
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "source" / "VortXiOSNative.app"
        self.app.mkdir(parents=True)
        (self.app / "resource.txt").write_bytes(b"accepted native bundle bytes")

    def tearDown(self):
        self.temporary.cleanup()

    @contextmanager
    def aliased_directory(self, **_kwargs):
        with TEMPORARY_DIRECTORY(prefix="physical-", dir=self.root) as directory:
            alias = self.root / "extraction-alias"
            alias.symlink_to(Path(directory).resolve(), target_is_directory=True)
            self.assertNotEqual(alias, alias.resolve())
            try:
                yield str(alias)
            finally:
                alias.unlink()

    def artifact_and_receipt(self, platform="ios"):
        artifact = self.root / "native.ipa"
        with NATIVE.zipfile.ZipFile(artifact, "w") as archive:
            for path in self.app.rglob("*"):
                name = f"Payload/{self.app.name}/{path.relative_to(self.app).as_posix()}"
                if path.is_symlink():
                    member = NATIVE.zipfile.ZipInfo(name)
                    member.create_system = 3
                    member.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(member, str(path.readlink()))
                elif path.is_file():
                    archive.write(path, name)
                else:
                    archive.writestr(name + "/", b"")
        receipt = {"schema": 1, "platform": platform, "bundlePayload": NATIVE.bundle_payload(self.app),
                   "engineSourceRevision": "e" * 40, "bundleIdentifier": "com.stremiox.app.native",
                   "version": "0.5.0", "build": "260"}
        return artifact, receipt

    def test_real_extractor_accepts_ordinary_ipa(self):
        artifact, receipt = self.artifact_and_receipt()
        result = NATIVE.verify_archive(receipt, artifact, "ios")
        self.assertEqual(result["artifactSha256"], NATIVE.sha256(artifact))
        self.assertEqual(result["engineSourceRevision"], receipt["engineSourceRevision"])

    def test_real_extractor_accepts_aliased_root_for_ios_and_tvos(self):
        for platform in ("ios", "tvos"):
            with self.subTest(platform=platform):
                artifact, receipt = self.artifact_and_receipt(platform)
                with patch.object(NATIVE.tempfile, "TemporaryDirectory", self.aliased_directory):
                    result = NATIVE.verify_archive(receipt, artifact, platform)
                self.assertEqual(result["platform"], platform)
                self.assertEqual(result["build"], "260")

    def test_aliased_extraction_preserves_contained_framework_symlinks(self):
        versions = self.app / "Frameworks" / "Lib.framework" / "Versions"
        (versions / "A").mkdir(parents=True)
        (versions / "A" / "Lib").write_bytes(b"accepted inert framework")
        (versions / "Current").symlink_to("A", target_is_directory=True)
        artifact, receipt = self.artifact_and_receipt()
        with patch.object(NATIVE.tempfile, "TemporaryDirectory", self.aliased_directory):
            result = NATIVE.verify_archive(receipt, artifact, "ios")
        self.assertEqual(result["artifactSha256"], NATIVE.sha256(artifact))

    def test_aliased_root_still_rejects_parent_and_absolute_paths(self):
        for name in ("../outside.txt", "Payload/../../outside.txt", str(self.root / "outside.txt")):
            with self.subTest(name=name):
                artifact = self.root / "bad.ipa"
                with NATIVE.zipfile.ZipFile(artifact, "w") as archive:
                    archive.writestr(name, b"untrusted member")
                with patch.object(NATIVE.tempfile, "TemporaryDirectory", self.aliased_directory):
                    with self.assertRaisesRegex(ValueError, "escapes"):
                        NATIVE.verify_archive({}, artifact, "ios")
                self.assertFalse((self.root / "outside.txt").exists())

    def test_aliased_root_rejects_writes_through_an_escaping_symlink(self):
        artifact = self.root / "bad-link.ipa"
        with NATIVE.zipfile.ZipFile(artifact, "w") as archive:
            link = NATIVE.zipfile.ZipInfo("Payload/VortXiOSNative.app/escape")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "../../../outside")
            archive.writestr("Payload/VortXiOSNative.app/escape/file.txt", b"untrusted write")
        with patch.object(NATIVE.tempfile, "TemporaryDirectory", self.aliased_directory):
            with self.assertRaisesRegex(ValueError, "escapes"):
                NATIVE.verify_archive({}, artifact, "ios")
        self.assertFalse((self.root / "outside").exists())

    def test_aliased_root_still_rejects_changed_payload(self):
        artifact, receipt = self.artifact_and_receipt()
        with NATIVE.zipfile.ZipFile(artifact, "a") as archive:
            archive.writestr(f"Payload/{self.app.name}/extra.txt", b"not accepted")
        with patch.object(NATIVE.tempfile, "TemporaryDirectory", self.aliased_directory):
            with self.assertRaisesRegex(ValueError, "payload differs"):
                NATIVE.verify_archive(receipt, artifact, "ios")


if __name__ == "__main__":
    unittest.main()
