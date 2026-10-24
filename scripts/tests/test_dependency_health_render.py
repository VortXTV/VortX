import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dependency_health_render", ROOT / "scripts/render-dependency-health.py")
render = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(render)

ADAPTER_SPEC = importlib.util.spec_from_file_location(
    "dependency_native_adapter_for_render_test", ROOT / "scripts/dependency_native_adapter.py")
native_adapter = importlib.util.module_from_spec(ADAPTER_SPEC)
ADAPTER_SPEC.loader.exec_module(native_adapter)
MAINTAINED_SPEC = importlib.util.spec_from_file_location(
    "dependency_health_maintained_for_render_test", ROOT / "scripts/tests/test_dependency_health.py")
maintained = importlib.util.module_from_spec(MAINTAINED_SPEC)
MAINTAINED_SPEC.loader.exec_module(maintained)


class DependencyHealthRenderTests(unittest.TestCase):
    @staticmethod
    def _native_groups(count=69):
        groups = {}
        for index in range(count):
            name = "dovi" if index == 0 else f"native-{index:02d}"
            groups[name] = {
                "mode": "github-tags+releases" if index < 34 else "official-archive/feed",
                "status": "observed" if index == 1 else "unverified",
                "reason": "retained ledger not refreshed" if index else "repository-metadata-only",
                "lanes": [f"native-{(index % 63) + 1:02d}"],
                "repository": f"public/{name}",
                "observation_key": f"github:public/{name}",
                "observation_source": "existing-github-tag-release-asset-observer",
                "supplemental_observations": [{"observation": "monitor-node"}] if index == 1 else [],
            }
        groups["dovi"]["repository_observation_scope"] = "repository-metadata-only"
        groups["dovi"]["underlying_library"] = {
            "status": "UNVERIFIED",
            "immutable_source": "dolby_vision/Cargo.toml",
            "version_field": "[package].version",
            "reason": "CLI tags do not identify the libdovi 3.x version",
        }
        return groups

    def test_all_source_records_and_counts_survive_grouping(self):
        entries = [{"ecosystem":"npm","name":"example","repository":"one","source":source,
                    "kind":"resolved-transitive","current":version,"status":status}
                   for source, version, status in (("package-lock.json","1.0.0","outdated"),
                                                   ("nested/package-lock.json","2.0.0","current"))]
        text = render.render({"entries":entries,"coverage_gaps":[{"source":"native","reason":"unknown"}],
                              "unresolved_entries":3,"complete":False})
        self.assertIn("1 distinct ecosystem/package identities; 2 declaration/lock/location records", text)
        self.assertIn("Complete: False; unresolved records: 3; coverage gaps: 1", text)
        self.assertIn("| package-lock.json | resolved-transitive | 1.0.0 | UNVERIFIED | outdated |", text)
        self.assertIn("| nested/package-lock.json | resolved-transitive | 2.0.0 | UNVERIFIED | current |", text)

    def test_untrusted_values_cannot_inject_html_or_markdown(self):
        value = '<img src="https://invalid/"> ![image](https://invalid/) | `code`\nnewline'
        escaped = render.cell(value)
        self.assertNotIn("<img", escaped)
        self.assertNotIn("![image]", escaped)
        self.assertIn("&lt;img", escaped)
        self.assertIn("\\|", escaped)
        self.assertNotIn("\n", escaped)
        text = render.render({"entries":[],"coverage_gaps":[],"checked_at":value})
        self.assertNotIn("<img", text)
        self.assertNotIn("![image]", text)

    def test_every_metadata_change_enrollment_and_contraction_is_escaped_and_retained(self):
        malicious = '<script> ![asset](https://invalid/) | tag'
        data = {"entries":[], "coverage_gaps":[], "complete":False,
                "github_observation_changes":[
                    {"component":"github:public/example","identity":identity,"version":malicious,
                     "change":kind,"before":"a"*64,"after":"b"*64}
                    for identity,kind in (("tag:"+malicious,"changed"),("asset:1:2","disappeared"),("asset:1:2","reappeared"))],
                "newly_tracked":[{"component":"github:public/example","kind":"github-history-baseline",
                                 "source":"https://api.github.com/repos/public/example/releases"}],
                "history_contractions":[{"component":"github:public/example","missing_observations":[malicious],
                                         "missing_versions":["v1.0.0","v2.0.0-rc.1"]}]}
        text = render.render(data)
        for word in ("changed", "disappeared", "reappeared", "github-history-baseline", "v2.0.0-rc.1"):
            self.assertIn(word, text)
        self.assertIn("Historical values remain retained", text)
        self.assertNotIn("<script>", text)
        self.assertNotIn("![asset]", text)

    def test_native_groups_are_complete_and_refresh_state_is_explicit(self):
        data = {
            "entries": [],
            "coverage_gaps": [],
            "complete": False,
            "native_monitor_refresh": {
                "status": "not-refreshed",
                "fresh": False,
                "reason": "native-manifest-not-supplied",
                "unresolved_groups": ["native-68"],
                "coverage_gap_count": 35,
            },
            "native_monitor": {
                "groups": self._native_groups(),
                "coverage_gaps": [{
                    "source": "native/dovi/libdovi",
                    "reason": "underlying-library-version-unverified",
                }],
                "source_changes": [{
                    "group": "native-01",
                    "scope": "source-evidence",
                    "before": "a" * 64,
                    "after": "b" * 64,
                }],
            },
            "identity_conflicts": [{
                "component": "github:public/native-01",
                "scope": "prior",
                "keys": ["github:PUBLIC/NATIVE-01", "github:public/native-01"],
                "reason": "conflicting-github-identity-history",
                "detail": "private-token cursor=do-not-print",
            }],
        }
        text = render.render(data)
        self.assertIn("69 native upstream groups recorded", text)
        self.assertIn("native sources were NOT REFRESHED in this run", text)
        self.assertIn("native-01", text)
        self.assertIn("native-68", text)
        self.assertIn("Inventory lanes", text)
        self.assertIn("Observation mapping", text)
        self.assertIn("Supplemental mappings", text)
        self.assertIn("Underlying libdovi 3.x: UNVERIFIED", text)
        self.assertIn(r"dolby\_vision/Cargo.toml", text)
        self.assertIn("native/dovi/libdovi", text)
        self.assertIn("not a release notification", text)
        self.assertIn("Query blocked", text)
        self.assertNotIn("private-token", text)
        self.assertNotIn("do-not-print", text)
        self.assertNotIn("cursor=", text)

    def test_actual_native_adapter_shape_renders_all_mapping_labels(self):
        capture = json.loads((ROOT / "scripts/tests/fixtures/native-manifest-capture.json").read_text())
        manifest = maintained.NativeDependencyAdapterTests.manifest_from_capture(capture)
        public_display_labels = [
            "OpenSSL libssl/libcrypto",
            "Nettle / Hogweed",
            "libsmbclient / Samba",
            "Little CMS",
            "SPIRV-Headers / Vulkan-Headers",
            "Android libmpv wrapper",
            "Android platform SDK",
            "Xcode / Swift compiler",
            "AVKit / AVFoundation / VideoToolbox / Metal / CoreAudio",
            "libz / bz2 / iconv / expat / resolv / xml2 / libc++",
            "QuickJS Bellard",
            "linuxdeploy / AppImage plugin",
            "pkgconf/pkg-config",
            "VortX native SDK",
            "AWS-LC C library / Rust adapter",
            "QuickJS-NG / rquickjs",
            "ring C/assembly",
            "cc / cmake Rust build helpers",
            "Rust compiler",
        ]
        for lane_name, label in zip(manifest["lanes"], public_display_labels):
            manifest["lanes"][lane_name]["component"] = label
        unsafe_labels = {
            "native-20": "/Users/private-component",
            "native-21": "~/private-component",
            "native-22": r"C:\private-component",
            "native-23": "https://private.example/component",
            "native-24": "display\nnewline",
        }
        for lane_name, label in unsafe_labels.items():
            manifest["lanes"][lane_name]["component"] = label
        native = native_adapter.build_native_coverage(manifest)
        text = render.render({"entries": [], "coverage_gaps": native["coverage_gaps"],
                              "native_monitor": native})
        self.assertIn("69 native upstream groups recorded", text)
        for lane in range(1, 64):
            self.assertIn(f"native-{lane:02d}", text)
        for observation in ("monitor-python", "monitor-pyyaml", "monitor-node", "service-postgres"):
            self.assertIn(observation, text)
        for label in public_display_labels:
            self.assertIn(label, text)
        for label in unsafe_labels.values():
            self.assertNotIn(label, text)
        self.assertIn("component OpenSSL libssl/libcrypto", text)
        self.assertIn("pin A17", text)
        self.assertNotIn("source_evidence", text)
        self.assertNotIn("last_success", text)
        self.assertNotIn("journal_refs", text)

    def test_native_values_escape_and_private_cursor_fields_are_not_rendered(self):
        data = {
            "entries": [],
            "coverage_gaps": [],
            "native_monitor": {
                "groups": {
                    "unsafe": {
                        "mode": "<script>",
                        "status": "![status]",
                        "reason": "reason | `code`",
                        "lanes": ["lane | <x>"],
                        "repository": "public/unsafe",
                        "observation_key": "github:public/unsafe",
                        "observation_source": "public observer",
                        "last_success": {"cursor": "secret-token"},
                    },
                },
            },
        }
        text = render.render(data)
        self.assertNotIn("<script>", text)
        self.assertNotIn("![status]", text)
        self.assertIn("&lt;script&gt;", text)
        self.assertIn("\\|", text)
        self.assertNotIn("secret-token", text)
        self.assertNotIn("last_success", text)
        self.assertNotIn('"cursor"', text)


if __name__ == "__main__": unittest.main()
