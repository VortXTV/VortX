#!/usr/bin/env python3
"""Exercise the production archive checker with already-built, real native SDK libraries.

These are ZIP payload fixtures for APK/AAB library checks, not installable application builds.
No native source compilation, credentials, signing or app installation is performed.
"""
import argparse
import hashlib
import os
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ndk-bin", type=Path, required=True)
    parser.add_argument("--staged-dir", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    contents = {abi: (args.staged_dir / abi / "libvortx_ffi.so").read_bytes() for abi in ABIS}
    original_hashes = {abi: hashlib.sha256(data).hexdigest() for abi, data in contents.items()}
    environment = os.environ | {"READELF": str(args.ndk_bin / "llvm-readelf"), "STRIP": str(args.ndk_bin / "llvm-strip")}
    build_root = ROOT / "app/build"
    build_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-android-content-", dir=build_root) as directory:
        scratch = Path(directory)

        def archive(name, prefix, payloads, extra=None):
            path = scratch / name
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as package:
                for abi, data in payloads.items():
                    package.writestr(f"{prefix}/{abi}/libvortx_ffi.so", data)
                if extra:
                    package.writestr(*extra)
            return path

        def check(path, expected_error=None):
            result = subprocess.run(["bash", str(ROOT / "scripts/verify-native-android-artifacts.sh"),
                "--native-only", "--staged-dir", str(args.staged_dir), "--source-sha", args.source_sha,
                str(path)], env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if expected_error:
                if result.returncode == 0 or expected_error not in result.stdout:
                    raise RuntimeError(f"negative content case failed: {path.name}\n{result.stdout}")
            elif result.returncode:
                raise RuntimeError(f"approved content case failed: {path.name}\n{result.stdout}")
            print(f"PASS: {path.name}")

        check(archive("exact.apk", "lib", contents))
        check(archive("exact.aab", "base/lib", contents))
        stripped = {}
        for abi, data in contents.items():
            path = scratch / f"stripped-{abi}.so"
            path.write_bytes(data)
            subprocess.run([str(args.ndk_bin / "llvm-strip"), "--strip-unneeded", str(path)], check=True)
            stripped[abi] = path.read_bytes()
        check(archive("ndk-stripped.apk", "lib", stripped))
        check(archive("extra-abi.apk", "lib", contents, ("lib/x86/libvortx_ffi.so", contents["x86_64"])),
              "exactly one libvortx_ffi.so")
        check(archive("legacy-payload.apk", "lib", contents, ("lib/arm64-v8a/libstremiox_core.so", contents["arm64-v8a"])),
              "still contains legacy")
        sections = subprocess.check_output([str(args.ndk_bin / "llvm-readelf"), "--wide", "--sections",
                                           str(args.staged_dir / "arm64-v8a/libvortx_ffi.so")], text=True)
        match = re.search(r"\]\s+\.text\s+PROGBITS\s+[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)", sections)
        if not match or int(match.group(2), 16) == 0:
            raise RuntimeError("cannot locate actual ELF .text code for the stale-code negative case")
        changed = bytearray(contents["arm64-v8a"])
        changed[int(match.group(1), 16)] ^= 1
        check(archive("same-abi-stale-code.apk", "lib", contents | {"arm64-v8a": bytes(changed)}),
              "differs from staged source")
    for abi, expected in original_hashes.items():
        actual = hashlib.sha256((args.staged_dir / abi / "libvortx_ffi.so").read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"test changed original staged SDK: {abi}")
    print("PASS: native Android real-SDK archive payload and immutable input checks")


if __name__ == "__main__":
    main()
