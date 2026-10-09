#!/usr/bin/env python3
"""Compile exact added native transport methods with inert reference-counted buffers.

The patch is the production source; this runner does not maintain a second model.
--prepare-only and --normalize perform source preparation only, no compiler/run.
This is a transport fixture, NOT native VO, PiP, vendor or device acceptance.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "scripts/mpv-ios-native-pip-frame.patch"
FIXTURE = ROOT / "app/Tests/MPVNativeFrameTransportTests.c"
ADDED = (
    "include/mpv/vortx_apple_frame.h",
    "video/out/vortx_apple_frame.h",
    "video/out/vortx_apple_frame.c",
)


def normalize_hunks(text: str) -> str:
    """Formatting only: recompute unified-diff lengths from existing bytes."""
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        match = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)\n", line)
        if not match:
            continue
        old = new = 0
        for content in lines[index + 1:]:
            if content.startswith(("@@ ", "diff --git ")):
                break
            if content.startswith(" "):
                old += 1
                new += 1
            elif content.startswith("-"):
                old += 1
            elif content.startswith("+"):
                new += 1
            elif content.startswith("\\"):
                continue
            else:
                raise ValueError(f"unexpected hunk line: {content!r}")
        lines[index] = f"@@ -{match[1]},{old} +{match[2]},{new} @@{match[3]}\n"
    return "".join(lines)


def added_sources(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for block in text.split("diff --git ")[1:]:
        first, *lines = block.splitlines(keepends=True)
        path = first.strip().split(" b/", 1)[1]
        if path not in ADDED:
            continue
        if "--- /dev/null\n" not in lines:
            raise ValueError(f"expected actual newly added file: {path}")
        hunk = False
        content: list[str] = []
        for line in lines:
            if line.startswith("@@ "):
                hunk = True
            elif hunk:
                if not line.startswith("+"):
                    raise ValueError(f"non-addition in {path}: {line!r}")
                content.append(line[1:])
        result[path] = "".join(content)
    if set(result) != set(ADDED):
        raise ValueError(f"missing production sources: {set(ADDED) - set(result)}")
    return result


def contextualize(text: str, source_root: Path) -> str:
    """Mechanical diff formatting against read-only, pinned native sources.

    Exact old bytes must match at the declared line or at a unique subsequent
    occurrence. No source tree is written and no source change is inferred.
    """
    output: list[str] = []
    for block in text.split("diff --git ")[1:]:
        first, *lines = block.splitlines(keepends=True)
        path = first.strip().split(" b/", 1)[1]
        if "--- /dev/null\n" in lines:
            output.append("diff --git " + block)
            continue
        original = (source_root / path).read_text().splitlines(keepends=True)
        result: list[str] = []
        cursor = 0
        index = 0
        while index < len(lines):
            match = re.match(r"@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", lines[index])
            if not match:
                index += 1
                continue
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
            position = int(match[1]) - 1
            if position < cursor or original[position:position + len(old)] != old:
                matches = [at for at in range(cursor, len(original) - len(old) + 1)
                           if original[at:at + len(old)] == old]
                # Handwritten hunks may be a few lines off. Require a unique
                # nearest exact match within eight lines, never a fuzzy match.
                nearby = sorted((abs(at - position), at) for at in matches
                                if abs(at - position) <= 8)
                if len(matches) == 1:
                    position = matches[0]
                elif nearby and (len(nearby) == 1 or nearby[0][0] < nearby[1][0]):
                    position = nearby[0][1]
                else:
                    raise ValueError(f"ambiguous/missing exact hunk in {path}:{match[1]}")
            result.extend(original[cursor:position])
            result.extend(new)
            cursor = position + len(old)
        result.extend(original[cursor:])
        output.append(f"diff --git a/{path} b/{path}\n")
        output.extend(difflib.unified_diff(original, result, fromfile=f"a/{path}",
                                           tofile=f"b/{path}", n=3))
    return "".join(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--normalize", action="store_true")
    parser.add_argument("--contextualize-source", type=Path)
    args = parser.parse_args()
    text = PATCH.read_text()
    normalized = normalize_hunks(text)
    if args.contextualize_source:
        PATCH.write_text(contextualize(normalized, args.contextualize_source))
        print("Expanded exact existing hunks to three-line context; source read-only.")
        return
    if args.normalize:
        PATCH.write_text(normalized)
        print("Normalized unified-diff hunk lengths only; no compilation.")
        return
    if text != normalized:
        raise SystemExit("Patch hunk lengths are not normalized; use --normalize.")
    sources = added_sources(text)
    build_root = ROOT / "_build/tests"
    build_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="native-frame-transport-", dir=build_root))
    print(f"EXTRACTED_SOURCE_DIR={output}", flush=True)
    for relative, source in sources.items():
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
        print(f"SHA256 {hashlib.sha256(source.encode()).hexdigest()} {relative}")
    # Only the visibility macro and opaque handle are needed by this ABI fixture.
    # Buffer/GPU dependencies are deliberately inert; the transport is exact.
    (output / "include/mpv/client.h").write_text(
        "#define MPV_EXPORT\ntypedef struct mpv_handle mpv_handle;\n")
    print(f"PATCH_SHA256={hashlib.sha256(PATCH.read_bytes()).hexdigest()}", flush=True)
    print(f"FIXTURE_SHA256={hashlib.sha256(FIXTURE.read_bytes()).hexdigest()}", flush=True)
    if args.prepare_only:
        print("SOURCE PREPARATION ONLY: no compiler or runtime invoked.")
        return
    executable = output / "transport-tests"
    subprocess.run([
        "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
        "-I", str(output / "include"), "-I", str(output / "video/out"),
        str(output / "video/out/vortx_apple_frame.c"), str(FIXTURE),
        "-o", str(executable),
    ], check=True, timeout=45)
    subprocess.run([str(executable)], check=True, timeout=10)


if __name__ == "__main__":
    main()
