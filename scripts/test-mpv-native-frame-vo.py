#!/usr/bin/env python3
"""Mechanically compile actual native lifetime methods with inert GPU/VT doubles.

No MPV SDK build, GPU, decoder, AVKit, sockets or media. The native checkout is
read-only input. Generated files remain under this worktree's _build/tests.
The fixture does not validate rendering, real GPU drain, or physical PiP.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "scripts/mpv-ios-native-pip-frame.patch"
FIXTURE = ROOT / "app/Tests/MPVNativeFrameVOLifetimeTests.c"
NATIVE = Path("/Users/daksh/VortXTV/MPVKit/dist/libmpv-master-8c67647b")


def patched_source(path: str, source_root: Path) -> str:
    original = (source_root / path).read_text().splitlines(keepends=True)
    blocks = PATCH.read_text().split("diff --git ")[1:]
    block, = [block for block in blocks if block.splitlines()[0] == f"a/{path} b/{path}"]
    lines = block.splitlines(keepends=True)
    result: list[str] = []
    cursor = index = 0
    while index < len(lines):
        match = re.match(r"@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", lines[index])
        if not match:
            index += 1
            continue
        position = int(match[1]) - 1
        old: list[str] = []
        new: list[str] = []
        index += 1
        while index < len(lines) and not lines[index].startswith("@@ "):
            line = lines[index]
            if line.startswith((" ", "-")):
                old.append(line[1:])
            if line.startswith((" ", "+")):
                new.append(line[1:])
            index += 1
        if position < cursor or original[position:position + len(old)] != old:
            raise ValueError(f"nonexact or overlapping production hunk {path}:{position + 1}")
        result.extend(original[cursor:position])
        result.extend(new)
        cursor = position + len(old)
    result.extend(original[cursor:])
    return "".join(result)


def method(source: str, name: str) -> str:
    matches = list(re.finditer(r"(?m)^static [^;\n]*\b" + re.escape(name) +
                              r"\([^;]*?\)\n\{\n", source))
    if len(matches) != 1:
        raise ValueError(f"expected one exact function definition: {name}")
    start = matches[0].start()
    end = source.index("\n}\n", matches[0].end()) + 3
    return source[start:end]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--native-source", type=Path, default=NATIVE)
    parser.add_argument("--mode-baseline-source", type=Path,
                        help="retained pre-fix actual-method extraction, for regression RED")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("transport_extract", ROOT /
                                                "scripts/test-mpv-native-frame-transport.py")
    assert spec and spec.loader
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    patch = PATCH.read_text()
    if patch != transport.normalize_hunks(patch):
        raise SystemExit("Patch hunk lengths are not normalized")
    sources = transport.added_sources(patch)
    candidate = patched_source("video/out/vo_gpu_next.c", args.native_source)
    baseline = (args.native_source / "video/out/vo_gpu_next.c").read_text()
    functions = ["get_image", "wakeup", "destroy_gpu_resources", "uninit",
                 "create_gpu_resources", "preinit", "vortx_frame_mode"]
    methods = "\n".join(method(candidate, name) for name in functions)
    # Lifecycle tests can inject a reason; compatibility tests invoke this
    # separately extracted actual pixel/option admission method directly.
    methods += method(candidate, "vortx_frame_eligibility").replace(
        "vortx_frame_eligibility(", "vortx_native_eligibility(", 1)
    if args.mode_baseline_source:
        old_mode = method(args.mode_baseline_source.read_text(), "vortx_frame_mode")
        methods = methods.replace(method(candidate, "vortx_frame_mode"), old_mode, 1)
        print("MODE_BASELINE_SHA256=" + hashlib.sha256(
            args.mode_baseline_source.read_bytes()).hexdigest(), flush=True)
    # Only rename the original method so candidate/baseline can coexist. Its
    # body is byte-for-byte pinned production, not an alternative lifecycle.
    old_uninit = method(baseline, "uninit").replace("uninit(", "baseline_uninit(", 1)
    build_root = ROOT / "_build/tests"
    build_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="native-frame-vo-", dir=build_root))
    for relative, source in sources.items():
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
    (output / "include/mpv/client.h").write_text(
        "#define MPV_EXPORT\ntypedef struct mpv_handle mpv_handle;\n")
    generated = FIXTURE.read_text().replace("/* ACTUAL_NATIVE_METHODS */", methods + old_uninit)
    if generated == FIXTURE.read_text():
        raise ValueError("fixture extraction marker missing")
    (output / "lifetime-tests.c").write_text(generated)
    for path in [PATCH, FIXTURE, Path(__file__), args.native_source / "video/out/vo_gpu_next.c"]:
        print(f"SHA256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path}", flush=True)
    print(f"EXTRACTED_SOURCE_DIR={output}", flush=True)
    print(f"METHODS_SHA256={hashlib.sha256(methods.encode()).hexdigest()}", flush=True)
    print(f"GENERATED_SHA256={hashlib.sha256(generated.encode()).hexdigest()}", flush=True)
    if args.prepare_only:
        print("SOURCE PREPARATION ONLY: no compiler/runtime invoked")
        return
    executable = output / "lifetime-tests"
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                    "-I", str(output / "include"), "-I", str(output / "video/out"),
                    str(output / "video/out/vortx_apple_frame.c"), str(output / "lifetime-tests.c"),
                    "-o", str(executable)], check=True, timeout=45)
    subprocess.run([str(executable)], check=True, timeout=10)


if __name__ == "__main__":
    main()
