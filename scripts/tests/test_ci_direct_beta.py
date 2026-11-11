"""Secretless contract fixtures for scripts/verify-ci-direct-beta.py. UNRUN candidate."""
import copy
import hashlib
import importlib.util
import json
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

    def test_current_native_project_no_longer_satisfies_the_immutable_beta7_contract(self):
        # Beta 7 shipped five Apple version pairs; the VortXAetherKit framework made the current project six.
        root = Path(__file__).resolve().parents[2]
        project = (root / "app/project.yml").read_text()
        gradle = (root / "android/app/build.gradle.kts").read_text()
        with self.assertRaises(ValueError):
            MODULE.source_versions(project, gradle, "0.5.6", NativeBeta7Contract.tag)

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
                           "head_branch": MODULE.build_tag(tag), "path": ".github/workflows/" + workflow, "workflow_id": 7,
                           "status": "completed", "conclusion": "success", "repository": repository,
                           "head_repository": repository}
                    artifact = {"id": 8, "name": artifact_name, "expired": False, "size_in_bytes": len(data),
                                "digest": "sha256:" + digest, "created_at": "2026-10-26T01:00:01Z",
                                "workflow_run": {"id": 5, "head_sha": self.source, "head_branch": MODULE.build_tag(tag),
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


class NativeBeta11Contract(NativeBeta7Contract):
    """Every beta 7 native check, rerun under beta 11's tag, six Apple pairs and candidate build tag."""
    tag = "v0.5.6-beta.11"
    build_tag = "v0.5.6-beta.11-candidate.1"
    native_targets = NativeBeta7Contract.native_targets + ("VortXAetherKit",)

    def evidence(self, tag=None):
        # The Android lane records the tag it was dispatched at, which for beta 11 is the candidate tag.
        tag = tag or self.tag
        lines = super().evidence(tag)
        if tag == self.tag:
            lines[0] = "release tag: " + self.build_tag
        return lines

    def test_current_native_project_no_longer_satisfies_the_immutable_beta7_contract(self):
        pass  # Covered once by NativeBeta7Contract.

    def test_historical_six_pair_and_job_contracts_remain_required(self):
        pass  # Covered once by NativeBeta7Contract with the five beta 7 targets.

    def test_current_native_project_uses_all_six_exact_versioned_targets(self):
        root = Path(__file__).resolve().parents[2]
        project = (root / "app/project.yml").read_text()
        gradle = (root / "android/app/build.gradle.kts").read_text()
        builds = re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?\s*$', project, re.M)
        self.assertEqual(MODULE.source_versions(project, gradle, "0.5.6", self.tag), builds[0])
        self.assertEqual(len(builds), 6)

    def test_builds_bind_to_the_candidate_tag_and_the_beta7_engine(self):
        self.assertEqual(MODULE.build_tag(self.tag), self.build_tag)
        for tag in ("v0.5.6-beta.7", "v0.5.6-beta.6", "v0.5.6-beta.14"):
            self.assertEqual(MODULE.build_tag(tag), tag)
        self.assertEqual(MODULE.expected_engine(self.tag), MODULE.NATIVE_BETA7_ENGINE)
        for tag in ("v0.5.6-beta.8", "v0.5.6-beta.9", "v0.5.6-beta.10", "v0.5.6-beta.14", self.build_tag):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                MODULE.expected_engine(tag)
        for lane in ("apple", "android"):
            self.assertEqual(MODULE.job_contract(lane, self.tag), MODULE.job_contract(lane, NativeBeta7Contract.tag))

    def test_dispatch_receipt_must_name_the_candidate_tag(self):
        pointer = {"runId": 5, "attempt": 1}
        receipt = {"schemaVersion": 1, "event": "workflow_dispatch", "ref": "refs/tags/" + self.build_tag,
                   "sourceCommit": self.source, "workflowCommit": self.source, "runId": 5, "attempt": 1,
                   "inputs": MODULE.APPLE_INPUTS}
        MODULE.validate_dispatch(receipt, pointer, self.tag, self.source)
        with self.assertRaises(ValueError):
            MODULE.validate_dispatch({**receipt, "ref": "refs/tags/" + self.tag}, pointer, self.tag, self.source)

    def test_android_evidence_from_the_release_tag_itself_is_refused(self):
        evidence = self.evidence()
        evidence[0] = "release tag: " + self.tag
        with self.assertRaises(ValueError):
            MODULE.validate_android_evidence(evidence, {"runId": 5, "attempt": 1}, self.tag, self.source, "0.5.6", "281")


class NativeBeta12Contract(unittest.TestCase):
    tag = "v0.5.6-beta.12"
    candidate = "v0.5.6-beta.12-candidate.3"
    build = "283"
    preflight_mode = "beta12-candidate-preflight"
    rejected_candidates = ("1", "2")
    source = "a" * 40
    pointer = {"runId": 5, "attempt": 1, "artifactId": 8}

    def test_only_exact_protected_tag_candidate_and_build_are_admitted(self):
        self.assertEqual(MODULE.build_tag(self.tag), self.candidate)
        self.assertEqual(MODULE.expected_engine(self.tag), "2ea2e0f27dd2e53b7b28228435ca35a70f92831f")
        self.assertEqual(MODULE.source_versions(NativeBeta11Contract.project(build=self.build),
            NativeBeta11Contract.gradle(build=self.build), "0.5.6", self.tag), self.build)
        with self.assertRaisesRegex(ValueError, "exact cross-platform build"):
            MODULE.source_versions(NativeBeta11Contract.project(build="282"),
                NativeBeta11Contract.gradle(build="282"), "0.5.6", self.tag)
        for tag in (self.candidate, "v0.5.6-beta.14",
                    *(self.tag + "-candidate." + suffix for suffix in self.rejected_candidates)):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                MODULE.expected_engine(tag)

    def test_candidate_requires_all_native_gates_and_skips_android_draft_write(self):
        apple, _ = MODULE.job_contract("apple", self.tag)
        android, skipped = MODULE.job_contract("android", self.tag)
        for name in (MODULE.BETA12_LIVE_ABI, MODULE.BETA12_APPLE_GATE, MODULE.BETA12_APPLE_EVIDENCE,
                     MODULE.BETA12_AETHER_RESOLVE, MODULE.BETA12_AETHER_VERIFY, MODULE.BETA12_AETHER_EVIDENCE):
            self.assertIn(name, apple)
        self.assertIn(MODULE.BETA12_ANDROID_GATE, android)
        self.assertIn(MODULE.BETA12_ANDROID_EVIDENCE, android)
        self.assertIn(MODULE.ANDROID_DRAFT_STEP, skipped)
        self.assertNotIn(MODULE.ANDROID_DRAFT_STEP, android)
        historical, _ = MODULE.job_contract("android", NativeBeta11Contract.tag)
        self.assertIn(MODULE.ANDROID_DRAFT_STEP, historical)
        original = NativeBeta7Contract.job(self, "android", self.tag)
        MODULE.successful_job([original], "android", 5, 1, self.source, self.tag)
        draft = next(step for step in original["steps"] if step["name"] == MODULE.ANDROID_DRAFT_STEP)
        draft["conclusion"] = "success"
        with self.assertRaisesRegex(ValueError, "forbidden publication"):
            MODULE.successful_job([original], "android", 5, 1, self.source, self.tag)

    def test_preflight_ref_absence_and_receipt_are_distinct_from_a_release(self):
        with mock.patch.object(MODULE, "api", return_value=[{"ref": "refs/tags/" + self.candidate}]):
            MODULE.require_uncreated_protected_tag(self.tag)
        with mock.patch.object(MODULE, "api", return_value=[{"ref": "refs/tags/" + self.tag}]):
            with self.assertRaisesRegex(ValueError, "already exists"):
                MODULE.require_uncreated_protected_tag(self.tag)
        proof = {"tag": self.tag, "sourceCommit": self.source, "builds": {"apple": self.pointer}}
        self.assertEqual(MODULE.candidate_receipt(proof)["mode"], self.preflight_mode)
        self.assertEqual(MODULE.candidate_receipt(proof), MODULE.candidate_receipt({**proof, "releaseId": 17}))
        self.assertNotEqual(MODULE.candidate_receipt(proof), MODULE.candidate_receipt({**proof, "sourceCommit": "b" * 40}))

    def test_aether_sidecar_binds_every_original_native_receipt(self):
        identity = {"schemaVersion": 1, "sourceCommit": self.source, "workflowCommit": self.source,
                    "ref": "refs/tags/" + self.candidate, "runId": 5, "attempt": 1}
        lock = "1" * 64
        raw_resolution = MODULE.canonical({**identity, "packageResolvedSha256": lock, "packages": MODULE.BETA12_AETHER_PACKAGES})
        contents = {"aether-resolved.json": raw_resolution}
        with tempfile.TemporaryDirectory() as temporary:
            handoff = Path(temporary)
            for key, (platform, variant) in MODULE.BETA12_AETHER_APPS.items():
                prefix = "Contents/Frameworks/" if key == "macos" else "Frameworks/"
                binaries = {name: {"path": prefix + name + ".framework/" + name, "architectures": ["arm64"],
                                   "rawSha256": "2" * 64, "normalizedSha256": "3" * 64}
                            for name in MODULE.BETA12_AETHER_BINARIES}
                native = MODULE.canonical({"bundlePayload": {item["path"]: {"sha256": item["normalizedSha256"]}
                                                            for item in binaries.values()}})
                (handoff / f"native-{key}.json").write_bytes(native)
                contents[f"aether-{key}.json"] = MODULE.canonical({**identity, "key": key, "architecture": "arm64",
                    "resolutionReceiptSha256": hashlib.sha256(raw_resolution).hexdigest(), "packageResolvedSha256": lock,
                    "nativeAppReceiptSha256": hashlib.sha256(native).hexdigest(), "aetherLinkMapSha256": "4" * 64,
                    "provider": {"platform": platform, "variant": variant, "libraryIdentifier": "fixture-arm64",
                                 "upstreamSha256": "5" * 64, "processedSha256": "6" * 64, "arm64Sha256": "7" * 64},
                    "binaries": binaries})
            proof = MODULE.protected_aether_gate(contents, self.pointer, self.tag, self.source, handoff)
            self.assertEqual(set(proof["apps"]), set(MODULE.BETA12_AETHER_APPS))
            wrong_ref = MODULE.canonical({**json.loads(raw_resolution), "ref": "refs/tags/" + self.tag})
            with self.assertRaisesRegex(ValueError, "resolution source or pins"):
                MODULE.protected_aether_gate({**contents, "aether-resolved.json": wrong_ref},
                                             self.pointer, self.tag, self.source, handoff)
            changed = json.loads(contents["aether-tvos-lite.json"])
            changed["binaries"]["VortXAetherKit"]["normalizedSha256"] = "8" * 64
            with self.assertRaisesRegex(ValueError, "normalized bytes"):
                MODULE.protected_aether_gate({**contents, "aether-tvos-lite.json": MODULE.canonical(changed)},
                                             self.pointer, self.tag, self.source, handoff)


class NativeBeta13Contract(NativeBeta12Contract):
    tag = "v0.5.6-beta.13"
    candidate = "v0.5.6-beta.13-candidate.1"
    build = "285"
    preflight_mode = "beta13-candidate-preflight"
    rejected_candidates = ("2", "9")

    def test_beta13_artifact_only_guard_is_part_of_the_original_apple_job(self):
        required, _ = MODULE.job_contract("apple", self.tag)
        historical, _ = MODULE.job_contract("apple", NativeBeta12Contract.tag)
        guard = "Verify protected Beta 13 artifact-only dispatch"
        self.assertIn(guard, required)
        self.assertNotIn(guard, historical)
        original = NativeBeta7Contract.job(self, "apple", self.tag)
        MODULE.successful_job([original], "apple", 5, 1, self.source, self.tag)
        original["steps"] = [step for step in original["steps"] if step["name"] != guard]
        with self.assertRaisesRegex(ValueError, guard):
            MODULE.successful_job([original], "apple", 5, 1, self.source, self.tag)

    def test_beta13_requires_focused_android_backup_cas_step(self):
        guard = MODULE.BETA13_ANDROID_BACKUP_CAS
        historical, _ = MODULE.job_contract("android", NativeBeta12Contract.tag)
        self.assertNotIn(guard, historical)
        original = NativeBeta7Contract.job(self, "android", self.tag)
        MODULE.successful_job([original], "android", 5, 1, self.source, self.tag)
        original["steps"] = [step for step in original["steps"] if step["name"] != guard]
        with self.assertRaisesRegex(ValueError, guard):
            MODULE.successful_job([original], "android", 5, 1, self.source, self.tag)

    def test_dispatch_receipt_rejects_final_previous_and_unapproved_candidate_refs(self):
        receipt = {"schemaVersion": 1, "event": "workflow_dispatch", "ref": "refs/tags/" + self.candidate,
                   "sourceCommit": self.source, "workflowCommit": self.source, "runId": 5, "attempt": 1,
                   "inputs": MODULE.APPLE_INPUTS}
        MODULE.validate_dispatch(receipt, self.pointer, self.tag, self.source)
        for tag in (self.tag, NativeBeta12Contract.candidate, self.tag + "-candidate.2"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                MODULE.validate_dispatch({**receipt, "ref": "refs/tags/" + tag}, self.pointer, self.tag, self.source)


if __name__ == "__main__":
    unittest.main()
