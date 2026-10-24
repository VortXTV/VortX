import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dependency_health", ROOT / "scripts/dependency-health.py")
health = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(health)


class DependencyHealthTests(unittest.TestCase):
    def fixture_inventory(self, files):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="dependency-fixture-") as folder:
            root = Path(folder)
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            paths = b"\0".join(name.encode() for name in files) + b"\0"
            with patch.object(health.subprocess, "check_output", side_effect=["a"*40, paths]), \
                 patch.object(health.Path, "home", return_value=root):
                return health.inventory({"repositories":[{"path":folder,"label":"fixture"}]})

    def test_only_explicit_registry_specs_are_admitted(self):
        for value in ("^1.2.3", "~2", ">=1.0.0 <2", "1.0.0 - 2.0.0", "1 || 2", "*", "1.x", "next", "1.0.0-rc.1"):
            with self.subTest(value=value): self.assertTrue(health.npm_registry_spec(value))
        for value in ("owner/private-repo#branch", "gitlab:private/repo", "bitbucket:private/repo", "git@host:repo", "ssh://private/repo", "../private", "https://host/file", "npm:private@latest"):
            with self.subTest(value=value): self.assertFalse(health.npm_registry_spec(value))
        result = self.fixture_inventory({"package.json":json.dumps({"dependencies":{
            "secret":"owner/private-repo#branch", "alias":"npm:public@^1.0.0"}})})
        self.assertEqual([e["name"] for e in result["entries"]], ["public"])
        self.assertNotIn("private-repo", json.dumps(result))
        self.assertNotIn("secret", json.dumps(result))

    def test_registry_inline_comments_and_unknown_directives_fail_closed(self):
        for directive in ("registry=https://private.invalid/ # comment", "registry https://private.invalid/", "registry=${PRIVATE_REGISTRY}", 'registry="https://private.invalid/', "userconfig=/private/config"):
            with self.subTest(directive=directive):
                result = self.fixture_inventory({"package.json":'{"dependencies":{"example":"1.0.0"}}', ".npmrc":directive})
                self.assertEqual(result["entries"], [])
                self.assertTrue(result["coverage_gaps"])
                self.assertNotIn("private.invalid", json.dumps(result))
        result = self.fixture_inventory({"package.json":'{"dependencies":{"example":"1.0.0"}}',
                                         ".npmrc":'registry="https://registry.npmjs.org/" ; comment'})
        self.assertEqual([e["name"] for e in result["entries"]], ["example"])

    def test_registry_override_environment_does_not_fall_back_to_public(self):
        with patch.dict(health.os.environ, {"NPM_CONFIG_USERCONFIG":"/private/unknown"}):
            result = self.fixture_inventory({"package.json":'{"dependencies":{"example":"1.0.0"}}'})
        self.assertEqual(result["entries"], [])

    def test_nested_private_packages_are_discovered_before_all_references(self):
        result = self.fixture_inventory({
            "package.json":'{"dependencies":{"nested-private":"1.0.0","example":"1.0.0"}}',
            "zzz/nested/package.json":'{"name":"nested-private","private":true}',
            "package-lock.json":'{"packages":{"node_modules/nested-private":{"version":"1.0.0","resolved":"https://registry.npmjs.org/nested-private/-/nested-private-1.0.0.tgz"}}}'})
        self.assertEqual({e["name"] for e in result["entries"]}, {"example"})

    def test_cargo_manifest_requires_corroborated_public_origin(self):
        lock = 'version=3\n[[package]]\nname="example"\nversion="1.0.0"\nsource="registry+https://github.com/rust-lang/crates.io-index"\n'
        manifest = '[dependencies]\nexample="1"\nprivate_name="1"\n'
        result = self.fixture_inventory({"Cargo.lock":lock,"Cargo.toml":manifest})
        self.assertEqual({e["name"] for e in result["entries"]}, {"example"})
        self.assertEqual(len(result["entries"]), 2)
        self.assertTrue(result["coverage_gaps"])
        for extra in ({".cargo/config.toml":'[source.crates-io]\nreplace-with="private"\n'},
                      {".cargo/config.toml":'unsupported invalid config'},):
            result = self.fixture_inventory({"Cargo.lock":lock,"Cargo.toml":manifest,**extra})
            self.assertEqual([e["kind"] for e in result["entries"]], ["resolved-transitive"])
        with patch.dict(health.os.environ, {"CARGO_REGISTRY_DEFAULT":"private"}):
            result = self.fixture_inventory({"Cargo.lock":lock,"Cargo.toml":manifest})
        self.assertEqual([e["kind"] for e in result["entries"]], ["resolved-transitive"])

    def test_cargo_identity_and_sparse_path_are_ecosystem_specific(self):
        for name in ("@scope/name", "name.with.dots", "path/name"):
            with self.subTest(name=name), patch.object(health, "get") as fetch:
                with self.assertRaises(ValueError): health.releases("cargo", name)
                fetch.assert_not_called()
        with patch.object(health,"get",return_value=b'{"vers":"1.0.0"}') as fetch:
            result = health.releases("cargo", "Example_Name")
        self.assertEqual(result["source"], "https://index.crates.io/ex/am/example_name")

    def test_stable_comparison_does_not_promote_prereleases(self):
        self.assertEqual(health.stable_key("v1.12.3"), (1, 12, 3))
        self.assertIsNone(health.stable_key("1.12.3-rc.1"))
        self.assertIsNone(health.stable_key("^1.12.3"))
        self.assertEqual(health.stable_key("2026.10.21"), (2026, 10, 21))

    def test_registry_latest_tag_cannot_label_prerelease_as_stable(self):
        raw = json.dumps({"versions":{"1.0.0":{},"2.0.0-rc.1":{}},"dist-tags":{"latest":"2.0.0-rc.1"}}).encode()
        with patch.object(health, "get", return_value=raw):
            result = health.releases("npm", "example")
        self.assertEqual(result["latest_stable"], "1.0.0")
        self.assertIn("2.0.0-rc.1", result["versions"])

    def test_private_origins_and_firstparty_names_are_not_queried_publicly(self):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="dependency-fixture-") as folder:
            root = Path(folder)
            (root / "package.json").write_text(json.dumps({"name":"private-local","private":True,"dependencies":{"private-local":"1.0.0","@private/pkg":"1.0.0","public":"1.0.0"}}))
            (root / ".npmrc").write_text("@private:registry=https://private.invalid/\n//private.invalid/:_authToken=DO_NOT_LEAK\n")
            (root / "package-lock.json").write_text(json.dumps({"packages":{
                "node_modules/private":{"version":"1.0.0","resolved":"https://private.invalid/private.tgz"},
                "node_modules/public":{"version":"1.0.0","resolved":"https://registry.npmjs.org/public/-/public-1.0.0.tgz"}}}))
            with patch.object(health.subprocess, "check_output", side_effect=["a"*40,b"package.json\0package-lock.json\0"]), patch.object(health.Path,"home",return_value=root):
                result = health.inventory({"repositories":[{"path":folder,"label":"fixture"}]})
            self.assertEqual({entry["name"] for entry in result["entries"]}, {"public"})
            self.assertNotIn("DO_NOT_LEAK", json.dumps(result))
            self.assertNotIn("private.invalid", json.dumps(result))

    def test_real_vendor_manifest_is_not_silently_excluded(self):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="dependency-fixture-") as folder:
            root = Path(folder); (root / "vendor").mkdir()
            (root / "vendor/Cargo.lock").write_text('version = 3\n[[package]]\nname="example"\nversion="1.0.0"\nsource="registry+https://github.com/rust-lang/crates.io-index"\n')
            with patch.object(health.subprocess, "check_output", side_effect=["a"*40,b"vendor/Cargo.lock\0"]):
                result = health.inventory({"repositories":[{"path":folder,"label":"fixture"}]})
            self.assertEqual(result["entries"][0]["name"], "example")

    def test_bom_managed_library_is_tracked_with_unresolved_current(self):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="dependency-fixture-") as folder:
            root = Path(folder)
            (root / "libs.versions.toml").write_text('[libraries]\nui={group="androidx.compose.ui",name="ui"}\n')
            with patch.object(health.subprocess, "check_output", side_effect=["a"*40,b"libs.versions.toml\0"]):
                result = health.inventory({"repositories":[{"path":folder,"label":"fixture"}],
                                           "public_maven_names":["androidx.compose.ui:ui"]})
            self.assertEqual(result["entries"][0]["name"], "androidx.compose.ui:ui")
            self.assertEqual(result["entries"][0]["current"], "BOM-managed/unresolved")
            self.assertTrue(result["coverage_gaps"])

    def test_unknown_maven_and_plugin_names_never_trigger_public_lookup(self):
        for value in ('{module="internal.company:secret",version="1.0"}',
                      '{module="internal.company:secret"}'):
            with self.subTest(value=value):
                result = self.fixture_inventory({"libs.versions.toml":
                    '[libraries]\nprivate=' + value + '\n'
                    '[plugins]\nprivate={id="internal.company.plugin",version="1.0"}\n'})
                self.assertEqual(result["entries"], [])
                self.assertNotIn("internal.company", json.dumps(result))
                self.assertTrue(result["coverage_gaps"])

    def test_multiple_new_versions_including_prerelease_are_all_reported(self):
        inventory = {"entries": [{"ecosystem":"npm", "name":"example", "current":"1.0.0"}], "coverage_gaps":[]}
        before = {"releases":{"npm:example":{"versions":["1.0.0"],"latest_stable":"1.0.0"}}}
        release = {"versions":["1.0.0","1.0.1","1.1.0","2.0.0-rc.1"],"latest_stable":"1.1.0","source":"https://registry.npmjs.org/example"}
        with patch.object(health, "releases", return_value=release):
            report = health.compare(inventory, before, 1)
        self.assertEqual(report["new_releases"][0]["new_versions"], ["1.0.1","1.1.0","2.0.0-rc.1"])
        self.assertEqual(report["entries"][0]["status"], "outdated")

    def test_registry_failure_is_unverified_and_retains_original_cursor(self):
        previous = {"versions":["1.0.0"],"latest_stable":"1.0.0"}
        inventory = {"entries":[{"ecosystem":"cargo","name":"example","current":"1.0.0"}],"coverage_gaps":[]}
        with patch.object(health, "releases", side_effect=ValueError("untrusted response")):
            report = health.compare(inventory, {"releases":{"cargo:example":previous}}, 1)
        self.assertEqual(report["releases"]["cargo:example"], previous)
        self.assertEqual(report["entries"][0]["status"], "unverified")
        self.assertFalse(report["complete"])
        self.assertEqual(len(report["registry_errors"]), 1)

    def test_new_component_is_enrolled_without_fabricating_new_release(self):
        inventory = {"entries":[{"ecosystem":"npm","name":"new","current":"^1"}],"coverage_gaps":[]}
        with patch.object(health, "releases", return_value={"versions":["1.0.0"],"latest_stable":"1.0.0","source":"https://registry.npmjs.org/new"}):
            report = health.compare(inventory, {"releases":{"npm:old":{}}}, 1)
        self.assertEqual(report["new_releases"], [])
        self.assertEqual(report["newly_tracked"][0]["component"], "npm:new")
        self.assertEqual(report["entries"][0]["status"], "latest-comparison-needs-resolution")

    def test_manifest_and_transitive_lock_keep_different_versions(self):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="dependency-fixture-") as folder:
            root = Path(folder)
            (root / "package.json").write_text(json.dumps({"dependencies":{"example":"^2","local":"file:../local"}}))
            (root / "package-lock.json").write_text(json.dumps({"packages":{"node_modules/example":{"version":"2.0.0"},"node_modules/nested/node_modules/example":{"version":"1.9.0"}}}))
            with patch.object(health.subprocess, "check_output", side_effect=["a"*40, b"package.json\0package-lock.json\0"]):
                report = health.inventory({"repositories":[{"path":folder,"label":"fixture"}]})
            self.assertEqual({e["current"] for e in report["entries"]}, {"^2","2.0.0","1.9.0"})
            self.assertTrue(all(e["name"] == "example" for e in report["entries"]))

    def test_unsupported_format_and_broken_repository_never_count_as_complete(self):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="dependency-fixture-") as folder:
            (Path(folder) / "go.mod").write_text("module example\n")
            with patch.object(health.subprocess, "check_output", side_effect=["a"*40,b"go.mod\0"]):
                report = health.inventory({"repositories":[{"path":folder,"label":"fixture"}]})
            self.assertEqual(len(report["coverage_gaps"]), 1)
        with patch.object(health.subprocess, "check_output", side_effect=OSError("unavailable")):
            report = health.inventory({"repositories":[{"path":"/missing","label":"fixture"}]})
        self.assertEqual(len(report["coverage_gaps"]), 1)

    def test_unchanged_release_list_is_quiet_but_coverage_errors_are_not_hidden(self):
        metadata = {"versions":["1.0.0"],"latest_stable":"1.0.0","source":"https://registry.npmjs.org/example"}
        inventory = {"entries":[{"ecosystem":"npm","name":"example","current":"1.0.0"}],"coverage_gaps":[{"source":"native","reason":"unresolved"}]}
        with patch.object(health,"releases",return_value=metadata):
            report = health.compare(inventory,{"releases":{"npm:example":metadata}},1)
        self.assertEqual(report["new_releases"], [])
        self.assertEqual(report["entries"][0]["status"], "current-or-newer")
        self.assertFalse(report["complete"])

    def test_source_failure_retains_absent_cursor_and_later_intervening_release(self):
        previous = {"versions":["1.0.0"],"latest_stable":"1.0.0","source":"https://registry.npmjs.org/example"}
        missing = {"entries":[],"coverage_gaps":[{"source":"repo","reason":"Repository unavailable"}]}
        with patch.object(health, "releases") as fetch:
            failed = health.compare(missing, {"releases":{"npm:example":previous}}, 1)
        fetch.assert_not_called()
        self.assertEqual(failed["releases"]["npm:example"], previous)
        self.assertFalse(failed["complete"])
        restored = {"entries":[{"ecosystem":"npm","name":"example","current":"1.0.0","kind":"resolved-transitive"}],
                    "coverage_gaps":[]}
        current = {**previous,"versions":["1.0.0","1.1.0"],"latest_stable":"1.1.0"}
        with patch.object(health, "releases", return_value=current):
            recovered = health.compare(restored, failed, 1)
        self.assertEqual(recovered["newly_tracked"], [])
        self.assertEqual(recovered["new_releases"][0]["new_versions"], ["1.1.0"])

    def test_release_contraction_cannot_make_reappearing_old_version_new(self):
        previous = {"versions":["1.0.0","2.0.0-rc.1"],"latest_stable":"1.0.0",
                    "source":"https://registry.npmjs.org/example"}
        def inventory():
            return {"entries":[{"ecosystem":"npm","name":"example","current":"1.0.0","kind":"resolved-transitive"}],
                    "coverage_gaps":[]}
        with patch.object(health, "releases", return_value={**previous,"versions":["1.0.0"]}):
            contracted = health.compare(inventory(), {"releases":{"npm:example":previous}}, 1)
        self.assertEqual(contracted["releases"]["npm:example"]["versions"], previous["versions"])
        with patch.object(health, "releases", return_value=previous):
            reappeared = health.compare(inventory(), contracted, 1)
        self.assertEqual(reappeared["new_releases"], [])

    def test_generic_compare_marks_dropped_versions_and_excludes_inactive_prior_keys(self):
        previous = {
            "versions": ["1.0.0", "2.0.0-rc.1"],
            "latest_stable": "1.0.0",
            "source": "https://index.crates.io/ex/am/example",
        }
        inactive = {**previous, "source": "https://index.crates.io/ac/ti/active"}
        inventory = {"entries": [{"ecosystem": "cargo", "name": "example", "current": "1.0.0",
                                  "kind": "resolved-transitive"}], "coverage_gaps": []}
        current = {"versions": ["1.0.0"], "latest_stable": "1.0.0",
                   "source": previous["source"]}
        with patch.object(health, "releases", return_value=current):
            report = health.compare(
                inventory,
                {"releases": {"cargo:example": previous, "cargo:inactive": inactive}},
                1,
            )
        self.assertEqual(report["successful_observations"].keys(), {"cargo:example"})
        self.assertEqual(report["releases"]["cargo:example"]["versions"], previous["versions"])
        self.assertEqual(report["releases"]["cargo:example"]["absent_versions"], ["2.0.0-rc.1"])
        self.assertEqual(report["history_contractions"][0]["component"], "cargo:example")
        self.assertEqual(report["releases"]["cargo:inactive"], inactive)

    def test_cargo_declared_constraint_is_not_an_installed_version(self):
        inventory = {"entries":[
            {"ecosystem":"cargo","name":"example","current":"1","kind":"dependencies"},
            {"ecosystem":"cargo","name":"example","current":"1.9.0","kind":"workspace"},
            {"ecosystem":"cargo","name":"example","current":"1.9.0","kind":"resolved-transitive"},
        ],"coverage_gaps":[]}
        with patch.object(health, "releases", return_value={"versions":["1.9.0"],"latest_stable":"1.9.0",
                                                          "source":"https://index.crates.io/ex/am/example"}):
            report = health.compare(inventory, {}, 1)
        self.assertEqual([e["status"] for e in report["entries"]],
                         ["latest-comparison-needs-resolution","latest-comparison-needs-resolution","current-or-newer"])
        self.assertEqual(report["unresolved_entries"], 2)
        self.assertFalse(report["complete"])

    def test_npm_partial_declaration_stays_unresolved_while_exact_pin_is_compared(self):
        inventory = {"entries":[
            {"ecosystem":"npm","name":"example","current":"1.2","kind":"dependencies"},
            {"ecosystem":"npm","name":"example","current":"1.2.9","kind":"dependencies"},
            {"ecosystem":"npm","name":"example","current":"1.2.9","kind":"resolved-transitive"},
        ],"coverage_gaps":[]}
        with patch.object(health, "releases", return_value={"versions":["1.2.9"],"latest_stable":"1.2.9",
                                                          "source":"https://registry.npmjs.org/example"}):
            report = health.compare(inventory, {}, 1)
        self.assertEqual([e["status"] for e in report["entries"]],
                         ["latest-comparison-needs-resolution","current-or-newer","current-or-newer"])
        self.assertEqual(report["unresolved_entries"], 1)
        self.assertFalse(report["complete"])

