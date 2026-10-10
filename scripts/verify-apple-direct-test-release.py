#!/usr/bin/env python3
"""Prepare and verify a direct-only local Apple test release (never a package build).

The manifest records retained local build receipts honestly. It contains no GitHub Actions
run/artifact identifiers and cannot promote an install feed. Published assets are checked
against the immutable release ID/tag, retained native payload receipts, package signatures,
and the public route snapshot captured before publication.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from typing import Any, Iterator


SCHEMA_VERSION = 1
REPOSITORY = "VortXTV/VortX"
PROVENANCE_NAME = "VortX-Apple-Local-Test-Provenance.json"
APPLE_MARKER = "vortx-platforms: apple"
DIRECT_MARKER = "vortx-distribution: direct-test"
LATEST_MARKER = "<!-- vortx-channel: latest-beta -->"
BETA_TAG_RE = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)-beta\.(?P<number>\d+)$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
IOS_BUNDLE = "com.stremiox.app.native"
MAC_BUNDLE = "com.stremiox.mac"
EXPECTED_NATIVE_FEATURES = "state,resource-host;server=iOS,tvOS,separate-mac"
REQUIRED_NATIVE_ARCHIVES = frozenset({"libvortx_ffi.a", "Libmpv", "Libavcodec", "Libavformat", "Libplacebo"})
NATIVE_RECEIPT_SUFFIX = {"ios": "ios", "macos": "mac"}


class DirectTestError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DirectTestError(message)


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise DirectTestError(f"cannot read JSON {path.name}: {error}") from error
    require(isinstance(value, dict), f"{path.name} must contain a JSON object")
    return value


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_sha(value: Any, label: str) -> str:
    require(isinstance(value, str) and SHA256_RE.fullmatch(value) is not None,
            f"{label} must be a lower-case SHA-256")
    return value


def checked_commit(value: Any, label: str) -> str:
    require(isinstance(value, str) and COMMIT_RE.fullmatch(value) is not None,
            f"{label} must be a full lower-case commit SHA")
    return value


def tag_version(tag: Any, label: str) -> str:
    match = re.fullmatch(r"v(?P<version>\d+\.\d+\.\d+)(?:-[0-9A-Za-z.]+)?", tag) if isinstance(tag, str) else None
    require(match is not None, f"{label} has an invalid release tag")
    return match.group("version")


def release_markers(body: Any) -> list[str]:
    require(isinstance(body, str), "release body must be text")
    return [line.strip() for line in body.replace("\r", "").splitlines()]


def validate_release_identity(release: dict[str, Any], *, expected_tag: str | None = None,
                              expected_release_id: int | None = None,
                              published: bool) -> tuple[str, str, int]:
    tag = release.get("tag_name")
    match = BETA_TAG_RE.fullmatch(tag) if isinstance(tag, str) else None
    require(match is not None, "direct Apple test releases require a strict vX.Y.Z-beta.N tag")
    version = match.group("version")
    release_id = release.get("id")
    require(isinstance(release_id, int) and not isinstance(release_id, bool) and release_id > 0,
            "release ID must be a positive immutable GitHub release ID")
    require(release.get("prerelease") is True, "direct Apple test release must remain a prerelease")
    require(release.get("draft") is (not published),
            "release draft/published state differs from the requested operation")
    if published:
        require(isinstance(release.get("published_at"), str) and release["published_at"],
                "published release lacks published_at")
    else:
        require(not release.get("published_at"), "draft release unexpectedly has published_at")
    if expected_tag is not None:
        require(tag == expected_tag, "immutable release tag differs from the event tag")
    if expected_release_id is not None:
        require(release_id == expected_release_id, "immutable release ID differs from the manifest")
    markers = release_markers(release.get("body", ""))
    require(markers.count(APPLE_MARKER) == 1, f"release body must contain exactly one line: {APPLE_MARKER}")
    require(markers.count(DIRECT_MARKER) == 1, f"release body must contain exactly one line: {DIRECT_MARKER}")
    require(not any("vortx-channel: latest-beta" in line for line in markers),
            "direct Apple test release cannot carry the latest-beta channel marker")
    return tag, version, release_id


def parse_github_release_asset(url: Any, label: str) -> tuple[str, str]:
    require(isinstance(url, str), f"{label} URL must be text")
    parsed = urllib.parse.urlparse(url)
    pieces = parsed.path.split("/")
    require(parsed.scheme == "https" and parsed.netloc == "github.com" and
            parsed.username is None and parsed.password is None and not parsed.query and not parsed.fragment,
            f"{label} URL must be an immutable public GitHub release URL")
    try:
        marker = pieces.index("download")
        tag, name = pieces[marker + 1], pieces[marker + 2]
    except (ValueError, IndexError) as error:
        raise DirectTestError(f"{label} URL is not a GitHub release asset URL") from error
    require(marker == len(pieces) - 3 and pieces[1:3] == REPOSITORY.split("/") and
            pieces[3] == "releases" and name,
            f"{label} URL has an unexpected release-asset path")
    return tag, name


def _fetch(url: str, *, method: str = "GET") -> tuple[bytes, dict[str, str], str, int]:
    request = urllib.request.Request(url, method=method, headers={"User-Agent": "VortX-direct-test-release-verifier"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read() if method != "HEAD" else b""
            headers = {key.lower(): value for key, value in response.headers.items()}
            return body, headers, response.geturl(), response.status
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise DirectTestError(f"public route unavailable: {url} ({error})") from error


def _fetch_json(url: str) -> tuple[dict[str, Any], dict[str, str]]:
    raw, headers, _, status = _fetch(url)
    require(status == 200, f"public JSON route returned HTTP {status}: {url}")
    require("application/json" in headers.get("content-type", "").lower(),
            f"public route is not JSON: {url}")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise DirectTestError(f"public route is invalid JSON: {url}") from error
    require(isinstance(value, dict), f"public route must return a JSON object: {url}")
    return value, headers


def _appcast_entry(entry: Any, label: str) -> dict[str, Any]:
    require(isinstance(entry, dict), f"existing appcast is missing {label}")
    tag, asset = parse_github_release_asset(entry.get("url"), f"appcast {label}")
    require(entry.get("ipa") == entry.get("url"), f"appcast {label} aliases differ")
    version = entry.get("version")
    platform, suffix, artifact_type = {
        "ios": ("iOS", "ipa", "ipa"), "tvos": ("tvOS", "ipa", "ipa"), "mac": ("macOS", "dmg", "dmg")
    }[label]
    require(isinstance(version, str) and re.fullmatch(r"\d+\.\d+\.\d+", version) is not None and
            asset == f"VortX-{platform}-{tag}-ci.{suffix}" and entry.get("artifactType") == artifact_type,
            f"appcast {label} is not the expected platform/tag asset")
    sha = checked_sha(entry.get("sha256"), f"appcast {label} sha256")
    size = entry.get("size")
    require(isinstance(size, int) and size > 0, f"appcast {label} size is invalid")
    require(version == tag_version(tag, f"appcast {label}"),
            f"appcast {label} version differs from its release tag")
    return {"tag": tag, "version": version, "build": str(entry.get("build", "")),
            "asset": asset, "sha256": sha, "size": size, "artifactType": entry.get("artifactType")}


def capture_public_routes(direct_tag: str) -> dict[str, Any]:
    """Capture stable release/platform identities, not transient text or a hard-coded old tag."""
    appcast, appcast_headers = _fetch_json("https://vortx.tv/appcast.json")
    source, source_headers = _fetch_json("https://vortx.tv/altstore.json")
    compatibility, compatibility_headers = _fetch_json("https://vortx.tv/vortx-altstore.json")
    require(source == compatibility, "canonical and compatibility AltStore routes differ")
    generation = appcast_headers.get("x-vortx-feed-generation", "")
    require(generation and generation == source_headers.get("x-vortx-feed-generation", "") ==
            compatibility_headers.get("x-vortx-feed-generation", ""),
            "appcast and AltStore routes lack one coherent feed generation")
    appcast_tag = appcast.get("_generatedFromTag")
    require(isinstance(appcast_tag, str) and appcast_tag and appcast_tag != direct_tag,
            "the feed already points at this direct-only tag")
    apple = {key: _appcast_entry(appcast.get(key), f"{key}") for key in ("ios", "tvos", "mac")}
    require(all(entry["tag"] == appcast_tag for entry in apple.values()),
            "existing appcast Apple assets do not share its generated tag")
    android_raw = appcast.get("android")
    android: dict[str, Any] | None = None
    if android_raw is not None:
        require(isinstance(android_raw, dict), "existing appcast Android field is malformed")
        android = {}
        for flavor in ("full", "play"):
            entry = android_raw.get(flavor)
            require(isinstance(entry, dict), f"existing appcast Android {flavor} field is malformed")
            tag, asset = parse_github_release_asset(entry.get("url"), f"appcast Android {flavor}")
            engine = "mpv" if flavor == "full" else "media3"
            version = entry.get("version")
            apk_name = f"VortX-{version}-{flavor}-{engine}-universal.apk"
            require(tag != direct_tag and entry.get("flavor") == flavor and entry.get("engine") == engine and
                    entry.get("artifactType") == "apk" and asset == apk_name and
                    version == tag_version(tag, f"appcast Android {flavor}") and
                    isinstance(entry.get("size"), int) and entry["size"] > 0,
                    f"existing appcast Android {flavor} route is not independent of the direct test release")
            android[flavor] = {"tag": tag, "version": version, "asset": asset, "flavor": flavor, "engine": engine,
                               "artifactType": entry.get("artifactType"),
                               "sha256": checked_sha(entry.get("sha256"), f"appcast Android {flavor} sha256"),
                               "size": entry.get("size")}
    apps = source.get("apps")
    require(isinstance(apps, list), "canonical AltStore source has no apps[]")
    source_apps: dict[str, Any] = {}
    for bundle in (IOS_BUNDLE, "com.stremiox.tv"):
        matching = [app for app in apps if isinstance(app, dict) and app.get("bundleIdentifier") == bundle]
        require(len(matching) == 1 and isinstance(matching[0].get("versions"), list) and matching[0]["versions"],
                f"canonical AltStore source is missing current {bundle} metadata")
        entry = matching[0]["versions"][0]
        tag, asset = parse_github_release_asset(entry.get("downloadURL"), f"AltStore {bundle}")
        require(tag != direct_tag, "AltStore source unexpectedly references the direct test tag")
        source_apps[bundle] = {"tag": tag, "asset": asset, "build": str(entry.get("buildVersion", "")),
                               "sha256": checked_sha(entry.get("sha256"), f"AltStore {bundle} sha256")}
    require(source_apps[IOS_BUNDLE]["tag"] == appcast_tag and source_apps["com.stremiox.tv"]["tag"] == appcast_tag,
            "AltStore Apple entries are not on the existing appcast tag")
    require(source_apps[IOS_BUNDLE]["build"] == apple["ios"]["build"] and
            source_apps["com.stremiox.tv"]["build"] == apple["tvos"]["build"] and
            source_apps[IOS_BUNDLE]["sha256"] == apple["ios"]["sha256"] and
            source_apps["com.stremiox.tv"]["sha256"] == apple["tvos"]["sha256"],
            "AltStore Apple metadata differs from the existing appcast")
    _, _, final_url, status = _fetch("https://dl.vortx.tv/", method="HEAD")
    require(status in (200, 206), f"existing Android download route returned HTTP {status}")
    dl_tag, dl_asset = parse_github_release_asset(final_url, "dl.vortx.tv")
    require(dl_tag != direct_tag and re.fullmatch(r"VortX-[0-9.]+-full-mpv-universal\.apk", dl_asset) is not None,
            "dl.vortx.tv must remain an Android Full/MPV APK route, not an Apple asset")
    return {
        "feedGeneration": generation,
        "appcast": {"tag": appcast_tag, "apple": apple, "android": android},
        "altstore": source_apps,
        "download": {"platform": "android", "tag": dl_tag, "asset": dl_asset,
                     "flavor": "full", "engine": "mpv"},
    }


def validate_route_snapshot(snapshot: Any, direct_tag: str) -> dict[str, Any]:
    require(isinstance(snapshot, dict), "pre-publication public route snapshot must be a JSON object")
    require(set(snapshot) == {"feedGeneration", "appcast", "altstore", "download"},
            "route snapshot contains unexpected fields")
    appcast = snapshot.get("appcast")
    altstore = snapshot.get("altstore")
    download = snapshot.get("download")
    generation = snapshot.get("feedGeneration")
    require(isinstance(generation, str) and generation, "route snapshot lacks a feed generation")
    require(isinstance(appcast, dict) and set(appcast) == {"tag", "apple", "android"} and
            isinstance(appcast.get("tag"), str) and appcast["tag"] != direct_tag,
            "route snapshot appcast must retain another published tag")
    apple = appcast.get("apple")
    require(isinstance(apple, dict) and set(apple) == {"ios", "tvos", "mac"},
            "route snapshot must contain the existing iOS, tvOS and Mac feed routes")
    expected_assets = {"ios": ("iOS", "ipa"), "tvos": ("tvOS", "ipa"), "mac": ("macOS", "dmg")}
    for platform, item in apple.items():
        slug, suffix = expected_assets[platform]
        require(isinstance(item, dict) and set(item) == {"tag", "version", "build", "asset", "sha256", "size", "artifactType"} and
                item.get("tag") == appcast["tag"] and item.get("tag") != direct_tag,
                f"route snapshot {platform} feed does not retain the existing generated tag")
        require(item.get("artifactType") == ("dmg" if platform == "mac" else "ipa"),
                f"route snapshot {platform} feed artifact type is invalid")
        require(isinstance(item.get("build"), str) and item["build"].isdigit() and item.get("version"),
                f"route snapshot {platform} feed version/build is invalid")
        require(item.get("version") == tag_version(item["tag"], f"route snapshot {platform}") and
                item.get("asset") == f"VortX-{slug}-{item['tag']}-ci.{suffix}" and
                isinstance(item.get("size"), int) and item["size"] > 0,
                f"route snapshot {platform} feed asset/version/size is invalid")
        checked_sha(item.get("sha256"), f"route snapshot {platform} feed hash")
    require(isinstance(altstore, dict) and set(altstore) == {IOS_BUNDLE, "com.stremiox.tv"},
            "route snapshot must contain the existing iOS and tvOS AltStore entries")
    for bundle, item in altstore.items():
        require(isinstance(item, dict) and set(item) == {"tag", "asset", "build", "sha256"} and
                item.get("tag") == appcast["tag"] and item.get("tag") != direct_tag and
                isinstance(item.get("build"), str) and item["build"].isdigit(),
                f"route snapshot AltStore entry for {bundle} is invalid")
    require(altstore[IOS_BUNDLE]["build"] == apple["ios"]["build"] and
            altstore["com.stremiox.tv"]["build"] == apple["tvos"]["build"] and
            altstore[IOS_BUNDLE]["asset"] == apple["ios"]["asset"] and
            altstore["com.stremiox.tv"]["asset"] == apple["tvos"]["asset"] and
            altstore[IOS_BUNDLE]["sha256"] == apple["ios"]["sha256"] and
            altstore["com.stremiox.tv"]["sha256"] == apple["tvos"]["sha256"],
            "route snapshot AltStore metadata differs from appcast")
    download_match = re.fullmatch(r"VortX-(\d+\.\d+\.\d+)-full-mpv-universal\.apk",
                                  download.get("asset", "") if isinstance(download, dict) else "")
    require(isinstance(download, dict) and set(download) == {"platform", "tag", "asset", "flavor", "engine"} and
            download.get("platform") == "android" and
            download.get("tag") != direct_tag and isinstance(download.get("tag"), str) and
            download.get("flavor") == "full" and download.get("engine") == "mpv" and
            download_match is not None and tag_version(download["tag"], "dl.vortx.tv") == download_match.group(1),
            "route snapshot must retain a separate Android Full/MPV APK route")
    android = appcast.get("android")
    require(android is None or (isinstance(android, dict) and set(android) == {"full", "play"}),
            "route snapshot appcast Android metadata is malformed or references the direct-only tag")
    if android is not None:
        for flavor, item in android.items():
            require(isinstance(item, dict), f"route snapshot appcast Android {flavor} metadata is malformed")
            require(set(item) == {"tag", "version", "asset", "flavor", "engine", "artifactType", "sha256", "size"},
                    f"route snapshot appcast Android {flavor} metadata has unexpected fields")
            engine = "mpv" if flavor == "full" else "media3"
            expected_asset = f"VortX-{tag_version(item.get('tag'), f'appcast Android {flavor}')}-{flavor}-{engine}-universal.apk"
            require(item.get("tag") != direct_tag and item.get("flavor") == flavor and
                    item.get("engine") == engine and item.get("artifactType") == "apk" and
                    item.get("asset") == expected_asset and item.get("version") == tag_version(item.get("tag"), f'appcast Android {flavor}') and
                    isinstance(item.get("size"), int) and item["size"] > 0,
                    f"route snapshot appcast Android {flavor} metadata is malformed")
            checked_sha(item.get("sha256"), f"route snapshot appcast Android {flavor} hash")
    return snapshot


def _native_module() -> Any:
    path = Path(__file__).with_name("verify-native-apple-package.py")
    spec = importlib.util.spec_from_file_location("vortx_native_package", path)
    require(spec is not None and spec.loader is not None, "cannot load the existing Apple package verifier")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NATIVE = _native_module()


def validate_bundle_payload(payload: Any, platform: str) -> dict[str, Any]:
    require(isinstance(payload, dict) and payload, f"accepted {platform} receipt has no bundle payload hashes")
    for relative, value in payload.items():
        relative_path = PurePosixPath(relative) if isinstance(relative, str) else None
        require(relative_path is not None and not relative_path.is_absolute() and relative_path.parts and
                ".." not in relative_path.parts and isinstance(value, dict),
                f"accepted {platform} bundle payload contains an unsafe relative path")
        if set(value) == {"sha256"}:
            checked_sha(value["sha256"], f"accepted {platform} payload {relative}")
        else:
            require(set(value) == {"symlink"} and isinstance(value.get("symlink"), str),
                    f"accepted {platform} payload {relative} is malformed")
            target = PurePosixPath(value["symlink"])
            require(not target.is_absolute(), f"accepted {platform} payload {relative} has an absolute symlink")
            resolved = list(relative_path.parent.parts)
            for part in target.parts:
                if part in ("", "."):
                    continue
                if part == "..":
                    require(bool(resolved), f"accepted {platform} payload {relative} symlink escapes the app")
                    resolved.pop()
                else:
                    resolved.append(part)
    return payload


def _portable_receipt(receipt: dict[str, Any], platform: str) -> dict[str, Any]:
    require(receipt.get("schema") == 1 and receipt.get("platform") == platform,
            f"accepted {platform} app receipt has the wrong schema/platform")
    required = ("engineSourceRevision", "bundleIdentifier", "version", "build", "executableSha256",
                "unsignedExecutableSha256", "bundlePayload", "linkMapSha256", "loadedArchives")
    for field in required:
        require(field in receipt, f"accepted {platform} app receipt lacks {field}")
    bundle_payload = validate_bundle_payload(receipt["bundlePayload"], platform)
    loaded = receipt["loadedArchives"]
    loaded_names = {name for name in loaded if isinstance(name, str)} if isinstance(loaded, dict) else set()
    missing_archives = sorted(REQUIRED_NATIVE_ARCHIVES - loaded_names)
    require(not missing_archives,
            f"accepted {platform} app receipt lacks required engine/player archives: {missing_archives}")
    safe_loaded: dict[str, str] = {}
    for name, value in sorted(loaded.items()):
        require(isinstance(name, str) and Path(name).name == name and isinstance(value, dict),
                "native archive receipt is malformed")
        safe_loaded[name] = checked_sha(value.get("sha256"), f"{platform} archive {name}")
    return {"schema": 1, "platform": platform, "engineSourceRevision": receipt["engineSourceRevision"],
            "bundleIdentifier": receipt["bundleIdentifier"], "version": receipt["version"],
            "build": str(receipt["build"]), "executableSha256": checked_sha(receipt["executableSha256"], "executable hash"),
            "unsignedExecutableSha256": checked_sha(receipt["unsignedExecutableSha256"], "unsigned executable hash"),
            "bundlePayload": bundle_payload, "linkMapSha256": checked_sha(receipt["linkMapSha256"], "link-map hash"),
            "loadedArchives": safe_loaded}


def _check_engine_input_binding(input_manifest: dict[str, Any], receipts: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    require(input_manifest.get("schema") == 1, "native input manifest has an unsupported schema")
    require(input_manifest.get("features") == EXPECTED_NATIVE_FEATURES,
            "native input feature declaration differs from the reviewed native package contract")
    revision = checked_commit(input_manifest.get("engineSourceRevision"), "engine SDK source revision")
    entries = input_manifest.get("inputs")
    require(isinstance(entries, list) and entries, "native input manifest has no inputs")
    by_key: dict[tuple[str, str, str], dict[str, Any]] = {}
    sanitized: list[dict[str, Any]] = []
    for item in entries:
        require(isinstance(item, dict), "native input manifest entry is malformed")
        kind, slice_name, target = item.get("kind"), item.get("slice"), item.get("target")
        digest = checked_sha(item.get("sha256"), "native input hash")
        path = Path(item.get("path", ""))
        require(path.is_file() and sha256_file(path) == digest,
                f"retained build input no longer matches its captured hash ({kind}/{slice_name})")
        key = (str(kind), str(slice_name), str(target or ""))
        require(key not in by_key, f"duplicate native input entry {key}")
        by_key[key] = item
        sanitized_item: dict[str, Any] = {"kind": kind, "slice": slice_name, "sha256": digest}
        if target is not None:
            sanitized_item["target"] = target
        if item.get("unsignedSha256") is not None:
            sanitized_item["unsignedSha256"] = checked_sha(item["unsignedSha256"], "unsigned server hash")
        sanitized.append(sanitized_item)
    for platform in ("ios", "macos"):
        engine_slice = NATIVE.ENGINE_SLICES[platform]
        player_slice = NATIVE.MPV_SLICES[platform]
        engine = by_key.get(("engine", engine_slice, ""))
        require(engine is not None, f"accepted {platform} engine SDK slice is missing")
        require(receipts[platform]["engineSourceRevision"] == revision,
                f"accepted {platform} app receipt engine revision differs from the input manifest")
        for archive, digest in receipts[platform]["loadedArchives"].items():
            if archive == "libvortx_ffi.a":
                expected = engine
            else:
                targets = [target for target, name in NATIVE.MPV_TARGETS.items() if name == archive]
                require(len(targets) == 1, f"unknown linked player archive {archive}")
                expected = by_key.get(("mpv", player_slice, targets[0]))
            require(expected is not None and expected["sha256"] == digest,
                    f"accepted {platform} linker receipt differs from the captured SDK hash for {archive}")
    return sorted(sanitized, key=lambda row: (row["kind"], row["slice"] or "", row.get("target", "")))


def _recheck_native_app_receipts(run_dir: Path, input_manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Re-run the existing native acceptance checks against retained originals and link maps."""
    layouts = {
        "ios": ("DerivedData-iOS/Build/Products/Release-iphoneos/VortXiOSNative.app",
                "DerivedData-iOS/Build/Intermediates.noindex/VortX.build/Release-iphoneos/"
                "VortXiOSNative.build/VortXiOSNative-arm64.map"),
        "macos": ("DerivedData-mac/Build/Products/Release/VortX.app",
                  "DerivedData-mac/Build/Intermediates.noindex/VortX.build/Release/"
                  "VortXMac.build/VortX-arm64.map"),
    }
    receipts: dict[str, dict[str, Any]] = {}
    for platform, (app_relative, map_relative) in layouts.items():
        suffix = NATIVE_RECEIPT_SUFFIX[platform]
        app = run_dir / app_relative
        link_map = run_dir / map_relative
        require(app.is_dir(), f"retained original {platform} app is missing; refusing receipt-only attestation")
        require(link_map.is_file(), f"retained original {platform} link map is missing; refusing receipt-only attestation")
        recorded = read_json(run_dir / f"native-{suffix}.json")
        try:
            rechecked = NATIVE.verify_app(input_manifest, app, platform, link_map)
        except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
            raise DirectTestError(f"fresh native {platform} app/link-map verification failed: {error}") from error
        require(rechecked == recorded,
                f"fresh native {platform} app/link-map receipt differs from the retained accepted receipt")
        receipts[platform] = recorded
    return receipts


