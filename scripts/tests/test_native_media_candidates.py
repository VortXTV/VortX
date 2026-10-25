"""Secretless producer contracts. Synthetic ELF text is not actual native acceptance."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("native_media_evidence", ROOT / "scripts/native-media-hosted/evidence.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ACQUIRE_SPEC = importlib.util.spec_from_file_location("android_mpv_acquisition", ROOT / "scripts/acquire-android-mpv-component.py")
ACQUIRE = importlib.util.module_from_spec(ACQUIRE_SPEC)
ACQUIRE_SPEC.loader.exec_module(ACQUIRE)


class NativeMediaProducer(unittest.TestCase):
    def test_all_recipe_inputs_match(self):
        lines = (ROOT / "scripts/native-media-hosted/inputs.sha256").read_text().splitlines()
        names = set()
        for line in lines:
            expected, name = line.split("  ", 1)
            self.assertNotIn(name, names)
            names.add(name)
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), expected)
        self.assertEqual(len(names), 25)
        self.assertEqual(names, {
            'scripts/assemble-mpvkit-dvfel.sh',
            'scripts/build-mpvkit-dvfel.sh',
            'scripts/mpv-coreaudio-hotplug-lifecycle.patch',
            'scripts/mpv-http-seek-interrupt.patch',
            'scripts/mpv-moltenvk-resize.patch',
            'scripts/mpv-original-local-file-witness.patch',
            'scripts/mpv-original-http-reference-recipe.patch',
            'scripts/mpv-owned-subtitle-constructor.patch',
            'scripts/mpv-owned-subtitle-publication.patch',
            'scripts/mpv-upstream-audio-layout-bounds.patch',
            'scripts/mpv-upstream-edition-title-lifetime.patch',
            'scripts/mpv-upstream-gpu-next-seek-reset.patch',
            'scripts/mpvkit-dvfel.patch',
            'scripts/native-media-hosted/android-assembly.patch',
            'scripts/native-media-hosted/android/buildscripts/include/depinfo.sh',
            'scripts/native-media-hosted/android/buildscripts/include/download-deps.sh',
            'scripts/native-media-hosted/android/buildscripts/include/download-lua.sh',
            'scripts/native-media-hosted/android/buildscripts/include/download-libunibreak.sh',
            'scripts/native-media-hosted/android/buildscripts/patch.sh',
            'scripts/native-media-hosted/android/buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch',
            'scripts/native-media-hosted/android/buildscripts/scripts/ffmpeg.sh',
            'scripts/native-media-hosted/build.sh',
            'scripts/native-media-hosted/evidence.py',
            'scripts/verify-mpvkit-dvfel-apple-tls.sh',
            'scripts/verify-mpvkit-dvfel-artifacts.sh',
        })
        self.assertIn('scripts/native-media-hosted/android/buildscripts/include/download-libunibreak.sh', names)
        self.assertIn('scripts/native-media-hosted/android/buildscripts/scripts/ffmpeg.sh', names)
        self.assertIn('scripts/mpv-upstream-audio-layout-bounds.patch', names)
        self.assertIn('scripts/mpv-upstream-gpu-next-seek-reset.patch', names)
        self.assertIn('scripts/mpv-original-local-file-witness.patch', names)
        self.assertIn('scripts/mpv-upstream-edition-title-lifetime.patch', names)
        self.assertIn('scripts/mpv-owned-subtitle-constructor.patch', names)
        self.assertIn('scripts/mpv-owned-subtitle-publication.patch', names)
        self.assertIn('scripts/mpv-original-http-reference-recipe.patch', names)

    def test_android_preserves_selected_custom_source_family(self):
        import re
        apple = (ROOT / "scripts/mpvkit-dvfel.patch").read_text()
        android = (ROOT / "scripts/native-media-hosted/android/buildscripts/include/depinfo.sh").read_text()
        for android_key, apple_key in [("v_mpv_sha", "mpvPinnedSHA"),
                                       ("v_libplacebo_sha", "placeboPinnedSHA"),
                                       ("v_ffmpeg_sha", "ffmpegPinnedSHA")]:
            actual = re.search(r"^" + android_key + r"=([0-9a-f]{40})$", android, re.M).group(1)
            expected = re.search(r"static let " + apple_key + r' = "([0-9a-f]{40})"', apple).group(1)
            self.assertEqual(actual, expected, android_key)
        self.assertIn("v_ffmpeg=9.0.2\n", android)
        self.assertNotIn("v_mpv=0.41.0", android)
        self.assertNotIn("v_libplacebo=7.360.1", android)
        download = (ROOT / "scripts/native-media-hosted/android/buildscripts/include/download-deps.sh").read_text()
        self.assertIn('fetch_commit mpv https://github.com/mpv-player/mpv.git "$v_mpv_sha"', download)
        self.assertIn('fetch_commit libplacebo https://code.videolan.org/videolan/libplacebo.git "$v_libplacebo_sha"', download)
        self.assertIn('[ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]', download)

    def test_both_candidate_recipes_apply_the_same_backports(self):
        apple = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
        android = (ROOT / "scripts/native-media-hosted/build.sh").read_text()
        for source, apple_number, android_number in [
                ("mpv-http-seek-interrupt.patch", "0006-http-seek-interrupt.patch", "0001-http-seek-interrupt.patch"),
                ("mpv-upstream-audio-layout-bounds.patch", "0007-upstream-audio-layout-bounds.patch", "0002-upstream-audio-layout-bounds.patch"),
                ("mpv-upstream-gpu-next-seek-reset.patch", "0008-upstream-gpu-next-seek-reset.patch", "0003-upstream-gpu-next-seek-reset.patch"),
                ("mpv-original-local-file-witness.patch", "0009-original-local-file-witness.patch", "0004-original-local-file-witness.patch"),
                ("mpv-upstream-edition-title-lifetime.patch", "0010-upstream-edition-title-lifetime.patch", "0005-upstream-edition-title-lifetime.patch"),
                ("mpv-owned-subtitle-constructor.patch", "0011-owned-subtitle-constructor.patch", "0006-owned-subtitle-constructor.patch"),
                ("mpv-owned-subtitle-publication.patch", "0012-owned-subtitle-publication.patch", "0007-owned-subtitle-publication.patch"),
                ("mpv-original-http-reference-recipe.patch", "0013-original-http-reference-recipe.patch", "0008-original-http-reference-recipe.patch")]:
            self.assertIn('copy_exact "$REPO/scripts/' + source + '"', apple)
            self.assertIn('"$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/' + apple_number + '"', apple)
            self.assertIn('cp "$root/scripts/' + source + '" "$upstream/buildscripts/patches/mpv/' + android_number + '"', android)
        self.assertLess(android.index("0006-owned-subtitle-constructor.patch"),
                        android.index("bash patch.sh"))
        self.assertLess(apple.index('copy_exact "$REPO/scripts/mpv-upstream-edition-title-lifetime.patch"'),
                        apple.index('copy_exact "$REPO/scripts/mpv-owned-subtitle-constructor.patch"'))
        self.assertLess(android.index('cp "$root/scripts/mpv-upstream-edition-title-lifetime.patch"'),
                        android.index('cp "$root/scripts/mpv-owned-subtitle-constructor.patch"'))
        self.assertLess(apple.index('copy_exact "$REPO/scripts/mpv-owned-subtitle-constructor.patch"'),
                        apple.index('copy_exact "$REPO/scripts/mpv-owned-subtitle-publication.patch"'))
        self.assertLess(android.index('cp "$root/scripts/mpv-owned-subtitle-constructor.patch"'),
                        android.index('cp "$root/scripts/mpv-owned-subtitle-publication.patch"'))
        self.assertLess(apple.index('copy_exact "$REPO/scripts/mpv-owned-subtitle-publication.patch"'),
                        apple.index('copy_exact "$REPO/scripts/mpv-original-http-reference-recipe.patch"'))
        self.assertLess(android.index('cp "$root/scripts/mpv-owned-subtitle-publication.patch"'),
                        android.index('cp "$root/scripts/mpv-original-http-reference-recipe.patch"'))
        self.assertLess(android.index("0007-owned-subtitle-publication.patch"),
                        android.index("bash patch.sh"))
        self.assertLess(android.index("0008-original-http-reference-recipe.patch"),
                        android.index("bash patch.sh"))

    def test_android_python_closure_is_pinned_and_isolated(self):
        workflow = (ROOT / ".github/workflows/native-media-candidates.yml").read_text()
        android = workflow.split("\n  android:\n", 1)[1]
        tools = android.split("- name: Prepare hosted build tools", 1)[1].split(
            "- name: Build unpromoted Android candidate", 1)[0]
        self.assertIn('/usr/bin/python3.12 -I -m venv "$tools"', tools)
        self.assertNotIn("--system-site-packages", tools)
        self.assertIn('pip --isolated --disable-pip-version-check install --require-hashes --no-index --no-deps --only-binary=:all:', tools)
        import re
        pins = re.findall(r"https://files\.pythonhosted\.org/packages/[^'\s]+", tools)
        self.assertEqual(len(pins), 9)
        expected = {
            "meson-1.12.1-py3-none-any.whl": "930bc7542cbd9f57009e182fd014eba48cf1a0180a7b9006d2d32d8f168d8b02",
            "jinja2-3.1.6-py3-none-any.whl": "85ece4451f492d0c13c5dd7c13a64681a86afae63a5f347908daf103ce6d2f67",
            "markupsafe-3.0.4-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl": "8e124f974786f831d6043728e38296969d3579db8896fe004682f5758e613581",
            "jsonschema-4.26.0-py3-none-any.whl": "d489f15263b8d200f8387e64b4c3a75f06629559fb73deb8fdfb525f2dab50ce",
            "attrs-26.1.0-py3-none-any.whl": "c647aa4a12dfbad9333ca4e71fe62ddc36f4e63b2d260a37a8b83d2f043ac309",
            "jsonschema_specifications-2025.9.1-py3-none-any.whl": "98802fee3a11ee76ecaca44429fda8a41bff98b00a0f2838151b113f210cc6fe",
            "referencing-0.37.0-py3-none-any.whl": "381329a9f99628c9069361716891d34ad94af76e461dcb0335825aecc7692231",
            "rpds_py-2026.9.1-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl": "addeda51556dac7c1a2f14cda62db8b621cd12afba3091d03a96c72932387eab",
            "typing_extensions-4.16.0-py3-none-any.whl": "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8",
        }
        self.assertEqual({url.rsplit("/", 1)[1].split("#sha256=")[0]:
                          url.rsplit("#sha256=", 1)[1] for url in pins}, expected)
        manifest_hash = hashlib.sha256((ROOT / "scripts/native-media-hosted/inputs.sha256").read_bytes()).hexdigest()
        self.assertEqual(workflow.count(manifest_hash), 2, "both lanes verify the exact reviewed input manifest")
        build = (ROOT / "scripts/native-media-hosted/build.sh").read_text()
        preflight = build.split("<<'PYTHON_TOOLCHAIN'\n", 1)[1].split("\nPYTHON_TOOLCHAIN", 1)[0]
        self.assertLess(build.index("<<'PYTHON_TOOLCHAIN'"), build.index("bash -e include/download-deps.sh"))
        self.assertIn("unset PYTHONPATH PYTHONHOME", build)
        self.assertIn("export PYTHONNOUSERSITE=1", build)
        self.assertIn('export PYTHON="$(command -v python3)"', build)
        self.assertIn('"$PYTHON" -I - ', build)
        for fence in ['Path(sys.prefix).resolve() != tools', 'sys.prefix == sys.base_prefix',
                      'sys.version_info[:2] != (3, 12)', 'site.ENABLE_USER_SITE is not False',
                      'config.get("include-system-site-packages") != "false"',
                      'metadata.version != expected_version', 'not origin.is_relative_to(tools)',
                      'not Path(metadata.locate_file("")).resolve().is_relative_to(tools)']:
            self.assertIn(fence, preflight)
        for version in ["1.12.1", "3.1.6", "3.0.4", "4.26.0", "26.1.0",
                        "2025.9.1", "0.37.0", "2026.9.1", "4.16.0"]:
            self.assertIn('"' + version + '"', preflight)
        self.assertIn('jinja_module.Environment().from_string', preflight)
        self.assertIn('schema_module.validate', preflight)
        self.assertIn('> "$out/python-toolchain.json"', build)

    def fixture(self, out, *, missing=None, bad_abi=False, bad_tls=False):
        native_patch = (ROOT / "scripts/native-media-hosted/android/buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch").read_text()
        header = "\n".join(line[1:] for line in native_patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
        (out / "tls_mbedtls_vortx_distrust.h").write_text(header)
        import re
        keys = b"".join(bytes(int(x, 16) for x in re.findall(r"0x([0-9a-f]{2})", line))
                        for line in header.splitlines() if "}, /* EM" in line)
        required = {"libmpv.so", "libplayer.so", "libc++_shared.so", "libavcodec.so", "libavformat.so",
                    "libavutil.so", "libavfilter.so", "libavdevice.so", "libswresample.so", "libswscale.so"}
        with zipfile.ZipFile(out / "libmpv-release-candidate.aar", "w") as archive:
            for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
                for name in sorted(required):
                    entry = f"jni/{abi}/{name}"
                    if entry == missing:
                        continue
                    data = b"fixture:" + abi.encode() + b"\0"
                    if name == "libavformat.so":
                        data += b"--enable-mbedtls --enable-gpl --enable-version3\0"
                        data += keys[:-1] if bad_tls else keys
                    archive.writestr(entry, data)
            if bad_abi:
                archive.writestr("jni/mips/libmpv.so", b"unadmitted")

    @staticmethod
    def readelf(*args):
        data = Path(args[-1]).read_bytes()
        elf_class, machine = ("ELF32", "ARM") if b"armeabi-v7a" in data else (
            ("ELF64", "AArch64") if b"arm64-v8a" in data else ("ELF64", "Advanced Micro Devices X86-64"))
        if "-h" in args:
            return f"Class: {elf_class}\nMachine: {machine}\nType: DYN\nData: little endian\n"
        return ("LOAD 0x0000 0x0000 0x0000 0x1000 0x1000 R E 0x4000\n"
                "GNU_RELRO 0x4000 0x4000 0x4000 0x4000 0x4000 R 0x1\n")

    def run_fixture(self, **options):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            self.fixture(out, **options)
            MODULE.android(out, out, out)
            import json
            result = json.loads((out / "android-artifact-evidence.json").read_text())
            self.assertEqual(len(result["libraries"]), 30)
            self.assertFalse(result["promotionEligible"])
            self.assertFalse(result["runtimeSecurityTested"])
            self.assertFalse(result["appAndSeamBindingChanged"])

    def test_three_abi_receipt_remains_unpromoted(self):
        with patch.object(MODULE, "run", side_effect=self.readelf):
            self.run_fixture()

    def test_missing_library_rejects(self):
        with patch.object(MODULE, "run", side_effect=self.readelf), self.assertRaises(ValueError):
            self.run_fixture(missing="jni/x86_64/libmpv.so")

    def test_extra_abi_rejects(self):
        with patch.object(MODULE, "run", side_effect=self.readelf), self.assertRaises(ValueError):
            self.run_fixture(bad_abi=True)

    def test_incomplete_distrust_payload_rejects(self):
        with patch.object(MODULE, "run", side_effect=self.readelf), self.assertRaises(ValueError):
            self.run_fixture(bad_tls=True)

    def test_wrong_elf_identity_rejects(self):
        def wrong(*args):
            return self.readelf(*args).replace("AArch64", "RISC-V")
        with patch.object(MODULE, "run", side_effect=wrong), self.assertRaises(ValueError):
            self.run_fixture()

    def test_64_bit_page_alignment_rejects(self):
        def unaligned(*args):
            return self.readelf(*args).replace("E 0x4000", "E 0x1000")
        with patch.object(MODULE, "run", side_effect=unaligned), self.assertRaises(ValueError):
            self.run_fixture()

    # Actual arm64 libavcodec program-header geometry from artifact 12338601965.
    # These are metadata fixtures, not execution of that library or a device-security test.
    @staticmethod
    def isolated_relro_headers():
        return [
            'LOAD 0x000000 0x000000 0x000000 0xb3c840 0xb3c840 R E 0x4000',
            'LOAD 0xb3c840 0xb40840 0xb40840 0x045228 0x0457c0 RW 0x4000',
            'LOAD 0xb81a68 0xb89a68 0xb89a68 0x001020 0x5ae498 RW 0x4000',
            'GNU_RELRO 0xb3c840 0xb40840 0xb40840 0x045228 0x0457c0 R 0x1',
        ]

    def test_isolated_relro_layout_reaches_existing_full_artifact_gate(self):
        def isolated(*args):
            if '-h' in args:
                return self.readelf(*args)
            return '\n'.join(self.isolated_relro_headers()) + '\n'
        with patch.object(MODULE, 'run', side_effect=isolated):
            self.run_fixture()

    def test_relro_shared_writable_tail_is_not_exempt(self):
        rows = [line.split() for line in self.isolated_relro_headers()]
        rows[1][5] = '0x0467c0'  # containing LOAD extends past RELRO into mutable data
        self.assertFalse(MODULE.relro_16k_safe(rows[-1], rows[:-1]))

    def test_relro_next_load_overlapping_rounded_padding_rejects(self):
        rows = [line.split() for line in self.isolated_relro_headers()]
        rows[2][2] = '0xb87000'  # after RELRO end, but inside rounded protection end 0xb88000
        self.assertFalse(MODULE.relro_16k_safe(rows[-1], rows[:-1]))

    def test_relro_previous_load_overlapping_rounded_start_rejects(self):
        rows = [line.split() for line in self.isolated_relro_headers()]
        rows[0][5] = '0xb40500'  # before RELRO start, but inside rounded protection start 0xb40000
        self.assertFalse(MODULE.relro_16k_safe(rows[-1], rows[:-1]))

    def test_relro_next_load_at_exact_next_page_is_safe(self):
        rows = [line.split() for line in self.isolated_relro_headers()]
        rows[2][2] = '0xb88000'
        self.assertTrue(MODULE.relro_16k_safe(rows[-1], rows[:-1]))

    def test_relro_ambiguous_or_wrong_file_mapping_rejects(self):
        rows = [line.split() for line in self.isolated_relro_headers()]
        self.assertFalse(MODULE.relro_16k_safe(rows[-1], rows[:-1] + [rows[1]]))
        rows[1][1] = '0xb3c841'
        self.assertFalse(MODULE.relro_16k_safe(rows[-1], rows[:-1]))

    def test_isolated_relro_does_not_excuse_bad_load_alignment(self):
        def unaligned(*args):
            if '-h' in args:
                return self.readelf(*args)
            return '\n'.join(self.isolated_relro_headers()).replace('E 0x4000', 'E 0x1000')
        with patch.object(MODULE, 'run', side_effect=unaligned), self.assertRaises(ValueError):
            self.run_fixture()

    def test_explicit_inspector_is_used_and_separately_identified(self):
        def reader_output(*args):
            return 'LLVM synthetic inspection fixture' if '--version' in args else self.readelf(*args)
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            self.fixture(out)
            binary = out / 'llvm-readobj'
            binary.write_bytes(b'fixture only, not executable LLVM')
            reader = out / 'llvm-readelf'
            reader.symlink_to(binary.name)
            with patch.object(MODULE, 'run', side_effect=reader_output) as calls:
                MODULE.android(out, out, out, readelf=reader)
            import json
            result = json.loads((out / 'android-artifact-evidence.json').read_text())
            self.assertEqual(len(result['libraries']), 30)
            self.assertEqual(result['inspection']['resolvedReader'], str(reader.resolve()))
            self.assertEqual(result['inspection']['readerSHA256'], hashlib.sha256(reader.read_bytes()).hexdigest())
            self.assertEqual(result['inspection']['validatorSHA256'], hashlib.sha256(Path(MODULE.__file__).read_bytes()).hexdigest())
            self.assertTrue(all(call.args[0] == str(reader) for call in calls.call_args_list))
            self.assertFalse(result['promotionEligible'])
            self.assertFalse(result['runtimeSecurityTested'])
            self.assertFalse(result['appAndSeamBindingChanged'])

    def test_relative_inspector_path_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.android(Path('.'), Path('.'), Path('.'), readelf=Path('llvm-readelf'))


class AndroidMpvComponentBinding(unittest.TestCase):
    # Synthetic ZIP contents only: this checks acquisition policy, never native compatibility.
    URL = "https://github.com/VortXTV/VortX/releases/download/vendor-fixture/libmpv.aar"

    @staticmethod
    def fixture(path, *, min_sdk="26", missing=None, extra_abi=False, duplicate=False, manifest=None):
        entries = {
            "classes.jar": b"synthetic classes, not executable",
            "AndroidManifest.xml": manifest if manifest is not None else (
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                'package="dev.jdtech.mpv"><uses-sdk android:minSdkVersion="' + min_sdk + '"/></manifest>'
            ).encode(),
        }
        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            for name in ("libmpv.so", "libplayer.so", "libc++_shared.so", "libavcodec.so",
                         "libavformat.so", "libavutil.so", "libavfilter.so", "libavdevice.so",
                         "libswresample.so", "libswscale.so"):
                if f"jni/{abi}/{name}" != missing:
                    entries[f"jni/{abi}/{name}"] = b"synthetic, not an ELF"
        if extra_abi:
            entries["jni/mips/libmpv.so"] = b"unadmitted"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
            if duplicate:
                archive.writestr("classes.jar", b"duplicate")
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_empty_selection_has_no_network_and_both_consumers_share_full_only_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "android").mkdir()
            (root / "android/mpv-component.properties").write_text("url=\nsha256=\n")
            with patch.object(ACQUIRE, "build_opener", side_effect=AssertionError("unexpected network")), patch("builtins.print"):
                self.assertIsNone(ACQUIRE.acquire(root))
            self.assertFalse((root / "android/.gradle").exists())
        # Source contracts only; real Gradle resolution/package-content gates remain separate.
        app = (ROOT / "android/app/build.gradle.kts").read_text()
        seam = (ROOT / "android/mpv-seam/build.gradle.kts").read_text()
        root_build = (ROOT / "android/build.gradle.kts").read_text()
        self.assertEqual(app.count('"fullImplementation"(checkNotNull(rootProject.extra["vortxMpvAarDependency"]))'), 1)
        self.assertIn('"fullImplementation"(project(":mpv-seam"))', app)
        self.assertEqual(seam.count('mpvLinkAar(checkNotNull(rootProject.extra["vortxMpvAarDependency"]))'), 1)
        self.assertIn("dependsOn(mpvLinkAar)", seam)
        self.assertIn('extra["vortxMpvAarDependency"] = files(aar).builtBy(verifyMpvComponent)', root_build)
        self.assertIn('extra["vortxMpvAarDependency"] = libs.mpv.libmpv', root_build)
        self.assertNotIn('"playImplementation"(rootProject.extra["vortxMpvAarDependency"])', app)
        self.assertNotIn('"playImplementation"(project(":mpv-seam"))', app)

    def test_selection_and_redirects_refuse_unapproved_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            descriptor = Path(directory) / "component.properties"
            for text in (
                f"url={self.URL}\nsha256=\n", "url=\nsha256=" + "a" * 64 + "\n",
                "url=https://example.com/private.aar\nsha256=" + "a" * 64 + "\n",
                f"url={self.URL}?token=not-a-credential\nsha256=" + "a" * 64 + "\n",
                f"url={self.URL}\nsha256=" + "a" * 64 + "\nurl=\n",
            ):
                with self.subTest(descriptor=text):
                    descriptor.write_text(text)
                    with self.assertRaises(ValueError):
                        ACQUIRE.selection(descriptor)
        handler = ACQUIRE.ReleaseRedirects()
        request = ACQUIRE.Request(self.URL)
        for url in ("http://github.com/payload", "https://example.com/payload",
                    "https://user@github.com/payload", "https://github.com:444/payload"):
            with self.subTest(redirect=url), self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "Found", {}, url)
        allowed = handler.redirect_request(request, None, 302, "Found", {},
                                           "https://release-assets.githubusercontent.com/payload?signature=synthetic")
        self.assertEqual(allowed.host, "release-assets.githubusercontent.com")

    def test_cached_bytes_are_reused_and_bad_or_linked_cache_never_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "android").mkdir()
            source = root / "fixture.aar"
            checksum = self.fixture(source)
            (root / "android/mpv-component.properties").write_text(f"url={self.URL}\nsha256={checksum}\n")
            target = root / "android/.gradle/vortx-mpv-components" / checksum / "libmpv.aar"
            target.parent.mkdir(parents=True)
            original = source.read_bytes()
            target.write_bytes(original)
            inode = target.stat().st_ino
            with patch.object(ACQUIRE, "build_opener", side_effect=AssertionError("unexpected network")), patch("builtins.print"):
                ACQUIRE.acquire(root)
                self.assertEqual(target.read_bytes(), original)
                self.assertEqual(target.stat().st_ino, inode)
                target.write_bytes(b"corrupt existing cache")
                with self.assertRaisesRegex(ValueError, "digest mismatch"):
                    ACQUIRE.acquire(root)
                self.assertEqual(target.read_bytes(), b"corrupt existing cache")
                target.unlink()  # fixture-owned path only; production never removes a bad cache
                target.symlink_to(source)
                with self.assertRaisesRegex(ValueError, "linked"):
                    ACQUIRE.acquire(root)
                self.assertTrue(target.is_symlink())
                self.assertEqual(source.read_bytes(), original)

    def test_actual_aar_content_gate_accepts_exact_shape_and_rejects_wrong_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fixture.aar"
            checksum = self.fixture(target)
            ACQUIRE.verify_aar(target, checksum)
            for options in ({"min_sdk": "25"}, {"extra_abi": True},
                            {"missing": "jni/arm64-v8a/libavcodec.so"}):
                with self.subTest(options=options):
                    checksum = self.fixture(target, **options)
                    with self.assertRaises(ValueError):
                        ACQUIRE.verify_aar(target, checksum)
            with self.assertWarns(UserWarning):
                checksum = self.fixture(target, duplicate=True)
            with self.assertRaisesRegex(ValueError, "membership"):
                ACQUIRE.verify_aar(target, checksum)

    def test_manifest_encoding_and_character_references_keep_the_same_identity(self):
        document = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                    'package="dev.jdtech.mpv"><uses-sdk android:minSdkVersion="2&#54;"/></manifest>')
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fixture.aar"
            for encoding in ("utf-8", "utf-16"):
                with self.subTest(encoding=encoding):
                    checksum = self.fixture(target, manifest=document.encode(encoding))
                    ACQUIRE.verify_aar(target, checksum)

    def test_aar_manifest_rejects_dtd_entities_in_every_supported_encoding(self):
        manifest = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                    'package="dev.jdtech.mpv"><uses-sdk android:minSdkVersion="26"/></manifest>')
        declarations = (
            '<!DOCTYPE manifest>',
            '<!DOCTYPE manifest [<!ENTITY value "26">]>',
            '<!DOCTYPE manifest [<!ENTITY value SYSTEM "file:///unread-fixture">]>',
            '<!DOCTYPE manifest [<!ENTITY % value "ignored">%value;]>',
            '<!DOCTYPE manifest SYSTEM "https://unread.invalid/fixture.dtd">',
        )
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "fixture.aar"
            for declaration in declarations:
                for encoding in ("utf-8", "utf-16"):
                    with self.subTest(declaration=declaration, encoding=encoding):
                        checksum = self.fixture(target, manifest=(declaration + manifest).encode(encoding))
                        with self.assertRaisesRegex(ValueError, "declarations"):
                            ACQUIRE.verify_aar(target, checksum)

    def test_manifest_structure_and_malformed_xml_fail_closed(self):
        for raw in (b"<manifest>", b"<manifest>" + b"<node>" * 32 + b"</node>" * 32 + b"</manifest>",
                    b"<manifest>" + b"<node/>" * 4096 + b"</manifest>", b" " * 65537):
            with self.subTest(prefix=raw[:40]), self.assertRaises(ValueError):
                ACQUIRE.manifest_identity(raw)


if __name__ == "__main__":
    unittest.main()
