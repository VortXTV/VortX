"""Hermetic hosted-only layout/transport guard tests. UNRUN here; no compiler or network."""
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest import mock


class KotlinLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        required = {"VORTX_HOSTED_LAYOUT_UNIT_TESTS": "1", "GITHUB_ACTIONS": "true",
                    "GITHUB_REPOSITORY": "VortXTV/VortX", "GITHUB_EVENT_NAME": "push",
                    "GITHUB_REF": "refs/heads/beta-xperience-wire-parity-20261030"}
        if not all(os.environ.get(key) == value for key, value in required.items()):
            raise RuntimeError("layout test proposal requires separately authorized exact hosted context")
        cls.guards = ExitStack()
        cls.addClassCleanup(cls.guards.close)
        for name in ("Popen", "run", "call", "check_call", "check_output"):
            cls.guards.enter_context(mock.patch.object(subprocess, name, side_effect=AssertionError("subprocess prohibited by layout tests")))
        for name in ("socket", "create_connection"):
            cls.guards.enter_context(mock.patch.object(socket, name, side_effect=AssertionError("network prohibited by layout tests")))
        specification = importlib.util.spec_from_file_location("layout_driver_under_test", Path(__file__).with_name("run-hosted.py"))
        cls.driver = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(cls.driver)
        cls.guards.enter_context(mock.patch.object(cls.driver, "run_child", side_effect=AssertionError("compiler/runtime child prohibited by layout tests")))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="layout-source-unit-", dir=os.environ["RUNNER_TEMP"])
        self.addCleanup(self.temporary.cleanup)
        self.prefix = Path(self.temporary.name) / "kotlin"
        self.wrapper = self.prefix / "bin/kotlinc"
        self.wrapper.parent.mkdir(parents=True)
        self.wrapper.write_bytes(b"WRAPPER_CONTENT_MUST_NOT_BE_LOGGED")
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(self.driver.shutil, "which", return_value=str(self.wrapper)).start()
        self.emitted = mock.patch.object(self.driver, "emit").start()

    def layout(self, home, omit=None):
        (home / "lib").mkdir(parents=True)
        (home / "bin").mkdir(parents=True, exist_ok=True)
        (home / "bin/kotlinc").write_bytes(b"SYNTHETIC_COMPILER_LAUNCHER_NOT_EXECUTED")
        for name in ("kotlin-compiler.jar", "kotlin-stdlib.jar", "kotlin-reflect.jar"):
            if name != omit:
                (home / "lib" / name).write_bytes(name.encode("ascii"))

    def discovery(self):
        records = [call.args[1] for call in self.emitted.call_args_list if call.args[0] == "kotlin-layout-discovery"]
        self.assertEqual(len(records), 1)
        self.assertEqual(len(records[0]["candidates"]), 2)
        return records[0]

    def test_original_prefix_layout(self):
        self.layout(self.prefix)
        actual = self.driver.installed_kotlin({})
        self.assertEqual(actual["home"], str(self.prefix))
        self.assertFalse(actual["launcherDiffersFromCompilerLauncher"])
        self.assertEqual(actual["classpath"], os.pathsep.join(actual["classpathEntries"]))
        self.assertEqual(actual["classpath"], self.driver.exact_kotlin_classpath(actual))
        self.assertEqual(sum(candidate["qualifies"] for candidate in self.discovery()["candidates"]), 1)

    def test_homebrew_libexec_layout(self):
        home = self.prefix / "libexec"
        self.layout(home)
        actual = self.driver.installed_kotlin({})
        self.assertEqual(actual["home"], str(home))
        self.assertTrue(actual["launcherDiffersFromCompilerLauncher"])
        self.assertNotIn("WRAPPER_CONTENT_MUST_NOT_BE_LOGGED", json.dumps(self.discovery()))
        self.assertEqual(actual["compilerLauncher"]["resolved"], str(home / "bin/kotlinc"))

    def test_two_complete_candidates_reject(self):
        self.layout(self.prefix)
        self.layout(self.prefix / "libexec")
        with self.assertRaisesRegex(RuntimeError, "exactly one complete bounded candidate"):
            self.driver.installed_kotlin({})
        self.assertEqual(sum(candidate["qualifies"] for candidate in self.discovery()["candidates"]), 2)

    def test_missing_required_jar_rejects_with_metadata(self):
        self.layout(self.prefix, omit="kotlin-reflect.jar")
        with self.assertRaises(RuntimeError):
            self.driver.installed_kotlin({})
        report = self.discovery()["candidates"][0]
        self.assertEqual(report["jarCount"], 2)
        self.assertTrue(report["jarCountComplete"])
        self.assertIn("required-jars-missing", report["reasons"])

    def test_no_candidate_has_actionable_zero_counts(self):
        with self.assertRaises(RuntimeError):
            self.driver.installed_kotlin({})
        for candidate in self.discovery()["candidates"]:
            self.assertEqual(candidate["jarCount"], 0)
            self.assertEqual(candidate["jarBytes"], 0)
            self.assertFalse(candidate["qualifies"])

    def test_jar_count_limit_is_not_raised(self):
        self.layout(self.prefix)
        for number in range(94):
            (self.prefix / "lib" / (str(number) + ".jar")).write_bytes(b"x")
        with self.assertRaises(RuntimeError):
            self.driver.installed_kotlin({})
        report = self.discovery()["candidates"][0]
        self.assertEqual(report["jarCount"], 97)
        self.assertFalse(report["jarCountComplete"])
        self.assertIn("jar-count-budget", report["reasons"])

    def check_mocked_size_rejection(self, size, extras, reason):
        self.layout(self.prefix)
        for number in range(extras):
            (self.prefix / "lib" / ("extra" + str(number) + ".jar")).write_bytes(b"x")
        original_stat = Path.stat

        def mocked_stat(path, *args, **kwargs):
            result = original_stat(path, *args, **kwargs)
            if path.parent == self.prefix / "lib" and path.suffix == ".jar":
                fields = list(result)
                fields[6] = size
                return os.stat_result(fields)
            return result

        with mock.patch.object(Path, "stat", new=mocked_stat):
            with self.assertRaises(RuntimeError):
                self.driver.installed_kotlin({})
        self.assertIn(reason, self.discovery()["candidates"][0]["reasons"])

    def test_per_file_limit_is_not_raised(self):
        self.check_mocked_size_rejection(128 * 1024 * 1024 + 1, 0, "jar-file-budget-or-type")

    def test_aggregate_limit_is_not_raised(self):
        self.check_mocked_size_rejection(128 * 1024 * 1024, 2, "jar-aggregate-budget")

    def transport_contract(self):
        data = Path(__file__).with_name("transport-cases.json").read_bytes()
        cases, relations = self.driver.transport_cases(data)
        return data, cases, relations

    def guard_outputs(self, cases):
        # Fabricated guard-test records only; never producer observations or a parity receipt.
        outputs = {runtime: {"records": {}, "canonical": {}, "failures": []} for runtime in self.driver.TRANSPORT_RUNTIMES}
        for runtime in outputs:
            for case in cases:
                if case["mode"] == "LITERAL_CONTRACT_UNOBSERVED":
                    self.guard_accept(outputs, case, runtime, case["expectedCanonicalUTF8"].encode("utf-8"))
                else:
                    outputs[runtime]["records"][case["id"]] = {"id": case["id"], "category": "INVALID_REGISTRY",
                        "bytes": 0, "sha256": "-", "fingerprint": "-", "inputSHA256": case["inputUTF8SHA256"]}
        return outputs

    def guard_accept(self, outputs, case, runtime, value):
        sha = self.driver.digest(value)
        outputs[runtime]["records"][case["id"]] = {"id": case["id"], "category": "ACCEPTED", "bytes": len(value),
            "sha256": sha, "fingerprint": sha, "inputSHA256": case["inputUTF8SHA256"], "actualBytes": len(value), "independentSHA256": sha}
        outputs[runtime]["canonical"][case["id"]] = value

    def guard_directory(self, cases, output, name):
        directory = Path(self.temporary.name) / name
        directory.mkdir()
        rows = []
        for case in cases:
            record = output["records"][case["id"]]
            rows.append("\t".join(str(record[key]) for key in ("id", "category", "bytes", "sha256", "fingerprint", "inputSHA256")))
            if case["id"] in output["canonical"]:
                (directory / (case["id"] + ".canonical")).write_bytes(output["canonical"][case["id"]])
        (directory / "results.tsv").write_text("\n".join(rows) + "\n", encoding="ascii")
        return directory

    def test_transport_corpus_semantic_and_hash_guards(self):
        data, _, _ = self.transport_contract()
        with self.assertRaises(RuntimeError):
            self.driver.transport_cases(data + b" ")
        mutations = (
            lambda body: body["cases"][1].update(id=body["cases"][0]["id"]),
            lambda body: body["cases"][0].update(mode="UNKNOWN_MODE"),
            lambda body: body["cases"][0].update(inputUTF8SHA256="0" * 64),
            lambda body: body["cases"][0].update(referenceSHA256="0" * 64),
            lambda body: body["cases"][0].update(observedApple={}),
            lambda body: body["fixtureDescriptor"]["catalog"].update(supportsSkip=False),
        )
        for mutate in mutations:
            body = json.loads(data)
            mutate(body)
            changed = json.dumps(body).encode("utf-8")
            # Unit-only pin substitution reaches inner guards; production has no override argument.
            with mock.patch.object(self.driver, "TRANSPORT_CORPUS_SHA256", self.driver.digest(changed)):
                with self.assertRaises(RuntimeError):
                    self.driver.transport_cases(changed)
        with mock.patch.object(self.driver, "TRANSPORT_CORPUS_SHA256", self.driver.digest(b"{")):
            with self.assertRaises(RuntimeError):
                self.driver.transport_cases(b"{")

    def test_transport_input_byte_limits(self):
        data, _, _ = self.transport_contract()
        large = json.loads(data)
        large["cases"][0]["note"] = "x" * (128 * 1024)
        oversized = json.dumps(large).encode("utf-8")
        with mock.patch.object(self.driver, "TRANSPORT_CORPUS_SHA256", self.driver.digest(oversized)):
            with self.assertRaises(RuntimeError):
                self.driver.transport_cases(oversized)
        body = json.loads(data)
        body["cases"][0]["input"] = "x" * 4097
        body["cases"][0]["inputUTF8SHA256"] = self.driver.digest(b"x" * 4097)
        changed = json.dumps(body).encode("utf-8")
        with mock.patch.object(self.driver, "TRANSPORT_CORPUS_SHA256", self.driver.digest(changed)):
            with self.assertRaises(RuntimeError):
                self.driver.transport_cases(changed)

    def test_transport_result_identity_guards_fail_summary(self):
        _, cases, relations = self.transport_contract()
        for variant in ("duplicate", "unknown", "input-hash", "producer-hash", "all-producer-hash"):
            outputs = self.guard_outputs(cases)
            runtimes = self.driver.TRANSPORT_RUNTIMES if variant == "all-producer-hash" else ("apple",)
            for runtime in runtimes:
                directory = self.guard_directory(cases, outputs[runtime], variant + runtime)
                rows = (directory / "results.tsv").read_text(encoding="ascii").splitlines()
                if variant == "duplicate":
                    rows.append(rows[0])
                else:
                    fields = rows[0].split("\t")
                    fields[{"unknown": 0, "input-hash": 5, "producer-hash": 4, "all-producer-hash": 4}[variant]] = "unknown-case" if variant == "unknown" else "0" * 64
                    rows[0] = "\t".join(fields)
                (directory / "results.tsv").write_text("\n".join(rows) + "\n", encoding="ascii")
                outputs[runtime] = self.driver.read_transport_results(directory, cases, runtime)
            self.assertFalse(self.driver.transport_comparison(cases, relations, outputs)["summary"]["passed"])

    def test_transport_observe_never_waives_equality(self):
        _, cases, relations = self.transport_contract()
        probe = next(case for case in cases if case["comparisonExpected"] == "OBSERVE")
        for variant in ("bytes", "category"):
            outputs = self.guard_outputs(cases)
            for runtime in outputs:
                self.guard_accept(outputs, probe, runtime, b"synthetic-guard-value")
            self.assertTrue(self.driver.transport_comparison(cases, relations, outputs)["summary"]["passed"])
            if variant == "bytes":
                self.guard_accept(outputs, probe, "jdk21", b"different-guard-value")
            else:
                outputs["jdk21"]["records"][probe["id"]] = {"id": probe["id"], "category": "INVALID_REGISTRY",
                    "bytes": 0, "sha256": "-", "fingerprint": "-", "inputSHA256": probe["inputUTF8SHA256"]}
                outputs["jdk21"]["canonical"].pop(probe["id"])
            self.assertFalse(self.driver.transport_comparison(cases, relations, outputs)["summary"]["passed"])

    def test_transport_equal_unexpected_literals_and_rejections_fail(self):
        _, cases, relations = self.transport_contract()
        related_ids = {name for relation in relations for name in relation["caseIDs"]}
        for mode in ("LITERAL_CONTRACT_UNOBSERVED", "GUARD_REJECTION_UNOBSERVED"):
            outputs = self.guard_outputs(cases)
            self.assertTrue(self.driver.transport_comparison(cases, relations, outputs)["summary"]["passed"])
            case = next(item for item in cases if item["mode"] == mode and item["id"] not in related_ids)
            for runtime in outputs:
                self.guard_accept(outputs, case, runtime, b"synthetic-unexpected-value")
            self.assertFalse(self.driver.transport_comparison(cases, relations, outputs)["summary"]["passed"])

    def test_transport_both_relation_kinds_are_checked(self):
        _, cases, relations = self.transport_contract()
        indexed = {case["id"]: case for case in cases}
        for name, value, reason in (("scheme-host-case", b"changed-guard-value", "relation-same-bytes"),
                ("explicit-default-https", indexed["ascii-https"]["expectedCanonicalUTF8"].encode("utf-8"), "relation-distinct-bytes")):
            outputs = self.guard_outputs(cases)
            for runtime in outputs:
                self.guard_accept(outputs, indexed[name], runtime, value)
            report = self.driver.transport_comparison(cases, relations, outputs)
            self.assertFalse(report["summary"]["passed"])
            self.assertTrue(any(reason in item["reasons"] for item in report["failures"]))

    def test_transport_output_limits_and_rejected_canonical(self):
        _, cases, relations = self.transport_contract()
        rejected = next(case for case in cases if case["mode"] == "GUARD_REJECTION_UNOBSERVED")
        exact_outputs = self.guard_outputs(cases)
        exact_directory = self.guard_directory(cases, exact_outputs["apple"], "exact-membership")
        exact_outputs["apple"] = self.driver.read_transport_results(exact_directory, cases, "apple")
        self.assertEqual(exact_outputs["apple"]["failures"], [])
        self.assertTrue(self.driver.transport_comparison(cases, relations, exact_outputs)["summary"]["passed"])
        for variant in ("canonical-limit", "metadata-limit", "rejected-canonical", "extra-file",
                        "extra-directory", "extra-symlink", "symlink-directory", "entry-limit"):
            outputs = self.guard_outputs(cases)
            directory = self.guard_directory(cases, outputs["apple"], variant)
            if variant == "metadata-limit":
                (directory / "results.tsv").write_bytes(b"x" * (32 * 1024 + 1))
            elif variant == "canonical-limit":
                (directory / (cases[0]["id"] + ".canonical")).write_bytes(b"x" * (16 * 1024 + 1))
            elif variant == "rejected-canonical":
                (directory / (rejected["id"] + ".canonical")).write_bytes(b"x")
            elif variant == "extra-file":
                (directory / "unreferenced.canonical").write_bytes(b"x")
            elif variant == "extra-directory":
                (directory / "unexpected-directory").mkdir()
            elif variant == "extra-symlink":
                (directory / "unexpected-link").symlink_to(directory / "missing-target")
            elif variant == "symlink-directory":
                alias = directory.with_name("symlink-directory-alias")
                alias.symlink_to(directory, target_is_directory=True)
                directory = alias
            else:
                for index in range(54):
                    (directory / ("unexpected-" + str(index))).write_bytes(b"x")
            outputs["apple"] = self.driver.read_transport_results(directory, cases, "apple")
            expected_reason = {"canonical-limit": "canonical-missing-unsafe-or-limit",
                "metadata-limit": "metadata-missing-unsafe-nonascii-or-limit",
                "rejected-canonical": "rejection-has-canonical-or-fingerprint",
                "extra-file": "output-membership-mismatch", "extra-directory": "output-entry-not-regular",
                "extra-symlink": "output-entry-not-regular", "symlink-directory": "output-directory-missing-or-unsafe",
                "entry-limit": "output-entry-limit"}[variant]
            self.assertTrue(any(expected_reason in item["reasons"] for item in outputs["apple"]["failures"]))
            self.assertFalse(self.driver.transport_comparison(cases, relations, outputs)["summary"]["passed"])

    def test_transport_mismatch_witness_is_bounded_and_absent_on_pass(self):
        _, cases, relations = self.transport_contract()
        outputs = self.guard_outputs(cases)
        report = self.driver.transport_comparison(cases, relations, outputs)
        self.assertEqual(self.driver.transport_mismatch_witnesses(cases, outputs, report, self.driver.TRANSPORT_CORPUS_SHA256), [])
        probe = next(case for case in cases if case["comparisonExpected"] == "OBSERVE")
        for runtime in outputs:
            self.guard_accept(outputs, probe, runtime, b"a" * 600)
        self.guard_accept(outputs, probe, "jdk21", b"b" * 600)
        report = self.driver.transport_comparison(cases, relations, outputs)
        witnesses = self.driver.transport_mismatch_witnesses(cases, outputs, report, self.driver.TRANSPORT_CORPUS_SHA256)
        self.assertEqual(len(witnesses), 3)
        for item in witnesses:
            actual = outputs[item["runtime"]]["canonical"][probe["id"]]
            self.assertEqual(item["fullBytes"], len(actual))
            self.assertEqual(item["fullSHA256"], self.driver.digest(actual))
            self.assertEqual(item["prefixBytes"], 512)
            self.assertTrue(item["truncated"])
            self.assertEqual(self.driver.base64.b64decode(item["prefixBase64"]), actual[:512])


if __name__ == "__main__":
    unittest.main()