def _validate_artifact_receipt(run_dir: Path, platform: str, version: str, build: str,
                               engine_revision: str) -> dict[str, Any]:
    require(platform in NATIVE_RECEIPT_SUFFIX, f"unsupported native package platform: {platform}")
    suffix = NATIVE_RECEIPT_SUFFIX[platform]
    package_receipt_path = run_dir / f"native-package-{suffix}.json"
    app_receipt_path = run_dir / f"native-{suffix}.json"
    package_receipt = read_json(package_receipt_path)
    raw_app_receipt = read_json(app_receipt_path)
    portable = _portable_receipt(raw_app_receipt, platform)
    bundle = IOS_BUNDLE if platform == "ios" else MAC_BUNDLE
    expected_name = f"VortX-{('iOS' if platform == 'ios' else 'macOS')}-{version}-{build}-test.{('ipa' if platform == 'ios' else 'dmg')}"
    artifact_path = run_dir / "out" / expected_name
    require(artifact_path.is_file(), f"retained {platform} test artifact is missing")
    actual_sha = sha256_file(artifact_path)
    require(package_receipt.get("schema") == 1 and package_receipt.get("artifact") == expected_name and
            package_receipt.get("artifactSha256") == actual_sha, f"retained {platform} package receipt differs from artifact bytes")
    require(package_receipt.get("build") == build and package_receipt.get("version") == version and
            package_receipt.get("platform") == platform and package_receipt.get("bundleIdentifier") == bundle and
            package_receipt.get("engineSourceRevision") == engine_revision,
            f"retained {platform} package receipt identity is incoherent")
    require(portable["engineSourceRevision"] == engine_revision and portable["version"] == version and
            portable["build"] == build and portable["bundleIdentifier"] == bundle,
            f"accepted {platform} app receipt differs from the package receipt")
    return {"name": expected_name, "size": artifact_path.stat().st_size, "sha256": actual_sha,
            "platform": platform, "bundleIdentifier": bundle, "version": version, "build": build,
            "architecture": "arm64", "signatureMode": "unsigned-resign-required" if platform == "ios" else "adhoc",
            "notarization": "not-notarized" if platform == "macos" else "not-applicable",
            "packageReceiptSha256": sha256_file(package_receipt_path),
            "acceptedAppReceiptSha256": sha256_file(app_receipt_path),
            "acceptedAppReceipt": portable}


