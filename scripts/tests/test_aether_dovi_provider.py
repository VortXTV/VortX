"""Synthetic rejection tests for the real-provider inspector; no compiler or network."""
import importlib.util
from pathlib import Path
import shutil
import stat
import struct
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("dovi_provider", ROOT / "scripts/aether-dovi-provider.py")
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
SDK = 27 << 16
SYMBOLS = ["dovi_parse_fixture", "dovi_free_fixture"]


def macho(*, cpu=0x1000007, platform=8, minimum=17 << 16, sdk=SDK,
          names=SYMBOLS, weak=False, empty=False, out_of_code=False):
    code = b"\xc3" * (0 if empty else max(1, len(names)))
    commands_size = 152 + 24 + 24
    code_offset = 32 + commands_size
    strings = b"\0"
    entries = b""
    for index, name in enumerate(names):
        entries += struct.pack("<IBBHQ", len(strings), 0x0f, 1, 0x80 if weak else 0,
                               0xffff if out_of_code else 0x1000 + index)
        strings += b"_" + name.encode() + b"\0"
    segment = struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", 0x1000, len(code),
                          code_offset, len(code), 7, 5, 1, 0)
    segment += struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x1000,
                           len(code), code_offset, 0, 0, 0, 0x80000400, 0, 0, 0)
    version = struct.pack("<6I", 0x32, 24, platform, minimum, sdk, 0)
    symtab = struct.pack("<6I", 2, 24, code_offset + len(code), len(names),
                         code_offset + len(code) + len(entries), len(strings))
    header = struct.pack("<8I", 0xfeedfacf, cpu, 3, 1, 3, commands_size, 0, 0)
    return header + segment + version + symtab + code + entries + strings


def member(body, name="fixture.o"):
    encoded = name.encode()
    if len(encoded) > 15:
        body = encoded + body
        encoded = ("#1/" + str(len(encoded))).encode()
    header = encoded.ljust(16) + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
    header += b"100644".ljust(8) + str(len(body)).encode().ljust(10) + b"`\n"
    return header + body + (b"\n" if len(body) & 1 else b"")


def archive(*bodies):
    return b"!<arch>\n" + b"".join(member(body) for body in bodies)


class ProviderInspectionTests(unittest.TestCase):
    def inspect(self, body):
        return provider.archive(body, SYMBOLS, SDK)

    def test_real_code_shape_accepts_all_requested_strong_definitions(self):
        receipt = self.inspect(archive(macho()))
        self.assertEqual({name: 1 for name in SYMBOLS}, receipt["requiredSymbolOwners"])

    def test_every_member_must_have_the_right_cpu_platform_and_deployment(self):
        for changes in ({"cpu": 0x100000c}, {"platform": 7}, {"platform": 3},
                        {"platform": 1}, {"minimum": 16 << 16}, {"sdk": 26 << 16}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.inspect(archive(macho(), macho(names=[], **changes)))

    def test_weak_duplicate_missing_and_out_of_code_apis_are_rejected(self):
        for body in (archive(macho(weak=True)), archive(macho(), macho()),
                     archive(macho(names=SYMBOLS[:1])), archive(macho(out_of_code=True)),
                     archive(macho(empty=True))):
            with self.subTest(body=provider.sha(body)), self.assertRaises(ValueError):
                self.inspect(body)

    def test_legitimate_empty_text_data_object_is_not_a_false_rejection(self):
        self.assertEqual(2, len(self.inspect(archive(macho(), macho(names=[], empty=True)))["members"]))

    def test_index_prefix_cannot_hide_a_foreign_member(self):
        body = b"!<arch>\n" + member(macho()) + member(b"not an object", "__.SYMDEF_payload")
        with self.assertRaises(ValueError):
            self.inspect(body)

    def test_sdk_zero_is_limited_to_a_rust_codegen_member(self):
        with self.assertRaises(ValueError):
            self.inspect(archive(macho(sdk=0)))
        body = b"!<arch>\n" + member(macho(sdk=0), "fixture.rcgu.o")
        self.assertEqual(1, len(self.inspect(body)["members"]))

    def test_truncation_and_non_archive_inputs_fail(self):
        for body in (b"", b"!<arch>\n", archive(macho())[:-9], b"not a library"):
            with self.subTest(body=provider.sha(body)), self.assertRaises(ValueError):
                self.inspect(body)

    def test_header_tokens_preserve_abi_but_ignore_comments_and_whitespace(self):
        a = b"typedef struct { const int *field; } DoviFixture;"
        self.assertEqual(provider.tokens(a), provider.tokens(b"/* comment */ typedef struct{const int*field;}DoviFixture;"))
        self.assertNotEqual(provider.tokens(a), provider.tokens(a.replace(b"const ", b"")))
        self.assertNotEqual(provider.tokens(a), provider.tokens(a.replace(b"int", b"long")))

    def test_owned_paths_reject_escape_symlinks_and_existing_fresh_outputs(self):
        (ROOT / "app/build").mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "app/build") as directory:
            root = Path(directory).resolve()
            child = root / "fresh"
            provider.owned(child, root, fresh=True)
            for path in (root, root.parent / "outside", root / ".." / "escape"):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    provider.owned(path, root, fresh=True)
            child.mkdir()
            with self.assertRaises(ValueError):
                provider.owned(child, root, fresh=True)
            link = root / "link"
            link.symlink_to(root.parent, target_is_directory=True)
            with self.assertRaises(ValueError):
                provider.owned(link / "escape", root)


class StagingPermissionTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "app/build").mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / "app/build")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.work = self.root / "extension"
        self.work.mkdir()

    @staticmethod
    def snapshot(root):
        return {str(path.relative_to(root)): (
            stat.S_IMODE(path.stat().st_mode),
            provider.sha(path.read_bytes()) if path.is_file() else None)
            for path in [root, *sorted(root.rglob("*"))]}

    def test_readonly_copy_replaces_only_staged_archive_and_plist(self):
        original = self.root / "original.xcframework"
        old = original / provider.OLD
        (old / "Headers").mkdir(parents=True)
        (old / "libdovi.a").write_bytes(b"original arm archive")
        (old / "Headers/dovi.h").write_bytes(b"original header")
        (original / "Info.plist").write_bytes(b"original plist")
        (original / "unknown.txt").write_bytes(b"unreviewed file retained")
        (original / "other-slice").mkdir()
        (original / "other-slice/library.a").write_bytes(b"unrelated archive")
        for path in original.rglob("*"):
            path.chmod(0o555 if path.is_dir() else 0o444)
        original.chmod(0o555)
        before = self.snapshot(original)
        staged = self.work / "Dovi.xcframework"
        shutil.copytree(original, staged)
        with provider.writable_staged_directory(staged, self.work):
            (staged / provider.OLD).rename(staged / provider.NEW)
        archive = staged / provider.NEW / "libdovi.a"
        old_inode = archive.stat().st_ino
        provider.replace_staged_file(archive, b"combined real-provider placeholder", self.work)
        provider.replace_staged_file(staged / "Info.plist", b"updated plist", self.work)
        self.assertNotEqual(old_inode, archive.stat().st_ino)
        self.assertEqual(b"combined real-provider placeholder", archive.read_bytes())
        self.assertEqual(b"updated plist", (staged / "Info.plist").read_bytes())
        self.assertEqual(before, self.snapshot(original))
        actual = self.snapshot(staged)
        self.assertEqual({name.replace(provider.OLD, provider.NEW, 1) for name in before}, set(actual))
        for name, (mode, digest) in before.items():
            moved = name.replace(provider.OLD, provider.NEW, 1)
            self.assertEqual(mode, actual[moved][0], moved)
            if name not in ("Info.plist", provider.OLD + "/libdovi.a"):
                self.assertEqual(digest, actual[moved][1], moved)
        self.assertEqual([], list(staged.rglob(".dovi-replace-*")))

    def test_replacement_failure_restores_modes_and_leaves_original_and_unknown_files(self):
        staged = self.work / "stage"
        staged.mkdir()
        target = staged / "libdovi.a"
        target.write_bytes(b"original")
        target.chmod(0o444)
        (staged / "unknown").write_bytes(b"keep")
        staged.chmod(0o555)
        before = self.snapshot(staged)
        with mock.patch.object(provider.os, "replace", side_effect=OSError("replacement refused")):
            with self.assertRaisesRegex(OSError, "replacement refused"):
                provider.replace_staged_file(target, b"replacement", self.work)
        self.assertEqual(before, self.snapshot(staged))

    def test_rename_failure_restores_readonly_staging_directory(self):
        staged = self.work / "stage"
        staged.mkdir()
        staged.chmod(0o555)
        with self.assertRaisesRegex(RuntimeError, "simulated rename failure"):
            with provider.writable_staged_directory(staged, self.work):
                raise RuntimeError("simulated rename failure")
        self.assertEqual(0o555, stat.S_IMODE(staged.stat().st_mode))

    def test_symlink_and_outside_targets_are_rejected_without_modification(self):
        external = self.root / "external"
        external.mkdir()
        target = external / "libdovi.a"
        target.write_bytes(b"original")
        target.chmod(0o444)
        external.chmod(0o555)
        (self.work / "file-link").symlink_to(target)
        (self.work / "directory-link").symlink_to(external, target_is_directory=True)
        before = self.snapshot(external)
        for path in (target, self.work / "file-link", self.work / "directory-link/libdovi.a"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                provider.replace_staged_file(path, b"bad", self.work)
        for directory in (external, self.work / "directory-link", self.work):
            with self.subTest(directory=directory), self.assertRaises(ValueError):
                with provider.writable_staged_directory(directory, self.work):
                    self.fail("unsafe directory admitted")
        self.assertEqual(before, self.snapshot(external))

    def test_nonregular_target_and_symlink_xcframework_root_are_rejected(self):
        directory = self.work / "directory"
        directory.mkdir()
        with self.assertRaises(ValueError):
            provider.replace_staged_file(directory, b"bad", self.work)
        link = self.work / "root-link"
        link.symlink_to(directory, target_is_directory=True)
        with self.assertRaises(ValueError):
            provider.manifest(link)

    def test_extension_rejects_work_inside_inputs_before_any_tool_or_mutation(self):
        package = self.root / "package"
        built_provider = self.root / "provider"
        package.mkdir()
        built_provider.mkdir()
        for work in (package / "extension", built_provider / "extension"):
            with self.subTest(work=work), mock.patch.object(provider, "run") as run:
                with self.assertRaisesRegex(ValueError, "outside package and provider"):
                    provider.extend(package, built_provider, work)
                run.assert_not_called()
                self.assertFalse(work.exists())


if __name__ == "__main__":
    unittest.main()
