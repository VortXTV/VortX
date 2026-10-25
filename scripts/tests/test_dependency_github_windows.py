"""Offline regression proposal; no network or production cursor writes."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dependency_health_window", ROOT/"scripts/dependency-health.py")
health = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(health)


class GitHubWindowTests(unittest.TestCase):
    name = "public/example"
    base = "https://api.github.com/repos/public/example"
    stamp = "2026-10-24T00:00:00Z"

    def row(self, identity, stamp=None, draft=False):
        return {"id":identity, "tag_name":f"v1.0.{identity}", "draft":draft,
                "prerelease":False, "immutable":None, "created_at":stamp or self.stamp,
                "published_at":stamp or self.stamp, "updated_at":stamp or self.stamp,
                "name":None, "body":None}

    def fixture(self, pages, visibility="public"):
        data = {self.base:{"private":visibility != "public", "visibility":visibility,
                                "full_name":self.name}}
        data.update({f"{self.base}/releases?per_page=10&page={page}":rows
                     for page,rows in pages.items()})
        return lambda url,github=False:json.dumps(data[url]).encode()

    def window(self, pages, previous=None):
        with patch.object(health, "get", side_effect=self.fixture(pages)):
            return health.github_release_window(self.name, previous, "pagination-bound")

    def inventory(self):
        return {"entries":[{"ecosystem":"github", "name":self.name,
                            "current":"v1.0.0", "kind":"github-action"}], "coverage_gaps":[]}

    def test_coverage_fallback_is_not_a_malformed_metadata_fallback(self):
        with patch.object(health, "github_complete_releases",
                          side_effect=health.GitHubCoverageError("pagination-bound")), \
                patch.object(health, "get", side_effect=self.fixture({1:[self.row(1)]})):
            result = health.github_releases(self.name)
        self.assertEqual(result["github_partial"]["cause"], "pagination-bound")
        self.assertEqual(set(result["observations"]), {"release:1"})
        with patch.object(health, "github_complete_releases", side_effect=ValueError("DO_NOT_LEAK")), \
                patch.object(health, "github_release_window") as window:
            with self.assertRaises(ValueError):
                health.github_releases(self.name)
            window.assert_not_called()

    def test_bounded_head_and_catchup_advance_without_replaying_full_scan(self):
        pages = {page:[self.row(page*100+n) for n in range(10)] for page in range(1,7)}
        first = self.window(pages)
        self.assertEqual(first["github_partial"]["observed_release_pages"], [1,2,3,4,5,6])
        self.assertEqual(first["github_partial"]["next_release_page"], 7)
        second_pages = {page:pages[page] for page in (1,2)}
        second_pages[7] = [self.row(700)]
        with patch.object(health, "github_complete_releases") as complete, \
                patch.object(health, "get", side_effect=self.fixture(second_pages)) as get:
            second = health.github_releases(self.name, first)
        complete.assert_not_called()
        self.assertEqual(second["github_partial"]["observed_release_pages"], [1,2,7])
        self.assertEqual(second["github_partial"]["next_release_page"], 3)
        self.assertFalse(second["github_partial"]["releases_complete"])
        self.assertEqual(get.call_count, 4)  # anonymous identity + three bounded pages
        self.assertEqual(second["github_partial"]["baseline_at"], first["github_partial"]["baseline_at"])

    def test_partial_merge_never_tombstones_unseen_tag_release_or_asset(self):
        current = self.window({1:[self.row(2)]})
        old = self.window({1:[self.row(1)]})
        old["versions"].append("v99.0.0")
        old["versions"].sort()
        old["observations"]["tag:v99.0.0"] = {
            "kind":"tag","version":"v99.0.0","commit":"a"*40,
            "ref_type":"commit","ref":"a"*40}
        old["observations"]["asset:1:3"] = {
            "kind":"asset","version":"v1.0.1","id":3,"release_id":1,
            "revision":"b"*64,"digest":None}
        merged, changes, _ = health.merge_github_observations(old, current)
        self.assertEqual(set(merged["observations"]), set(old["observations"]) | set(current["observations"]))
        self.assertEqual(merged["absent_observations"], [])
        self.assertEqual(merged["absent_versions"], [])
        self.assertFalse(any(event["change"] == "disappeared" for event in changes))
        self.assertEqual(set(merged["publication_timestamps"]), {"1","2"})

    def test_old_catchup_enrolls_but_new_publication_notifies_once_and_stays_unverified(self):
        old = self.window({1:[self.row(1)]})
        old["github_partial"]["baseline_at"] = "2026-10-23T00:00:00+00:00"
        fresh = self.window({1:[self.row(2, "2026-10-20T00:00:00Z"),
                                self.row(3, "2026-10-24T00:00:00Z")]}, old)
        with patch.object(health, "releases", return_value=fresh):
            report = health.compare(self.inventory(), {"releases":{"github:"+self.name:old}}, 1)
        self.assertEqual(report["new_releases"][0]["new_versions"], ["v1.0.3"])
        self.assertEqual(report["newly_tracked"][0]["kind"], "github-history-catchup")
        self.assertEqual(report["newly_tracked"][0]["versions"], ["v1.0.2"])
        self.assertEqual(report["entries"][0]["status"], "unverified")
        self.assertFalse(report["complete"])
        self.assertEqual(report["registry_errors"], [
            {"component":"github:"+self.name,"reason":"GitHubPartialCoverage"}])
        self.assertFalse(any(event["identity"] == "release:2" for event in report["github_observation_changes"]))
        with patch.object(health, "releases", return_value=fresh):
            repeated = health.compare(self.inventory(), report, 1)
        self.assertEqual(repeated["new_releases"], [])

    def test_drafts_are_not_enrolled_and_private_identity_stops_before_authenticated_pages(self):
        value = self.window({1:[self.row(1, draft=True)]})
        self.assertEqual(value["versions"], [])
        with patch.object(health, "get", side_effect=self.fixture({}, visibility="private")) as get:
            with self.assertRaises(ValueError):
                health.github_release_window(self.name, None, "pagination-bound")
        self.assertEqual(get.call_count, 1)
        self.assertEqual(get.call_args.kwargs, {})

    def test_malformed_window_preserves_exact_prior_cursor_and_emits_no_secret(self):
        old = self.window({1:[self.row(1)]})
        bad = self.row(2); bad["published_at"] = "DO_NOT_LEAK"
        with patch.object(health, "get", side_effect=self.fixture({1:[bad]})):
            report = health.compare(self.inventory(), {"releases":{"github:"+self.name:old}}, 1)
        self.assertEqual(report["releases"]["github:"+self.name], old)
        self.assertEqual(report["new_releases"], [])
        self.assertNotIn("DO_NOT_LEAK", json.dumps(report))

    def test_partial_cursor_rejects_boolean_or_unbounded_page_before_authenticated_history(self):
        old = self.window({1:[self.row(1)]})
        for value in (True,0,2,1001,"3"):
            old["github_partial"]["next_release_page"] = value
            with self.subTest(value=value), patch.object(health, "get", side_effect=self.fixture({})) as get:
                with self.assertRaises(ValueError):
                    health.github_release_window(self.name, old, "pagination-bound")
                self.assertEqual(get.call_count, 1)  # public-visibility prerequisite only

    def test_existing_absence_is_retained_but_fresh_reappearance_clears_it(self):
        old = self.window({1:[self.row(1)]})
        old["absent_observations"] = ["release:1"]
        old["absent_versions"] = ["v1.0.1"]
        absent, _, _ = health.merge_github_observations(old, self.window({1:[self.row(2)]}))
        self.assertEqual(absent["absent_observations"], ["release:1"])
        restored, events, _ = health.merge_github_observations(absent, self.window({1:[self.row(1)]}))
        self.assertEqual(restored["absent_observations"], [])
        self.assertTrue(any(event["change"] == "reappeared" for event in events))

    def test_partial_legacy_migration_does_not_invent_history_contraction(self):
        fresh = self.window({1:[self.row(2)]})
        legacy = {"versions":["v0.9.0"],"latest_stable":"v0.9.0","source":self.base+"/releases"}
        migrated, events, enrolled = health.merge_github_observations(legacy, fresh)
        self.assertTrue(enrolled)
        self.assertEqual(events, [])
        self.assertEqual(migrated["versions"], ["v0.9.0","v1.0.2"])
        self.assertEqual(migrated["absent_versions"], [])

    def test_multi_release_timestamps_do_not_break_individual_history_validation(self):
        old = self.window({1:[self.row(1),self.row(2)]})
        first, _, _ = health.merge_github_observations(old, old)
        second, events, _ = health.merge_github_observations(first, old)
        self.assertEqual(events, [])
        self.assertEqual(set(second["publication_timestamps"]), {"1","2"})

    def test_retained_capacity_is_separate_from_fresh_observation_budget(self):
        value = self.window({1:[self.row(1),self.row(2)]})
        with patch.object(health, "GITHUB_RETAINED_OBSERVATIONS", 1):
            with self.assertRaises(ValueError):
                health.validate_github_observations(value)
        with patch.object(health, "GITHUB_OBSERVATIONS", 1):
            health.validate_github_observations(value)  # retained record is still valid
            with patch.object(health, "releases", return_value=value):
                report = health.compare(self.inventory(), {"releases":{"github:"+self.name:value}}, 1)
        self.assertEqual(report["releases"]["github:"+self.name], value)
        self.assertEqual(report["registry_errors"][0]["reason"], "GitHubCoverageError")
        self.assertEqual(report["new_releases"], [])

    def test_retained_union_at_capacity_rejects_new_identity_and_preserves_exact_prior(self):
        old = self.window({1:[self.row(1)]})
        fresh = self.window({1:[self.row(2)]}, old)
        fresh["untrusted_failure_detail"] = "DO_NOT_LEAK_RETENTION"
        snapshot = json.loads(json.dumps(old))
        checkpoints = []
        with patch.object(health, "GITHUB_RETAINED_OBSERVATIONS", 1), \
                patch.object(health, "releases", return_value=fresh):
            report = health.compare(
                self.inventory(), {"releases":{"github:"+self.name:old}}, 1,
                checkpoint=lambda *values:checkpoints.append(values))
        self.assertEqual(old, snapshot)
        self.assertEqual(report["releases"]["github:"+self.name], snapshot)
        self.assertEqual(report["registry_errors"], [{"component":"github:"+self.name,"reason":"ValueError"}])
        self.assertEqual(report["new_releases"], [])
        self.assertEqual(report["github_observation_changes"], [])
        self.assertEqual(report["successful_observations"], {})
        self.assertEqual(checkpoints, [("github:"+self.name, None, "ValueError")])
        self.assertNotIn("DO_NOT_LEAK_RETENTION", json.dumps(report))

    def test_legacy_merge_validates_final_result_before_returning_it(self):
        fresh = self.window({1:[self.row(2)]})
        legacy = {"versions":["v0.9.0"], "latest_stable":"v0.9.0", "source":self.base+"/releases"}
        validate = health.validate_github_observations
        def reject_final_result(value):
            if value.get("legacy_published_versions"):
                raise ValueError("DO_NOT_LEAK_LEGACY_MERGE")
            return validate(value)
        with patch.object(health, "validate_github_observations", side_effect=reject_final_result), \
                patch.object(health, "releases", return_value=fresh):
            report = health.compare(self.inventory(), {"releases":{"github:"+self.name:legacy}}, 1)
        self.assertEqual(report["releases"]["github:"+self.name], legacy)
        self.assertEqual(report["registry_errors"], [{"component":"github:"+self.name,"reason":"ValueError"}])
        self.assertEqual(report["new_releases"], [])
        self.assertNotIn("DO_NOT_LEAK_LEGACY_MERGE", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
