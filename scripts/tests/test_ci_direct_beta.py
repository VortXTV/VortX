"""Secretless contract fixtures for scripts/verify-ci-direct-beta.py. UNRUN candidate."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
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
        for tag in ("v0.5.6-beta.1", "v0.5.6-beta.7", "v0.5.7-beta.1", "main", "", None):
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


if __name__ == "__main__":
    unittest.main()
