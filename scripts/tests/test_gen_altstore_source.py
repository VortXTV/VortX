import base64
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "gen-altstore-source.py"
SPEC = importlib.util.spec_from_file_location("gen_altstore_source", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


NATIVE_PROJECT_TARGETS = ("VortXiOSNative", "VortXMac", "VortXTV", "VortXTopShelf", "VortXTVLite")


def project_target_fixture(name, build=221):
    return f'  {name}:\n    settings:\n      base:\n        CURRENT_PROJECT_VERSION: "{build}"\n'


def project_fixture(build=221, historical=False, targets=NATIVE_PROJECT_TARGETS):
    names = (*targets, *(("VortX",) if historical else ()))
    return ("name: VortX\ntargets:\n" + "".join(project_target_fixture(name, build) for name in names)
            + "  CinemaUISmokeRenderer:\n    type: application\nschemes:\n  VortXTV:\n    build:\n")


def release(tag, build, complete=True):
    assets = []
    if complete:
        assets = [
            {"name": f"VortX-iOS-{tag}-ci.ipa", "state": "uploaded", "size": 10, "digest": "sha256:" + "1" * 64},
            {"name": f"VortX-tvOS-{tag}-ci.ipa", "state": "uploaded", "size": 20, "digest": "sha256:" + "2" * 64},
        ]
    return {
        "tagName": tag,
        "name": tag,
        "publishedAt": "2026-08-20T00:00:00Z",
        "body": "Verified notes.",
        "assets": assets,
        "isPrerelease": True,
        "isDraft": False,
        "build": build,
    }


def source(build=220):
    entry = {
        "version": "0.3.14",
        "buildVersion": str(build),
        "date": "2026-08-20",
        "localizedDescription": "Known good.",
        "downloadURL": "https://github.com/VortXTV/VortX/releases/download/v0.3.14-beta.18/asset",
        "size": 1,
        "sha256": "f" * 64,
        "minOSVersion": "16.0",
    }
    tv_entry = {**entry, "minOSVersion": "18.0"}
    return {
        "name": "VortX",
        "identifier": "tv.vortx.altstore",
        "apps": [
            {"name": "VortX", "bundleIdentifier": "com.stremiox.app.native", "versions": [entry]},
            {"name": "VortX (Apple TV)", "bundleIdentifier": "com.stremiox.tv", "versions": [tv_entry]},
        ],
    }


class ProjectBuildTests(unittest.TestCase):
    def parse(self, content):
        encoded = base64.b64encode(content.encode()).decode()
        with patch.object(MODULE, "gh_json", return_value={"content": encoded}):
            return MODULE.tag_build("v0.5.6")

    def test_native_five_and_historical_six_named_targets(self):
        self.assertEqual(self.parse(project_fixture()), "221")
        self.assertEqual(self.parse(project_fixture(historical=True)), "221")
        self.assertEqual(self.parse(project_fixture().replace(
            "  CinemaUISmokeRenderer:\n    type: application\n", "")), "221")

    def test_missing_native_targets_in_both_layouts(self):
        for historical in (False, True):
            for missing in NATIVE_PROJECT_TARGETS:
                with self.subTest(historical=historical, missing=missing):
                    targets = tuple(name for name in NATIVE_PROJECT_TARGETS if name != missing)
                    with self.assertRaises(MODULE.MetadataError):
                        self.parse(project_fixture(historical=historical, targets=targets))

    def test_duplicate_misplaced_incomplete_and_counterfeit_metadata(self):
        native, historical = project_fixture(), project_fixture(historical=True)
        field = '        CURRENT_PROJECT_VERSION: "221"\n'
        incomplete = project_fixture(targets=tuple(name for name in NATIVE_PROJECT_TARGETS if name != "VortXTopShelf"))
        cases = (
            ("bare six-line counter", field * 6),
            ("native mismatch", native.replace('"221"', '"220"', 1)),
            ("historical mismatch", historical.replace(project_target_fixture("VortX"), project_target_fixture("VortX", 220))),
            ("legacy target missing its build", historical.replace(project_target_fixture("VortX"), "  VortX:\n    settings:\n      base:\n")),
            ("native target missing its build", native.replace(field, "", 1)),
            ("duplicate field", native.replace(field, field * 2, 1)),
            ("counterfeit six fields with a missing target", incomplete.replace(field, field * 3, 1)),
            ("duplicate named target", native.replace("schemes:\n", project_target_fixture("VortXTV") + "schemes:\n")),
            ("unexpected versioned target", native.replace("schemes:\n", project_target_fixture("OtherApp") + "schemes:\n")),
            ("versioned smoke renderer", native.replace("  CinemaUISmokeRenderer:\n    type: application\n", project_target_fixture("CinemaUISmokeRenderer"))),
            ("build outside targets", "settings:\n      base:\n" + field + native),
            ("build in schemes", native + field),
            ("misindented settings scope", native.replace("    settings:\n", "   settings:\n", 1)),
            ("duplicate settings scope", native.replace("  CinemaUISmokeRenderer:\n", "    settings:\n      base:\n  CinemaUISmokeRenderer:\n")),
            ("unquoted build", native.replace('"221"', "221", 1)),
            ("zero build", project_fixture(build=0)),
            ("inline targets override", native + "targets: {}\n"),
            ("quoted targets override", native + '"targets": {}\n'),
            ("spaced targets override", native + "targets : {}\n"),
            ("spaced quoted targets override", native + '"targets" : {}\n'),
            ("inline settings override", native.replace("  CinemaUISmokeRenderer:\n", "    settings: {}\n  CinemaUISmokeRenderer:\n")),
            ("spaced settings override", native.replace("  CinemaUISmokeRenderer:\n", "    settings : {}\n  CinemaUISmokeRenderer:\n")),
            ("inline base override", native.replace("  CinemaUISmokeRenderer:\n", "      base: {}\n  CinemaUISmokeRenderer:\n")),
            ("spaced base override", native.replace("  CinemaUISmokeRenderer:\n", "      base : {}\n  CinemaUISmokeRenderer:\n")),
            ("duplicate targets section", native + "targets:\n"),
        )
        for name, content in cases:
            with self.subTest(name=name):
                with self.assertRaises(MODULE.MetadataError):
                    self.parse(content)


class BackfillTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.out = Path(self.directory.name) / "source.json"
        self.original_out = MODULE.OUT
        MODULE.OUT = self.out
        self.out.write_text(json.dumps(source(), indent=2) + "\n", encoding="utf-8")

    def tearDown(self):
        MODULE.OUT = self.original_out
        self.directory.cleanup()

    def test_missing_metadata_fails_without_partial_overwrite(self):
        before = self.out.read_bytes()
        with patch.object(MODULE, "recent_releases", return_value=[release("v0.3.14-beta.19", 221, complete=False)]):
            with self.assertRaises(MODULE.MetadataError):
                MODULE.main()
        self.assertEqual(self.out.read_bytes(), before)

    def test_older_candidate_is_rejected_by_monotonic_guard(self):
        before = self.out.read_bytes()
        with patch.object(MODULE, "recent_releases", return_value=[release("v0.3.14-beta.18", 219)]):
            with self.assertRaises(MODULE.MetadataError):
                MODULE.main()
        self.assertEqual(self.out.read_bytes(), before)

    def test_success_replaces_atomically_after_complete_generation(self):
        candidates = [release("v0.3.14-beta.19", 221), release("v0.3.14-beta.18", 220)]
        with patch.object(MODULE, "recent_releases", return_value=candidates):
            MODULE.main()
        result = json.loads(self.out.read_text(encoding="utf-8"))
        self.assertEqual(result["apps"][0]["versions"][0]["buildVersion"], "221")
        self.assertEqual(result["apps"][1]["versions"][0]["buildVersion"], "221")
        self.assertEqual(len(result["apps"][0]["versions"]), 2)

    def test_recent_releases_numeric_sort_is_not_tag_lexical(self):
        listed = [
            {"tagName": "v0.3.14-beta.9"},
            {"tagName": "v0.3.14-beta.10"},
        ]
        details = {
            "v0.3.14-beta.9": release("v0.3.14-beta.9", 209),
            "v0.3.14-beta.10": release("v0.3.14-beta.10", 210),
        }

        def fake_gh(*args):
            if args[:2] == ("release", "list"):
                return listed
            if args[:2] == ("release", "view"):
                return details[args[4]]
            if args[0] == "api":
                tag = args[1].split("ref=", 1)[1]
                content = project_fixture(details[tag]["build"], historical=tag.endswith(".9")).encode()
                return {"content": base64.b64encode(content).decode()}
            raise AssertionError(args)

        with patch.object(MODULE, "gh_json", side_effect=fake_gh):
            result = MODULE.recent_releases()
        self.assertEqual([item["build"] for item in result], [210, 209])

    def test_equal_build_different_tag_is_rejected_before_any_backfill_write(self):
        candidates = [release("v0.3.14-beta.18", 220), release("v0.3.14-beta.19", 220)]
        with patch.object(MODULE, "recent_releases", return_value=candidates):
            with self.assertRaises(MODULE.MetadataError):
                MODULE.main()


if __name__ == "__main__":
    unittest.main()
