#!/usr/bin/env python3
"""Bind Xcode's processed static archive to the admitted XCFramework constituents."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("dovi_provider", Path(__file__).with_name("aether-dovi-provider.py"))
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)


def run(*args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def digest(path):
    return hashlib.sha256(provider.read(path)).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--processed", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--owned-root", type=Path, required=True)
    parser.add_argument("--platform", choices=["tvos-simulator", "ios-simulator", "macos"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for path in (args.processed, args.work, args.output):
        provider.owned(path, args.owned_root)
    provider.package_owned(args.package, args.owned_root)
    receipt = json.loads(provider.read(args.work / "extension-receipt.json"))
    provider.need(receipt["packageCommit"] == provider.PACKAGE and
                  receipt["provider"]["sourceCommit"] == provider.SOURCE, "unbound extension receipt")
    xc = args.package / "Dovi.xcframework"
    provider.need(provider.manifest(xc) == receipt["after"], "admitted package changed")
    info = plistlib.loads(provider.read(xc / "Info.plist"))
    platform, _, variant = args.platform.partition("-")
    candidates = [row for row in info["AvailableLibraries"]
                  if row["SupportedPlatform"] == platform and row.get("SupportedPlatformVariant", "") == variant]
    provider.need(len(candidates) == 1, "ambiguous platform provider")
    row = candidates[0]
    original = xc / row["LibraryIdentifier"] / row["LibraryPath"]
    provider.owned(original, args.owned_root)
    expected_arches = set(run("xcrun", "lipo", "-archs", original).split())
    actual_arches = set(run("xcrun", "lipo", "-archs", args.processed).split())
    provider.need(actual_arches and actual_arches <= expected_arches, "processed archive has an unadmitted architecture")
    rows = {}
    with tempfile.TemporaryDirectory(prefix="processed-proof-", dir=args.work) as directory:
        scratch = Path(directory)
        for arch in sorted(actual_arches):
            provider.need(arch in ("arm64", "x86_64"), "unexpected CPU architecture")
            inputs = []
            for index, (path, arches) in enumerate(((original, expected_arches), (args.processed, actual_arches))):
                if len(arches) == 1:
                    inputs.append(path)
                else:
                    output = scratch / f"{index}-{arch}.a"
                    run("xcrun", "lipo", path, "-thin", arch, "-output", output)
                    inputs.append(output)
            expected, actual = map(digest, inputs)
            provider.need(actual == expected, "Xcode processed a different provider for " + arch)
            rows[arch] = actual
    args.output.write_text(json.dumps({"schema": 1, "platform": args.platform,
        "packageCommit": provider.PACKAGE, "extensionReceiptSHA256": digest(args.work / "extension-receipt.json"),
        "sourceLibrary": str(original), "processedLibrary": str(args.processed),
        "processedSHA256": digest(args.processed), "architectureSHA256": rows}, indent=2) + "\n")
    print("ok: processed Dovi bytes match the admitted provider for " + args.platform)


if __name__ == "__main__":
    main()