def _assert_ancestor(repo_root: Path, source_commit: str, release_commit: str) -> None:
    require(COMMIT_RE.fullmatch(source_commit) is not None and COMMIT_RE.fullmatch(release_commit) is not None,
            "build source and release commits must be full immutable hashes")
    head = subprocess.run(["git", "-C", str(repo_root), "rev-parse", "HEAD"], text=True,
                          capture_output=True, check=False)
    require(head.returncode == 0 and head.stdout.strip() == release_commit,
            "checked-out release verifier source does not equal the release tag commit")
    ancestor = subprocess.run(["git", "-C", str(repo_root), "merge-base", "--is-ancestor", source_commit, release_commit],
                              text=True, capture_output=True, check=False)
    require(ancestor.returncode == 0, "package source commit is not an ancestor of the release-tag commit")


def _check_local_tag(repo_root: Path, tag: str, release_commit: str) -> None:
    resolved = subprocess.run(["git", "-C", str(repo_root), "rev-parse", f"refs/tags/{tag}^{{commit}}"],
                              text=True, capture_output=True, check=False)
    require(resolved.returncode == 0 and resolved.stdout.strip() == release_commit,
            "local release tag does not resolve to the supplied immutable release commit")


def create_manifest(release: dict[str, Any], release_commit: str, run_dir: Path,
                    repo_root: Path) -> dict[str, Any]:
    tag, version, release_id = validate_release_identity(release, published=False)
    release_commit = checked_commit(release_commit, "release-tag commit")
    source_commit = checked_commit((run_dir / "source-revision.txt").read_text().strip(), "build source commit")
    require(source_commit == release_commit,
            "local Apple build source commit must exactly equal the release tag commit")
    _check_local_tag(repo_root, tag, release_commit)
    _assert_ancestor(repo_root, source_commit, release_commit)
    inputs_path = run_dir / "native-build-inputs.json"
    inputs = read_json(inputs_path)
    fresh_receipts = _recheck_native_app_receipts(run_dir, inputs)
    portable_receipts = {platform: _portable_receipt(receipt, platform)
                         for platform, receipt in fresh_receipts.items()}
    input_hashes = _check_engine_input_binding(inputs, portable_receipts)
    engine_revision = inputs["engineSourceRevision"]
    ios_build = str(read_json(run_dir / "native-package-ios.json").get("build"))
    mac_build = str(read_json(run_dir / "native-package-mac.json").get("build"))
    ios = _validate_artifact_receipt(run_dir, "ios", version, ios_build, engine_revision)
    mac = _validate_artifact_receipt(run_dir, "macos", version, mac_build, engine_revision)
    require(ios["build"] == mac["build"], "iOS and Mac packages must use the same numeric build")
    inspect_artifact(run_dir / "out" / ios["name"], ios, "ios")
    inspect_artifact(run_dir / "out" / mac["name"], mac, "macos")
    route_snapshot = validate_route_snapshot(capture_public_routes(tag), tag)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "distribution": "direct-test-only",
        "provenanceKind": "local-retained-native-build-receipts",
        "repository": REPOSITORY,
        "release": {"id": release_id, "tag": tag, "commit": release_commit, "version": version,
                    "prerelease": True},
        "build": {"sourceCommit": source_commit, "version": version, "number": ios["build"],
                  "execution": "local", "engineSourceRevision": engine_revision},
        "engineInputs": {"manifestSha256": sha256_file(inputs_path), "features": inputs.get("features"),
                         "engineSourceRevision": engine_revision, "hashes": input_hashes},
        "targets": ["ios", "macos"],
        "excludedTargets": ["tvos", "android"],
        "feedPolicy": {"promotion": False, "sourceMutation": False, "routesMustRemain": route_snapshot},
        "artifacts": {"ios": ios, "macos": mac},
    }


