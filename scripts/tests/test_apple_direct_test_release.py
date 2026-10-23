#!/usr/bin/env python3
"""Contract tests for the read-only local Apple direct-test release lane."""
import copy
import importlib.util
import io
import json
import plistlib
import tempfile
import unittest
import warnings
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.error import HTTPError

SCRIPT_PATH = Path(__file__).parents[1] / "verify-apple-direct-test-release.py"
SPEC = importlib.util.spec_from_file_location("apple_direct_test_release", SCRIPT_PATH)
DIRECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIRECT)


def route_snapshot(tag="v0.5.0-beta.3"):
    def entry(platform, build):
        key, suffix = {"iOS": ("ios", "ipa"), "tvOS": ("tvos", "ipa"), "macOS": ("mac", "dmg")}[platform]
        return {"tag": tag, "version": "0.5.0", "build": str(build),
                "asset": f"VortX-{platform}-{tag}-ci.{suffix}",
                "sha256": "a" * 64, "size": 100, "artifactType": "dmg" if key == "mac" else "ipa"}

    return {
        "feedGeneration": "release-feed-generation-123",
        "appcast": {"tag": tag, "apple": {"ios": entry("iOS", 263), "tvos": entry("tvOS", 263), "mac": entry("macOS", 263)},
                    "android": None},
        "altstore": {
            DIRECT.IOS_BUNDLE: {"tag": tag, "asset": f"VortX-iOS-{tag}-ci.ipa", "build": "263", "sha256": "a" * 64},
            "com.stremiox.tv": {"tag": tag, "asset": f"VortX-tvOS-{tag}-ci.ipa", "build": "263", "sha256": "a" * 64},
        },
        "download": {"platform": "android", "tag": "v0.4.0-beta.21",
                     "asset": "VortX-0.4.0-full-mpv-universal.apk", "flavor": "full", "engine": "mpv"},
    }


def app_receipt(platform, bundle, engine):
    archive_hashes = {"Libmpv": "a", "Libavcodec": "b", "Libavformat": "c", "Libplacebo": "d"}
    loaded = {"libvortx_ffi.a": "f" * 64}
    for archive, character in archive_hashes.items():
        loaded[archive] = character * 64
    return {"schema": 1, "platform": platform, "engineSourceRevision": engine, "bundleIdentifier": bundle,
            "version": "0.5.0", "build": "264", "executableSha256": "b" * 64,
            "unsignedExecutableSha256": "c" * 64, "linkMapSha256": "d" * 64,
            "bundlePayload": {"Info.plist": {"sha256": "e" * 64}},
            "loadedArchives": loaded}


def direct_input_hashes(platforms=("ios", "macos")):
    hashes = []
    archive_hashes = {"Libmpv": "a", "Libavcodec": "b", "Libavformat": "c", "Libplacebo": "d"}
    for platform in platforms:
        engine_slice = DIRECT.NATIVE.ENGINE_SLICES[platform]
        player_slice = DIRECT.NATIVE.MPV_SLICES[platform]
        hashes.append({"kind": "engine", "slice": engine_slice, "sha256": "f" * 64})
        hashes.append({"kind": "header", "slice": engine_slice, "sha256": "1" * 64})
        for target, archive in DIRECT.NATIVE.MPV_TARGETS.items():
            if archive in archive_hashes:
                hashes.append({"kind": "mpv", "slice": player_slice, "target": target,
                               "sha256": archive_hashes[archive] * 64})
    return hashes


def valid_manifest(release_commit="2" * 40, build_source=None):
    build_source = release_commit if build_source is None else build_source
    engine = "3" * 40
    artifacts = {}
    for platform, slug, bundle, extension, signature, notarization in (
            ("ios", "iOS", DIRECT.IOS_BUNDLE, "ipa", "unsigned-resign-required", "not-applicable"),
            ("macos", "macOS", DIRECT.MAC_BUNDLE, "dmg", "adhoc", "not-notarized")):
        name = f"VortX-{slug}-0.5.0-264-test.{extension}"
        artifacts[platform] = {"name": name, "size": 3, "sha256": "4" * 64, "platform": platform,
                               "bundleIdentifier": bundle, "version": "0.5.0", "build": "264",
                               "architecture": "arm64", "signatureMode": signature, "notarization": notarization,
                               "packageReceiptSha256": "5" * 64, "acceptedAppReceiptSha256": "6" * 64,
                               "acceptedAppReceipt": app_receipt(platform, bundle, engine)}
    return {"schemaVersion": 1, "distribution": "direct-test-only",
            "provenanceKind": "local-retained-native-build-receipts", "repository": "VortXTV/VortX",
            "release": {"id": 123, "tag": "v0.5.0-beta.4", "commit": release_commit,
                        "version": "0.5.0", "prerelease": True},
            "build": {"sourceCommit": build_source, "version": "0.5.0", "number": "264",
                      "execution": "local", "engineSourceRevision": engine},
            "engineInputs": {"manifestSha256": "7" * 64, "features": DIRECT.EXPECTED_NATIVE_FEATURES, "engineSourceRevision": engine,
                             "hashes": direct_input_hashes()},
            "targets": ["ios", "macos"], "excludedTargets": ["tvos", "android"],
            "feedPolicy": {"promotion": False, "sourceMutation": False,
                           "routesMustRemain": route_snapshot()},
            "artifacts": artifacts}


def release_json(manifest, body=None, published=True):
    assets = [{"name": DIRECT.PROVENANCE_NAME, "state": "uploaded", "size": 10,
               "digest": "sha256:" + "8" * 64,
               "browser_download_url": f"https://github.com/VortXTV/VortX/releases/download/{manifest['release']['tag']}/{DIRECT.PROVENANCE_NAME}"}]
    for item in manifest["artifacts"].values():
        assets.append({"name": item["name"], "state": "uploaded", "size": item["size"],
                       "digest": "sha256:" + item["sha256"],
                       "browser_download_url": f"https://github.com/VortXTV/VortX/releases/download/{manifest['release']['tag']}/{item['name']}"})
    return {"id": 123, "tag_name": manifest["release"]["tag"], "draft": not published,
            "prerelease": True, "published_at": "2026-10-10T00:00:00Z" if published else None,
            "body": body or f"Apple only\n{DIRECT.APPLE_MARKER}\n{DIRECT.DIRECT_MARKER}", "assets": assets}


def valid_tv_manifest():
    manifest = valid_manifest()
    manifest.update(schemaVersion=2, targets=["ios", "macos", "tvos", "tvos-lite"], excludedTargets=["android"])
    manifest["engineInputs"]["hashes"] = direct_input_hashes(("ios", "macos", "tvos"))
    for target, slug, bundle in (("tvos", "tvOS", "com.stremiox.tv"),
                                ("tvos-lite", "tvOS-lite", "com.stremiox.tv.lite")):
        item = copy.deepcopy(manifest["artifacts"]["ios"])
        item.update(name=f"VortX-{slug}-0.5.0-264-test.ipa", platform="tvos", bundleIdentifier=bundle,
                    acceptedAppReceipt=app_receipt("tvos", bundle, "3" * 40))
        manifest["artifacts"][target] = item
    return manifest