class MavenMetadataSecurityTests(unittest.TestCase):
    name = "public.example:fixture"
    source = "https://repo.maven.apache.org/maven2/public/example/fixture/maven-metadata.xml"
    document = ('<metadata><versioning><versions><version>1.0.0</version>'
                '<version>2.0.&#48;</version><version>3.0.0-rc.1</version>'
                '</versions></versioning></metadata>')

    def test_normal_metadata_encodings_keep_versions_latest_and_source(self):
        for encoding in ("utf-8", "utf-16"):
            with self.subTest(encoding=encoding), patch.object(health, "get", return_value=self.document.encode(encoding)) as fetch:
                metadata = health.releases("maven", self.name)
            self.assertEqual(metadata, {"versions":["1.0.0", "2.0.0", "3.0.0-rc.1"],
                                        "latest_stable":"2.0.0", "source":self.source})
            fetch.assert_called_once_with(self.source)

    def test_version_path_text_and_namespace_behavior_is_retained(self):
        document = (b'<metadata><version>ignored</version><versioning><versions>'
                    b'<version>1.0.0<ignored>9.0.0</ignored>8.0.0</version>'
                    b'<version/><version xmlns="urn:ignored">7.0.0</version>'
                    b'<version><![CDATA[2.0.0]]></version></versions></versioning></metadata>')
        self.assertEqual(health.maven_versions(document), ["1.0.0", "2.0.0"])

    def test_dtd_entities_reject_before_any_expansion_in_all_encodings(self):
        declarations = (
            '<!DOCTYPE metadata>',
            '<!DOCTYPE metadata [<!ENTITY value "1.0.0">]>',
            '<!DOCTYPE metadata [<!ENTITY value SYSTEM "file:///unread-fixture">]>',
            '<!DOCTYPE metadata [<!ENTITY % value "ignored">%value;]>',
            '<!DOCTYPE metadata SYSTEM "https://unread.invalid/fixture.dtd">',
        )
        for declaration in declarations:
            for encoding in ("utf-8", "utf-16"):
                with self.subTest(declaration=declaration, encoding=encoding), \
                     self.assertRaisesRegex(ValueError, "declarations"):
                    health.maven_versions((declaration + self.document).encode(encoding))

    def test_size_structure_and_malformed_xml_are_bounded(self):
        with patch.object(health, "LIMIT", 10), self.assertRaisesRegex(ValueError, "bound"):
            health.maven_versions(self.document.encode())
        for raw in (b"<metadata>", b"<metadata>" + b"<node>" * 64 + b"</node>" * 64 + b"</metadata>",
                    b"<metadata>" + b"<node/>" * 200_000 + b"</metadata>"):
            with self.subTest(prefix=raw[:40]), self.assertRaises(ValueError):
                health.maven_versions(raw)

    def test_rejected_metadata_retains_complete_previous_cursor_and_source(self):
        previous = {"versions":["0.9.0", "1.0.0"], "latest_stable":"1.0.0", "source":self.source,
                    "observed_at":"2026-10-21T00:00:00+00:00"}
        inventory = {"entries":[{"ecosystem":"maven", "name":self.name, "current":"1.0.0",
                                 "kind":"declared-library"}], "coverage_gaps":[]}
        malicious = '<!DOCTYPE metadata [<!ENTITY value "2.0.0">]>' + self.document
        with patch.object(health, "get", return_value=malicious.encode("utf-16")):
            result = health.compare(inventory, {"releases":{"maven:" + self.name:previous}}, 1)
        self.assertEqual(result["releases"]["maven:" + self.name], previous)
        self.assertEqual(result["registry_errors"], [{"component":"maven:" + self.name, "reason":"ValueError"}])
        self.assertEqual(result["new_releases"], [])
        self.assertEqual(result["entries"][0]["status"], "unverified")
        self.assertFalse(result["complete"])

    def test_public_registry_redirects_require_https_without_userinfo(self):
        handler = health.RegistryHTTPSRedirects()
        request = health.urllib.request.Request(self.source)
        for url in ("http://repo.maven.apache.org/fixture", "ftp://repo.maven.apache.org/fixture",
                    "file:///unread-fixture", "https://user:fixture@repo.maven.apache.org/fixture",
                    "https://repo.maven.apache.org:444/fixture", "https://repo.maven.apache.org/fixture#fragment"):
            with self.subTest(redirect=url), self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "Found", {}, url)
        allowed = handler.redirect_request(request, None, 302, "Found", {},
                                           "https://plugins-artifacts.gradle.org/fixture")
        self.assertEqual(allowed.host, "plugins-artifacts.gradle.org")
        with patch.object(health.urllib.request, "build_opener") as build:
            build.return_value.open.return_value.__enter__.return_value.read.return_value = b"metadata"
            self.assertEqual(health.get(self.source), b"metadata")
        self.assertIsInstance(build.call_args.args[0], health.RegistryHTTPSRedirects)