def _validate_manifest_shape(manifest: dict[str, Any], release: dict[str, Any], release_commit: str) -> tuple[str, str]:
    release_commit = checked_commit(release_commit, "release-tag commit")
    require(set(manifest) == {"schemaVersion", "distribution", "provenanceKind", "repository", "release",
                             "build", "engineInputs", "targets", "excludedTargets", "feedPolicy", "artifacts"},
            "manifest contains unexpected fields")
    manifest_release = manifest.get("release")
    require(isinstance(manifest_release, dict), "manifest lacks release identity")
    tag, version, release_id = validate_release_identity(release, expected_tag=manifest_release.get("tag"),
                                                        expected_release_id=manifest_release.get("id"),
                                                        published=True)
    require(manifest.get("schemaVersion") == SCHEMA_VERSION and manifest.get("distribution") == "direct-test-only" and
            manifest.get("provenanceKind") == "local-retained-native-build-receipts" and
            manifest.get("repository") == REPOSITORY, "manifest is not a supported local direct-test attestation")
    rel = manifest.get("release")
    build = manifest.get("build")
    require(isinstance(rel, dict) and isinstance(build, dict), "manifest lacks release/build identity")
    require(set(rel) == {"id", "tag", "commit", "version", "prerelease"} and
            set(build) == {"sourceCommit", "version", "number", "execution", "engineSourceRevision"},
            "manifest release/build identity contains unexpected fields")
    require(rel.get("id") == release_id and rel.get("tag") == tag and rel.get("version") == version and
            rel.get("commit") == release_commit and rel.get("prerelease") is True,
            "manifest release ID/tag/commit differs from the immutable published release")
    source_commit = checked_commit(build.get("sourceCommit"), "manifest build source commit")
    require(source_commit == release_commit,
            "manifest build source commit must exactly equal the release tag commit")
    require(build.get("execution") == "local" and build.get("version") == version and
            isinstance(build.get("number"), str) and build["number"].isdigit(),
            "manifest must describe the actual local build/version")
    engine = checked_commit(build.get("engineSourceRevision"), "manifest engine source revision")
    engine_inputs = manifest.get("engineInputs")
    require(isinstance(engine_inputs, dict) and
            set(engine_inputs) == {"manifestSha256", "features", "engineSourceRevision", "hashes"} and
            engine == engine_inputs.get("engineSourceRevision") and
            engine_inputs.get("features") == EXPECTED_NATIVE_FEATURES,
            "engine source revision differs from the recorded input manifest")
    require(manifest.get("targets") == ["ios", "macos"] and manifest.get("excludedTargets") == ["tvos", "android"],
            "direct-test manifest must claim only iOS and macOS and explicitly exclude tvOS/Android")
    feed_policy = manifest.get("feedPolicy")
    require(isinstance(feed_policy, dict) and set(feed_policy) == {"promotion", "sourceMutation", "routesMustRemain"} and
            feed_policy.get("promotion") is False and
            feed_policy.get("sourceMutation") is False,
            "direct-test manifest may not promote or mutate public feeds")
    snapshot = validate_route_snapshot(feed_policy.get("routesMustRemain"), tag)
    artifacts = manifest.get("artifacts")
    require(isinstance(artifacts, dict) and set(artifacts) == {"ios", "macos"},
            "manifest must contain exactly iOS and macOS artifacts")
    expected = {"ios": (IOS_BUNDLE, "ipa", "unsigned-resign-required", "not-applicable"),
                "macos": (MAC_BUNDLE, "dmg", "adhoc", "not-notarized")}
    for platform, (bundle, extension, signature, notarization) in expected.items():
        item = artifacts[platform]
        require(isinstance(item, dict) and set(item) == {"name", "size", "sha256", "platform", "bundleIdentifier",
                "version", "build", "architecture", "signatureMode", "notarization", "packageReceiptSha256",
                "acceptedAppReceiptSha256", "acceptedAppReceipt"},
                f"manifest {platform} artifact is malformed")
        basename = item.get("name")
        require(isinstance(basename, str) and Path(basename).name == basename and
                basename == f"VortX-{('iOS' if platform == 'ios' else 'macOS')}-{version}-{build['number']}-test.{extension}",
                f"manifest {platform} asset name is not the expected build artifact")
        require(item.get("platform") == platform and item.get("bundleIdentifier") == bundle and
                item.get("version") == version and item.get("build") == build["number"] and
                item.get("architecture") == "arm64" and item.get("signatureMode") == signature and
                item.get("notarization") == notarization,
                f"manifest {platform} platform/content/signature metadata is invalid")
        require(isinstance(item.get("size"), int) and item["size"] > 0,
                f"manifest {platform} artifact size is invalid")
        checked_sha(item.get("sha256"), f"manifest {platform} artifact SHA-256")
        checked_sha(item.get("packageReceiptSha256"), f"manifest {platform} package receipt SHA-256")
        checked_sha(item.get("acceptedAppReceiptSha256"), f"manifest {platform} accepted-app receipt SHA-256")
        portable = item.get("acceptedAppReceipt")
        require(isinstance(portable, dict) and set(portable) == {"schema", "platform", "engineSourceRevision",
                "bundleIdentifier", "version", "build", "executableSha256", "unsignedExecutableSha256",
                "bundlePayload", "linkMapSha256", "loadedArchives"} and portable.get("schema") == 1 and
                portable.get("platform") == platform and
                portable.get("bundleIdentifier") == bundle and portable.get("version") == version and
                portable.get("build") == build["number"] and portable.get("engineSourceRevision") == engine,
                f"manifest {platform} accepted-content receipt identity is incoherent")
        validate_bundle_payload(portable.get("bundlePayload"), platform)
        for digest in (portable.get("executableSha256"), portable.get("unsignedExecutableSha256"), portable.get("linkMapSha256")):
            checked_sha(digest, f"manifest {platform} accepted receipt hash")
        require(isinstance(portable.get("loadedArchives"), dict) and portable["loadedArchives"],
                f"manifest {platform} accepted receipt has no linker archives")
        require(REQUIRED_NATIVE_ARCHIVES.issubset(portable["loadedArchives"]),
                f"manifest {platform} accepted receipt lacks required engine/player archives")
        for name, digest in portable["loadedArchives"].items():
            require(isinstance(name, str) and Path(name).name == name, "manifest archive name leaks a path")
            checked_sha(digest, f"manifest {platform} linked archive hash")
    checked_sha(engine_inputs.get("manifestSha256"), "engine input-manifest SHA-256")
    input_index: dict[tuple[str, str, str], str] = {}
    hashes = engine_inputs.get("hashes")
    require(isinstance(hashes, list) and hashes, "manifest omits retained SDK input hashes")
    for item in hashes:
        require(isinstance(item, dict) and "path" not in item and
                set(item).issubset({"kind", "slice", "sha256", "target", "unsignedSha256"}) and
                {"kind", "slice", "sha256"}.issubset(item),
                "engine input hashes may not publish local filesystem paths or unknown fields")
        digest = checked_sha(item.get("sha256"), "engine input SHA-256")
        key = (str(item.get("kind")), str(item.get("slice")), str(item.get("target") or ""))
        require(key not in input_index, f"manifest duplicates engine input {key}")
        input_index[key] = digest
    for platform, engine_slice, player_slice in (
            ("ios", NATIVE.ENGINE_SLICES["ios"], NATIVE.MPV_SLICES["ios"]),
            ("macos", NATIVE.ENGINE_SLICES["macos"], NATIVE.MPV_SLICES["macos"])):
        receipt_archives = artifacts[platform]["acceptedAppReceipt"]["loadedArchives"]
        engine_hash = input_index.get(("engine", engine_slice, ""))
        require(engine_hash is not None and receipt_archives.get("libvortx_ffi.a") == engine_hash,
                f"manifest {platform} engine receipt differs from accepted SDK input hashes")
        for archive, digest in receipt_archives.items():
            if archive == "libvortx_ffi.a":
                continue
            targets = [target for target, name in NATIVE.MPV_TARGETS.items() if name == archive]
            require(len(targets) == 1 and input_index.get(("mpv", player_slice, targets[0])) == digest,
                    f"manifest {platform} player receipt differs from accepted SDK input hashes for {archive}")
    return tag, source_commit