def tv_ipa(root, target, *, main_changes=None, extension_changes=None, extension=None, extra_files=None):
    """Real ZIP/plist/payload fixture; dummy executables never invoke signature removal."""
    full = target == "tvos"
    bundle = "com.stremiox.tv" if full else "com.stremiox.tv.lite"
    scheme = "vortx" if full else "vortx-lite"
    executable = "VortXTV" if full else "VortXTVLite"
    app = root / (executable + ".app")
    app.mkdir(parents=True)
    info = {"CFBundleIdentifier": bundle, "CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "264",
            "CFBundleExecutable": executable, "UIDeviceFamily": [3], "CFBundleSupportedPlatforms": ["AppleTVOS"],
            "MinimumOSVersion": "18.0", "VortXNativeDataEngine": True, "VortXNativeResourceHost": True,
            "VortXEngineSourceRevision": "3" * 40, "VortXNativeTransport": "in-process" if full else "none",
            "VortXURLScheme": scheme,
            "CFBundleURLTypes": [{"CFBundleURLName": bundle, "CFBundleURLSchemes": [scheme]}]}
    info.update(main_changes or {})
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    (app / executable).write_bytes(b"fixture unsigned TV executable")
    (app / "Assets.car").write_bytes(b"fixture exact accepted resources")
    if (full if extension is None else extension):
        shelf = app / "PlugIns/VortXTopShelf.appex"
        shelf.mkdir(parents=True)
        shelf_info = {"CFBundleIdentifier": "com.stremiox.tv.topshelf", "CFBundleShortVersionString": "0.5.0",
                      "CFBundleVersion": "264", "CFBundleExecutable": "VortXTopShelf", "UIDeviceFamily": [3],
                      "CFBundleSupportedPlatforms": ["AppleTVOS"], "MinimumOSVersion": "18.0",
                      "VortXURLScheme": "vortx", "NSExtension": {
                          "NSExtensionPointIdentifier": "com.apple.tv-top-shelf",
                          "NSExtensionPrincipalClass": "VortXTopShelf.ContentProvider"}}
        shelf_info.update(extension_changes or {})
        (shelf / "Info.plist").write_bytes(plistlib.dumps(shelf_info))
        (shelf / "VortXTopShelf").write_bytes(b"fixture unsigned shelf executable")
    for relative, data in (extra_files or {}).items():
        path = app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    item = valid_tv_manifest()["artifacts"][target]
    item["acceptedAppReceipt"]["bundlePayload"] = DIRECT.NATIVE.bundle_payload(app)
    artifact = root / item["name"]
    with zipfile.ZipFile(artifact, "w") as archive:
        for path in sorted(app.rglob("*")):
            if path.is_file():
                archive.write(path, "Payload/" + str(path.relative_to(root)))
    item.update(size=artifact.stat().st_size, sha256=DIRECT.sha256_file(artifact))
    return artifact, item


def tv_commands(command, **kwargs):
    """Only platform inspection is mocked; extraction and accepted-content hashing are real."""
    if command[0] == "codesign":
        return SimpleNamespace(returncode=1, stdout="", stderr="code object is not signed at all")
    if command[0] == "lipo":
        return SimpleNamespace(returncode=0, stdout="arm64\n", stderr="")
    if command[0] == "otool":
        return SimpleNamespace(returncode=0, stdout=("Load command 1\n      cmd LC_BUILD_VERSION\n"
                                                    "  cmdsize 32\n platform 3\n    minos 18.0\n      sdk 26.5\n"), stderr="")
    if command[0] == "git":
        return SimpleNamespace(returncode=0, stdout="2" * 40, stderr="")
    raise AssertionError(f"unexpected external command: {command}")


class DownloadRedirectTests(unittest.TestCase):
    URL = "https://github.com/VortXTV/VortX/releases/download/v0.4.0-beta.21/VortX-0.4.0-full-mpv-universal.apk"

    def opener(self, location, code=302):
        opener = SimpleNamespace(open=lambda request, timeout: None)
        def open_route(request, timeout):
            self.assertEqual(request.full_url, "https://dl.vortx.tv/")
            self.assertEqual(request.get_method(), "HEAD")
            self.assertEqual(timeout, 20)
            raise HTTPError(request.full_url, code, "fixture", {"Location": location}, None)
        opener.open = open_route
        return opener

    def test_identity_is_first_github_redirect_not_signed_cdn_url(self):
        cdn = "https://release-assets.githubusercontent.com/temporary?signature=fixture"
        with patch.object(DIRECT.urllib.request, "build_opener", return_value=self.opener(self.URL)), \
             patch.object(DIRECT, "_fetch", return_value=(b"", {}, cdn, 200)) as fetch:
            self.assertEqual(DIRECT._download_release_url(), self.URL)
        fetch.assert_called_once_with(self.URL, method="HEAD")
        self.assertIsNone(DIRECT._NoRedirect().redirect_request(None, None, 302, "", {}, self.URL))

    def test_invalid_first_destinations_are_rejected_before_following(self):
        for url in ("https://example.com/asset.apk", self.URL + "?token=bad", "/relative.apk", ""):
            with self.subTest(url=url), \
                 patch.object(DIRECT.urllib.request, "build_opener", return_value=self.opener(url)), \
                 patch.object(DIRECT, "_fetch") as fetch:
                with self.assertRaises(DIRECT.DirectTestError):
                    DIRECT._download_release_url()
                fetch.assert_not_called()

    def test_non_redirect_status_is_rejected(self):
        with patch.object(DIRECT.urllib.request, "build_opener", return_value=self.opener(self.URL, 404)), \
             patch.object(DIRECT, "_fetch") as fetch:
            with self.assertRaisesRegex(DIRECT.DirectTestError, "HTTP 404"):
                DIRECT._download_release_url()
            fetch.assert_not_called()

    def test_asset_reachability_is_still_required(self):
        with patch.object(DIRECT.urllib.request, "build_opener", return_value=self.opener(self.URL)), \
             patch.object(DIRECT, "_fetch", return_value=(b"", {}, self.URL, 403)):
            with self.assertRaisesRegex(DIRECT.DirectTestError, "HTTP 403"):
                DIRECT._download_release_url()


class DirectReleaseIdentityTests(unittest.TestCase):
    def test_release_tag_markers_and_prerelease_are_strict(self):
        release = release_json(valid_manifest(), published=False)
        self.assertEqual(DIRECT.validate_release_identity(release, published=False),
                         ("v0.5.0-beta.4", "0.5.0", 123))
        bad = [
            {"tag_name": "v0.5.0"}, {"tag_name": "v0.5.0-beta.x"}, {"prerelease": False},
            {"id": 0}, {"body": f"{DIRECT.APPLE_MARKER}\ncomment: {DIRECT.DIRECT_MARKER}"},
            {"body": f"{DIRECT.APPLE_MARKER}\n{DIRECT.DIRECT_MARKER}\n{DIRECT.DIRECT_MARKER}"},
            {"body": f"{DIRECT.APPLE_MARKER}\n{DIRECT.DIRECT_MARKER}\n{DIRECT.LATEST_MARKER}"},
        ]
        for change in bad:
            with self.subTest(change=change), self.assertRaises(DIRECT.DirectTestError):
                DIRECT.validate_release_identity({**release, **change}, published=False)

    def test_release_id_and_tag_must_match_immutable_event_values(self):
        release = release_json(valid_manifest())
        with self.assertRaisesRegex(DIRECT.DirectTestError, "event tag"):
            DIRECT.validate_release_identity(release, expected_tag="v0.5.0-beta.5", published=True)
        with self.assertRaisesRegex(DIRECT.DirectTestError, "release ID"):
            DIRECT.validate_release_identity(release, expected_release_id=124, published=True)

    def test_download_url_parser_accepts_only_immutable_release_asset_path(self):
        self.assertEqual(DIRECT.parse_github_release_asset(
            "https://github.com/VortXTV/VortX/releases/download/v0.5.0-beta.3/VortX-iOS-v0.5.0-beta.3-ci.ipa", "fixture"),
            ("v0.5.0-beta.3", "VortX-iOS-v0.5.0-beta.3-ci.ipa"))
        for url in ("http://github.com/VortXTV/VortX/releases/download/tag/file",
                    "https://github.com/VortXTV/VortX/releases/download/tag/file?latest=true",
                    "https://example.com/VortXTV/VortX/releases/download/tag/file",
                    "https://github.com/attacker/repo/releases/download/tag/file"):
            with self.subTest(url=url), self.assertRaises(DIRECT.DirectTestError):
                DIRECT.parse_github_release_asset(url, "fixture")


