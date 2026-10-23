"""Synthetic regression coverage for the direct-dependency advisory policy."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("rust_audit_policy", ROOT / "scripts/check-rust-audit-policy.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class RustAuditPolicyTests(unittest.TestCase):
    def policy(self):
        return {"advisories": {"version": 2, "unmaintained": "workspace", "yanked": "deny",
                               "ignore": ["RUSTSEC-2024-0429"]}}

    def report(self, name="transitive", *, vulnerability=False):
        warnings = [{"kind": "unmaintained", "package": {"name": name, "version": "1.0.0"},
                     "advisory": {"id": "RUSTSEC-2025-0001", "package": name, "informational": "unmaintained"}}]
        return {"database": {"advisory-count": 1}, "lockfile": {"dependency-count": 2},
                "settings": {"ignore": ["RUSTSEC-2024-0429"], "target_arch": [], "target_os": [], "severity": None,
                             "informational_warnings": ["unmaintained", "unsound", "notice"]},
                "vulnerabilities": {"found": vulnerability, "count": int(vulnerability),
                                     "list": [{"advisory": {"id": "RUSTSEC-2026-0194"}}] if vulnerability else []},
                "warnings": {"unmaintained": warnings}}

    def test_direct_normal_dev_build_and_target_dependencies_are_blocked(self):
        for kind in guard.TABLES:
            for target in (False, True):
                owner = {kind: {"direct": "1"}}
                manifest = {"target": {"cfg(unix)": owner}} if target else owner
                with self.subTest(kind=kind, target=target):
                    self.assertEqual(guard.direct_unmaintained(self.report("direct"), manifest, self.policy()),
                                     [{"name": "direct", "version": "1.0.0", "advisory": "RUSTSEC-2025-0001"}])

    def test_package_alias_is_matched_to_registry_package_in_all_tables(self):
        for kind in guard.TABLES:
            for target in (False, True):
                owner = {kind: {"local_alias": {"version": "1", "package": "actual-package"}}}
                manifest = {"target": {"cfg(unix)": owner}} if target else owner
                with self.subTest(kind=kind, target=target):
                    self.assertEqual(len(guard.direct_unmaintained(self.report("actual-package"), manifest, self.policy())), 1)
                    self.assertEqual(guard.direct_unmaintained(self.report("local_alias"), manifest, self.policy()), [])

    def test_transitive_warnings_remain_in_original_report_without_becoming_a_waiver(self):
        report = self.report()
        before = copy.deepcopy(report)
        self.assertEqual(guard.direct_unmaintained(report, {"dependencies": {"direct": "1"}}, self.policy()), [])
        self.assertEqual(report, before)
        self.assertEqual(report["settings"]["ignore"], ["RUSTSEC-2024-0429"])

    def test_empty_warning_map_is_valid_and_actual_vulnerabilities_are_untouched(self):
        report = self.report(vulnerability=True)
        report["warnings"] = {}
        before = copy.deepcopy(report)
        self.assertEqual(guard.direct_unmaintained(report, {}, self.policy()), [])
        self.assertEqual(report, before)  # Workflow must retain cargo-audit's original nonzero exit.
        self.assertTrue(report["vulnerabilities"]["found"])

    def test_missing_or_malformed_report_sections_cannot_pass(self):
        for key in ("database", "lockfile", "settings", "vulnerabilities", "warnings"):
            for value in (None, []):
                report = self.report()
                report[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(guard.PolicyError):
                    guard.direct_unmaintained(report, {}, self.policy())
        for section, key, value in (("database", "advisory-count", 0), ("lockfile", "dependency-count", 0),
                                    ("vulnerabilities", "count", 1), ("warnings", "unmaintained", {})):
            report = self.report()
            report[section][key] = value
            with self.subTest(section=section, key=key), self.assertRaises(guard.PolicyError):
                guard.direct_unmaintained(report, {}, self.policy())

    def test_unknown_policy_additional_ignores_and_report_filters_fail_closed(self):
        for key, value in (("version", 3), ("unmaintained", "all"), ("yanked", "warn"),
                           ("ignore", ["RUSTSEC-2024-0429", "RUSTSEC-2026-0194"])):
            policy = self.policy()
            policy["advisories"][key] = value
            with self.subTest(key=key), self.assertRaises(guard.PolicyError):
                guard.direct_unmaintained(self.report(), {}, policy)
        for key, value in (("ignore", ["RUSTSEC-2024-0429", "RUSTSEC-2026-0194"]),
                           ("target_os", ["macos"]), ("target_arch", ["aarch64"]), ("severity", "high"),
                           ("informational_warnings", ["unsound", "notice"])):
            report = self.report()
            report["settings"][key] = value
            with self.subTest(key=key), self.assertRaises(guard.PolicyError):
                guard.direct_unmaintained(report, {}, self.policy())

    def test_malformed_warning_identity_and_unknown_manifest_inheritance_fail_closed(self):
        report = self.report()
        report["warnings"]["unmaintained"][0]["advisory"]["package"] = "other-package"
        with self.assertRaises(guard.PolicyError):
            guard.direct_unmaintained(report, {}, self.policy())
        for manifest in ({"dependencies": {"alias": {"workspace": True}}}, {"target": []},
                         {"dev-dependencies": {"alias": True}}, {"dependencies": {"alias": {"package": None}}}):
            with self.subTest(manifest=manifest), self.assertRaises(guard.PolicyError):
                guard.direct_unmaintained(self.report(), manifest, self.policy())


if __name__ == "__main__":
    unittest.main()
