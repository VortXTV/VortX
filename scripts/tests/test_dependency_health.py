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



if __name__ == "__main__":
    unittest.main()