@contextmanager
def open_app(artifact: Path, platform: str) -> Iterator[Path]:
    with tempfile.TemporaryDirectory(prefix="vortx-direct-apple-verify-") as temporary:
        root = Path(temporary).resolve()
        mounted = False
        if platform == "ios":
            require(artifact.suffix == ".ipa", "iOS direct-test artifact must be an IPA")
            with zipfile.ZipFile(artifact) as archive:
                for item in archive.infolist():
                    destination = (root / item.filename).resolve()
                    require(destination.is_relative_to(root), "IPA entry escapes its extraction root")
                    mode = item.external_attr >> 16
                    if mode & 0o170000 == 0o120000:
                        link = archive.read(item).decode("utf-8")
                        link_target = (destination.parent / link).resolve()
                        require(link_target.is_relative_to(root), "IPA symlink escapes its extraction root")
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.symlink_to(link)
                    else:
                        archive.extract(item, root)
            apps = list((root / "Payload").glob("*.app"))
        else:
            require(platform == "macos" and artifact.suffix == ".dmg", "macOS direct-test artifact must be a DMG")
            mount = root / "mount"
            mount.mkdir()
            subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(artifact)],
                           check=True, text=True, capture_output=True)
            mounted = True
            apps = list(mount.glob("*.app"))
        try:
            require(len(apps) == 1, f"{platform} package must contain exactly one app")
            yield apps[0]
        finally:
            if mounted:
                subprocess.run(["hdiutil", "detach", str(root / "mount")], check=True,
                               text=True, capture_output=True)