class DirectReleaseManifestTests(unittest.TestCase):
    def test_manifest_requires_exact_release_tag_source_and_only_two_apple_targets(self):
        manifest = valid_manifest()
        release = release_json(manifest)
        tag, source = DIRECT._validate_manifest_shape(manifest, release, manifest["release"]["commit"])
        self.assertEqual((tag, source), ("v0.5.0-beta.4", manifest["release"]["commit"]))
        self.assertNotIn("runId", manifest)
        self.assertNotIn("artifactId", manifest)
        self.assertEqual(manifest["targets"], ["ios", "macos"])
        self.assertEqual(manifest["excludedTargets"], ["tvos", "android"])

        stale_ancestor = valid_manifest(build_source="1" * 40)
        with self.assertRaisesRegex(DIRECT.DirectTestError, "exactly equal"):
            DIRECT._validate_manifest_shape(stale_ancestor, release_json(stale_ancestor),
                                            stale_ancestor["release"]["commit"])
        with tempfile.TemporaryDirectory(prefix="vortx-exact-source-commit-") as temporary:
            run_dir = Path(temporary)
            (run_dir / "source-revision.txt").write_text("1" * 40)
            with patch.object(DIRECT, "_check_local_tag") as check_tag:
                with self.assertRaisesRegex(DIRECT.DirectTestError, "must exactly equal"):
                    DIRECT.create_manifest(release_json(stale_ancestor, published=False),
                                           stale_ancestor["release"]["commit"], run_dir, run_dir)
                check_tag.assert_not_called()

    def test_manifest_rejects_ci_fiction_feed_mutation_and_mislabeled_signature(self):
        for mutate, reason in (
            (lambda value: value["build"].update(execution="github-actions"), "local"),
            (lambda value: value["targets"].append("tvos"), "claim only iOS and macOS"),
            (lambda value: value["feedPolicy"].update(promotion=True), "may not promote"),
            (lambda value: value["artifacts"]["ios"].update(signatureMode="developer-id"), "signature metadata"),
            (lambda value: value["release"].update(commit="9" * 40), "release ID/tag/commit"),
        ):
            manifest = valid_manifest()
            mutate(manifest)
            with self.subTest(reason=reason), self.assertRaisesRegex(DIRECT.DirectTestError, reason):
                DIRECT._validate_manifest_shape(manifest, release_json(manifest), "2" * 40)

    def test_manifest_rejects_local_paths_in_bundle_receipt(self):
        manifest = valid_manifest()
        manifest["artifacts"]["ios"]["acceptedAppReceipt"]["bundlePayload"] = {
            "Frameworks/Private.framework/Link": {"symlink": "/Users/daksh/private-key"}}
        with self.assertRaisesRegex(DIRECT.DirectTestError, "absolute symlink"):
            DIRECT._validate_manifest_shape(manifest, release_json(manifest), manifest["release"]["commit"])

    def test_generator_reads_canonical_mac_receipt_names_and_strips_paths(self):
        with tempfile.TemporaryDirectory(prefix="vortx-local-package-receipt-") as temporary:
            run_dir = Path(temporary)
            out = run_dir / "out"
            out.mkdir()
            engine = "3" * 40
            for platform, slug, bundle, extension, receipt_suffix in (
                    ("ios", "iOS", DIRECT.IOS_BUNDLE, "ipa", "ios"),
                    ("macos", "macOS", DIRECT.MAC_BUNDLE, "dmg", "mac")):
                name = f"VortX-{slug}-0.5.0-264-test.{extension}"
                artifact = out / name
                artifact.write_bytes(platform.encode())
                raw_receipt = app_receipt(platform, bundle, engine)
                raw_receipt["loadedArchives"] = {
                    archive: {"path": f"/private/SDK/{archive}", "sha256": digest}
                    for archive, digest in (("libvortx_ffi.a", "f" * 64), ("Libmpv", "a" * 64),
                                            ("Libavcodec", "b" * 64), ("Libavformat", "c" * 64),
                                            ("Libplacebo", "d" * 64))}
                (run_dir / f"native-{receipt_suffix}.json").write_text(json.dumps(raw_receipt))
                package_receipt = {"schema": 1, "artifact": name, "artifactSha256": DIRECT.sha256_file(artifact),
                                   "build": "264", "version": "0.5.0", "platform": platform,
                                   "bundleIdentifier": bundle, "engineSourceRevision": engine}
                (run_dir / f"native-package-{receipt_suffix}.json").write_text(json.dumps(package_receipt))
                result = DIRECT._validate_artifact_receipt(run_dir, platform, "0.5.0", "264", engine)
                self.assertEqual(result["name"], name)
                self.assertEqual(result["signatureMode"], "adhoc" if platform == "macos" else "unsigned-resign-required")
                self.assertEqual(set(result["acceptedAppReceipt"]["loadedArchives"]), DIRECT.REQUIRED_NATIVE_ARCHIVES)

    def test_portable_receipt_rejects_missing_required_player_archives(self):
        for missing in ("Libmpv", "Libavcodec", "Libavformat", "Libplacebo"):
            raw = app_receipt("ios", DIRECT.IOS_BUNDLE, "3" * 40)
            del raw["loadedArchives"][missing]
            with self.subTest(missing=missing), self.assertRaisesRegex(
                    DIRECT.DirectTestError, "lacks required engine/player archives"):
                DIRECT._portable_receipt(raw, "ios")

    def test_native_recheck_uses_retained_app_and_link_map_and_compares_receipts(self):
        with tempfile.TemporaryDirectory(prefix="vortx-native-retained-recheck-") as temporary:
            run_dir = Path(temporary)
            expected = {}
            for platform, bundle, receipt_name, app_path, map_path in (
                    ("ios", DIRECT.IOS_BUNDLE, "native-ios.json",
                     "DerivedData-iOS/Build/Products/Release-iphoneos/VortXiOSNative.app",
                     "DerivedData-iOS/Build/Intermediates.noindex/VortX.build/Release-iphoneos/"
                     "VortXiOSNative.build/VortXiOSNative-arm64.map"),
                    ("macos", DIRECT.MAC_BUNDLE, "native-mac.json",
                     "DerivedData-mac/Build/Products/Release/VortX.app",
                     "DerivedData-mac/Build/Intermediates.noindex/VortX.build/Release/"
                     "VortXMac.build/VortX-arm64.map")):
                (run_dir / app_path).mkdir(parents=True)
                map_file = run_dir / map_path
                map_file.parent.mkdir(parents=True)
                map_file.write_bytes(b"retained linker map")
                expected[platform] = app_receipt(platform, bundle, "3" * 40)
                (run_dir / receipt_name).write_text(json.dumps(expected[platform]))

            with patch.object(DIRECT.NATIVE, "verify_app", side_effect=lambda manifest, app, platform, link_map:
                              expected[platform]) as verify_app:
                receipts = DIRECT._recheck_native_app_receipts(run_dir, {"schema": 1})
            self.assertEqual(receipts, expected)
            self.assertEqual(verify_app.call_count, 2)
            self.assertEqual(verify_app.call_args_list[0].args[2], "ios")
            self.assertEqual(verify_app.call_args_list[1].args[2], "macos")

            changed = dict(expected["ios"], executableSha256="9" * 64)
            with patch.object(DIRECT.NATIVE, "verify_app", side_effect=[changed, expected["macos"]]):
                with self.assertRaisesRegex(DIRECT.DirectTestError, "differs from the retained accepted receipt"):
                    DIRECT._recheck_native_app_receipts(run_dir, {"schema": 1})

        with tempfile.TemporaryDirectory(prefix="vortx-native-retained-missing-") as temporary:
            with self.assertRaisesRegex(DIRECT.DirectTestError, "original ios app is missing"):
                DIRECT._recheck_native_app_receipts(Path(temporary), {"schema": 1})

    def test_manifest_preparation_rechecks_both_local_package_contents(self):
        manifest = valid_manifest()
        with tempfile.TemporaryDirectory(prefix="vortx-direct-manifest-prepare-") as temporary:
            run_dir = Path(temporary)
            (run_dir / "out").mkdir()
            (run_dir / "source-revision.txt").write_text("2" * 40)
            (run_dir / "native-build-inputs.json").write_text(json.dumps({
                "schema": 1, "engineSourceRevision": "3" * 40,
                "features": DIRECT.EXPECTED_NATIVE_FEATURES, "inputs": [{"fixture": True}]}))
            for platform in ("ios", "macos"):
                suffix = "ios" if platform == "ios" else "mac"
                (run_dir / f"native-{suffix}.json").write_text("{}")
                (run_dir / f"native-package-{suffix}.json").write_text(json.dumps({"build": "264"}))
            artifacts = manifest["artifacts"]
            with patch.object(DIRECT, "_check_local_tag"), patch.object(DIRECT, "_assert_ancestor"), \
                 patch.object(DIRECT, "_recheck_native_app_receipts", return_value={"ios": {}, "macos": {}}), \
                 patch.object(DIRECT, "_portable_receipt", side_effect=lambda receipt, platform: artifacts[platform]["acceptedAppReceipt"]), \
                 patch.object(DIRECT, "_check_engine_input_binding", return_value=manifest["engineInputs"]["hashes"]), \
                 patch.object(DIRECT, "_validate_artifact_receipt", side_effect=lambda directory, platform, version, build, revision: artifacts[platform]), \
                 patch.object(DIRECT, "capture_public_routes", return_value=manifest["feedPolicy"]["routesMustRemain"]), \
                 patch.object(DIRECT, "inspect_artifact") as inspect:
                result = DIRECT.create_manifest(release_json(manifest, published=False), "2" * 40, run_dir, Path("."))
            self.assertEqual(result["build"]["number"], "264")
            self.assertEqual([call.args[2] for call in inspect.call_args_list], ["ios", "macos"])

    def test_prepare_cli_prints_tag_and_reports_source_errors_cleanly(self):
        manifest = valid_manifest()
        release = release_json(manifest, published=False)
        with tempfile.TemporaryDirectory(prefix="vortx-direct-prepare-cli-") as temporary:
            root = Path(temporary)
            release_path = root / "release.json"
            release_path.write_text(json.dumps(release))
            output = root / "out" / "provenance.json"
            args = ["prepare", "--release-json", str(release_path), "--release-commit",
                    manifest["release"]["commit"], "--build-dir", str(root), "--repo-root", str(root),
                    "--output", str(output)]
            stdout = io.StringIO()
            with patch.object(DIRECT, "create_manifest", return_value=manifest), redirect_stdout(stdout):
                self.assertEqual(DIRECT.main(args), 0)
            self.assertIn(manifest["release"]["tag"], stdout.getvalue())
            self.assertEqual(json.loads(output.read_text()), manifest)

            output.unlink()
            stderr = io.StringIO()
            mismatch = DIRECT.DirectTestError("local Apple build source commit must exactly equal the release tag commit")
            with patch.object(DIRECT, "create_manifest", side_effect=mismatch), redirect_stderr(stderr):
                self.assertEqual(DIRECT.main(args), 1)
            self.assertIn("must exactly equal", stderr.getvalue())
            self.assertFalse(output.exists())

    def test_route_snapshot_is_platform_semantic_and_rejects_direct_tag_or_invalid_dl(self):
        snapshot = route_snapshot()
        self.assertIs(DIRECT.validate_route_snapshot(snapshot, "v0.5.0-beta.4"), snapshot)
        bad = route_snapshot()
        bad["download"]["platform"] = "ios"
        with self.assertRaisesRegex(DIRECT.DirectTestError, "Android Full/MPV APK"):
            DIRECT.validate_route_snapshot(bad, "v0.5.0-beta.4")
        bad = route_snapshot("v0.5.0-beta.4")
        with self.assertRaisesRegex(DIRECT.DirectTestError, "another published tag"):
            DIRECT.validate_route_snapshot(bad, "v0.5.0-beta.4")

    def test_postpublish_verifier_checks_exact_asset_bytes_and_unchanged_routes(self):
        manifest = valid_manifest()
        release = release_json(manifest)
        with tempfile.TemporaryDirectory(prefix="vortx-direct-release-test-") as temporary:
            root = Path(temporary)
            provenance = root / "provenance.json"
            assets = root / "assets"
            assets.mkdir()
            for platform in ("ios", "macos"):
                item = manifest["artifacts"][platform]
                artifact = assets / item["name"]
                artifact.write_bytes(b"abc")
                self.assertEqual(artifact.stat().st_size, item["size"])
                item["sha256"] = DIRECT.sha256_file(artifact)
                release_asset = next(asset for asset in release["assets"] if asset["name"] == item["name"])
                release_asset["digest"] = "sha256:" + item["sha256"]
            body = DIRECT.canonical_json(manifest)
            provenance.write_bytes(body)
            release["assets"][0]["size"] = len(body)
            release["assets"][0]["digest"] = "sha256:" + DIRECT.sha256_file(provenance)
            with patch.object(DIRECT, "_assert_ancestor"), \
                 patch.object(DIRECT, "_check_local_tag"), \
                 patch.object(DIRECT, "capture_public_routes", return_value=manifest["feedPolicy"]["routesMustRemain"]), \
                 patch.object(DIRECT, "inspect_artifact"), \
                 patch.object(DIRECT.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=manifest["release"]["commit"])):
                DIRECT.verify_published(release, manifest, manifest["release"]["commit"], root, provenance, assets)
            changed = route_snapshot("v0.5.0-beta.2")
            with patch.object(DIRECT, "_assert_ancestor"), patch.object(DIRECT, "_check_local_tag"), \
                 patch.object(DIRECT, "capture_public_routes", return_value=changed), \
                 patch.object(DIRECT, "inspect_artifact"), \
                 patch.object(DIRECT.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=manifest["release"]["commit"])):
                with self.assertRaisesRegex(DIRECT.DirectTestError, "route changed"):
                    DIRECT.verify_published(release, manifest, manifest["release"]["commit"], root, provenance, assets)

    def test_postpublish_verifier_rejects_extra_android_or_tvos_assets_and_bad_digests(self):
        manifest = valid_manifest()
        release = release_json(manifest)
        with tempfile.TemporaryDirectory(prefix="vortx-direct-release-reject-") as temporary:
            root = Path(temporary)
            provenance = root / "provenance.json"
            assets = root / "assets"
            assets.mkdir()
            for platform in ("ios", "macos"):
                item = manifest["artifacts"][platform]
                artifact = assets / item["name"]
                artifact.write_bytes(b"abc")
                item["sha256"] = DIRECT.sha256_file(artifact)
                next(asset for asset in release["assets"] if asset["name"] == item["name"])["digest"] = "sha256:" + item["sha256"]
            provenance.write_bytes(DIRECT.canonical_json(manifest))
            release["assets"][0]["size"] = provenance.stat().st_size
            release["assets"][0]["digest"] = "sha256:" + DIRECT.sha256_file(provenance)
            with patch.object(DIRECT, "_assert_ancestor"), patch.object(DIRECT, "_check_local_tag"), patch.object(DIRECT, "inspect_artifact"), \
                 patch.object(DIRECT, "capture_public_routes", return_value=manifest["feedPolicy"]["routesMustRemain"]), \
                 patch.object(DIRECT.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=manifest["release"]["commit"])):
                release["assets"].append({"name": "VortX-0.5.0-full-mpv-universal.apk"})
                with self.assertRaisesRegex(DIRECT.DirectTestError, "exactly its provenance"):
                    DIRECT.verify_published(release, manifest, manifest["release"]["commit"], root, provenance, assets)
                release["assets"].pop()
                release["assets"][1]["digest"] = "sha256:" + "9" * 64
                with self.assertRaisesRegex(DIRECT.DirectTestError, "GitHub release metadata"):
                    DIRECT.verify_published(release, manifest, manifest["release"]["commit"], root, provenance, assets)


