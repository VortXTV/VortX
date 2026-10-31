"""Secretless producer contracts. Synthetic ELF text is not actual native acceptance."""
import base64
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import stat
import subprocess
import sys
from contextlib import redirect_stdout
from copy import deepcopy
from pathlib import Path
import tarfile
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
    def test_apple_subtitle_readonly_copyback_policy(self):
        apple = (ROOT / 'scripts/build-mpvkit-dvfel.sh').read_text()
        signature = 'run_with_subtitle_sources_readonly() (\n'
        self.assertEqual(apple.count(signature), 1)
        function = signature + apple.split(signature, 1)[1].split('\n)\n', 1)[0] + '\n)\n'
        self.assertNotIn('(deny network', function)
        self.assertEqual(function.count('(subpath (param '), 4)
        call = 'run_with_subtitle_sources_readonly "$(cd "$WORK" && pwd -P)" /usr/bin/env swift run --jobs 1'
        self.assertEqual(apple.count(call), 1)
        self.assertLess(apple.index('\nprepare_subtitle_sources\n'), apple.index(call))
        self.assertIn('"$SUBTITLE_SOURCE_HELPER" verify "$WORK"', apple)
        if sys.platform != 'darwin' or not Path('/usr/bin/sandbox-exec').is_file():
            self.skipTest('actual source-write sandbox regression requires macOS')
        names = ('libunibreak-8.0-9c4fad6e', 'libfribidi-1.0.17-6949dcde',
                 'libharfbuzz-15.0.0-968536e9', 'libbluray-1.5.0-f676408e')
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve() / 'work with spaces'
            work.mkdir()
            originals = {}
            for name in names:
                source = work / 'dist' / name
                source.mkdir(parents=True)
                header = source / 'shader.hh'
                header.write_bytes(b'known shader body\n')
                header.chmod(0o644)
                os.utime(header, ns=(1700000000123456789, 1700000000123456789))
                value = header.stat()
                originals[header] = (header.read_bytes(), value.st_mtime_ns,
                                     stat.S_IMODE(value.st_mode))
            script = work / 'copyback_fixture.py'
            script.write_text('''import os, shutil, sys
from pathlib import Path
work, mode = Path(sys.argv[1]), sys.argv[2]
names = ('libunibreak-8.0-9c4fad6e', 'libfribidi-1.0.17-6949dcde', 'libharfbuzz-15.0.0-968536e9', 'libbluray-1.5.0-f676408e')
for name in names:
    source = work / 'dist' / name / 'shader.hh'
    output = work / 'outputs' / name / 'shader.hh'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b'known shader body\\n' if mode == 'match' else b'changed shader body\\n')
    try:
        shutil.copyfile(output, source)
    except OSError:
        # Same fallback as pinned HarfBuzz gen-gpu-shader-artifacts.py.
        if output.read_text() != source.read_text():
            sys.exit('source shader is out of date')
    else:
        sys.exit('source copy unexpectedly succeeded')
    try:
        os.utime(source, None)
    except OSError:
        pass
    else:
        sys.exit('source metadata write unexpectedly succeeded')
    print('protected ' + name)
''')

            def invoke(mode):
                return subprocess.run(
                    ['/bin/bash', '-c', function + '\nrun_with_subtitle_sources_readonly "$@"',
                     'readonly-fixture', str(work), sys.executable, str(script), str(work), mode],
                    cwd=work, capture_output=True, text=True, timeout=30)

            matched = invoke('match')
            self.assertEqual(matched.returncode, 0, matched.stdout + matched.stderr)
            for name in names:
                self.assertIn('protected ' + name, matched.stdout)
                self.assertEqual((work / 'outputs' / name / 'shader.hh').read_bytes(),
                                 b'known shader body\n')
            mismatched = invoke('mismatch')
            self.assertNotEqual(mismatched.returncode, 0)
            self.assertIn('source shader is out of date', mismatched.stderr)
            for header, original in originals.items():
                value = header.stat()
                self.assertEqual((header.read_bytes(), value.st_mtime_ns,
                                  stat.S_IMODE(value.st_mode)), original)

    def test_all_recipe_inputs_match(self):
        lines = (ROOT / "scripts/native-media-hosted/inputs.sha256").read_text().splitlines()
        names = set()
        for line in lines:
            expected, name = line.split("  ", 1)
            self.assertNotIn(name, names)
            names.add(name)
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), expected)
        self.assertEqual(len(names), 36)
        self.assertEqual(names, {
            'scripts/assemble-mpvkit-dvfel.sh',
            'scripts/build-mpvkit-dvfel.sh',
            'scripts/ffmpeg-response-witness.patch',
            'scripts/ffmpeg-response-generation.patch',
            'scripts/mpv-completed-response-observation.patch',
            'scripts/ffmpeg-sent-request-evidence.patch',
            'scripts/mpv-sent-request-evidence.patch',
            'scripts/mpv-bounded-prefix-request.patch',
            'scripts/ffmpeg-original-transport-evidence.patch',
            'scripts/mpv-original-transport-evidence.patch',
            'scripts/ffmpeg-finite-reference-reader.patch',
            'scripts/mpv-finite-reference-reader.patch',
            'scripts/mpv-coreaudio-hotplug-lifecycle.patch',
            'scripts/mpv-http-seek-interrupt.patch',
            'scripts/mpv-moltenvk-resize.patch',
            'scripts/mpv-original-local-file-witness.patch',
            'scripts/mpv-original-http-reference-recipe.patch',
            'scripts/mpv-original-http-cancel-lifetime.patch',
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
        self.assertIn('scripts/mpv-original-http-cancel-lifetime.patch', names)

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
                ("mpv-original-http-reference-recipe.patch", "0013-original-http-reference-recipe.patch", "0008-original-http-reference-recipe.patch"),
                ("mpv-original-http-cancel-lifetime.patch", "0014-original-http-cancel-lifetime.patch", "0009-original-http-cancel-lifetime.patch"),
                ("mpv-completed-response-observation.patch", "0015-completed-response-observation.patch", "0010-completed-response-observation.patch"),
                ("mpv-sent-request-evidence.patch", "0016-sent-request-evidence.patch", "0011-sent-request-evidence.patch"),
                ("mpv-bounded-prefix-request.patch", "0017-bounded-prefix-request.patch", "0012-bounded-prefix-request.patch"),
                ("mpv-original-transport-evidence.patch", "0018-original-transport-evidence.patch", "0013-original-transport-evidence.patch"),
                ("mpv-finite-reference-reader.patch", "0019-finite-reference-reader.patch", "0014-finite-reference-reader.patch")]:
            if source == "mpv-sent-request-evidence.patch":
                self.assertIn('SENT_MPV_PATCH="$REPO/scripts/' + source + '"', apple)
                self.assertIn('copy_exact "$SENT_MPV_PATCH" "$GENERATED_SENT_MPV_PATCH"', apple)
            elif source == "mpv-bounded-prefix-request.patch":
                self.assertIn('PREFIX_PATCH="$REPO/scripts/' + source + '"', apple)
                self.assertIn('copy_exact "$PREFIX_PATCH" "$GENERATED_PREFIX_PATCH"', apple)
            elif source == "mpv-original-transport-evidence.patch":
                self.assertIn('TRANSPORT_MPV_PATCH="$REPO/scripts/' + source + '"', apple)
                self.assertIn('copy_exact "$TRANSPORT_MPV_PATCH" "$GENERATED_TRANSPORT_MPV_PATCH"', apple)
            elif source == "mpv-finite-reference-reader.patch":
                self.assertIn('READER_MPV_PATCH="$REPO/scripts/' + source + '"', apple)
                self.assertIn('copy_exact "$READER_MPV_PATCH" "$GENERATED_READER_MPV_PATCH"', apple)
            else:
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
        self.assertLess(apple.index('copy_exact "$REPO/scripts/mpv-original-http-reference-recipe.patch"'),
                        apple.index('copy_exact "$REPO/scripts/mpv-original-http-cancel-lifetime.patch"'))
        self.assertLess(android.index('cp "$root/scripts/mpv-original-http-reference-recipe.patch"'),
                        android.index('cp "$root/scripts/mpv-original-http-cancel-lifetime.patch"'))
        self.assertLess(android.index("0009-original-http-cancel-lifetime.patch"),
                        android.index("bash patch.sh"))
        self.assertLess(apple.index('copy_exact "$REPO/scripts/mpv-original-http-cancel-lifetime.patch"'),
                        apple.index('copy_exact "$REPO/scripts/mpv-completed-response-observation.patch"'))
        self.assertLess(android.index('cp "$root/scripts/mpv-original-http-cancel-lifetime.patch"'),
                        android.index('cp "$root/scripts/mpv-completed-response-observation.patch"'))
        self.assertLess(android.index("0010-completed-response-observation.patch"),
                        android.index("bash patch.sh"))
        self.assertLess(apple.index('copy_exact "$REPO/scripts/mpv-completed-response-observation.patch"'),
                        apple.index('copy_exact "$SENT_MPV_PATCH" "$GENERATED_SENT_MPV_PATCH"'))
        self.assertLess(android.index('cp "$root/scripts/mpv-completed-response-observation.patch"'),
                        android.index('cp "$root/scripts/mpv-sent-request-evidence.patch"'))
        self.assertLess(android.index("0011-sent-request-evidence.patch"), android.index("bash patch.sh"))

    def test_response_witness_is_the_same_exact_ffmpeg_producer_on_both_lanes(self):
        relative = "scripts/ffmpeg-response-witness.patch"
        patch_bytes = (ROOT / relative).read_bytes()
        self.assertEqual(hashlib.sha256(patch_bytes).hexdigest(),
                         "6a2bf6d0feff31280470ac46e9c56b2e0a4522513959784dcb04aaf196334b9b")
        patch_text = patch_bytes.decode()
        self.assertEqual([line for line in patch_text.splitlines() if line.startswith("--- ")],
                         ["--- a/libavformat/http.c"])
        self.assertEqual([line for line in patch_text.splitlines() if line.startswith("+++ ")],
                         ["+++ b/libavformat/http.c"])
        # Completed read-only metadata only, not a worker/current-response reader.
        for option in ("response_etag", "response_location"):
            self.assertIn('AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY', next(
                line for line in patch_text.splitlines()
                if line.startswith('+    { "' + option + '"')))
        apple = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
        android = (ROOT / "scripts/native-media-hosted/build.sh").read_text()
        self.assertIn('RESPONSE_PATCH="$REPO/scripts/ffmpeg-response-witness.patch"', apple)
        self.assertIn('copy_exact "$RESPONSE_PATCH" "$GENERATED_RESPONSE_PATCH"', apple)
        self.assertIn('/patch/FFmpeg/0001-response-witness.patch"', apple)
        self.assertLess(apple.index('copy_exact "$RESPONSE_PATCH" "$GENERATED_RESPONSE_PATCH"'),
                        apple.index('swift run --jobs 1 --build-path'))
        self.assertLess(apple.index('build enable-gpl platform=ios,tvos,macos'),
                        apple.index('FFMPEG_RESPONSE_SOURCE='))
        copy = 'cp "$root/scripts/ffmpeg-response-witness.patch" "$upstream/buildscripts/patches/ffmpeg/0002-response-witness.patch"'
        self.assertIn(copy, android)
        self.assertLess(android.index('buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch; do'),
                        android.index(copy))
        self.assertLess(android.index(copy), android.index("bash patch.sh"))
        source_check = android.index("deps/ffmpeg/libavformat/http.c | shasum")
        self.assertLess(android.index("bash patch.sh"), source_check)
        self.assertLess(source_check, android.index('for arch in armv7l arm64 x86_64;'))
        # The original witness delta is pinned above; final source includes the
        # complete later finite/sparse sequence rather than its historical HTTP.
        for recipe in (apple, android):
            self.assertIn("946fcce07b6dcd0331c8cc609192aeff5e1924f8", recipe)
            self.assertIn("d1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831", recipe)
        # The preexisting lexical patcher remains the dependency sequence authority.
        patcher = (ROOT / "scripts/native-media-hosted/android/buildscripts/patch.sh").read_text()
        self.assertIn('PATCHES=(patches/*)', patcher)
        self.assertIn('patches=("$dep_path"/*)', patcher)
        self.assertIn('git apply --reverse --check', patcher)

    def test_completed_response_observation_preserves_source_and_sequence_fences(self):
        generation = (ROOT / "scripts/ffmpeg-response-generation.patch").read_bytes()
        observation = (ROOT / "scripts/mpv-completed-response-observation.patch").read_bytes()
        self.assertEqual(hashlib.sha256(generation).hexdigest(),
                         "ddfb68b5d7ed3779cfa69a75a28e9d4b17bd4f28529cccf26a005e790da03098")
        self.assertEqual(hashlib.sha256(observation).hexdigest(),
                         "c038924be4c9b0ef187e1e9336d201b866dfa6f13457817c6e8c2d484e882e8e")
        generation_text, observation_text = generation.decode(), observation.decode()
        self.assertEqual([line for line in generation_text.splitlines() if line.startswith("+++ ")],
                         ["+++ b/libavformat/http.c"])
        self.assertEqual([line for line in observation_text.splitlines() if line.startswith("+++ ")],
                         ["+++ b/stream/reference_source.h", "+++ b/stream/stream_lavf.c"])
        self.assertIn('AV_OPT_TYPE_INT64', next(line for line in generation_text.splitlines()
                                              if line.startswith('+    { "response_generation"')))
        self.assertIn('AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY', next(
            line for line in generation_text.splitlines() if line.startswith('+    { "response_generation"')))
        self.assertIn('#if HAVE_PTHREADS || HAVE_W32THREADS || HAVE_OS2THREADS', generation_text)
        self.assertIn('static AVMutex response_generation_lock = AV_MUTEX_INITIALIZER;', generation_text)
        self.assertIn('last_response_generation < INT64_MAX', generation_text)
        self.assertIn('s->response_generation = 0;', generation_text)
        self.assertIn('INITIAL_REQUEST_ONLY', observation_text)
        for name in ('stream_reference_source_observe_response',
                     'stream_reference_source_revalidate_observation',
                     'stream_reference_observation_cancelled',
                     'stream_reference_observation_release'):
            self.assertIn(name, observation_text)
        apple = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
        android = (ROOT / "scripts/native-media-hosted/build.sh").read_text()
        self.assertIn('copy_exact "$RESPONSE_GENERATION_PATCH" "$GENERATED_RESPONSE_GENERATION_PATCH"', apple)
        self.assertIn('/patch/FFmpeg/0002-response-generation.patch"', apple)
        self.assertLess(apple.index('copy_exact "$RESPONSE_PATCH" "$GENERATED_RESPONSE_PATCH"'),
                        apple.index('copy_exact "$RESPONSE_GENERATION_PATCH" "$GENERATED_RESPONSE_GENERATION_PATCH"'))
        self.assertLess(apple.index('copy_exact "$RESPONSE_GENERATION_PATCH" "$GENERATED_RESPONSE_GENERATION_PATCH"'),
                        apple.index('swift run --jobs 1 --build-path'))
        copy = 'cp "$root/scripts/ffmpeg-response-generation.patch" "$upstream/buildscripts/patches/ffmpeg/0003-response-generation.patch"'
        self.assertIn(copy, android)
        self.assertLess(android.index('cp "$root/scripts/ffmpeg-response-witness.patch"'), android.index(copy))
        self.assertLess(android.index(copy), android.index("bash patch.sh"))
        for recipe in (apple, android):
            for afterimage in ("d1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831",
                               "650bf7b94771e70a6b934b21e362bc77f66ceb1d23ee684d2b169c6e694544a5",
                               "1f606a977b55f18fdb9f9fc7f5e4549b5774bef10a06c33b06ab945531909b29"):
                self.assertIn(afterimage, recipe)
        # Source contracts only. This does not exercise an HTTP owner or reader.

    def test_sent_request_private_header_and_native_only_link_contract(self):
        ffmpeg = (ROOT / "scripts/ffmpeg-sent-request-evidence.patch").read_bytes()
        mpv = (ROOT / "scripts/mpv-sent-request-evidence.patch").read_bytes()
        self.assertEqual(hashlib.sha256(ffmpeg).hexdigest(), "085b66cb5623ed8087481d3217b65da587b2970cd345a45896e7e87823dec9c9")
        self.assertEqual(hashlib.sha256(mpv).hexdigest(), "e3840084725be1f4948fb90c6fec87c35d55665f8310854713ebff496e1358bf")
        self.assertEqual([line for line in ffmpeg.decode().splitlines() if line.startswith("+++ ")],
                         ["+++ b/libavformat/http.c", "+++ b/libavformat/vortx_http_request.h"])
        self.assertEqual([line for line in mpv.decode().splitlines() if line.startswith("+++ ")],
                         ["+++ b/stream/reference_source.h", "+++ b/stream/stream_lavf.c",
                          "+++ b/stream/vortx_http_request.h", "+++ b/meson.build"])
        self.assertNotIn('+            if (!av_isalnum', ffmpeg.decode())
        self.assertIn("*c >= 'A' && *c <= 'Z'", ffmpeg.decode())
        self.assertIn("vortx_sent_request_link_roots = []", mpv.decode())
        self.assertIn("if host_machine.system() == 'android'", mpv.decode())
        for symbol in ("stream_reference_source_observe_sent_request",
                       "stream_reference_source_revalidate_sent_request",
                       "stream_reference_sent_request_cancelled", "stream_reference_sent_request_release",
                       "stream_reference_sent_request_values_clear", "stream_reference_sent_request_copy_values"):
            self.assertIn("'-Wl,--undefined=" + symbol + "'", mpv.decode())
        # Internal functions remain hidden. These link roots do not export APIs or mount a reader.
        self.assertNotIn("--export-dynamic", mpv.decode())
        self.assertNotIn("--dynamic-list", mpv.decode())
        apple = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
        android = (ROOT / "scripts/native-media-hosted/build.sh").read_text()
        copy = 'cp "$root/scripts/ffmpeg-sent-request-evidence.patch" "$upstream/buildscripts/patches/ffmpeg/0004-sent-request-evidence.patch"'
        self.assertIn(copy, android)
        self.assertLess(android.index('cp "$root/scripts/ffmpeg-response-generation.patch"'), android.index(copy))
        self.assertLess(android.index(copy), android.index("bash patch.sh"))
        self.assertIn('copy_exact "$SENT_FFMPEG_PATCH" "$GENERATED_SENT_FFMPEG_PATCH"', apple)
        self.assertIn('copy_exact "$SENT_MPV_PATCH" "$GENERATED_SENT_MPV_PATCH"', apple)
        self.assertIn('Sources/BuildScripts/patch/libmpv/0016-sent-request-evidence.patch', apple)
        self.assertLess(apple.index('copy_exact "$REPO/scripts/mpv-completed-response-observation.patch"'),
                        apple.index('copy_exact "$SENT_MPV_PATCH" "$GENERATED_SENT_MPV_PATCH"'))
        for lane in ("apple", "android"):
            roots = MODULE.CURRENT_SOURCE_ROOTS[lane]
            ffroot = next(name for name, pin in roots.items() if pin == MODULE.CURRENT_NATIVE_PINS["ffmpeg"])
            mproot = next(name for name, pin in roots.items() if pin == MODULE.CURRENT_NATIVE_PINS["mpv"])
            ffheader = MODULE.CURRENT_UNTRACKED_FILES[lane][ffroot]["libavformat/vortx_http_request.h"]
            mpheader = MODULE.CURRENT_UNTRACKED_FILES[lane][mproot]["stream/vortx_http_request.h"]
            self.assertEqual(ffheader, "d7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9")
            self.assertEqual(ffheader, mpheader)
        self.assertIn('native-media-hosted/evidence.py" apple-sent-abi "$STAGED_DEST"', apple)
        self.assertIn('evidence.py apple-sent-abi "$out/MPVKit-DVFEL"', android)

    def test_bounded_prefix_material_carrier_is_exact_private_and_ordered(self):
        material = (ROOT / "scripts/mpv-bounded-prefix-request.patch").read_bytes()
        self.assertEqual(hashlib.sha256(material).hexdigest(),
                         "edcfdc7d9d8da7f8a44b19d326a809de844be968cc8061b80744229da801331e")
        text = material.decode()
        self.assertEqual([line for line in text.splitlines() if line.startswith("+++ ")],
                         ["+++ b/stream/reference_source.h", "+++ b/stream/stream_lavf.c",
                          "+++ b/meson.build"])
        symbol = "stream_reference_source_prepare_prefix_request"
        self.assertIn(symbol, MODULE.SENT_MPV_FUNCTIONS)
        self.assertEqual(text.count("+        '-Wl,--undefined=" + symbol + "',"), 1)
        self.assertNotIn("--export-dynamic", text)
        self.assertNotIn("--dynamic-list", text)
        self.assertNotIn("avio_open", text)
        self.assertNotIn("avformat_open_input", text)
        apple = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
        android = (ROOT / "scripts/native-media-hosted/build.sh").read_text()
        self.assertLess(apple.index('copy_exact "$SENT_MPV_PATCH" "$GENERATED_SENT_MPV_PATCH"'),
                        apple.index('copy_exact "$PREFIX_PATCH" "$GENERATED_PREFIX_PATCH"'))
        copy = 'cp "$root/scripts/mpv-bounded-prefix-request.patch" "$upstream/buildscripts/patches/mpv/0012-bounded-prefix-request.patch"'
        self.assertLess(android.index('cp "$root/scripts/mpv-sent-request-evidence.patch"'), android.index(copy))
        self.assertLess(android.index(copy), android.index("bash patch.sh"))
        for lane, groups in MODULE.CURRENT_SOURCE_ROOTS.items():
            native = next(name for name, pin in groups.items() if pin == MODULE.CURRENT_NATIVE_PINS["mpv"])
            self.assertEqual(MODULE.CURRENT_UNTRACKED_FILES[lane][native]["stream/reference_source.h"],
                             "1f606a977b55f18fdb9f9fc7f5e4549b5774bef10a06c33b06ab945531909b29")

    def test_transport_carriers_are_exact_ordered_v2_and_keep_private_retention(self):
        ffmpeg = (ROOT / "scripts/ffmpeg-original-transport-evidence.patch").read_bytes()
        mpv = (ROOT / "scripts/mpv-original-transport-evidence.patch").read_bytes()
        self.assertEqual(hashlib.sha256(ffmpeg).hexdigest(),
                         "480302686b9fff135cd0665e7af76d635fc21d83f54ee0096578ddd6bd6d83e5")
        self.assertEqual(hashlib.sha256(mpv).hexdigest(),
                         "dad7f2d20ea14eb4661ef853978be78806e1b01fce67653e3ffec9b57d4a0e82")
        self.assertEqual([line for line in ffmpeg.decode().splitlines() if line.startswith("+++ ")],
                         ["+++ b/libavformat/" + name for name in
                          ("http.c", "url.h", "tls.c", "tls.h", "tls_securetransport.c",
                           "tls_mbedtls.c", "vortx_http_request.h")])
        self.assertEqual([line for line in mpv.decode().splitlines() if line.startswith("+++ ")],
                         ["+++ b/stream/" + name for name in
                          ("reference_source.h", "stream_lavf.c", "vortx_http_request.h")])
        self.assertIn('+    if (!shr->listen && !shr->numerichost)', ffmpeg.decode())
        for patch_text in (ffmpeg.decode(), mpv.decode()):
            for symbol in MODULE.SENT_FFMPEG_FUNCTIONS:
                self.assertIn(symbol, patch_text)
            self.assertNotIn('--export-dynamic', patch_text)
            self.assertNotIn('--dynamic-list', patch_text)
        self.assertIn('stream_reference_sent_request_copy_transport', mpv.decode())
        apple = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
        android = (ROOT / "scripts/native-media-hosted/build.sh").read_text()
        for source, apple_number, android_number in (
                ("ffmpeg-original-transport-evidence.patch", "0004-original-transport-evidence.patch",
                 "0005-original-transport-evidence.patch"),
                ("mpv-original-transport-evidence.patch", "0018-original-transport-evidence.patch",
                 "0013-original-transport-evidence.patch")):
            kind = "FFMPEG" if source.startswith("ffmpeg") else "MPV"
            folder = "ffmpeg" if kind == "FFMPEG" else "mpv"
            copy = 'copy_exact "$TRANSPORT_' + kind + '_PATCH" "$GENERATED_TRANSPORT_' + kind + '_PATCH"'
            self.assertIn(copy, apple)
            self.assertIn(apple_number, apple)
            self.assertLess(apple.index(copy), apple.index('swift run --jobs 1 --build-path'))
            android_copy = ('cp "$root/scripts/' + source + '" "$upstream/buildscripts/patches/' +
                            folder + '/' + android_number + '"')
            self.assertIn(android_copy, android)
            self.assertLess(android.index(android_copy), android.index('bash patch.sh'))
        self.assertLess(apple.index('copy_exact "$PREFIX_PATCH" "$GENERATED_PREFIX_PATCH"'),
                        apple.index('copy_exact "$TRANSPORT_MPV_PATCH" "$GENERATED_TRANSPORT_MPV_PATCH"'))
        self.assertLess(android.index('cp "$root/scripts/mpv-bounded-prefix-request.patch"'),
                        android.index('cp "$root/scripts/mpv-original-transport-evidence.patch"'))
        self.assertIn('cold_paths=(dist)', android)
        self.assertIn('cold_paths=(buildscripts/deps buildscripts/prefix libmpv/src/main/jniLibs libmpv/build)', android)
        self.assertIn('[[ ! -e "$upstream/$relative" && ! -L "$upstream/$relative" ]]', android)
        assembly = (ROOT / 'scripts/native-media-hosted/android-assembly.patch').read_text()
        self.assertIn('-Wl,-u,stream_reference_sent_request_copy_transport', assembly)
        self.assertIn('-Dstrip=false', assembly)
        self.assertIn('keepDebugSymbols', assembly)
        self.assertIn('**/libmpv.so', assembly)
        self.assertNotIn('--export-dynamic', assembly)
        self.assertNotIn('--dynamic-list', assembly)

    def test_finite_reference_reader_carriers_preserve_full_source_and_patch_order(self):
        ffmpeg = (ROOT / 'scripts/ffmpeg-finite-reference-reader.patch').read_bytes()
        mpv = (ROOT / 'scripts/mpv-finite-reference-reader.patch').read_bytes()
        self.assertEqual(hashlib.sha256(ffmpeg).hexdigest(),
                         'a06f4b8b9eadc12eace93b1b340e0555116061188d0674f063698ea75d953abd')
        self.assertEqual(hashlib.sha256(mpv).hexdigest(),
                         '42c020f9f6550af5072a8eff1b5860249bb9df5f9418855cb4636cd15854f7f2')
        self.assertEqual([line for line in ffmpeg.decode().splitlines() if line.startswith('+++ ')],
                         ['+++ b/libavformat/' + name for name in
                          ('http.c', 'url.h', 'avio.c', 'tcp.c', 'tls.c',
                           'vortx_reference_reader.inc', 'vortx_reference_pin.h',
                           'vortx_reference_reader_stream.h', 'vortx_reference_sparse.h',
                           'vortx_reference_sparse.inc')])
        self.assertEqual([line for line in mpv.decode().splitlines() if line.startswith('+++ ')],
                         ['+++ b/' + name for name in
                          ('demux/demux.c', 'demux/demux.h', 'demux/demux_lavf.c',
                           'demux/reference_reader.c', 'demux/reference_reader.h',
                           'demux/reference_reader_internal.h', 'stream/stream_lavf.c',
                           'stream/reference_source.h', 'stream/vortx_reference_reader_stream.h',
                           'meson.build', 'player/owned_subtitle.c', 'player/owned_subtitle.h',
                           'player/command.c', 'player/reference_owned.inc', 'sub/owned_text_slot.h',
                           'sub/osd.c', 'sub/dec_sub.c', 'sub/dec_sub.h',
                           'demux/demux_mkv.c', 'demux/reference_mkv.h',
                           'demux/reference_mkv_reader.c', 'demux/reference_mkv_sparse.h',
                           'demux/reference_mkv_sparse_planner.c',
                           'demux/reference_mkv_sparse_planner.h',
                           'demux/reference_mkv_sparse_worker.c',
                           'stream/vortx_reference_sparse.h')])
        self.assertEqual(ffmpeg.decode().count('new file mode 100644\n'), 5)
        self.assertEqual(mpv.decode().count('new file mode 100644\n'), 12)
        for text in (ffmpeg.decode(), mpv.decode()):
            self.assertNotIn('--export-dynamic', text)
            self.assertNotIn('--dynamic-list', text)
        apple = (ROOT / 'scripts/build-mpvkit-dvfel.sh').read_text()
        android = (ROOT / 'scripts/native-media-hosted/build.sh').read_text()
        for kind, folder, apple_number, android_number in (
                ('FFMPEG', 'ffmpeg', '0005', '0006'), ('MPV', 'mpv', '0019', '0014')):
            source = folder + '-finite-reference-reader.patch'
            copy = 'copy_exact "$READER_' + kind + '_PATCH" "$GENERATED_READER_' + kind + '_PATCH"'
            previous = 'copy_exact "$TRANSPORT_' + kind + '_PATCH" "$GENERATED_TRANSPORT_' + kind + '_PATCH"'
            self.assertIn('READER_' + kind + '_PATCH="$REPO/scripts/' + source + '"', apple)
            self.assertIn(apple_number + '-finite-reference-reader.patch', apple)
            self.assertLess(apple.index(previous), apple.index(copy))
            self.assertLess(apple.index(copy), apple.index('swift run --jobs 1 --build-path'))
            android_copy = ('cp "$root/scripts/' + source + '" "$upstream/buildscripts/patches/' +
                            folder + '/' + android_number + '-finite-reference-reader.patch"')
            self.assertLess(android.index('cp "$root/scripts/' + folder + '-original-transport-evidence.patch"'),
                            android.index(android_copy))
            self.assertLess(android.index(android_copy), android.index('bash patch.sh'))
        # Source-carrier pairing only; these assertions execute no native/network reader.
        for lane, groups in MODULE.CURRENT_SOURCE_ROOTS.items():
            ffroot = next(name for name, pin in groups.items() if pin == MODULE.CURRENT_NATIVE_PINS['ffmpeg'])
            mproot = next(name for name, pin in groups.items() if pin == MODULE.CURRENT_NATIVE_PINS['mpv'])
            self.assertEqual(MODULE.CURRENT_UNTRACKED_FILES[lane][ffroot]['libavformat/vortx_reference_reader_stream.h'],
                             'adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87')
            self.assertEqual(MODULE.CURRENT_UNTRACKED_FILES[lane][ffroot]['libavformat/vortx_reference_reader_stream.h'],
                             MODULE.CURRENT_UNTRACKED_FILES[lane][mproot]['stream/vortx_reference_reader_stream.h'])

    def test_response_witness_source_evidence_profile_preserves_exact_capture_and_consumer(self):
        spec = importlib.util.spec_from_file_location(
            "current_native_response_packager", ROOT / "scripts/package-native-current-component.py")
        consumer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(consumer)
        self.assertEqual(MODULE.CURRENT_SOURCE_PROFILE, consumer.PROFILE)
        self.assertEqual(consumer.PROFILE, "original-http-sparse-native-reference-reader-v2-dependencies-openssl410-crypto-subtitles-bluray150-candidate")
        self.assertEqual(MODULE.CURRENT_RECIPE_PATHS, consumer.RECIPE_PATHS)
        self.assertEqual(len(consumer.RECIPE_PATHS), 36)
        manifest = ROOT / "scripts/native-media-hosted/inputs.sha256"
        self.assertEqual(hashlib.sha256(manifest.read_bytes()).hexdigest(), consumer.PROFILE_MANIFEST_SHA256)
        recipe = dict((name, checksum) for checksum, name in
                      (line.split("  ", 1) for line in manifest.read_text().splitlines()))
        self.assertEqual(MODULE.CURRENT_RESPONSE_FILES, consumer.RESPONSE)
        self.assertEqual(MODULE.CURRENT_READER_FFMPEG_CREATED, consumer.READER_FFMPEG_CREATED)
        self.assertEqual(MODULE.CURRENT_READER_MPV_FILES, consumer.READER_MPV)
        self.assertEqual(consumer.READER_FFMPEG_CREATED, {
            "libavformat/vortx_reference_reader.inc": "a8c74f929942423550dba65f738fd4d2ad2d63d975665f64e6da1b00f5001645",
            "libavformat/vortx_reference_pin.h": "e0ccea8466e28169d0882fd664081baa09d3a39626d5351a31804b6dc4bb4e94",
            "libavformat/vortx_reference_reader_stream.h": "adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87",
            "libavformat/vortx_reference_sparse.h": "fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c",
            "libavformat/vortx_reference_sparse.inc": "0e3201c26657765a1e6e7a15fe9db1bcac5cf96a8cb7e9d691533e0f4bf3f15f",
        })
        self.assertEqual(consumer.RESPONSE["libavformat/http.c"],
                         "d1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831")
        self.assertEqual(len(consumer.READER_MPV), 25)
        self.assertNotIn("meson.build", consumer.READER_MPV)
        native_created = {
            "demux/reference_mkv.h": "38df7814efc3aa7434e5afe269406a989ab6a5fa22a200aa28149a3ab68e46d9",
            "demux/reference_mkv_reader.c": "3ac442e8ff489d11f4a5df6b86f8d964457753f66ce5f3eb530d7db3746b6f7c",
            "demux/reference_mkv_sparse.h": "4b013b6e794257a576bc01f6becb9d120cb878e0851b2e0bdd2225dcf7b18df2",
            "demux/reference_mkv_sparse_planner.c": "e36c6a879138b26e125f647c9254b41674b22b338ab12838376fe8d38bdae056",
            "demux/reference_mkv_sparse_planner.h": "c88597a42186ceb81f45f1f44b3734469cf06889ea3bf91e4853b861943e84fe",
            "demux/reference_mkv_sparse_worker.c": "5deae68bf3c680aa4898ca6c8e0c0e76aa4628bffa693d0ae2d6dd287d9a5e64",
            "stream/vortx_reference_sparse.h": "fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c",
        }
        self.assertEqual({name: consumer.READER_MPV[name] for name in native_created},
                         native_created)
        self.assertEqual(consumer.READER_MPV["demux/demux_mkv.c"],
                         "1b7cc4d40efa0620bd10669dc44a7d6b32d0236e2ae2be3510a3bac0829e39c2")
        self.assertEqual(consumer.READER_MPV["demux/reference_reader.c"],
                         "222ec8920d38971d386470d8172e45a89a52350eb352124ddf954be9409b792b")
        self.assertEqual(consumer.READER_MPV["demux/demux.c"],
                         "f5a4cd7bf4e29902ef965e43027755c19ded1423129a3fbe9808ad89e64c0e1c")
        self.assertEqual(consumer.READER_MPV["demux/reference_reader.h"],
                         "59d669fb370bc12f01856031b8f9d908eb1d50a927d955ecb1fe0b4484c2407d")
        self.assertEqual(consumer.READER_MPV["player/command.c"],
                         "e7a19f392bb69e9d208382f157234ac3c908d22a0d4afee5f372ee8f9d33dade")
        self.assertEqual(consumer.READER_MPV["player/owned_subtitle.c"],
                         "014b93845488ef873a4d29c4c8dd4ada69d244626e7a7b38bac82809989c6b29")
        self.assertEqual(consumer.READER_MPV["player/reference_owned.inc"],
                         "23ac96bfedefcab2234afa2a6f329a36fac6735effca6798b4043d777b060217")
        self.assertEqual(set(consumer.CREATED_MPV), set(native_created) | {
            "player/owned_subtitle.c", "player/owned_subtitle.h", "player/reference_owned.inc",
            "demux/reference_reader.c", "demux/reference_reader.h",
            "demux/reference_reader_internal.h", "stream/vortx_reference_reader_stream.h",
            "sub/owned_text_slot.h", "stream/reference_source.h", "stream/vortx_http_request.h",
        })
        self.assertEqual({name: consumer.CREATED_MPV[name] for name in native_created},
                         native_created)
        meson = {
            "apple": "c2abd8f89a772717fdd4bcdbb4a2236d9fb28eca029acfe84bf12f7333df5a55",
            "android": "32c9a1321883f6a980652173061c9c01727ef83b7a0dfe6e8e3a22364b753d47"}
        self.assertEqual(MODULE.CURRENT_READER_MPV_MESON, meson)
        self.assertEqual(consumer.READER_MPV_MESON, meson)
        self.assertEqual(MODULE.CURRENT_MBEDTLS_FILES, consumer.MBEDTLS)
        self.assertEqual(consumer.MBEDTLS, {
            "apple": "77d72cb88fc662b984f051335b356abc3e76e97ce39302dde6961ecdbba7a332",
            "android": "7099664b2c15a784db38a0db7956f718862201ef6c02d27779b2fc654b44aeac"})
        for lane, groups in MODULE.CURRENT_SOURCE_ROOTS.items():
            self.assertEqual(len(consumer.READER_MPV | {"meson.build": consumer.READER_MPV_MESON[lane]}), 26)
            for directory, commit in groups.items():
                self.assertEqual(consumer.untracked(lane, {"commit": commit}, recipe),
                                 MODULE.CURRENT_UNTRACKED_FILES[lane][directory])
        for helper in ("buildscripts/include/download-lua.sh", "buildscripts/include/download-libunibreak.sh"):
            self.assertEqual(MODULE.CURRENT_UNTRACKED_FILES["android"]["_native-publisher"][helper],
                             recipe["scripts/native-media-hosted/android/" + helper])
        # These are synthetic source observations, not native tar/binary or HTTP execution.
        old_sources = ("6a34addba8bc8ce1a24b28a3faac3e6fc8b1c5d464be88946e4b0694eaf98a22",
                       "3c9becd663989d20b09805aeb99b525252908398e29b172e92e64f1c769831aa",
                       "db1b96a39966a51edbb10975b1cc67a69a6c744fa4101931470717cd63d44da0",
                       "b4261b2728bba10b77e99b43d2ee937a25392f9e53c15785f188566a8f166c1f",
                       "205a083b57dd105078e3f71a1d0fad1fb6342d023d9fae32a60cbf6227218e74",
                       "faebc27e86d3bf4375ef9c4461526f58caeaf3a6974d776f1a52159e29cdedd2",
                       "d4ec29f40e9302f6bb1abedcbd0c5adf87c20b11236a8ad8aff42fea46616802")
        for lane in ("apple", "android"):
            expected = dict(consumer.RESPONSE, **{"libavformat/tls_mbedtls.c": consumer.MBEDTLS[lane]})
            valid = {name: {"kind": "file", "tracked": True, "sha256": checksum}
                     for name, checksum in expected.items()}
            valid.update({name: {"kind": "file", "tracked": False, "sha256": checksum}
                          for name, checksum in consumer.READER_FFMPEG_CREATED.items()})
            self.assertEqual(len(expected), 8)
            self.assertEqual(len(valid), 13)
            for guard in (MODULE.require_current_response_source, consumer.require_response_source):
                guard(valid, lane)
                for path in expected:
                    for field, value in (("tracked", False), ("kind", "symlink"), ("sha256", "0" * 64)):
                        observed = deepcopy(valid)
                        observed[path][field] = value
                        with self.subTest(lane=lane, path=path, field=field), self.assertRaises(ValueError):
                            guard(observed, lane)
                    observed = deepcopy(valid)
                    del observed[path]
                    with self.assertRaises(ValueError):
                        guard(observed, lane)
                for old in old_sources:
                    observed = deepcopy(valid)
                    observed["libavformat/http.c"]["sha256"] = old
                    with self.assertRaises(ValueError):
                        guard(observed, lane)
                for path in consumer.READER_FFMPEG_CREATED:
                    for field, value in (("tracked", True), ("kind", "symlink"), ("sha256", "0" * 64)):
                        observed = deepcopy(valid)
                        observed[path][field] = value
                        with self.subTest(lane=lane, path=path, field=field), self.assertRaises(ValueError):
                            guard(observed, lane)
                    observed = deepcopy(valid)
                    del observed[path]
                    with self.assertRaises(ValueError):
                        guard(observed, lane)
                with self.assertRaises(ValueError):
                    guard(valid, "unknown")
                other = "android" if lane == "apple" else "apple"
                with self.assertRaises(ValueError):
                    guard(valid, other)

        # The dependency candidate retains seven strict Apple Git roots, adds
        # seven independently authenticated archive-backed source roots, and
        # carries the fixed Shaderc/OpenSSL/crypto/subtitle receipt families.
        # Synthetic
        # bytes below test policy only; fixed production pins are asserted before
        # substitutions.
        expected_apple_roots = {
            '_native-mpvkit': '2103893078c5e339073b11737b86f7f22b9c4491',
            'libmpv-master-8c67647b': '8c67647b50059406c5c0444903597281b81516cf',
            'FFmpeg-9.0.2-946fcce0': '946fcce07b6dcd0331c8cc609192aeff5e1924f8',
            'libplacebo-7.387.0-275f7dea': '275f7dea27924cdd34ab2e6c20e448b6bc4fab65',
            'lcms2-2.20rc1-13154341': '1315434113566bcf3eb46c2485fcc1c0a56ab806',
            'libdav1d-1.5.4-54706fc6': '54706fc6bc0cdecab7e9593974a4039cc038fca7',
            'openssl-4.1.0-2f4e3a5f': '2f4e3a5fec05394068cfa7379890ab552483a8a6'}
        self.assertEqual(MODULE.CURRENT_SOURCE_ROOTS['apple'], expected_apple_roots)
        self.assertEqual(len(MODULE.CURRENT_SOURCE_ROOTS['apple']), 7)
        self.assertEqual(len(consumer.OUTPUTS['apple']), 20)
        self.assertEqual(MODULE.CURRENT_UNTRACKED_FILES['apple']['libdav1d-1.5.4-54706fc6'], {})
        self.assertEqual(MODULE.CURRENT_UNTRACKED_FILES['apple']['openssl-4.1.0-2f4e3a5f'], {})
        self.assertEqual(MODULE.CURRENT_SOURCE_ROOTS['android']['harfbuzz'],
                         '35f656a1a2bab548ea7f54a6dd3fba2b09680d14')
        self.assertEqual(consumer.ANDROID_PINS['harfbuzz'],
                         '35f656a1a2bab548ea7f54a6dd3fba2b09680d14')
        self.assertNotIn(expected_apple_roots['lcms2-2.20rc1-13154341'],
                         MODULE.CURRENT_SOURCE_ROOTS['android'].values())
        libraries = ('Libmpv', 'Libavcodec', 'Libavdevice', 'Libavfilter', 'Libavformat',
                     'Libavutil', 'Libswresample', 'Libswscale', 'Libplacebo', 'lcms2', 'Libdav1d',
                     'Libssl', 'Libcrypto', 'gmp', 'nettle', 'hogweed', 'gnutls', 'Libsmbclient',
                     'Libunibreak', 'Libfribidi', 'Libharfbuzz', 'Libbluray')
        self.assertEqual(tuple(consumer.LIBRARIES), libraries)
        self.assertEqual(consumer.NATIVE_UPGRADES_PROFILE,
                         'native-upgrades-openssl410-crypto-subtitles-bluray150-v6')
        self.assertEqual(consumer.PROFILE,
                         'original-http-sparse-native-reference-reader-v2-dependencies-openssl410-crypto-subtitles-bluray150-candidate')
        self.assertEqual(consumer.CRYPTO_CHAIN_PROFILE, 'native-upgrades-crypto-chain-v1')
        self.assertEqual(consumer.CRYPTO_INSTALLED_HELPERS['Sources/BuildScripts/crypto-chain-gate.py'],
                         'be5bc18e00b9b1cb4c4c5889b0935b4cd5d1538a98bcfb985ccbfcb208825a9b')
        self.assertEqual(MODULE.CRYPTO_INSTALLED_HELPERS, consumer.CRYPTO_INSTALLED_HELPERS)
        self.assertEqual(consumer.CRYPTO_SOURCE_PROFILE,
                         'gmp630-nettle400-gnutls3813-release-sources-v1')
        self.assertEqual(tuple(row['id'] for row in consumer.CRYPTO_SOURCE_OUTPUTS),
                         ('gmp', 'nettle', 'gnutls'))
        self.assertEqual(len(consumer.CRYPTO_MATRIX), 9)
        self.assertEqual(tuple(row[0] for row in consumer.CRYPTO_LIBRARIES),
                         ('gmp', 'nettle', 'hogweed', 'gnutls', 'Libsmbclient'))
        self.assertEqual(consumer.SUBTITLE_SOURCE_PROFILE,
                         'unibreak800-fribidi1017-harfbuzz1500-bluray150-release-sources-v3-pax-ns')
        self.assertEqual(
            consumer.SUBTITLE_INSTALLED_HELPERS['Sources/BuildScripts/subtitle-release-sources.py'],
            'f082ea41b939e8152a2571636f937e2bb9dcfed57ffd2f1dbe65ed68522800df')
        self.assertEqual(tuple(row['id'] for row in consumer.SUBTITLE_SOURCE_OUTPUTS),
                         ('libunibreak', 'libfribidi', 'libharfbuzz', 'libbluray'))
        self.assertEqual(tuple(row['version'] for row in consumer.SUBTITLE_SOURCE_OUTPUTS),
                         ('8.0', '1.0.17', '15.0.0', '1.5.0'))
        self.assertEqual(tuple(row['sha256'] for row in consumer.SUBTITLE_SOURCE_OUTPUTS),
                         ('9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4',
                          '6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2',
                          '968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df',
                          'f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2'))
        bluray_pin = consumer.SUBTITLE_SOURCE_OUTPUTS[-1]
        self.assertEqual((bluray_pin['bytes'], bluray_pin['sourceRoot'], bluray_pin['output']),
                         (473072, 'libbluray-1.5.0-f676408e', 'apple-bluray-source.tar.xz'))
        self.assertEqual(tuple(pin.get('sourceTransformPolicy', 'none')
                               for pin in consumer.SUBTITLE_SOURCE_OUTPUTS),
                         ('none', 'none', 'none', 'bluray150-retained-apple-mobile-v1'))
        self.assertEqual(set(consumer.BLURAY_SOURCE_TRANSFORMS),
                         {'meson.build', 'src/file/mount_darwin.c', 'src/libbluray/bdj/bdj.c'})
        self.assertEqual(MODULE.BLURAY_SOURCE_TRANSFORMS, consumer.BLURAY_SOURCE_TRANSFORMS)
        self.assertEqual(MODULE.SUBTITLE_SOURCE_OUTPUTS, consumer.SUBTITLE_SOURCE_OUTPUTS)
        self.assertEqual(MODULE.SUBTITLE_SOURCE_PROFILE, consumer.SUBTITLE_SOURCE_PROFILE)
        self.assertEqual({name: (policy['beforeSHA256'], policy['afterSHA256'])
                          for name, policy in consumer.BLURAY_SOURCE_TRANSFORMS.items()}, {
            'meson.build': ('5f707fc923e4d2b9c845adff896b7c1734ea257e4a5fe77c67ddc856caaf73a0',
                            '97eab258bb691ded280ebeff128c5caf4f1807b3a78f76721bb30034d1c715cd'),
            'src/file/mount_darwin.c': ('055d80dbbe5f4b64837347fce756d9538f6254ddbb7d5608cc26f1bb7caee4df',
                                      'f439c23dd34529ad613909114e6dedd0f339550ba90b3ea243350333ab33c483'),
            'src/libbluray/bdj/bdj.c': ('5fbe6d6bde9ac48a89399553d1cd1bcbfd7cffbcbc6f88aa6f010e91f1307e1f',
                                      'a5111e63b6b557820f395cbcd140d070c5181187b07ddf9fe5085fd0f33f78aa')})
        self.assertEqual(tuple(row['entryPoint'] for row in consumer.SUBTITLE_SOURCE_OUTPUTS),
                         ('configure', 'meson.build', 'meson.build', 'meson.build'))
        self.assertEqual(tuple(row[0] for row in consumer.SUBTITLE_MATRIX),
                         tuple(row[0] for row in consumer.CRYPTO_MATRIX))
        self.assertEqual(consumer.SUBTITLE_VERSIONS,
                         {'libunibreak': '8.0', 'libfribidi': '1.0.17',
                          'libharfbuzz': '15.0.0', 'libbluray': '1.5.0'})
        self.assertEqual(consumer.SUBTITLE_SELECTORS,
                         {'libunibreak': '8.0-9c4fad6e',
                          'libfribidi': '1.0.17-6949dcde',
                          'libharfbuzz': '15.0.0-968536e9',
                          'libbluray': '1.5.0-f676408e'})
        self.assertEqual(consumer.SUBTITLE_ROUTES,
                         {'libunibreak': 'release-autoconf',
                          'libfribidi': 'release-meson',
                          'libharfbuzz': 'release-meson', 'libbluray': 'release-meson'})
        self.assertEqual(tuple(consumer.SUBTITLE_MAKE_ARGUMENTS),
                         ('-j1', 'AUTOCONF=/usr/bin/false', 'AUTOHEADER=/usr/bin/false',
                          'AUTOMAKE=/usr/bin/false', 'ACLOCAL=/usr/bin/false'))
        self.assertEqual(7 + len(consumer.CRYPTO_SOURCE_OUTPUTS) +
                         len(consumer.SUBTITLE_SOURCE_OUTPUTS), 14)
        self.assertEqual(set(consumer.OUTPUTS['apple']), {
            'apple-candidate.tar.gz', 'apple-original-library-zips.tar',
            'apple-artifact-gate.txt', 'apple-shaderc-original-all.zip',
            'apple-shaderc-original-xcframework.zip', 'apple-shaderc-inputs.json',
            'apple-openssl-builds.json', 'apple-crypto-source-gmp.tar.xz',
            'apple-crypto-source-nettle.tar.gz', 'apple-crypto-source-gnutls.tar.xz',
            'apple-crypto-release-sources.tar', 'apple-crypto-release-sources.json',
            'apple-crypto-chain.json', 'apple-subtitle-source-unibreak.tar.gz',
            'apple-subtitle-source-fribidi.tar.xz', 'apple-subtitle-source-harfbuzz.tar.xz',
            'apple-subtitle-release-sources.tar', 'apple-subtitle-release-sources.json',
            'apple-subtitle-builds.json', 'apple-bluray-source.tar.xz'})
        self.assertEqual(tuple(consumer.OPENSSL_ENV_KEYS[-3:]),
                         ('MAKEFLAGS', 'CMAKE_BUILD_PARALLEL_LEVEL', 'CARGO_BUILD_JOBS'))
        self.assertEqual(consumer.OPENSSL_SOURCE_SHA,
                         '2f4e3a5fec05394068cfa7379890ab552483a8a6')
        self.assertEqual(consumer.OPENSSL_SOURCE_TAG, 'openssl-4.1.0')
        self.assertEqual(consumer.OPENSSL_SOURCE_VERSION, '4.1.0')
        self.assertEqual(consumer.OPENSSL_BOM_PROFILE, 'openssl-4.1.0-source-v1')
        self.assertEqual(consumer.OPENSSL_OUTPUT_ROOT, 'openssl')
        self.assertEqual(len(consumer.OPENSSL_GITLINKS), 11)
        self.assertEqual(consumer.OPENSSL_GITLINKS['cloudflare-quiche'],
                         '7ab6a55cfe471267d61e4d28ba43d41defcd87e0')
        self.assertEqual(consumer.OPENSSL_GITLINKS['fuzz/corpora'],
                         '7e3fb43a75c55275759e8bdb5c32de4b50978eab')
        self.assertEqual(consumer.OPENSSL_GITLINKS['wycheproof'],
                         '3fa63dd0344abb611f1fb1d77e119938603ea230')
        gitlink_row = {'root': 'source-openssl', 'commit': consumer.OPENSSL_SOURCE_SHA,
                       'gitlinks': [{'path': name, 'commit': commit}
                                    for name, commit in consumer.OPENSSL_GITLINKS.items()]}
        consumer.validate_native_gitlinks(gitlink_row, {'source-openssl/.gitmodules': {}})
        for mutate, files in (
                (lambda row: row['gitlinks'].pop(), {'source-openssl/.gitmodules': {}}),
                (lambda row: row['gitlinks'][0].update(commit='0' * 40), {'source-openssl/.gitmodules': {}}),
                (lambda row: row['gitlinks'].append({'path': 'extra/corpora', 'commit': '1' * 40}),
                 {'source-openssl/.gitmodules': {}}),
                (lambda row: None, {'source-openssl/.gitmodules': {},
                                    'source-openssl/cloudflare-quiche/file': {}}),
                (lambda row: None, {'source-openssl/.gitmodules': {},
                                    'source-openssl/cloudflare-quiche': {}})):
            observed = deepcopy(gitlink_row)
            mutate(observed)
            with self.assertRaises(ValueError):
                consumer.validate_native_gitlinks(observed, files)
        self.assertEqual(consumer.OPENSSL_CONFIGURE_FLAGS,
                         ('no-async', 'no-shared', 'no-dso', 'no-tests', 'no-apps', 'no-docs'))
        targets = {base: base if base in consumer.UNSUFFIXED_LIBRARIES else base + '-GPL'
                   for base in libraries}
        source_package = ''.join('.binaryTarget(name: "%s", url: "https://fixture.invalid/%s.zip", '
                                 'checksum: "%s")\n' % (targets[base], base, 'a' * 64)
                                 for base in libraries)
        fixture_all_members = {}
        for slice_name, arch, platform_name in consumer.SHADERC_MATRIX:
            name = 'lib/%s/thin/%s/lib/libshaderc_combined.a' % (platform_name, arch)
            fixture_all_members[name] = ('fixture-' + slice_name + '-' + arch).encode()
        fixture_all_archive = io.BytesIO()
        with zipfile.ZipFile(fixture_all_archive, 'w') as archive:
            for name, payload in fixture_all_members.items():
                info = zipfile.ZipInfo(name)
                info.create_system, info.external_attr = 3, 0o100644 << 16
                archive.writestr(info, payload)
        fixture_all_body = fixture_all_archive.getvalue()
        fixture_all_rows = {name: {'kind': 'file', 'bytes': len(payload),
                                   'sha256': hashlib.sha256(payload).hexdigest()}
                            for name, payload in fixture_all_members.items()}
        self.assertEqual(consumer.SHADERC_SOURCE_SPECS, (
            ('libshaderc.zip', 124322785,
             'd213fa58de7886846fb8cb713ea5213b77654a3ad2ba3d89b1f2fe367d945ba5'),
            ('Libshaderc_combined.xcframework.zip', 61246203,
             '77a3d355993cf53843a394bf58262dab99cdd93f9e6fe31d5ca6e55b03866ce1')))

        def shaderc_xcframework_fixture(path, *, extra=(), link_body_overrides=None):
            """Write a tiny metadata-only XCFramework ZIP with the three known links."""
            framework = MODULE.SHADERC_XC_MAC_FRAMEWORK
            link_body_overrides = {} if link_body_overrides is None else dict(link_body_overrides)
            directories = (
                'Libshaderc_combined.xcframework/',
                'Libshaderc_combined.xcframework/macos-arm64_x86_64/',
                framework + '/',
                framework + '/Versions/',
                framework + '/Versions/A/',
                framework + '/Versions/A/Resources/',
            )
            files = {
                framework + '/Versions/A/Resources/Info.plist': b'fixture plist',
                framework + '/Versions/A/Libshaderc_combined': b'fixture binary',
            }
            links = {
                name: link_body_overrides.get(name, target.encode('utf-8'))
                for name, target in MODULE.SHADERC_XC_LINKS.items()
            }

            def add(archive, name, payload, mode):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = mode << 16
                archive.writestr(info, payload)

            with zipfile.ZipFile(path, 'w') as archive:
                for name in directories:
                    add(archive, name, b'', stat.S_IFDIR | 0o755)
                for name, payload in files.items():
                    add(archive, name, payload, stat.S_IFREG | 0o644)
                for name, payload in links.items():
                    add(archive, name, payload, stat.S_IFLNK | 0o755)
                for name, payload, mode in extra:
                    add(archive, name, payload, mode)

        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'shaderc-xc-links.zip'
            shaderc_xcframework_fixture(fixture)
            rows = MODULE._shaderc_zip_index(fixture, role='xcframework')
            framework = MODULE.SHADERC_XC_MAC_FRAMEWORK
            binary_link = framework + '/Libshaderc_combined'
            binary_name, binary_row = MODULE._shaderc_resolve_archive_path(
                rows, binary_link, framework)
            self.assertEqual(binary_name, framework + '/Versions/A/Libshaderc_combined')
            self.assertEqual(binary_row['kind'], 'file')
            resources_name, resources_row = MODULE._shaderc_resolve_archive_path(
                rows, framework + '/Resources', framework)
            self.assertEqual(resources_name, framework + '/Versions/A/Resources')
            self.assertEqual(resources_row['kind'], 'directory')
            self.assertEqual(rows[binary_link]['rawBytes'], len(b'Versions/Current/Libshaderc_combined'))
            self.assertEqual(rows[binary_link]['rawSHA256'], hashlib.sha256(
                b'Versions/Current/Libshaderc_combined').hexdigest())
            with self.assertRaisesRegex(ValueError, 'symlink'):
                MODULE._shaderc_zip_index(fixture, role='all')

            def resolver_link(target):
                raw = target.encode('utf-8')
                return {'directory': False, 'kind': 'symlink', 'target': target,
                        'bytes': len(raw), 'rawBytes': len(raw),
                        'rawSHA256': hashlib.sha256(raw).hexdigest()}

            with self.assertRaisesRegex(ValueError, 'cycle'):
                MODULE._shaderc_resolve_archive_path(
                    {framework + '/A': resolver_link('B'),
                     framework + '/B': resolver_link('A')},
                    framework + '/A', framework)
            with self.assertRaisesRegex(ValueError, 'target'):
                MODULE._shaderc_resolve_archive_path(
                    {framework + '/A': resolver_link('../../outside')},
                    framework + '/A', framework)
            with self.assertRaisesRegex(ValueError, 'missing'):
                MODULE._shaderc_resolve_archive_path(
                    {framework + '/A': resolver_link('Missing')},
                    framework + '/A', framework)

            unlisted = Path(directory) / 'unlisted.zip'
            shaderc_xcframework_fixture(
                unlisted,
                extra=((framework + '/Unlisted', b'Versions/A/Info.plist',
                        stat.S_IFLNK | 0o755),))
            with self.assertRaisesRegex(ValueError, 'unlisted'):
                MODULE._shaderc_zip_index(unlisted, role='xcframework')

            special = Path(directory) / 'special.zip'
            shaderc_xcframework_fixture(
                special,
                extra=((framework + '/special', b'special', stat.S_IFCHR | 0o644),))
            with self.assertRaisesRegex(ValueError, 'special'):
                MODULE._shaderc_zip_index(special, role='xcframework')

            case_collision = Path(directory) / 'case-collision.zip'
            shaderc_xcframework_fixture(
                case_collision,
                extra=((framework + '/Versions/A/libshaderc_combined', b'case',
                        stat.S_IFREG | 0o644),))
            with self.assertRaisesRegex(ValueError, 'case-colliding'):
                MODULE._shaderc_zip_index(case_collision, role='xcframework')

            bad_body = Path(directory) / 'bad-body.zip'
            shaderc_xcframework_fixture(
                bad_body,
                link_body_overrides={framework + '/Resources': b'Versions/Current/\xff'})
            with self.assertRaisesRegex(ValueError, 'UTF-8'):
                MODULE._shaderc_zip_index(bad_body, role='xcframework')

        fixture_specs = (('libshaderc.zip', len(fixture_all_body), hashlib.sha256(fixture_all_body).hexdigest()),
                         ('Libshaderc_combined.xcframework.zip', 7,
                          hashlib.sha256(b'xc-body').hexdigest()))
        consumer.SHADERC_SOURCE_SPECS = fixture_specs
        shaderc_target = ('.binaryTarget(\n    name: "Libshaderc_combined",\n'
                          '    url: "%s",\n    checksum: "%s"\n)\n' %
                          (consumer.SHADERC_REMOTE_URL, fixture_specs[1][2]))
        source_package += shaderc_target
        ignore = (b'# Build OUTPUT (hundreds of MB), reproducible from the pinned refs via\n'
                  b'# scripts/build-mpvkit-dvfel.sh. Must never enter git history.\nartifacts/\n')
        profile_receipt = 'PASS dependency-profile ' + consumer.NATIVE_UPGRADES_PROFILE
        gates = ['TLS VERIFY PASSED: 5 Apple slices and 9 architectures use SecureTransport',
                 'MPVKit-DVFEL ARTIFACT VERIFY PASSED: FFmpeg 9.0.2 (libavcodec/libavformat 63.1.102), dovi_split, and Apple TLS gates',
                 'PASS openssl-profile openssl-4.1.0-source-v1',
                 'PASS apple-openssl-receipt',
                 'PASS apple-shaderc-receipt',
                 'PASS ' + consumer.CRYPTO_SOURCE_PROFILE + ' verify',
                     'PASS crypto-chain archive/public-symbol correspondence; native SMB/runtime gates OPEN',
                     'PASS ' + consumer.SUBTITLE_SOURCE_PROFILE + ' verify',
                     'PASS subtitle-profile ' + consumer.SUBTITLE_SOURCE_PROFILE,
                     'PASS apple-subtitle-receipt',
                 'PASS apple-sent-abi', 'PASS apple-reference-abi']

        def synthetic_tar(files, compressed, links=None):
            links = {} if links is None else links
            result = io.BytesIO()
            with tarfile.open(fileobj=result, mode='w:gz' if compressed else 'w') as archive:
                for name, data in files.items():
                    info = tarfile.TarInfo(name)
                    info.size, info.mode = len(data), 0o644
                    archive.addfile(info, io.BytesIO(data))
                for name, target in links.items():
                    info = tarfile.TarInfo(name)
                    info.type, info.mode, info.size = tarfile.SYMTYPE, 0o777, 0
                    info.linkname = target
                    archive.addfile(info)
            return result.getvalue()

        def crypto_source_fixture():
            """Tiny source archives exercise raw-body/capture binding only."""
            definitions = (
                ('gmp', '6.3.0', 'gmp-6.3.0', 'gmp-6.3.0.tar.xz', 'xz',
                 'gmp-6.3.0-a3c2b802', 'https://fixture.invalid/gmp-6.3.0.tar.xz'),
                ('nettle', '4.0', 'nettle-4.0', 'nettle-4.0.tar.gz', 'gz',
                 'nettle-4.0-3addbc00', 'https://fixture.invalid/nettle-4.0.tar.gz'),
                ('gnutls', '3.8.13', 'gnutls-3.8.13', 'gnutls-3.8.13.tar.xz', 'xz',
                 'gnutls-3.8.13-ffed8ec1', 'https://fixture.invalid/gnutls-3.8.13.tar.xz'))
            pins, verified, bodies = [], [], {}
            for identifier, version, archive_root, filename, compression, source_root, url in definitions:
                configure = ('#!/bin/sh\n# inert source-policy fixture: ' + identifier + '\n').encode()
                encoded = io.BytesIO()
                with tarfile.open(fileobj=encoded, mode='w:' + compression,
                                  format=tarfile.PAX_FORMAT) as source:
                    root = tarfile.TarInfo(archive_root + '/')
                    root.type, root.mode, root.mtime = tarfile.DIRTYPE, 0o755, 0
                    source.addfile(root)
                    entry = tarfile.TarInfo(archive_root + '/configure')
                    entry.mode, entry.mtime, entry.size = 0o755, 0, len(configure)
                    source.addfile(entry, io.BytesIO(configure))
                body = encoded.getvalue()
                pin = {'id': identifier, 'version': version, 'archiveRoot': archive_root,
                       'filename': filename, 'compression': compression, 'bytes': len(body),
                       'sha256': hashlib.sha256(body).hexdigest(), 'sourceRoot': source_root,
                       'url': url, 'output': 'apple-crypto-source-' + identifier +
                       ('.tar.gz' if compression == 'gz' else '.tar.xz')}
                rows = consumer.crypto_index_archive(pin, body)
                pins.append(pin)
                verified.append((pin, body, rows))
                bodies[pin['output']] = body
            expected = consumer.crypto_expected_receipt(verified)
            receipt = consumer.crypto_canonical(expected)
            capture_stream = io.BytesIO()
            with tarfile.open(fileobj=capture_stream, mode='w', format=tarfile.PAX_FORMAT) as capture:
                for pin, _, rows in verified:
                    root_name = pin['archiveRoot']
                    root = tarfile.TarInfo(root_name)
                    root.type, root.mode, root.mtime = tarfile.DIRTYPE, 0o755, 0
                    capture.addfile(root)
                    configure = ('#!/bin/sh\n# inert source-policy fixture: ' + pin['id'] + '\n').encode()
                    entry = tarfile.TarInfo(root_name + '/configure')
                    entry.mode, entry.mtime, entry.size = 0o755, 0, len(configure)
                    capture.addfile(entry, io.BytesIO(configure))
                    self.assertEqual({row['path'] for row in rows}, {'', 'configure'})
            return {'pins': tuple(pins), 'bodies': bodies, 'receipt': receipt,
                    'capture': capture_stream.getvalue()}

        crypto_sources = crypto_source_fixture()

        # These tiny sources have their own explicit hashes and transform map.
        # Production libbluray pins/preimages/afterimages were asserted above;
        # no inert body is assigned the actual upstream digest.
        bluray_fixture_files, bluray_fixture_transforms = {}, {}
        for name in sorted(consumer.BLURAY_SOURCE_TRANSFORMS):
            before = ('inert bluray source ' + name + '\nfixture-mobile-anchor\n').encode()
            after = before.replace(b'fixture-mobile-anchor', b'fixture-mobile-afterimage')
            bluray_fixture_files[name] = before
            bluray_fixture_transforms[name] = {
                'beforeSHA256': hashlib.sha256(before).hexdigest(),
                'afterSHA256': hashlib.sha256(after).hexdigest(),
                'replacements': [{'before': 'fixture-mobile-anchor',
                                  'after': 'fixture-mobile-afterimage'}]}

        def subtitle_source_fixture():
            """Tiny four-root release archives exercise raw/derived capture binding."""
            definitions = (
                ('libunibreak', '8.0', 'libunibreak-8.0', 'libunibreak-8.0.tar.gz',
                 'gz', 'libunibreak-8.0-9c4fad6e', 'configure',
                 'https://fixture.invalid/libunibreak-8.0.tar.gz', 0o755,
                 1789445730.0),
                ('libfribidi', '1.0.17', 'fribidi-1.0.17', 'fribidi-1.0.17.tar.xz',
                 'xz', 'libfribidi-1.0.17-6949dcde', 'meson.build',
                 'https://fixture.invalid/fribidi-1.0.17.tar.xz', 0o644,
                 1789883576.0),
                ('libharfbuzz', '15.0.0', 'harfbuzz-15.0.0', 'harfbuzz-15.0.0.tar.xz',
                 'xz', 'libharfbuzz-15.0.0-968536e9', 'meson.build',
                 'https://fixture.invalid/harfbuzz-15.0.0.tar.xz', 0o644,
                 1792687043.4438004),
                ('libbluray', '1.5.0', 'libbluray-1.5.0', 'libbluray-1.5.0.tar.xz',
                 'xz', 'libbluray-1.5.0-f676408e', 'meson.build',
                 'https://fixture.invalid/libbluray-1.5.0.tar.xz', 0o644, 1792339200.0))
            pins, verified, bodies, raw_files = [], [], {}, {}
            for identifier, version, archive_root, filename, compression, source_root, entry_point, url, mode, mtime in definitions:
                source_body = ('#!/bin/sh\n# inert subtitle source-policy fixture: ' +
                               identifier + '\n').encode()
                files = (dict(bluray_fixture_files) if identifier == 'libbluray'
                         else {entry_point: source_body})
                raw_files[identifier] = files
                encoded = io.BytesIO()
                with tarfile.open(fileobj=encoded, mode='w:' + compression,
                                  format=tarfile.PAX_FORMAT) as source:
                    root = tarfile.TarInfo(archive_root + '/')
                    root.type, root.mode, root.mtime = tarfile.DIRTYPE, 0o755, mtime
                    if mtime % 1:
                        # Preserve the authenticated decimal from the real
                        # HarfBuzz PAX member. Formatting the binary float can
                        # round the nanosecond identity by one or more units.
                        root.pax_headers['mtime'] = (
                            '1792687043.4438004' if identifier == 'libharfbuzz'
                            else format(mtime, '.9f').rstrip('0').rstrip('.'))
                    source.addfile(root)
                    for name, file_body in files.items():
                        entry = tarfile.TarInfo(archive_root + '/' + name)
                        entry.mode, entry.mtime, entry.size = mode, mtime, len(file_body)
                        if mtime % 1:
                            entry.pax_headers['mtime'] = (
                                '1792687043.4438004' if identifier == 'libharfbuzz'
                                else format(mtime, '.9f').rstrip('0').rstrip('.'))
                        source.addfile(entry, io.BytesIO(file_body))
                body = encoded.getvalue()
                pin = {'id': identifier, 'version': version, 'archiveRoot': archive_root,
                       'filename': filename, 'compression': compression, 'bytes': len(body),
                       'maximumBytes': 8 * 1024 * 1024 if identifier != 'libharfbuzz' else 32 * 1024 * 1024,
                       'entryPoint': entry_point, 'sha256': hashlib.sha256(body).hexdigest(),
                       'sourceRoot': source_root, 'url': url,
                       'sourceTransformPolicy': ('bluray150-retained-apple-mobile-v1'
                                                 if identifier == 'libbluray' else 'none'),
                       'output': ('apple-bluray-source.tar.xz' if identifier == 'libbluray'
                                  else 'apple-subtitle-source-' + identifier.removeprefix('lib') +
                                  ('.tar.gz' if compression == 'gz' else '.tar.xz'))}
                with patch.object(consumer, 'BLURAY_SOURCE_TRANSFORMS', bluray_fixture_transforms), \
                        patch.object(MODULE, 'BLURAY_SOURCE_TRANSFORMS', bluray_fixture_transforms):
                    rows = consumer.crypto_index_archive(pin, body, True)
                    self.assertEqual(rows, MODULE._crypto_index_archive(pin, body, True))
                if identifier == 'libharfbuzz':
                    expected_ns = 1792687043443800400
                    self.assertEqual(next(row['mtimeNs'] for row in rows if row['path'] == ''),
                                     expected_ns)
                    self.assertEqual(next(row['mtimeNs'] for row in rows
                                          if row['path'] == entry_point), expected_ns)
                pins.append(pin)
                verified.append((pin, body, rows))
                bodies[pin['output']] = body
            expected = {
                'schema': 3, 'profile': consumer.SUBTITLE_SOURCE_PROFILE,
                'identityBasis': 'fixed-sha256-from-upstream-release-metadata-maintained-android-pin-or-official-sidecar; fixed-apple-source-transforms',
                'upstreamSignatureVerified': False, 'roots': []}
            for pin, body, rows in verified:
                expected['roots'].append({
                    'id': pin['id'], 'version': pin['version'], 'url': pin['url'],
                    'archive': 'archives/' + pin['filename'],
                    'archiveRoot': pin['archiveRoot'], 'archiveBytes': len(body),
                    'archiveSHA256': pin['sha256'],
                    'sourceRoot': 'dist/' + pin['sourceRoot'],
                    'sourceTransformPolicy': pin['sourceTransformPolicy'],
                    'membersSHA256': hashlib.sha256(consumer.crypto_canonical(rows)).hexdigest(),
                    'members': rows})
            receipt = consumer.crypto_canonical(expected)
            capture_stream = io.BytesIO()
            with tarfile.open(fileobj=capture_stream, mode='w', format=tarfile.PAX_FORMAT) as capture:
                for pin, _, rows in verified:
                    root_name = pin['archiveRoot']
                    for row in rows:
                        name = row['path']
                        entry = tarfile.TarInfo(root_name + ('/' + name if name else ''))
                        entry.mode = row['mode']
                        seconds, nanos = divmod(row['mtimeNs'], 1000000000)
                        entry.mtime = seconds
                        if nanos:
                            entry.pax_headers['mtime'] = ('%d.%09d' % (seconds, nanos)).rstrip('0')
                        if row['kind'] == 'directory':
                            entry.type = tarfile.DIRTYPE
                            capture.addfile(entry)
                        else:
                            body = raw_files[pin['id']][name]
                            with patch.object(consumer, 'BLURAY_SOURCE_TRANSFORMS',
                                              bluray_fixture_transforms):
                                body = consumer.bluray_source_body(pin, name, body)
                            self.assertEqual((len(body), hashlib.sha256(body).hexdigest()),
                                             (row['bytes'], row['sha256']))
                            entry.size = len(body)
                            capture.addfile(entry, io.BytesIO(body))
            return {'pins': tuple(pins), 'bodies': bodies, 'receipt': receipt,
                    'capture': capture_stream.getvalue(), 'rawFiles': raw_files,
                    'transforms': bluray_fixture_transforms}

        subtitle_sources = subtitle_source_fixture()
        # Exercise both independently implemented source boundaries with tiny,
        # honestly pinned bytes. The separate helper-boundary command covers
        # these policies against the retained authentic release body.
        fixture_bluray_pin = next(pin for pin in subtitle_sources['pins']
                                  if pin['id'] == 'libbluray')
        for module, transform in ((consumer, consumer.bluray_source_body),
                                  (MODULE, MODULE._bluray_source_body)):
            with self.subTest(boundary=module.__name__), patch.object(
                    module, 'BLURAY_SOURCE_TRANSFORMS', bluray_fixture_transforms):
                for name, raw in bluray_fixture_files.items():
                    self.assertEqual(hashlib.sha256(transform(fixture_bluray_pin, name, raw)).hexdigest(),
                                     bluray_fixture_transforms[name]['afterSHA256'])
                    with self.assertRaisesRegex(ValueError, 'preimage'):
                        transform(fixture_bluray_pin, name, raw + b'changed')
                name = 'meson.build'
                wrong_policy = dict(fixture_bluray_pin, sourceTransformPolicy='none')
                with self.assertRaises(ValueError):
                    transform(wrong_policy, name, bluray_fixture_files[name])
                altered = deepcopy(bluray_fixture_transforms)
                altered[name]['afterSHA256'] = '0' * 64
                with patch.object(module, 'BLURAY_SOURCE_TRANSFORMS', altered):
                    with self.assertRaisesRegex(ValueError, 'afterimage'):
                        transform(fixture_bluray_pin, name, bluray_fixture_files[name])
                repeated = bluray_fixture_files[name] + b'fixture-mobile-anchor\n'
                altered[name]['beforeSHA256'] = hashlib.sha256(repeated).hexdigest()
                with patch.object(module, 'BLURAY_SOURCE_TRANSFORMS', altered):
                    with self.assertRaisesRegex(ValueError, 'unique'):
                        transform(fixture_bluray_pin, name, repeated)

        # Removing a required transform member while rehashing the enclosing
        # raw body must fail beyond the digest/length boundary.
        missing_bluray = synthetic_tar({
            fixture_bluray_pin['archiveRoot'] + '/meson.build': bluray_fixture_files['meson.build']}, False)
        missing_pin = dict(fixture_bluray_pin, compression='none', bytes=len(missing_bluray),
                           sha256=hashlib.sha256(missing_bluray).hexdigest())
        for module, indexer in ((consumer, consumer.crypto_index_archive),
                                (MODULE, MODULE._crypto_index_archive)):
            with self.subTest(boundary=module.__name__), patch.object(
                    module, 'BLURAY_SOURCE_TRANSFORMS', bluray_fixture_transforms):
                with self.assertRaises(ValueError):
                    indexer(missing_pin, missing_bluray, True)
        # The HarfBuzz fixture above deliberately carries a fractional PAX mtime;
        # a decimal with more than nine fractional digits is a malformed source
        # body and must fail before receipt construction.
        bad_pax = io.BytesIO()
        with tarfile.open(fileobj=bad_pax, mode='w:xz', format=tarfile.PAX_FORMAT) as source:
            root = tarfile.TarInfo('harfbuzz-15.0.0/')
            root.type, root.mode, root.mtime = tarfile.DIRTYPE, 0o755, 1.0
            root.pax_headers['mtime'] = '1.1234567890'
            source.addfile(root)
            entry = tarfile.TarInfo('harfbuzz-15.0.0/meson.build')
            entry.mode, entry.mtime, entry.size = 0o644, 1.0, 1
            entry.pax_headers['mtime'] = '1.1234567890'
            source.addfile(entry, io.BytesIO(b'x'))
        bad_body = bad_pax.getvalue()
        bad_pin = deepcopy(next(pin for pin in subtitle_sources['pins'] if pin['id'] == 'libharfbuzz'))
        bad_pin['bytes'], bad_pin['sha256'] = len(bad_body), hashlib.sha256(bad_body).hexdigest()
        with self.assertRaises(ValueError):
            consumer.crypto_index_archive(bad_pin, bad_body, True)

        def shaderc_receipt_fixture():
            rows = []
            for slice_name, arch, platform_name in consumer.SHADERC_MATRIX:
                all_entry = 'lib/%s/thin/%s/lib/libshaderc_combined.a' % (platform_name, arch)
                rows.append({
                    'slice': slice_name, 'arch': arch,
                    'allZipEntry': all_entry,
                    'allArchiveSHA256': fixture_all_rows[all_entry]['sha256'],
                    'xcArchiveSHA256': fixture_all_rows[all_entry]['sha256'],
                    'equal': True})
            return {
                'schema': 1, 'profile': consumer.NATIVE_UPGRADES_PROFILE,
                'wrapperVersion': consumer.SHADERC_WRAPPER_VERSION,
                'validatorSHA256': recipe['scripts/native-media-hosted/evidence.py'],
                'reader': {'mode': 'xcrun-resolved-lipo', 'requestedReader': '/usr/bin/xcrun',
                           'resolvedReader': '/fixture/lipo', 'readerSHA256': 'b' * 64,
                           'toolchainReader': '/usr/bin/xcodebuild',
                           'toolchainSHA256': 'c' * 64,
                           'toolchainVersion': 'synthetic Xcode toolchain'},
                'sources': [{'name': name, 'bytes': size, 'sha256': checksum}
                            for name, size, checksum in consumer.SHADERC_SOURCE_SPECS],
                'matrix': rows, 'runtimeSecurityTested': False, 'promotionEligible': False}

        def synthetic_fat(parts):
            # Tiny universal archive sentinel: the consumer checks bounded fat
            # headers/segments only; this is not a native compatibility claim.
            cpu = {'arm64': (0x0100000c, 0), 'arm64e': (0x0100000c, 2),
                   'x86_64': (0x01000007, 3)}
            header_size, offset = 8 + 20 * len(parts), 8 + 20 * len(parts)
            records, payload = [], bytearray()
            for arch, data in parts:
                cputype, subtype = cpu[arch]
                records.append((cputype, subtype, offset, len(data), 2))
                payload.extend(data)
                offset += len(data)
            result = bytearray((0xcafebabe).to_bytes(4, 'big'))
            result.extend(len(parts).to_bytes(4, 'big'))
            for record in records:
                for value in record:
                    result.extend(value.to_bytes(4, 'big'))
            result.extend(payload)
            self.assertEqual(len(result), header_size + len(payload))
            return bytes(result)

        crypto_slice_arches = {}
        for platform, arch, slice_name in consumer.CRYPTO_MATRIX:
            crypto_slice_arches.setdefault(slice_name, set()).add(arch)

        crypto_header_bodies = {
            'gmp': (b'#define __GNU_MP_VERSION 6\n#define __GNU_MP_VERSION_MINOR 3\n'
                    b'#define __GNU_MP_VERSION_PATCHLEVEL 0\n#define GMP_LIMB_BITS 64\n'
                    b'#define GMP_NAIL_BITS 0\n#define __GMP_CC "fixture"\n'
                    b'#define __GMP_CFLAGS "-arch arm64"\n'),
            'nettle': (b'#define NETTLE_VERSION_MAJOR 4\n#define NETTLE_VERSION_MINOR 0\n'
                       b'#define NETTLE_USE_MINI_GMP 0\n'),
            'hogweed': (b'#define NETTLE_VERSION_MAJOR 4\n#define NETTLE_VERSION_MINOR 0\n'
                        b'#define NETTLE_USE_MINI_GMP 0\n'),
            'gnutls': (b'#define GNUTLS_VERSION_MAJOR 3\n#define GNUTLS_VERSION_MINOR 8\n'
                       b'#define GNUTLS_VERSION_PATCH 13\n#define GNUTLS_VERSION "3.8.13"\n'),
            'libsmbclient.h': b'fixture libsmbclient public header\n',
            'samba/version.h': b'fixture samba version header\n'}
        crypto_smb_headers = {
            name: (len(body), hashlib.sha256(body).hexdigest())
            for name, body in (('libsmbclient.h', crypto_header_bodies['libsmbclient.h']),
                               ('samba/version.h', crypto_header_bodies['samba/version.h']))}

        def crypto_zip_entry(archive, name, payload, mode=stat.S_IFREG | 0o644,
                             target=None):
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = mode << 16
            archive.writestr(info, (target.encode() if target is not None else payload))

        def crypto_library_fixture():
            bodies, thin_bodies = {}, {}
            for target, _, archive_name, binary_name in consumer.CRYPTO_LIBRARIES:
                members = {}
                metadata = {'CFBundlePackageType': 'XFWK',
                            'XCFrameworkFormatVersion': '1.0', 'AvailableLibraries': []}
                for slice_name in sorted(crypto_slice_arches):
                    arches = sorted(crypto_slice_arches[slice_name])
                    platform_name = ('macos' if slice_name.startswith('macos-') else
                                     'tvos' if slice_name.startswith('tvos-') else 'ios')
                    declaration = {'LibraryIdentifier': slice_name,
                                   'LibraryPath': binary_name + '.framework',
                                   'SupportedArchitectures': arches,
                                   'SupportedPlatform': platform_name}
                    if slice_name.endswith('-simulator'):
                        declaration['SupportedPlatformVariant'] = 'simulator'
                    metadata['AvailableLibraries'].append(declaration)
                    framework = (target + '.xcframework/' + slice_name + '/' +
                                 binary_name + '.framework')
                    parts = []
                    for arch in arches:
                        thin = ('!<arch>\nfixture-' + target + '-' + slice_name + '-' + arch).encode()
                        thin_bodies[(target, slice_name, arch)] = thin
                        parts.append((arch, thin))
                    packaged = parts[0][1] if len(parts) == 1 else synthetic_fat(parts)
                    if slice_name.startswith('macos-'):
                        members[framework + '/Versions/A/' + binary_name] = packaged
                        members[framework + '/Versions/A/Resources/Info.plist'] = b'fixture framework info\n'
                        members[framework + '/Versions/Current'] = ('symlink', 'A')
                        members[framework + '/' + binary_name] = ('symlink', 'Versions/Current/' + binary_name)
                        members[framework + '/Resources'] = ('symlink', 'Versions/Current/Resources')
                    else:
                        members[framework + '/' + binary_name] = packaged
                    headers = framework + '/Headers/'
                    if target == 'gmp':
                        members[headers + 'gmp.h'] = crypto_header_bodies['gmp']
                    elif target == 'nettle':
                        members[headers + 'version.h'] = crypto_header_bodies['nettle']
                    elif target == 'hogweed':
                        members[headers + 'nettle/version.h'] = crypto_header_bodies['hogweed']
                    elif target == 'gnutls':
                        members[headers + 'gnutls.h'] = crypto_header_bodies['gnutls']
                    else:
                        members[headers + 'samba-4.0/libsmbclient.h'] = crypto_header_bodies['libsmbclient.h']
                        members[headers + 'samba-4.0/samba/version.h'] = crypto_header_bodies['samba/version.h']
                encoded = plistlib.dumps(metadata, fmt=plistlib.FMT_XML, sort_keys=True)
                members[target + '.xcframework/Info.plist'] = encoded
                output = io.BytesIO()
                with zipfile.ZipFile(output, 'w') as archive:
                    for name, value in members.items():
                        if isinstance(value, tuple):
                            crypto_zip_entry(archive, name, b'', stat.S_IFLNK | 0o777, value[1])
                        else:
                            crypto_zip_entry(archive, name, value)
                bodies[target] = output.getvalue()
            smb_pins = {}
            for platform, arch, slice_name in consumer.CRYPTO_MATRIX:
                thin = thin_bodies[('Libsmbclient', slice_name, arch)]
                smb_pins[platform + '/' + arch] = (len(thin), hashlib.sha256(thin).hexdigest())
            return bodies, thin_bodies, crypto_smb_headers, smb_pins

        crypto_zip_bodies, crypto_thin_bodies, crypto_smb_headers, crypto_smb_pins = crypto_library_fixture()

        # GNU configure's CPU spelling is separate from the Apple compiler target.
        for platform, arch, _ in consumer.SUBTITLE_MATRIX:
            producer_platform = MODULE._subtitle_platform(platform, arch)
            consumer_platform = consumer.subtitle_platform(platform, arch)
            self.assertEqual(producer_platform, consumer_platform)
            host_cpu = 'x86_64' if arch == 'x86_64' else 'aarch64'
            host_vendor = {'ios': 'ios', 'isimulator': 'ios', 'tvos': 'tvos',
                           'tvsimulator': 'tvos', 'macos': 'apple'}[platform]
            self.assertEqual(consumer_platform[3], host_cpu + '-' + host_vendor + '-darwin')
            compiler_cpu = 'x86_64' if arch == 'x86_64' else 'arm64'
            self.assertTrue(consumer_platform[1].startswith(compiler_cpu + '-apple-'))
            self.assertEqual(consumer_platform[6], compiler_cpu)

        subtitle_library_specs = (
            ('Libunibreak', 'libunibreak', 'libunibreak.a', 'Libunibreak',
             'include/unibreakbase.h', 'lib/pkgconfig/libunibreak.pc',
             b'#define UNIBREAK_VERSION   0x0800   /**< Version of the libunibreak */\n'
             b'extern const int unibreak_version;\n'),
            ('Libfribidi', 'libfribidi', 'libfribidi.a', 'Libfribidi',
             'include/fribidi/fribidi-config.h', 'lib/pkgconfig/fribidi.pc',
             b'#define FRIBIDI_VERSION "1.0.17"\n'
             b'#define FRIBIDI_MAJOR_VERSION 1\n#define FRIBIDI_MINOR_VERSION 0\n'
             b'#define FRIBIDI_MICRO_VERSION 17\nvoid fribidi_version_info(void);\n'),
            ('Libharfbuzz', 'libharfbuzz', 'libharfbuzz.a', 'Libharfbuzz',
             'include/harfbuzz/hb-version.h', 'lib/pkgconfig/harfbuzz.pc',
             b'#define HB_VERSION_STRING "15.0.0"\n'
             b'#define HB_VERSION_MAJOR 15\n#define HB_VERSION_MINOR 0\n'
             b'#define HB_VERSION_MICRO 0\nvoid hb_version_string(void);\n'),
            ('Libbluray', 'libbluray', 'libbluray.a', 'Libbluray',
             'include/libbluray/bluray-version.h', 'lib/pkgconfig/libbluray.pc',
             b'#define BLURAY_VERSION_STRING "1.5.0"\n'
             b'#define BLURAY_VERSION_MAJOR 1\n#define BLURAY_VERSION_MINOR 5\n'
             b'#define BLURAY_VERSION_MICRO 0\n'))
        self.assertEqual(tuple(consumer.SUBTITLE_LIBRARIES),
                         tuple(spec[:4] for spec in subtitle_library_specs))

        subtitle_slice_arches = {}
        for platform, arch, slice_name in consumer.SUBTITLE_MATRIX:
            subtitle_slice_arches.setdefault(slice_name, set()).add(arch)

        def subtitle_zip_entry(archive, name, payload, mode=stat.S_IFREG | 0o644,
                               target=None):
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = mode << 16
            archive.writestr(info, (target.encode() if target is not None else payload))

        def subtitle_library_fixture():
            bodies, thin_bodies = {}, {}
            for target, directory, archive_name, binary_name, header_path, pc_path, header_body in subtitle_library_specs:
                members = {}
                metadata = {'CFBundlePackageType': 'XFWK',
                            'XCFrameworkFormatVersion': '1.0', 'AvailableLibraries': []}
                for slice_name in sorted(subtitle_slice_arches):
                    arches = sorted(subtitle_slice_arches[slice_name])
                    platform_name = ('macos' if slice_name.startswith('macos-') else
                                     'tvos' if slice_name.startswith('tvos-') else 'ios')
                    declaration = {'LibraryIdentifier': slice_name,
                                   'LibraryPath': binary_name + '.framework',
                                   'SupportedArchitectures': arches,
                                   'SupportedPlatform': platform_name}
                    if slice_name.endswith('-simulator'):
                        declaration['SupportedPlatformVariant'] = 'simulator'
                    metadata['AvailableLibraries'].append(declaration)
                    framework = (target + '.xcframework/' + slice_name + '/' +
                                 binary_name + '.framework')
                    parts = []
                    for arch in arches:
                        thin = ('!<arch>\nfixture-' + target + '-' + slice_name + '-' + arch).encode()
                        thin_bodies[(target, slice_name, arch)] = thin
                        parts.append((arch, thin))
                    packaged = parts[0][1] if len(parts) == 1 else synthetic_fat(parts)
                    if slice_name.startswith('macos-'):
                        members[framework + '/Versions/A/' + binary_name] = packaged
                        members[framework + '/Versions/A/Resources/Info.plist'] = b'fixture framework info\n'
                        members[framework + '/Versions/Current'] = ('symlink', 'A')
                        members[framework + '/' + binary_name] = ('symlink', 'Versions/Current/' + binary_name)
                        members[framework + '/Resources'] = ('symlink', 'Versions/Current/Resources')
                    else:
                        members[framework + '/' + binary_name] = packaged
                    members[framework + '/Headers/' + header_path.removeprefix('include/')] = header_body
                members[target + '.xcframework/Info.plist'] = plistlib.dumps(
                    metadata, fmt=plistlib.FMT_XML, sort_keys=True)
                output = io.BytesIO()
                with zipfile.ZipFile(output, 'w') as archive:
                    for name, value in members.items():
                        if isinstance(value, tuple):
                            subtitle_zip_entry(archive, name, b'', stat.S_IFLNK | 0o777, value[1])
                        else:
                            subtitle_zip_entry(archive, name, value)
                bodies[target] = output.getvalue()
            return bodies, thin_bodies

        subtitle_zip_bodies, subtitle_thin_bodies = subtitle_library_fixture()
        self.assertEqual(len(subtitle_zip_bodies), 4)
        self.assertEqual(len(subtitle_thin_bodies), 36)
        self.assertTrue(all(body.startswith(b'!<arch>\n')
                            for body in subtitle_thin_bodies.values()))

        def crypto_inline(path, body):
            return {'path': path, 'bytes': len(body),
                    'sha256': hashlib.sha256(body).hexdigest(),
                    'bodyBase64': base64.b64encode(body).decode('ascii')}

        def subtitle_equal_fake_value(value):
            """Keep the record wrapper/hash coherent while retaining a false body."""
            build = value['rows'][0]['builds']['libunibreak']
            header = 'include/unibreakbase.h'
            fake_body = (b'#define UNIBREAK_VERSION   0x0800   /**< Version of the libunibreak */\n'
                         b'extern const int unibreak_version;\n'
                         b'/* forged but internally coherent subtitle header */\n')
            record_row = build['record']
            record = json.loads(base64.b64decode(record_row['bodyBase64']))
            record['installedIdentity'][header] = {
                'bytes': len(fake_body), 'sha256': hashlib.sha256(fake_body).hexdigest(),
                'bodyBase64': base64.b64encode(fake_body).decode('ascii')}
            record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
            build['record'] = crypto_inline(record_row['path'], record_body)

        def subtitle_zip_with_header(body, header_body, header_suffix='unibreakbase.h'):
            """Rewrite one ZIP member so archive-byte tampering remains well formed."""
            rewritten = io.BytesIO()
            with zipfile.ZipFile(io.BytesIO(body)) as incoming, zipfile.ZipFile(
                    rewritten, 'w') as outgoing:
                for info in incoming.infolist():
                    payload = incoming.read(info)
                    if info.filename.endswith('/Headers/' + header_suffix):
                        payload = header_body
                    clone = zipfile.ZipInfo(info.filename)
                    clone.create_system, clone.external_attr = info.create_system, info.external_attr
                    outgoing.writestr(clone, payload)
            return rewritten.getvalue()

        def crypto_text(text):
            body = text.encode('utf-8')
            return {'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest(),
                    'text': text}

        def crypto_tool(name, resolved, body=None):
            body = (name + ' synthetic selected tool\n').encode() if body is None else body
            return {'resolvedPath': resolved, 'path': name, 'bytes': len(body),
                    'sha256': hashlib.sha256(body).hexdigest()}

        def crypto_tools_fixture():
            toolchain = '/fixture/Xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/'
            platforms = {}
            sdk_names = {
                'ios': 'iPhoneOS.sdk', 'isimulator': 'iPhoneSimulator.sdk',
                'tvos': 'AppleTVOS.sdk', 'tvsimulator': 'AppleTVSimulator.sdk',
                'macos': 'MacOSX.sdk'}
            for platform, sdk_name in sdk_names.items():
                sdk = '/fixture/Xcode/Platforms/' + sdk_name.removesuffix('.sdk') + (
                    '.platform/Developer/SDKs/' + sdk_name)
                platforms[platform] = {
                    'sdkRoot': sdk, 'resolvedSDKRoot': sdk,
                    'ar': dict(crypto_tool('ar', toolchain + 'ar'),
                               selectedPath=toolchain + 'ar'),
                    'ranlib': dict(crypto_tool('ranlib', toolchain + 'ranlib'),
                                   selectedPath=toolchain + 'ranlib')}
            return {
                'xcrun': crypto_tool('xcrun', '/usr/bin/xcrun'),
                'xcodebuild': crypto_tool('xcodebuild', '/usr/bin/xcodebuild'),
                'lipo': crypto_tool('lipo', toolchain + 'lipo'),
                'nm': crypto_tool('nm', toolchain + 'nm'),
                'toolchainVersion': crypto_text('Xcode synthetic toolchain fixture\n'),
                'platforms': platforms}

        crypto_tool_rows = crypto_tools_fixture()

        def crypto_archive_sources():
            source = io.BytesIO()
            with zipfile.ZipFile(source, 'w') as archive:
                for output, body in crypto_sources['bodies'].items():
                    archive.writestr(output, body)
                archive.writestr('apple-crypto-release-sources.json', crypto_sources['receipt'])
                archive.writestr('apple-crypto-release-sources.tar', crypto_sources['capture'])
            source.seek(0)
            with zipfile.ZipFile(source) as archive:
                with patch.object(consumer, 'CRYPTO_SOURCE_OUTPUTS', crypto_sources['pins']):
                    return consumer.crypto_source_outputs(archive)

        crypto_archive_source_rows = crypto_archive_sources()

        def subtitle_archive_sources(*, bodies=None, receipt=None, capture=None):
            source = io.BytesIO()
            with zipfile.ZipFile(source, 'w') as archive:
                for output, body in (subtitle_sources['bodies'] if bodies is None else bodies).items():
                    archive.writestr(output, body)
                archive.writestr('apple-subtitle-release-sources.json',
                                 subtitle_sources['receipt'] if receipt is None else receipt)
                archive.writestr('apple-subtitle-release-sources.tar',
                                 subtitle_sources['capture'] if capture is None else capture)
            source.seek(0)
            with zipfile.ZipFile(source) as archive:
                with patch.object(consumer, 'SUBTITLE_SOURCE_OUTPUTS', subtitle_sources['pins']):
                    with patch.object(consumer, 'BLURAY_SOURCE_TRANSFORMS',
                                      subtitle_sources['transforms']):
                        return consumer.subtitle_source_outputs(archive)

        subtitle_archive_source_rows = subtitle_archive_sources()
        self.assertEqual(len(subtitle_archive_source_rows['roots']), 4)
        for mutation in ('missing-new-raw', 'changed-new-raw', 'changed-derived-capture',
                         'wrong-transform-policy', 'wrong-derived-member'):
            bodies = dict(subtitle_sources['bodies'])
            receipt = json.loads(subtitle_sources['receipt'])
            capture = subtitle_sources['capture']
            if mutation == 'missing-new-raw':
                bodies.pop('apple-bluray-source.tar.xz')
            elif mutation == 'changed-new-raw':
                bodies['apple-bluray-source.tar.xz'] += b'changed'
            elif mutation == 'changed-derived-capture':
                capture = synthetic_tar({'libbluray-1.5.0/meson.build': b'forged derived body'}, False)
            else:
                root = next(row for row in receipt['roots'] if row['id'] == 'libbluray')
                if mutation == 'wrong-transform-policy':
                    root['sourceTransformPolicy'] = 'none'
                else:
                    member = next(row for row in root['members'] if row['path'] == 'meson.build')
                    member['sha256'] = '0' * 64
                    root['membersSHA256'] = hashlib.sha256(
                        consumer.crypto_canonical(root['members'])).hexdigest()
            with self.subTest(bluray_source=mutation), self.assertRaises(ValueError):
                subtitle_archive_sources(bodies=bodies, receipt=consumer.crypto_canonical(receipt),
                                         capture=capture)

        def crypto_chain_receipt_for(package_body):
            """Construct a complete raw-byte-bound schema-2 fixture receipt."""
            work = Path('/fixture/work')
            catalog = consumer.crypto_zip_catalog(crypto_zip_bodies)
            build_rows, build_bodies = {}, {}

            def generated_body(library, name, platform, arch):
                if library == 'gmp' and name == 'gmp.h':
                    return crypto_header_bodies['gmp']
                if library == 'nettle' and name == 'version.h':
                    return crypto_header_bodies['nettle']
                if library == 'gnutls' and name == 'lib/includes/gnutls/gnutls.h':
                    return crypto_header_bodies['gnutls']
                return ('generated ' + library + ' ' + platform + ' ' + arch +
                        ' ' + name + '\n').encode()

            def build_value(library, platform, arch):
                sdk = crypto_tool_rows['platforms'][platform]
                expected = consumer.crypto_recipe_contract(work, library, platform, arch, sdk)
                # Assert the agreed GNU flag contract independently of the
                # implementation-generated recipe used below. Native generators
                # retain the bare host compiler; CPP/ASM retain target flags.
                cpu = 'x86_64' if arch == 'x86_64' else 'arm64'
                target_suffix, minimum = {
                    'ios': ('ios15.0', '-mios-version-min=15.0'),
                    'isimulator': ('ios15.0-simulator', '-mios-simulator-version-min=15.0'),
                    'tvos': ('tvos15.0', '-mtvos-version-min=15.0'),
                    'tvsimulator': ('tvos15.0-simulator', '-mtvos-simulator-version-min=15.0'),
                    'macos': ('macos12.0', '-mmacosx-version-min=12.0')}[platform]
                target_flags = ('-arch ' + arch + ' -isysroot ' + sdk['sdkRoot'] +
                                ' -target ' + cpu + '-apple-' + target_suffix + ' ' + minimum)
                if platform in ('tvos', 'tvsimulator'):
                    target_flags += ' -DHAVE_FORK=0'
                for dependency in {'gmp': (), 'nettle': ('gmp',),
                                   'gnutls': ('gmp', 'nettle')}[library]:
                    target_flags += ' -I' + str(work / 'dist' / dependency / platform /
                                               'thin' / arch / 'include')
                for key in ('CFLAGS', 'CXXFLAGS'):
                    self.assertEqual(expected['environment'][key], target_flags + ' -O2')
                for key in ('CPPFLAGS', 'ASMFLAGS'):
                    self.assertEqual(expected['environment'][key], target_flags)
                self.assertEqual(expected['environment']['CC_FOR_BUILD'], '/usr/bin/clang')
                self.assertFalse({'CFLAGS_FOR_BUILD', 'CPPFLAGS_FOR_BUILD', 'CXXFLAGS_FOR_BUILD'} &
                                 set(expected['environment']))
                scratch = Path(expected['buildDirectory'])
                prefix = Path(expected['prefix'])
                names = tuple(consumer.CRYPTO_GENERATED) + tuple(
                    consumer.CRYPTO_EXTRA_GENERATED[library])
                generated = {name: generated_body(library, name, platform, arch)
                             for name in names}
                record = dict(expected)
                record['generatedConfiguration'] = {
                    name: {'bytes': len(body),
                           'sha256': hashlib.sha256(body).hexdigest()}
                    for name, body in generated.items()}
                record_body = json.dumps(record, sort_keys=True,
                                         separators=(',', ':')).encode()
                installed = {
                    relative: generated[name]
                    for name, relative in consumer.CRYPTO_INSTALLED_CONFIGURATION[library].items()}
                value = {
                    'record': crypto_inline(
                        (scratch / 'vortx-crypto-build.json').relative_to(work).as_posix(),
                        record_body),
                    'generatedConfiguration': {
                        name: crypto_inline((scratch / name).relative_to(work).as_posix(), body)
                        for name, body in generated.items()},
                    'installedConfiguration': {
                        relative: crypto_inline((prefix / relative).relative_to(work).as_posix(), body)
                        for relative, body in installed.items()},
                    'sdkMetadata': {
                        name: crypto_inline(
                            (scratch / 'vortx-sdk-pkgconfig' / name).relative_to(work).as_posix(),
                            ('synthetic ' + name + ' metadata\n').encode())
                        for name in ('zlib.pc', 'libxml-2.0.pc')}}
                installed_bodies, installed_rows = consumer.crypto_build_evidence(
                    value, work, library, platform, arch, sdk, [0])
                if platform == 'ios' and arch == 'arm64':
                    for name, mutate in (
                            ('absent-c-optimization', lambda env: env.update(CFLAGS=target_flags)),
                            ('absent-cxx-optimization', lambda env: env.update(CXXFLAGS=target_flags)),
                            ('double-optimization', lambda env: env.update(CFLAGS=target_flags + ' -O2 -O2')),
                            ('nontrailing-optimization', lambda env: env.update(CFLAGS='-O2 ' + target_flags)),
                            ('wrong-optimization-level', lambda env: env.update(CFLAGS=target_flags + ' -O3')),
                            ('cpp-optimization-smuggling', lambda env: env.update(CPPFLAGS=target_flags + ' -O2')),
                            ('asm-optimization-smuggling', lambda env: env.update(ASMFLAGS=target_flags + ' -O2')),
                            ('native-generator-optimization-smuggling',
                             lambda env: env.update(CC_FOR_BUILD='/usr/bin/clang -O2'))):
                        changed = deepcopy(value)
                        changed_record = deepcopy(record)
                        mutate(changed_record['environment'])
                        self.assertNotEqual(changed_record, record, 'GNU flag mutation is a no-op')
                        changed_body = json.dumps(changed_record, sort_keys=True,
                                                  separators=(',', ':')).encode()
                        changed['record'] = crypto_inline(value['record']['path'], changed_body)
                        with self.subTest(gnu_library=library, optimization=name), self.assertRaises(ValueError):
                            consumer.crypto_build_evidence(changed, work, library, platform, arch, sdk, [0])
                return value, installed_bodies, installed_rows

            for identity in consumer.CRYPTO_MATRIX:
                platform, arch, slice_name = identity
                build_rows[identity], build_bodies[identity] = {}, {}
                for library in ('gmp', 'nettle', 'gnutls'):
                    value, installed, installed_rows = build_value(library, platform, arch)
                    build_rows[identity][library] = value
                    build_bodies[identity][library] = {
                        'installed': installed, 'rows': installed_rows}

            def plain(row):
                return {key: row[key] for key in ('path', 'bytes', 'sha256')}

            def static_row(target, platform, arch, slice_name):
                _, directory, archive_name, _ = next(
                    item for item in consumer.CRYPTO_LIBRARIES if item[0] == target)
                body = crypto_thin_bodies[(target, slice_name, arch)]
                return {'path': 'dist/' + directory +
                        '/' + platform + '/thin/' + arch + '/lib/' +
                        archive_name,
                        'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}

            symbols = {
                # Mach-O nm spellings retain one leading underscore; the
                # consumer normalizes it before applying the public ABI policy.
                'gmp': ('___gmpz_cmp\n___gmpz_init\n', ''),
                'nettle': ('_nettle_sha256_init\n_nettle_version_major\n',
                           '___gmpz_cmp\n'),
                'hogweed': ('_nettle_rsa_private_key_init\n',
                            '___gmpz_init\n_nettle_sha256_init\n'),
                'gnutls': ('_gnutls_check_version\n_gnutls_global_init\n_gnutls_record_send\n',
                           '_nettle_sha256_init\n_nettle_rsa_private_key_init\n'),
                'Libsmbclient': ('_smbc_init_context\n_smbc_new_context\n',
                                 '_gnutls_record_send\n')}

            def library_rows(identity):
                platform, arch, slice_name = identity
                result, observations = {}, {}
                slice_arches = sorted({candidate_arch for _, candidate_arch, candidate_slice
                                       in consumer.CRYPTO_MATRIX if candidate_slice == slice_name})
                for target, directory, archive_name, binary_name in consumer.CRYPTO_LIBRARIES:
                    framework = ('artifacts/' + target + '.xcframework/' + slice_name + '/' +
                                 binary_name + '.framework')
                    packaged_path = (framework + '/Versions/A/' + binary_name
                                     if slice_name.startswith('macos-')
                                     else framework + '/' + binary_name)
                    packaged, packaged_name = consumer.crypto_zip_row(
                        catalog, target, packaged_path)
                    packaged_body = consumer.crypto_zip_file(catalog, target, packaged_name)
                    thin = static_row(target, platform, arch, slice_name)
                    segments = consumer._macho_arch_hashes(packaged_body)
                    if segments is None:
                        segments = {slice_arches[0]: (len(packaged_body),
                                                      hashlib.sha256(packaged_body).hexdigest())}
                    correspondence = {'bytes': segments[arch][0], 'sha256': segments[arch][1]}
                    architectures = crypto_text('\n'.join(slice_arches))
                    defined, undefined = symbols[target]
                    observations[target] = {
                        'defined': consumer.crypto_normalize_symbols(defined),
                        'undefined': consumer.crypto_normalize_symbols(undefined)}

                    if target == 'Libsmbclient':
                        thin_headers = [
                            {'path': 'dist/libsmbclient/' + platform + '/thin/' + arch +
                             '/include/samba-4.0/' + name,
                             'bytes': size, 'sha256': checksum}
                            for name, (size, checksum) in crypto_smb_headers.items()]
                        header_names = tuple(crypto_smb_headers)
                    else:
                        source = 'nettle' if target == 'hogweed' else target
                        relative = {'gmp': 'include/gmp.h',
                                    'nettle': 'include/nettle/version.h',
                                    'hogweed': 'include/nettle/version.h',
                                    'gnutls': 'include/gnutls/gnutls.h'}[target]
                        thin_headers = [plain(build_bodies[identity][source]['rows'][relative])]
                        header_names = ({'gmp': ('gmp.h',), 'nettle': ('version.h',),
                                         'hogweed': ('nettle/version.h',),
                                         'gnutls': ('gnutls.h',)}[target])

                    packaged_headers, packaged_header_bodies = [], []
                    for header_name in header_names:
                        header_path = framework + '/Headers/' + (
                            'samba-4.0/' + header_name if target == 'Libsmbclient' else header_name)
                        row, archive_name = consumer.crypto_zip_row(catalog, target, header_path)
                        packaged_headers.append(row)
                        body = consumer.crypto_zip_file(catalog, target, archive_name)
                        packaged_header_bodies.append(body)

                    if target == 'gmp':
                        thin_evidence = []
                        for candidate in consumer.CRYPTO_MATRIX:
                            if candidate[2] != slice_name:
                                continue
                            candidate_source = build_bodies[candidate]['gmp']
                            thin_evidence.append(
                                ((candidate[0], candidate[1]),
                                 candidate_source['installed']['include/gmp.h'],
                                 plain(candidate_source['rows']['include/gmp.h'])))
                        header_correspondence = consumer.crypto_header_correspondence(
                            target, packaged_header_bodies[0], thin_evidence)
                    elif target == 'Libsmbclient':
                        header_correspondence = {'kind': 'exact-checked-header-bytes'}
                    else:
                        source = 'nettle' if target == 'hogweed' else target
                        relative = {'nettle': 'include/nettle/version.h',
                                    'gnutls': 'include/gnutls/gnutls.h'}[source]
                        header_correspondence = consumer.crypto_header_correspondence(
                            target, packaged_header_bodies[0],
                            [((platform, arch), build_bodies[identity][source]['installed'][relative],
                              plain(build_bodies[identity][source]['rows'][relative]))])
                    result[target] = {
                        'version': consumer.CRYPTO_VERSIONS[target], 'thin': thin,
                        'thinHeaders': thin_headers, 'packaged': packaged,
                        'packagedHeaders': packaged_headers, 'correspondence': correspondence,
                        'frameworkLayout': consumer.crypto_framework_layout(
                            target, binary_name, slice_name, catalog),
                        'headerCorrespondence': header_correspondence,
                        'architectures': architectures,
                        'defined': crypto_text(defined), 'undefined': crypto_text(undefined)}
                return result, observations

            rows = []
            for identity in consumer.CRYPTO_MATRIX:
                platform, arch, slice_name = identity
                libraries_for_row, observations = library_rows(identity)
                symbol_policy = consumer.crypto_validate_symbols(observations)
                rows.append({
                    'platform': platform, 'arch': arch, 'slice': slice_name,
                    'libraries': libraries_for_row,
                    'builds': build_rows[identity],
                    'sambaGnuTLSImports': symbol_policy['sambaGnuTLSImports'],
                    'helperImports': symbol_policy['helperImports']})

            xcframework_info = {}
            for target, _, _, _ in consumer.CRYPTO_LIBRARIES:
                row, _ = consumer.crypto_zip_row(
                    catalog, target, 'artifacts/' + target + '.xcframework/Info.plist')
                xcframework_info[target] = row
            source_receipt = crypto_archive_source_rows['capture']['receipt']
            value = {
                'schemaVersion': 2, 'profile': consumer.CRYPTO_CHAIN_PROFILE,
                'work': str(work), 'packagePolicy': consumer.CRYPTO_PACKAGE_POLICY,
                'inlineBodyPolicy': consumer.CRYPTO_INLINE_BODY_POLICY,
                'versions': dict(consumer.CRYPTO_VERSIONS),
                'sourcePins': deepcopy(consumer.CRYPTO_SOURCE_PINS),
                'tools': crypto_tool_rows,
                'packageManifest': {'path': 'Package.swift', 'bytes': len(package_body),
                                    'sha256': hashlib.sha256(package_body).hexdigest()},
                'xcframeworkInfo': xcframework_info,
                'releaseSourceBoundary': {
                    'path': 'dist/crypto-sources/receipt.json',
                    'bytes': source_receipt['bytes'], 'sha256': source_receipt['sha256']},
                'rows': rows, 'acceptance': consumer.CRYPTO_ACCEPTANCE,
                'openGates': list(consumer.CRYPTO_OPEN_GATES)}
            return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

        def subtitle_builds_receipt_for():
            """Construct a complete source-build BOM from inert, byte-bound rows."""
            work = Path('/fixture/work')
            build_rows = {}

            def build_environment(library, platform, arch, build):
                sdk_root = crypto_tool_rows['platforms'][platform]['sdkRoot']
                _, target, minimum, _, _, _, _ = consumer.subtitle_platform(platform, arch)
                prefix = '-arch ' + arch + ' -isysroot '
                suffix = ' -target ' + target + ' ' + minimum
                fork = ' -DHAVE_FORK=0' if platform in ('tvos', 'tvsimulator') else ''
                cflags = prefix + sdk_root + suffix + fork
                ldflags = '-lc++ ' + prefix + sdk_root + suffix
                if library == 'libbluray':
                    freetype = work / 'dist/libfreetype' / platform / 'thin' / arch
                    cflags += ' -I' + str(freetype / 'include')
                    ldflags += ' -L' + str(freetype / 'lib') + ' -lfreetype'
                pkg_roots = [str(work / 'dist' / name / platform / 'thin' / arch /
                                 'lib/pkgconfig')
                             for name in consumer.OPENSSL_PKG_LIBRARIES]
                pkg_roots.append(str(build / 'vortx-sdk-pkgconfig'))
                return {
                    'LC_CTYPE': 'C', 'MAKEFLAGS': '-j1',
                    'CMAKE_BUILD_PARALLEL_LEVEL': '1', 'CARGO_BUILD_JOBS': '1',
                    'CC': '/usr/bin/clang', 'CXX': '/usr/bin/clang++',
                    'CURRENT_ARCH': arch,
                    'CFLAGS': cflags + (' -O2' if library == 'libunibreak' else ''),
                    'CPPFLAGS': cflags,
                    'CXXFLAGS': cflags + (' -O2' if library == 'libunibreak' else ''),
                    'ASMFLAGS': cflags,
                    'LDFLAGS': ldflags,
                    'PKG_CONFIG_LIBDIR': ':'.join(pkg_roots),
                    'PKG_CONFIG_PATH': '', 'PATH': consumer.OPENSSL_DEFAULT_PATH}

            def record_template(library, platform, arch):
                build = work / 'dist' / library / platform / 'scratch' / arch
                prefix = work / 'dist' / library / platform / 'thin' / arch
                _, _, _, host, _, _, _ = consumer.subtitle_platform(platform, arch)
                arguments = (['--host=' + host, '--with-pic', '--enable-static',
                              '--disable-shared']
                             if library == 'libunibreak'
                             else list(consumer.SUBTITLE_ARGUMENTS[library]))
                return {
                    'schema': 1, 'library': library,
                    'selector': consumer.SUBTITLE_SELECTORS[library],
                    'route': consumer.SUBTITLE_ROUTES[library],
                    'platform': platform, 'arch': arch,
                    'sourceDirectory': str(work / 'dist' /
                                           (library + '-' + consumer.SUBTITLE_SELECTORS[library])),
                    'buildDirectory': str(build), 'prefix': str(prefix),
                    'arguments': arguments,
                    'environment': build_environment(library, platform, arch, build),
                    'makeArguments': (list(consumer.SUBTITLE_MAKE_ARGUMENTS)
                                      if library == 'libunibreak' else []),
                    'compiled': True, 'installed': True}

            def generated_body(library, name, platform, arch, expected, prefix):
                """Build bounded inert files that satisfy the fixed policy checks."""
                if library == 'libunibreak':
                    if name == 'Makefile':
                        environment = expected['environment']
                        return (('CC = ' + environment['CC'] + '\n' +
                                 'CFLAGS = ' + environment['CFLAGS'] + '\n' +
                                 'CPPFLAGS = ' + environment['CPPFLAGS'] + '\n' +
                                 'LDFLAGS = ' + environment['LDFLAGS'] + '\n' +
                                 'PACKAGE_VERSION = 8.0\n' +
                                 'prefix = ' + str(prefix) + '\n').encode())
                    if name in ('config.status', 'config.log'):
                        return ('inert configure trace\n' +
                                '\n'.join(expected['arguments']) + '\n').encode()
                    raise AssertionError('unknown libunibreak generated file ' + name)

                environment = expected['environment']
                subsystem = {'ios': 'ios', 'isimulator': 'ios-simulator',
                             'tvos': 'tvos', 'tvsimulator': 'tvos-simulator',
                             'macos': 'macos'}[platform]
                cpu = 'x86_64' if arch == 'x86_64' else 'arm64'
                cpu_family = 'x86_64' if arch == 'x86_64' else 'aarch64'
                if name == 'crossFile.meson':
                    cflags = ', '.join("'" + item + "'"
                                       for item in environment['CFLAGS'].split(' '))
                    ldflags = ', '.join("'" + item + "'"
                                        for item in environment['LDFLAGS'].split(' '))
                    return ("""[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
objcpp = '/usr/bin/clang++'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = 'pkg-config'

[properties]
has_function_printf = true
has_function_hfkerhisadf = false

[host_machine]
system = 'darwin'
subsystem = '{subsystem}'
kernel = 'xnu'
cpu_family = '{cpu_family}'
cpu = '{cpu}'
endian = 'little'

[built-in options]
default_library = 'static'
buildtype = 'release'
prefix = '{prefix}'
c_args = [{cflags}]
cpp_args = [{cflags}]
objc_args = [{cflags}]
objcpp_args = [{cflags}]
c_link_args = [{ldflags}]
cpp_link_args = [{ldflags}]
objc_link_args = [{ldflags}]
objcpp_link_args = [{ldflags}]
""".format(subsystem=subsystem, cpu_family=cpu_family, cpu=cpu,
           prefix=prefix, cflags=cflags, ldflags=ldflags)).encode()
                if name == 'build.ninja':
                    return b'ninja_required_version = 1.10\n'
                if name == 'compile_commands.json':
                    if library == 'libbluray':
                        source_root = '../../../../libbluray-1.5.0-f676408e/'
                        rows = []
                        for source, output in (
                                ('src/libbluray/bluray.c', 'src/libbluray.a.p/libbluray_bluray.c.o'),
                                ('contrib/libudfread/src/udfread.c',
                                 'contrib/libudfread/src/libudfread.a.p/udfread.c.o')):
                            path = source_root + source
                            arguments = (['/usr/bin/clang'] + environment['CFLAGS'].split() +
                                         ['-o', output, '-c', path])
                            rows.append({'directory': expected['buildDirectory'],
                                         'command': ' '.join(arguments), 'arguments': arguments,
                                         'file': path, 'output': output})
                        return json.dumps(rows).encode()
                    if library == 'libfribidi':
                        # Pinned gen.tab/meson.build native:true generators and
                        # lib/meson.build's distinct shipping static-library list.
                        root = '../../../../libfribidi-1.0.17-6949dcde/'
                        rows = []
                        for program in ('gen-unicode-version', 'gen-bidi-type-tab',
                                        'gen-joining-type-tab', 'gen-arabic-shaping-tab',
                                        'gen-mirroring-tab', 'gen-brackets-tab', 'gen-brackets-type-tab'):
                            sources = ([program + '.c'] if program == 'gen-unicode-version'
                                       else [program + '.c', 'packtab.c'])
                            for source in sources:
                                path = root + 'gen.tab/' + source
                                output = 'gen.tab/' + program + '.p/' + source + '.o'
                                rows.append({'directory': expected['buildDirectory'],
                                             'command': ' '.join(['cc', '-UHAVE_CONFIG_H',
                                                 '-DHAVE_STRINGIZE', '-DDONT_HAVE_FRIBIDI_CONFIG_H',
                                                 '-o', output, '-c', path]),
                                             'file': path, 'output': output})
                        for source in ('fribidi.c', 'fribidi-arabic.c', 'fribidi-bidi.c',
                                       'fribidi-bidi-types.c', 'fribidi-char-sets.c',
                                       'fribidi-char-sets-cap-rtl.c', 'fribidi-char-sets-cp1255.c',
                                       'fribidi-char-sets-cp1256.c', 'fribidi-char-sets-iso8859-6.c',
                                       'fribidi-char-sets-iso8859-8.c', 'fribidi-char-sets-utf8.c',
                                       'fribidi-deprecated.c', 'fribidi-joining.c',
                                       'fribidi-joining-types.c', 'fribidi-mirroring.c',
                                       'fribidi-brackets.c', 'fribidi-run.c', 'fribidi-shape.c'):
                            path = root + 'lib/' + source
                            output = 'lib/libfribidi.a.p/' + source + '.o'
                            arguments = (['/usr/bin/clang'] + environment['CFLAGS'].split() +
                                         ['-o', output, '-c', path])
                            row = {'directory': expected['buildDirectory'],
                                   'command': ' '.join(arguments), 'file': path, 'output': output}
                            if source == 'fribidi-arabic.c':
                                row['arguments'] = arguments
                            rows.append(row)
                        assert len(rows) == 31
                        return json.dumps(rows).encode()
                    command = ' '.join(('clang', environment['CFLAGS'], '-c', 'fixture.c'))
                    extra_command = ' '.join(('clang', environment['CFLAGS'],
                                              '-c', 'fixture-extra.c'))
                    arguments = (['clang'] + environment['CFLAGS'].split() +
                                 ['-c', 'fixture-extra.c'])
                    return json.dumps([
                        {'directory': str(prefix), 'command': command,
                         'file': 'fixture.c'},
                        {'directory': str(prefix), 'command': extra_command,
                         'arguments': arguments,
                         'file': 'fixture-extra.c'}]).encode()
                if name == 'meson-info/intro-buildoptions.json':
                    options = [{'name': 'default_library', 'value': 'static'},
                               {'name': 'buildtype', 'value': 'release'},
                               {'name': 'prefix', 'value': str(prefix)}]
                    for argument in consumer.SUBTITLE_ARGUMENTS[library]:
                        if argument == '--wrap-mode=nodownload':
                            option, value = 'wrap_mode', 'nodownload'
                        elif argument == '--force-fallback-for=libudfread':
                            option, value = 'force_fallback_for', ['libudfread']
                        else:
                            option, raw = argument.removeprefix('-D').split('=', 1)
                            value = {'true': True, 'false': False}.get(raw, raw)
                        options.append({'name': option, 'value': value})
                    return json.dumps(options, sort_keys=True).encode()
                if name == 'meson-info/intro-dependencies.json':
                    if library == 'libbluray':
                        freetype = work / 'dist/libfreetype' / platform / 'thin' / arch
                        sdk = crypto_tool_rows['platforms'][platform]['sdkRoot']
                        return json.dumps([
                            {'name': 'freetype2', 'type': 'pkgconfig', 'version': '26.6.20',
                             'compile_args': ['-I' + str(freetype / 'include/freetype2')],
                             'link_args': ['-L' + str(freetype / 'lib'), '-lfreetype']},
                            {'name': 'libxml-2.0', 'type': 'pkgconfig', 'version': '2.9.13',
                             'compile_args': ['-I' + sdk + '/usr/include/libxml2'],
                             'link_args': ['-lxml2']},
                            {'name': 'libudfread', 'type': 'internal', 'version': '1.2.0',
                             'compile_args': [], 'link_args': []}]).encode()
                    return b'[{"name":"c"}]'
                if library == 'libbluray' and name == 'config.h':
                    return (b'#define VERSION "1.5.0"\n#define HAVE_FT2 1\n'
                            b'#define HAVE_LIBXML2 1\n#define HAVE_LIBUDFREAD 1\n'
                            b'/* #undef HAVE_FONTCONFIG */\n')
                if library == 'libbluray' and name == 'contrib/libudfread/config.h':
                    return b'#define HAVE_UDFREAD_VERSION_H 1\n'
                raise AssertionError('unknown subtitle generated file ' + name)

            def installed_body(library, relative, platform, arch, prefix):
                for target, _, _, _, header_path, pc_path, header in subtitle_library_specs:
                    if library == target.lower():
                        if relative == header_path:
                            return header
                        if relative == pc_path:
                            package_name = target.removeprefix('Lib')
                            requires = ('Requires: freetype2, libxml-2.0 >=  2.6\n'
                                       if library == 'libbluray' else '')
                            return (('prefix=' + prefix + '\n' +
                                     'exec_prefix=${prefix}\nlibdir=${prefix}/lib\n'
                                     'includedir=${prefix}/include\nName: ' + package_name +
                                     '\nVersion: ' + consumer.SUBTITLE_VERSIONS[library] +
                                     '\nLibs: -L${libdir} -l' + package_name.lower() +
                                     '\nCflags: -I${includedir}\n' + requires).encode())
                raise AssertionError('unknown subtitle installed identity ' + library + '/' + relative)

            def build_value(library, platform, arch):
                expected = record_template(library, platform, arch)
                base_flags = expected['environment']['CPPFLAGS']
                optimized_flags = base_flags + (' -O2' if library == 'libunibreak' else '')
                self.assertEqual(expected['environment']['CFLAGS'], optimized_flags)
                self.assertEqual(expected['environment']['CXXFLAGS'], optimized_flags)
                self.assertEqual(expected['environment']['ASMFLAGS'], base_flags)
                for validator in (consumer.subtitle_environment, MODULE._subtitle_environment):
                    sdk_root, accepted_flags, _ = validator(
                        expected['environment'], work, library, platform, arch)
                    self.assertEqual(accepted_flags, base_flags)
                    self.assertEqual(sdk_root, crypto_tool_rows['platforms'][platform]['sdkRoot'])
                    if library != 'libunibreak' and platform == 'ios' and arch == 'arm64':
                        for key in ('CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'ASMFLAGS'):
                            changed = deepcopy(expected['environment'])
                            changed[key] += ' -O2'
                            with self.subTest(meson_library=library, forbidden_optimization=key), self.assertRaises(ValueError):
                                validator(changed, work, library, platform, arch)
                scratch = Path(expected['buildDirectory'])
                prefix = Path(expected['prefix'])
                generated = {name: generated_body(library, name, platform, arch,
                                                   expected, prefix)
                             for name in consumer.SUBTITLE_GENERATED[library]}
                installed = {name: installed_body(library, name, platform, arch, str(prefix))
                             for name in consumer.SUBTITLE_INSTALLED[library]}
                record = dict(expected)
                record['generatedConfiguration'] = {
                    name: {'bytes': len(body),
                           'sha256': hashlib.sha256(body).hexdigest(),
                           'bodyBase64': base64.b64encode(body).decode('ascii')}
                    for name, body in generated.items()}
                record['installedIdentity'] = {
                    name: {'bytes': len(body),
                           'sha256': hashlib.sha256(body).hexdigest(),
                           'bodyBase64': base64.b64encode(body).decode('ascii')}
                    for name, body in installed.items()}
                record['compiled'], record['installed'] = True, True
                record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
                value = {
                    'record': crypto_inline(
                        (scratch / 'vortx-subtitle-build.json').relative_to(work).as_posix(),
                        record_body)}
                if library == 'libbluray':
                    freetype = work / 'dist/libfreetype' / platform / 'thin' / arch
                    sdk = crypto_tool_rows['platforms'][platform]['sdkRoot']
                    freetype_archive = b'!<arch>\ninert retained target Freetype identity\n'
                    freetype_pc = (
                        'prefix=' + str(freetype) + '\n'
                        'libdir=${prefix}/lib\nincludedir=${prefix}/include\n'
                        'Name: FreeType 2\nDescription: inert target Freetype fixture\n'
                        'Version: 26.6.20\nRequires: zlib\nLibs: -L${libdir} -lfreetype\n'
                        'Cflags: -I${includedir}/freetype2\n').encode()
                    freetype_header = (b'#define FREETYPE_MAJOR 2\n#define FREETYPE_MINOR 13\n'
                                       b'#define FREETYPE_PATCH 3\n')
                    xml_header = b'#define LIBXML_DOTTED_VERSION "2.9.13"\n'
                    xml_pc = ('Name: libxml-2.0\nDescription: Target Apple SDK libxml2\n'
                              'Version: 2.9.13\nLibs: -lxml2\nCflags: -I"' + sdk +
                              '/usr/include/libxml2"\n').encode()
                    xml_stub = (b'--- !tapi-tbd\ntbd-version: 4\n'
                                b'install-name: "/usr/lib/libxml2.2.dylib"\n...\n')
                    zlib_header = b'#define ZLIB_VERSION "1.2.12"\n'
                    zlib_pc = (b'Name: zlib\nDescription: Target Apple SDK zlib\n'
                               b'Version: 1.2.12\nLibs: -lz\nCflags:\n')
                    zlib_stub = (b'--- !tapi-tbd\ntbd-version: 4\n'
                                 b'install-name: "/usr/lib/libz.1.dylib"\n...\n')
                    value['dependencyInputs'] = {
                        'freetypeArchive': {
                            'path': str((freetype / 'lib/libfreetype.a').relative_to(work)),
                            'bytes': len(freetype_archive),
                            'sha256': hashlib.sha256(freetype_archive).hexdigest()},
                        'freetypePC': crypto_inline(
                            str((freetype / 'lib/pkgconfig/freetype2.pc').relative_to(work)),
                            freetype_pc),
                        'freetypeHeader': crypto_inline(
                            str((freetype / 'include/freetype2/freetype/freetype.h').relative_to(work)),
                            freetype_header),
                        'sdkLibxmlPC': crypto_inline(
                            str((scratch / 'vortx-sdk-pkgconfig/libxml-2.0.pc').relative_to(work)), xml_pc),
                        'sdkLibxmlHeader': crypto_inline(
                            sdk + '/usr/include/libxml2/libxml/xmlversion.h', xml_header),
                        'sdkLibxmlStub': crypto_inline(sdk + '/usr/lib/libxml2.tbd', xml_stub),
                        'sdkZlibPC': crypto_inline(
                            str((scratch / 'vortx-sdk-pkgconfig/zlib.pc').relative_to(work)), zlib_pc),
                        'sdkZlibHeader': crypto_inline(sdk + '/usr/include/zlib.h', zlib_header),
                        'sdkZlibStub': crypto_inline(sdk + '/usr/lib/libz.tbd', zlib_stub)}
                return value

            for platform, arch, slice_name in consumer.SUBTITLE_MATRIX:
                identity = (platform, arch, slice_name)
                build_rows[identity] = {
                    library: build_value(library, platform, arch)
                    for library in ('libunibreak', 'libfribidi', 'libharfbuzz', 'libbluray')}

            receipt_rows = []
            for platform, arch, slice_name in consumer.SUBTITLE_MATRIX:
                receipt_rows.append({'platform': platform, 'arch': arch, 'slice': slice_name,
                                     'builds': build_rows[(platform, arch, slice_name)]})
            source_receipt = subtitle_archive_source_rows['capture']['receipt']
            value = {
                'schemaVersion': 1,
                'profile': consumer.NATIVE_UPGRADES_PROFILE,
                'sourceProfile': consumer.SUBTITLE_SOURCE_PROFILE,
                'versions': dict(consumer.SUBTITLE_VERSIONS),
                'selectors': dict(consumer.SUBTITLE_SELECTORS),
                'releaseSourceBoundary': {
                    'path': 'dist/subtitle-sources-v3/receipt.json',
                    'bytes': source_receipt['bytes'], 'sha256': source_receipt['sha256']},
                'rows': receipt_rows,
                'retainedLibassCompatibility': 'HOLD',
                'retainedBlurayCompatibility': 'HOLD',
                'retainedFreetypeAuthentication': 'HOLD',
                'runtimeSecurityTested': False,
                'promotionEligible': False}
            return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode(), value

        openssl_members, openssl_outputs = {}, {}
        subtitle_build_body, subtitle_build_value = subtitle_builds_receipt_for()
        openssl_header = b'#define OPENSSL_VERSION_NUMBER 0x40100000L\n'
        slice_arches = {}
        for platform, arch, _, slice_name in consumer.OPENSSL_MATRIX:
            slice_arches.setdefault(slice_name, set()).add(arch)
        for base in ('Libssl', 'Libcrypto'):
            for platform, arch, _, slice_name in consumer.OPENSSL_MATRIX:
                payloads = [(candidate, ('fixture-' + base + '-' + slice_name + '-' + candidate).encode())
                            for candidate in sorted(slice_arches[slice_name])]
                binary = payloads[0][1] if len(payloads) == 1 else synthetic_fat(payloads)
                binary_name = '%s.xcframework/%s/%s.framework/%s' % (base, slice_name, base, base)
                header_name = '%s.xcframework/%s/%s.framework/Headers/openssl/opensslv.h' % (
                    base, slice_name, base)
                openssl_members[binary_name] = binary
                openssl_members[header_name] = openssl_header
                key = (base, platform, arch)
                openssl_outputs.setdefault(key, {})
                thin = dict(payloads)[arch]
                openssl_outputs[key]['libssl.a' if base == 'Libssl' else 'libcrypto.a'] = {
                    'name': 'libssl.a' if base == 'Libssl' else 'libcrypto.a',
                    'path': 'lib/libssl.a' if base == 'Libssl' else 'lib/libcrypto.a',
                    'bytes': len(thin), 'sha256': hashlib.sha256(thin).hexdigest()}
                openssl_outputs[key]['opensslv.h'] = {
                    'name': 'opensslv.h', 'path': 'include/openssl/opensslv.h',
                    'bytes': len(openssl_header), 'sha256': hashlib.sha256(openssl_header).hexdigest()}

        def openssl_zip(base):
            result = io.BytesIO()
            with zipfile.ZipFile(result, 'w') as archive:
                for name, payload in openssl_members.items():
                    if name.startswith(base + '.xcframework/'):
                        info = zipfile.ZipInfo(name)
                        info.create_system, info.external_attr = 3, 0o100644 << 16
                        archive.writestr(info, payload)
            return result.getvalue()

        def openssl_receipt_fixture(old_version=False, wrong_source=False, forge=False):
            matrix = []
            for platform, arch, target, slice_name in consumer.OPENSSL_MATRIX:
                sdk_name = {'ios': 'iPhoneOS.sdk', 'isimulator': 'iPhoneSimulator.sdk',
                            'tvos': 'AppleTVOS.sdk', 'tvsimulator': 'AppleTVSimulator.sdk',
                            'macos': 'MacOSX.sdk'}[platform]
                sdk = '/fixture/Xcode/Platforms/%s.platform/Developer/SDKs/%s' % (
                    sdk_name.removesuffix('.sdk'), sdk_name)
                prefix = '/fixture/work/dist/openssl/%s/thin/%s' % (platform, arch)
                build_directory = '/fixture/work/dist/openssl/%s/scratch/%s' % (platform, arch)
                cpu = 'arm64' if arch in ('arm64', 'arm64e') else 'x86_64'
                minimum = '12.0' if platform == 'macos' else '15.0'
                target_triple = {'ios': cpu + '-apple-ios' + minimum,
                                 'isimulator': cpu + '-apple-ios' + minimum + '-simulator',
                                 'tvos': cpu + '-apple-tvos' + minimum,
                                 'tvsimulator': cpu + '-apple-tvos' + minimum + '-simulator',
                                 'macos': cpu + '-apple-macos' + minimum}[platform]
                minimum_flag = {'ios': '-mios-version-min=' + minimum,
                                'isimulator': '-mios-simulator-version-min=' + minimum,
                                'tvos': '-mtvos-version-min=' + minimum,
                                'tvsimulator': '-mtvos-simulator-version-min=' + minimum,
                                'macos': '-mmacosx-version-min=' + minimum}[platform]
                common_flags = '-arch %s -isysroot %s -target %s %s' % (
                    arch, sdk, target_triple, minimum_flag)
                cflags = common_flags + (' -DHAVE_FORK=0'
                                         if platform in ('tvos', 'tvsimulator') else '')
                pkg_config = [('/fixture/work/dist/%s/%s/thin/%s/lib/pkgconfig' %
                               (library, platform, arch))
                              for library in consumer.OPENSSL_PKG_LIBRARIES]
                pkg_config.append(build_directory + '/vortx-sdk-pkgconfig')
                env = {'CC': '/usr/bin/clang', 'CXX': '/usr/bin/clang++',
                       'CFLAGS': cflags + ' -O3', 'CPPFLAGS': cflags,
                       'CXXFLAGS': cflags + ' -O3',
                       'ASMFLAGS': cflags, 'LDFLAGS': '-lc++ ' + common_flags,
                       'PKG_CONFIG_LIBDIR': ':'.join(pkg_config),
                       'PKG_CONFIG_PATH': '', 'PATH': consumer.OPENSSL_DEFAULT_PATH,
                       'CURRENT_ARCH': arch, 'LC_CTYPE': 'C',
                       'AR': '/fixture/Xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar',
                       'ARFLAGS': 'qc',
                       'RANLIB': '/fixture/Xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/ranlib',
                       'MAKEFLAGS': '-j1', 'CMAKE_BUILD_PARALLEL_LEVEL': '1',
                       'CARGO_BUILD_JOBS': '1'}
                target_config = ('my %%targets = (\n'
                                 '    "%s" => {\n'
                                 '        inherit_from => [ "darwin-common" ],\n'
                                 '        CC => "/usr/bin/clang",\n'
                                 '        cflags => "-fno-common",\n'
                                 '        lib_cppflags => "-DL_ENDIAN",\n'
                                 '        bn_ops => "SIXTY_FOUR_BIT_LONG",\n'
                                 '        asm_arch => "%s",\n'
                                 '        perlasm_scheme => "%s",\n'
                                 '        sys_id => "%s",\n'
                                 '    },\n);\n\n' % (
                                     target,
                                     'aarch64' if arch in ('arm64', 'arm64e') else 'x86_64',
                                     'ios64' if arch in ('arm64', 'arm64e') else 'macosx',
                                     'MACOSX' if platform == 'macos' else 'iOS'))
                outputs = [openssl_outputs[('Libssl', platform, arch)]['libssl.a'],
                           openssl_outputs[('Libcrypto', platform, arch)]['libcrypto.a'],
                           openssl_outputs[('Libssl', platform, arch)]['opensslv.h']]
                effective = {'target': target, 'CC': env['CC'],
                             'CFLAGS': [env['CFLAGS']], 'CPPFLAGS': [env['CPPFLAGS']],
                             'CXX': env['CXX'], 'CXXFLAGS': [env['CXXFLAGS']],
                             'LDFLAGS': [env['LDFLAGS']], 'AR': env['AR'],
                             'ARFLAGS': ['qc'], 'RANLIB': env['RANLIB'],
                             'CROSS_COMPILE': None, 'cflags': ['-fno-common'],
                             'cppflags': ['-D_REENTRANT'],
                             'lflags': ['-Wl,-search_paths_first'],
                             'lib_cppflags': '-DL_ENDIAN'}
                if forge and platform == 'ios' and arch == 'arm64':
                    outputs[0] = dict(outputs[0], sha256='0' * 64)
                matrix.append({'platform': platform, 'arch': arch, 'slice': slice_name,
                               'configureTarget': target,
                               'configureArguments': ['--config=' + build_directory +
                                                      '/vortx-openssl-target.conf',
                                                      '--prefix=' + prefix,
                                                      *consumer.OPENSSL_CONFIGURE_FLAGS, target],
                               'sdkRoot': sdk,
                               'sourceDirectory': '/fixture/work/dist/openssl-4.1.0-2f4e3a5f',
                               'buildDirectory': build_directory, 'prefix': prefix,
                               'environment': env, 'targetConfig': target_config,
                               'targetConfigSHA256': hashlib.sha256(target_config.encode()).hexdigest(),
                               'effectiveConfiguration': effective,
                               'compiled': True,
                               'installed': True, 'outputs': outputs})
            return {'schema': 1, 'profile': consumer.NATIVE_UPGRADES_PROFILE,
                    'sourceProfile': consumer.OPENSSL_BOM_PROFILE,
                    'version': '3.3.5' if old_version else consumer.OPENSSL_SOURCE_VERSION,
                    'sourceSHA': '0' * 40 if wrong_source else consumer.OPENSSL_SOURCE_SHA,
                    'sourceTag': consumer.OPENSSL_SOURCE_TAG,
                    'validatorSHA256': recipe['scripts/native-media-hosted/evidence.py'],
                    'matrix': matrix, 'runtimeSecurityTested': False, 'promotionEligible': False}

        def candidate_archive(*, missing_lcms=False, include_receipt=True,
                              local_lcms=True, changed_lcms=False, missing_dav=False,
                              local_dav=True, changed_dav=False, shaderc_tamper=False,
                              include_shaderc_receipt=True, missing_ssl=False,
                              missing_crypto=False, old_openssl_version=False,
                              wrong_openssl_source=False, forged_openssl=False,
                              include_openssl_receipt=True, openssl_receipt_override=None,
                              include_crypto_outputs=True,
                              include_crypto_chain=True, tamper_crypto_source=False,
                              include_subtitle_outputs=True, include_subtitle_builds=True,
                              tamper_subtitle_source=False, subtitle_equal_fake=False,
                              subtitle_wrong_root=False, subtitle_extra_options=False,
                              subtitle_header_mismatch=False, subtitle_open_link=False,
                              subtitle_shaping_gate=False, missing_bluray=False,
                              local_bluray=True, bluray_header_mismatch=False):
            originals, candidate, candidate_links, package = {}, {}, {}, []
            subtitle_zip_variants = dict(subtitle_zip_bodies)
            if bluray_header_mismatch:
                subtitle_zip_variants['Libbluray'] = subtitle_zip_with_header(
                    subtitle_zip_variants['Libbluray'],
                    subtitle_library_specs[-1][-1].replace(b'"1.5.0"', b'"1.4.0"'),
                    'libbluray/bluray-version.h')
            if subtitle_header_mismatch:
                target = 'Libunibreak'
                subtitle_zip_variants[target] = subtitle_zip_with_header(
                    subtitle_zip_variants[target],
                    b'#define UNIBREAK_VERSION   0x0700   /**< Version of the libunibreak */\n'
                    b'extern const int unibreak_version;\n')
            for base, target in targets.items():
                if base in ('Libssl', 'Libcrypto'):
                    body = openssl_zip(base)
                    if ((base != 'Libssl' or not missing_ssl) and
                            (base != 'Libcrypto' or not missing_crypto)):
                        originals[base + '.xcframework.zip'] = body
                    for name, payload in openssl_members.items():
                        if name.startswith(base + '.xcframework/'):
                            candidate['MPVKit-DVFEL/artifacts/' + target + '.xcframework/' +
                                      name.split('/', 1)[1]] = payload
                    package.append('.binaryTarget(\n            name: "%s",\n'
                                   '            path: "artifacts/%s.xcframework"\n        )\n' %
                                   (target, target))
                    continue
                if base in crypto_zip_bodies:
                    originals[base + '.xcframework.zip'] = crypto_zip_bodies[base]
                    package.append('.binaryTarget(\n            name: "%s",\n'
                                   '            path: "artifacts/%s.xcframework"\n        )\n' %
                                   (target, target))
                    continue
                if base in subtitle_zip_variants:
                    if include_subtitle_outputs and not (base == 'Libbluray' and missing_bluray):
                        originals[base + '.xcframework.zip'] = subtitle_zip_variants[base]
                    if base == 'Libbluray' and not local_bluray:
                        package.append('.binaryTarget(name: "%s", url: "https://fixture.invalid/%s.zip", '
                                       'checksum: "%s")\n' % (target, target, 'a' * 64))
                    else:
                        package.append('.binaryTarget(\n            name: "%s",\n'
                                       '            path: "artifacts/%s.xcframework"\n        )\n' %
                                       (target, target))
                    continue
                payload = ('synthetic native-correspondence payload ' + base).encode()
                library = io.BytesIO()
                with zipfile.ZipFile(library, 'w') as archive:
                    info = zipfile.ZipInfo(base + '.xcframework/payload')
                    info.create_system, info.external_attr = 3, 0o100644 << 16
                    archive.writestr(info, payload)
                if ((base != 'lcms2' or not missing_lcms) and
                        (base != 'Libdav1d' or not missing_dav)):
                    originals[base + '.xcframework.zip'] = library.getvalue()
                candidate['MPVKit-DVFEL/artifacts/' + target + '.xcframework/payload'] = (
                    b'changed dependency bytes' if ((base == 'lcms2' and changed_lcms) or
                                                     (base == 'Libdav1d' and changed_dav)) else payload)
                if ((base == 'lcms2' and not local_lcms) or
                        (base == 'Libdav1d' and not local_dav)):
                    package.append('.binaryTarget(name: "%s", url: "https://fixture.invalid/%s.zip", '
                                   'checksum: "%s")\n' % (base, base, 'a' * 64))
                else:
                    package.append('.binaryTarget(\n            name: "%s",\n'
                                   '            path: "artifacts/%s.xcframework"\n        )\n' %
                                   (target, target))
            for base, body in crypto_zip_bodies.items():
                target = targets[base]
                with zipfile.ZipFile(io.BytesIO(body)) as library:
                    root = base + '.xcframework/'
                    for info in library.infolist():
                        if info.is_dir():
                            continue
                        name = info.filename
                        package_name = ('MPVKit-DVFEL/artifacts/' + target +
                                       '.xcframework/' + name.removeprefix(root))
                        mode = info.external_attr >> 16
                        if stat.S_ISLNK(mode):
                            candidate_links[package_name] = library.read(info).decode('utf-8')
                        else:
                            candidate[package_name] = library.read(info)
            for base, body in subtitle_zip_variants.items():
                target = targets[base]
                with zipfile.ZipFile(io.BytesIO(body)) as library:
                    root = base + '.xcframework/'
                    for info in library.infolist():
                        if info.is_dir():
                            continue
                        name = info.filename
                        package_name = ('MPVKit-DVFEL/artifacts/' + target +
                                       '.xcframework/' + name.removeprefix(root))
                        mode = info.external_attr >> 16
                        if stat.S_ISLNK(mode):
                            candidate_links[package_name] = library.read(info).decode('utf-8')
                        else:
                            candidate[package_name] = library.read(info)
            candidate['MPVKit-DVFEL/Package.swift'] = (''.join(package) + shaderc_target).encode()
            candidate['MPVKit-DVFEL/.gitignore'] = ignore
            package_body = candidate['MPVKit-DVFEL/Package.swift']
            result = io.BytesIO()
            with zipfile.ZipFile(result, 'w') as archive:
                archive.writestr('apple-original-library-zips.tar', synthetic_tar(originals, False))
                archive.writestr('apple-candidate.tar.gz', synthetic_tar(candidate, True, candidate_links))
                archive.writestr('apple-artifact-gate.txt', '\n'.join(
                    gates + ([profile_receipt] if include_receipt else [])) + '\n')
                all_body = b'bad!!' if shaderc_tamper else fixture_all_body
                archive.writestr('apple-shaderc-original-all.zip', all_body)
                archive.writestr('apple-shaderc-original-xcframework.zip', b'xc-body')
                if include_shaderc_receipt:
                    archive.writestr('apple-shaderc-inputs.json',
                                     json.dumps(shaderc_receipt_fixture()).encode())
                if include_openssl_receipt:
                    openssl_value = (openssl_receipt_override if openssl_receipt_override is not None else
                        openssl_receipt_fixture(old_version=old_openssl_version,
                                                wrong_source=wrong_openssl_source,
                                                forge=forged_openssl))
                    archive.writestr('apple-openssl-builds.json',
                                     (json.dumps(openssl_value, indent=2, sort_keys=True) + '\n').encode())
                if include_crypto_outputs:
                    for output, body in crypto_sources['bodies'].items():
                        if tamper_crypto_source and output == 'apple-crypto-source-gmp.tar.xz':
                            body = b'tampered source body'
                        archive.writestr(output, body)
                    archive.writestr('apple-crypto-release-sources.json', crypto_sources['receipt'])
                    archive.writestr('apple-crypto-release-sources.tar', crypto_sources['capture'])
                    if include_crypto_chain:
                        archive.writestr('apple-crypto-chain.json',
                                         crypto_chain_receipt_for(package_body))
                if include_subtitle_outputs:
                    for output, body in subtitle_sources['bodies'].items():
                        if tamper_subtitle_source and output == 'apple-subtitle-source-unibreak.tar.gz':
                            body = b'tampered subtitle source body'
                        archive.writestr(output, body)
                    archive.writestr('apple-subtitle-release-sources.json', subtitle_sources['receipt'])
                    archive.writestr('apple-subtitle-release-sources.tar', subtitle_sources['capture'])
                    if include_subtitle_builds:
                        subtitle_value = deepcopy(subtitle_build_value)
                        if subtitle_equal_fake:
                            subtitle_equal_fake_value(subtitle_value)
                        if subtitle_wrong_root:
                            record_row = subtitle_value['rows'][0]['builds']['libunibreak']['record']
                            record = json.loads(base64.b64decode(record_row['bodyBase64']))
                            record['sourceDirectory'] = '/fixture/work/dist/foreign-source'
                            record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
                            subtitle_value['rows'][0]['builds']['libunibreak']['record'] = crypto_inline(
                                record_row['path'], record_body)
                        if subtitle_extra_options:
                            record = json.loads(base64.b64decode(
                                subtitle_value['rows'][0]['builds']['libunibreak']['record']['bodyBase64']))
                            record['arguments'].append('--fixture-unapproved-option')
                            record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
                            subtitle_value['rows'][0]['builds']['libunibreak']['record'] = crypto_inline(
                                'dist/libunibreak/ios/scratch/arm64/vortx-subtitle-build.json', record_body)
                        if subtitle_open_link:
                            subtitle_value['retainedLibassCompatibility'] = 'OPEN'
                        if subtitle_shaping_gate:
                            subtitle_value['runtimeSecurityTested'] = True
                        archive.writestr('apple-subtitle-builds.json',
                                         json.dumps(subtitle_value, indent=2, sort_keys=True).encode() + b'\n')
            result.seek(0)
            return result

        captured = {'source-0/Package.swift': source_package.encode()}
        crypto_pins = crypto_sources['pins']

        def check_apple(archive, *, validate_sources=True, validate_subtitle_sources=True):
            with patch.object(consumer, 'CRYPTO_SOURCE_OUTPUTS', crypto_pins), \
                    patch.object(consumer, 'CRYPTO_SMB_HEADERS', crypto_smb_headers), \
                    patch.object(consumer, 'CRYPTO_SMB_PINS', crypto_smb_pins), \
                    patch.object(consumer, 'SUBTITLE_SOURCE_OUTPUTS', subtitle_sources['pins']), \
                    patch.object(consumer, 'BLURAY_SOURCE_TRANSFORMS', subtitle_sources['transforms']):
                archive_sources = (consumer.crypto_source_outputs(archive)
                                   if validate_sources else {'profile': consumer.CRYPTO_SOURCE_PROFILE})
                subtitle_sources_for_archive = (consumer.subtitle_source_outputs(archive)
                                                if validate_subtitle_sources else
                                                {'profile': consumer.SUBTITLE_SOURCE_PROFILE})
                consumer.apple(archive, {}, captured, recipe, archive_sources,
                               subtitle_sources_for_archive)

        with candidate_archive() as fixture, zipfile.ZipFile(fixture) as archive:
            check_apple(archive)
        for change, rejection in (
                ({'missing_lcms': True}, 'Apple original ZIP set'),
                ({'include_receipt': False}, 'artifact gates'),
                ({'local_lcms': False}, 'Apple package/source correspondence'),
                ({'changed_lcms': True}, 'Apple assembled/original ZIP/native source byte correspondence'),
                ({'missing_dav': True}, 'Apple original ZIP set'),
                ({'local_dav': False}, 'Apple package/source correspondence'),
                ({'changed_dav': True}, 'Apple assembled/original ZIP/native source byte correspondence'),
                ({'missing_ssl': True}, 'Apple original ZIP set'),
                ({'missing_crypto': True}, 'Apple original ZIP set'),
                ({'old_openssl_version': True}, 'OpenSSL receipt source/profile boundary'),
                ({'wrong_openssl_source': True}, 'OpenSSL receipt source/profile boundary'),
                ({'forged_openssl': True}, 'OpenSSL framework/static-library byte correspondence'),
                ({'shaderc_tamper': True}, 'Exact published Shaderc body'),
                ({'include_shaderc_receipt': False}, 'Missing Shaderc receipt output'),
                ({'include_openssl_receipt': False}, 'Missing OpenSSL BOM output'),
                ({'include_crypto_outputs': False}, 'Missing crypto source/artifact receipt output'),
                ({'include_crypto_chain': False}, 'Missing crypto source/artifact receipt output'),
                ({'tamper_crypto_source': True}, 'Crypto release source body differs from its fixed pin')):
            with self.subTest(dependency_candidate=change):
                with candidate_archive(**change) as fixture, zipfile.ZipFile(fixture) as archive:
                    with self.assertRaisesRegex(ValueError, rejection):
                        check_apple(archive, validate_sources=change.get('include_crypto_outputs', True))

        for change in (
                {'include_subtitle_outputs': False},
                {'include_subtitle_builds': False},
                {'tamper_subtitle_source': True},
                {'subtitle_equal_fake': True},
                {'subtitle_wrong_root': True},
                {'subtitle_extra_options': True},
                {'subtitle_header_mismatch': True},
                {'missing_bluray': True},
                {'local_bluray': False},
                {'bluray_header_mismatch': True},
                {'subtitle_open_link': True},
                {'subtitle_shaping_gate': True}):
            with self.subTest(dependency_candidate=change):
                with candidate_archive(**change) as fixture, zipfile.ZipFile(fixture) as archive:
                    with self.assertRaises(ValueError):
                        check_apple(archive, validate_subtitle_sources=
                                    change.get('include_subtitle_outputs', True))

        # Equal self-reported fake hashes do not establish correspondence: the
        # offline consumer must still bind every row to retained ZIP bytes.
        with candidate_archive() as fixture, zipfile.ZipFile(fixture) as archive:
            candidate_rows, captured_rows = consumer.tar_index(
                archive, 'apple-candidate.tar.gz', file_limit=512 * 1024**2,
                total=4 * 1024**3, capture=('MPVKit-DVFEL/Package.swift',),
                allow_dirs=True)
            forged = consumer.crypto_load(archive.read('apple-crypto-chain.json'))
            forged['rows'][0]['libraries']['gmp']['thin']['sha256'] = '0' * 64
            forged['rows'][0]['libraries']['gmp']['correspondence']['sha256'] = '0' * 64
            forged_body = (json.dumps(forged, indent=2, sort_keys=True) + '\n').encode()
            with patch.object(consumer, 'CRYPTO_SMB_HEADERS', crypto_smb_headers), \
                    patch.object(consumer, 'CRYPTO_SMB_PINS', crypto_smb_pins), \
                    self.assertRaises(ValueError):
                consumer.crypto_chain_receipt(
                    forged_body, crypto_zip_bodies, crypto_archive_source_rows,
                    candidate_rows['MPVKit-DVFEL/Package.swift'],
                    captured_rows['MPVKit-DVFEL/Package.swift'])

        valid_receipt = shaderc_receipt_fixture()
        consumer.shaderc_receipt(valid_receipt,
                                 valid_receipt['sources'],
                                 recipe['scripts/native-media-hosted/evidence.py'],
                                 fixture_all_rows)
        for index, mutate in enumerate((
                lambda row: row.update(validatorSHA256='0' * 64),
                lambda row: row.update(profile='old-profile'),
                lambda row: row.update(runtimeSecurityTested=True),
                lambda row: row['reader'].update(resolvedReader='/' + 'x' * 4096),
                lambda row: row['reader'].update(toolchainReader='/fixture/other-xcodebuild'),
                lambda row: row['reader'].update(toolchainSHA256='not-a-digest'),
                lambda row: row['reader'].pop('toolchainSHA256'),
                lambda row: row['sources'][0].update(bytes=6),
                lambda row: row['matrix'].pop(),
                lambda row: row['matrix'][0].update(equal=False),
                lambda row: row['matrix'][0].update(allZipEntry='lib/ios/thin/x86_64/lib/libshaderc_combined.a'),
                lambda row: row['matrix'][0].update(allArchiveSHA256='a' * 64,
                                                     xcArchiveSHA256='a' * 64))):
            observed = deepcopy(valid_receipt)
            before_mutation = deepcopy(observed)
            mutate(observed)
            with self.subTest(receipt='shaderc', index=index):
                self.assertNotEqual(observed, before_mutation,
                                    'negative Shaderc receipt mutation is a no-op')
                with self.assertRaises(ValueError):
                    consumer.shaderc_receipt(observed, valid_receipt['sources'],
                                             recipe['scripts/native-media-hosted/evidence.py'],
                                             fixture_all_rows)
        with self.assertRaises(ValueError):
            consumer.shaderc_remote_target(source_package.replace(fixture_specs[1][2], '0' * 64))

        consumer.subtitle_builds_receipt(subtitle_build_body, subtitle_zip_bodies,
                                         subtitle_archive_source_rows)
        for row in subtitle_build_value['rows']:
            fri_record = json.loads(base64.b64decode(
                row['builds']['libfribidi']['record']['bodyBase64']))
            MODULE._subtitle_record_contract(fri_record, Path('/fixture/work'), 'libfribidi',
                                             row['platform'], row['arch'], [0])

        def subtitle_body_with_record_mutation(mutate):
            value = deepcopy(subtitle_build_value)
            row = value['rows'][0]['builds']['libunibreak']
            record = json.loads(base64.b64decode(row['record']['bodyBase64']))
            before = deepcopy(record)
            mutate(record)
            self.assertNotEqual(record, before, 'negative subtitle record mutation is a no-op')
            body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
            row['record'] = crypto_inline(
                'dist/libunibreak/ios/scratch/arm64/vortx-subtitle-build.json', body)
            return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

        def subtitle_body_with_generated_mutation(library, name, mutate):
            value = deepcopy(subtitle_build_value)
            row = value['rows'][0]['builds'][library]
            record = json.loads(base64.b64decode(row['record']['bodyBase64']))
            generated = json.loads(base64.b64decode(
                record['generatedConfiguration'][name]['bodyBase64']))
            before = deepcopy(generated)
            mutate(generated)
            self.assertNotEqual(generated, before,
                                'negative subtitle generated-body mutation is a no-op')
            generated_body = json.dumps(generated, sort_keys=True).encode()
            record['generatedConfiguration'][name] = {
                'bytes': len(generated_body),
                'sha256': hashlib.sha256(generated_body).hexdigest(),
                'bodyBase64': base64.b64encode(generated_body).decode('ascii')}
            record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
            row['record'] = crypto_inline(row['record']['path'], record_body)
            return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

        def subtitle_body_with_generated_text_mutation(library, name, mutate):
            value = deepcopy(subtitle_build_value)
            row = value['rows'][0]['builds'][library]
            record = json.loads(base64.b64decode(row['record']['bodyBase64']))
            generated = record['generatedConfiguration'][name]
            old_body = base64.b64decode(generated['bodyBase64'])
            new_body = mutate(old_body)
            self.assertNotEqual(new_body, old_body,
                                'negative subtitle generated-text mutation is a no-op')
            generated.update(bytes=len(new_body),
                             sha256=hashlib.sha256(new_body).hexdigest(),
                             bodyBase64=base64.b64encode(new_body).decode('ascii'))
            record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
            row['record'] = crypto_inline(row['record']['path'], record_body)
            return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

        def subtitle_body_with_installed_mutation(
                mutate, library='libunibreak', header='include/unibreakbase.h'):
            value = deepcopy(subtitle_build_value)
            row = value['rows'][0]['builds'][library]
            record = json.loads(base64.b64decode(row['record']['bodyBase64']))
            installed = record['installedIdentity'][header]
            old_body = base64.b64decode(installed['bodyBase64'])
            new_body = mutate(old_body)
            self.assertNotEqual(new_body, old_body,
                                'negative subtitle installed-body mutation is a no-op')
            installed.update(bytes=len(new_body),
                             sha256=hashlib.sha256(new_body).hexdigest(),
                             bodyBase64=base64.b64encode(new_body).decode('ascii'))
            record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
            row['record'] = crypto_inline(row['record']['path'], record_body)
            return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

        def subtitle_body_with_all_installed_mutation(library, header, mutate):
            value = deepcopy(subtitle_build_value)
            for row in value['rows']:
                build = row['builds'][library]
                record = json.loads(base64.b64decode(build['record']['bodyBase64']))
                installed = record['installedIdentity'][header]
                old_body = base64.b64decode(installed['bodyBase64'])
                new_body = mutate(old_body)
                self.assertNotEqual(new_body, old_body,
                                    'negative subtitle installed-body mutation is a no-op')
                installed.update(bytes=len(new_body),
                                 sha256=hashlib.sha256(new_body).hexdigest(),
                                 bodyBase64=base64.b64encode(new_body).decode('ascii'))
                record_body = json.dumps(record, indent=2, sort_keys=True).encode() + b'\n'
                build['record'] = crypto_inline(build['record']['path'], record_body)
            return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

        self.assertEqual(sum(len(row['builds']) for row in subtitle_build_value['rows']), 36)
        def unibreak_optimization_mutation(record, key, change):
            old = record['environment'].get(key)
            new = change(record['environment']['CPPFLAGS'])
            record['environment'][key] = new
            if key in ('CFLAGS', 'CPPFLAGS'):
                generated = record['generatedConfiguration']['Makefile']
                body = base64.b64decode(generated['bodyBase64'])
                before = (key + ' = ' + old + '\n').encode()
                self.assertEqual(body.count(before), 1)
                body = body.replace(before, (key + ' = ' + new + '\n').encode())
                generated.update(bytes=len(body), sha256=hashlib.sha256(body).hexdigest(),
                                 bodyBase64=base64.b64encode(body).decode('ascii'))

        for name, key, change in (
                ('absent-c-optimization', 'CFLAGS', lambda base: base),
                ('absent-cxx-optimization', 'CXXFLAGS', lambda base: base),
                ('double-optimization', 'CFLAGS', lambda base: base + ' -O2 -O2'),
                ('nontrailing-optimization', 'CFLAGS', lambda base: '-O2 ' + base),
                ('wrong-optimization-level', 'CFLAGS', lambda base: base + ' -O3'),
                ('cpp-optimization-smuggling', 'CPPFLAGS', lambda base: base + ' -O2'),
                ('asm-optimization-smuggling', 'ASMFLAGS', lambda base: base + ' -O2'),
                ('native-generator-optimization-smuggling', 'CC_FOR_BUILD',
                 lambda base: '/usr/bin/clang -O2')):
            body = subtitle_body_with_record_mutation(
                lambda record: unibreak_optimization_mutation(record, key, change))
            record = json.loads(base64.b64decode(
                json.loads(body)['rows'][0]['builds']['libunibreak']['record']['bodyBase64']))
            with self.subTest(unibreak_optimization=name):
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(body, subtitle_zip_bodies, subtitle_archive_source_rows)
                with self.assertRaises(ValueError):
                    MODULE._subtitle_record_contract(record, Path('/fixture/work'), 'libunibreak',
                                                     'ios', 'arm64', [0])
        # Correct optimized environment cannot conceal a stale unoptimized
        # generated Makefile; bind the effective assignment separately.
        body = subtitle_body_with_generated_text_mutation(
            'libunibreak', 'Makefile', lambda raw: raw.replace(b' -O2\n', b'\n', 1))
        with self.assertRaises(ValueError):
            consumer.subtitle_builds_receipt(body, subtitle_zip_bodies, subtitle_archive_source_rows)
        stale_record = json.loads(base64.b64decode(
            json.loads(body)['rows'][0]['builds']['libunibreak']['record']['bodyBase64']))
        with self.assertRaises(ValueError):
            MODULE._subtitle_record_contract(stale_record, Path('/fixture/work'), 'libunibreak',
                                             'ios', 'arm64', [0])
        for row in subtitle_build_value['rows']:
            bluray_record = json.loads(base64.b64decode(
                row['builds']['libbluray']['record']['bodyBase64']))
            MODULE._subtitle_record_contract(bluray_record, Path('/fixture/work'), 'libbluray',
                                             row['platform'], row['arch'], [0])

        # Real Meson static layout, including its public dependency/version spelling.
        real_pc_prefix = Path('/fixture/work/dist/libbluray/macos/thin/arm64')
        real_static_pc = (
            'prefix=' + str(real_pc_prefix) + '\n'
            'includedir=${prefix}/include\nlibdir=${prefix}/lib\n\n'
            'Name: libbluray\nDescription: library supporting Blu-ray playback\n'
            'Version: 1.5.0\nRequires: freetype2, libxml-2.0 >=  2.6\n'
            'Libs: -L${libdir} -lbluray -framework CoreFoundation -framework DiskArbitration\n'
            'Cflags: -I${includedir}\n').encode()
        MODULE._subtitle_pc(real_static_pc, 'libbluray', real_pc_prefix)
        consumer.subtitle_pc(real_static_pc, 'libbluray', real_pc_prefix)
        public_requires = b'Requires: freetype2, libxml-2.0 >=  2.6\n'
        for name, replacement in (
                ('private-only', b'Requires.private: freetype2 libxml-2.0 >= 2.6\n'),
                ('split-public-private', b'Requires: freetype2\nRequires.private: libxml-2.0 >= 2.6\n'),
                ('private-extra', public_requires + b'Requires.private: host-package\n'),
                ('private-empty', public_requires + b'Requires.private:\n'),
                ('duplicate-field', public_requires + public_requires),
                ('duplicate-package', b'Requires: freetype2, freetype2, libxml-2.0 >= 2.6\n'),
                ('missing-freetype', b'Requires: libxml-2.0 >= 2.6\n'),
                ('missing-xml', b'Requires: freetype2\n'),
                ('missing-xml-version', b'Requires: freetype2, libxml-2.0\n'),
                ('wrong-xml-version', b'Requires: freetype2, libxml-2.0 >= 2.7\n'),
                ('wrong-xml-operator', b'Requires: freetype2, libxml-2.0 <= 2.6\n'),
                ('extra-dependency', public_requires.rstrip(b'\n') + b', libudfread\n'),
                ('host-dependency', public_requires.rstrip(b'\n') + b', host-package\n'),
                ('host-path', public_requires.rstrip(b'\n') + b', /opt/homebrew/lib/pkgconfig/host.pc\n')):
            with self.subTest(bluray_static_pc=name):
                changed = real_static_pc.replace(public_requires, replacement)
                self.assertNotEqual(changed, real_static_pc)
                with self.assertRaises(ValueError):
                    MODULE._subtitle_pc(changed, 'libbluray', real_pc_prefix)
                with self.assertRaises(ValueError):
                    consumer.subtitle_pc(changed, 'libbluray', real_pc_prefix)
                # Rehash both installed bytes and their containing real-shape record.
                body = subtitle_body_with_installed_mutation(
                    lambda old, replacement=replacement: old.replace(public_requires, replacement),
                    library='libbluray', header='lib/pkgconfig/libbluray.pc')
                record = json.loads(base64.b64decode(
                    json.loads(body)['rows'][0]['builds']['libbluray']['record']['bodyBase64']))
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(body, subtitle_zip_bodies, subtitle_archive_source_rows)
                with self.assertRaises(ValueError):
                    MODULE._subtitle_record_contract(record, Path('/fixture/work'), 'libbluray',
                                                     'ios', 'arm64', [0])

        def change_bluray_compile_role(rows, key, replacement):
            row = rows[0]
            arguments = row['arguments']
            if key == 'compiler':
                arguments[0] = replacement
            else:
                old = row[key]
                self.assertIn(old, arguments)
                arguments[arguments.index(old)] = replacement
                row[key] = replacement
            row['command'] = ' '.join(arguments)

        bluray_generated_negative = (
            ('host-freetype', 'meson-info/intro-dependencies.json',
             lambda rows: rows[0].update(compile_args=['-I/opt/homebrew/include/freetype2'])),
            ('wrong-sdk-xml', 'meson-info/intro-dependencies.json',
             lambda rows: rows[1].update(compile_args=['-I/fixture/other-sdk/usr/include/libxml2'])),
            ('external-udf-role', 'meson-info/intro-dependencies.json',
             lambda rows: rows[2].update(type='pkgconfig')),
            ('wrong-embedded-udf-version', 'meson-info/intro-dependencies.json',
             lambda rows: rows[2].update(version='1.1.2')),
            ('missing-embedded-udf-source', 'compile_commands.json', lambda rows: rows.pop()),
            ('host-compiler-role', 'compile_commands.json',
             lambda rows: change_bluray_compile_role(rows, 'compiler', 'cc')),
            ('source-outside-admitted-root', 'compile_commands.json',
             lambda rows: change_bluray_compile_role(rows, 'file', '/fixture/foreign/bluray.c')),
            ('output-outside-build-root', 'compile_commands.json',
             lambda rows: change_bluray_compile_role(rows, 'output', '/fixture/foreign/bluray.o')),
            ('download-wrap-mode', 'meson-info/intro-buildoptions.json',
             lambda rows: next(row for row in rows if row['name'] == 'wrap_mode').update(value='default')),
            ('no-forced-embedded-fallback', 'meson-info/intro-buildoptions.json',
             lambda rows: next(row for row in rows if row['name'] == 'force_fallback_for').update(value=[])))
        for name, generated_name, mutate in bluray_generated_negative:
            body = subtitle_body_with_generated_mutation('libbluray', generated_name, mutate)
            record = json.loads(base64.b64decode(
                json.loads(body)['rows'][0]['builds']['libbluray']['record']['bodyBase64']))
            with self.subTest(bluray_build=name):
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(body, subtitle_zip_bodies, subtitle_archive_source_rows)
                with self.assertRaises(ValueError):
                    MODULE._subtitle_record_contract(record, Path('/fixture/work'), 'libbluray',
                                                     'ios', 'arm64', [0])
        for name, generated_name, mutate in (
                ('disabled-freetype', 'config.h', lambda body: body.replace(b'HAVE_FT2 1', b'HAVE_FT2 0')),
                ('active-undef-freetype', 'config.h', lambda body: body + b'#undef HAVE_FT2\n'),
                ('enabled-fontconfig', 'config.h', lambda body: body + b'#define HAVE_FONTCONFIG 1\n'),
                ('wrong-configured-version', 'config.h', lambda body: body.replace(b'"1.5.0"', b'"1.4.0"')),
                ('disabled-udf-version-header', 'contrib/libudfread/config.h',
                 lambda body: body.replace(b'HAVE_UDFREAD_VERSION_H 1', b'HAVE_UDFREAD_VERSION_H 0')),
                ('active-undef-udf-version-header', 'contrib/libudfread/config.h',
                 lambda body: body + b'#undef HAVE_UDFREAD_VERSION_H\n')):
            body = subtitle_body_with_generated_text_mutation('libbluray', generated_name, mutate)
            record = json.loads(base64.b64decode(
                json.loads(body)['rows'][0]['builds']['libbluray']['record']['bodyBase64']))
            with self.subTest(bluray_config=name):
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(body, subtitle_zip_bodies, subtitle_archive_source_rows)
                with self.assertRaises(ValueError):
                    MODULE._subtitle_record_contract(record, Path('/fixture/work'), 'libbluray',
                                                     'ios', 'arm64', [0])

        dependency_fixture = subtitle_build_value['rows'][0]['builds']['libbluray']['dependencyInputs']
        dependency_sdk = crypto_tool_rows['platforms']['ios']['sdkRoot']
        def change_dependency_body(rows, name, change):
            row = rows[name]
            before = base64.b64decode(row['bodyBase64'])
            after = change(before)
            self.assertNotEqual(after, before, 'dependency body mutation is a no-op')
            rows[name] = crypto_inline(row['path'], after)

        for module in (consumer, MODULE):
            module._bluray_dependency_inputs(dependency_fixture, Path('/fixture/work'),
                                              'ios', 'arm64', dependency_sdk, [0])
            for name, mutate in (
                    ('missing-raw-sdk-input', lambda rows: rows.pop('sdkLibxmlHeader')),
                    ('wrong-freetype-architecture', lambda rows: rows['freetypeArchive'].update(
                        path=rows['freetypeArchive']['path'].replace('/arm64/', '/x86_64/'))),
                    ('unbound-raw-body', lambda rows: rows['sdkZlibHeader'].update(sha256='0' * 64)),
                    ('freetype-host-provider', lambda rows: change_dependency_body(rows, 'freetypePC',
                        lambda body: body.replace(b'-L${libdir}', b'-L/opt/homebrew/lib'))),
                    ('sdk-header-pc-version-mismatch', lambda rows: change_dependency_body(rows, 'sdkLibxmlHeader',
                        lambda body: body.replace(b'2.9.13', b'2.9.12'))),
                    ('sdk-linker-wrong-library', lambda rows: change_dependency_body(rows, 'sdkLibxmlStub',
                        lambda body: body.replace(b'libxml2.2.dylib', b'libxml2-host.dylib'))),
                    ('freetype-missing-version-macro', lambda rows: change_dependency_body(rows, 'freetypeHeader',
                        lambda body: body.replace(b'FREETYPE_PATCH', b'UNRELATED_PATCH')))):
                changed = deepcopy(dependency_fixture)
                mutate(changed)
                self.assertNotEqual(changed, dependency_fixture)
                with self.subTest(boundary=module.__name__, bluray_dependency=name), self.assertRaises(ValueError):
                    module._bluray_dependency_inputs(changed, Path('/fixture/work'),
                                                     'ios', 'arm64', dependency_sdk, [0])

        for name, mutate in (
                ('missing-fourth-build', lambda value: value['rows'][0]['builds'].pop('libbluray')),
                ('missing-ninth-slice', lambda value: value['rows'].pop()),
                ('missing-dependency-family', lambda value: value['rows'][0]['builds']['libbluray'].pop('dependencyInputs')),
                ('false-bluray-promotion', lambda value: value.update(retainedBlurayCompatibility='PASS')),
                ('false-freetype-authentication', lambda value: value.update(retainedFreetypeAuthentication='PASS'))):
            changed = deepcopy(subtitle_build_value)
            mutate(changed)
            self.assertNotEqual(changed, subtitle_build_value)
            with self.subTest(bluray_bom=name), self.assertRaises(ValueError):
                consumer.subtitle_builds_receipt(consumer.crypto_canonical(changed), subtitle_zip_bodies,
                                                 subtitle_archive_source_rows)

        def noncanonical_unibreak_host(record):
            before = record['arguments'][0]
            record['arguments'][0] = before.replace('--host=aarch64-', '--host=arm64-', 1)
            self.assertNotEqual(record['arguments'][0], before)
            # Keep both recorded configure traces coherent with the wrong argument.
            for name in ('config.status', 'config.log'):
                row = record['generatedConfiguration'][name]
                body = base64.b64decode(row['bodyBase64'])
                changed_body = body.replace(b'--host=aarch64-', b'--host=arm64-', 1)
                self.assertNotEqual(changed_body, body)
                row.update(bytes=len(changed_body),
                           sha256=hashlib.sha256(changed_body).hexdigest(),
                           bodyBase64=base64.b64encode(changed_body).decode('ascii'))

        subtitle_negative = (
            ('equal-fake-installed-header', subtitle_equal_fake_value, subtitle_build_body),
            ('noncanonical-gnu-host', noncanonical_unibreak_host,
             subtitle_body_with_record_mutation),
            ('wrong-source-root', lambda value: value.update(sourceDirectory='/fixture/work/dist/foreign-source'),
             subtitle_body_with_record_mutation),
            ('extra-option', lambda value: value['arguments'].append('--fixture-unapproved-option'),
             subtitle_body_with_record_mutation))
        for name, mutate, builder in subtitle_negative:
            with self.subTest(receipt='subtitle', mutation=name):
                if builder is subtitle_build_body:
                    observed = deepcopy(subtitle_build_value)
                    before = deepcopy(observed)
                    mutate(observed)
                    self.assertNotEqual(observed, before, 'negative subtitle receipt mutation is a no-op')
                    observed_body = (json.dumps(observed, indent=2, sort_keys=True) + '\n').encode()
                else:
                    observed_body = builder(mutate)
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(observed_body, subtitle_zip_bodies,
                                                     subtitle_archive_source_rows)

        generated_negative = (
            ('wrong-effective-prefix', 'meson-info/intro-buildoptions.json',
             lambda rows: next(
                 row for row in rows if row['name'] == 'prefix'
             ).update(value='/fixture/work/dist/foreign-prefix')),
            ('second-command-target', 'compile_commands.json',
             lambda rows: rows[14]['arguments'].__setitem__(
                 rows[14]['arguments'].index('-target') + 1,
                 'arm64-apple-ios99.0')),
            ('second-command-sdk', 'compile_commands.json',
             lambda rows: rows[14]['arguments'].__setitem__(
                 rows[14]['arguments'].index('-isysroot') + 1,
                 '/fixture/Xcode/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk')),
            ('second-command-minimum', 'compile_commands.json',
             lambda rows: rows[14]['arguments'].__setitem__(
                 rows[14]['arguments'].index('-mios-version-min=15.0'),
                 '-mios-version-min=16.0')),
            ('second-command-spelling-target', 'compile_commands.json',
             lambda rows: rows[14].update(
                 command=rows[14]['command'] + ' --target=arm64-apple-ios99.0')),
            ('second-arguments-spelling-target', 'compile_commands.json',
             lambda rows: rows[14]['arguments'].append('--target=arm64-apple-ios99.0')),
            ('second-command-spelling-sysroot', 'compile_commands.json',
             lambda rows: rows[14].update(
                 command=rows[14]['command'] +
                 ' --sysroot=/fixture/Platforms/Other.platform/SDKs/Other.sdk')),
            ('second-arguments-spelling-sysroot', 'compile_commands.json',
             lambda rows: rows[14]['arguments'].append(
                 '--sysroot=/fixture/Platforms/Other.platform/SDKs/Other.sdk')))
        for name, generated_name, mutate in generated_negative:
            with self.subTest(receipt='subtitle', mutation=name):
                observed_body = subtitle_body_with_generated_mutation(
                    'libfribidi', generated_name, mutate)
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(observed_body, subtitle_zip_bodies,
                                                     subtitle_archive_source_rows)

        def fri_native_arguments(rows):
            rows[0]['arguments'] = rows[0].pop('command').split()

        def fri_native_both(rows):
            rows[0]['arguments'] = rows[0]['command'].split()

        for name, mutate in (('native-arguments-only', fri_native_arguments),
                             ('native-both-payloads', fri_native_both),
                             ('unordered-exact-multiset', lambda rows: rows.reverse())):
            with self.subTest(receipt='fribidi-roles-positive', mutation=name):
                observed_body = subtitle_body_with_generated_mutation(
                    'libfribidi', 'compile_commands.json', mutate)
                consumer.subtitle_builds_receipt(observed_body, subtitle_zip_bodies,
                                                 subtitle_archive_source_rows)
                value = json.loads(observed_body)
                record = json.loads(base64.b64decode(
                    value['rows'][0]['builds']['libfribidi']['record']['bodyBase64']))
                MODULE._subtitle_record_contract(record, Path('/fixture/work'),
                                                 'libfribidi', 'ios', 'arm64', [0])

        fri_root = '../../../../libfribidi-1.0.17-6949dcde/'
        fri_negative = (
            ('missing-native', lambda rows: rows.pop(0)),
            ('duplicate-native', lambda rows: rows.__setitem__(1, deepcopy(rows[0]))),
            ('duplicate-packtab-role', lambda rows: rows.__setitem__(2, deepcopy(rows[4]))),
            ('unknown-native-program', lambda rows: rows[0].update(
                output='gen.tab/gen-unknown.p/gen-unicode-version.c.o')),
            ('native-foreign-directory', lambda rows: rows[0].update(directory='/fixture/foreign')),
            ('native-target-source-metadata', lambda rows: rows[0].update(
                file=fri_root + 'lib/fribidi.c')),
            ('native-target-source-command', lambda rows: rows[0].update(
                command=rows[0]['command'].replace(
                    fri_root + 'gen.tab/gen-unicode-version.c', fri_root + 'lib/fribidi.c'))),
            ('native-target-output-command', lambda rows: rows[0].update(
                command=rows[0]['command'].replace(
                    'gen.tab/gen-unicode-version.p/gen-unicode-version.c.o',
                    'lib/libfribidi.a.p/fribidi.c.o'))),
            ('native-extra-target-source', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' ' + fri_root + 'lib/fribidi.c')),
            ('native-wrong-compiler', lambda rows: rows[0].update(
                command=rows[0]['command'].replace('cc ', '/usr/bin/clang ', 1))),
            ('native-target-flags', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' -target arm64-apple-ios15.0')),
            ('native-conflicting-config', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' -DHAVE_CONFIG_H=1')),
            ('native-split-config-command', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' -D HAVE_CONFIG_H=1')),
            ('native-split-stringize-command', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' -U HAVE_STRINGIZE')),
            ('native-split-config-arguments', lambda rows: rows[0].update(
                arguments=rows[0]['command'].split() + ['-D', 'HAVE_CONFIG_H=1'])),
            ('native-split-stringize-arguments', lambda rows: rows[0].update(
                arguments=rows[0]['command'].split() + ['-U', 'HAVE_STRINGIZE'])),
            ('native-spaced-config-token', lambda rows: rows[0].update(
                arguments=rows[0]['command'].split() + ['-D HAVE_CONFIG_H=1'])),
            ('native-forwarded-config-command', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' -Wp,-DHAVE_CONFIG_H=1')),
            ('native-forwarded-config-arguments', lambda rows: rows[0].update(
                arguments=rows[0]['command'].split() + ['-Xpreprocessor', '-DHAVE_CONFIG_H=1'])),
            ('native-forwarded-config-clang', lambda rows: rows[0].update(
                arguments=rows[0]['command'].split() + ['-Xclang', '-DHAVE_CONFIG_H=1'])),
            ('native-joined-output-command', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' -o/fixture/foreign.o')),
            ('native-joined-output-arguments', lambda rows: rows[0].update(
                arguments=rows[0]['command'].split() + ['-o/fixture/foreign.o'])),
            ('native-response-file', lambda rows: rows[0].update(
                command=rows[0]['command'] + ' @/fixture/foreign.rsp')),
            ('missing-shipping', lambda rows: rows.pop()),
            ('duplicate-shipping', lambda rows: rows.__setitem__(-1, deepcopy(rows[-2]))),
            ('shipping-missing-target-arch', lambda rows: rows[13].update(
                command=rows[13]['command'].replace(' -arch arm64', '', 1))),
            ('shipping-joined-output-command', lambda rows: rows[13].update(
                command=rows[13]['command'] + ' -o/fixture/foreign.o')),
            ('shipping-alternate-output-arguments', lambda rows: rows[14]['arguments'].append(
                '--output=/fixture/foreign.o')),
            ('shipping-response-file', lambda rows: rows[13].update(
                command=rows[13]['command'] + ' @/fixture/foreign.rsp')),
            ('shipping-forged-native-role', lambda rows: rows.__setitem__(13, deepcopy(rows[0]))),
            ('shipping-unknown-source', lambda rows: rows[13].update(
                file=fri_root + 'lib/unknown.c')))
        for name, mutate in fri_negative:
            with self.subTest(receipt='fribidi-roles-negative', mutation=name):
                observed_body = subtitle_body_with_generated_mutation(
                    'libfribidi', 'compile_commands.json', mutate)
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(observed_body, subtitle_zip_bodies,
                                                     subtitle_archive_source_rows)
                value = json.loads(observed_body)
                record = json.loads(base64.b64decode(
                    value['rows'][0]['builds']['libfribidi']['record']['bodyBase64']))
                with self.assertRaises(ValueError):
                    MODULE._subtitle_record_contract(record, Path('/fixture/work'),
                                                     'libfribidi', 'ios', 'arm64', [0])

        makefile_negative = (
            ('wrong-makefile-cc', lambda body: body.replace(
                b'CC = /usr/bin/clang\n', b'CC = /usr/bin/not-clang\n', 1)),
            ('wrong-makefile-cflags', lambda body: body.replace(
                b'CFLAGS = ', b'CFLAGS = -Dforged ', 1)),
            ('modified-makefile-cflags', lambda body:
             body + b'CFLAGS += --target=arm64-apple-ios99.0\n'),
            ('duplicate-makefile-version', lambda body:
             body + b'PACKAGE_VERSION = 7.0\n'),
            ('duplicate-makefile-prefix', lambda body:
             body + b'prefix = /fixture/work/dist/foreign-prefix\n'))
        for name, mutate in makefile_negative:
            with self.subTest(receipt='subtitle', mutation=name):
                observed_body = subtitle_body_with_generated_text_mutation(
                    'libunibreak', 'Makefile', mutate)
                with self.assertRaises(ValueError):
                    consumer.subtitle_builds_receipt(observed_body, subtitle_zip_bodies,
                                                     subtitle_archive_source_rows)

        duplicate_header = subtitle_body_with_installed_mutation(
            lambda body: body + b'#define UNIBREAK_VERSION 0x0700\n')
        with self.assertRaises(ValueError):
            consumer.subtitle_builds_receipt(duplicate_header, subtitle_zip_bodies,
                                             subtitle_archive_source_rows)

        duplicate_hb = b'#define HB_VERSION_MAJOR (14)\n'
        duplicate_hb_body = subtitle_body_with_all_installed_mutation(
            'libharfbuzz', 'include/harfbuzz/hb-version.h',
            lambda body: body + duplicate_hb)
        duplicate_hb_zips = dict(subtitle_zip_bodies)
        duplicate_hb_zips['Libharfbuzz'] = subtitle_zip_with_header(
            duplicate_hb_zips['Libharfbuzz'],
            next(spec[-1] for spec in subtitle_library_specs
                 if spec[0] == 'Libharfbuzz') + duplicate_hb,
            'harfbuzz/hb-version.h')
        with self.assertRaises(ValueError):
            consumer.subtitle_builds_receipt(duplicate_hb_body, duplicate_hb_zips,
                                             subtitle_archive_source_rows)

        observed = deepcopy(subtitle_build_value)
        observed['retainedLibassCompatibility'] = 'OPEN'
        with self.assertRaises(ValueError):
            consumer.subtitle_builds_receipt(
                (json.dumps(observed, indent=2, sort_keys=True) + '\n').encode(),
                subtitle_zip_bodies, subtitle_archive_source_rows)
        observed = deepcopy(subtitle_build_value)
        observed['runtimeSecurityTested'] = True
        with self.assertRaises(ValueError):
            consumer.subtitle_builds_receipt(
                (json.dumps(observed, indent=2, sort_keys=True) + '\n').encode(),
                subtitle_zip_bodies, subtitle_archive_source_rows)

        changed_subtitle_zips = dict(subtitle_zip_bodies)
        changed_subtitle_zips['Libunibreak'] = subtitle_zip_with_header(
            changed_subtitle_zips['Libunibreak'],
            b'#define UNIBREAK_VERSION   0x0700   /**< Version of the libunibreak */\n'
            b'extern const int unibreak_version;\n')
        with self.assertRaises(ValueError):
            consumer.subtitle_builds_receipt(subtitle_build_body, changed_subtitle_zips,
                                             subtitle_archive_source_rows)

        valid_openssl = openssl_receipt_fixture()
        consumer.openssl_receipt(valid_openssl, recipe['scripts/native-media-hosted/evidence.py'])
        MODULE._openssl_receipt_shape(valid_openssl, recipe['scripts/native-media-hosted/evidence.py'])
        versioned_sdk = deepcopy(valid_openssl)
        versioned_row = versioned_sdk['matrix'][0]
        old_sdk = versioned_row['sdkRoot']
        new_sdk = old_sdk.replace('iPhoneOS.sdk', 'iPhoneOS26.1.sdk')
        versioned_row['sdkRoot'] = new_sdk
        for key in ('CFLAGS', 'CPPFLAGS', 'CXXFLAGS', 'ASMFLAGS', 'LDFLAGS'):
            updated = versioned_row['environment'][key].replace(old_sdk, new_sdk)
            versioned_row['environment'][key] = updated
            if key in ('CFLAGS', 'CPPFLAGS', 'CXXFLAGS', 'LDFLAGS'):
                # configdata.pm serializes each make flag as one complete string,
                # not as a tokenized argv list; keep the synthetic receipt aligned
                # with the SDK-bound environment in this positive case.
                versioned_row['effectiveConfiguration'][key] = [updated]
        consumer.openssl_receipt(versioned_sdk, recipe['scripts/native-media-hosted/evidence.py'])
        MODULE._openssl_receipt_shape(versioned_sdk, recipe['scripts/native-media-hosted/evidence.py'])

        def openssl_flag_mutation(value, key, transform, *, effective_only=False):
            row = value['matrix'][0]
            if effective_only:
                row['effectiveConfiguration'][key] = [transform(row['environment'][key])]
            else:
                row['environment'][key] = transform(row['environment'][key])
                if key in row['effectiveConfiguration']:
                    row['effectiveConfiguration'][key] = [row['environment'][key]]

        # Freshly serialize every mutation and rebuild the enclosing ZIP, rather
        # than breaking a body digest. Except for the explicit config-mismatch
        # cases, environment and configdata flags stay mutually consistent; both
        # readers must reject the compiler policy itself, and the complete Apple
        # package path must reach that same rejection with coherent ZIP hashes.
        optimization_cases = (
            ('missing-C', 'CFLAGS', lambda flags: flags.removesuffix(' -O3'), False),
            ('missing-CXX', 'CXXFLAGS', lambda flags: flags.removesuffix(' -O3'), False),
            ('duplicate-C', 'CFLAGS', lambda flags: flags + ' -O3', False),
            ('duplicate-CXX', 'CXXFLAGS', lambda flags: flags + ' -O3', False),
            ('wrong-O2-C', 'CFLAGS', lambda flags: flags.removesuffix(' -O3') + ' -O2', False),
            ('wrong-O2-CXX', 'CXXFLAGS', lambda flags: flags.removesuffix(' -O3') + ' -O2', False),
            ('nontrailing-C', 'CFLAGS', lambda flags: '-O3 ' + flags.removesuffix(' -O3'), False),
            ('nontrailing-CXX', 'CXXFLAGS', lambda flags: '-O3 ' + flags.removesuffix(' -O3'), False),
            ('CPP-smuggling', 'CPPFLAGS', lambda flags: flags + ' -O3', False),
            ('ASM-smuggling', 'ASMFLAGS', lambda flags: flags + ' -O3', False),
            ('effective-C-mismatch', 'CFLAGS', lambda flags: flags.removesuffix(' -O3'), True),
            ('effective-CXX-mismatch', 'CXXFLAGS', lambda flags: flags.removesuffix(' -O3'), True),
        )
        valid_openssl_body = (json.dumps(valid_openssl, indent=2, sort_keys=True) + '\n').encode()
        for label, key, transform, effective_only in optimization_cases:
            observed = deepcopy(valid_openssl)
            openssl_flag_mutation(observed, key, transform, effective_only=effective_only)
            body = (json.dumps(observed, indent=2, sort_keys=True) + '\n').encode()
            body_sha256 = hashlib.sha256(body).hexdigest()
            self.assertNotEqual(body_sha256, hashlib.sha256(valid_openssl_body).hexdigest(), label)
            rejection = ('OpenSSL effective make flags differ from the fixed environment'
                         if effective_only else
                         'OpenSSL compiler/linker flags differ from the fixed platform policy')
            for reader_name, reader in (('producer', MODULE._openssl_receipt_shape),
                                        ('consumer', consumer.openssl_receipt)):
                with self.subTest(openssl_optimization=label, reader=reader_name):
                    with self.assertRaisesRegex(ValueError, rejection):
                        reader(json.loads(body), recipe['scripts/native-media-hosted/evidence.py'])
            with self.subTest(openssl_optimization=label, reader='apple-package'):
                with candidate_archive(openssl_receipt_override=observed) as fixture, \
                        zipfile.ZipFile(fixture) as archive:
                    self.assertEqual(hashlib.sha256(archive.read('apple-openssl-builds.json')).hexdigest(),
                                     body_sha256)
                    with self.assertRaisesRegex(ValueError, rejection):
                        check_apple(archive)
        for index, sdk_mutation in enumerate((
                lambda row: row.update(sdkRoot=row['sdkRoot'].replace('iPhoneOS.sdk', 'AppleTVOS.sdk')),
                lambda row: row.update(sdkRoot=row['sdkRoot'].replace('iPhoneOS.sdk', 'iPhoneOS26.a.sdk')),
                lambda row: row.update(sdkRoot=row['sdkRoot'].replace('iPhoneOS.sdk', 'iPhoneOS26.1.sdk/../iPhoneOS.sdk')))):
            observed = deepcopy(valid_openssl)
            before_mutation = deepcopy(observed)
            sdk_mutation(observed['matrix'][0])
            with self.subTest(receipt='openssl-sdk', index=index):
                self.assertNotEqual(observed, before_mutation,
                                    'negative OpenSSL SDK mutation is a no-op')
                with self.assertRaises(ValueError):
                    consumer.openssl_receipt(observed, recipe['scripts/native-media-hosted/evidence.py'])
        for index, mutate in enumerate((
                lambda row: row.update(version='3.3.5'),
                lambda row: row.update(sourceSHA='0' * 40),
                lambda row: row.update(validatorSHA256='0' * 64),
                lambda row: row['matrix'].pop(),
                # A valid-looking output digest is bound to raw ZIP bytes by
                # consumer.apple; this offline receipt loop keeps a structural
                # output mutation so it tests only the receipt schema contract.
                lambda row: row['matrix'][0]['outputs'][0].update(name='libcrypto.a'),
                lambda row: row['matrix'][0].update(targetConfigSHA256='0' * 64),
                lambda row: row['matrix'][0].update(targetConfig=row['matrix'][0]['targetConfig'].replace('iOS', 'IOS')),
                lambda row: row['matrix'][0]['configureArguments'].pop(0),
                lambda row: row['matrix'][0]['environment'].update(unexpected='/fixture/forbidden'),
                lambda row: row['matrix'][0].update(sdkRoot=row['matrix'][0]['sdkRoot'].replace('iPhoneOS', 'iPhoneSimulator')),
                lambda row: row['matrix'][0]['environment'].update(CURRENT_ARCH='x86_64'),
                lambda row: row['matrix'][0]['environment'].update(CFLAGS=row['matrix'][0]['environment']['CFLAGS'].replace('15.0', '14.0')),
                lambda row: row['matrix'][0]['environment'].update(ARFLAGS='bad'),
                lambda row: row['matrix'][0]['environment'].update(AR='relative/ar'),
                lambda row: row['matrix'][0]['effectiveConfiguration'].update(ARFLAGS=['bad']),
                lambda row: row['matrix'][0]['effectiveConfiguration'].update(CFLAGS=['forged']),
                lambda row: row['matrix'][0]['effectiveConfiguration'].update(CROSS_COMPILE='host-'))):
            observed = deepcopy(valid_openssl)
            before_mutation = deepcopy(observed)
            mutate(observed)
            with self.subTest(receipt='openssl', index=index):
                self.assertNotEqual(observed, before_mutation,
                                    'negative OpenSSL receipt mutation is a no-op')
                with self.assertRaises(ValueError):
                    consumer.openssl_receipt(observed, recipe['scripts/native-media-hosted/evidence.py'])

    def test_shaderc_sdk_tool_identity_does_not_relax_archive_single_links(self):
        import os
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tool = root / 'sdk-tool'
            tool.write_bytes(b'fixed SDK tool fixture')
            os.link(tool, root / 'second-host-name')
            self.assertEqual(tool.stat().st_nlink, 2)
            expected = hashlib.sha256(tool.read_bytes()).hexdigest()
            self.assertEqual(MODULE._shaderc_tool_sha(tool, 'fixture SDK tool'), expected)
            with self.assertRaises(ValueError):
                MODULE._shaderc_regular(tool, 'archive fixture')
            alias = root / 'symlink-tool'
            alias.symlink_to(tool.name)
            for invalid in (alias, root, Path('relative-tool')):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    MODULE._shaderc_tool_sha(invalid, 'invalid SDK tool')
            empty = root / 'empty-tool'
            empty.write_bytes(b'')
            with self.assertRaises(ValueError):
                MODULE._shaderc_tool_sha(empty, 'empty SDK tool')

    def test_shaderc_sdk_tool_identity_rejects_a_replacement_before_open(self):
        import os
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tool = root / 'sdk-tool'
            tool.write_bytes(b'original SDK tool fixture')
            real_open = os.open

            def replace_then_open(path, flags):
                replacement = root / 'replacement'
                replacement.write_bytes(b'replacement SDK tool fixture')
                os.replace(replacement, tool)
                return real_open(path, flags)

            with patch.object(MODULE.os, 'open', side_effect=replace_then_open):
                with self.assertRaisesRegex(ValueError, 'changed before open'):
                    MODULE._shaderc_tool_sha(tool, 'changing SDK tool')

    def test_shaderc_single_arch_fat_is_thinned_instead_of_copied(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, thin, lipo = root / 'xc', root / 'thin', root / 'lipo'
            authentic_thin = b'!<arch>\nowned thin fixture'
            source.write_bytes(authentic_thin)
            with patch.object(MODULE, 'run') as reader:
                MODULE._shaderc_thin_xc(source, 'arm64', thin, lipo, 1)
                reader.assert_not_called()
            self.assertEqual(thin.read_bytes(), authentic_thin)
            thin.unlink()

            for magic in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                          b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
                with self.subTest(magic=magic.hex()):
                    source.write_bytes(magic + b'container-only bytes' + authentic_thin)

                    def actual_reader_boundary(*argv):
                        self.assertEqual(argv, (str(lipo), str(source), '-thin', 'arm64',
                                                '-output', str(thin)))
                        thin.write_bytes(authentic_thin)
                        return ''

                    with patch.object(MODULE, 'run', side_effect=actual_reader_boundary) as reader:
                        MODULE._shaderc_thin_xc(source, 'arm64', thin, lipo, 1)
                        reader.assert_called_once()
                    self.assertEqual(hashlib.sha256(thin.read_bytes()).hexdigest(),
                                     hashlib.sha256(authentic_thin).hexdigest())
                    self.assertNotEqual(hashlib.sha256(source.read_bytes()).hexdigest(),
                                        hashlib.sha256(authentic_thin).hexdigest())
                    thin.unlink()

            source.write_bytes(authentic_thin)
            with patch.object(MODULE, 'run') as reader:
                with self.assertRaisesRegex(ValueError, 'multi-architecture'):
                    MODULE._shaderc_thin_xc(source, 'arm64', thin, lipo, 2)
                reader.assert_not_called()
            for payload in (b'', b'\xca\xfe', b'not an archive'):
                source.write_bytes(payload)
                with patch.object(MODULE, 'run') as reader:
                    with self.assertRaisesRegex(ValueError, 'not an ar or fat'):
                        MODULE._shaderc_thin_xc(source, 'arm64', thin, lipo, 1)
                    reader.assert_not_called()


    def test_apple_ffmpeg_tls_cannot_autodetect_new_openssl(self):
        carrier = (ROOT / "scripts/mpvkit-dvfel.patch").read_text()
        self.assertIn('arguments += ["--disable-gnutls", "--disable-openssl", "--enable-securetransport"]', carrier)
        gate = (ROOT / "scripts/verify-mpvkit-dvfel-apple-tls.sh").read_text()
        self.assertIn("grep -Eq '^#define CONFIG_OPENSSL 0$'", gate)
        self.assertIn("grep -Eq '^#define CONFIG_GNUTLS 0$'", gate)
        self.assertIn("CONFIG_SECURETRANSPORT", gate)
        self.assertIn("_SSLSetPeerDomainName", gate)
        self.assertIn("_SecTrustEvaluate", gate)

    def test_apple_native_builder_keeps_one_worker(self):
        carrier = (ROOT / "scripts/mpvkit-dvfel.patch").read_text()
        added = "\n".join(line[1:] for line in carrier.splitlines()
                          if line.startswith("+") and not line.startswith("+++"))
        for arguments in ('["compile", "--clean", "-j", "1"]',
                          '["compile", "--verbose", "-j", "1"]',
                          '["install", "--no-rebuild"]',
                          '["configure", "-j1"]',
                          '["-j1"] + wafBuildArg()',
                          '["install", "-j1"] + wafInstallArg()',
                          '["-j1"], currentDirectoryURL: buildURL',
                          '["-j1", "install"]'):
            self.assertIn(arguments, added)
        for key, value in (("MAKEFLAGS", "-j1"),
                           ("CMAKE_BUILD_PARALLEL_LEVEL", "1"),
                           ("CARGO_BUILD_JOBS", "1")):
            self.assertIn('"' + key + '": "' + value + '"', added)
        self.assertNotIn('"-j8"', added)
        entry = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
        self.assertEqual(entry.count("swift run --jobs 1 --build-path"), 1)

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
        reader = out / 'ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf'
        reader.parent.mkdir(parents=True)
        reader.write_bytes(b'synthetic reader identity only; subprocess is mocked')
        required = {"libmpv.so", "libplayer.so", "libc++_shared.so", "libavcodec.so", "libavformat.so",
                    "libavutil.so", "libavfilter.so", "libavdevice.so", "libswresample.so", "libswscale.so"}
        with zipfile.ZipFile(out / "libmpv-release-candidate.aar", "w") as archive:
            for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
                for name in sorted(required):
                    entry = f"jni/{abi}/{name}"
                    if entry == missing:
                        continue
                    data = b"fixture:" + abi.encode() + b"/" + name.encode() + b"\0"
                    if name == "libavformat.so":
                        data += b"--enable-mbedtls --enable-gpl --enable-version3\0"
                        data += keys[:-1] if bad_tls else keys
                    archive.writestr(entry, data)
            if bad_abi:
                archive.writestr("jni/mips/libmpv.so", b"unadmitted")

    @staticmethod
    def readelf(*args):
        if '--version' in args:
            return 'LLVM synthetic inspection fixture'
        data = Path(args[-1]).read_bytes()
        if '--dyn-syms' in args:
            return SentRequestABISynthetic.dynsym(
                'defined-provider' if b'libavformat.so' in data else 'undefined-import',
                functions=MODULE.SENT_FFMPEG_FUNCTIONS + MODULE.REFERENCE_FFMPEG_FUNCTIONS)
        if '--symbols' in args:
            return SentRequestABISynthetic.symtab()
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

    def test_android_producer_rejects_missing_finite_reader_provider_or_import(self):
        # Retain the original finite negative as well as the sparse provider/import seam.
        for symbol in ('avpriv_vortx_reference_recipe_release_v1',
                       'avpriv_vortx_reference_sparse_budget_release_v1'):
            self.assertIn(symbol, MODULE.REFERENCE_FFMPEG_FUNCTIONS)
            for library in (b'libavformat.so', b'libmpv.so'):
                def missing(*args):
                    result = self.readelf(*args)
                    if '--dyn-syms' in args and library in Path(args[-1]).read_bytes():
                        return result.replace(symbol + '@', symbol + '_missing@')
                    return result
                with self.subTest(library=library, symbol=symbol), patch.object(MODULE, 'run', side_effect=missing), self.assertRaises(ValueError):
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
            if any(flag in args for flag in ('-h', '--version', '--dyn-syms', '--symbols')):
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
            if any(flag in args for flag in ('-h', '--version', '--dyn-syms', '--symbols')):
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


class SentRequestABISynthetic(unittest.TestCase):
    @staticmethod
    def dynsym(role, *, change=None, duplicate=False, missing=False, functions=None):
        rows = ['0: 0000000000000000 0 NOTYPE LOCAL DEFAULT UND']
        functions = MODULE.SENT_FFMPEG_FUNCTIONS if functions is None else functions
        names = functions[:1] if missing else functions
        for index, name in enumerate(names, 1):
            section = '12' if role == 'defined-provider' else 'UND'
            suffix = '@@LIBAVFORMAT_63' if role == 'defined-provider' else '@LIBAVFORMAT_63 (2)'
            row = f'{index}: 0000000000000000 16 FUNC GLOBAL DEFAULT {section} {name}{suffix}'
            rows.append(change(row) if change and index == 1 else row)
        if duplicate:
            rows.append(f'{len(rows)}: 0000000000000000 16 FUNC GLOBAL DEFAULT 12 '
                        f'{functions[0]}@OTHER_VERSION')
        return f"Symbol table '.dynsym' contains {len(rows)} entries:\n" + '\n'.join(rows) + '\n'

    @staticmethod
    def nm_text(names, kind='T'):
        return 'archive.a(object.o):\n' + ''.join(
            f'0000000000000000 {kind} _{name}\n' if kind != 'U' else f'                 U _{name}\n'
            for name in names)

    @staticmethod
    def symtab(binding='LOCAL', visibility='DEFAULT', *, change=None, missing=False):
        rows = ['0: 0000000000000000 0 NOTYPE LOCAL DEFAULT UND']
        if not missing:
            row = ('1: 0000000000000010 16 FUNC ' + binding + ' ' + visibility +
                   ' 12 ' + MODULE.PRIVATE_MPV_FUNCTIONS[0])
            rows.append(change(row) if change else row)
        return f"Symbol table '.symtab' contains {len(rows)} entries:\n" + '\n'.join(rows) + '\n'

    def test_exact_elf_provider_and_import_roles_and_version_normalization(self):
        for role in ('defined-provider', 'undefined-import'):
            rows = MODULE.required_elf_functions(self.dynsym(role), MODULE.SENT_FFMPEG_FUNCTIONS, role)
            self.assertEqual({row['name'] for row in rows}, set(MODULE.SENT_FFMPEG_FUNCTIONS))
            self.assertTrue(all(row['version'] == 'LIBAVFORMAT_63' for row in rows))
            self.assertTrue(all(row['type'] == 'FUNC' and row['binding'] == 'GLOBAL' and
                                row['visibility'] == 'DEFAULT' for row in rows))
            self.assertEqual({row['section'] for row in rows}, {'12'} if role == 'defined-provider' else {'UND'})
        self.assertEqual(MODULE.required_macho_functions(self.nm_text(MODULE.SENT_MPV_FUNCTIONS),
            MODULE.SENT_MPV_FUNCTIONS, 'defined-code'), sorted(MODULE.SENT_MPV_FUNCTIONS))

    def test_required_elf_and_macho_adversaries_are_not_plain_name_matches(self):
        bad = [self.dynsym('defined-provider', missing=True), self.dynsym('defined-provider', duplicate=True)]
        for old, new in [('FUNC', 'OBJECT'), ('GLOBAL', 'WEAK'), ('DEFAULT', 'HIDDEN'),
                         (' 12 ', ' UND '), ('@@LIBAVFORMAT_63', '@'),
                         ('@@LIBAVFORMAT_63', '@' + 'A' * 129)]:
            bad.append(self.dynsym('defined-provider', change=lambda row, old=old, new=new: row.replace(old, new)))
        bad.append(self.dynsym('defined-provider').replace("'.dynsym'", "'.symtab'"))
        for text in bad:
            with self.subTest(text=text), self.assertRaises(ValueError):
                MODULE.required_elf_functions(text, MODULE.SENT_FFMPEG_FUNCTIONS, 'defined-provider')
        with self.assertRaises(ValueError):
            MODULE.required_elf_functions(self.dynsym('defined-provider'), MODULE.SENT_FFMPEG_FUNCTIONS, 'undefined-import')
        for text in (self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS, 'D'),
                     self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS, 'W'),
                     self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS, 'U'),
                     self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS) + self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS[:1]),
                     self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS).replace('_avpriv_', '__avpriv_', 1)):
            with self.subTest(text=text), self.assertRaises(ValueError):
                MODULE.required_macho_functions(text, MODULE.SENT_FFMPEG_FUNCTIONS, 'defined-code')

    def test_finite_reader_elf_and_macho_require_every_function_and_correct_role(self):
        functions = MODULE.REFERENCE_FFMPEG_FUNCTIONS
        self.assertEqual(functions, (
            'avpriv_vortx_reference_capture_v1', 'avpriv_vortx_reference_revalidate_v1',
            'avpriv_vortx_reference_recipe_current', 'avpriv_vortx_reference_open_prefix_v1',
            'avpriv_vortx_reference_read_v1', 'avpriv_vortx_reference_stats_v1',
            'avpriv_vortx_reference_reader_close_v1', 'avpriv_vortx_reference_recipe_release_v1',
            'avpriv_vortx_reference_sparse_budget_create_v1',
            'avpriv_vortx_reference_sparse_budget_info_v1',
            'avpriv_vortx_reference_sparse_open_v1',
            'avpriv_vortx_reference_sparse_next_part_v1',
            'avpriv_vortx_reference_sparse_read_part_v1',
            'avpriv_vortx_reference_sparse_stats_v1',
            'avpriv_vortx_reference_sparse_close_v1',
            'avpriv_vortx_reference_sparse_budget_release_v1'))
        for role, kind in (('defined-provider', 'T'), ('undefined-import', 'U')):
            dynamic = self.dynsym(role, functions=functions)
            rows = MODULE.required_elf_functions(dynamic, functions, role)
            self.assertEqual([row['name'] for row in rows], sorted(functions))
            macho_role = 'defined-code' if role == 'defined-provider' else 'undefined-import'
            self.assertEqual(MODULE.required_macho_functions(self.nm_text(functions, kind),
                                                           functions, macho_role), sorted(functions))
            opposite_role = 'undefined-import' if role == 'defined-provider' else 'defined-provider'
            with self.assertRaises(ValueError):
                MODULE.required_elf_functions(dynamic, functions, opposite_role)
            for missing in functions:
                remaining = tuple(name for name in functions if name != missing)
                with self.subTest(role=role, missing=missing), self.assertRaises(ValueError):
                    MODULE.required_elf_functions(self.dynsym(role, functions=remaining), functions, role)
                with self.subTest(role=role, missing=missing), self.assertRaises(ValueError):
                    MODULE.required_macho_functions(self.nm_text(remaining, kind), functions, macho_role)
        for old, new in ((' FUNC ', ' OBJECT '), (' GLOBAL ', ' WEAK '),
                         (' DEFAULT ', ' HIDDEN '), (' 12 ', ' UND ')):
            text = self.dynsym('defined-provider', functions=functions,
                               change=lambda row, old=old, new=new: row.replace(old, new))
            with self.subTest(change=(old, new)), self.assertRaises(ValueError):
                MODULE.required_elf_functions(text, functions, 'defined-provider')

    def test_sparse_functions_reject_wrong_elf_and_macho_symbol_roles(self):
        functions = MODULE.REFERENCE_FFMPEG_FUNCTIONS
        sparse = tuple(name for name in functions if name.startswith('avpriv_vortx_reference_sparse_'))
        self.assertEqual(len(sparse), 8)
        for role, kind in (('defined-provider', 'T'), ('undefined-import', 'U')):
            macho_role = 'defined-code' if role == 'defined-provider' else 'undefined-import'
            wrong_section = (' 12 ', ' UND ') if role == 'defined-provider' else (' UND ', ' 12 ')
            for symbol in sparse:
                ordered = (symbol,) + tuple(name for name in functions if name != symbol)
                for old, new in ((' FUNC ', ' OBJECT '), (' GLOBAL ', ' WEAK '),
                                 (' DEFAULT ', ' HIDDEN '), wrong_section):
                    dynamic = self.dynsym(role, functions=ordered,
                        change=lambda row, old=old, new=new: row.replace(old, new))
                    with self.subTest(role=role, symbol=symbol, mutation=(old, new)), self.assertRaises(ValueError):
                        MODULE.required_elf_functions(dynamic, functions, role)
                with self.subTest(role=role, duplicate=symbol), self.assertRaises(ValueError):
                    MODULE.required_elf_functions(self.dynsym(role, functions=ordered, duplicate=True),
                                                  functions, role)
                remaining = tuple(name for name in functions if name != symbol)
                for wrong_kind in (('U', 'D', 'W') if kind == 'T' else ('T', 'D', 'W')):
                    observed = self.nm_text(remaining, kind) + self.nm_text((symbol,), wrong_kind)
                    with self.subTest(role=role, symbol=symbol, kind=wrong_kind), self.assertRaises(ValueError):
                        MODULE.required_macho_functions(observed, functions, macho_role)

    def test_apple_material_abi_rejects_old_component_missing_private_helper(self):
        required = MODULE.SENT_MPV_FUNCTIONS
        symbol = "stream_reference_source_prepare_prefix_request"
        self.assertIn(symbol, required)
        old = tuple(name for name in required if name != symbol)
        with self.assertRaisesRegex(ValueError, "missing required"):
            MODULE.required_macho_functions(self.nm_text(old), required, 'defined-code')
        for kind in ('U', 'D', 'W'):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                MODULE.required_macho_functions(self.nm_text(old) + self.nm_text((symbol,), kind),
                                                required, 'defined-code')

    def test_private_transport_code_requires_complete_nonexported_symtab(self):
        for binding, visibility in (('LOCAL', 'DEFAULT'), ('LOCAL', 'HIDDEN'), ('GLOBAL', 'HIDDEN')):
            text = self.symtab(binding, visibility)
            for observed in (text, self.dynsym('undefined-import') + text):
                with self.subTest(binding=binding, visibility=visibility):
                    rows = MODULE.required_private_elf_functions(observed, MODULE.PRIVATE_MPV_FUNCTIONS)
                    self.assertEqual(rows, [{'name': MODULE.PRIVATE_MPV_FUNCTIONS[0], 'size': 16,
                                            'type': 'FUNC', 'binding': binding, 'visibility': visibility,
                                            'section': '12'}])
        valid = self.symtab()
        bad = [self.symtab(missing=True), valid + valid,
               valid.replace("'.symtab'", "'.unknown'"),
               valid.replace('contains 2 entries:', 'contains two entries:'),
               valid.replace('1: 0000000000000010', '2: 0000000000000010'),
               valid.replace('contains 2 entries:', 'contains 3 entries:') + valid.splitlines()[-1] + '\n']
        for old, new in ((' 16 FUNC ', ' 0 FUNC '), (' FUNC ', ' OBJECT '),
                         (' LOCAL ', ' WEAK '), (' 12 ', ' UND '), (' 12 ', ' ABS '),
                         (' LOCAL DEFAULT 12 ', ' GLOBAL DEFAULT 12 ')):
            bad.append(self.symtab(change=lambda row, old=old, new=new: row.replace(old, new)))
        for observed in bad:
            with self.subTest(text=observed), self.assertRaises(ValueError):
                MODULE.required_private_elf_functions(observed, MODULE.PRIVATE_MPV_FUNCTIONS)

    def test_dynamic_private_export_or_retired_provider_cannot_satisfy_v2(self):
        self.assertEqual(MODULE.SENT_FFMPEG_FUNCTIONS,
                         ('avpriv_vortx_http_copy_sent_request_v2',
                          'avpriv_vortx_http_sent_request_clear_v2'))
        for forbidden in MODULE.RETIRED_SENT_FFMPEG_FUNCTIONS + MODULE.PRIVATE_MPV_FUNCTIONS:
            dynamic = self.dynsym('undefined-import').replace('contains 3 entries:', 'contains 4 entries:')
            dynamic += f'3: 0000000000000010 16 FUNC GLOBAL DEFAULT 12 {forbidden}\n'
            with self.subTest(name=forbidden), self.assertRaises(ValueError):
                MODULE.required_elf_functions(dynamic, MODULE.SENT_FFMPEG_FUNCTIONS, 'undefined-import',
                                              MODULE.RETIRED_SENT_FFMPEG_FUNCTIONS + MODULE.PRIVATE_MPV_FUNCTIONS)
        for retired in MODULE.RETIRED_SENT_FFMPEG_FUNCTIONS:
            with self.assertRaises(ValueError):
                MODULE.required_macho_functions(self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS) +
                                                self.nm_text((retired,)), MODULE.SENT_FFMPEG_FUNCTIONS,
                                                'defined-code', MODULE.RETIRED_SENT_FFMPEG_FUNCTIONS)

    def test_real_android_producer_records_default_reader_and_six_symbol_roles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reader = root / 'ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf'
            reader.parent.mkdir(parents=True)
            reader.write_bytes(b'synthetic reader identity only; subprocess is mocked')
            keys = [bytes([index]) * 32 for index in range(1, 9)]
            (root / 'tls_mbedtls_vortx_distrust.h').write_text('\n'.join(
                '{' + ','.join(f'0x{value:02x}' for value in key) + '}, /* EM fixture */' for key in keys))
            libraries = ('libmpv.so', 'libplayer.so', 'libc++_shared.so', 'libavcodec.so', 'libavformat.so',
                         'libavutil.so', 'libavfilter.so', 'libavdevice.so', 'libswresample.so', 'libswscale.so')
            with zipfile.ZipFile(root / 'libmpv-release-candidate.aar', 'w') as archive:
                for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
                    for library in libraries:
                        data = f'{abi}/{library}\0'.encode()
                        if library == 'libavformat.so':
                            data += b'--enable-mbedtls --enable-gpl --enable-version3\0' + b''.join(keys)
                        archive.writestr(f'jni/{abi}/{library}', data)
            def readelf(*args):
                if '--version' in args:
                    return 'LLVM synthetic ABI fixture\n'
                data = Path(args[-1]).read_bytes()
                if '--dyn-syms' in args:
                    self.assertIn('--wide', args)
                    return self.dynsym('defined-provider' if b'libavformat.so' in data else 'undefined-import',
                                       functions=MODULE.SENT_FFMPEG_FUNCTIONS + MODULE.REFERENCE_FFMPEG_FUNCTIONS)
                if '--symbols' in args:
                    self.assertIn('--wide', args)
                    self.assertIn(b'libmpv.so', data)
                    binding, visibility = ('LOCAL', 'DEFAULT') if b'armeabi-v7a' in data else (
                        ('LOCAL', 'HIDDEN') if b'arm64-v8a' in data else ('GLOBAL', 'HIDDEN'))
                    return self.symtab(binding, visibility)
                if '-h' in args:
                    elf, machine = ('ELF32', 'ARM') if b'armeabi-v7a' in data else (
                        ('ELF64', 'AArch64') if b'arm64-v8a' in data else ('ELF64', 'Advanced Micro Devices X86-64'))
                    return f'Class: {elf}\nMachine: {machine}\nType: DYN\nData: little endian\n'
                return ('LOAD 0x0000 0x0000 0x0000 0x1000 0x1000 R E 0x4000\n'
                        'GNU_RELRO 0x4000 0x4000 0x4000 0x4000 0x4000 R 0x1\n')
            with patch.object(MODULE, 'run', side_effect=readelf) as calls:
                MODULE.android(root, root, root)
            evidence = json.loads((root / 'android-artifact-evidence.json').read_text())
            abi = evidence['sentRequestABI']
            self.assertEqual(abi['schema'], 2)
            self.assertIs(abi['retiredV1Absent'], True)
            self.assertEqual(len(abi['libraries']), 6)
            self.assertEqual({row['role'] for row in abi['libraries']}, {'defined-provider', 'undefined-import'})
            self.assertEqual(abi['reader']['requestedReader'], str(reader))
            self.assertEqual(abi['reader']['resolvedReader'], str(reader.resolve()))
            self.assertEqual(abi['reader']['readerSHA256'], hashlib.sha256(reader.read_bytes()).hexdigest())
            self.assertEqual(abi['reader']['validatorSHA256'], hashlib.sha256(Path(MODULE.__file__).read_bytes()).hexdigest())
            self.assertEqual(abi['reader']['mode'], 'hosted-ndk-reader')
            self.assertEqual(len([c for c in calls.call_args_list if '--dyn-syms' in c.args]), 6)
            self.assertEqual(len([c for c in calls.call_args_list if '--symbols' in c.args]), 3)
            private = evidence['privateOwnerABI']
            self.assertEqual(private['schema'], 1)
            self.assertEqual(private['reader'], abi['reader'])
            self.assertEqual(len(private['libraries']), 3)
            self.assertEqual({row['abi'] for row in private['libraries']}, {'armeabi-v7a', 'arm64-v8a', 'x86_64'})
            reference = evidence['referenceReaderABI']
            self.assertEqual(reference['schema'], 1)
            self.assertEqual(reference['reader'], abi['reader'])
            self.assertEqual(len(reference['libraries']), 6)
            self.assertEqual({(row['abi'], row['library'], row['role']) for row in reference['libraries']},
                             {(native_abi, library, role) for native_abi in ('armeabi-v7a', 'arm64-v8a', 'x86_64')
                              for library, role in (('libavformat.so', 'defined-provider'),
                                                    ('libmpv.so', 'undefined-import'))})
            with zipfile.ZipFile(root / 'libmpv-release-candidate.aar') as archive:
                for row in reference['libraries']:
                    dynamic = self.dynsym(row['role'], functions=(MODULE.SENT_FFMPEG_FUNCTIONS +
                                                                 MODULE.REFERENCE_FFMPEG_FUNCTIONS))
                    self.assertEqual(row['binarySHA256'], hashlib.sha256(
                        archive.read('jni/' + row['abi'] + '/' + row['library'])).hexdigest())
                    self.assertEqual(row['dynsymTextSHA256'], hashlib.sha256(dynamic.encode()).hexdigest())
                    self.assertEqual(row['symbols'], MODULE.required_elf_functions(
                        dynamic, MODULE.REFERENCE_FFMPEG_FUNCTIONS, row['role']))
                for row in private['libraries']:
                    self.assertEqual(row['library'], 'libmpv.so')
                    self.assertEqual(row['binarySHA256'], hashlib.sha256(
                        archive.read('jni/' + row['abi'] + '/libmpv.so')).hexdigest())
                    binding, visibility = ('LOCAL', 'DEFAULT') if row['abi'] == 'armeabi-v7a' else (
                        ('LOCAL', 'HIDDEN') if row['abi'] == 'arm64-v8a' else ('GLOBAL', 'HIDDEN'))
                    text = self.symtab(binding, visibility)
                    self.assertEqual(row['symtabTextSHA256'], hashlib.sha256(text.encode()).hexdigest())
                    self.assertEqual(row['symbols'], MODULE.required_private_elf_functions(
                        text, MODULE.PRIVATE_MPV_FUNCTIONS))
            self.assertNotIn('inspection', evidence)
            self.assertFalse(evidence['promotionEligible'])
            self.assertFalse(evidence['runtimeSecurityTested'])
            for row in abi['libraries']:
                self.assertEqual(len(row['binarySHA256']), 64)
                self.assertEqual(len(row['dynsymTextSHA256']), 64)

    def test_apple_complete_nine_arch_gate_and_fixed_marker_with_cleanup(self):
        slices = {'ios-arm64': ('arm64',), 'ios-arm64_x86_64-simulator': ('arm64', 'x86_64'),
                  'tvos-arm64_arm64e': ('arm64', 'arm64e'),
                  'tvos-arm64_x86_64-simulator': ('arm64', 'x86_64'),
                  'macos-arm64_x86_64': ('arm64', 'x86_64')}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'package'
            for library in ('Libavformat', 'Libmpv'):
                for slice_name in slices:
                    binary = package / 'artifacts' / (library + '-GPL.xcframework') / slice_name / (library + '.framework') / library
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(f'{library}|{slice_name}'.encode())
            def inspect(*args):
                if '-archs' in args:
                    slice_name = Path(args[-1]).read_text().split('|')[1]
                    return ' '.join(reversed(slices[slice_name])) + '\n'
                if '-thin' in args:
                    Path(args[-1]).write_bytes(Path(args[2]).read_bytes())
                    return ''
                library = Path(args[-1]).read_text().split('|')[0]
                if '-gu' in args:
                    return self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS + MODULE.REFERENCE_FFMPEG_FUNCTIONS, 'U')
                return self.nm_text(MODULE.SENT_FFMPEG_FUNCTIONS + MODULE.REFERENCE_FFMPEG_FUNCTIONS
                                    if library == 'Libavformat' else MODULE.SENT_MPV_FUNCTIONS)
            output = io.StringIO()
            with patch.object(MODULE, 'run', side_effect=inspect) as calls, redirect_stdout(output):
                MODULE.apple_sent_abi(package)
            self.assertEqual(output.getvalue(), 'PASS apple-sent-abi\nPASS apple-reference-abi\n')
            self.assertEqual(len([c for c in calls.call_args_list if '-gU' in c.args]), 18)
            self.assertEqual(len([c for c in calls.call_args_list if '-gu' in c.args]), 9)
            self.assertEqual(sorted(path.name for path in root.iterdir()), ['package'])
            def wrong_archs(*args):
                return 'arm64 x86_64 arm64e\n' if '-archs' in args else inspect(*args)
            with patch.object(MODULE, 'run', side_effect=wrong_archs), self.assertRaises(ValueError):
                MODULE.apple_sent_abi(package)
            self.assertEqual(sorted(path.name for path in root.iterdir()), ['package'])


