"""Hermetic hosted-only layout test proposal. UNRUN; never invokes a compiler."""
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


if __name__ == "__main__":
    unittest.main()