class TVDirectReleaseTests(unittest.TestCase):
    def assert_manifest_rejected(self, mutate):
        manifest = valid_tv_manifest()
        mutate(manifest)
        with self.assertRaises(DIRECT.DirectTestError):
            DIRECT._validate_manifest_shape(manifest, release_json(manifest), "2" * 40)

    def test_schema_two_is_exact_and_both_tv_receipts_use_real_native_platform(self):
        manifest = valid_tv_manifest()
        self.assertEqual(DIRECT._validate_manifest_shape(manifest, release_json(manifest), "2" * 40),
                         ("v0.5.0-beta.4", "2" * 40))
        for target in ("tvos", "tvos-lite"):
            self.assertEqual(manifest["artifacts"][target]["platform"], "tvos")
            self.assertEqual(manifest["artifacts"][target]["acceptedAppReceipt"]["platform"], "tvos")
        mutations = [
            lambda value: value.update(schemaVersion=True), lambda value: value.update(schemaVersion=3),
            lambda value: value.update(schemaVersion=1), lambda value: value["targets"].pop(),
            lambda value: value["targets"].reverse(), lambda value: value["targets"].append("android"),
            lambda value: value.update(excludedTargets=["tvos", "android"]),
            lambda value: value["artifacts"].pop("tvos-lite"),
            lambda value: value["artifacts"].update(android=value["artifacts"]["tvos"]),
            lambda value: value["artifacts"].update(tvos=value["artifacts"]["tvos-lite"]),
            lambda value: value["artifacts"]["tvos-lite"].update(platform="tvos-lite"),
            lambda value: value["artifacts"]["tvos"]["acceptedAppReceipt"].update(platform="tvos-sim"),
            lambda value: value["artifacts"]["tvos"].update(build="265"),
            lambda value: value["artifacts"]["tvos"].update(signatureMode="developer-id"),
            lambda value: value["artifacts"]["tvos"]["acceptedAppReceipt"].update(engineSourceRevision="9" * 40),
            lambda value: value["artifacts"]["tvos-lite"]["acceptedAppReceipt"]["loadedArchives"].update(Libmpv="9" * 64),
            lambda value: value["engineInputs"]["hashes"].extend(value["engineInputs"]["hashes"][-1:]),
            lambda value: value["feedPolicy"].update(sourceMutation=True),
            lambda value: value["build"].update(sourceCommit="9" * 40),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(case=index):
                self.assert_manifest_rejected(mutate)

    def test_both_variants_bind_to_the_same_device_input_bytes(self):
        with tempfile.TemporaryDirectory(prefix="vortx-tv-input-binding-") as temporary:
            root = Path(temporary)
            manifest = valid_tv_manifest()
            receipts = {target: item["acceptedAppReceipt"] for target, item in manifest["artifacts"].items()}
            entries = []
            for index, entry in enumerate(manifest["engineInputs"]["hashes"]):
                path = root / str(index)
                path.write_bytes(f"exact input {index}".encode())
                row = dict(entry, path=str(path), sha256=DIRECT.sha256_file(path))
                entries.append(row)
                for target, receipt in receipts.items():
                    native = "tvos" if target.startswith("tvos") else target
                    if row["kind"] == "engine" and row["slice"] == DIRECT.NATIVE.ENGINE_SLICES[native]:
                        receipt["loadedArchives"]["libvortx_ffi.a"] = row["sha256"]
                    elif row["kind"] == "mpv" and row["slice"] == DIRECT.NATIVE.MPV_SLICES[native]:
                        receipt["loadedArchives"][DIRECT.NATIVE.MPV_TARGETS[row["target"]]] = row["sha256"]
            inputs = {"schema": 1, "features": DIRECT.EXPECTED_NATIVE_FEATURES,
                      "engineSourceRevision": "3" * 40, "inputs": entries}
            result = DIRECT._check_engine_input_binding(inputs, receipts)
            self.assertTrue(all("path" not in item for item in result))
            changed = copy.deepcopy(receipts)
            changed["tvos-lite"]["loadedArchives"]["libvortx_ffi.a"] = "9" * 64
            with self.assertRaisesRegex(DIRECT.DirectTestError, "accepted tvos-lite linker receipt"):
                DIRECT._check_engine_input_binding(inputs, changed)
            Path(entries[-1]["path"]).write_bytes(b"changed after capture")
            with self.assertRaisesRegex(DIRECT.DirectTestError, "no longer matches"):
                DIRECT._check_engine_input_binding(inputs, receipts)

    def test_tv_package_receipts_have_distinct_suffixes_but_native_tvos_identity(self):
        with tempfile.TemporaryDirectory(prefix="vortx-tv-package-receipt-") as temporary:
            root = Path(temporary)
            (root / "out").mkdir()
            for target in ("tvos", "tvos-lite"):
                item = valid_tv_manifest()["artifacts"][target]
                artifact = root / "out" / item["name"]
                artifact.write_bytes(target.encode())
                raw = item["acceptedAppReceipt"]
                raw["loadedArchives"] = {name: {"path": "/private/fixture/" + name, "sha256": digest}
                                         for name, digest in raw["loadedArchives"].items()}
                app_path = root / f"native-{target}.json"
                app_path.write_text(json.dumps(raw))
                package = {"schema": 1, "artifact": item["name"], "artifactSha256": DIRECT.sha256_file(artifact),
                           "platform": "tvos", "bundleIdentifier": item["bundleIdentifier"],
                           "version": "0.5.0", "build": "264", "engineSourceRevision": "3" * 40}
                package_path = root / f"native-package-{target}.json"
                package_path.write_text(json.dumps(package))
                result = DIRECT._validate_artifact_receipt(root, target, "0.5.0", "264", "3" * 40)
                self.assertEqual(result["platform"], "tvos")
                self.assertEqual(result["acceptedAppReceipt"]["platform"], "tvos")
                self.assertEqual(result["acceptedAppReceiptSha256"], DIRECT.sha256_file(app_path))
                self.assertEqual(result["packageReceiptSha256"], DIRECT.sha256_file(package_path))
                self.assertEqual(result["name"], item["name"])
                package["platform"] = target + "-sim"
                package_path.write_text(json.dumps(package))
                with self.assertRaisesRegex(DIRECT.DirectTestError, "identity is incoherent"):
                    DIRECT._validate_artifact_receipt(root, target, "0.5.0", "264", "3" * 40)

    def test_tv_native_recheck_uses_distinct_retained_apps_and_maps_and_compares_full_receipts(self):
        with tempfile.TemporaryDirectory(prefix="vortx-tv-retained-recheck-") as temporary:
            root = Path(temporary)
            expected = {}
            for target in DIRECT.TV_TARGETS:
                app_relative, map_relative = DIRECT.APP_LAYOUTS[target]
                (root / app_relative).mkdir(parents=True)
                map_path = root / map_relative
                map_path.parent.mkdir(parents=True)
                map_path.write_bytes(b"retained exact link map")
                expected[target] = valid_tv_manifest()["artifacts"][target]["acceptedAppReceipt"]
                (root / f"native-{DIRECT.NATIVE_RECEIPT_SUFFIX[target]}.json").write_text(json.dumps(expected[target]))
            with patch.object(DIRECT.NATIVE, "verify_app", side_effect=list(expected.values())) as verify, \
                 patch.object(DIRECT, "_verify_tvos_bundle") as verify_tv:
                self.assertEqual(DIRECT._recheck_native_app_receipts(root, {"schema": 1}, DIRECT.TV_TARGETS), expected)
            self.assertEqual([call.args[2] for call in verify.call_args_list], ["ios", "macos", "tvos", "tvos"])
            self.assertEqual([call.args[1] for call in verify_tv.call_args_list], ["tvos", "tvos-lite"])
            self.assertNotEqual(verify.call_args_list[2].args[3], verify.call_args_list[3].args[3])
            changed = copy.deepcopy(list(expected.values()))
            changed[-1]["linkMapSha256"] = "9" * 64
            with patch.object(DIRECT.NATIVE, "verify_app", side_effect=changed), patch.object(DIRECT, "_verify_tvos_bundle"):
                with self.assertRaisesRegex(DIRECT.DirectTestError, "tvos-lite.*differs from the retained"):
                    DIRECT._recheck_native_app_receipts(root, {"schema": 1}, DIRECT.TV_TARGETS)

    def test_explicit_tv_prepare_rechecks_all_four_and_rejects_divergent_build(self):
        manifest = valid_tv_manifest()
        with tempfile.TemporaryDirectory(prefix="vortx-tv-manifest-prepare-") as temporary:
            root = Path(temporary)
            (root / "source-revision.txt").write_text("2" * 40)
            (root / "native-build-inputs.json").write_text(json.dumps({
                "schema": 1, "features": DIRECT.EXPECTED_NATIVE_FEATURES, "engineSourceRevision": "3" * 40}))
            receipts = {}
            for target, item in manifest["artifacts"].items():
                (root / f"native-package-{DIRECT.NATIVE_RECEIPT_SUFFIX[target]}.json").write_text(json.dumps({"build": "264"}))
                receipts[target] = copy.deepcopy(item["acceptedAppReceipt"])
                receipts[target]["loadedArchives"] = {name: {"path": "/fixture/" + name, "sha256": digest}
                                                     for name, digest in receipts[target]["loadedArchives"].items()}
            def artifact_receipt(directory, target, version, build, revision):
                return dict(manifest["artifacts"][target], build=build)
            with patch.object(DIRECT, "_check_local_tag"), patch.object(DIRECT, "_assert_ancestor"), \
                 patch.object(DIRECT, "_recheck_native_app_receipts", return_value=receipts) as recheck, \
                 patch.object(DIRECT, "_check_engine_input_binding", return_value=manifest["engineInputs"]["hashes"]), \
                 patch.object(DIRECT, "_validate_artifact_receipt", side_effect=artifact_receipt), \
                 patch.object(DIRECT, "capture_public_routes", return_value=manifest["feedPolicy"]["routesMustRemain"]), \
                 patch.object(DIRECT, "inspect_artifact") as inspect:
                result = DIRECT.create_manifest(release_json(manifest, published=False), "2" * 40, root, root,
                                                include_tvos=True)
                self.assertEqual(result["schemaVersion"], 2)
                self.assertEqual(result["targets"], ["ios", "macos", "tvos", "tvos-lite"])
                self.assertEqual(result["excludedTargets"], ["android"])
                self.assertEqual(recheck.call_args.args[2], DIRECT.TV_TARGETS)
                self.assertEqual([call.args[2] for call in inspect.call_args_list], result["targets"])
                (root / "native-package-tvos-lite.json").write_text(json.dumps({"build": "265"}))
                inspect.reset_mock()
                with self.assertRaisesRegex(DIRECT.DirectTestError, "same numeric build"):
                    DIRECT.create_manifest(release_json(manifest, published=False), "2" * 40, root, root,
                                           include_tvos=True)
                inspect.assert_not_called()

    def test_prepare_flag_is_opt_in_and_asset_names_are_validated_before_output(self):
        with tempfile.TemporaryDirectory(prefix="vortx-tv-cli-") as temporary:
            root = Path(temporary)
            release_path, provenance, output = root / "release.json", root / "provenance.json", root / "output.json"
            for flag, manifest in (([], valid_manifest()), (["--include-tvos"], valid_tv_manifest())):
                release_path.write_text(json.dumps(release_json(manifest, published=False)))
                args = ["prepare", "--release-json", str(release_path), "--release-commit", "2" * 40,
                        "--build-dir", str(root), "--repo-root", str(root), "--output", str(output), *flag]
                with patch.object(DIRECT, "create_manifest", return_value=manifest) as create, redirect_stdout(io.StringIO()):
                    self.assertEqual(DIRECT.main(args), 0)
                self.assertEqual(create.call_args.kwargs.get("include_tvos", False), bool(flag))
                self.assertEqual(json.loads(output.read_text())["schemaVersion"], 2 if flag else 1)
            manifest = valid_tv_manifest()
            release_path.write_text(json.dumps(release_json(manifest)))
            provenance.write_bytes(DIRECT.canonical_json(manifest))
            args = ["asset-names", "--release-json", str(release_path), "--provenance", str(provenance),
                    "--release-commit", "2" * 40]
            stdout = io.StringIO()
            with patch.object(DIRECT.subprocess, "run", side_effect=AssertionError("names must be read-only")), \
                 patch.object(DIRECT, "_fetch", side_effect=AssertionError("names must not fetch")), redirect_stdout(stdout):
                self.assertEqual(DIRECT.main(args), 0)
            self.assertEqual(stdout.getvalue().splitlines(), [item["name"] for item in manifest["artifacts"].values()])
            manifest["artifacts"]["tvos-lite"]["name"] = "../../untrusted.ipa"
            provenance.write_bytes(DIRECT.canonical_json(manifest))
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(DIRECT.main(args), 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("expected build artifact", stderr.getvalue())

    def test_four_artifact_postpublish_checks_real_tv_bytes_exact_assets_and_unchanged_routes(self):
        manifest = valid_tv_manifest()
        with tempfile.TemporaryDirectory(prefix="vortx-tv-postpublish-") as temporary:
            root = Path(temporary)
            assets = root / "assets"
            assets.mkdir()
            for target in ("ios", "macos"):
                item = manifest["artifacts"][target]
                path = assets / item["name"]
                path.write_bytes(b"abc")
                item["sha256"] = DIRECT.sha256_file(path)
            for target in ("tvos", "tvos-lite"):
                _, manifest["artifacts"][target] = tv_ipa(assets, target)
            provenance = root / "provenance.json"
            provenance.write_bytes(DIRECT.canonical_json(manifest))
            release = release_json(manifest)
            release["assets"][0].update(size=provenance.stat().st_size, digest="sha256:" + DIRECT.sha256_file(provenance))
            real_inspect = DIRECT.inspect_artifact
            inspected = []
            def inspect(path, item, target):
                inspected.append(target)
                if target.startswith("tvos"):
                    real_inspect(path, item, target)
            with patch.object(DIRECT, "_check_local_tag"), patch.object(DIRECT, "_assert_ancestor"), \
                 patch.object(DIRECT, "inspect_artifact", side_effect=inspect), \
                 patch.object(DIRECT.subprocess, "run", side_effect=tv_commands), \
                 patch.object(DIRECT, "capture_public_routes", return_value=manifest["feedPolicy"]["routesMustRemain"]) as routes:
                DIRECT.verify_published(release, manifest, "2" * 40, root, provenance, assets)
                self.assertEqual(inspected, manifest["targets"])
                pristine = copy.deepcopy(release)
                bad_releases = []
                extra = copy.deepcopy(pristine)
                extra["assets"].append({"name": "extra.apk"})
                bad_releases.append(extra)
                missing = copy.deepcopy(pristine)
                missing["assets"].pop()
                bad_releases.append(missing)
                duplicate = copy.deepcopy(pristine)
                duplicate["assets"].append(duplicate["assets"][-1])
                bad_releases.append(duplicate)
                for field, value in (("digest", "sha256:" + "9" * 64), ("state", "new"), ("size", 1),
                                     ("browser_download_url", "https://github.com/VortXTV/VortX/releases/latest/download/file.ipa")):
                    bad = copy.deepcopy(pristine)
                    bad["assets"][-1][field] = value
                    bad_releases.append(bad)
                for index, bad in enumerate(bad_releases):
                    with self.subTest(release_case=index), self.assertRaises(DIRECT.DirectTestError):
                        DIRECT.verify_published(bad, manifest, "2" * 40, root, provenance, assets)
                routes.return_value = route_snapshot("v0.5.0-beta.2")
                with self.assertRaisesRegex(DIRECT.DirectTestError, "route changed"):
                    DIRECT.verify_published(pristine, manifest, "2" * 40, root, provenance, assets)
                routes.return_value = manifest["feedPolicy"]["routesMustRemain"]
                for body in (f"{DIRECT.APPLE_MARKER}\n{DIRECT.DIRECT_MARKER}\n{DIRECT.LATEST_MARKER}",):
                    bad = dict(pristine, body=body)
                    with self.assertRaises(DIRECT.DirectTestError):
                        DIRECT.verify_published(bad, manifest, "2" * 40, root, provenance, assets)
                with self.assertRaises(DIRECT.DirectTestError):
                    DIRECT.verify_published(dict(pristine, prerelease=False), manifest, "2" * 40, root, provenance, assets)

    def test_real_unsigned_full_and_lite_ipa_payloads_pass_without_signature_removal(self):
        for target in ("tvos", "tvos-lite"):
            with self.subTest(target=target), tempfile.TemporaryDirectory(prefix="vortx-tv-ipa-") as temporary:
                artifact, item = tv_ipa(Path(temporary), target)
                with patch.object(DIRECT.subprocess, "run", side_effect=tv_commands) as run, \
                     patch.object(DIRECT.NATIVE, "run", side_effect=AssertionError("no signature mutation permitted")):
                    DIRECT.inspect_artifact(artifact, item, target)
                inspected = [call.args[0][-1] for call in run.call_args_list if call.args[0][0] == "otool"]
                self.assertEqual(len(inspected), 2 if target == "tvos" else 1)

    def test_tv_ipa_rejects_wrong_self_consistent_variant_metadata(self):
        cases = [
            ("tvos", {"main_changes": {"CFBundleIdentifier": "com.stremiox.tv.lite"}}),
            ("tvos", {"main_changes": {"CFBundleVersion": "265"}}),
            ("tvos", {"main_changes": {"CFBundleExecutable": "VortXTVLite"}}),
            ("tvos", {"main_changes": {"UIDeviceFamily": [1, 2]}}),
            ("tvos", {"main_changes": {"CFBundleSupportedPlatforms": ["AppleTVSimulator"]}}),
            ("tvos", {"main_changes": {"MinimumOSVersion": "17.0"}}),
            ("tvos", {"main_changes": {"VortXEngineSourceRevision": "9" * 40}}),
            ("tvos", {"main_changes": {"VortXNativeTransport": "none"}}),
            ("tvos-lite", {"main_changes": {"VortXNativeTransport": "in-process"}}),
            ("tvos-lite", {"main_changes": {"VortXNativeDataEngine": 1}}),
            ("tvos", {"main_changes": {"VortXNativeResourceHost": False}}),
            ("tvos-lite", {"main_changes": {"VortXURLScheme": "vortx"}}),
            ("tvos", {"main_changes": {"CFBundleURLTypes": []}}),
            ("tvos", {"extension": False}), ("tvos-lite", {"extension": True}),
            ("tvos", {"extension_changes": {"CFBundleIdentifier": "wrong.shelf"}}),
            ("tvos", {"extension_changes": {"CFBundleVersion": "265"}}),
            ("tvos", {"extension_changes": {"CFBundleExecutable": "../VortXTV"}}),
            ("tvos", {"extension_changes": {"CFBundleSupportedPlatforms": ["AppleTVSimulator"]}}),
            ("tvos", {"extension_changes": {"MinimumOSVersion": "17.0"}}),
            ("tvos", {"extension_changes": {"NSExtension": {"NSExtensionPointIdentifier": "wrong"}}}),
            ("tvos", {"extra_files": {"PlugIns/Other.appex/Info.plist": b"extra extension"}}),
            ("tvos-lite", {"extra_files": {"vortx-streaming-server": b"daemon"}}),
            ("tvos", {"extra_files": {"PlugIns/VortXTopShelf.appex/_CodeSignature/CodeResources": b"signed"}}),
            ("tvos-lite", {"extra_files": {"Frameworks/F.framework/embedded.mobileprovision": b"provision"}}),
        ]
        for index, (target, options) in enumerate(cases):
            with self.subTest(case=index), tempfile.TemporaryDirectory(prefix="vortx-tv-invalid-ipa-") as temporary:
                artifact, item = tv_ipa(Path(temporary), target, **options)
                with patch.object(DIRECT.subprocess, "run", side_effect=tv_commands), self.assertRaises(DIRECT.DirectTestError):
                    DIRECT.inspect_artifact(artifact, item, target)

    def test_tv_ipa_rejects_payload_receipt_and_public_byte_tampering(self):
        with tempfile.TemporaryDirectory(prefix="vortx-tv-exact-payload-") as temporary:
            artifact, item = tv_ipa(Path(temporary), "tvos")
            wrong = copy.deepcopy(item)
            wrong["acceptedAppReceipt"]["bundlePayload"]["Assets.car"]["sha256"] = "9" * 64
            with patch.object(DIRECT.subprocess, "run", side_effect=tv_commands):
                with self.assertRaisesRegex(DIRECT.DirectTestError, "accepted payload verification failed"):
                    DIRECT.inspect_artifact(artifact, wrong, "tvos")
                with self.assertRaisesRegex(DIRECT.DirectTestError, "corresponding accepted app receipt"):
                    wrong = copy.deepcopy(item)
                    wrong["acceptedAppReceipt"]["platform"] = "tvos-lite"
                    DIRECT.inspect_artifact(artifact, wrong, "tvos")
                artifact.write_bytes(artifact.read_bytes() + b"changed public bytes")
                with self.assertRaisesRegex(DIRECT.DirectTestError, "size/SHA differs"):
                    DIRECT.inspect_artifact(artifact, item, "tvos")

    def test_tv_binary_checks_reject_simulator_old_sdk_wrong_floor_arch_and_signature(self):
        cases = [("lipo", "arm64 x86_64\n"), ("otool", "platform 8"), ("otool", "minos 17.0"),
                 ("otool", "sdk 26.4"), ("otool", "platform 3\n platform 8"), ("codesign", "signed")]
        for kind, value in cases:
            with self.subTest(kind=kind, value=value), tempfile.TemporaryDirectory(prefix="vortx-tv-binary-policy-") as temporary:
                artifact, item = tv_ipa(Path(temporary), "tvos")
                def commands(command, **kwargs):
                    result = tv_commands(command, **kwargs)
                    if command[0] == kind:
                        if kind == "codesign":
                            return SimpleNamespace(returncode=0, stdout="Signature=adhoc", stderr="")
                        if kind == "lipo":
                            result.stdout = value
                        else:
                            field = value.split()[0]
                            original = {"platform": "platform 3", "minos": "minos 18.0", "sdk": "sdk 26.5"}[field]
                            result.stdout = result.stdout.replace(original, value)
                    return result
                with patch.object(DIRECT.subprocess, "run", side_effect=commands), self.assertRaises(DIRECT.DirectTestError):
                    DIRECT.inspect_artifact(artifact, item, "tvos")

    def test_tv_ipa_extraction_rejects_path_and_symlink_escapes(self):
        for link in (False, True):
            with self.subTest(symlink=link), tempfile.TemporaryDirectory(prefix="vortx-tv-ipa-containment-") as temporary:
                artifact = Path(temporary) / "hostile.ipa"
                with zipfile.ZipFile(artifact, "w") as archive:
                    if link:
                        entry = zipfile.ZipInfo("Payload/VortXTV.app/Link")
                        entry.external_attr = 0o120777 << 16
                        archive.writestr(entry, "../../../outside")
                    else:
                        archive.writestr("../../outside", b"escape")
                with self.assertRaisesRegex(DIRECT.DirectTestError, "escapes its extraction root|unexpected archive entries"):
                    with DIRECT.open_app(artifact, "tvos"):
                        self.fail("hostile IPA must not open")

    def test_tv_ipa_wrapper_rejects_extra_payload_sibling_duplicates_and_wrong_app_filename(self):
        cases = [("outside", "Metadata.plist"), ("sibling", "Payload/unaccepted.txt"),
                 ("duplicate", "Payload/VortXTV.app/Info.plist"), ("backslash", "Payload\\escaped"),
                 ("wrong-app", None)]
        for kind, member in cases:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="vortx-tv-wrapper-policy-") as temporary:
                root = Path(temporary)
                artifact, item = tv_ipa(root, "tvos")
                with zipfile.ZipFile(artifact) as archive:
                    entries = [(info.filename, archive.read(info)) for info in archive.infolist()]
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    with zipfile.ZipFile(artifact, "w") as archive:
                        for filename, data in entries:
                            if kind == "wrong-app":
                                filename = filename.replace("Payload/VortXTV.app/", "Payload/Wrong.app/")
                            archive.writestr(filename, data)
                        if member is not None:
                            archive.writestr(member, b"unaccepted wrapper member")
                item.update(size=artifact.stat().st_size, sha256=DIRECT.sha256_file(artifact))
                with patch.object(DIRECT.subprocess, "run", side_effect=tv_commands), self.assertRaises(DIRECT.DirectTestError):
                    DIRECT.inspect_artifact(artifact, item, "tvos")


class WorkflowIsolationTests(unittest.TestCase):
    def test_direct_lane_is_read_only_and_standard_feed_verifier_remains_guarded(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/release-tvos.yml").read_text()
        direct = workflow.split("  verify-direct-apple-test:\n", 1)[1].split("\n  verify-published:\n", 1)[0]
        normal = workflow.split("  verify-published:\n", 1)[1]
        self.assertIn("contains(github.event.release.body, 'vortx-distribution: direct-test')", direct)
        self.assertIn("runs-on: macos-26", direct)
        self.assertIn("contents: read", direct)
        self.assertIn("verify-apple-direct-test-release.py asset-names", direct)
        self.assertLess(direct.index("verify-apple-direct-test-release.py asset-names"),
                        direct.index("while IFS= read -r ASSET_NAME"))
        self.assertIn('done < "$WORK_DIR/asset-names.txt"', direct)
        self.assertNotIn(".artifacts.ios.name, .artifacts.macos.name", direct)
        self.assertIn("verify-apple-direct-test-release.py verify-published", direct)
        self.assertLess(direct.index("unset GH_TOKEN"), direct.index("verify-apple-direct-test-release.py verify-published"))
        for forbidden in ("xcodebuild", "actions/upload-artifact", "release-feed.mjs", "__release/receipt", "-X POST"):
            self.assertNotIn(forbidden, direct)
        self.assertIn("!contains(github.event.release.body, 'vortx-distribution: direct-test')", normal)
        self.assertIn("._generatedFromTag == $tag", workflow)
        self.assertIn("Atomically activate the staged feed, prove routes, then publish last", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
