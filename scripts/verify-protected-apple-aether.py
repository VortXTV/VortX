#!/usr/bin/env python3
"""Verify protected arm64 Aether linkage and bind the Mac kit across final signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile


PACKAGES = {
    "aetherengine": ("AetherEngine", "7.53.0", "4a82484b256deb70a2ae80d6923707d1fe54c6e7"),
    "libdovi": ("LibDovi", "2.1.0", "0d7cce1d6836a30d13a3a2326e50a153af53f014"),
}
FRAMEWORKS = ("AetherLibavcodec", "AetherLibavfilter", "AetherLibavformat", "AetherLibavutil",
              "AetherLibdav1d", "AetherLibswresample", "AetherLibswscale", "AetherLibzimg", "AetherLibzvbi")
PLATFORMS = {
    "tvos-simulator": ("tvos", "simulator"), "ios-simulator": ("ios", "simulator"),
    "tvos": ("tvos", ""), "tvos-lite": ("tvos", ""), "ios": ("ios", ""), "macos": ("macos", ""),
}
LINK_MAP_OBJECT = re.compile(r"^\[\s*(\d+)\]\s+(.+?/libdovi\.a)\([^)]+\)$", re.MULTILINE)
LINK_MAP_SYMBOL = re.compile(r"^0x[0-9A-Fa-f]+\s+0x[0-9A-Fa-f]+\s+\[\s*(\d+)\]", re.MULTILINE)
OTHER_PLAYER = re.compile(r"MPVKit-DVFEL/|Libmpv(?:-GPL)?\.xcframework/|Libav(?:codec|filter|format|util)\.xcframework/")
METADATA_LIMIT = 8 * 1024 * 1024
LINK_MAP_LIMIT = 64 * 1024 * 1024
BITCODE_BINARY_LIMIT = 128 * 1024 * 1024
DEVICE_KEYS = {"tvos", "tvos-lite", "ios"}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True, timeout=60).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_bounded(path, limit=METADATA_LIMIT):
    require(path.is_file() and not path.is_symlink(), f"expected a regular evidence file: {path.name}")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(0 < len(data) <= limit, f"empty or oversized evidence file: {path.name}")
    return data


def native_normalizer():
    path = Path(os.environ["NATIVE_PACKAGE_VERIFIER_DIR"]) / "verify-native-apple-package.py"
    source = read_bounded(path)
    actual_blob = subprocess.check_output(["git", "hash-object", "--stdin"], input=source, timeout=60).decode().strip()
    require(actual_blob == run("git", "rev-parse", "HEAD:scripts/verify-native-apple-package.py"),
            "staged native package verifier differs from the candidate source")
    scope = {"__name__": "vortx_native_package_verifier", "__file__": str(path)}
    exec(compile(source, str(path), "exec", dont_inherit=True), scope)
    return scope["unsigned_hash"]


def identity():
    source = os.environ["BUILD_SOURCE_SHA"]
    workflow = os.environ["GITHUB_SHA"]
    ref = os.environ["GITHUB_REF"]
    run_id = os.environ["GITHUB_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    require(os.environ["GITHUB_EVENT_NAME"] == "workflow_dispatch" and
            os.environ["GITHUB_REPOSITORY"] == "VortXTV/VortX" and
            ref in ("refs/tags/v0.5.6-beta.12-candidate.3", "refs/tags/v0.5.6-beta.13-candidate.1",
                    "refs/tags/v0.5.6-device-test.2") and
            re.fullmatch(r"[0-9a-f]{40}", source) and source == workflow == run("git", "rev-parse", "HEAD") and
            all(re.fullmatch(r"[1-9][0-9]*", value) for value in (run_id, attempt)),
            "Aether evidence requires the exact candidate workflow and checkout")
    return {"schemaVersion": 1, "sourceCommit": source, "workflowCommit": workflow,
            "ref": ref, "runId": int(run_id), "attempt": int(attempt)}


def resolution(args):
    lock_bytes = read_bounded(args.lock)
    lock = json.loads(lock_bytes)
    require(lock["version"] in (2, 3), "unsupported SwiftPM lock schema")
    pins = lock["pins"]
    observed = {}
    for key, (name, version, revision) in PACKAGES.items():
        rows = [pin for pin in pins if pin["identity"] == key]
        require(len(rows) == 1, f"missing or ambiguous SwiftPM pin for {name}")
        row = rows[0]
        checkout = (args.packages / "checkouts" / name).resolve(strict=True)
        require(checkout == args.packages.resolve(strict=True) / "checkouts" / name,
                f"{name} checkout escapes the owned SwiftPM directory")
        url = f"https://github.com/superuser404notfound/{name}"
        require(row["kind"] == "remoteSourceControl" and row["location"].removesuffix(".git") == url and
                row["state"] == {"revision": revision, "version": version} and
                run("git", "-C", checkout, "rev-parse", "HEAD") == revision and
                not run("git", "-C", checkout, "status", "--porcelain=v1", "--untracked-files=all"),
                f"{name} checkout or lock differs from the reviewed clean pin")
        observed[key] = {"version": version, "revision": revision, "location": url}
    return {**identity(), "packageResolvedSha256": hashlib.sha256(lock_bytes).hexdigest(), "packages": observed}


def admit_provider(args, architecture, map_text):
    matches = LINK_MAP_OBJECT.findall(map_text.partition("# Symbols:")[0])
    require(matches, "Aether link map has no LibDovi archive members")
    paths = {Path(path).resolve(strict=True) for _, path in matches}
    require(len(paths) == 1, "Aether link map has ambiguous LibDovi provider paths")
    processed, = paths
    require(processed.is_relative_to((args.derived / "Build/Products").resolve(strict=True)),
            "Aether link map provider is outside these build products")
    live_symbols = map_text.partition("# Symbols:")[2].partition("# Dead Stripped Symbols:")[0]
    require({index for index, _ in matches}.intersection(LINK_MAP_SYMBOL.findall(live_symbols)),
            "Aether link map has no live LibDovi provider contribution")

    checkout = (args.packages / "checkouts/LibDovi").resolve(strict=True)
    xcframework = checkout / "Dovi.xcframework"
    manifest = plistlib.loads(read_bounded(xcframework / "Info.plist"))
    platform, variant = PLATFORMS[args.key]
    rows = [row for row in manifest["AvailableLibraries"] if row["SupportedPlatform"] == platform and
            row.get("SupportedPlatformVariant", "") == variant and architecture in row["SupportedArchitectures"]]
    require(len(rows) == 1, "missing or ambiguous pinned LibDovi arm64 slice")
    row, = rows
    upstream = (xcframework / row["LibraryIdentifier"] / row["LibraryPath"]).resolve(strict=True)
    require(upstream.is_relative_to(xcframework) and upstream.name == "libdovi.a",
            "unexpected pinned LibDovi slice location")
    with tempfile.TemporaryDirectory(prefix="vortx-aether-arm64-", dir=args.derived) as directory:
        digests = []
        for path in (upstream, processed):
            arches = run("xcrun", "lipo", "-archs", path).split()
            require(architecture in arches, f"missing {architecture} LibDovi slice")
            if arches != [architecture]:
                thin = Path(directory) / f"{len(digests)}.a"
                run("xcrun", "lipo", path, "-thin", architecture, "-output", thin)
                path = thin
            digests.append(sha256(path))
    require(digests[0] == digests[1], "linked LibDovi arm64 bytes differ from the pinned provider")
    return {"platform": platform, "variant": variant, "libraryIdentifier": row["LibraryIdentifier"],
            "upstreamSha256": sha256(upstream), "processedSha256": sha256(processed), "arm64Sha256": digests[0]}


def inspect_link_map(args):
    intermediate = (args.derived / "Build/Intermediates.noindex").resolve(strict=True)
    maps = [path for path in intermediate.rglob("VortXAetherKit-LinkMap-*-arm64.txt")
            if path.is_file() and "VortXAetherKit.build" in path.parts]
    require(len(maps) == 1, "missing or ambiguous Aether arm64 link map")
    link_map, = maps
    require(link_map.resolve(strict=True) == link_map, "Aether link map must be owned by the current build")
    map_bytes = read_bounded(link_map, LINK_MAP_LIMIT)
    # Apple's maps can contain non-UTF-8 bytes in unrelated linker symbols.
    map_text = map_bytes.decode("utf-8", errors="surrogateescape")
    require(re.search(r"^# Arch: arm64$", map_text, re.MULTILINE) and not OTHER_PLAYER.search(map_text),
            "Aether map architecture or native player isolation failed")
    return link_map, map_bytes, map_text


def inspect_app(args, resolved, resolution_bytes):
    architecture = "arm64"
    normalize = native_normalizer()
    native_bytes = read_bounded(args.native_receipt)
    native = json.loads(native_bytes)
    contents = args.app / "Contents" if args.key == "macos" else args.app
    info = plistlib.loads(read_bounded(contents / "Info.plist"))
    app_binary = contents / ("MacOS" if args.key == "macos" else "") / info["CFBundleExecutable"]
    require(run("xcrun", "lipo", "-archs", app_binary) == architecture and
            native["executableSha256"] == sha256(app_binary), "Aether evidence is not from the accepted arm64 app")
    frameworks = contents / "Frameworks"
    kit = frameworks / "VortXAetherKit.framework/VortXAetherKit"
    require(run("xcrun", "lipo", "-archs", kit) == architecture, "Aether kit is not arm64")
    require(not re.search(r"VortXAetherKit\.framework/|AetherLib\w+\.framework/",
                          run("otool", "-L", app_binary)),
            "main executable must load Aether only at runtime")
    kit_libraries = run("otool", "-L", kit)
    require("@rpath/AetherLibavcodec.framework/" in kit_libraries and
            not re.search(r"@rpath/(?:Libmpv|Libav(?:codec|filter|format|util))[^/]*\.framework/", kit_libraries) and
            not re.search(r"\b_dovi_", run("nm", "-u", kit)),
            "Aether lacks isolated dynamic FFmpeg or has unresolved Dolby Vision calls")

    binaries = {}
    for name in ("VortXAetherKit", *FRAMEWORKS):
        binary = (frameworks / f"{name}.framework" / name).resolve(strict=True)
        relative = binary.relative_to(args.app.resolve(strict=True)).as_posix()
        arches = sorted(run("xcrun", "lipo", "-archs", binary).split())
        require(architecture in arches, f"embedded {name} cannot load on arm64")
        normalized = normalize(binary)
        require(native["bundlePayload"][relative] == {"sha256": normalized},
                f"actual embedded {name} bytes differ from the native receipt")
        binaries[name] = {"path": relative, "architectures": arches, "rawSha256": sha256(binary),
                          "normalizedSha256": normalized}

    link_map, map_bytes, map_text = inspect_link_map(args)
    product, linked = link_output(args, link_map, map_text)
    if args.key == "macos":
        verify_macos_signing(args, resolution_bytes, link_map, map_bytes, product, linked, normalize,
                             binaries["VortXAetherKit"], native["executableSha256"])
    else:
        bind_link_output(args, product, linked, normalize, binaries["VortXAetherKit"]["normalizedSha256"])
    provider = admit_provider(args, architecture, map_text)
    return {**identity(), "key": args.key, "architecture": architecture,
            "resolutionReceiptSha256": hashlib.sha256(resolution_bytes).hexdigest(),
            "packageResolvedSha256": resolved["packageResolvedSha256"],
            "nativeAppReceiptSha256": hashlib.sha256(native_bytes).hexdigest(),
            "aetherLinkMapSha256": hashlib.sha256(map_bytes).hexdigest(),
            "provider": provider, "binaries": binaries}


def link_output(args, link_map, map_text):
    path_lines = re.findall(r"^# Path: (.+)$", map_text, re.MULTILINE)
    require(len(path_lines) == 1 and map_text.startswith(f"# Path: {path_lines[0]}\n"),
            "missing or ambiguous Aether link output path")
    products = (args.derived / "Build/Products").resolve(strict=True)
    app_directory = args.app.parent.resolve(strict=True)
    require(app_directory.parent == products, "app and kit are not sibling products of the current build")
    framework = app_directory / "VortXAetherKit.framework"
    product = (framework / "VortXAetherKit").resolve(strict=True)
    require(product.is_relative_to(framework) and product.name == "VortXAetherKit",
            "compiled Aether kit escapes its exact framework product")
    linked_path = Path(path_lines[0])
    require(linked_path.is_absolute(), "Aether link output path must be absolute")
    linked = linked_path.resolve(strict=True)
    # Xcode can link directly into the product or into this target's arm64 intermediate.
    # In both cases, independently compare the product to the embedded kit.
    object_output = link_map.parent / "Objects-normal/arm64/Binary/VortXAetherKit"
    require(linked in (product, object_output) and linked.is_file(),
            "Aether link output is outside the exact product or target-owned arm64 intermediate")
    return product, linked


def bind_link_output(args, product, linked, normalize, embedded_sha):
    compiled_sha = normalize(product)
    require(linked == product or normalize(linked) == compiled_sha,
            "Aether linked output differs from the compiled product after signature normalization")
    if compiled_sha == embedded_sha:
        return

    # The device copy phase in the protected Release workflow can remove bitcode.
    # Replay only the observed Xcode operation on an owned copy of the exact product.
    require(args.key in DEVICE_KEYS, "Aether simulator embedding changed the normalized compiled product")
    require(0 < product.stat().st_size <= BITCODE_BINARY_LIMIT, "compiled Aether kit exceeds the copy proof bound")
    developer = Path(os.environ["DEVELOPER_DIR"]).resolve(strict=True)
    expected_tool = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/bitcode_strip"
    tool = Path(run("/usr/bin/xcrun", "--find", "bitcode_strip")).resolve(strict=True)
    require(tool == expected_tool.resolve(strict=True) and tool.is_relative_to(developer),
            "bitcode_strip is outside the pinned default Xcode toolchain")
    with tempfile.TemporaryDirectory(prefix="vortx-aether-bitcode-", dir=args.derived) as directory:
        source = Path(directory) / "compiled"
        stripped = Path(directory) / "VortXAetherKit"
        shutil.copyfile(product, source)
        run(tool, source, "-r", "-o", stripped)
        require(stripped.is_file() and not stripped.is_symlink() and
                0 < stripped.stat().st_size <= BITCODE_BINARY_LIMIT,
                "bitcode_strip did not produce a bounded regular Aether kit")
        require(normalize(stripped) == embedded_sha,
                "Aether device embedding differs from the exact Xcode bitcode-strip result")


def private_signing_proof(path):
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    parent = path.parent.resolve(strict=True)
    require(parent.parent == temporary and parent.name.startswith("aether-macos-signing.") and
            not path.parent.is_symlink() and path.name == "receipt.json",
            "Mac Aether signing proof must use its dedicated runner-private directory")
    attributes = parent.stat()
    require(stat.S_ISDIR(attributes.st_mode) and stat.S_IMODE(attributes.st_mode) == 0o700 and
            attributes.st_uid == os.getuid(), "Mac Aether signing proof directory is not private")
    return parent / path.name


def macos_signing_inputs(args, resolution_bytes, link_map, map_bytes, product, linked, normalize):
    derived = Path(__file__).resolve().parents[1] / "app/build/ci-mac"
    app = derived / "Build/Products/Release/VortX.app"
    require(args.derived.resolve(strict=True) == derived and args.app.resolve(strict=True) == app,
            "Mac Aether signing requires the exact protected app and derived products")
    kit = app / "Contents/Frameworks/VortXAetherKit.framework/Versions/A/VortXAetherKit"
    require(kit.is_file() and kit.resolve(strict=True) == kit and
            (kit.parents[2] / "VortXAetherKit").resolve(strict=True) == kit,
            "Mac Aether signing requires the exact embedded versioned kit")
    require(all(path.is_file() and 0 < path.stat().st_size <= BITCODE_BINARY_LIMIT
                for path in (product, linked, kit)), "Mac Aether signing inputs exceed the binary proof bound")
    product_sha = sha256(product)
    linked_sha = product_sha if linked == product else sha256(linked)
    compiled_normalized_sha = normalize(product)
    require(linked == product or normalize(linked) == compiled_normalized_sha,
            "Mac Aether linked output differs from the compiled kit after signature normalization")
    app_attributes = app.stat()
    return {**identity(),
            "resolutionReceiptSha256": hashlib.sha256(resolution_bytes).hexdigest(),
            "aetherLinkMapSha256": hashlib.sha256(map_bytes).hexdigest(),
            "linkMapPath": str(link_map.relative_to(derived)),
            "linkedKitPath": str(linked.relative_to(derived)),
            "compiledKitPath": str(product.relative_to(derived)),
            "linkedKitRawSha256": linked_sha,
            "compiledKitRawSha256": product_sha,
            "compiledKitNormalizedSha256": compiled_normalized_sha,
            "appDevice": app_attributes.st_dev,
            "appInode": app_attributes.st_ino,
            "embeddedKitPath": kit.relative_to(app).as_posix()}, kit


def macos_app_executable(app):
    contents = app / "Contents"
    executable = plistlib.loads(read_bounded(contents / "Info.plist"))["CFBundleExecutable"]
    require(isinstance(executable, str) and re.fullmatch(r"[A-Za-z0-9._-]+", executable) and
            executable not in (".", ".."), "invalid Mac app executable name")
    binary = contents / "MacOS" / executable
    require(binary.is_file() and binary.resolve(strict=True) == binary,
            "Mac app executable must be in the exact signed bundle")
    return binary


def sign_macos(args, resolution_bytes):
    proof = private_signing_proof(args.output)
    require(not proof.exists() and not proof.is_symlink(), "Mac Aether signing proof already exists")
    link_map, map_bytes, map_text = inspect_link_map(args)
    product, linked = link_output(args, link_map, map_text)
    normalize = native_normalizer()
    before, kit = macos_signing_inputs(args, resolution_bytes, link_map, map_bytes, product, linked, normalize)
    pre_sign_sha = sha256(kit)
    require(normalize(kit) == before["compiledKitNormalizedSha256"],
            "Mac embedded Aether kit differs from the compiled kit before signing")
    app = args.app.resolve(strict=True)
    executable = macos_app_executable(app)
    run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    link_map, map_bytes, map_text = inspect_link_map(args)
    product, linked = link_output(args, link_map, map_text)
    after, final_kit = macos_signing_inputs(args, resolution_bytes, link_map, map_bytes, product, linked, normalize)
    require(after == before and final_kit == kit and macos_app_executable(app) == executable,
            "Mac Aether signing inputs changed during signing")
    receipt = {**after, "preSigningKitRawSha256": pre_sign_sha,
               "preSigningKitNormalizedSha256": before["compiledKitNormalizedSha256"],
               "signedKitRawSha256": sha256(final_kit),
               "signedKitNormalizedSha256": normalize(final_kit),
               "signedExecutableRawSha256": sha256(executable)}
    descriptor = os.open(proof, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write("\n")


def verify_macos_signing(args, resolution_bytes, link_map, map_bytes, product, linked, normalize,
                         kit_record, executable_sha):
    proof = private_signing_proof(args.macos_signing_proof)
    attributes = proof.lstat()
    require(stat.S_ISREG(attributes.st_mode) and stat.S_IMODE(attributes.st_mode) == 0o600 and
            attributes.st_uid == os.getuid(), "Mac Aether signing proof is not a private regular file")
    state, kit = macos_signing_inputs(args, resolution_bytes, link_map, map_bytes, product, linked, normalize)
    require(kit_record["path"] == state["embeddedKitPath"] and kit_record["rawSha256"] == sha256(kit),
            "Mac Aether signing proof does not name the accepted embedded kit")
    receipt = json.loads(read_bounded(proof))
    require(isinstance(receipt, dict) and isinstance(receipt.get("preSigningKitRawSha256"), str) and
            re.fullmatch(r"[0-9a-f]{64}", receipt["preSigningKitRawSha256"]),
            "Mac Aether signing proof lacks the original embedded kit digest")
    require(receipt ==
            {**state, "preSigningKitRawSha256": receipt["preSigningKitRawSha256"],
             "preSigningKitNormalizedSha256": state["compiledKitNormalizedSha256"],
             "signedKitRawSha256": kit_record["rawSha256"],
             "signedKitNormalizedSha256": kit_record["normalizedSha256"],
             "signedExecutableRawSha256": executable_sha},
            "Mac Aether signing proof does not bind the current link output and signed app")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resolution-receipt", type=Path)
    parser.add_argument("--key", choices=PLATFORMS)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--derived", type=Path)
    parser.add_argument("--native-receipt", type=Path)
    parser.add_argument("--sign-macos", action="store_true")
    parser.add_argument("--macos-signing-proof", type=Path)
    args = parser.parse_args()
    app_args = (args.resolution_receipt, args.key, args.app, args.derived)
    if args.sign_macos:
        require(args.key == "macos" and all(app_args) and not args.native_receipt and not args.macos_signing_proof,
                "Mac signing requires its exact app inputs and a separate private output")
    else:
        app_args += (args.native_receipt,)
        require(all(app_args) or not any(app_args), "Aether app receipt requires all app inputs")
        require((args.key == "macos") == (args.macos_signing_proof is not None),
                "only Mac Aether verification requires a signing proof")
    resolved = resolution(args)
    if args.key:
        resolution_bytes = read_bounded(args.resolution_receipt)
        require(json.loads(resolution_bytes) == resolved, "SwiftPM pins changed after admission")
        if args.sign_macos:
            sign_macos(args, resolution_bytes)
            print("Protected Mac Aether link output sealed across final signing")
            return
        resolved = inspect_app(args, resolved, resolution_bytes)
    with args.output.open("x") as stream:
        json.dump(resolved, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(f"Protected Apple Aether evidence verified: {args.key or 'resolved packages'}")


if __name__ == "__main__":
    main()
