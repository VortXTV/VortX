#!/usr/bin/env python3
"""Authored recovery tests. Importing this file never performs a real API request.

Public placement: scripts/tests/test_recover_beta056b2_release.py, with the verifier
at scripts/recover-beta056b2-release.py. In the recovery review location the sibling
*.after.py candidate is selected. RECOVERY_VERIFIER_PATH may select an exact reviewed
candidate explicitly. These tests use mocked public source responses, not live proof.
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile


HERE = Path(__file__).resolve()
DEPLOYED = HERE.parents[1] / "recover-beta056b2-release.py"
CANDIDATE = HERE.with_name("repair-20261019-beta056b2-recovery-verifier-v1.after.py")
VERIFIER_PATH = Path(os.environ["RECOVERY_VERIFIER_PATH"]) if "RECOVERY_VERIFIER_PATH" in os.environ else (
    DEPLOYED if DEPLOYED.is_file() else CANDIDATE)
SPEC = importlib.util.spec_from_file_location("beta056b2_recovery_under_test", VERIFIER_PATH)
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)

# Independent actual fixture. Do not derive it from any verifier input constant.
RAW_DISPATCH = b'''{
  "schemaVersion": 1,
  "event": "workflow_dispatch",
  "ref": "refs/tags/v0.5.6-beta.2",
  "sourceCommit": "96e6ca683fc60ce983d9426da186ed8d0c7bdedb",
  "workflowCommit": "96e6ca683fc60ce983d9426da186ed8d0c7bdedb",
  "runId": 39163405443,
  "attempt": 1,
  "inputs": {
    "publish_existing_055": false,
    "native_only": true,
    "tvos_test_only": false,
    "publish_release": false,
    "apple_only": false
  }
}
'''
TAG = "v0.5.6-beta.2"
SOURCE = "96e6ca683fc60ce983d9426da186ed8d0c7bdedb"
RELEASE = 416691309
TAG_OBJECT = "f93bb281b27cb60e86ca7d5f3dc9fd239afc1618"
APPLE = {"runId": 39163405443, "attempt": 1, "artifactId": 12152826504}
ANDROID = {"runId": 39163407259, "attempt": 1, "artifactId": 12150540496}
BOOLS = {"native_only": True, "publish_existing_055": False, "tvos_test_only": False,
         "publish_release": False, "apple_only": False}
OPTIONAL = ("release_tag", "recovery_source_commit", "resume_handoff", "mpvkit_artifacts_url",
            "mpvkit_artifacts_sha256", "release_id", "altstore_note")


class DraftUrlTests(unittest.TestCase):
    name = "VortX-tvOS-v0.5.6-beta.2-ci.ipa"
    slug = "untagged-60247beaa4d56a52ca14"

    def draft(self):
        return {"draft": True, "html_url": f"https://github.com/VortXTV/VortX/releases/tag/{self.slug}"}

    def url(self, slug):
        return f"https://github.com/VortXTV/VortX/releases/download/{slug}/{self.name}"

    def test_tag_urls_remain_valid_in_both_modes(self):
        for command, release in (("verify-draft", self.draft()), ("verify-published", {"draft": False})):
            V.validate_asset_url(command, release, TAG, self.name, self.url(TAG))

    def test_temporary_url_is_bound_to_authenticated_draft_html(self):
        before = copy.deepcopy(self.draft())
        V.validate_asset_url("verify-draft", before, TAG, self.name, self.url(self.slug))
        self.assertEqual(before, self.draft())
        for html in (None, 0, "", self.draft()["html_url"] + "\n",
                     self.draft()["html_url"] + "?x=1", self.draft()["html_url"] + "#x",
                     self.draft()["html_url"].replace("github.com", "example.invalid"),
                     self.draft()["html_url"].replace(self.slug, "untagged-" + "a" * 20),
                     self.draft()["html_url"].replace(self.slug, "untagged-" + "a" * 19),
                     self.draft()["html_url"].replace(self.slug, "untagged-" + "a" * 21),
                     self.draft()["html_url"].replace(self.slug, "untagged-" + "G" * 20)):
            with self.subTest(html=html), self.assertRaises(ValueError):
                V.validate_asset_url("verify-draft", {"draft": True, "html_url": html}, TAG, self.name, self.url(self.slug))

    def test_temporary_urls_never_pass_published_or_unknown_modes(self):
        for command in ("verify-published", "prepare", "", None, 1, True):
            with self.subTest(command=command), self.assertRaises(ValueError):
                V.validate_asset_url(command, self.draft(), TAG, self.name, self.url(self.slug))
        for draft in (False, None, 1, "true"):
            with self.subTest(draft=draft), self.assertRaises(ValueError):
                V.validate_asset_url("verify-draft", dict(self.draft(), draft=draft), TAG, self.name, self.url(self.slug))

    def test_draft_urls_reject_host_repo_name_and_suffix_changes(self):
        good = self.url(self.slug)
        for bad in (None, 1, "", good + "\n", good + "?x=1", good + "#x", good + "/",
                    good.replace("github.com", "example.invalid"), good.replace("VortXTV/VortX", "other/VortX"),
                    good.replace(self.name, self.name + ".extra"), good.replace(self.slug, TAG + "-wrong"),
                    good.replace(self.slug, "untagged-" + "a" * 20)):
            with self.subTest(url=bad), self.assertRaises(ValueError):
                V.validate_asset_url("verify-draft", self.draft(), TAG, self.name, bad)


class DispatchTests(unittest.TestCase):
    def receipt(self):
        return json.loads(RAW_DISPATCH)

    def validate(self, receipt, pointer=None, tag=TAG, source=SOURCE):
        V.validate_dispatch(receipt, APPLE if pointer is None else pointer, tag, source)

    def test_independent_actual_raw_fixture(self):
        self.assertEqual(len(RAW_DISPATCH), 421)
        self.assertEqual(hashlib.sha256(RAW_DISPATCH).hexdigest(),
                         "ad2039da0759f1921efd7c508d7702ced556233fc8513d6fb08ac111981cbe42")
        receipt = self.receipt()
        self.assertEqual(receipt["inputs"], BOOLS)
        before = copy.deepcopy(receipt)
        self.validate(receipt)
        self.assertEqual(receipt, before)
        self.assertNotIn("release_tag", receipt["inputs"])

    def test_full_and_each_partial_optional_shape_without_mutation(self):
        for names in (OPTIONAL, *((key,) for key in OPTIONAL)):
            with self.subTest(optional=names):
                receipt = self.receipt()
                receipt["inputs"].update({key: "" for key in names})
                before = copy.deepcopy(receipt)
                self.validate(receipt)
                self.assertEqual(receipt, before)

    def test_each_missing_boolean(self):
        for key in BOOLS:
            with self.subTest(key=key):
                receipt = self.receipt()
                del receipt["inputs"][key]
                with self.assertRaises(ValueError):
                    self.validate(receipt)

    def test_each_boolean_wrong_value_or_type(self):
        for key, expected in BOOLS.items():
            for bad in (0, 1, None, "true", "false", "", [], {}, not expected):
                with self.subTest(key=key, bad=bad):
                    receipt = self.receipt()
                    receipt["inputs"][key] = bad
                    with self.assertRaises(ValueError):
                        self.validate(receipt)

    def test_each_optional_nonempty_or_wrong_type(self):
        for key in OPTIONAL:
            for bad in ("unexpected", " ", None, 0, 1, True, False, [], {}):
                with self.subTest(key=key, bad=bad):
                    receipt = self.receipt()
                    receipt["inputs"][key] = bad
                    with self.assertRaises(ValueError):
                        self.validate(receipt)

    def test_unknown_input_and_nondictionary_inputs(self):
        receipt = self.receipt()
        receipt["inputs"]["unknown"] = ""
        with self.assertRaises(ValueError):
            self.validate(receipt)
        for bad in (None, [], "", False, 1):
            with self.subTest(bad=bad):
                receipt = self.receipt()
                receipt["inputs"] = bad
                with self.assertRaises(ValueError):
                    self.validate(receipt)

    def test_metadata_and_top_level_shape_drift(self):
        replacements = {"schemaVersion": (2, True), "event": ("release",),
                        "ref": ("refs/heads/main", "refs/tags/v0.5.6-beta.3"),
                        "sourceCommit": ("0" * 40,), "workflowCommit": ("0" * 40,),
                        "runId": (39163405444, "39163405443"), "attempt": (2, True, "1")}
        for key, bad_values in replacements.items():
            for bad in bad_values:
                with self.subTest(key=key, bad=bad):
                    receipt = self.receipt()
                    receipt[key] = bad
                    with self.assertRaises(ValueError):
                        self.validate(receipt)
        for key in self.receipt():
            with self.subTest(missing=key):
                receipt = self.receipt()
                del receipt[key]
                with self.assertRaises(ValueError):
                    self.validate(receipt)
        receipt = self.receipt()
        receipt["unexpected"] = None
        with self.assertRaises(ValueError):
            self.validate(receipt)
        for bad in (None, [], False):
            with self.assertRaises(ValueError):
                self.validate(bad)

    def test_caller_binding_drift(self):
        for tag, source in (("v0.5.6-beta.3", SOURCE), (TAG, "0" * 40)):
            with self.assertRaises(ValueError):
                self.validate(self.receipt(), tag=tag, source=source)
        for key in APPLE:
            pointer = dict(APPLE)
            pointer[key] += 1
            with self.assertRaises(ValueError):
                self.validate(self.receipt(), pointer=pointer)


class RecoveryPinsTests(unittest.TestCase):
    def test_release_version_build_pins(self):
        good = [TAG, SOURCE, RELEASE, "0.5.6", "276"]
        V.recovery_identity(*good)
        for index, bad in enumerate(("v0.5.6-beta.3", "0" * 40, 416691310, "0.5.7", "277")):
            with self.subTest(index=index):
                args = list(good)
                args[index] = bad
                with self.assertRaises(ValueError):
                    V.recovery_identity(*args)
        for bad in (str(RELEASE), True, float(RELEASE)):
            with self.assertRaises(ValueError):
                V.recovery_identity(TAG, SOURCE, bad)
        with self.assertRaises(ValueError):
            V.recovery_identity(TAG, SOURCE, RELEASE, "0.5.6", 276)

    def test_both_exact_pointers_and_each_field_drift(self):
        for lane, fixture in (("apple", APPLE), ("android", ANDROID)):
            V.recovery_pointer(lane, dict(fixture))
            for key in fixture:
                for bad in (fixture[key] + 1, str(fixture[key]), None, True):
                    with self.subTest(lane=lane, key=key, bad=bad):
                        pointer = dict(fixture)
                        pointer[key] = bad
                        with self.assertRaises(ValueError):
                            V.recovery_pointer(lane, pointer)
                pointer = dict(fixture)
                del pointer[key]
                with self.assertRaises(ValueError):
                    V.recovery_pointer(lane, pointer)
            with self.assertRaises(ValueError):
                V.recovery_pointer(lane, dict(fixture, unknown=1))
        with self.assertRaises(ValueError):
            V.recovery_pointer("apple", ANDROID)
        with self.assertRaises(ValueError):
            V.recovery_pointer("unknown", APPLE)

    def test_both_original_artifact_sizes_and_digests(self):
        fixtures = {
            "apple": {"size_in_bytes": 216906795, "digest": "sha256:6a619e2982396ee5ee5d8c3da444cda4f41c5a9ac3128bd8924b305c1c329ce8"},
            "android": {"size_in_bytes": 185302478, "digest": "sha256:d98e5d428e05764528d3c6ffc2030ba0290ed78ea1c24e0770172b0a3267659e"},
        }
        for lane, fixture in fixtures.items():
            V.recovery_artifact(lane, fixture)
            for key, bad in (("size_in_bytes", fixture["size_in_bytes"] + 1),
                             ("size_in_bytes", str(fixture["size_in_bytes"])),
                             ("digest", "sha256:" + "0" * 64)):
                with self.subTest(lane=lane, key=key):
                    artifact = dict(fixture)
                    artifact[key] = bad
                    with self.assertRaises(ValueError):
                        V.recovery_artifact(lane, artifact)

    def test_wrong_pointer_fails_before_api(self):
        with mock.patch.object(V, "api") as api:
            with self.assertRaises(ValueError):
                V.authenticate_build("apple", dict(APPLE, attempt=2), TAG, SOURCE, set(), Path("unused"))
            api.assert_not_called()

    def test_annotated_tag_and_peeled_source_both_pinned(self):
        good = [{"object": {"type": "tag", "sha": TAG_OBJECT}},
                {"object": {"type": "commit", "sha": SOURCE}}]
        with mock.patch.object(V, "api", side_effect=good) as api:
            V.check_tag(TAG, SOURCE)
            self.assertEqual(api.call_args_list, [mock.call("git/ref/tags/" + TAG),
                                                 mock.call("git/tags/" + TAG_OBJECT)])
        for first in ({"type": "commit", "sha": SOURCE}, {"type": "tag", "sha": "0" * 40}):
            with mock.patch.object(V, "api", return_value={"object": first}):
                with self.assertRaises(ValueError):
                    V.check_tag(TAG, SOURCE)
        with mock.patch.object(V, "api", side_effect=[good[0], {"object": {"type": "commit", "sha": "0" * 40}}]):
            with self.assertRaises(ValueError):
                V.check_tag(TAG, SOURCE)

    def test_stable_latest_and_main_drift(self):
        latest = {"id": 415681390, "tag_name": "v0.5.5", "prerelease": False, "draft": False}
        main = {"object": {"sha": "bcc7ed2dfcca91e900cebe25f6921d4294e23868"}}
        helper = argparse.Namespace(capture_public_routes=mock.Mock(return_value={"route": "original"}))
        with mock.patch.object(V, "api", side_effect=[latest, main]):
            stable = V.stable_snapshot(TAG, helper)
            self.assertEqual(stable["latest"], {"id": 415681390, "tag": "v0.5.5"})
        bad_latest = (dict(latest, id=415681391), dict(latest, tag_name="v0.5.4"),
                      dict(latest, tag_name=TAG), dict(latest, prerelease=True), dict(latest, draft=True))
        for bad in bad_latest:
            with self.subTest(latest=bad), mock.patch.object(V, "api", side_effect=[bad, main]):
                with self.assertRaises(ValueError):
                    V.stable_snapshot(TAG, helper)
        with mock.patch.object(V, "api", side_effect=[latest, {"object": {"sha": "0" * 40}}]):
            with self.assertRaises(ValueError):
                V.stable_snapshot(TAG, helper)


class PublicRecoverySourceTests(unittest.TestCase):
    def args(self):
        return argparse.Namespace(recovery_verifier_sha256=hashlib.sha256(VERIFIER_PATH.read_bytes()).hexdigest(),
                                  recovery_source_commit="a" * 40)

    def payload(self):
        own = VERIFIER_PATH.read_bytes()
        return {"type": "file", "encoding": "base64", "path": "scripts/recover-beta056b2-release.py",
                "size": len(own), "content": base64.encodebytes(own).decode("ascii")}

    def authenticate(self, payload, args=None):
        with mock.patch.object(V.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(payload).encode())) as get:
            result = V.authenticate_recovery_source(self.args() if args is None else args)
            request = get.call_args.args[0]
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.full_url,
                             "https://api.github.com/repos/VortXTV/VortX/contents/scripts/recover-beta056b2-release.py?ref=" + "a" * 40)
            self.assertFalse(request.has_header("Authorization"))
            return result

    def test_mocked_public_exact_commit_self_bytes(self):
        result = self.authenticate(self.payload())
        self.assertEqual(result["sourceCommit"], "a" * 40)
        self.assertEqual(result["path"], "scripts/recover-beta056b2-release.py")
        self.assertEqual(result["originalVerifier"]["sha256"],
                         "10a2fa9c5f243616ad0fe0735e369421272cb76718d6def27fb96f5cf7d894aa")
        self.assertEqual(result["exception"]["originalPublishedEventVerifier"],
                         "expected-to-fail-original-typed-input-shape")
        self.assertNotIn(str(HERE.parent), json.dumps(result))

    def test_review_hash_and_recovery_commit_fail_before_network(self):
        for key, bad in (("recovery_verifier_sha256", "0" * 64),
                         ("recovery_verifier_sha256", "not-a-hash"),
                         ("recovery_source_commit", "main"), ("recovery_source_commit", "a" * 39),
                         ("recovery_source_commit", "A" * 40)):
            with self.subTest(key=key), mock.patch.object(V.urllib.request, "urlopen") as get:
                args = self.args()
                setattr(args, key, bad)
                with self.assertRaises(ValueError):
                    V.authenticate_recovery_source(args)
                get.assert_not_called()

    def test_public_type_encoding_path_size_or_content_drift(self):
        for key, bad in (("type", "symlink"), ("encoding", "none"), ("path", "scripts/other.py"),
                         ("size", 0), ("size", True), ("size", "123"), ("size", 262145),
                         ("content", None), ("content", "invalid!"),
                         ("content", base64.b64encode(b"altered").decode("ascii"))):
            with self.subTest(key=key, bad=bad):
                payload = self.payload()
                payload[key] = bad
                with self.assertRaises(ValueError):
                    self.authenticate(payload)

    def test_oversized_source_response_fails(self):
        with mock.patch.object(V.urllib.request, "urlopen", return_value=io.BytesIO(b" " * 524289)):
            with self.assertRaisesRegex(ValueError, "response exceeds bound"):
                V.authenticate_recovery_source(self.args())

    def test_public_read_failure_propagates(self):
        with mock.patch.object(V.urllib.request, "urlopen", side_effect=OSError("unavailable")):
            with self.assertRaises(OSError):
                V.authenticate_recovery_source(self.args())

    def test_every_command_authenticates_recovery_before_helper_import(self):
        for command in ("prepare", "verify-draft", "verify-published"):
            argv = [str(VERIFIER_PATH), command, "--tag", TAG, "--source-commit", SOURCE,
                    "--release-id", str(RELEASE), "--repo-root", "unused", "--work-dir", "unused",
                    "--bundletool", "unused", "--recovery-verifier-sha256", "0" * 64,
                    "--recovery-source-commit", "a" * 40]
            if command == "prepare":
                argv += ["--apple-run", "39163405443", "--apple-attempt", "1", "--apple-artifact", "12152826504",
                         "--android-run", "39163407259", "--android-attempt", "1", "--android-artifact", "12150540496"]
            with self.subTest(command=command), mock.patch.object(V.sys, "argv", argv), \
                    mock.patch.object(V, "authenticate_recovery_source", side_effect=ValueError("review gate")) as gate, \
                    mock.patch.object(V, "source_contract") as contract, \
                    mock.patch.object(V.importlib.util, "spec_from_file_location") as helper_import, \
                    mock.patch.object(V, "api") as api:
                with self.assertRaisesRegex(ValueError, "review gate"):
                    V.main()
                gate.assert_called_once()
                contract.assert_not_called()
                helper_import.assert_not_called()
                api.assert_not_called()

    def test_both_recovery_flags_required_on_every_command(self):
        for command in ("prepare", "verify-draft", "verify-published"):
            for omitted in ("--recovery-verifier-sha256", "--recovery-source-commit"):
                argv = [str(VERIFIER_PATH), command, "--tag", TAG, "--source-commit", SOURCE,
                        "--release-id", str(RELEASE), "--repo-root", "unused", "--work-dir", "unused",
                        "--bundletool", "unused"]
                for flag, value in (("--recovery-verifier-sha256", "0" * 64),
                                    ("--recovery-source-commit", "a" * 40)):
                    if flag != omitted:
                        argv += [flag, value]
                with self.subTest(command=command, omitted=omitted), mock.patch.object(V.sys, "argv", argv), \
                        mock.patch.object(V.sys, "stderr", io.StringIO()), mock.patch.object(V, "api") as api:
                    with self.assertRaises(SystemExit) as error:
                        V.main()
                    self.assertEqual(error.exception.code, 2)
                    api.assert_not_called()


class RetainedGuardTests(unittest.TestCase):
    def release(self):
        return {"id": RELEASE, "tag_name": TAG, "draft": False, "prerelease": True,
                "published_at": "2026-10-19T00:00:00Z",
                "body": "<!-- vortx-distribution: hosted-direct-beta -->\n"}

    def test_release_prerelease_marker_and_provenance_binding(self):
        V.release_identity(self.release(), RELEASE, TAG, False)
        for changes in ({"prerelease": False}, {"draft": True}, {"id": RELEASE + 1},
                        {"tag_name": "v0.5.6-beta.3"}, {"published_at": None},
                        {"body": "<!-- vortx-distribution: hosted-direct-beta -->\n<!-- vortx-channel: latest-beta -->"},
                        {"body": "<!-- vortx-distribution: hosted-direct-beta -->\n" * 2}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                V.release_identity(dict(self.release(), **changes), RELEASE, TAG, False)
        line = "<!-- vortx-ci-provenance-sha256: " + "a" * 64 + " -->"
        self.assertEqual(V.provenance_binding(line), "a" * 64)
        for body in ("", line + "\n" + line, line.replace("a" * 64, "not-a-digest")):
            with self.assertRaises(ValueError):
                V.provenance_binding(body)

    def test_native_workflow_tag_stays_empty_and_raw_dispatch_is_pinned(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            workflow = {"schemaVersion": 1, "sourceCommit": SOURCE, "workflowCommit": SOURCE,
                        "verifierSha256": "f" * 64, "tag": "", "runId": 39163405443, "attempt": 1}
            workflow_path = directory / "native-workflow-provenance.json"
            dispatch_path = directory / "native-ci-dispatch.json"
            workflow_path.write_text(json.dumps(workflow))
            dispatch_path.write_bytes(RAW_DISPATCH + b" ")
            args = (directory, APPLE, TAG, SOURCE, "0.5.6", "276",
                    {"scripts/verify-native-apple-package.py": "f" * 64}, argparse.Namespace())
            with self.assertRaisesRegex(ValueError, "raw dispatch receipt"):
                V.inspect_apple(*args)
            dispatch_path.write_bytes(RAW_DISPATCH)
            with mock.patch.object(V, "read_json", wraps=V.read_json) as read:
                with self.assertRaises(FileNotFoundError):
                    V.inspect_apple(*args)
                self.assertIn(mock.call(directory / "native-build-inputs.json"), read.call_args_list)
            workflow["tag"] = TAG
            workflow_path.write_text(json.dumps(workflow))
            with self.assertRaisesRegex(ValueError, "tag must remain empty"):
                V.inspect_apple(*args)

    def test_original_nine_source_paths_remain_exact(self):
        paths = ("scripts/verify-ci-direct-beta.py", "scripts/verify-apple-direct-test-release.py",
                 "scripts/verify-native-apple-package.py", "scripts/verify-android-release-signing.sh",
                 "scripts/verify-android-release-version.sh", ".github/workflows/release-tvos.yml",
                 ".github/workflows/android-release.yml", "app/project.yml", "android/app/build.gradle.kts")
        self.assertEqual(V.TOOLS, paths)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recorded = {path: ("unchanged " + path + "\n").encode() for path in paths}
            recorded["app/project.yml"] = ("MARKETING_VERSION: 0.5.6\nCURRENT_PROJECT_VERSION: 276\n" * 6).encode()
            recorded["android/app/build.gradle.kts"] = b'versionName = "0.5.6"\nversionCode = 276\n'
            for path, data in recorded.items():
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)

            def git_read(command, **kwargs):
                self.assertEqual(command[:3], ["git", "-C", str(root)])
                if command[3:] == ["rev-parse", "HEAD"]:
                    return SOURCE + "\n"
                self.assertEqual(command[3], "show")
                prefix, relative = command[4].split(":", 1)
                self.assertEqual(prefix, SOURCE)
                return recorded[relative]

            with mock.patch.object(V.subprocess, "check_output", side_effect=git_read):
                build, hashes = V.source_contract(root, SOURCE, "0.5.6")
                self.assertEqual(build, "276")
                self.assertEqual(hashes, {path: hashlib.sha256(data).hexdigest() for path, data in recorded.items()})
                for relative in paths:
                    with self.subTest(path=relative):
                        (root / relative).write_bytes(recorded[relative] + b"changed")
                        with self.assertRaisesRegex(ValueError, "working file differs"):
                            V.source_contract(root, SOURCE, "0.5.6")
                        (root / relative).write_bytes(recorded[relative])
            with mock.patch.object(V.subprocess, "check_output", return_value="0" * 40 + "\n"):
                with self.assertRaisesRegex(ValueError, "exact source commit"):
                    V.source_contract(root, SOURCE, "0.5.6")

    def test_original_successful_step_and_forbidden_publication_guards(self):
        skips = {"apple": ("Validate immutable Beta 1 source recovery", "Build the content-addressed release feed artifact",
                           "Upload the immutable feed handoff", "Constrain legacy comparison to artifact-only builds",
                           "Constrain Full tvOS test mode to artifact-only builds", "Package Full tvOS test IPA"),
                 "android": ("Refuse Android-only publication",)}
        for lane, pointer in (("apple", APPLE), ("android", ANDROID)):
            _, job_name, _, required, upload = V.LANES[lane]
            steps = [{"name": name, "status": "completed", "conclusion": "success"} for name in required]
            steps += [{"name": name, "status": "completed", "conclusion": "skipped"} for name in skips[lane]]
            job = {"name": job_name, "run_id": pointer["runId"], "run_attempt": 1,
                   "head_sha": SOURCE, "status": "completed", "conclusion": "success", "steps": steps}
            accepted, uploaded = V.successful_job([job], lane, pointer["runId"], 1, SOURCE)
            self.assertEqual(accepted, job)
            self.assertEqual(uploaded["name"], upload)
            for index in (0, len(required) - 1, len(required)):
                bad = copy.deepcopy(job)
                bad["steps"][index]["conclusion"] = "failure" if index < len(required) else "success"
                with self.subTest(lane=lane, index=index), self.assertRaises(ValueError):
                    V.successful_job([bad], lane, pointer["runId"], 1, SOURCE)
            with self.assertRaises(ValueError):
                V.successful_job([job, job], lane, pointer["runId"], 1, SOURCE)

    def test_exact_upload_id_size_digest_log_and_time_guards(self):
        artifact = {"digest": "sha256:" + "a" * 64, "name": "VortX-tvOS-ci", "id": 12152826504,
                    "size_in_bytes": 216906795, "created_at": "2026-10-19T01:00:01Z"}
        step = {"started_at": "2026-10-19T01:00:00Z", "completed_at": "2026-10-19T01:00:03Z"}
        lines = ["2026-10-19T01:00:01Z SHA256 digest of uploaded artifact is " + "a" * 64,
                 "2026-10-19T01:00:02Z Artifact VortX-tvOS-ci successfully finalized. Artifact ID 12152826504",
                 "2026-10-19T01:00:03Z Artifact VortX-tvOS-ci has been successfully uploaded! Final size is 216906795 bytes. Artifact ID is 12152826504"]
        V.upload_proof(artifact, step, lines)
        for bad in (lines[:-1], lines + [lines[0]], [line.replace("216906795", "216906796") for line in lines],
                    [lines[0].replace("01:00:01", "00:59:59"), *lines[1:]]):
            with self.assertRaises(ValueError):
                V.upload_proof(artifact, step, bad)
        with self.assertRaises(ValueError):
            V.upload_proof(dict(artifact, created_at="2026-10-19T00:59:59Z"), step, lines)

    def test_seven_packages_and_nine_public_asset_names(self):
        apple, _, android = V.file_matrix(TAG, "0.5.6")
        expected = {"VortX-iOS-v0.5.6-beta.2-ci.ipa", "VortX-tvOS-v0.5.6-beta.2-ci.ipa",
                    "VortX-tvOS-lite-v0.5.6-beta.2-ci.ipa", "VortX-macOS-v0.5.6-beta.2-ci.dmg",
                    "VortX-0.5.6-full-mpv-universal.apk", "VortX-0.5.6-play-media3-universal.apk",
                    "VortX-0.5.6-play-media3.aab", "SHA256SUMS.txt", "VortX-Hosted-Direct-Beta-Provenance.json"}
        actual = {name.replace("-ci.", "-v0.5.6-beta.2-ci.") for name in apple.values()} | android | {
            "SHA256SUMS.txt", "VortX-Hosted-Direct-Beta-Provenance.json"}
        self.assertEqual(actual, expected)
        assets = [{"id": 100 + i, "name": name, "state": "uploaded", "size": 1,
                   "digest": "sha256:" + "a" * 64, "browser_download_url": "https://example.invalid/" + name}
                  for i, name in enumerate(sorted(expected))]
        self.assertEqual(set(V.release_assets({"assets": assets}, expected)), expected)
        for bad in (assets[:-1], assets + [dict(assets[0], id=999)],
                    [dict(asset, digest="sha256:" + "x" * 64) for asset in assets]):
            with self.assertRaises(ValueError):
                V.release_assets({"assets": bad}, expected)

    def test_zip_original_hash_and_flat_regular_entry_guards(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "original.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("payload", b"original")
            data = archive.read_bytes()
            metadata = {"size_in_bytes": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
            V.extract_exact(archive, metadata, {"payload"}, root / "accepted")
            self.assertEqual((root / "accepted/payload").read_bytes(), b"original")
            with self.assertRaisesRegex(ValueError, "ZIP digest"):
                V.extract_exact(archive, dict(metadata, digest="sha256:" + "0" * 64), {"payload"}, root / "bad-hash")
            with self.assertRaises(ValueError):
                V.extract_exact(archive, metadata, {"other"}, root / "bad-names")
            unsafe = root / "unsafe.zip"
            with zipfile.ZipFile(unsafe, "w") as output:
                output.writestr("../payload", b"original")
            data = unsafe.read_bytes()
            metadata = {"size_in_bytes": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
            with self.assertRaisesRegex(ValueError, "unsafe artifact ZIP entry"):
                V.extract_exact(unsafe, metadata, {"../payload"}, root / "bad-path")

    def test_public_download_rejects_altered_bytes_without_real_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            for data, size, digest in ((b"altered", 7, hashlib.sha256(b"original").hexdigest()),
                                       (b"too-long", 1, "a" * 64)):
                destination = Path(temporary) / hashlib.sha256(data).hexdigest()
                with self.subTest(data=data), mock.patch.object(V.urllib.request, "urlopen", return_value=io.BytesIO(data)):
                    with self.assertRaises(ValueError):
                        V.public_download(TAG, "asset", destination, size, digest)


if __name__ == "__main__":
    unittest.main()
