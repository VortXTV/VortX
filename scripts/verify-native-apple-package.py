#!/usr/bin/env python3
"""Bind a native Apple app and its linker map to the exact audited build inputs.

The manifest is captured after the SDK/MPV content gates and before app compilation.
An ABI-compatible stale archive must fail the linker-map content check. This supplements
the existing SDK, deployment, dSYM, signing, IPA/DMG and feed gates; it replaces none.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ENGINE_SLICES = {
    "ios": "ios-arm64", "ios-sim": "ios-arm64-simulator",
    "tvos": "tvos-arm64", "tvos-sim": "tvos-arm64-simulator", "macos": "macos-arm64",
}
MPV_SLICES = {
    "ios": "ios-arm64", "ios-sim": "ios-arm64_x86_64-simulator",
    "tvos": "tvos-arm64_arm64e", "tvos-sim": "tvos-arm64_x86_64-simulator",
    "macos": "macos-arm64_x86_64",
}
MPV_TARGETS = {
    "Libmpv-GPL": "Libmpv", "Libavcodec-GPL": "Libavcodec",
    "Libavdevice-GPL": "Libavdevice", "Libavfilter-GPL": "Libavfilter",
    "Libavformat-GPL": "Libavformat", "Libavutil-GPL": "Libavutil",
    "Libswresample-GPL": "Libswresample", "Libswscale-GPL": "Libswscale",
    "Libplacebo": "Libplacebo",
}
FLOORS = {"ios": "16.0", "ios-sim": "16.0", "tvos": "18.0", "tvos-sim": "18.0", "macos": "14.0"}
PLATFORMS = {"macos": "1", "ios": "2", "tvos": "3", "ios-sim": "7", "tvos-sim": "8"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*command: str) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)


def unsigned_hash(path: Path) -> str:
    # codesign changes a daemon's signature without changing the executable code. Normalize
    # BOTH copies through the same real tool, including the linker's original ad-hoc signature.
    with tempfile.TemporaryDirectory(prefix="vortx-signature-proof-") as directory:
        copy = Path(directory) / path.name
        shutil.copyfile(path, copy)
        signed = subprocess.run(["codesign", "-dv", str(copy)], capture_output=True).returncode == 0
        if signed:
            run("codesign", "--remove-signature", str(copy))
        return sha256(copy)


def record(path: Path, kind: str, slice_name: str | None = None, target: str | None = None) -> dict:
    path = path.resolve(strict=True)
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"missing or empty input: {path}")
    return {"path": str(path), "sha256": sha256(path), "kind": kind, "slice": slice_name, "target": target}


def snapshot(engine: Path, mpvkit: Path, revision: str, server: Path | None) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("native source revision must be a full immutable SHA")
    entries = []
    for slice_name in ENGINE_SLICES.values():
        entries.append(record(engine / slice_name / "libvortx_ffi.a", "engine", slice_name))
        entries.append(record(engine / slice_name / "Headers/vortx/vortx_ffi.h", "header", slice_name))
    if len({entry["sha256"] for entry in entries if entry["kind"] == "header"}) != 1:
        raise ValueError("native SDK copied headers do not match across all five slices")
    entries.append(record(mpvkit / "Package.swift", "mpv-manifest"))
    for target, binary in MPV_TARGETS.items():
        for slice_name in MPV_SLICES.values():
            entries.append(record(mpvkit / "artifacts" / f"{target}.xcframework" / slice_name / f"{binary}.framework" / binary,
                                  "mpv", slice_name, target))
    if server:
        entry = record(server, "mac-server")
        entry["unsignedSha256"] = unsigned_hash(server)
        entries.append(entry)
    return {"schema": 1, "engineSourceRevision": revision, "features": "state,resource-host;server=iOS,tvOS,separate-mac",
            "inputs": entries}


def verify_inputs(manifest: dict) -> None:
    if manifest.get("schema") != 1 or not re.fullmatch(r"[0-9a-f]{40}", manifest.get("engineSourceRevision", "")):
        raise ValueError("invalid native build input manifest")
    for entry in manifest["inputs"]:
        path = Path(entry["path"])
        if not path.is_file() or sha256(path) != entry["sha256"]:
            raise ValueError(f"build input changed after capture: {path}")


def verify_link_map(manifest: dict, platform: str, link_map: Path) -> dict:
    expected = {"libvortx_ffi.a": next(entry for entry in manifest["inputs"]
                if entry["kind"] == "engine" and entry["slice"] == ENGINE_SLICES[platform])}
    expected.update({MPV_TARGETS[entry["target"]]: entry for entry in manifest["inputs"]
                     if entry["kind"] == "mpv" and entry["slice"] == MPV_SLICES[platform]})
    loaded = {}
    content_hashes = {}
    for line in link_map.read_text().splitlines():
        match = re.match(r"^\[\s*\d+\]\s+(.+)$", line)
        if not match:
            continue
        # Linker-map archive member syntax: /exact/path/lib.a(member.o).
        archive_path = match.group(1).rsplit("(", 1)[0]
        if re.search(r"StremioXCore|libstremiox|NodeMobile", archive_path, re.IGNORECASE):
            raise ValueError(f"legacy engine/runtime contributed to native link: {archive_path}")
        name = Path(archive_path).name
        if name not in expected:
            continue
        path = Path(archive_path)
        if not path.is_file():
            raise ValueError(f"native link consumed an unavailable archive: {archive_path}")
        if archive_path not in content_hashes:
            content_hashes[archive_path] = sha256(path)
        if content_hashes[archive_path] != expected[name]["sha256"]:
            raise ValueError(f"native link consumed an unapproved archive: {archive_path}")
        loaded[name] = {"path": str(path), "sha256": expected[name]["sha256"]}
    # Other FFmpeg libraries may be dead-stripped, but these libraries must contribute actual code.
    required = {"libvortx_ffi.a", "Libmpv", "Libavcodec", "Libavformat", "Libplacebo"}
    if not required.issubset(loaded):
        raise ValueError(f"link map lacks required native/player archives: {sorted(required - loaded.keys())}")
    return loaded


def version(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def verify_app(manifest: dict, app: Path, platform: str, link_map: Path) -> dict:
    verify_inputs(manifest)
    loaded = verify_link_map(manifest, platform, link_map)
    contents = app / "Contents" if platform == "macos" else app
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for key in ("VortXNativeDataEngine", "VortXNativeResourceHost"):
        if info.get(key) not in (True, "YES"):
            raise ValueError(f"{app} does not declare {key}=true")
    if info.get("VortXEngineSourceRevision") != manifest["engineSourceRevision"]:
        raise ValueError("native app source revision differs from captured SDK inputs")
    transport = "daemon" if platform == "macos" else ("none" if info.get("CFBundleIdentifier") == "com.stremiox.tv.lite" else "in-process")
    if info.get("VortXNativeTransport") != transport:
        raise ValueError("native app transport selection differs from its target policy")
    floor_key = "LSMinimumSystemVersion" if platform == "macos" else "MinimumOSVersion"
    if version(info.get(floor_key, "0")) != version(FLOORS[platform]):
        raise ValueError(f"native app deployment floor differs from {FLOORS[platform]}")
    name = info.get("CFBundleExecutable", "")
    if not name or Path(name).name != name:
        raise ValueError("invalid bundle executable name")
    binary = contents / "MacOS" / name if platform == "macos" else contents / name
    if run("lipo", "-archs", str(binary)).strip() != "arm64":
        raise ValueError("native app must match the reviewed arm64 engine SDK")
    load_commands = run("otool", "-l", str(binary))
    build_versions = re.findall(r"cmd LC_BUILD_VERSION\n(.*?)(?=\nLoad command|\Z)", load_commands, re.DOTALL)
    if len(build_versions) != 1:
        raise ValueError("expected one native executable LC_BUILD_VERSION")
    build = build_versions[0]
    minos = re.search(r"\bminos\s+([0-9.]+)", build)
    sdk_platform = re.search(r"\bplatform\s+(\S+)", build)
    platform_names = {"macos": "MACOS", "ios": "IOS", "tvos": "TVOS", "ios-sim": "IOSSIMULATOR", "tvos-sim": "TVOSSIMULATOR"}
    if not minos or version(minos.group(1)) != version(FLOORS[platform]):
        raise ValueError("native executable minimum OS differs from its reviewed floor")
    if not sdk_platform or sdk_platform.group(1) not in (PLATFORMS[platform], platform_names[platform]):
        raise ValueError("native executable was built for another Apple platform")
    symbols = run("nm", "-g", str(binary))
    if re.search(r"\b_stremiox_core_|\b_node_start\b", symbols):
        raise ValueError("native executable retains legacy core/Node symbols")
    required_symbols = ["vortx_init_from_state_json", "vortx_dispatch_json", "vortx_get_state_json",
                        "vortx_resource_host_new", "vortx_resource_host_load_json", "vortx_resource_host_free"]
    if transport == "in-process":
        required_symbols += ["vortx_server_start", "vortx_server_port", "vortx_server_base_url", "vortx_server_stop"]
    for symbol in required_symbols:
        if not re.search(rf"\b[Tt]\s+_{symbol}$", symbols, re.MULTILINE):
            raise ValueError(f"native executable lacks callable {symbol}")
    for path in app.rglob("*"):
        if path.name in ("server.js", "node-darwin-arm64") or "NodeMobile" in path.name or "StremioXCore" in path.name:
            raise ValueError(f"native bundle retained a legacy runtime payload: {path}")
    if platform == "macos":
        server = next((entry for entry in manifest["inputs"] if entry["kind"] == "mac-server"), None)
        daemon = contents / "Resources/vortx-streaming-server"
        if not server or not daemon.is_file() or unsigned_hash(daemon) != server["unsignedSha256"]:
            raise ValueError("native Mac bundle does not contain the exact captured daemon code")
    return {"schema": 1, "engineSourceRevision": manifest["engineSourceRevision"], "platform": platform,
            "bundleIdentifier": info.get("CFBundleIdentifier"), "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "executableSha256": sha256(binary),
            "unsignedExecutableSha256": unsigned_hash(binary), "bundlePayload": bundle_payload(app),
            "linkMapSha256": sha256(link_map), "loadedArchives": loaded}


def bundle_payload(app: Path) -> dict:
    """Hash bundle content while permitting the signing operation performed by packaging."""
    payload = {}
    macho_magics = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
                    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app)
        if "_CodeSignature" in relative.parts:
            continue
        if path.is_symlink():
            payload[str(relative)] = {"symlink": str(path.readlink())}
        elif path.is_file():
            with path.open("rb") as stream:
                macho = stream.read(4) in macho_magics
            payload[str(relative)] = {"sha256": unsigned_hash(path) if macho else sha256(path)}
    return payload


def verify_packaged_copy(receipt: dict, app: Path, platform: str) -> dict:
    if receipt.get("schema") != 1 or receipt.get("platform") != platform:
        raise ValueError("package proof requires the corresponding accepted app receipt")
    if receipt.get("bundlePayload") != bundle_payload(app):
        raise ValueError("packaged app payload differs from the accepted native app")
    for path in app.rglob("*"):
        if path.name in ("server.js", "node-darwin-arm64") or "NodeMobile" in path.name or "StremioXCore" in path.name:
            raise ValueError(f"native archive contains a legacy runtime payload: {path}")
    return {key: receipt[key] for key in ("engineSourceRevision", "platform", "bundleIdentifier", "version", "build")}


def verify_archive(receipt: dict, artifact: Path, platform: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="vortx-native-package-") as directory:
        scratch = Path(directory)
        mounted = False
        if artifact.suffix == ".ipa" and platform != "macos":
            with zipfile.ZipFile(artifact) as archive:
                for item in archive.infolist():
                    destination = (scratch / item.filename).resolve()
                    if not destination.is_relative_to(scratch):
                        raise ValueError("IPA archive path escapes its extraction directory")
                    # Preserve symlink references so the accepted bundle payload remains exact.
                    mode = item.external_attr >> 16
                    if mode & 0o170000 == 0o120000:
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.symlink_to(archive.read(item).decode())
                    else:
                        archive.extract(item, scratch)
            apps = list((scratch / "Payload").glob("*.app"))
        elif artifact.suffix == ".dmg" and platform == "macos":
            mount = scratch / "mount"
            mount.mkdir()
            run("hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(artifact.resolve()))
            mounted = True
            apps = list(mount.glob("*.app"))
        else:
            raise ValueError("artifact extension does not match the native Apple platform")
        try:
            if len(apps) != 1:
                raise ValueError("native package must contain exactly one app")
            if platform == "macos":
                run("codesign", "--verify", "--deep", "--strict", str(apps[0]))
            result = verify_packaged_copy(receipt, apps[0], platform)
            result.update({"schema": 1, "artifact": artifact.name, "artifactSha256": sha256(artifact)})
            return result
        finally:
            if mounted:
                run("hdiutil", "detach", str(scratch / "mount"))


def main() -> None:
    if sys.version_info < (3, 9):
        raise ValueError("native package verification requires Python 3.9 or newer")
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("snapshot")
    capture.add_argument("--engine", type=Path, required=True)
    capture.add_argument("--mpvkit", type=Path, required=True)
    capture.add_argument("--engine-revision", required=True)
    capture.add_argument("--mac-server", type=Path)
    capture.add_argument("--output", type=Path, required=True)
    check = commands.add_parser("verify")
    check.add_argument("--manifest", type=Path, required=True)
    check.add_argument("--app", type=Path, required=True)
    check.add_argument("--platform", choices=ENGINE_SLICES, required=True)
    check.add_argument("--link-map", type=Path, required=True)
    check.add_argument("--receipt", type=Path, required=True)
    archive = commands.add_parser("verify-archive")
    archive.add_argument("--app-receipt", type=Path, required=True)
    archive.add_argument("--artifact", type=Path, required=True)
    archive.add_argument("--platform", choices=("ios", "tvos", "macos"), required=True)
    archive.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "snapshot":
        result = snapshot(args.engine, args.mpvkit, args.engine_revision, args.mac_server)
        destination = args.output
    elif args.command == "verify":
        manifest = json.loads(args.manifest.read_text())
        result = verify_app(manifest, args.app, args.platform, args.link_map)
        destination = args.receipt
    else:
        result = verify_archive(json.loads(args.app_receipt.read_text()), args.artifact, args.platform)
        destination = args.receipt
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"PASS: native Apple {args.command}: {destination}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        raise SystemExit(f"FAIL: {error}") from error