class SentRequestOfflineEvidence(unittest.TestCase):
    @staticmethod
    def fixture():
        spec = importlib.util.spec_from_file_location(
            "sent_request_offline_consumer", ROOT / "scripts/package-native-current-component.py")
        consumer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(consumer)
        validator = hashlib.sha256(Path(MODULE.__file__).read_bytes()).hexdigest()
        value = {"schema": 2, "retiredV1Absent": True,
                 "reader": {"mode": "hosted-ndk-reader", "requestedReader": "/sdk/llvm-readelf",
                 "resolvedReader": "/sdk/llvm-readobj", "readerSHA256": "a" * 64,
                 "readerVersion": "synthetic LLVM", "validatorSHA256": validator}, "libraries": []}
        records = {}
        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            for library, role in (("libavformat.so", "defined-provider"), ("libmpv.so", "undefined-import")):
                checksum = hashlib.sha256((abi + library).encode()).hexdigest()
                records["jni/" + abi + "/" + library] = {"sha256": checksum}
                value["libraries"].append({"abi": abi, "library": library, "role": role,
                    "binarySHA256": checksum, "dynsymTextSHA256": "b" * 64,
                    "symbols": MODULE.required_elf_functions(SentRequestABISynthetic.dynsym(role),
                                                              MODULE.SENT_FFMPEG_FUNCTIONS, role)})
        return consumer, value, records, validator

    def test_six_roles_are_bound_to_verified_jni_and_validator_source(self):
        consumer, value, records, validator = self.fixture()
        consumer.sent_request_abi(value, records, validator)
        explicit = deepcopy(value)
        explicit["reader"]["mode"] = "explicit-read-only-inspector"
        consumer.sent_request_abi(explicit, records, validator)
        self.assertIn('"PASS apple-sent-abi" in gate.splitlines()',
                      (ROOT / "scripts/package-native-current-component.py").read_text())

    def test_stale_or_forged_normalized_evidence_is_rejected(self):
        consumer, original, records, validator = self.fixture()
        for change in (lambda value: value.update(schema=1),
                       lambda value: value.update(retiredV1Absent=False),
                       lambda value: value["libraries"].pop(),
                       lambda value: value["libraries"].append(deepcopy(value["libraries"][0])),
                       lambda value: value["libraries"][0].update(role="undefined-import"),
                       lambda value: value["libraries"][0].update(binarySHA256="c" * 64),
                       lambda value: value["reader"].update(validatorSHA256="c" * 64),
                       lambda value: value["reader"].update(mode="unknown"),
                       lambda value: value["reader"].update(requestedReader="relative-reader"),
                       lambda value: value["libraries"][0]["symbols"][0].update(type="OBJECT"),
                       lambda value: value["libraries"][0]["symbols"][0].update(binding="WEAK"),
                       lambda value: value["libraries"][0]["symbols"][0].update(visibility="HIDDEN"),
                       lambda value: value["libraries"][0]["symbols"][0].update(section="UND"),
                       lambda value: value["libraries"][1]["symbols"][0].update(section="12"),
                       lambda value: value["libraries"][0]["symbols"][0].update(version="bad@version"),
                       lambda value: value["libraries"][0]["symbols"][0].update(
                           name="avpriv_vortx_http_copy_sent_request"),
                       lambda value: value.update(ignoredUnknownField=True)):
            value = deepcopy(original)
            change(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                consumer.sent_request_abi(value, records, validator)
        with self.assertRaises(ValueError):
            consumer.sent_request_abi({}, records, validator)

    @staticmethod
    def reference_fixture():
        consumer, sent, records, validator = SentRequestOfflineEvidence.fixture()
        value = {'schema': 1, 'reader': deepcopy(sent['reader']), 'libraries': []}
        for row in sent['libraries']:
            reference = deepcopy(row)
            reference['symbols'] = MODULE.required_elf_functions(
                SentRequestABISynthetic.dynsym(row['role'], functions=MODULE.REFERENCE_FFMPEG_FUNCTIONS),
                MODULE.REFERENCE_FFMPEG_FUNCTIONS, row['role'])
            value['libraries'].append(reference)
        return consumer, value, sent, records, validator

    def test_reference_reader_evidence_binds_all_eight_functions_and_same_inspector(self):
        consumer, value, sent, records, validator = self.reference_fixture()
        consumer.sent_request_abi(sent, records, validator)
        consumer.reference_reader_abi(value, records, validator, sent['reader'])
        self.assertEqual(set(consumer.REFERENCE_FFMPEG_FUNCTIONS), set(MODULE.REFERENCE_FFMPEG_FUNCTIONS))
        self.assertEqual(len(value['libraries']), 6)
        self.assertTrue(all(len(row['symbols']) == 16 for row in value['libraries']))
        explicit = deepcopy(value)
        expected_reader = deepcopy(sent['reader'])
        expected_reader['mode'] = 'explicit-read-only-inspector'
        explicit['reader'] = deepcopy(expected_reader)
        consumer.reference_reader_abi(explicit, records, validator, expected_reader)
        self.assertIn('"PASS apple-reference-abi" in gate.splitlines()',
                      (ROOT / 'scripts/package-native-current-component.py').read_text())

    def test_reference_reader_evidence_rejects_missing_functions_wrong_roles_and_bytes(self):
        consumer, original, sent, records, validator = self.reference_fixture()
        for index, row in enumerate(original['libraries']):
            for symbol_index, symbol in enumerate(row['symbols']):
                value = deepcopy(original)
                value['libraries'][index]['symbols'].pop(symbol_index)
                with self.subTest(abi=row['abi'], library=row['library'], missing=symbol['name']), self.assertRaises(ValueError):
                    consumer.reference_reader_abi(value, records, validator, sent['reader'])
        for change in (lambda value: value.update(schema=2),
                       lambda value: value.update(schema=True),
                       lambda value: value['libraries'].pop(),
                       lambda value: value['libraries'].append(deepcopy(value['libraries'][0])),
                       lambda value: value['libraries'][0].update(role='undefined-import'),
                       lambda value: value['libraries'][1].update(role='defined-provider'),
                       lambda value: value['libraries'][0].update(binarySHA256='c' * 64),
                       lambda value: value['libraries'][0].update(dynsymTextSHA256='not-a-digest'),
                       lambda value: value['libraries'][0]['symbols'][0].update(type='OBJECT'),
                       lambda value: value['libraries'][0]['symbols'][0].update(binding='WEAK'),
                       lambda value: value['libraries'][0]['symbols'][0].update(visibility='HIDDEN'),
                       lambda value: value['libraries'][0]['symbols'][0].update(section='UND'),
                       lambda value: value['libraries'][1]['symbols'][0].update(section='12'),
                       lambda value: value['libraries'][0]['symbols'][0].update(
                           name='avpriv_vortx_http_copy_sent_request_v2'),
                       lambda value: value['libraries'][0]['symbols'].append(
                           deepcopy(value['libraries'][0]['symbols'][0])),
                       lambda value: value.update(unrecognized=True)):
            value = deepcopy(original)
            change(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                consumer.reference_reader_abi(value, records, validator, sent['reader'])
        with self.assertRaises(ValueError):
            consumer.reference_reader_abi({}, records, validator, sent['reader'])
        missing_record = dict(records)
        del missing_record['jni/arm64-v8a/libavformat.so']
        with self.assertRaises(ValueError):
            consumer.reference_reader_abi(original, missing_record, validator, sent['reader'])

    def test_sparse_evidence_rejects_finite_only_or_wrong_sparse_symbol_roles(self):
        consumer, original, sent, records, validator = self.reference_fixture()
        sparse = set(name for name in MODULE.REFERENCE_FFMPEG_FUNCTIONS
                     if name.startswith('avpriv_vortx_reference_sparse_'))
        self.assertEqual(len(sparse), 8)
        for index, row in enumerate(original['libraries']):
            finite_only = deepcopy(original)
            finite_only['libraries'][index]['symbols'] = [
                item for item in row['symbols'] if item['name'] not in sparse]
            self.assertEqual(len(finite_only['libraries'][index]['symbols']), 8)
            with self.subTest(abi=row['abi'], library=row['library'], finite_only=True), self.assertRaises(ValueError):
                consumer.reference_reader_abi(finite_only, records, validator, sent['reader'])
            for symbol_index, symbol in enumerate(row['symbols']):
                if symbol['name'] not in sparse:
                    continue
                value = deepcopy(original)
                value['libraries'][index]['symbols'][symbol_index]['section'] = (
                    'UND' if row['role'] == 'defined-provider' else '12')
                with self.subTest(abi=row['abi'], library=row['library'], wrong_role=symbol['name']), self.assertRaises(ValueError):
                    consumer.reference_reader_abi(value, records, validator, sent['reader'])

    def test_reference_reader_evidence_rejects_distinct_valid_inspector_identity(self):
        consumer, original, sent, records, validator = self.reference_fixture()
        # Each altered reader remains individually well formed and validator-bound;
        # rejection must come from equality with the original sent-request reader.
        for field, replacement in (('mode', 'explicit-read-only-inspector'),
                                   ('requestedReader', '/another/llvm-readelf'),
                                   ('resolvedReader', '/another/llvm-readobj'),
                                   ('readerSHA256', 'd' * 64),
                                   ('readerVersion', 'another synthetic LLVM')):
            value = deepcopy(original)
            value['reader'][field] = replacement
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'inspector identity'):
                consumer.reference_reader_abi(value, records, validator, sent['reader'])
        forged_validator = deepcopy(original)
        forged_validator['reader']['validatorSHA256'] = 'd' * 64
        with self.assertRaises(ValueError):
            consumer.reference_reader_abi(forged_validator, records, validator, sent['reader'])

    @staticmethod
    def private_fixture():
        consumer, sent, records, validator = SentRequestOfflineEvidence.fixture()
        private = {"schema": 1, "reader": deepcopy(sent["reader"]), "libraries": []}
        for abi, binding, visibility in (("armeabi-v7a", "LOCAL", "DEFAULT"),
                                         ("arm64-v8a", "LOCAL", "HIDDEN"),
                                         ("x86_64", "GLOBAL", "HIDDEN")):
            private["libraries"].append({"abi": abi, "library": "libmpv.so",
                "binarySHA256": records["jni/" + abi + "/libmpv.so"]["sha256"],
                "symtabTextSHA256": "c" * 64,
                "symbols": MODULE.required_private_elf_functions(
                    SentRequestABISynthetic.symtab(binding, visibility), MODULE.PRIVATE_MPV_FUNCTIONS)})
        return consumer, private, sent, records, validator

    def test_private_code_evidence_is_bound_to_same_reader_and_three_packaged_libraries(self):
        consumer, private, sent, records, validator = self.private_fixture()
        consumer.sent_request_abi(sent, records, validator)
        consumer.private_owner_abi(private, records, sent["reader"])
        explicit = deepcopy(sent["reader"])
        explicit["mode"] = "explicit-read-only-inspector"
        private["reader"] = deepcopy(explicit)
        consumer.private_owner_abi(private, records, explicit)

    def test_private_code_evidence_rejects_stale_reader_bytes_and_noncode_rows(self):
        consumer, original, sent, records, _ = self.private_fixture()
        for change in (lambda value: value.update(schema=2),
                       lambda value: value.update(schema=True),
                       lambda value: value["libraries"].pop(),
                       lambda value: value["libraries"].append(deepcopy(value["libraries"][0])),
                       lambda value: value["libraries"][0].update(abi="mips"),
                       lambda value: value["libraries"][0].update(library="libavformat.so"),
                       lambda value: value["reader"].update(readerSHA256="d" * 64),
                       lambda value: value["libraries"][0].update(binarySHA256="d" * 64),
                       lambda value: value["libraries"][0].update(symtabTextSHA256="not-a-digest"),
                       lambda value: value["libraries"][0]["symbols"].clear(),
                       lambda value: value["libraries"][0]["symbols"].append(
                           deepcopy(value["libraries"][0]["symbols"][0])),
                       lambda value: value["libraries"][0]["symbols"][0].update(name="other_helper"),
                       lambda value: value["libraries"][0]["symbols"][0].update(size=0),
                       lambda value: value["libraries"][0]["symbols"][0].update(size=True),
                       lambda value: value["libraries"][0]["symbols"][0].update(type="OBJECT"),
                       lambda value: value["libraries"][0]["symbols"][0].update(binding="WEAK"),
                       lambda value: value["libraries"][0]["symbols"][0].update(binding="GLOBAL"),
                       lambda value: value["libraries"][0]["symbols"][0].update(section="UND"),
                       lambda value: value["libraries"][0]["symbols"][0].update(section="ABS"),
                       lambda value: value["libraries"][0]["symbols"][0].update(section="0"),
                       lambda value: value.update(unrecognized=True)):
            value = deepcopy(original)
            change(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                consumer.private_owner_abi(value, records, sent["reader"])
        with self.assertRaises(ValueError):
            consumer.private_owner_abi({}, records, sent["reader"])


if __name__ == "__main__":
    unittest.main()