def inspect_artifact(path: Path, item: dict[str, Any], platform: str) -> None:
    require(path.is_file() and path.stat().st_size == item["size"] and sha256_file(path) == item["sha256"],
            f"published {platform} artifact size/SHA differs from local build receipt")
    accepted = item["acceptedAppReceipt"]
    with open_app(path, platform) as app:
        NATIVE.verify_packaged_copy(accepted, app, platform)
        contents = app / "Contents" if platform == "macos" else app
        info_path = contents / "Info.plist"
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        require(info.get("CFBundleIdentifier") == item["bundleIdentifier"] and
                info.get("CFBundleShortVersionString") == item["version"] and
                str(info.get("CFBundleVersion")) == item["build"],
                f"published {platform} bundle identity/version/build differs from its manifest")
        if platform == "ios":
            require(info.get("UIDeviceFamily") == [1, 2], "iOS IPA must support both iPhone and iPad")
            require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "iOS IPA is not a device build")
            require(_version_tuple(info.get("MinimumOSVersion")) == _version_tuple(NATIVE.FLOORS["ios"]),
                    "iOS deployment floor differs from the accepted minimum")
            require(not any(part.name == "_CodeSignature" for part in app.rglob("_CodeSignature")) and
                    not any(part.name == "embedded.mobileprovision" for part in app.rglob("embedded.mobileprovision")),
                    "iOS test IPA is expected to be unsigned for normal re-signing/sideload")
            diag = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], text=True,
                                  capture_output=True, check=False)
            require(diag.returncode != 0, "iOS test IPA unexpectedly carries a code signature")
        else:
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True,
                           text=True, capture_output=True)
            diag = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], text=True,
                                  capture_output=True, check=False)
            detail = diag.stdout + diag.stderr
            require(diag.returncode == 0 and re.search(r"(?m)^Signature=adhoc\s*$", detail) is not None and
                    re.search(r"(?m)^Authority=", detail) is None,
                    "Mac DMG must contain a valid ad-hoc-signed app, not a distribution identity")
            require(_version_tuple(info.get("LSMinimumSystemVersion")) == _version_tuple(NATIVE.FLOORS["macos"]),
                    "Mac deployment floor differs from the accepted minimum")
        executable = info.get("CFBundleExecutable")
        require(isinstance(executable, str) and executable and Path(executable).name == executable,
                f"{platform} bundle executable name is invalid")
        binary = contents / "MacOS" / executable if platform == "macos" else contents / executable
        archs = subprocess.run(["lipo", "-archs", str(binary)], check=True, text=True,
                               capture_output=True).stdout.strip().split()
        require(archs == ["arm64"], f"{platform} executable architecture is not exactly arm64")


