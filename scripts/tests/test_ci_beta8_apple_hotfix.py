"""UNRUN synthetic controls for the actual read-only Beta8 verifier. No CI/package proof.
Future invocation imports the verifier, with network/process boundaries explicitly mocked.
No import, parser or test was executed while authoring this source proposal.
"""
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location("beta8_verifier", Path(__file__).resolve().parents[1] / "verify-ci-beta8-apple-hotfix.py")
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)
SOURCE = "1234567890abcdef1234567890abcdef12345678" # Explicit controlled new source, not a real receipt.
POINTER = {"runId": 11, "attempt": 2, "artifactId": 33}
BASE = datetime(2026, 10, 30, tzinfo=timezone.utc)


def project(build="281"):
    return "name: Controlled\ntargets:\n" + "".join(
        f"  {name}:\n    settings:\n      MARKETING_VERSION: 0.5.6\n      CURRENT_PROJECT_VERSION: {build}\n"
        for name in ("VortXiOSNative", "VortXMac", "VortXTV", "VortXTopShelf", "VortXTVLite")) + "schemes:\n"


def steps():
    names = list(V.LANES["apple"][3])
    location = names.index("Verify complete native engine ABI")
    names[location:location] = [V.SDK_CACHE, V.SDK_BUILD]
    names.insert(names.index(V.LIVE_ABI), V.SDK_SAVE)
    names.extend(V.job_contract("apple", V.TAG)[1])
    forbidden = set(V.job_contract("apple", V.TAG)[1])
    return {name: {"name": name, "number": index + 1, "status": "completed",
                   "conclusion": "skipped" if name in forbidden else "success",
                   "started_at": (BASE + timedelta(seconds=index * 3)).isoformat(),
                   "completed_at": (BASE + timedelta(seconds=index * 3 + 1)).isoformat()}
            for index, name in enumerate(names)}


def timed(step, bodies, bom=False):
    return [("\ufeff" if bom and index == 0 else "") + step["started_at"] + " " + body + "\n"
            for index, body in enumerate(bodies)]


