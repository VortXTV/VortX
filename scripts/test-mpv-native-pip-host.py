#!/usr/bin/env python3
"""Actual iOS PiP owner/lifecycle methods with inert AVKit/Metal/libmpv doubles.

No app, native SDK build, GPU, decoder, network, provider, or audio. CoreMedia
creates only CPU-backed synthetic sample buffers. Generated sources stay in the
registered worktree. --baseline-dismantle-ref substitutes ONLY that immutable
production boundary, not a fabricated old PiP implementation.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "app/Sources/Player"
TESTS = ROOT / "app/Tests"


def method(source: str, name: str) -> str:
    matches = list(re.finditer(r"(?m)^    (?:private |static )?func " + re.escape(name) + r"\(", source))
    if len(matches) != 1:
        raise ValueError(f"expected one production method {name}, got {len(matches)}")
    start = matches[0].start()
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end] + "\n"


def ios_only_method(source: str) -> str:
    # The extracted dismantle boundary contains one iOS-only branch, no else.
    directives = [line.strip() for line in source.splitlines() if line.lstrip().startswith("#")]
    if directives not in ([], ["#if os(iOS)", "#endif"]):
        raise ValueError("unexpected platform alternatives in dismantle method")
    return "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#")) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--baseline-dismantle-ref")
    parser.add_argument("--baseline-host-blob", help="Immutable retained pre-fix controller Git blob")
    args = parser.parse_args()
    bridge_path = PLAYER / "MPVSampleBufferPiPController.swift"
    engine_path = PLAYER / "MPVMetalViewController.swift"
    representable_path = PLAYER / "MPVMetalPlayerView.swift"
    fixture_path = TESTS / "MPVNativePiPHostTests.swift"
    bridge = bridge_path.read_text()
    if args.baseline_host_blob:
        bridge = subprocess.run(
            ["git", "-C", str(ROOT), "show", args.baseline_host_blob],
            check=True, capture_output=True, text=True, timeout=10).stdout
        print(f"BASELINE_HOST_BLOB={args.baseline_host_blob}", flush=True)
        print(f"BASELINE_HOST_SHA256={hashlib.sha256(bridge.encode()).hexdigest()}", flush=True)
    if not bridge.startswith("#if os(iOS)\n") or not bridge.endswith("#endif\n"):
        raise ValueError("unexpected bridge platform boundary")
    # Compile the ENTIRE production bridge (including its actual frame consumer,
    # mailbox and subscription), omitting only imports and the SwiftUI button.
    bridge = bridge.split("\nstruct MPVPictureInPictureButton: View {", 1)[0]
    bridge = "\n".join(line for line in bridge.splitlines()[1:] if not line.startswith("import ")) + "\n"
    engine = engine_path.read_text()
    names = ["preparePiPCaptureAdmission", "releasePiPCaptureAdmission", "subscribePiP",
             "performPiPMode", "setPiPHeadless", "restorePiPBeforeReplacement",
             "closePiPForegroundAuthority", "openPiPForegroundAuthority"]
    methods = "\n".join(method(engine, name) for name in names)
    for name in ["pipLoadedOwner", "piPHasRetiredGPU"]:
        match, = re.findall(r"(?m)^    var " + name + r"[^\n]+", engine)
        methods += match + "\n"
    representable = representable_path.read_text()
    if args.baseline_dismantle_ref:
        representable = subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{args.baseline_dismantle_ref}:app/Sources/Player/MPVMetalPlayerView.swift"],
            check=True, capture_output=True, text=True, timeout=10).stdout
    dismantle = ios_only_method(method(representable, "dismantleUIViewController"))
    fixture = fixture_path.read_text()
    for marker, replacement in [("// @@ENGINE_METHODS@@", methods),
                                ("// @@DISMANTLE_METHOD@@", dismantle),
                                ("// @@PRODUCTION_BRIDGE@@", bridge)]:
        if fixture.count(marker) != 1:
            raise ValueError(f"nonunique extraction marker {marker}")
        fixture = fixture.replace(marker, replacement)

    # ABI layout is mirrored field-for-field, not guessed from a Swift tuple.
    patch = (ROOT / "scripts/mpv-ios-native-pip-frame.patch").read_text()
    public = patch.split("diff --git a/video/out/", 1)[0]
    public = "\n".join(line[1:] for line in public.splitlines() if line.startswith("+") and not line.startswith("+++"))
    fields = re.search(r"struct mpv_vortx_apple_frame \{(.*?)\n\};", public, re.S)[1]
    mirror = re.search(r"typedef struct \{(.*?)\n\} VortXMPVNativeFrame;",
                       (PLAYER / "VortXMPVNativeFrameBridge.h").read_text(), re.S)[1]
    def declarations(value: str) -> str:
        value = re.sub(r"/\*.*?\*/|//[^\n]*", "", value, flags=re.S)
        return re.sub(r"\s+", " ", value).strip()
    if declarations(fields) != declarations(mirror):
        raise ValueError("native ABI frame layout differs from committed public header")
    print("PASS native ABI mirror exactly matches committed public fields", flush=True)

    build_root = ROOT / "_build/tests"
    build_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="native-pip-host-", dir=build_root))
    generated = output / "HostTests.swift"
    generated.write_text(fixture)
    inputs = [bridge_path, engine_path, representable_path, PLAYER / "MetalLayer.swift",
              PLAYER / "MPVPiPCaptureGate.swift", PLAYER / "VortXMPVNativeFrameBridge.h",
              PLAYER / "VortXMPVNativeFrameBridge.c", PLAYER / "VortX-Bridging.h",
              ROOT / "app/Sources/PlayerScreen.swift", fixture_path,
              TESTS / "MPVNativePiPHostStub.h", TESTS / "MPVNativePiPHostStub.c", Path(__file__)]
    for path in inputs:
        print(f"SHA256 {hashlib.sha256(path.read_bytes()).hexdigest()} {path}", flush=True)
    print(f"EXTRACTED_SOURCE_DIR={output}", flush=True)
    print(f"GENERATED_SHA256={hashlib.sha256(fixture.encode()).hexdigest()}", flush=True)
    print(f"METHODS_SHA256={hashlib.sha256((methods + dismantle + bridge).encode()).hexdigest()}", flush=True)
    if args.prepare_only:
        print("SOURCE PREPARATION ONLY: no compiler/runtime invoked")
        return
    objects = []
    for source in [PLAYER / "VortXMPVNativeFrameBridge.c", TESTS / "MPVNativePiPHostStub.c"]:
        obj = output / (source.stem + ".o")
        subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-c",
                        str(source), "-o", str(obj)], check=True, timeout=45)
        objects.append(str(obj))
    executable = output / "host-tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                    "-import-objc-header", str(TESTS / "MPVNativePiPHostStub.h"),
                    str(PLAYER / "MPVPiPCaptureGate.swift"), str(generated), *objects,
                    "-framework", "CoreFoundation", "-o", str(executable)], check=True, timeout=45)
    command = [str(executable)]
    if args.baseline_dismantle_ref:
        command.append("--dismantle-only")
    subprocess.run(command, check=True, timeout=10)


if __name__ == "__main__":
    main()