def _version_tuple(value: Any) -> tuple[int, ...]:
    require(isinstance(value, str) and re.fullmatch(r"\d+(?:\.\d+){1,2}", value) is not None,
            "bundle deployment version is malformed")
    return tuple(int(part) for part in value.split("."))


def verify_published(release: dict[str, Any], manifest: dict[str, Any], release_commit: str,
                     repo_root: Path, provenance_file: Path, asset_dir: Path) -> None:
    tag, source_commit = _validate_manifest_shape(manifest, release, release_commit)
    _check_local_tag(repo_root, tag, release_commit)
    require(source_commit == release_commit,
            "manifest build source commit must exactly equal the release tag commit")
    _assert_ancestor(repo_root, source_commit, release_commit)
    require(release_commit == subprocess.run(["git", "-C", str(repo_root), "rev-parse", "HEAD"],
            text=True, capture_output=True, check=True).stdout.strip(),
            "release event checkout differs from the tag commit")
    require(read_json(provenance_file) == manifest, "parsed provenance differs from the downloaded provenance asset")
    assets = release.get("assets")
    require(isinstance(assets, list), "published release has no assets[]")
    names = [asset.get("name") for asset in assets if isinstance(asset, dict)]
    require(len(names) == len(assets) and len(names) == len(set(names)),
            "published release has malformed or duplicate assets")
    provenance_records = [asset for asset in assets if asset.get("name") == PROVENANCE_NAME]
    require(len(provenance_records) == 1 and provenance_records[0].get("state") == "uploaded",
            "published release must contain exactly one uploaded local provenance asset")
    provenance_asset = provenance_records[0]
    require(provenance_asset.get("size") == provenance_file.stat().st_size and
            sha256_file(provenance_file) == _asset_sha(release, PROVENANCE_NAME),
            "published provenance asset differs from immutable release metadata")
    expected_provenance_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{PROVENANCE_NAME}"
    require(provenance_asset.get("browser_download_url") == expected_provenance_url,
            "published provenance asset URL is not tag-bound")
    expected_names = {PROVENANCE_NAME, manifest["artifacts"]["ios"]["name"], manifest["artifacts"]["macos"]["name"]}
    observed_names = [asset.get("name") for asset in assets if isinstance(asset, dict)]
    require(len(observed_names) == len(assets) and len(observed_names) == len(set(observed_names)) and
            set(observed_names) == expected_names,
            "direct-test release must contain exactly its provenance, iOS IPA and Mac DMG (no tvOS/APK assets)")
    for platform in ("ios", "macos"):
        item = manifest["artifacts"][platform]
        asset_name = item["name"]
        asset_record = next(asset for asset in assets if asset["name"] == asset_name)
        require(asset_record.get("state") == "uploaded" and asset_record.get("size") == item["size"] and
                _normalize_github_digest(asset_record.get("digest")) == item["sha256"],
                f"GitHub release metadata differs from local {platform} artifact receipt")
        expected_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{asset_name}"
        require(asset_record.get("browser_download_url") == expected_url,
                f"published {platform} asset URL is not tag-bound")
        artifact_path = asset_dir / asset_name
        inspect_artifact(artifact_path, item, platform)
    current_routes = capture_public_routes(tag)
    require(current_routes == manifest["feedPolicy"]["routesMustRemain"],
            "appcast, AltStore or Android /dl route changed since the direct-test release was prepared")