class GitHubHistoryTests(unittest.TestCase):
    name = "public/example"
    source = "https://api.github.com/repos/public/example/releases"
    stamp = "2026-10-21T00:00:00Z"

    def inventory(self):
        return {"entries":[{"ecosystem":"github", "name":self.name, "current":"v1.0.0", "kind":"github-action"}],
                "coverage_gaps":[]}

    def metadata(self, commit="a"*40, asset_revision="c"*64):
        return {"github_history_schema":2, "legacy_published_versions":[], "repository":self.name, "source":self.source,
                "versions":["v1.0.0"], "latest_stable":"v1.0.0", "observations":{
                    "tag:v1.0.0":{"kind":"tag", "version":"v1.0.0", "commit":commit, "ref_type":"commit", "ref":commit},
                    "release:1":{"kind":"release", "version":"v1.0.0", "id":1, "revision":"b"*64},
                    "asset:1:2":{"kind":"asset", "version":"v1.0.0", "release_id":1, "id":2,
                                 "revision":asset_revision, "digest":None}}}

    def report(self, metadata, prior):
        with patch.object(health, "releases", return_value=metadata):
            return health.compare(self.inventory(), prior, 1)

    def api(self, tags=("v1.0.0", "v2.0.0-rc.1", "v99.0.0"), releases=True):
        base = self.source.removesuffix("/releases")
        release = {"id":1, "tag_name":"v1.0.0", "draft":False, "prerelease":False,
                   "created_at":self.stamp, "published_at":self.stamp, "updated_at":self.stamp, "body":None, "name":None}
        rc = {**release, "id":3, "tag_name":"v2.0.0-rc.1", "prerelease":True}
        asset = {"id":2, "name":"component.zip", "size":12, "state":"uploaded", "content_type":"application/zip",
                 "created_at":self.stamp, "updated_at":self.stamp, "digest":"sha256:"+"d"*64,
                 "url":base+"/releases/assets/2",
                 "browser_download_url":"https://github.com/public/example/releases/download/v1.0.0/component.zip"}
        data = {base:{"private":False,"visibility":"public","full_name":self.name},
                base+"/tags?per_page=100&page=1":[{"name":tag,"commit":{"sha":"a"*40}} for tag in tags],
                base+"/git/matching-refs/tags/":[{"ref":"refs/tags/"+tag,"object":{"type":"commit","sha":"a"*40}} for tag in tags],
                self.source+"?per_page=100&page=1":[release,rc] if releases else [],
                base+"/releases/1/assets?per_page=100&page=1":[asset],
                base+"/releases/3/assets?per_page=100&page=1":[]}
        return data

    def test_all_tags_rc_and_published_releases_union_without_tag_stable_inference(self):
        data = self.api()
        with patch.object(health, "get", side_effect=lambda url,github=False: json.dumps(data[url]).encode()) as fetch:
            result = health.releases("github", self.name)
        self.assertEqual(result["versions"], ["v1.0.0","v2.0.0-rc.1","v99.0.0"])
        self.assertEqual(result["latest_stable"], "v1.0.0")
        self.assertIn("asset:1:2", result["observations"])
        self.assertTrue(all(call.args[0].startswith("https://api.github.com/repos/public/example") for call in fetch.call_args_list))
        self.assertFalse(any("/latest" in call.args[0] or "/download/" in call.args[0] for call in fetch.call_args_list))
        data = self.api(tags=("v99.0.0",), releases=False)
        with patch.object(health, "get", side_effect=lambda url,github=False: json.dumps(data[url]).encode()):
            tags_only = health.releases("github", self.name)
        self.assertEqual(tags_only["versions"], ["v99.0.0"])
        self.assertIsNone(tags_only["latest_stable"])

    def test_private_or_foreign_repository_stops_before_history_and_no_origin_is_retained(self):
        for repository in ({"private":True,"visibility":"private","full_name":self.name},
                           {"private":False,"visibility":"public","full_name":"foreign/example"}):
            with self.subTest(repository=repository), patch.object(health, "get", return_value=json.dumps(repository).encode()) as fetch:
                with self.assertRaises(ValueError): health.releases("github", self.name)
                self.assertEqual(fetch.call_count, 1)
                self.assertEqual(fetch.call_args.kwargs, {})

    def test_github_cli_has_fixed_host_and_rejects_foreign_query_or_path_before_process(self):
        from types import SimpleNamespace
        bad = ("https://private.invalid/repos/public/example", "https://api.github.com.evil/repos/public/example",
               "https://user@api.github.com/repos/public/example", "https://api.github.com:443/repos/public/example",
               self.source+"?token=DO_NOT_LEAK", self.source+"/latest", self.source+"#fragment")
        with patch.object(health.subprocess, "run") as run:
            for url in bad:
                with self.subTest(url=url), self.assertRaises(ValueError): health.get(url, github=True)
            run.assert_not_called()
        with patch.dict(health.os.environ, {"GH_HOST":"private.invalid"}), patch.object(
                health.subprocess, "run", return_value=SimpleNamespace(returncode=0,stdout=b"[]")) as run:
            self.assertEqual(health.get(self.source+"?per_page=100&page=1", github=True), b"[]")
        self.assertEqual(run.call_args.args[0][:5], ["gh","api","--hostname","github.com","--method"])
        self.assertEqual(run.call_args.args[0][-1], "repos/public/example/releases?per_page=100&page=1")
        with patch.object(health.urllib.request, "build_opener") as build, patch.object(health.subprocess, "run") as run:
            build.return_value.open.return_value.__enter__.return_value.read.return_value = b"{}"
            self.assertEqual(health.get(self.source.removesuffix("/releases")), b"{}")
            request = build.return_value.open.call_args.args[0]
            self.assertNotIn("Authorization", request.headers)
            run.assert_not_called()
        with self.assertRaises(ValueError):
            health.GitHubNoRedirect().redirect_request(None,None,302,"",{},"https://private.invalid/DO_NOT_LEAK")

    def test_pagination_bound_overlap_malformed_and_ref_mismatch_fail_instead_of_truncate(self):
        full = [{"id":number+1} for number in range(100)]
        with patch.object(health, "GITHUB_PAGES", 1), patch.object(health, "get", return_value=json.dumps(full).encode()):
            with self.assertRaises(ValueError): health.github_list(self.source, "id")
        with patch.object(health, "get", side_effect=[json.dumps(full).encode(),json.dumps([full[0]]).encode()]):
            with self.assertRaises(ValueError): health.github_list(self.source, "id")
        for value in ({}, [None], [{"id":True}]):
            with self.subTest(value=value), patch.object(health, "get", return_value=json.dumps(value).encode()):
                with self.assertRaises((ValueError,KeyError,TypeError)): health.github_list(self.source, "id")
        data = self.api(); data[self.source.removesuffix("/releases")+"/git/matching-refs/tags/"] = []
        with patch.object(health, "get", side_effect=lambda url,github=False: json.dumps(data[url]).encode()):
            with self.assertRaises(ValueError): health.releases("github", self.name)

    def test_bad_asset_url_or_schema_fails_whole_component_and_retains_cursor(self):
        previous = self.metadata()
        for field,value in (("browser_download_url","https://user:DO_NOT_LEAK@private.invalid/asset"),
                            ("url","https://private.invalid/metadata"), ("size",-1), ("digest","md5:untrusted")):
            data = self.api()
            data[self.source.removesuffix("/releases")+"/releases/1/assets?per_page=100&page=1"][0][field] = value
            checkpoints = []
            with self.subTest(field=field), patch.object(health,"get",side_effect=lambda url,github=False: json.dumps(data[url]).encode()):
                report = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1,
                                        lambda *args: checkpoints.append(args))
            self.assertEqual(report["releases"]["github:"+self.name], previous)
            self.assertEqual(report["new_releases"], [])
            self.assertEqual(report["entries"][0]["status"], "unverified")
            self.assertIsNone(checkpoints[0][1])
            self.assertNotIn("DO_NOT_LEAK", json.dumps(report))
            self.assertNotIn("private.invalid", json.dumps(report))

    def test_retag_and_asset_metadata_change_keep_every_revision_without_new_version(self):
        before = self.metadata()
        after = self.metadata(commit="e"*40, asset_revision="f"*64)
        report = self.report(after, {"releases":{"github:"+self.name:before}})
        self.assertEqual(report["new_releases"], [])
        changed = {(event["identity"],event["change"]) for event in report["github_observation_changes"]}
        self.assertEqual(changed, {("tag:v1.0.0","changed"),("asset:1:2","changed")})
        history = report["releases"]["github:"+self.name]["observation_history"]
        self.assertEqual(len(history["tag:v1.0.0"]), 2)
        self.assertEqual(len(history["asset:1:2"]), 2)
        # Annotated tag replacement at the same peeled commit is also observable.
        old = self.metadata(); old["observations"]["tag:v1.0.0"].update(ref_type="tag",ref="d"*40)
        new = self.metadata(); new["observations"]["tag:v1.0.0"].update(ref_type="tag",ref="e"*40)
        annotated = self.report(new, {"releases":{"github:"+self.name:old}})
        self.assertEqual(annotated["github_observation_changes"][0]["change"], "changed")

    def test_disappearance_reappearance_preserves_cursor_head_and_is_not_a_new_release(self):
        before = self.metadata()
        gone = self.metadata(); del gone["observations"]["asset:1:2"]
        contracted = self.report(gone, {"releases":{"github:"+self.name:before}})
        retained = contracted["releases"]["github:"+self.name]
        self.assertIn("asset:1:2", retained["observations"])
        self.assertEqual(retained["absent_observations"], ["asset:1:2"])
        self.assertEqual(contracted["entries"][0]["status"], "unverified")
        self.assertFalse(contracted["complete"])
        self.assertEqual(contracted["github_observation_changes"][0]["change"], "disappeared")
        restored = self.report(before, contracted)
        self.assertEqual(restored["new_releases"], [])
        self.assertEqual(restored["releases"]["github:"+self.name]["absent_observations"], [])
        self.assertEqual(restored["github_observation_changes"][0]["change"], "reappeared")
        lost_version = self.metadata()
        lost_version["versions"] = []; lost_version["latest_stable"] = None; lost_version["observations"] = {}
        contraction = self.report(lost_version, {"releases":{"github:"+self.name:before}})
        self.assertEqual(contraction["releases"]["github:"+self.name]["latest_stable"], "v1.0.0")
        self.assertEqual(contraction["releases"]["github:"+self.name]["versions"], ["v1.0.0"])
        self.assertEqual(len(contraction["history_contractions"][0]["missing_observations"]), 3)
        returned = self.report(before, contraction)
        self.assertEqual(returned["new_releases"], [])
        self.assertEqual(len(returned["github_observation_changes"]), 3)

    def test_legacy_baseline_notifies_new_published_version_but_quietly_enrolls_old_tag(self):
        old = {"versions":["v0.9.0"],"latest_stable":"v0.9.0","source":self.source}
        current = self.metadata()
        current["versions"].append("v99.0.0")
        current["observations"]["tag:v99.0.0"] = {
            "kind":"tag","version":"v99.0.0","commit":"a"*40,"ref_type":"commit","ref":"a"*40}
        report = self.report(current, {"releases":{"github:"+self.name:old}})
        self.assertEqual(report["new_releases"][0]["new_versions"], ["v1.0.0"])
        self.assertNotIn("v99.0.0", report["new_releases"][0]["new_versions"])
        self.assertEqual(report["github_observation_changes"], [])
        self.assertEqual(report["newly_tracked"][0]["kind"], "github-history-baseline")
        self.assertEqual(report["releases"]["github:"+self.name]["versions"], ["v0.9.0","v1.0.0","v99.0.0"])
        self.assertEqual(report["history_contractions"][0]["missing_versions"], ["v0.9.0"])

    def test_tag_previously_observed_then_published_notifies_once_and_new_tag_is_not_release(self):
        tag_only = self.metadata()
        tag_only["latest_stable"] = None
        tag_only["observations"] = {"tag:v1.0.0":tag_only["observations"]["tag:v1.0.0"]}
        published = self.report(self.metadata(), {"releases":{"github:"+self.name:tag_only}})
        self.assertEqual(published["new_releases"][0]["new_versions"], ["v1.0.0"])
        unchanged = self.report(self.metadata(), published)
        self.assertEqual(unchanged["new_releases"], [])
        current = self.metadata(); current["versions"].append("v99.0.0")
        current["observations"]["tag:v99.0.0"] = {
            "kind":"tag","version":"v99.0.0","commit":"a"*40,"ref_type":"commit","ref":"a"*40}
        tag_added = self.report(current, unchanged)
        self.assertEqual(tag_added["new_releases"], [])
        self.assertTrue(any(event["identity"] == "tag:v99.0.0" and event["change"] == "added"
                            for event in tag_added["github_observation_changes"]))

    def test_prior_repository_mismatch_fails_before_success_checkpoint(self):
        legacy = {"versions":["v0.9.0"],"latest_stable":"v0.9.0","source":self.source}
        foreign = self.metadata(); foreign["repository"] = "foreign/example"
        foreign["source"] = "https://api.github.com/repos/foreign/example/releases"
        for previous in ({**legacy,"source":"https://api.github.com/repos/foreign/example/releases"},
                         {**legacy,"repository":"foreign/example"}, foreign):
            checkpoints = []
            with self.subTest(previous=previous), patch.object(health,"releases",return_value=self.metadata()):
                report = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1,
                                        lambda *args: checkpoints.append(args))
            self.assertEqual(report["releases"]["github:"+self.name], previous)
            self.assertEqual(report["new_releases"], [])
            self.assertIsNone(checkpoints[0][1])
            self.assertIsNotNone(checkpoints[0][2])

    def test_malformed_prior_history_preserves_exact_cursor_and_failed_checkpoint(self):
        previous = self.metadata()
        previous["observation_history"] = {
            "tag:v1.0.0":{"not-a-fingerprint":previous["observations"]["tag:v1.0.0"]}}
        checkpoints = []
        with patch.object(health,"releases",return_value=self.metadata()):
            report = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1,
                                    lambda *args: checkpoints.append(args))
        self.assertEqual(report["releases"]["github:"+self.name], previous)
        self.assertEqual(report["new_releases"], [])
        self.assertIsNone(checkpoints[0][1])
        self.assertIsNotNone(checkpoints[0][2])

    def test_legacy_publication_aba_is_quiet_but_old_tag_later_publication_notifies_once(self):
        old = {"versions":["v0.9.0"],"latest_stable":"v0.9.0","source":self.source}
        current = self.metadata(); current["versions"].append("v99.0.0")
        current["observations"]["tag:v99.0.0"] = {
            "kind":"tag","version":"v99.0.0","commit":"a"*40,"ref_type":"commit","ref":"a"*40}
        migrated = self.report(current, {"releases":{"github:"+self.name:old}})
        self.assertEqual(migrated["new_releases"][0]["new_versions"], ["v1.0.0"])
        self.assertEqual(migrated["releases"]["github:"+self.name]["legacy_published_versions"], ["v0.9.0"])
        returned = json.loads(json.dumps(current))
        returned["versions"].insert(0, "v0.9.0")
        returned["observations"]["release:9"] = {
            "kind":"release","version":"v0.9.0","id":9,"revision":"9"*64}
        reappeared = self.report(returned, migrated)
        self.assertEqual(reappeared["new_releases"], [])
        self.assertEqual(reappeared["releases"]["github:"+self.name]["legacy_published_versions"], ["v0.9.0"])
        published = json.loads(json.dumps(returned))
        published["observations"]["release:99"] = {
            "kind":"release","version":"v99.0.0","id":99,"revision":"f"*64}
        notified = self.report(published, reappeared)
        self.assertEqual(notified["new_releases"][0]["new_versions"], ["v99.0.0"])
        self.assertEqual(self.report(published, notified)["new_releases"], [])

    def test_unknown_rich_schema_and_malformed_retained_legacy_provenance_fail_checkpoint(self):
        cases = []
        for schema in (1, 3, None, True):
            value = self.metadata(); value["github_history_schema"] = schema; cases.append(value)
        for marker in ("v1.0.0", ["v99.0.0"], ["v1.0.0","v1.0.0"]):
            value = self.metadata(); value["legacy_published_versions"] = marker; cases.append(value)
        unsorted = self.metadata(); unsorted["versions"] = ["v0.9.0","v1.0.0"]
        unsorted["legacy_published_versions"] = ["v1.0.0","v0.9.0"]; cases.append(unsorted)
        for previous in cases:
            checkpoints = []
            with self.subTest(previous=previous), patch.object(health,"releases",return_value=self.metadata()):
                report = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1,
                                        lambda *args: checkpoints.append(args))
            self.assertEqual(report["releases"]["github:"+self.name], previous)
            self.assertEqual(report["new_releases"], [])
            self.assertIsNone(checkpoints[0][1]); self.assertIsNotNone(checkpoints[0][2])

    def test_malformed_unversioned_publication_cursor_never_becomes_provenance(self):
        legacy = {"versions":["v0.9.0"],"latest_stable":"v0.9.0","source":self.source}
        for previous in ({**legacy,"versions":["v0.9.0","v0.9.0"]},
                         {**legacy,"versions":["v1.0.0","v0.9.0"]},
                         {**legacy,"legacy_published_versions":["v99.0.0"]}):
            checkpoints = []
            with self.subTest(previous=previous), patch.object(health,"releases",return_value=self.metadata()):
                report = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1,
                                        lambda *args: checkpoints.append(args))
            self.assertEqual(report["releases"]["github:"+self.name], previous)
            self.assertIsNone(checkpoints[0][1]); self.assertIsNotNone(checkpoints[0][2])

    def test_failed_schema_or_refresh_cannot_advance_report_or_success_journal(self):
        previous = self.metadata(); malformed = self.metadata()
        malformed["observations"]["tag:v1.0.0"]["commit"] = "not-a-commit"
        checkpoints = []
        with patch.object(health,"releases",return_value=malformed):
            failed = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1,
                                    lambda *args: checkpoints.append(args))
        self.assertEqual(failed["releases"]["github:"+self.name], previous)
        self.assertIsNone(checkpoints[0][1])
        with patch.object(health,"releases",side_effect=RuntimeError("DO_NOT_LEAK")):
            failed = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1)
        self.assertEqual(failed["releases"]["github:"+self.name], previous)
        self.assertNotIn("DO_NOT_LEAK", json.dumps(failed))
        with patch.object(health,"releases") as fetch:
            replay = health.compare(self.inventory(), {"releases":{"github:"+self.name:previous}}, 1,
                                    reuse={"github:"+self.name:{"versions":["v9.0.0"]}})
        fetch.assert_not_called()
        self.assertEqual(replay["releases"]["github:"+self.name], previous)


