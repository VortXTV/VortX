#!/usr/bin/env python3
"""Contract tests for the read-only local Apple direct-test release lane."""
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

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


def direct_input_hashes():
    hashes = []
    archive_hashes = {"Libmpv": "a", "Libavcodec": "b", "Libavformat": "c", "Libplacebo": "d"}
    for platform in ("ios", "macos"):
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
    for platform in ("ios", "macos"):
        item = manifest["artifacts"][platform]
        assets.append({"name": item["name"], "state": "uploaded", "size": item["size"],
                       "digest": "sha256:" + item["sha256"],
                       "browser_download_url": f"https://github.com/VortXTV/VortX/releases/download/{manifest['release']['tag']}/{item['name']}"})
    return {"id": 123, "tag_name": manifest["release"]["tag"], "draft": not published,
            "prerelease": True, "published_at": "2026-10-10T00:00:00Z" if published else None,
            "body": body or f"Apple only\n{DIRECT.APPLE_MARKER}\n{DIRECT.DIRECT_MARKER}", "assets": assets}


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


class WorkflowIsolationTests(unittest.TestCase):
    def test_direct_lane_is_read_only_and_standard_feed_verifier_remains_guarded(self):
        workflow = (Path(__file__).parents[2] / ".github/workflows/release-tvos.yml").read_text()
        direct = workflow.split("  verify-direct-apple-test:\n", 1)[1].split("\n  verify-published:\n", 1)[0]
        normal = workflow.split("  verify-published:\n", 1)[1]
        self.assertIn("contains(github.event.release.body, 'vortx-distribution: direct-test')", direct)
        self.assertIn("runs-on: macos-26", direct)
        self.assertIn("contents: read", direct)
        self.assertIn("verify-apple-direct-test-release.py verify-published", direct)
        self.assertLess(direct.index("unset GH_TOKEN"), direct.index("verify-apple-direct-test-release.py verify-published"))
        for forbidden in ("xcodebuild", "actions/upload-artifact", "release-feed.mjs", "__release/receipt", "-X POST"):
            self.assertNotIn(forbidden, direct)
        self.assertIn("!contains(github.event.release.body, 'vortx-distribution: direct-test')", normal)
        self.assertIn("._generatedFromTag == $tag", workflow)
        self.assertIn("Atomically activate the staged feed, prove routes, then publish last", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