def _normalize_github_digest(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return value.lower().removeprefix("sha256:")


def _asset_sha(release: dict[str, Any], asset_name: str) -> str:
    assets = release.get("assets")
    require(isinstance(assets, list), "release metadata has no assets[]")
    selected = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == asset_name]
    require(len(selected) == 1 and selected[0].get("state") == "uploaded",
            f"published release must contain exactly one uploaded {asset_name}")
    return _normalize_github_digest(selected[0].get("digest"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare", help="build truthful local provenance from retained Apple package receipts")
    prepare.add_argument("--release-json", type=Path, required=True, help="exact existing GitHub draft release JSON")
    prepare.add_argument("--release-commit", required=True, help="full commit resolved from the local release tag")
    prepare.add_argument("--build-dir", type=Path, required=True, help="retained local Apple build/package receipt directory")
    prepare.add_argument("--repo-root", type=Path, default=Path.cwd())
    prepare.add_argument("--output", type=Path, required=True)
    verify = commands.add_parser("verify-published", help="read-only post-publication content/provenance/route verification")
    verify.add_argument("--release-json", type=Path, required=True)
    verify.add_argument("--provenance", type=Path, required=True)
    verify.add_argument("--asset-dir", type=Path, required=True)
    verify.add_argument("--release-commit", required=True)
    verify.add_argument("--repo-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            release = read_json(args.release_json)
            validate_release_identity(release, published=False)
            manifest = create_manifest(release, args.release_commit, args.build_dir, args.repo_root)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(canonical_json(manifest))
            print(f"PASS: generated local direct-test provenance for {manifest['release']['tag']} build {manifest['build']['number']}")
        else:
            release = read_json(args.release_json)
            manifest = read_json(args.provenance)
            verify_published(release, manifest, args.release_commit, args.repo_root, args.provenance, args.asset_dir)
            print(f"PASS: published direct-test release {manifest['release']['id']} verified (no feed writes)")
        return 0
    except (DirectTestError, OSError, KeyError, TypeError, subprocess.CalledProcessError,
            zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