class NativeDependencyAdapterTests(unittest.TestCase):
    """Offline native topology/retention checks; no registry or GitHub calls."""
    @classmethod
    def setUpClass(cls):
        adapter_path = ROOT / "scripts/dependency_native_adapter.py"
        adapter_spec = importlib.util.spec_from_file_location("dependency_native_adapter", adapter_path)
        cls.adapter = importlib.util.module_from_spec(adapter_spec)
        assert adapter_spec.loader is not None
        adapter_spec.loader.exec_module(cls.adapter)
        capture_path = ROOT / "scripts/tests/fixtures/native-manifest-capture.json"
        cls.capture = json.loads(capture_path.read_text())
        cls.manifest = cls.manifest_from_capture(cls.capture)

    @staticmethod
    def manifest_from_capture(capture):
        upstreams = {}
        for group, repository in capture["github"]:
            repository = repository.lower()
            upstreams[group] = {
                "mode": "github-tags+releases",
                "endpoints": [
                    f"https://api.github.com/repos/{repository}/releases?per_page=100&page={{page}}",
                    f"https://api.github.com/repos/{repository}/tags?per_page=100&page={{page}}",
                ],
                "review": "CAPTURED_PUBLIC_TABLE",
            }
            if group == "dovi":
                upstreams[group]["scope"] = capture["scope_notes"]["dovi"]
        for group, mode, endpoint in capture["unsupported"]:
            endpoints = endpoint if isinstance(endpoint, list) else ([] if endpoint is None else [endpoint])
            upstreams[group] = {
                "mode": mode,
                "endpoints": endpoints,
                "review": "CAPTURED_PUBLIC_TABLE",
            }
        lanes = {}
        for row, groups, pin_map in capture["lanes"]:
            lanes[f"native-{row:02d}"] = {
                "row": row,
                "component": f"captured-native-{row:02d}",
                "lane": "captured",
                "evidence": {"tsv_data_row": row, "pin_map": pin_map},
                "upstreams": groups,
                "modes": [upstreams[group]["mode"] for group in groups],
            }
        supplemental = {}
        for name, groups in capture["supplemental"]:
            supplemental[name] = {
                "component": name,
                "upstreams": groups,
                "modes": [upstreams[group]["mode"] for group in groups],
            }
        return {
            "schema_version": 1,
            "counts": capture["counts"],
            "source_evidence": {
                "inventory": {"sha256": "1" * 64},
                "pin_map": {"sha256": "2" * 64},
                "original_readme": {"sha256": "3" * 64},
                "central_config_snapshot": {"sha256": "4" * 64},
            },
            "upstreams": upstreams,
            "lanes": lanes,
            "supplemental_observations": supplemental,
        }

    def test_public_capture_and_mixed_case_identity_are_complete(self):
        mapping = self.adapter.github_upstream_identities(self.manifest)
        self.assertEqual(len(self.manifest["lanes"]), 63)
        self.assertEqual(len(self.manifest["upstreams"]), 69)
        self.assertEqual(len(mapping["identities"]), 34)
        result = self.adapter.augment_inventory(
            {"entries": [{
                "ecosystem": "github", "name": "MPV-PLAYER/MPV",
                "current": "manual-pin", "repository": "config",
                "source": "pin-map", "kind": "manual-pin",
            }], "coverage_gaps": []},
            self.manifest,
        )
        matches = [entry for entry in result["entries"]
                   if entry["ecosystem"] == "github" and entry["name"] == "mpv-player/mpv"]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["name_aliases"], ["MPV-PLAYER/MPV"])

    def test_native_mapping_projection_covers_all_lanes_and_supplemental_observations(self):
        coverage = self.adapter.build_native_coverage(self.manifest)
        lane_rows = [mapping for record in coverage["groups"].values()
                     for mapping in record["lane_mappings"]]
        supplemental_rows = [mapping for record in coverage["groups"].values()
                             for mapping in record["supplemental_mappings"]]
        expected_lane_rows = sum(len(lane["upstreams"]) for lane in self.manifest["lanes"].values())
        expected_supplemental_rows = sum(
            len(spec["upstreams"]) for spec in self.manifest["supplemental_observations"].values())
        self.assertEqual(len(lane_rows), expected_lane_rows)
        self.assertEqual({(item["lane"], item["row"]) for item in lane_rows},
                         {(name, lane["row"]) for name, lane in self.manifest["lanes"].items()})
        self.assertEqual(len({item["observation"] for item in supplemental_rows}),
                         len(self.manifest["supplemental_observations"]))
        self.assertEqual(len(supplemental_rows), expected_supplemental_rows)
        for item in lane_rows + supplemental_rows:
            for value in item.values():
                if isinstance(value, str):
                    self.assertNotIn("/", value)
                    self.assertNotIn("\\", value)
                    self.assertNotIn("\n", value)
        private = json.loads(json.dumps(self.manifest))
        private["lanes"]["native-01"]["component"] = "/Users/daksh/private-component"
        private["lanes"]["native-01"]["evidence"]["pin_map"] = "/private/pin-map"
        private["supplemental_observations"]["monitor-python"]["component"] = "/private/runtime"
        private_coverage = self.adapter.build_native_coverage(private)
        private_text = json.dumps(private_coverage["groups"], sort_keys=True)
        self.assertNotIn("/Users/daksh/private-component", private_text)
        self.assertNotIn("/private/pin-map", private_text)
        self.assertNotIn("/private/runtime", private_text)

    def test_contraction_and_unsupported_retention_are_flat(self):
        previous = self.adapter.build_native_coverage(self.manifest)
        previous["groups"]["mpv"]["status"] = "observed"
        previous["groups"]["mpv"]["last_success"] = {"cursor": "retained"}
        previous["groups"]["ffmpeg"]["journal_refs"] = [f"ref-{index}" for index in range(20)]
        previous["groups"]["ffmpeg"]["previous_state"] = {"previous_state": {"status": "unverified"}}
        comparison = {
            "releases": {"github:mpv-player/mpv": {
                "absent_observations": ["tag:v2"], "absent_versions": []}},
            "history_contractions": [{"component": "github:mpv-player/mpv"}],
        }
        current = self.adapter.coverage_after_compare(self.manifest, previous, comparison)
        mpv = current["groups"]["mpv"]
        self.assertEqual(mpv["status"], "unverified")
        self.assertEqual(mpv["reason"], "existing-github-observer-incomplete")
        self.assertEqual(mpv["last_success"], {"cursor": "retained"})
        self.assertNotIn("previous_state", mpv)
        ffmpeg = current["groups"]["ffmpeg"]
        self.assertEqual(len(ffmpeg["journal_refs"]), 8)
        self.assertNotIn("previous_state", ffmpeg)

    def test_dovi_repository_observation_has_explicit_library_gap(self):
        metadata = {
            "source": "https://api.github.com/repos/quietvoid/dovi_tool/releases",
            "observed_at": "2026-10-24T00:00:00+00:00",
            "versions": ["v1.0.0"],
            "latest_stable": "v1.0.0",
        }
        direct = self.adapter.build_native_coverage(
            self.manifest, releases={"github:quietvoid/dovi_tool": metadata},
        )
        self.assertEqual(direct["groups"]["dovi"]["status"], "unverified")
        self.assertEqual(direct["groups"]["dovi"]["reason"],
                         "existing-github-observer-success-evidence-missing")
        previous = self.adapter.build_native_coverage(self.manifest)
        previous["groups"]["dovi"]["status"] = "observed"
        previous["groups"]["dovi"]["last_success"] = {"cursor": "retained"}
        retained_only = self.adapter.coverage_after_compare(
            self.manifest, previous,
            {"checked_at": "2026-10-24T00:01:00+00:00",
             "releases": {"github:quietvoid/dovi_tool": metadata},
             "registry_errors": [], "history_contractions": [],
             "successful_observations": {}},
        )
        self.assertEqual(retained_only["groups"]["dovi"]["status"], "unverified")
        self.assertEqual(retained_only["groups"]["dovi"]["reason"],
                         "existing-github-observer-success-evidence-missing")
        self.assertEqual(retained_only["groups"]["dovi"]["last_success"], {"cursor": "retained"})
        coverage = self.adapter.coverage_after_compare(
            self.manifest, None,
            {"checked_at": "2026-10-24T00:01:00+00:00",
             "releases": {"github:quietvoid/dovi_tool": metadata},
             "registry_errors": [], "history_contractions": [],
             "successful_observations": {
                 "github:quietvoid/dovi_tool": {
                     "observed_at": metadata["observed_at"],
                     "source": metadata["source"],
                     "kind": "fresh",
                 },
             }},
        )
        dovi = coverage["groups"]["dovi"]
        self.assertEqual(dovi["status"], "observed")
        self.assertEqual(dovi["repository_observation_scope"], "repository-metadata-only")
        self.assertEqual(dovi["underlying_library"]["immutable_source"], "dolby_vision/Cargo.toml")
        self.assertEqual(dovi["underlying_library"]["status"], "UNVERIFIED")
        self.assertIn({"source": "native/dovi/libdovi", "reason": "underlying-library-version-unverified"},
                      coverage["coverage_gaps"])

        malformed_kind = self.adapter.coverage_after_compare(
            self.manifest, None,
            {"checked_at": "2026-10-24T00:01:00+00:00",
             "releases": {"github:quietvoid/dovi_tool": metadata},
             "registry_errors": [], "history_contractions": [],
             "successful_observations": {
                 "github:quietvoid/dovi_tool": {
                     "observed_at": metadata["observed_at"],
                     "source": metadata["source"],
                     "kind": ["fresh"],
                 },
             }},
        )
        self.assertEqual(malformed_kind["groups"]["dovi"]["status"], "unverified")
        self.assertEqual(malformed_kind["groups"]["dovi"]["reason"],
                         "existing-github-observer-success-evidence-invalid")

        malformed_releases = self.adapter.coverage_after_compare(
            self.manifest, None,
            {"checked_at": "2026-10-24T00:01:00+00:00",
             "releases": ["github:quietvoid/dovi_tool"],
             "registry_errors": [], "history_contractions": [],
             "successful_observations": {
                 "github:quietvoid/dovi_tool": {
                     "observed_at": metadata["observed_at"],
                     "source": metadata["source"],
                     "kind": "fresh",
                 },
             }},
        )
        self.assertEqual(malformed_releases["groups"]["dovi"]["status"], "unverified")
        self.assertEqual(malformed_releases["groups"]["dovi"]["reason"],
                         "existing-github-observer-observation-malformed")

    def test_lane_pin_evidence_change_is_separate_source_event(self):
        prior = self.adapter.build_native_coverage(self.manifest)
        changed = json.loads(json.dumps(self.manifest))
        changed["lanes"]["native-17"]["evidence"]["pin_map"] = "A17-replaced"
        current = self.adapter.build_native_coverage(changed)
        changes = self.adapter.detect_source_changes(prior, current)
        self.assertIn("dovi", {item["group"] for item in changes})

    def test_supplemental_and_source_evidence_changes_are_attributed(self):
        prior = self.adapter.build_native_coverage(self.manifest)
        changed = json.loads(json.dumps(self.manifest))
        # Swap the two one-to-one supplemental attributions so the manifest
        # remains topology-complete while both affected groups change.
        changed["supplemental_observations"]["monitor-node"]["upstreams"] = ["python-runtime"]
        changed["supplemental_observations"]["monitor-python"]["upstreams"] = ["node-runtime"]
        changed["source_evidence"]["pin_map"]["sha256"] = "9" * 64
        current = self.adapter.build_native_coverage(changed)
        changes = self.adapter.detect_source_changes(prior, current)
        changed_groups = {item["group"] for item in changes}
        self.assertIn("node-runtime", changed_groups)
        self.assertIn("python-runtime", changed_groups)
        self.assertEqual([item["scope"] for item in changes if item["group"] == "__manifest__"],
                         ["source-evidence"])

    def test_compare_reconciles_mixed_case_prior_and_reuse_with_new_release(self):
        adapter = self.adapter
        source = "https://api.github.com/repos/public/example/releases"
        prior_record = {
            "github_history_schema": 2, "legacy_published_versions": [],
            "repository": "PUBLIC/EXAMPLE", "source": source.replace("public/example", "PUBLIC/EXAMPLE"),
            "versions": ["v1.0.0"], "latest_stable": "v1.0.0",
            "observed_at": "2026-10-24T00:00:00+00:00",
            "observations": {
                "tag:v1.0.0": {"kind": "tag", "version": "v1.0.0", "commit": "a" * 40,
                               "ref_type": "commit", "ref": "a" * 40},
                "release:1": {"kind": "release", "version": "v1.0.0", "id": 1, "revision": "b" * 64},
                "asset:1:10": {"kind": "asset", "version": "v1.0.0", "id": 10, "release_id": 1,
                               "revision": "c" * 64, "digest": "sha256:" + "1" * 64},
            },
        }
        fresh = json.loads(json.dumps(prior_record))
        fresh["repository"] = "public/example"; fresh["source"] = source
        fresh["observed_at"] = "2026-10-24T01:00:00+00:00"
        fresh["observations"]["tag:v1.0.0"]["commit"] = "d" * 40
        fresh["observations"]["tag:v1.0.0"]["ref"] = "d" * 40
        fresh["observations"]["release:1"]["revision"] = "e" * 64
        fresh["observations"]["asset:1:10"]["revision"] = "f" * 64
        fresh["observations"]["asset:1:10"]["digest"] = "sha256:" + "2" * 64
        fresh["versions"].append("v2.0.0"); fresh["latest_stable"] = "v2.0.0"
        fresh["observations"]["tag:v2.0.0"] = {
            "kind": "tag", "version": "v2.0.0", "commit": "c" * 40,
            "ref_type": "commit", "ref": "c" * 40,
        }
        fresh["observations"]["release:2"] = {
            "kind": "release", "version": "v2.0.0", "id": 2, "revision": "d" * 64,
        }
        fresh["observations"]["asset:2:20"] = {
            "kind": "asset", "version": "v2.0.0", "id": 20, "release_id": 2,
            "revision": "e" * 64, "digest": "sha256:" + "3" * 64,
        }
        prior, reused, conflicts = adapter.reconcile_github_state(
            {"releases": {"github:PUBLIC/EXAMPLE": prior_record}},
            {"github:PUBLIC/EXAMPLE": fresh},
        )
        self.assertFalse(conflicts)
        with patch.object(health, "releases") as fetch:
            report = health.compare(
                {"entries": [{"ecosystem": "github", "name": "public/example", "current": "v1.0.0",
                               "kind": "github-action"}], "coverage_gaps": []},
                prior, 1, reuse=reused,
            )
        fetch.assert_not_called()
        self.assertEqual(report["new_releases"][0]["new_versions"], ["v2.0.0"])
        self.assertIn("tag:v1.0.0", report["releases"]["github:public/example"]["observations"])
        self.assertEqual(report["releases"]["github:public/example"]["vortx_identity_aliases"],
                         ["github:PUBLIC/EXAMPLE"])
        self.assertEqual(report["releases"]["github:public/example"]["observed_at"],
                         "2026-10-24T01:00:00+00:00")
        self.assertEqual(report["releases"]["github:public/example"]["vortx_alias_observed_at"],
                         {"github:PUBLIC/EXAMPLE": "2026-10-24T01:00:00+00:00"})
        self.assertGreaterEqual(len(report["releases"]["github:public/example"]["observation_history"]["tag:v1.0.0"]), 2)
        self.assertGreaterEqual(len(report["releases"]["github:public/example"]["observation_history"]["asset:1:10"]), 2)

        with patch.object(health, "releases", return_value=fresh) as fetch:
            fresh_report = health.compare(
                {"entries": [{"ecosystem": "github", "name": "public/example", "current": "v1.0.0",
                               "kind": "github-action"}], "coverage_gaps": []},
                prior, 1,
            )
        fetch.assert_called_once_with("github", "public/example")
        self.assertEqual(fresh_report["releases"]["github:public/example"]["vortx_identity_aliases"],
                         ["github:PUBLIC/EXAMPLE"])
        self.assertEqual(fresh_report["releases"]["github:public/example"]["vortx_alias_observed_at"],
                         {"github:PUBLIC/EXAMPLE": "2026-10-24T00:00:00+00:00"})
        self.assertEqual(fresh_report["releases"]["github:public/example"]["observed_at"],
                         "2026-10-24T01:00:00+00:00")

    def test_compare_blocks_conflicting_aliases_without_query_or_history_selection(self):
        adapter = self.adapter
        base = {"github_history_schema": 2, "legacy_published_versions": [],
                "repository": "public/example", "source": "https://api.github.com/repos/public/example/releases",
                "versions": ["v1.0.0"], "latest_stable": "v1.0.0",
                "observations": {"tag:v1.0.0": {"kind": "tag", "version": "v1.0.0", "commit": "a" * 40,
                                                   "ref_type": "commit", "ref": "a" * 40}}}
        conflict = json.loads(json.dumps(base)); conflict["observations"]["tag:v1.0.0"]["commit"] = "b" * 40
        prior, reused, conflicts = adapter.reconcile_github_state(
            {"releases": {"github:public/example": base, "github:PUBLIC/EXAMPLE": conflict}}, {},
        )
        with patch.object(health, "releases") as fetch:
            report = health.compare(
                {"entries": [{"ecosystem": "github", "name": "public/example", "current": "v1.0.0",
                               "kind": "github-action"}], "coverage_gaps": []},
                prior, 1, reuse=reused, identity_conflicts=conflicts,
            )
        fetch.assert_not_called()
        self.assertEqual(report["registry_errors"], [{"component": "github:public/example", "reason": "IdentityConflict"}])
        self.assertFalse(report["complete"])
        self.assertIn("github:PUBLIC/EXAMPLE", report["releases"])

    def test_malformed_prior_source_is_blocked_without_cursor_loss_or_query(self):
        malformed = {
            "repository": "public/example",
            "source": "https://[invalid",
            "versions": ["v1.0.0"],
            "observations": {"tag:v1.0.0": {"commit": "a" * 40}},
        }
        prior, reused, conflicts = self.adapter.reconcile_github_state(
            {"releases": {"github:public/example": malformed}}, {},
        )
        self.assertEqual(len(conflicts), 1)
        with patch.object(health, "releases") as fetch:
            report = health.compare(
                {"entries": [{"ecosystem": "github", "name": "public/example", "current": "v1.0.0",
                               "kind": "github-action"}], "coverage_gaps": []},
                prior, 1, reuse=reused, identity_conflicts=conflicts,
            )
        fetch.assert_not_called()
        self.assertEqual(report["registry_errors"],
                         [{"component": "github:public/example", "reason": "IdentityConflict"}])
        self.assertEqual(report["releases"]["github:public/example"], malformed)

        for malformed_cursor in (None, ["not", "a", "mapping"]):
            prior, reused, conflicts = self.adapter.reconcile_github_state(
                {"releases": {"github:public/example": malformed_cursor}}, {},
            )
            self.assertEqual(len(conflicts), 1)
            with patch.object(health, "releases") as fetch:
                report = health.compare(
                    {"entries": [{"ecosystem": "github", "name": "public/example", "current": "v1.0.0",
                                   "kind": "github-action"}], "coverage_gaps": []},
                    prior, 1, reuse=reused, identity_conflicts=conflicts,
                )
            fetch.assert_not_called()
            self.assertEqual(report["registry_errors"],
                             [{"component": "github:public/example", "reason": "IdentityConflict"}])
            self.assertEqual(report["releases"]["github:public/example"], malformed_cursor)

    def test_generic_only_refresh_carries_native_ledger_for_both_modes(self):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="native-carry-forward-") as folder:
            folder = Path(folder)
            config = folder / "config.json"
            previous_path = folder / "previous.json"
            config.write_text("{}")
            native = {"schema_version": 1, "groups": {
                "ffmpeg": {"status": "unverified", "last_success": {"cursor": "retained"}},
                "mpv": {"status": "observed", "last_success": {"cursor": "observed"}},
            }}
            previous_path.write_text(json.dumps({"native_monitor": native}))
            for suffix, inventory_only in (("full", False), ("inventory", True)):
                report = folder / f"{suffix}.json"
                argv = ["dependency-health.py", "--config", str(config),
                        "--report", str(report), "--previous", str(previous_path)]
                if inventory_only:
                    argv.append("--inventory-only")
                with patch("sys.argv", argv), patch.object(health, "inventory", return_value={
                        "entries": [], "manifests": [], "coverage_gaps": []}):
                    health.main()
                output = json.loads(report.read_text())
                self.assertEqual(output["native_monitor"], native)
                self.assertFalse(output["complete"])
                self.assertFalse(output["native_complete"])
                self.assertEqual(output["native_monitor_refresh"]["status"], "not-refreshed")
                self.assertEqual(output["native_monitor_refresh"]["unresolved_groups"], ["ffmpeg"])

    def test_main_native_compare_reconciles_report_gap_and_complete_flag(self):
        temporary_root = ROOT / "_build"
        temporary_root.mkdir(exist_ok=True)
        capture = json.loads((ROOT / "scripts/tests/fixtures/native-manifest-capture.json").read_text())
        manifest = NativeDependencyAdapterTests.manifest_from_capture(capture)
        media3_sources = {
            "maven:androidx.media3:media3-exoplayer":
                "https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer/maven-metadata.xml",
            "maven:androidx.media3:media3-exoplayer-hls":
                "https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-hls/maven-metadata.xml",
            "maven:androidx.media3:media3-ui":
                "https://dl.google.com/dl/android/maven2/androidx/media3/media3-ui/maven-metadata.xml",
            "maven:androidx.media3:media3-session":
                "https://dl.google.com/dl/android/maven2/androidx/media3/media3-session/maven-metadata.xml",
        }
        releases = {
            component: {"versions": ["1.0.0"], "latest_stable": "1.0.0",
                        "source": source, "observed_at": "2026-10-24T00:00:00+00:00"}
            for component, source in media3_sources.items()
        }
        successful = {
            component: {"observed_at": metadata["observed_at"], "source": metadata["source"], "kind": "fresh"}
            for component, metadata in releases.items()
        }

        with tempfile.TemporaryDirectory(dir=temporary_root, prefix="native-main-report-") as folder:
            folder = Path(folder)
            config = folder / "config.json"
            manifest_path = folder / "native-manifest.json"
            report = folder / "report.json"
            config.write_text("{}")
            manifest_path.write_text(json.dumps(manifest))

            def fake_compare(data, prior, workers, record, reuse, identity_conflicts=None):
                return {
                    "entries": data["entries"], "manifests": data["manifests"],
                    "coverage_gaps": [
                        {"source": "native/media3", "reason": "parent-registry-compare-timestamp-missing"},
                        {"source": "registry/example", "reason": "registry-unavailable"},
                    ],
                    "releases": releases, "registry_errors": [], "history_contractions": [],
                    "identity_conflicts": [], "successful_observations": successful,
                    "checked_at": "2026-10-24T00:01:00+00:00",
                    "unresolved_entries": 0, "complete": True,
                }

            argv = ["dependency-health.py", "--config", str(config), "--report", str(report),
                    "--native-manifest", str(manifest_path), "--workers", "1"]
            with patch("sys.argv", argv), patch.object(health, "inventory", return_value={
                    "entries": [], "manifests": [], "coverage_gaps": []}), \
                    patch.object(health, "compare", side_effect=fake_compare):
                health.main()
            output = json.loads(report.read_text())
            self.assertFalse(any(item["source"] == "native/media3"
                                 for item in output["coverage_gaps"]))
            self.assertIn({"source": "registry/example", "reason": "registry-unavailable"},
                          output["coverage_gaps"])
            self.assertFalse(output["complete"])

    def _same_run_parent_releases(self):
        releases = {}
        for group, endpoints in self.adapter._PARENT_REGISTRY_IDENTITIES.items():
            for endpoint, component in endpoints.items():
                if component.startswith("cargo:"):
                    source = self.adapter._cargo_index_source(component.split(":", 1)[1])
                else:
                    source = endpoint
                releases[component] = {
                    "versions": ["1.0.0", "1.1.0", "1.1.0-rc01"],
                    "latest_stable": "1.1.0",
                    "source": source,
                    "observed_at": "2026-10-24T00:00:00+00:00",
                }
        return releases

    def _same_run_parent_successful_observations(self, releases=None):
        releases = releases or self._same_run_parent_releases()
        return {
            component: {
                "observed_at": metadata["observed_at"],
                "source": metadata["source"],
                "kind": "fresh",
            }
            for component, metadata in releases.items()
        }

    def test_parent_registry_projects_complete_same_run_generic_observations(self):
        comparison = {
            "checked_at": "2026-10-24T00:01:00+00:00",
            "releases": self._same_run_parent_releases(),
            "registry_errors": [],
            "history_contractions": [],
            "successful_observations": self._same_run_parent_successful_observations(),
        }
        coverage = self.adapter.coverage_after_compare(self.manifest, None, comparison)
        parent_groups = {
            group for group, spec in self.manifest["upstreams"].items()
            if spec["mode"] == "parent-registry"
        }
        self.assertEqual(parent_groups, set(self.adapter._PARENT_REGISTRY_IDENTITIES))
        for group in parent_groups:
            record = coverage["groups"][group]
            self.assertEqual(record["status"], "observed")
            self.assertEqual(record["observation_source"], "same-run-generic-registry-observer")
            self.assertEqual(set(record["registry_reuse_keys"]),
                             set(self.adapter._PARENT_REGISTRY_IDENTITIES[group].values()))
            self.assertEqual(record["observation_checked_at"], comparison["checked_at"])
        media3_sources = {item["component"]: item for item in coverage["groups"]["media3"]["registry_sources"]}
        self.assertEqual(
            media3_sources["maven:androidx.media3:media3-exoplayer"]["manifest_endpoint"],
            "https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer/maven-metadata.xml",
        )
        self.assertEqual(
            media3_sources["maven:androidx.media3:media3-exoplayer"]["observation_source"],
            comparison["releases"]["maven:androidx.media3:media3-exoplayer"]["source"],
        )
        self.assertNotIn("UPSTREAM_METADATA_REUSED", json.dumps(coverage))

    def test_observed_parent_removes_stale_group_gap_but_keeps_subordinate_gap(self):
        previous = self.adapter.build_native_coverage(self.manifest)
        previous["coverage_gaps"].append({
            "source": "native/media3",
            "reason": "adapter-not-implemented-parent-registry-reuse",
        })
        comparison = {
            "checked_at": "2026-10-24T00:01:00+00:00",
            "releases": self._same_run_parent_releases(),
            "registry_errors": [],
            "history_contractions": [],
            "successful_observations": self._same_run_parent_successful_observations(),
        }
        coverage = self.adapter.coverage_after_compare(self.manifest, previous, comparison)
        self.assertFalse(any(item["source"] == "native/media3"
                             for item in coverage["coverage_gaps"]))
        self.assertTrue(any(item["source"] == "native/dovi/libdovi"
                            for item in coverage["coverage_gaps"]))

    def test_main_report_reconciles_precompare_native_gaps_without_hiding_unknowns(self):
        existing = [
            {"source": "native/media3", "reason": "parent-registry-compare-timestamp-missing"},
            {"source": "native/dovi/libdovi", "reason": "underlying-library-version-unverified"},
            {"source": "native/removed-group", "reason": "retained-unknown-group"},
            {"source": "registry/example", "reason": "registry-unavailable"},
        ]
        current = {
            "groups": {
                "media3": {"status": "observed"},
                "dovi": {"status": "observed"},
            },
            "coverage_gaps": [
                {"source": "native/dovi/libdovi", "reason": "underlying-library-version-unverified"},
            ],
        }
        reconciled = self.adapter.reconcile_top_level_coverage_gaps(existing, current)
        pairs = {(item["source"], item["reason"]) for item in reconciled}
        self.assertNotIn(("native/media3", "parent-registry-compare-timestamp-missing"), pairs)
        self.assertIn(("native/dovi/libdovi", "underlying-library-version-unverified"), pairs)
        self.assertIn(("native/removed-group", "retained-unknown-group"), pairs)
        self.assertIn(("registry/example", "registry-unavailable"), pairs)

        pending = self.adapter.reconcile_top_level_coverage_gaps(
            [{"source": "native/mpv", "reason": "existing-github-observer-not-run"}],
            {"groups": {"mpv": {"status": "pending-observation"}}, "coverage_gaps": []},
        )
        self.assertIn({"source": "native/mpv", "reason": "existing-github-observer-not-run"}, pending)
        merged_pending = self.adapter.merge_native_coverage(
            {"groups": {"mpv": {"status": "pending-observation"}},
             "coverage_gaps": [{"source": "native/mpv", "reason": "existing-github-observer-not-run"}]},
            {"groups": {"mpv": {"status": "pending-observation"}}, "coverage_gaps": []},
        )
        self.assertIn({"source": "native/mpv", "reason": "existing-github-observer-not-run"},
                      merged_pending["coverage_gaps"])

    def test_parent_registry_never_promotes_retained_only_or_partial_metadata(self):
        releases = self._same_run_parent_releases()
        direct = self.adapter.build_native_coverage(self.manifest, releases=releases)
        self.assertEqual(direct["groups"]["media3"]["status"], "unverified")
        self.assertEqual(direct["groups"]["media3"]["reason"],
                         "parent-registry-compare-timestamp-missing")
        previous = self.adapter.build_native_coverage(self.manifest)
        previous["groups"]["media3"]["last_success"] = {"cursor": "retained"}
        del releases["maven:androidx.media3:media3-session"]
        comparison = {
            "checked_at": "2026-10-24T00:01:00+00:00",
            "releases": releases,
            "registry_errors": [],
            "history_contractions": [],
            "successful_observations": self._same_run_parent_successful_observations(releases),
        }
        coverage = self.adapter.coverage_after_compare(self.manifest, previous, comparison)
        media3 = coverage["groups"]["media3"]
        self.assertEqual(media3["status"], "unverified")
        self.assertEqual(media3["reason"], "parent-registry-observation-missing")
        self.assertEqual(media3["last_success"], {"cursor": "retained"})
        self.assertNotIn("maven:androidx.media3:media3-session", media3.get("registry_observed_at", {}))

    def test_parent_registry_requires_explicit_compare_success_evidence(self):
        releases = self._same_run_parent_releases()
        comparison = {
            "checked_at": "2026-10-24T00:01:00+00:00",
            "releases": releases,
            "registry_errors": [],
            "history_contractions": [],
        }
        coverage = self.adapter.coverage_after_compare(self.manifest, None, comparison)
        self.assertEqual(coverage["groups"]["media3"]["status"], "unverified")
        self.assertEqual(coverage["groups"]["media3"]["reason"],
                         "parent-registry-success-evidence-missing")

        evidence = self._same_run_parent_successful_observations(releases)
        evidence["maven:androidx.media3:media3-exoplayer"]["observed_at"] = "stale"
        comparison["successful_observations"] = evidence
        coverage = self.adapter.coverage_after_compare(self.manifest, None, comparison)
        self.assertEqual(coverage["groups"]["media3"]["status"], "unverified")
        self.assertEqual(coverage["groups"]["media3"]["reason"],
                         "parent-registry-success-evidence-mismatch")

    def test_parent_registry_failure_contraction_and_source_allowlist_are_unverified(self):
        releases = self._same_run_parent_releases()
        previous = self.adapter.build_native_coverage(self.manifest)
        previous["groups"]["ring"]["last_success"] = {"cursor": "ring-retained"}
        releases["cargo:ring"]["absent_versions"] = ["0.1.0"]
        comparison = {
            "checked_at": "2026-10-24T00:01:00+00:00",
            "releases": releases,
            "registry_errors": [{"component": "cargo:ring", "reason": "ValueError"}],
            "history_contractions": [{"component": "cargo:ring"}],
            "successful_observations": self._same_run_parent_successful_observations(releases),
        }
        coverage = self.adapter.coverage_after_compare(self.manifest, previous, comparison)
        ring = coverage["groups"]["ring"]
        self.assertEqual(ring["status"], "unverified")
        self.assertEqual(ring["reason"], "parent-registry-observation-failed")
        self.assertEqual(ring["last_success"], {"cursor": "ring-retained"})

        contraction = {
            "checked_at": "2026-10-24T00:01:00+00:00",
            "releases": releases,
            "registry_errors": [],
            "history_contractions": [{"component": "cargo:ring", "missing_versions": ["0.1.0"]}],
            "successful_observations": self._same_run_parent_successful_observations(releases),
        }
        contraction_coverage = self.adapter.coverage_after_compare(self.manifest, previous, contraction)
        self.assertEqual(contraction_coverage["groups"]["ring"]["status"], "unverified")
        self.assertEqual(contraction_coverage["groups"]["ring"]["reason"],
                         "parent-registry-observation-incomplete")

        changed = json.loads(json.dumps(self.manifest))
        changed["upstreams"]["ring"]["endpoints"].append("https://crates.io/api/v1/crates/private-ring")
        invalid = self.adapter.build_native_coverage(
            changed, releases=self._same_run_parent_releases(),
            observation_checked_at="2026-10-24T00:01:00+00:00",
        )
        self.assertEqual(invalid["groups"]["ring"]["status"], "unverified")
        self.assertEqual(invalid["groups"]["ring"]["reason"],
                         "parent-registry-source-not-allowlisted")
        self.assertNotIn("private-ring", json.dumps(invalid))

        malformed = self.adapter.coverage_after_compare(
            self.manifest, previous,
            {"checked_at": "2026-10-24T00:01:00+00:00", "releases": None,
             "registry_errors": None, "identity_conflicts": None,
             "history_contractions": None},
        )
        self.assertEqual(malformed["groups"]["media3"]["status"], "unverified")
        self.assertEqual(malformed["groups"]["media3"]["reason"],
                         "parent-registry-observation-not-run")

        malformed_collections = self.adapter.coverage_after_compare(
            self.manifest, previous,
            {"checked_at": "2026-10-24T00:01:00+00:00", "releases": self._same_run_parent_releases(),
             "registry_errors": None, "history_contractions": [],
             "successful_observations": self._same_run_parent_successful_observations()},
        )
        self.assertEqual(malformed_collections["groups"]["media3"]["status"], "unverified")
        self.assertEqual(malformed_collections["groups"]["media3"]["reason"],
                         "parent-registry-compare-collections-malformed")

        for field, value in (("registry_errors", ["unknown failure"]),
                             ("identity_conflicts", [{}]),
                             ("history_contractions", [None]),
                             ("history_contractions", [{"component": ""}])):
            with self.subTest(field=field):
                malformed_item = {
                    "checked_at": "2026-10-24T00:01:00+00:00",
                    "releases": self._same_run_parent_releases(),
                    "registry_errors": [], "identity_conflicts": [], "history_contractions": [],
                    "successful_observations": self._same_run_parent_successful_observations(),
                }
                malformed_item[field] = value
                coverage = self.adapter.coverage_after_compare(self.manifest, previous, malformed_item)
                self.assertEqual(coverage["groups"]["media3"]["reason"],
                                 "parent-registry-compare-collections-malformed")
if __name__ == "__main__":
    unittest.main()
