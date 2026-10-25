"""Secretless contract fixtures for scripts/verify-ci-direct-beta.py. UNRUN candidate."""
import copy
import hashlib
import importlib.util
import re
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "ci_direct_beta", Path(__file__).resolve().parents[1] / "verify-ci-direct-beta.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class HostedDirectBetaContract(unittest.TestCase):
    def test_engine_pin_is_exact_tag_bound_without_fallback(self):
        self.assertEqual(MODULE.ENGINE, "a3169f338f3f05da4ad3adb39a1e557c3ddcac33")
        self.assertEqual(MODULE.expected_engine("v0.5.6-beta.3"), "a3169f338f3f05da4ad3adb39a1e557c3ddcac33")
        self.assertEqual(MODULE.expected_engine("v0.5.6-beta.4"), "a3169f338f3f05da4ad3adb39a1e557c3ddcac33")
        self.assertEqual(MODULE.expected_engine("v0.5.6-beta.5"), "a3169f338f3f05da4ad3adb39a1e557c3ddcac33")
        self.assertEqual(MODULE.expected_engine("v0.5.6-beta.6"), "a3169f338f3f05da4ad3adb39a1e557c3ddcac33")
        self.assertEqual(MODULE.expected_engine("v0.5.6-beta.2"), "af29b22e4c45740a1f5b6cb415b81f8430f55b9f")
        self.assertEqual(MODULE.expected_engine("v0.5.6-beta.7"), "2ea2e0f27dd2e53b7b28228435ca35a70f92831f")
        for tag in ("v0.5.6-beta.1", "v0.5.6-beta.8", "v0.5.7-beta.1", "main", "", None):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                MODULE.expected_engine(tag)

    def test_tag_is_strict_positive_beta(self):
        self.assertEqual(MODULE.tag_version("v0.5.6-beta.1"), "0.5.6")
        for value in ("v0.5.6", "v0.5.6-beta.0", "v0.5.6-beta1", "main", "v0.5.6-beta.1/other"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.tag_version(value)

    def test_original_dispatch_is_not_relabelled(self):
        pointer = {"runId": 5, "attempt": 1, "artifactId": 8}
        receipt = {"schemaVersion": 1, "event": "workflow_dispatch", "ref": "refs/tags/v0.5.6-beta.1",
                   "sourceCommit": "a" * 40, "workflowCommit": "a" * 40, "runId": 5, "attempt": 1,
                   "inputs": copy.deepcopy(MODULE.APPLE_INPUTS)}
        MODULE.validate_dispatch(receipt, pointer, "v0.5.6-beta.1", "a" * 40)
        for field, value in (("release_tag", "v0.5.6-beta.1"), ("publish_release", True),
                             ("native_only", 1), ("recovery_source_commit", "a" * 40),
                             ("resume_handoff", "{}"), ("apple_only", True),
                             ("mpvkit_artifacts_url", "https://example.invalid")):
            changed = copy.deepcopy(receipt)
            changed["inputs"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                MODULE.validate_dispatch(changed, pointer, "v0.5.6-beta.1", "a" * 40)

    def test_marker_rejects_latest_and_other_distribution(self):
        release = {"id": 7, "tag_name": "v0.5.6-beta.1", "draft": True, "prerelease": True,
                   "body": MODULE.MARKER, "target_commitish": "a" * 40, "published_at": None}
        MODULE.release_identity(release, 7, "v0.5.6-beta.1", True, "a" * 40)
        for addition in (MODULE.MARKER, "vortx-channel: latest-beta", "vortx-distribution: direct-test",
                         "vortx-platforms: apple"):
            with self.subTest(addition=addition), self.assertRaises(ValueError):
                MODULE.release_identity({**release, "body": MODULE.MARKER + "\n" + addition}, 7,
                                        "v0.5.6-beta.1", True, "a" * 40)

    def test_prepared_digest_binding(self):
        line = "<!-- vortx-ci-provenance-sha256: " + "a" * 64 + " -->"
        self.assertEqual(MODULE.provenance_binding(line), "a" * 64)
        for body in ("", line + "\n" + line, line.replace(" -->", "-->")):
            with self.subTest(body=body), self.assertRaises(ValueError):
                MODULE.provenance_binding(body)

    def test_exact_matrix_includes_both_simulator_receipts(self):
        apple, matrix, android = MODULE.file_matrix("v0.5.6-beta.1", "0.5.6")
        self.assertEqual(len(apple), 4)
        self.assertEqual(len(matrix), 18)
        self.assertEqual(len(android), 3)
        self.assertIn("native-ios-simulator.json", matrix)
        self.assertIn("native-tvos-simulator.json", matrix)
        self.assertNotIn("VortX-iOS-v0.5.6-beta.1-ci.ipa", matrix)

    def test_upload_identity_and_attempt_window(self):
        artifact = {"id": 10, "name": "VortX-tvOS-ci", "digest": "sha256:" + "a" * 64,
                    "size_in_bytes": 42, "created_at": "2026-10-19T01:00:01Z"}
        step = {"started_at": "2026-10-19T01:00:00Z", "completed_at": "2026-10-19T01:00:02Z"}
        lines = [
            "2026-10-19T01:00:00.100Z SHA256 digest of uploaded artifact is " + "a" * 64,
            "2026-10-19T01:00:01.100Z Artifact VortX-tvOS-ci successfully finalized. Artifact ID 10",
            "2026-10-19T01:00:02.100Z Artifact VortX-tvOS-ci has been successfully uploaded! Final size is 42 bytes. Artifact ID is 10",
        ]
        MODULE.upload_proof(artifact, step, lines)
        for invalid in (lines[:-1], lines + [lines[0]], [line.replace("ID 10", "ID 11") for line in lines],
                        [line.replace("T01:00:", "T00:00:") for line in lines]):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                MODULE.upload_proof(artifact, step, invalid)

    def test_exact_checksum_names_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "package.ipa"
            payload.write_bytes(b"fixture")
            sums = root / "SHA256SUMS-ci.txt"
            line = hashlib.sha256(b"fixture").hexdigest() + "  out/package.ipa\n"
            sums.write_text(line)
            MODULE.checksums(sums, {payload.name: payload}, "out/")
            for invalid in (line + line, line.replace("out/", "../"), "0" * 64 + "  out/package.ipa\n"):
                sums.write_text(invalid)
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    MODULE.checksums(sums, {payload.name: payload}, "out/")

    def test_archive_rejects_extra_file_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "artifact.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr("wanted.json", "{}")
                stream.writestr("unexpected.json", "{}")
            metadata = {"size_in_bytes": archive.stat().st_size, "digest": "sha256:" + MODULE.digest(archive)}
            output = root / "extract"
            with self.assertRaises(ValueError):
                MODULE.extract_exact(archive, metadata, {"wanted.json"}, output)
            self.assertFalse(output.exists())

    def test_asset_identity_ignores_read_counters_not_content(self):
        asset = {"id": 1, "name": "file.ipa", "state": "uploaded", "size": 2,
                 "digest": "sha256:" + "a" * 64, "browser_download_url": "fixed", "download_count": 0}
        baseline = MODULE.release_assets({"assets": [asset]}, {"file.ipa"})
        self.assertEqual(baseline, MODULE.release_assets({"assets": [{**asset, "download_count": 5}]}, {"file.ipa"}))
        self.assertNotEqual(baseline, MODULE.release_assets({"assets": [{**asset, "id": 2}]}, {"file.ipa"}))
        with self.assertRaises(ValueError):
            MODULE.release_assets({"assets": [asset, asset]}, {"file.ipa"})


class NativeBeta7Contract(unittest.TestCase):
    tag = "v0.5.6-beta.7"
    source = "a" * 40  # Disposable immutable identity, not a proposed release source.
    native_targets = ("VortXiOSNative", "VortXMac", "VortXTV", "VortXTopShelf", "VortXTVLite")

    @classmethod
    def project(cls, targets=None, build="281"):
        return "name: VortX\ntargets:\n" + "".join(
            f'  {name}:\n    settings:\n      base:\n        MARKETING_VERSION: "0.5.6"\n'
            f'        CURRENT_PROJECT_VERSION: "{build}"\n' for name in (targets or cls.native_targets))

    @staticmethod
    def gradle(build="281"):
        return f'versionName = "0.5.6"\nversionCode = {build}\n'

    def job(self, lane, tag=None):
        required, skipped = MODULE.job_contract(lane, tag or self.tag)
        return {"name": MODULE.LANES[lane][1], "run_id": 5, "run_attempt": 1,
                "head_sha": self.source, "status": "completed", "conclusion": "success",
                "steps": ([{"name": name, "status": "completed", "conclusion": "success"}
                           for name in required] +
                          [{"name": name, "status": "completed", "conclusion": "skipped"}
                           for name in skipped])}

    def accept_job(self, lane, job, tag=None):
        return MODULE.successful_job([job], lane, 5, 1, self.source, tag or self.tag)

    def evidence(self, tag=None):
        tag = tag or self.tag
        values = [("release tag", tag), ("release tag commit", self.source), ("source commit", self.source),
                  ("native engine source commit", MODULE.expected_engine(tag)),
                  ("native engine Cargo features", "jni,server,resource-host"),
                  ("workflow run", "https://github.com/VortXTV/VortX/actions/runs/5"),
                  ("workflow run attempt", "1"), ("Android versionCode", "281"),
                  ("Android versionName", "0.5.6")]
        if tag != self.tag:
            values.append(("legacy Stremio source commit (not packaged)", MODULE.STREMIO))
        return [label + ": " + value for label, value in values]

    def test_current_native_project_uses_all_five_exact_versioned_targets(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "app/project.yml").read_text()
        gradle = (root / "android/app/build.gradle.kts").read_text()
        builds = re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?\s*$', project, re.M)
        self.assertEqual(MODULE.source_versions(project, gradle, "0.5.6", self.tag), builds[0])
        self.assertEqual(len(builds), 5)

    def test_native_project_refuses_missing_extra_misnamed_or_disagreeing_target_pairs(self):
        project = self.project()
        self.assertEqual(MODULE.source_versions(project, self.gradle(), "0.5.6", self.tag), "281")
        invalid = [self.project(self.native_targets[:-1]),
                   self.project(self.native_targets + ("RemovedLegacyTarget",)),
                   project.replace("VortXTopShelf:", "UnknownTarget:"),
                   project.replace('CURRENT_PROJECT_VERSION: "281"', 'CURRENT_PROJECT_VERSION: "282"', 1),
                   project.replace('MARKETING_VERSION: "0.5.6"', 'MARKETING_VERSION: "0.5.7"', 1),
                   project.replace("\ntargets:\n", "\nunknown:\n")]
        for value in invalid:
            with self.subTest(project=value), self.assertRaises(ValueError):
                MODULE.source_versions(value, self.gradle(), "0.5.6", self.tag)
        for gradle in (self.gradle("282"), self.gradle() + self.gradle(), self.gradle().replace("0.5.6", "0.5.7")):
            with self.subTest(gradle=gradle), self.assertRaises(ValueError):
                MODULE.source_versions(project, gradle, "0.5.6", self.tag)
        with self.assertRaises(ValueError):
            MODULE.source_versions(project, self.gradle(), "0.5.6", "v0.5.6-beta.8")

    def test_historical_six_pair_and_job_contracts_remain_required(self):
        project = self.project(self.native_targets + ("HistoricalLegacyTarget",))
        for number in range(2, 7):
            tag = f"v0.5.6-beta.{number}"
            with self.subTest(tag=tag):
                self.assertEqual(MODULE.source_versions(project, self.gradle(), "0.5.6", tag), "281")
                with self.assertRaises(ValueError):
                    MODULE.source_versions(self.project(), self.gradle(), "0.5.6", tag)
                for lane in ("apple", "android"):
                    required, skipped = MODULE.job_contract(lane, tag)
                    self.assertEqual(required, MODULE.LANES[lane][3])
                    self.assertIn("Fetch stremiox-core (private, pinned)", required)
                    self.accept_job(lane, self.job(lane, tag), tag)
                    with self.assertRaises(ValueError):
                        self.accept_job(lane, self.job(lane), tag)

    def test_every_native_required_and_forbidden_step_matches_current_actual_workflow(self):
        root = Path(__file__).resolve().parents[2]
        for lane in ("apple", "android"):
            workflow, job = MODULE.LANES[lane][:2]
            text = (root / ".github/workflows" / workflow).read_text()
            section = text.split("  " + job + ":\n", 1)[1]
            section = re.split(r'\n  [A-Za-z0-9_-]+:\n', section, maxsplit=1)[0]
            names = re.findall(r'^      - name: (.+)$', section, re.M)
            required, skipped = MODULE.job_contract(lane, self.tag)
            for name in required + skipped:
                with self.subTest(lane=lane, name=name):
                    self.assertEqual(names.count(name), 1)
            self.assertNotIn("Fetch stremiox-core (private, pinned)", required)
        self.assertIn("Require real native sync revision and account tests before packaging",
                      MODULE.job_contract("android", self.tag)[0])
        self.assertIn("Reject removed legacy comparison builds", MODULE.job_contract("apple", self.tag)[1])

    def test_native_job_refuses_every_missing_duplicate_failed_or_skipped_required_step(self):
        for lane in ("apple", "android"):
            job = self.job(lane)
            self.accept_job(lane, job)
            required, _ = MODULE.job_contract(lane, self.tag)
            for name in required:
                for mode in ("missing", "duplicate", "failed", "skipped"):
                    changed = copy.deepcopy(job)
                    selected = next(step for step in changed["steps"] if step["name"] == name)
                    if mode == "missing":
                        changed["steps"].remove(selected)
                    elif mode == "duplicate":
                        changed["steps"].append(copy.deepcopy(selected))
                    else:
                        selected["conclusion"] = mode
                    with self.subTest(lane=lane, name=name, mode=mode), self.assertRaises(ValueError):
                        self.accept_job(lane, changed)

    def test_native_job_refuses_any_active_or_duplicate_forbidden_step_and_wrong_attempt_source(self):
        for lane in ("apple", "android"):
            job = self.job(lane)
            _, skipped = MODULE.job_contract(lane, self.tag)
            for name in skipped:
                for mode in ("active", "duplicate", "missing"):
                    changed = copy.deepcopy(job)
                    selected = next(step for step in changed["steps"] if step["name"] == name)
                    if mode == "active":
                        selected["conclusion"] = "success"
                    elif mode == "duplicate":
                        changed["steps"].append(copy.deepcopy(selected))
                    else:
                        changed["steps"].remove(selected)
                    with self.subTest(lane=lane, name=name, mode=mode), self.assertRaises(ValueError):
                        self.accept_job(lane, changed)
            for key, value in (("head_sha", "b" * 40), ("run_attempt", 2), ("run_id", 6),
                               ("status", "in_progress"), ("conclusion", "failure")):
                with self.subTest(lane=lane, key=key), self.assertRaises(ValueError):
                    self.accept_job(lane, {**job, key: value})

    def test_native_android_evidence_has_exact_current_pin_without_legacy_source(self):
        evidence = self.evidence()
        MODULE.validate_android_evidence(evidence, {"runId": 5, "attempt": 1}, self.tag,
                                         self.source, "0.5.6", "281")
        for line in evidence:
            for mode in ("missing", "duplicate", "wrong"):
                changed = list(evidence)
                if mode == "missing":
                    changed.remove(line)
                elif mode == "duplicate":
                    changed.append(line)
                else:
                    changed[changed.index(line)] = line + "-wrong"
                with self.subTest(line=line.split(": ", 1)[0], mode=mode), self.assertRaises(ValueError):
                    MODULE.validate_android_evidence(changed, {"runId": 5, "attempt": 1}, self.tag,
                                                     self.source, "0.5.6", "281")
        for legacy in ("legacy Stremio source commit (not packaged): " + MODULE.STREMIO,
                       "legacy Stremio source commit: removed"):
            with self.subTest(legacy=legacy), self.assertRaises(ValueError):
                MODULE.validate_android_evidence(evidence + [legacy], {"runId": 5, "attempt": 1},
                                                 self.tag, self.source, "0.5.6", "281")

    def test_historical_android_evidence_still_requires_exact_legacy_source(self):
        for number in range(2, 7):
            tag = f"v0.5.6-beta.{number}"
            evidence = self.evidence(tag)
            MODULE.validate_android_evidence(evidence, {"runId": 5, "attempt": 1}, tag,
                                             self.source, "0.5.6", "281")
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                MODULE.validate_android_evidence(evidence[:-1], {"runId": 5, "attempt": 1}, tag,
                                                 self.source, "0.5.6", "281")


    def test_authenticated_handoff_records_the_same_native_or_historical_steps_it_verified(self):
        for lane in ("apple", "android"):
            for tag in (self.tag, "v0.5.6-beta.6"):
                with self.subTest(lane=lane, tag=tag), tempfile.TemporaryDirectory() as temporary:
                    work = Path(temporary)
                    archive = work / "fixture.zip"
                    with zipfile.ZipFile(archive, "w") as stream:
                        stream.writestr("wanted.json", "{}")
                    data = archive.read_bytes()
                    digest = MODULE.digest(archive)
                    workflow, job_name, artifact_name = MODULE.LANES[lane][:3]
                    job = self.job(lane, tag)
                    job["id"] = 9
                    upload = next(step for step in job["steps"] if step["name"] == MODULE.LANES[lane][4])
                    upload.update(started_at="2026-10-26T01:00:00Z", completed_at="2026-10-26T01:00:02Z")
                    repository = {"id": 1, "full_name": MODULE.REPO}
                    run = {"id": 5, "run_attempt": 1, "event": "workflow_dispatch", "head_sha": self.source,
                           "head_branch": tag, "path": ".github/workflows/" + workflow, "workflow_id": 7,
                           "status": "completed", "conclusion": "success", "repository": repository,
                           "head_repository": repository}
                    artifact = {"id": 8, "name": artifact_name, "expired": False, "size_in_bytes": len(data),
                                "digest": "sha256:" + digest, "created_at": "2026-10-26T01:00:01Z",
                                "workflow_run": {"id": 5, "head_sha": self.source, "head_branch": tag,
                                                 "repository_id": 1, "head_repository_id": 1}}
                    metadata = {"actions/runs/5": run,
                                "actions/workflows/" + workflow: {"id": 7, "path": ".github/workflows/" + workflow},
                                "actions/runs/5/attempts/1/jobs?per_page=100&page=1": {"jobs": [job], "total_count": 1},
                                "actions/artifacts/8": artifact}
                    log = (f"2026-10-26T01:00:00.100Z SHA256 digest of uploaded artifact is {digest}\n"
                           f"2026-10-26T01:00:01.100Z Artifact {artifact_name} successfully finalized. Artifact ID 8\n"
                           f"2026-10-26T01:00:02.100Z Artifact {artifact_name} has been successfully uploaded! Final size is {len(data)} bytes. Artifact ID is 8\n").encode()
                    downloads = {"actions/jobs/9/logs": log, "actions/artifacts/8/zip": data}
                    def download(endpoint, destination, limit):
                        payload = downloads[endpoint]
                        self.assertLessEqual(len(payload), limit)
                        destination.write_bytes(payload)
                    # Only API transport is synthetic. Real job/step/upload/ZIP proof and extraction run.
                    with mock.patch.object(MODULE, "api", side_effect=metadata.__getitem__), \
                            mock.patch.object(MODULE, "api_download", side_effect=download):
                        output, public = MODULE.authenticate_build(lane, {"runId": 5, "attempt": 1, "artifactId": 8},
                                                                   tag, self.source, {"wanted.json"}, work)
                    self.assertEqual((output / "wanted.json").read_text(), "{}")
                    self.assertEqual(public["requiredSuccessfulSteps"], list(MODULE.job_contract(lane, tag)[0]))

    def test_android_inspection_returns_exact_tag_engine_after_original_evidence_checks(self):
        for tag in (self.tag, "v0.5.6-beta.6"):
            with self.subTest(tag=tag), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                _, _, names = MODULE.file_matrix(tag, "0.5.6")
                for name in names:
                    prefix = "base/" if name.endswith(".aab") else ""
                    with zipfile.ZipFile(directory / name, "w") as stream:
                        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
                            stream.writestr(f"{prefix}lib/{abi}/libvortx_ffi.so", b"fixture-not-native-code")
                sums = "".join(MODULE.digest(directory / name) + "  " + name + "\n" for name in sorted(names))
                (directory / "SHA256SUMS-android.txt").write_text(sums)
                (directory / "SIGNING_PROVENANCE.txt").write_text("\n".join(self.evidence(tag)) + "\n")
                bundletool = directory / "fixture.jar"
                bundletool.write_bytes(b"fixture-not-a-tool")
                # These fixtures cover the actual metadata return path, not signer/native validity.
                # Real signer/version tools are explicitly not executed; production gates stay unchanged.
                with mock.patch.object(MODULE, "BUNDLETOOL_SHA", MODULE.digest(bundletool)), \
                        mock.patch.object(MODULE.subprocess, "run") as package_tools:
                    records, evidence = MODULE.inspect_android(directory, {"runId": 5, "attempt": 1}, tag,
                                                               self.source, "0.5.6", "281", directory, bundletool)
                self.assertEqual(len(records), 3)
                self.assertEqual(evidence["engineSourceCommit"], MODULE.expected_engine(tag))
                self.assertEqual(package_tools.call_count, 2)
                self.assertEqual([call.args[0][1].split("/")[-1] for call in package_tools.call_args_list],
                                 ["verify-android-release-signing.sh", "verify-android-release-version.sh"])
                for call in package_tools.call_args_list:
                    self.assertIs(call.kwargs["check"], True)


if __name__ == "__main__":
    unittest.main()