class Beta8AppleHotfixControls(unittest.TestCase):
    def test_exact_release_version_build_and_native_only(self):
        self.assertEqual(V.tag_version(V.TAG), "0.5.6")
        self.assertEqual(V.expected_engine(V.TAG), "2ea2e0f27dd2e53b7b28228435ca35a70f92831f")
        self.assertEqual(V.source_versions(project(), "0.5.6", V.TAG), "281")
        for tag in ("v0.5.6-beta.7", "v0.5.6-beta.8", "v0.5.6-beta.10", "v0.5.6", V.BUILD_TAG, V.TAG + " "):
            with self.assertRaises(ValueError): V.expected_engine(tag)
        with self.assertRaises(ValueError): V.source_versions(project("280"), "0.5.6", V.TAG)

    def test_each_real_target_pair_required(self):
        for malformed in (project().replace("VortXTopShelf:", "OtherExtension:"),
                          project().replace("CURRENT_PROJECT_VERSION: 281", "CURRENT_PROJECT_VERSION: 282", 1),
                          project().replace("MARKETING_VERSION: 0.5.6", "MARKETING_VERSION: 0.5.7", 1)):
            with self.assertRaises(ValueError): V.source_versions(malformed, "0.5.6", V.TAG)

    def test_typed_dispatch_binds_original_normal_source_and_tag(self):
        receipt = {"schemaVersion": 1, "event": "workflow_dispatch", "ref": "refs/tags/" + V.BUILD_TAG,
                   "sourceCommit": SOURCE, "workflowCommit": SOURCE, "runId": 11, "attempt": 2,
                   "inputs": dict(V.APPLE_INPUTS)}
        V.validate_dispatch(receipt, POINTER, V.TAG, SOURCE)
        self.assertNotEqual(V.BUILD_TAG, V.TAG)
        wrong_release_ref = copy.deepcopy(receipt); wrong_release_ref["ref"] = "refs/tags/" + V.TAG
        with self.assertRaises(ValueError): V.validate_dispatch(wrong_release_ref, POINTER, V.TAG, SOURCE)
        for field, value in (("native_only", "true"), ("recovery_source_commit", V.BASE_BETA7_SOURCE),
                             ("publish_release", True), ("mpvkit_artifacts_url", "https://override.invalid")):
            wrong = copy.deepcopy(receipt); wrong["inputs"][field] = value
            with self.assertRaises(ValueError): V.validate_dispatch(wrong, POINTER, V.TAG, SOURCE)
        wrong = copy.deepcopy(receipt); wrong["workflowCommit"] = "a" * 40
        with self.assertRaises(ValueError): V.validate_dispatch(wrong, POINTER, V.TAG, SOURCE)

    def test_actual_job_requires_full_steps_original_attempt_and_skips(self):
        selected = steps()
        job = {"name": "build-tvos", "run_id": 11, "run_attempt": 2, "head_sha": SOURCE,
               "status": "completed", "conclusion": "success", "steps": list(selected.values())}
        V.successful_job([job], "apple", 11, 2, SOURCE, V.TAG)
        wrong = copy.deepcopy(job); wrong["run_attempt"] = 1
        with self.assertRaises(ValueError): V.successful_job([wrong], "apple", 11, 2, SOURCE, V.TAG)
        for name in (V.LIVE_ABI, "Build tvOS (Lite)", "Upload the immutable feed handoff"):
            wrong = copy.deepcopy(job)
            next(step for step in wrong["steps"] if step["name"] == name)["conclusion"] = "failure"
            with self.assertRaises(ValueError): V.successful_job([wrong], "apple", 11, 2, SOURCE, V.TAG)

    def test_original_run_source_and_artifact_cannot_be_replaced(self):
        run = {"id": 11, "run_attempt": 2, "event": "workflow_dispatch", "head_sha": SOURCE,
               "head_branch": V.BUILD_TAG, "path": ".github/workflows/release-tvos.yml", "workflow_id": 44,
               "status": "completed", "conclusion": "success", "repository": {"full_name": V.REPO, "id": 55},
               "head_repository": {"full_name": V.REPO, "id": 55}}
        workflow = {"id": 44, "path": run["path"]}
        for key, value in (("head_sha", "a" * 40), ("run_attempt", 1), ("head_branch", "main"), ("head_branch", V.TAG)):
            wrong = copy.deepcopy(run); wrong[key] = value
            with mock.patch.object(V, "api", side_effect=[wrong, workflow]), mock.patch.object(V, "api_download") as download:
                with self.assertRaises(ValueError): V.authenticate_build("apple", POINTER, V.TAG, SOURCE, set(), Path("unused"))
                download.assert_not_called()
        job = {"name": "build-tvos", "id": 77, "run_id": 11, "run_attempt": 2, "head_sha": SOURCE,
               "status": "completed", "conclusion": "success", "steps": list(steps().values())}
        wrong_artifact = {"id": 34, "name": "VortX-tvOS-ci"}
        with mock.patch.object(V, "api", side_effect=[run, workflow, {"jobs": [job], "total_count": 1}, wrong_artifact]), mock.patch.object(V, "api_download") as download:
            with self.assertRaises(ValueError): V.authenticate_build("apple", POINTER, V.TAG, SOURCE, set(), Path("unused"))
            download.assert_not_called()

    def test_original_upload_digest_id_size_order_and_bom(self):
        step = {"started_at": BASE.isoformat(), "completed_at": (BASE + timedelta(seconds=1)).isoformat()}
        artifact = {"created_at": BASE.isoformat(), "digest": "sha256:" + "a" * 64, "id": 33, "name": "VortX-tvOS-ci", "size_in_bytes": 123}
        bodies = ["SHA256 digest of uploaded artifact is " + "a" * 64,
                  "Artifact VortX-tvOS-ci successfully finalized. Artifact ID 33",
                  "Artifact VortX-tvOS-ci has been successfully uploaded! Final size is 123 bytes. Artifact ID is 33"]
        raw = timed(step, bodies, bom=True)
        V.upload_proof(artifact, step, raw)
        with self.assertRaises(ValueError): V.upload_proof(artifact, step, raw + [raw[0]])
        with self.assertRaises(ValueError): V.upload_proof({**artifact, "id": 34}, step, raw)
        with self.assertRaises(ValueError): V.upload_proof(artifact, step, ["\ufeff" + raw[0], *raw[1:]])

    def test_raw_log_continuations_never_gain_timed_marker_authority(self):
        step = {"started_at": BASE.isoformat(), "completed_at": (BASE + timedelta(seconds=1)).isoformat()}
        raw = timed(step, ["  DISPATCH_INPUTS_JSON: {"], bom=True) + ['  "native_only": true,\n', '}\n']
        self.assertEqual(V.step_log_bodies(raw, step), ["  DISPATCH_INPUTS_JSON: {"])
        for bad in ([raw[1]], raw[:1] + ['  "recovery_source_commit": "old",\n'], ["\ufeff" + raw[0]]):
            with self.assertRaises(ValueError): V.step_log_bodies(bad, step)

    def test_full_live_abi_requires_fixture_and_unique_post_runtime_hashes(self):
        selected = steps(); runtime = selected[V.LIVE_ABI]
        raw = timed(runtime, [V.FIXTURE + ": OK", "Verified unchanged library " + "a" * 64, "Verified unchanged header " + "b" * 64], bom=True)
        self.assertEqual(V.live_abi_log_proof(selected, raw)["runtimeHeaderSha256"], "b" * 64)
        with self.assertRaises(ValueError): V.live_abi_log_proof(selected, raw[1:])
        with self.assertRaises(ValueError): V.live_abi_log_proof(selected, raw + raw[1:2])
        wrong = copy.deepcopy(selected); wrong["Build iOS"]["number"] = 1
        with self.assertRaises(ValueError): V.live_abi_log_proof(wrong, raw)

    def test_sdk_exact_hit_and_miss_are_not_abi_acceptance(self):
        selected = steps(); key = "vortx-ffi-resource-host-v1-macOS-26.0-" + V.ENGINE + "-" + "a" * 64
        missed = timed(selected[V.SDK_CACHE], ["Cache not found for input keys: " + key])
        self.assertFalse(V.sdk_cache_proof(selected, missed)["validationAcceptance"])
        selected[V.SDK_BUILD]["conclusion"] = selected[V.SDK_SAVE]["conclusion"] = "skipped"
        hit = timed(selected[V.SDK_CACHE], ["Cache hit for: " + key, "Cache restored from key: " + key])
        self.assertEqual(V.sdk_cache_proof(selected, hit)["restore"], "exact-hit")
        with self.assertRaises(ValueError): V.sdk_cache_proof(selected, [line.replace(V.ENGINE, "b" * 40) for line in hit])
        with self.assertRaises(ValueError): V.sdk_cache_proof(selected, missed)

    def test_archive_requires_original_digest_exact_flat_roster(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); archive = root / "artifact.zip"
            with zipfile.ZipFile(archive, "w") as output: output.writestr("one.json", b"original")
            metadata = {"size_in_bytes": archive.stat().st_size, "digest": "sha256:" + V.digest(archive)}
            V.extract_exact(archive, metadata, {"one.json"}, root / "accepted")
            with self.assertRaises(ValueError): V.extract_exact(archive, {**metadata, "digest": "sha256:" + "a" * 64}, {"one.json"}, root / "wrong")
            with self.assertRaises(ValueError): V.extract_exact(archive, metadata, {"other.json"}, root / "other")

    def test_apple_matrix_has_no_android_or_recovery_receipt(self):
        packages, names = V.file_matrix(V.TAG, V.VERSION)
        self.assertEqual(set(packages), {"ios", "tvos", "tvos-lite", "macos"})
        self.assertEqual(len(packages) + 2, 6)
        self.assertTrue({"native-ios-simulator.json", "native-tvos-simulator.json", "native-ci-dispatch.json"} <= names)
        self.assertFalse(any(name.endswith((".apk", ".aab")) or "repair" in name for name in names))
        with self.assertRaises(ValueError): V.job_contract("android", V.TAG)

    def test_release_and_asset_identity_refuse_old_extra_or_stable(self):
        release = {"id": 99, "tag_name": V.TAG, "target_commitish": SOURCE, "draft": True,
                   "prerelease": True, "published_at": None, "body": V.MARKER, "assets": []}
        V.release_identity(release, 99, V.TAG, True, SOURCE)
        for wrong in ({**release, "prerelease": False}, {**release, "target_commitish": V.BASE_BETA7_SOURCE}, {**release, "body": V.MARKER + "\n<!-- vortx-channel: latest-beta -->"}):
            with self.assertRaises(ValueError): V.release_identity(wrong, 99, V.TAG, True, SOURCE)
        asset = {"id": 1, "name": "one.ipa", "state": "uploaded", "size": 1, "digest": "sha256:" + "a" * 64, "browser_download_url": "unused"}
        with self.assertRaises(ValueError): V.release_assets({"assets": [asset, {**asset, "id": 2, "name": "old.apk"}]}, {"one.ipa"})

    def test_published_url_is_canonical_and_provenance_binding_unique(self):
        url = f"https://github.com/{V.REPO}/releases/download/{V.TAG}/one.ipa"
        V.validate_asset_url("verify-published", {"draft": False}, V.TAG, "one.ipa", url)
        with self.assertRaises(ValueError): V.validate_asset_url("verify-published", {"draft": False}, V.TAG, "one.ipa", url.replace(V.TAG, "v0.5.6-beta.7"))
        marker = "<!-- vortx-ci-provenance-sha256: " + "a" * 64 + " -->"
        self.assertEqual(V.provenance_binding(marker), "a" * 64)
        with self.assertRaises(ValueError): V.provenance_binding(marker + "\n" + marker)


if __name__ == "__main__":
    unittest.main()
