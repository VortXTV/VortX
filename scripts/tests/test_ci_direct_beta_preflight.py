"""Regression fixtures for the hosted direct-beta release preflight.

Run in the root-owned local test slot:
CI_DIRECT_BETA_REPO_ROOT=<exact integration checkout> python3 -B <this file>
No real API requests, package tools, app builds, signing, or publication occur.
The producer test executes only the actual workflow's isolated jq receipt step.
"""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

HERE = Path(__file__).resolve()
ROOT = Path(os.environ.get("CI_DIRECT_BETA_REPO_ROOT", HERE.parents[2]))
SPEC = importlib.util.spec_from_file_location("ci_direct_beta_preflight", ROOT / "scripts/verify-ci-direct-beta.py")
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)
FIXTURES = json.loads(HERE.with_name("ci-direct-beta-preflight-fixtures.json").read_bytes())
CASE = FIXTURES["beta3"]
BOOLS = CASE["booleans"]
STRINGS = CASE["strings"]
EXPECTED = {**BOOLS, **{key: "" for key in STRINGS}}
TAG, SOURCE = CASE["tag"], CASE["source"]
POINTER = {"runId": CASE["runId"], "attempt": CASE["attempt"], "artifactId": 789}
RAW_ORIGINAL = b'''{
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


def receipt(inputs=EXPECTED):
    return {"schemaVersion": 1, "event": "workflow_dispatch", "ref": "refs/tags/" + TAG,
            "sourceCommit": SOURCE, "workflowCommit": SOURCE, "runId": POINTER["runId"],
            "attempt": POINTER["attempt"], "inputs": copy.deepcopy(inputs)}


class ProducerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = (ROOT / ".github/workflows/release-tvos.yml").read_text()
        step = workflow.split("      - name: Record artifact-only dispatch inputs for hosted beta verification\n")
        if len(step) != 2:
            raise AssertionError("expected one exact producer workflow step")
        section = step[1].split("\n      - name:", 1)[0]
        cls.script = textwrap.dedent(section.split("        run: |\n", 1)[1])

    def produce(self, inputs):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "out").mkdir()
            environment = dict(os.environ, DISPATCH_INPUTS_JSON=json.dumps(inputs),
                               GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/tags/" + TAG,
                               BUILD_SOURCE_SHA=SOURCE, GITHUB_SHA=SOURCE,
                               GITHUB_RUN_ID=str(POINTER["runId"]), GITHUB_RUN_ATTEMPT="1")
            result = subprocess.run(["bash", "-c", self.script], cwd=directory, env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            path = directory / "out/native-ci-dispatch.json"
            return result.returncode, path.read_bytes() if path.exists() else b""

    def test_actual_sparse_and_complete_inputs_emit_exact_twelve_typed_fields(self):
        samples = [BOOLS, EXPECTED] + [{**BOOLS, key: ""} for key in STRINGS]
        for inputs in samples:
            with self.subTest(keys=sorted(inputs)):
                status, raw = self.produce(inputs)
                self.assertEqual(status, 0)
                observed = json.loads(raw)
                self.assertEqual(observed, receipt())
                self.assertEqual(len(observed["inputs"]), 12)
                V.validate_dispatch(observed, POINTER, TAG, SOURCE)

    def test_unknown_missing_or_mistyped_boolean_inputs_fail(self):
        invalid = [None, [], {}, {**BOOLS, "unknown": ""}]
        for key in BOOLS:
            invalid.append({name: value for name, value in BOOLS.items() if name != key})
            invalid.extend({**BOOLS, key: value} for value in (None, 0, 1, "true", "false"))
        for inputs in invalid:
            with self.subTest(inputs=inputs):
                status, raw = self.produce(inputs)
                self.assertNotEqual(status, 0)
                self.assertFalse(raw)

    def test_every_optional_string_rejects_wrong_type(self):
        for key in STRINGS:
            for value in (None, False, 0, [], {}):
                with self.subTest(key=key, value=value):
                    status, raw = self.produce({**BOOLS, key: value})
                    self.assertNotEqual(status, 0)
                    self.assertFalse(raw)

    def test_actual_nondefault_values_are_recorded_truthfully_and_strict_release_reader_rejects(self):
        actual_values = [(key, not value) for key, value in BOOLS.items()]
        actual_values += [(key, value) for key in STRINGS for value in ("nonempty", " ")]
        for key, value in actual_values:
            with self.subTest(key=key, value=value):
                status, raw = self.produce({**BOOLS, key: value})
                self.assertEqual(status, 0)
                observed = json.loads(raw)
                self.assertEqual(observed, receipt({**EXPECTED, key: value}))
                self.assertEqual(len(observed["inputs"]), 12)
                with self.assertRaisesRegex(ValueError, "original typed Apple dispatch inputs differ"):
                    V.validate_dispatch(observed, POINTER, TAG, SOURCE)


class StrictReaderContract(unittest.TestCase):
    def test_original_beta2_receipt_hash_remains_exact_and_reader_rejects_sparse_receipt(self):
        original = FIXTURES["beta2OriginalReceipt"]
        self.assertEqual(len(RAW_ORIGINAL), original["bytes"])
        self.assertEqual(hashlib.sha256(RAW_ORIGINAL).hexdigest(), original["sha256"])
        before = bytes(RAW_ORIGINAL)
        with self.assertRaisesRegex(ValueError, "original typed Apple dispatch inputs differ"):
            V.validate_dispatch(json.loads(RAW_ORIGINAL), {"runId": 39163405443, "attempt": 1},
                                "v0.5.6-beta.2", "96e6ca683fc60ce983d9426da186ed8d0c7bdedb")
        self.assertEqual(RAW_ORIGINAL, before)

    def test_reader_stays_strict_for_missing_extra_type_value_and_identity(self):
        V.validate_dispatch(receipt(), POINTER, TAG, SOURCE)
        invalid = [receipt(BOOLS), receipt({**EXPECTED, "unknown": ""})]
        for key, value in EXPECTED.items():
            invalid.append(receipt({name: item for name, item in EXPECTED.items() if name != key}))
            invalid.append(receipt({**EXPECTED, key: "false" if type(value) is bool else False}))
            invalid.append(receipt({**EXPECTED, key: not value if type(value) is bool else "nonempty"}))
        for key, value in (("sourceCommit", "c" * 40), ("workflowCommit", "c" * 40),
                           ("ref", "refs/heads/main"), ("runId", 124), ("attempt", True)):
            invalid.append({**receipt(), key: value})
        for value in invalid:
            before = copy.deepcopy(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                V.validate_dispatch(value, POINTER, TAG, SOURCE)
            self.assertEqual(value, before)


class RawProcess:
    def __init__(self, payload, status=0):
        self.stdout = io.BytesIO(payload)
        self.status = status
        self.returncode = None
        self.killed = False

    def wait(self, timeout=None):
        if self.returncode is None:
            self.returncode = self.status
        return self.returncode

    def poll(self):
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9


class RawTransportContract(unittest.TestCase):
    payload = b"\x1b[36;1mraw CI line\x1b[0m\nPK\x03\x04\x00\xff\x1b]8;;https://example.invalid\x07"

    def download(self, process, limit, accept=None, options=("--allow-escape-sequences",), endpoint="actions/jobs/123/logs"):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "raw"
            with mock.patch.object(V, "gh_raw_options", return_value=options) as capability, \
                    mock.patch.object(V.subprocess, "Popen", return_value=process) as popen:
                try:
                    V.api_download(endpoint, destination, limit, accept)
                finally:
                    self.assertEqual(popen.call_count, 1)  # No flag fallback/retry after raw failure.
                    capability.assert_called_once_with()
            return destination.read_bytes(), popen.call_args

    def test_escape_and_binary_bytes_are_exactly_captured_without_terminal_rendering(self):
        process = RawProcess(self.payload)
        raw, call = self.download(process, len(self.payload))
        self.assertEqual(raw, self.payload)
        self.assertEqual(call.args[0], ["gh", "api", "--method", "GET", "--allow-escape-sequences",
                                       "--", "repos/VortXTV/VortX/actions/jobs/123/logs"])
        self.assertEqual(call.kwargs, {"stdout": subprocess.PIPE})
        self.assertTrue(process.stdout.closed)

    def test_octet_stream_header_is_preserved_on_raw_capture(self):
        _, call = self.download(RawProcess(self.payload), len(self.payload), "application/octet-stream")
        self.assertIn("Accept: application/octet-stream", call.args[0])

    def test_old_cli_preserves_full_escape_and_binary_bytes_without_option(self):
        raw, call = self.download(RawProcess(self.payload), len(self.payload), options=())
        self.assertEqual(raw, self.payload)
        self.assertEqual(call.args[0], ["gh", "api", "--method", "GET", "--",
                                       "repos/VortXTV/VortX/actions/jobs/123/logs"])

    def test_old_and_new_cli_preserve_exact_artifact_and_asset_ids(self):
        for options in ((), ("--allow-escape-sequences",)):
            for endpoint, accept in (("actions/artifacts/789/zip", None),
                                     ("releases/assets/456", "application/octet-stream")):
                with self.subTest(options=options, endpoint=endpoint):
                    raw, call = self.download(RawProcess(self.payload), len(self.payload), accept, options, endpoint)
                    expected = ["gh", "api", "--method", "GET", *options]
                    if accept:
                        expected += ["-H", "Accept: " + accept]
                    expected += ["--", "repos/VortXTV/VortX/" + endpoint]
                    self.assertEqual(call.args[0], expected)
                    self.assertEqual(raw, self.payload)

    def test_nonzero_cli_exit_still_rejects_and_does_not_hide_endpoint(self):
        process = RawProcess(self.payload, status=1)
        with self.assertRaisesRegex(ValueError, "GitHub raw read failed: actions/jobs/123/logs"):
            self.download(process, len(self.payload))
        self.assertTrue(process.stdout.closed)

    def test_declared_bound_still_rejects_and_reaps_child(self):
        process = RawProcess(self.payload)
        with self.assertRaisesRegex(ValueError, "download exceeds declared bound"):
            self.download(process, len(self.payload) - 1)
        self.assertTrue(process.killed)
        self.assertTrue(process.stdout.closed)

    def test_existing_destination_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "raw"
            destination.write_bytes(b"prior")
            with mock.patch.object(V, "gh_raw_options", return_value=()), \
                    mock.patch.object(V.subprocess, "Popen") as popen, self.assertRaises(FileExistsError):
                V.api_download("actions/jobs/123/logs", destination, 100)
            popen.assert_not_called()
            self.assertEqual(destination.read_bytes(), b"prior")

    def test_json_metadata_path_does_not_receive_escape_output_permission(self):
        with mock.patch.object(V.subprocess, "check_output", return_value=b"{}") as output:
            self.assertEqual(V.api("actions/runs/123"), {})
        self.assertEqual(output.call_args.args[0], ["gh", "api", "--method", "GET", "--",
                                                  "repos/VortXTV/VortX/actions/runs/123"])


class CliCapabilityContract(unittest.TestCase):
    old_help = b"USAGE\n  gh api <endpoint> [flags]\n\nFLAGS\n  -X, --method string   HTTP method\n\nLEARN MORE\n  https://cli.github.com/manual\n"
    new_help = old_help.replace(b"FLAGS\n", b"FLAGS\n      --allow-escape-sequences   Allow printing terminal escape sequences\n", 1)
    version = b"gh version 2.96.0 (fixture)\nhttps://github.com/cli/cli/releases/tag/v2.96.0\n"

    def setUp(self):
        V.gh_raw_options.cache_clear()

    def tearDown(self):
        V.gh_raw_options.cache_clear()

    def test_old_and_new_help_are_cached_once_with_version_and_help_hash_receipt(self):
        for help_raw, expected in ((self.old_help, ()), (self.new_help, ("--allow-escape-sequences",)),
                                   (self.new_help.replace(b"\n", b"\r\n"), ("--allow-escape-sequences",))):
            with self.subTest(expected=expected):
                V.gh_raw_options.cache_clear()
                with mock.patch.object(V, "gh_metadata", side_effect=(help_raw, self.version)) as metadata, \
                        mock.patch.object(V.sys, "stderr", io.StringIO()) as recorded:
                    self.assertEqual(V.gh_raw_options(), expected)
                    self.assertEqual(V.gh_raw_options(), expected)
                self.assertEqual(metadata.call_args_list, [mock.call(("api", "--help")), mock.call(("--version",))])
                lines = recorded.getvalue().splitlines()
                self.assertEqual(len(lines), 1)
                observed = json.loads(lines[0].removeprefix("GitHub raw transport capability: "))
                self.assertEqual(observed, {"schemaVersion": 1, "version": "gh version 2.96.0 (fixture)",
                                           "versionSha256": hashlib.sha256(self.version).hexdigest(),
                                           "apiHelpSha256": hashlib.sha256(help_raw).hexdigest(),
                                           "apiHelpBytes": len(help_raw), "rawOptions": list(expected)})

    def test_unrecognized_truncated_control_and_ambiguous_capability_help_reject(self):
        malformed = (b"", b"not api help\n", self.old_help.replace(b"LEARN MORE", b"TRUNCATED"),
                     self.old_help + b"\x1b[31m", self.old_help + b"--allow-escape-sequences\n",
                     self.new_help.replace(b"FLAGS\n", b"FLAGS\n      --allow-escape-sequences   Duplicate\n", 1),
                     self.new_help.replace(b"--allow-escape-sequences ", b"--allow-escape-sequences-other "))
        for help_raw in malformed:
            with self.subTest(help_raw=help_raw):
                V.gh_raw_options.cache_clear()
                with mock.patch.object(V, "gh_metadata", side_effect=(help_raw, self.version)), \
                        self.assertRaises(ValueError):
                    V.gh_raw_options()

    def test_unrecognized_version_rejects_before_raw_download(self):
        with mock.patch.object(V, "gh_metadata", side_effect=(self.old_help, b"unknown version\n")), \
                self.assertRaisesRegex(ValueError, "unrecognized CLI version metadata"):
            V.gh_raw_options()

    def test_failed_capability_does_not_spawn_or_retry_raw_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "raw"
            with mock.patch.object(V, "gh_metadata", side_effect=ValueError("metadata failed")) as metadata, \
                    mock.patch.object(V.subprocess, "Popen") as raw, self.assertRaises(ValueError):
                V.api_download("actions/jobs/123/logs", destination, 100)
            self.assertEqual(metadata.call_count, 1)
            raw.assert_not_called()
            self.assertFalse(destination.exists())


class BoundedCliMetadataContract(unittest.TestCase):
    def capture(self, chunks, status=0, ready=True):
        process = RawProcess(b"", status)
        process.stdout = mock.Mock()
        process.stdout.fileno.return_value = 42
        selector = mock.Mock()
        selector.select.return_value = [(None, None)] if ready else []
        manager = mock.MagicMock()
        manager.__enter__.return_value = selector
        with mock.patch.object(V.subprocess, "Popen", return_value=process) as popen, \
                mock.patch.object(V.selectors, "DefaultSelector", return_value=manager), \
                mock.patch.object(V.os, "read", side_effect=chunks) as read:
            try:
                result = V.gh_metadata(("api", "--help"))
            finally:
                self.assertTrue(process.stdout.close.called)
                self.assertEqual(popen.call_args.args[0], ["gh", "api", "--help"])
                self.assertEqual(popen.call_args.kwargs, {"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT})
                for call in read.call_args_list:
                    self.assertEqual(call.args[0], 42)
                    self.assertLessEqual(call.args[1], 4096)
        return result, process

    def test_bounded_help_capture_preserves_exact_bytes(self):
        result, process = self.capture([b"help\r\n", b"more\n", b""])
        self.assertEqual(result, b"help\r\nmore\n")
        self.assertFalse(process.killed)

    def test_metadata_nonzero_empty_overflow_and_timeout_fail_cleanly(self):
        cases = (([b"help", b""], 1, True, "CLI metadata command failed"),
                 ([b""], 0, True, "CLI metadata is empty"),
                 ([b"x" * 4096] * 16 + [b"x"], 0, True, "CLI metadata exceeds bound"),
                 ([], 0, False, "CLI metadata timed out"))
        for chunks, status, ready, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                self.capture(chunks, status, ready)

    def test_only_fixed_local_metadata_commands_are_admitted(self):
        with mock.patch.object(V.subprocess, "Popen") as popen, self.assertRaises(ValueError):
            V.gh_metadata(("api", "releases/456"))
        popen.assert_not_called()


class DraftIdentityAndUrlContract(unittest.TestCase):
    def draft(self):
        return copy.deepcopy(FIXTURES["beta2AuthenticatedDraftSubset"])

    def test_retained_actual_draft_url_subset_is_bound_to_exact_identity(self):
        draft = self.draft()
        before = copy.deepcopy(draft)
        V.release_identity(draft, 416691309, "v0.5.6-beta.2", True,
                           "96e6ca683fc60ce983d9426da186ed8d0c7bdedb")
        V.validate_asset_url("verify-draft", draft, draft["tag_name"], draft["assetName"], draft["assetUrl"])
        self.assertEqual(draft, before)

    def test_source_id_tag_draft_prerelease_and_published_state_mutations_reject(self):
        draft = self.draft()
        for key, value in (("id", 416691310), ("tag_name", TAG), ("target_commitish", "main"),
                           ("draft", False), ("draft", 1), ("prerelease", False),
                           ("published_at", "2026-10-20T00:00:00Z")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                V.release_identity({**draft, key: value}, 416691309, draft["tag_name"], True,
                                   draft["target_commitish"])

    def test_temporary_urls_only_work_for_authenticated_matching_drafts(self):
        draft = self.draft()
        for command in ("verify-published", "prepare", "", None):
            with self.subTest(command=command), self.assertRaises(ValueError):
                V.validate_asset_url(command, draft, draft["tag_name"], draft["assetName"], draft["assetUrl"])
        for key, value in (("draft", False), ("draft", "true"), ("draft", 1),
                           ("html_url", draft["html_url"] + "\n"),
                           ("html_url", draft["html_url"] + "?x=1"),
                           ("html_url", draft["html_url"].replace("github.com", "example.invalid")),
                           ("html_url", draft["html_url"].replace("88b70aa43090b5e5a27d", "a" * 20))):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                V.validate_asset_url("verify-draft", {**draft, key: value}, draft["tag_name"],
                                     draft["assetName"], draft["assetUrl"])

    def test_wrong_host_repository_filename_slug_and_suffix_reject(self):
        draft = self.draft()
        good = draft["assetUrl"]
        for bad in (None, 1, "", good + "\n", good + "?x=1", good + "#x", good + "/",
                    good.replace("github.com", "example.invalid"),
                    good.replace("VortXTV/VortX", "other/VortX"),
                    good.replace(draft["assetName"], draft["assetName"] + ".extra"),
                    good.replace("88b70aa43090b5e5a27d", "b" * 20)):
            with self.subTest(url=bad), self.assertRaises(ValueError):
                V.validate_asset_url("verify-draft", draft, draft["tag_name"], draft["assetName"], bad)

    def test_beta3_generic_path_keeps_canonical_urls_after_publication(self):
        draft = {"id": CASE["releaseId"], "tag_name": TAG, "target_commitish": SOURCE,
                 "draft": True, "prerelease": True, "published_at": None, "body": V.MARKER,
                 "html_url": "https://github.com/VortXTV/VortX/releases/tag/untagged-" + "a" * 20}
        name = "VortX-tvOS-v0.5.6-beta.3-ci.ipa"
        canonical = "https://github.com/VortXTV/VortX/releases/download/" + TAG + "/" + name
        temporary = canonical.replace("/download/" + TAG + "/",
                                      "/download/untagged-" + "a" * 20 + "/")
        V.release_identity(draft, CASE["releaseId"], TAG, True, SOURCE)
        V.validate_asset_url("verify-draft", draft, TAG, name, temporary)
        published = {**draft, "draft": False, "published_at": "2026-10-20T00:00:00Z"}
        V.release_identity(published, CASE["releaseId"], TAG, False, SOURCE)
        V.validate_asset_url("verify-published", published, TAG, name, canonical)
        with self.assertRaises(ValueError):
            V.validate_asset_url("verify-published", published, TAG, name, temporary)


if __name__ == "__main__":
    unittest.main()
