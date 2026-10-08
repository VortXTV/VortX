#!/usr/bin/env python3
"""Silent fault injection into pinned, real mpv CoreAudio lifecycle functions.

Only three SHA-verified public source files are downloaded (once, into app/build).
No app, media, audio framework, HAL device, provider or private engine is opened.
CoreAudio entry points are fake implementations; lifecycle bodies are extracted
unchanged from upstream / the exact build patch, NOT reimplemented in this test.
"""

import hashlib
import os
import pathlib
import re
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "app/build/coreaudio-lifecycle"
PIN = "8c67647b50059406c5c0444903597281b81516cf"
HASHES = {
    "ao_coreaudio.c": "ea11a0cf81cd479479faf4534e63f01d4d49c89b9f8b388e5732f4417d2a4b27",
    "ao.c": "5fd091c800dbeb0d6f2c236ce9b1d88852266994c652f0c5317346ddc1d344e3",
    "buffer.c": "e053296cdfe58a07b6bd2aa5554774ff5c54ca57c622a56636fb6fe8f0fed105",
}


def function(source, name):
    pattern = rf"^(?:static )?[\w *]+\b{re.escape(name)}\([^;]*?\)\s*\{{"
    match = re.search(pattern, source, re.M)
    assert match, f"missing production function {name}"
    start = source.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


def verify_archive_gate(build_script):
    # Execute the production shell gate, not a Python imitation of its rules.
    gate = re.search(r"^for library in Libavformat Libmpv; do\n.*?^done$",
                     build_script, re.M | re.S).group()
    directory = BUILD / "archive-gate"
    archives = directory / "MPVKit/dist/release"
    archives.mkdir(parents=True, exist_ok=True)
    marker = directory / "started"
    marker.write_text("synthetic build marker\n")
    os.utime(marker, (1000, 1000))
    ffmpeg = archives / "Libavformat.xcframework.zip"
    mpv = archives / "Libmpv.xcframework.zip"
    for path in (ffmpeg, mpv):
        path.write_bytes(b"synthetic archive, not a framework")
        os.utime(path, (1001, 1001))
    environment = dict(os.environ, WORK=str(directory), BUILD_STARTED_MARKER=str(marker))

    def run():
        return subprocess.run(["bash", "-eu", "-c", gate], env=environment,
                              capture_output=True, text=True)

    assert run().returncode == 0
    os.utime(mpv, (999, 999))
    result = run()
    assert result.returncode != 0 and "refusing stale Libmpv ZIP" in result.stderr
    os.utime(mpv, (1001, 1001))
    os.utime(ffmpeg, (999, 999))
    result = run()
    assert result.returncode != 0 and "refusing stale Libavformat ZIP" in result.stderr
    print("PASS production archive gate: fresh pair admitted; stale mpv/FFmpeg independently refused")


def main():
    upstream = BUILD / "upstream/audio/out"
    upstream.mkdir(parents=True, exist_ok=True)
    sources = {}
    for name, digest in HASHES.items():
        path = upstream / name
        if not path.exists():
            url = f"https://raw.githubusercontent.com/mpv-player/mpv/{PIN}/audio/out/{name}"
            path.write_bytes(urllib.request.urlopen(url, timeout=30).read())
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest, f"source drift: {path}"
        sources[name] = data.decode()

    # Prove the generic driver's admission/free ordering used by the fixture.
    alloc = function(sources["ao.c"], "ao_init")
    assert alloc.index("ao->driver->init(ao)") < alloc.index("if (r < 0)")
    assert alloc.index("if (r < 0)") < alloc.index("ao->driver_initialized = true")
    assert "ao_uninit(ao);" in alloc
    generic_uninit = function(sources["buffer.c"], "ao_uninit")
    assert "if (ao->driver_initialized)\n        ao->driver->uninit(ao);" in generic_uninit

    variants = {"original": sources["ao_coreaudio.c"]}
    patch = ROOT / "scripts/mpv-coreaudio-hotplug-lifecycle.patch"
    assert patch.is_file(), "missing production CoreAudio lifetime patch"
    build_script = (ROOT / "scripts/build-mpvkit-dvfel.sh").read_text()
    assert 'cp "$REPO/scripts/mpv-coreaudio-hotplug-lifecycle.patch"' in build_script
    assert "0005-coreaudio-hotplug-lifecycle.patch" in build_script
    assert "for library in Libavformat Libmpv; do" in build_script
    verify_archive_gate(build_script)
    if patch.exists():
        patched_root = BUILD / "patched"
        patched = patched_root / "audio/out/ao_coreaudio.c"
        patched.parent.mkdir(parents=True, exist_ok=True)
        patched.write_text(variants["original"])
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=patched_root, check=True)
        subprocess.run(["git", "apply", str(patch)], cwd=patched_root, check=True)
        variants["patched"] = patched.read_text()

    fixture = (ROOT / "scripts/fixtures/mpv-coreaudio-lifecycle.c").read_text()
    names = ["reinit_device", "init", "init_audiounit", "cancel_and_release_idle_work",
             "uninit", "hotplug_cb", "hotplug_init", "hotplug_uninit",
             "register_hotplug_cb", "unregister_hotplug_cb"]
    for variant, source in variants.items():
        private = re.search(r"struct priv \{.*?\n\};", source, re.S).group()
        properties = re.search(r"static uint32_t hotplug_properties\[\] = \{.*?\n\};", source, re.S).group()
        bodies = "\n\n".join(function(source, name) for name in names)
        generated = fixture.replace("/* PRODUCTION_PRIV */", private)
        generated = generated.replace("/* PRODUCTION_FUNCTIONS */", properties + "\n" + bodies + "\n" + generic_uninit)
        c_path = BUILD / f"{variant}.c"
        binary = BUILD / f"{variant}-probe"
        c_path.write_text(generated)
        subprocess.run(["xcrun", "clang", "-std=c11", "-fblocks", "-g", "-O1",
                        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        "-Wall", "-Werror", "-Wno-unused-function",
                        str(c_path), "-o", str(binary)], check=True)
        linked = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        assert "CoreAudio.framework" not in linked and "AudioToolbox.framework" not in linked
        cases = ["chmap", "unit-property", "hotplug-partial"] if variant == "original" else [
            "device", "chmap", "component", "unit-new", "unit-init", "unit-property",
            "unit-device", "unit-map", "unit-callback", "listener-first", "listener-second",
            "hotplug-partial", "hotplug-first", "success", "hotplug-success", "refcount",
            "retry-registration", "exclusive", "physical-format", "physical-format-failure",
            "idle-work", "repeated-cleanup"]
        for case in cases:
            result = subprocess.run([str(binary), case, variant], capture_output=True, text=True)
            (BUILD / f"{variant}-{case}.log").write_text(result.stdout + result.stderr)
            if variant == "original":
                assert result.returncode != 0 and "heap-use-after-free" in result.stderr, (case, result.stderr)
                print(f"EXPECTED RED original {case}: ASan heap-use-after-free")
            else:
                assert result.returncode == 0, (case, result.stdout, result.stderr)
                print(f"PASS patched {case}")
    print("PASS: exact build patch, 3 native red controls + 22 patched lifecycle cases; no HAL/audio calls")


if __name__ == "__main__":
    main()
