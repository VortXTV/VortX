"""Synthetic rejection tests for the real-provider inspector; no compiler or network."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
