#!/usr/bin/env python3
"""Read-only dependency inventory/release comparison. Never installs or resolves builds.

Python >=3.11; PyYAML is required only for YAML lockfiles. Reports missing coverage
and registry failures explicitly. Local configuration/report paths are not published.
"""
import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from xml.parsers import expat

LIMIT = 32 * 1024 * 1024
SKIP = {"node_modules", "target", "build", "_build", ".git", ".gradle", "dist", ".next", "source-evidence", "_recovery"}
PACKAGE = re.compile(r"^(?:@[a-z0-9._-]+/)?[a-z0-9._-]+$", re.I)
CARGO_PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
CARGO_PUBLIC_SOURCES = {"registry+https://github.com/rust-lang/crates.io-index", "registry+sparse+https://index.crates.io/", "registry+https://index.crates.io/"}
VERSION = re.compile(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(.*)$")


def stable_key(version):
    match = VERSION.fullmatch(version)
    if not match or (match[4] and not match[4].startswith("+")):
        return None
    return tuple(int(match[x] or 0) for x in (1, 2, 3))


def public_github(value):
    match = re.fullmatch(r"(?:git\+)?https://github.com/([\w.-]+/[\w.-]+?)(?:\.git)?(?:#[^\s]+)?/?", value)
    return match[1].lower() if match else None


def npm_registry_spec(value):
    """Admit registry ranges/tags only, never repository/SSH/path specifications."""
    if not isinstance(value, str): return False
    value = value.strip()
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]*", value): return True
    atom = r"(?:[v=]?\d+|[xX*])(?:\.(?:\d+|[xX*])){0,2}(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"
    token = rf"(?:[~^]|[<>]=?)?\s*{atom}"
    return bool(re.fullmatch(rf"{token}(?:(?:\s+-\s+|\s*\|\|\s*|\s+){token})*", value))


def npm_registry_settings(paths):
    """Unknown applicable registry directives block public fallback; never expose values."""
    settings = {}
    for path in paths:
        if not path.is_file(): continue
        try: lines = path.read_text().splitlines()
        except (OSError, UnicodeError): return {"registry": None}
        for line in lines:
            line = line.strip()
            if not line or line.startswith(("#", ";", "//")): continue
            # npm permits inline comments; only whitespace-delimited markers are removed.
            line = re.split(r"\s+[;#]", line, maxsplit=1)[0].strip()
            match = re.fullmatch(r"((?:@[\w.-]+:)?registry)\s*=\s*(.+)", line, re.I)
            if match:
                key, value = match[1].lower(), match[2].strip()
                if value.startswith(('"', "'")):
                    value = value[1:-1] if len(value) >= 2 and value[-1] == value[0] else ""
                settings[key] = value if re.fullmatch(r"https://[^\s\"']+", value) else None
            elif re.search(r"registry|userconfig|globalconfig", line.split("=", 1)[0], re.I):
                scope = re.match(r"(@[\w.-]+):registry\b", line, re.I)
                settings[scope[1].lower() + ":registry" if scope else "registry"] = None
    return settings


def cargo_manifest_origin_known(root, public_names, name):
    """Only corroborated public identities with no unsupported source overrides qualify."""
    if name not in public_names: return False
    if any(key.upper().startswith(("CARGO_REGISTRIES_", "CARGO_SOURCE_")) or
           key.upper() in {"CARGO_HOME", "CARGO_REGISTRY_DEFAULT", "CARGO_REGISTRY_INDEX"}
           for key in os.environ): return False
    paths = {Path.home() / ".cargo" / filename for filename in ("config", "config.toml")}
    for parent in (root, *root.parents):
        paths.update(parent / ".cargo" / filename for filename in ("config", "config.toml"))
    for path in paths:
        if not path.is_file(): continue
        try: data = tomllib.loads(path.read_text())
        except (OSError, ValueError, UnicodeError): return False
        if any(data.get(key) for key in ("source", "registries", "registry")): return False
    return True


def inventory(config):
    entries, gaps, manifests, repository_states = [], [], [], []
    local_names = set(config.get("private_npm_names", []))
    contexts = []
    for spec in config["repositories"]:
        root, label = Path(spec["path"]), spec["label"]
        try:
            head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            paths = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
            files = sorted(set(x.decode() for x in paths.split(b"\0") if x))
            files = [rel for rel in files if not any(part in SKIP for part in Path(rel).parts[:-1]) and
                     (root / rel).is_file() and not (root / rel).is_symlink()]
            repository_states.append({"label": label, "head": head, "role": spec.get("role", "source")})
        except (OSError, subprocess.CalledProcessError):
            gaps.append({"source": label, "reason": "Repository unavailable"}); continue
        public_cargo = set()
        contexts.append((root, label, files, public_cargo))
        # Discover nested private packages and approved lock identities before any query eligibility.
        for relative in files:
            try:
                source = root / relative
                if source.stat().st_size > LIMIT: continue
                if source.name == "package.json":
                    document = json.loads(source.read_text())
                    if document.get("private") and document.get("name"): local_names.add(document["name"])
                elif source.name == "Cargo.lock":
                    public_cargo.update(item["name"] for item in tomllib.loads(source.read_text()).get("package", [])
                                        if item.get("source") in CARGO_PUBLIC_SOURCES)
            except (OSError, ValueError): pass
    def public_npm(root, source, name, resolved=None):
        if name in local_names or name.startswith(("@vortx/", "@stremiox/")):
            return False
        if resolved is not None:
            url = urllib.parse.urlsplit(resolved)
            return (url.scheme == "https" and url.netloc == "registry.npmjs.org" and
                    not url.query and not url.fragment and
                    urllib.parse.unquote(url.path).startswith("/" + name + "/-/"))
        # Only registry keys are interpreted; credentials are neither expanded nor recorded.
        if any(key.lower() in {"npm_config_registry", "npm_config_userconfig", "npm_config_globalconfig"}
               for key in os.environ): return False
        rc_paths = [Path.home() / ".npmrc", root / ".npmrc"]
        relative = source.parent.relative_to(root)
        for depth in range(1, len(relative.parts) + 1): rc_paths.append(root.joinpath(*relative.parts[:depth]) / ".npmrc")
        settings = npm_registry_settings(rc_paths)
        registry = settings.get("registry", "https://registry.npmjs.org/")
        if name.startswith("@"): registry = settings.get(name.split("/")[0].lower() + ":registry", registry)
        return isinstance(registry, str) and registry.rstrip("/") == "https://registry.npmjs.org"
    def add(eco, name, current, repo, file, kind):
        if eco in ("maven", "plugin") and name not in config.get(
                "public_maven_names" if eco == "maven" else "public_plugin_names", []):
            gaps.append({"source": f"{repo}/{file}", "reason": "Maven/plugin public origin requires explicit corroboration"})
            return
        identity = CARGO_PACKAGE if eco == "cargo" else PACKAGE
        if eco in ("npm", "cargo") and not identity.fullmatch(name):
            gaps.append({"source": f"{repo}/{file}", "reason": "Unsupported registry package identity"})
            return
        entries.append({"ecosystem": eco, "name": name, "current": str(current),
                        "repository": repo, "source": file, "kind": kind})
    for root, label, files, public_cargo in contexts:
        for rel in files:
            path = root / rel
            if any(part in SKIP for part in path.relative_to(root).parts[:-1]) or not path.is_file() or path.is_symlink():
                continue
            name = path.name
            recognized = name in {"package.json", "package-lock.json", "Cargo.lock", "Cargo.toml", "pnpm-lock.yaml", "libs.versions.toml"}
            unsupported = name in {"yarn.lock", "bun.lock", "bun.lockb", "uv.lock", "poetry.lock", "composer.json", "composer.lock", "Gemfile", "Gemfile.lock", "go.mod", "go.sum", "pyproject.toml", "requirements.txt", "Package.resolved", "Package.swift", "Dockerfile", "docker-compose.yml", "gradle.lockfile", "rust-toolchain.toml"}
            workflow = rel.startswith(".github/workflows/") and path.suffix in (".yml", ".yaml")
            if not (recognized or unsupported or workflow):
                continue
            try:
                raw = path.read_bytes()
                if len(raw) > LIMIT: raise ValueError("Manifest exceeds bounded reader")
                manifests.append({"repository": label, "path": rel, "sha256": hashlib.sha256(raw).hexdigest()})
                if unsupported:
                    gaps.append({"source": f"{label}/{rel}", "reason": "Inventory found a lock format requiring an additional adapter"}); continue
                text = raw.decode("utf-8")
                if name == "package.json":
                    data = json.loads(text)
                    for kind in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
                        for dep, version in data.get(kind, {}).items():
                            if str(version).startswith(("workspace:", "file:", "link:")): continue
                            if str(version).startswith("npm:"):
                                target, separator, version = version[4:].rpartition("@")
                                if not separator or not PACKAGE.fullmatch(target):
                                    gaps.append({"source": f"{label}/{rel}", "reason": "Unsupported npm alias needs explicit source tracking"}); continue
                                dep = target
                            if not npm_registry_spec(version):
                                gaps.append({"source": f"{label}/{rel}", "reason": "Non-registry dependency needs explicit source tracking"}); continue
                            if public_npm(root, path, dep): add("npm", dep, version, label, rel, kind)
                            else: gaps.append({"source": f"{label}/{rel}", "reason": "Non-public npm dependency not sent to public registry"})
                    manager = data.get("packageManager", "")
                    if "@" in manager:
                        manager, version = manager.split("@", 1)
                        if public_npm(root, path, manager): add("npm", manager, version.split("+")[0], label, rel, "toolchain")
                elif name == "package-lock.json":
                    data = json.loads(text)
                    if "packages" not in data: raise ValueError("npm lock v1 needs an adapter")
                    for location, item in data["packages"].items():
                        if "node_modules/" not in location or item.get("link"): continue
                        dep = item.get("name", location.rsplit("node_modules/", 1)[-1])
                        if item.get("version") and public_npm(root, path, dep, item.get("resolved")):
                            add("npm", dep, item["version"], label, rel, "resolved-transitive")
                        elif item.get("version"):
                            gaps.append({"source": f"{label}/{rel}", "reason": "Non-public npm lock origin not sent to public registry"})
                elif name == "Cargo.lock":
                    for item in tomllib.loads(text).get("package", []):
                        source = item.get("source", "")
                        if source in CARGO_PUBLIC_SOURCES:
                            add("cargo", item["name"], item["version"], label, rel, "resolved-transitive")
                        elif source:
                            gaps.append({"source": f"{label}/{rel}", "reason": f"Non-crates.io dependency needs explicit source tracking: {item['name']}"})
                elif name == "Cargo.toml":
                    data = tomllib.loads(text)
                    tables = [(k, data.get(k, {})) for k in ("dependencies", "dev-dependencies", "build-dependencies")]
                    tables += [("workspace", data.get("workspace", {}).get("dependencies", {}))]
                    for target in data.get("target", {}).values():
                        tables += [("target", target.get(k, {})) for k in ("dependencies", "dev-dependencies", "build-dependencies")]
                    for kind, table in tables:
                        for dep, value in table.items():
                            if isinstance(value, dict):
                                if any(k in value for k in ("path", "git", "workspace", "registry")): continue
                                dep, value = value.get("package", dep), value.get("version")
                            if value:
                                if cargo_manifest_origin_known(root, public_cargo, dep): add("cargo", dep, value, label, rel, kind)
                                else: gaps.append({"source": f"{label}/{rel}", "reason": "Cargo manifest public registry origin not corroborated"})
                elif name == "pnpm-lock.yaml":
                    import yaml
                    data = yaml.safe_load(text)
                    for key, item in data.get("packages", {}).items():
                        # pnpm v9: scoped/name@version; peers are snapshot suffixes, not versions.
                        dep, sep, version = key.split("(", 1)[0].rpartition("@")
                        if not sep or not dep or not version: raise ValueError("Unsupported pnpm package key")
                        tarball = item.get("resolution", {}).get("tarball")
                        if public_npm(root, path, dep, tarball): add("npm", dep, version, label, rel, "resolved-transitive")
                        else: gaps.append({"source": f"{label}/{rel}", "reason": "Non-public pnpm dependency not sent to public registry"})
                elif name == "libs.versions.toml":
                    data = tomllib.loads(text); versions = data.get("versions", {})
                    for alias, item in data.get("libraries", {}).items():
                        if isinstance(item, str):
                            coordinate, version = item.rsplit(":", 1)
                        else:
                            coordinate = item.get("module") or f"{item['group']}:{item['name']}"
                            version = item.get("version")
                            if isinstance(version, dict): version = versions.get(version.get("ref"))
                        if version:
                            add("maven", coordinate, version, label, rel, "declared-library")
                        else:
                            gaps.append({"source": f"{label}/{rel}", "reason": "BOM-managed version needs resolved runtime graph"})
                            add("maven", coordinate, "BOM-managed/unresolved", label, rel, "unresolved-library")
                    for alias, item in data.get("plugins", {}).items():
                        plugin = item["id"]; version = item.get("version")
                        if isinstance(version, dict): version = versions.get(version.get("ref"))
                        if version: add("plugin", plugin, version, label, rel, "declared-plugin")
                    gaps.append({"source": f"{label}/{rel}", "reason": "Gradle transitive runtime graph not resolved by a source-only scan"})
                elif workflow:
                    for action, pin in re.findall(r"^\s*(?:-\s*)?uses:\s*([\w.-]+/[\w./-]+)@([^\s#]+)", text, re.M):
                        add("github", "/".join(action.split("/")[:2]).lower(), pin, label, rel, "github-action")
            except (ValueError, KeyError, TypeError, ImportError, OSError) as error:
                gaps.append({"source": f"{label}/{rel}", "reason": f"Parse failed: {type(error).__name__}"})
    for item in config.get("components", []):
        add(item["ecosystem"], item["name"], item["current"], item.get("repository", "manual-native"), item["source"], item.get("kind", "manual-pin"))
    for gap in config.get("coverage_gaps", []): gaps.append(gap)
    # Deterministic, no silent duplicate masking of different locked versions/locations.
    entries = [dict(zip(("ecosystem", "name", "current", "repository", "source", "kind"), values)) for values in sorted(set(tuple(e[k] for k in ("ecosystem", "name", "current", "repository", "source", "kind")) for e in entries))]
    return {"repositories": repository_states, "manifests": manifests, "entries": entries,
            "coverage_gaps": sorted(gaps, key=lambda x: (x["source"], x["reason"]))}


GITHUB_PAGES = 20
GITHUB_OBSERVATIONS = 20_000
GITHUB_SHA = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")


class GitHubNoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise ValueError("GitHub source redirects require explicit reconciliation")


class RegistryHTTPSRedirects(urllib.request.HTTPRedirectHandler):
    """Public registries may redirect between HTTPS origins, never downgrade protocols."""
    max_redirections = 5

    def redirect_request(self, request, response, code, message, headers, new_url):
        target = urllib.parse.urlsplit(new_url)
        if (target.scheme != "https" or not target.hostname or target.username or target.password
                or target.port not in (None, 443) or target.fragment):
            raise ValueError("Unsupported registry metadata redirect")
        return super().redirect_request(request, response, code, message, headers, new_url)


def github_repository(name):
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}", name):
        raise ValueError("Invalid public GitHub repository identity")
    if name.split("/")[1] in {".", ".."}: raise ValueError("Invalid public GitHub repository identity")
    return name.lower()


def github_endpoint(url):
    """Only constructed same-origin repository GETs; GH_HOST cannot redirect credentials."""
    parsed = urllib.parse.urlsplit(url)
    match = re.fullmatch(r"/repos/([^/]+/[^/]+)(.*)", parsed.path)
    if parsed.scheme != "https" or parsed.netloc != "api.github.com" or parsed.fragment or not match:
        raise ValueError("Unsupported GitHub metadata origin")
    github_repository(match[1])
    suffix = match[2]
    if suffix in {"", "/git/matching-refs/tags/"}:
        if parsed.query: raise ValueError("Unexpected GitHub query")
    elif suffix in {"/tags", "/releases"} or re.fullmatch(r"/releases/[1-9][0-9]*/assets", suffix):
        pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if (len(pairs) != 2 or pairs[0] != ("per_page", "100") or pairs[1][0] != "page"
                or not re.fullmatch(r"[1-9][0-9]*", pairs[1][1]) or int(pairs[1][1]) > GITHUB_PAGES):
            raise ValueError("Unexpected GitHub pagination")
    else: raise ValueError("Unsupported GitHub metadata endpoint")
    return parsed.path.lstrip("/") + ("?" + parsed.query if parsed.query else "")


def github_text(value):
    if not isinstance(value, str) or not value or len(value) > 4096 or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Malformed GitHub text metadata")
    return value


def github_id(value):
    if type(value) is not int or value <= 0: raise ValueError("Malformed GitHub immutable identity")
    return value


def github_stamp(value):
    github_text(value)
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value):
        raise ValueError("Malformed GitHub timestamp")
    dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return value


def github_fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def github_optional_text_hash(value):
    if value is not None and not isinstance(value, str): raise ValueError("Malformed GitHub optional text")
    return None if value is None else github_fingerprint(value)


def github_asset_urls(row, name, asset_id):
    """Validate URL metadata, never follow asset/download URLs or retain unsafe origins."""
    api = urllib.parse.urlsplit(github_text(row["url"]))
    if (api.scheme != "https" or api.netloc != "api.github.com" or api.query or api.fragment
            or api.path.lower() != f"/repos/{name}/releases/assets/{asset_id}"):
        raise ValueError("Unexpected release asset metadata origin")
    download = urllib.parse.urlsplit(github_text(row["browser_download_url"]))
    prefix = "/" + name + "/releases/download/"
    decoded = urllib.parse.unquote(download.path)
    if "\\" in decoded or any(part in {".", ".."} for part in decoded.split("/")):
        raise ValueError("Unexpected release asset path")
    if (download.scheme != "https" or download.netloc != "github.com" or download.query or download.fragment
            or not download.path.lower().startswith(prefix) or len(download.path) <= len(prefix)
            or "/" not in download.path[len(prefix):]):
        raise ValueError("Unexpected release asset download origin")


def github_list(base, identity):
    rows, seen = [], set()
    for page in range(1, GITHUB_PAGES + 1):
        batch = json.loads(get(f"{base}?per_page=100&page={page}", github=True))
        if not isinstance(batch, list) or len(batch) > 100: raise ValueError("Malformed GitHub list")
        for row in batch:
            if not isinstance(row, dict): raise ValueError("Malformed GitHub list row")
            key = github_id(row[identity]) if identity == "id" else github_text(row[identity])
            if key in seen: raise ValueError("Overlapping GitHub pagination")
            seen.add(key); rows.append(row)
        if len(batch) < 100: return rows
    raise ValueError("GitHub pagination exceeds coverage bound")


def validate_github_observations(data):
    if type(data.get("github_history_schema")) is not int or data["github_history_schema"] != 2:
        raise ValueError("GitHub observation schema requires fresh enrollment")
    github_repository(data["repository"])
    if data["source"] != f"https://api.github.com/repos/{data['repository']}/releases":
        raise ValueError("Unexpected retained GitHub source")
    if (not isinstance(data["versions"], list)
            or any(not isinstance(version, str) or github_text(version) != version for version in data["versions"])
            or data["versions"] != sorted(set(data["versions"]))):
        raise ValueError("Malformed GitHub version history")
    legacy = data["legacy_published_versions"]
    if (not isinstance(legacy, list) or any(not isinstance(version, str) or github_text(version) != version for version in legacy)
            or legacy != sorted(set(legacy)) or not set(legacy) <= set(data["versions"])):
        raise ValueError("Malformed retained GitHub publication provenance")
    if data["latest_stable"] is not None and (data["latest_stable"] not in data["versions"]
                                              or stable_key(data["latest_stable"]) is None):
        raise ValueError("Malformed GitHub stable observation")
    observations = data["observations"]
    if not isinstance(observations, dict) or len(observations) > GITHUB_OBSERVATIONS:
        raise ValueError("GitHub observations exceed coverage bound")
    for identity, record in observations.items():
        if not isinstance(record, dict) or record.get("version") not in data["versions"]:
            raise ValueError("Malformed GitHub observation")
        kind = record.get("kind")
        if kind == "tag":
            if (set(record) != {"kind", "version", "commit", "ref_type", "ref"}
                    or identity != "tag:" + record["version"] or record["ref_type"] not in {"tag", "commit"}
                    or not GITHUB_SHA.fullmatch(record["commit"]) or not GITHUB_SHA.fullmatch(record["ref"])
                    or (record["ref_type"] == "commit" and record["ref"] != record["commit"])):
                raise ValueError("Malformed GitHub tag binding")
        elif kind == "release":
            if (set(record) != {"kind", "version", "id", "revision"}
                    or identity != f"release:{github_id(record['id'])}"):
                raise ValueError("Malformed GitHub release binding")
        elif kind == "asset":
            if (set(record) != {"kind", "version", "id", "release_id", "revision", "digest"}
                    or identity != f"asset:{github_id(record['release_id'])}:{github_id(record['id'])}"
                    or (record["digest"] is not None and not re.fullmatch(r"sha256:[0-9a-f]{64}", record["digest"]))):
                raise ValueError("Malformed GitHub asset binding")
        else: raise ValueError("Unknown GitHub observation")
        if kind != "tag" and not re.fullmatch(r"[0-9a-f]{64}", record["revision"]):
            raise ValueError("Malformed GitHub metadata fingerprint")
    return data


def github_releases(name):
    name = github_repository(name)
    base = f"https://api.github.com/repos/{name}"
    repository = json.loads(get(base))  # Anonymous visibility check before authenticated public history.
    if (not isinstance(repository, dict) or repository.get("private") is not False
            or repository.get("visibility") != "public" or repository.get("full_name", "").lower() != name):
        raise ValueError("GitHub public source identity is unconfirmed")
    tags = github_list(base + "/tags", "name")
    refs = json.loads(get(base + "/git/matching-refs/tags/", github=True))
    if not isinstance(refs, list) or len(refs) > GITHUB_PAGES * 100:
        raise ValueError("GitHub tag-ref coverage exceeds bound")
    by_ref = {}
    for row in refs:
        if not isinstance(row, dict) or not github_text(row["ref"]).startswith("refs/tags/"):
            raise ValueError("Malformed GitHub tag reference")
        tag = row["ref"][len("refs/tags/"):]
        if tag in by_ref: raise ValueError("Duplicate GitHub tag reference")
        by_ref[tag] = row["object"]
    if set(by_ref) != {row["name"] for row in tags}:
        raise ValueError("GitHub tags and ref coverage differ")
    observations, versions, stable = {}, set(), []
    for row in tags:
        tag, commit, ref = row["name"], row["commit"]["sha"], by_ref[row["name"]]
        versions.add(tag)
        observations["tag:" + tag] = {"kind":"tag", "version":tag, "commit":commit,
                                      "ref_type":ref["type"], "ref":ref["sha"]}
    for row in github_list(base + "/releases", "id"):
        if type(row["draft"]) is not bool: raise ValueError("Malformed GitHub draft flag")
        if row["draft"]: continue  # Authenticated draft visibility is not public release enrollment.
        tag, release_id = github_text(row["tag_name"]), github_id(row["id"])
        if type(row["prerelease"]) is not bool: raise ValueError("Malformed GitHub prerelease flag")
        if row.get("immutable") is not None and type(row["immutable"]) is not bool:
            raise ValueError("Malformed GitHub immutable flag")
        versions.add(tag)
        if not row["prerelease"] and stable_key(tag) is not None: stable.append(tag)
        metadata = {key: github_stamp(row[key]) for key in ("created_at", "published_at")}
        metadata["updated_at"] = github_stamp(row["updated_at"]) if row.get("updated_at") is not None else None
        metadata.update({"prerelease":row["prerelease"], "immutable":row.get("immutable"),
                         "name":github_optional_text_hash(row.get("name")),
                         "body":github_optional_text_hash(row.get("body"))})
        observations[f"release:{release_id}"] = {"kind":"release", "version":tag, "id":release_id,
                                                "revision":github_fingerprint(metadata)}
        for asset in github_list(base + f"/releases/{release_id}/assets", "id"):
            asset_id = github_id(asset["id"])
            github_asset_urls(asset, name, asset_id)
            digest = asset.get("digest")
            if digest is not None and (not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
                raise ValueError("Malformed GitHub asset digest")
            if type(asset["size"]) is not int or asset["size"] < 0: raise ValueError("Malformed GitHub asset size")
            metadata = {key: github_stamp(asset[key]) for key in ("created_at", "updated_at")}
            metadata.update({key:github_text(asset[key]) for key in ("name", "state", "content_type")})
            metadata.update({"size":asset["size"], "digest":digest,
                             "label":github_optional_text_hash(asset.get("label")),
                             "url":asset["url"], "download_url":asset["browser_download_url"]})
            observations[f"asset:{release_id}:{asset_id}"] = {"kind":"asset", "version":tag, "id":asset_id,
                "release_id":release_id, "revision":github_fingerprint(metadata), "digest":digest}
            if len(observations) > GITHUB_OBSERVATIONS: raise ValueError("GitHub observation coverage exceeds bound")
    data = {"versions":sorted(versions), "latest_stable":max(stable, key=lambda v: (stable_key(v), v)) if stable else None,
            "source":base + "/releases", "repository":name, "github_history_schema":2, "legacy_published_versions":[], "observations":observations}
    return validate_github_observations(data)


def merge_github_observations(previous, data):
    """Retain known identities/revisions through deletion; absence is never an all-clear."""
    validate_github_observations(data)
    if (previous.get("source") != data["source"]
            or previous.get("repository", data["repository"]) != data["repository"]):
        raise ValueError("Retained GitHub repository identity changed")
    if ("github_history_schema" in previous
            and (type(previous["github_history_schema"]) is not int or previous["github_history_schema"] != 2)):
        raise ValueError("Unknown retained GitHub schema")
    if "github_history_schema" not in previous:
        if "legacy_published_versions" in previous: raise ValueError("Unversioned publication provenance")
        if (not isinstance(previous.get("versions"), list) or not previous["versions"]
                or any(not isinstance(version, str) or github_text(version) != version for version in previous["versions"])
                or previous["versions"] != sorted(set(previous["versions"]))):
            raise ValueError("Malformed legacy GitHub cursor")
        latest = data["latest_stable"]
        prior_latest = previous.get("latest_stable")
        if prior_latest is not None:
            if prior_latest not in previous["versions"]: raise ValueError("Malformed legacy GitHub head")
            if stable_key(prior_latest) is not None and (latest is None or stable_key(prior_latest) > stable_key(latest)):
                latest = prior_latest
        return {**data, "latest_stable":latest, "versions":sorted(set(previous["versions"]) | set(data["versions"])),
                "legacy_published_versions":list(previous["versions"]),
                "observation_history":{key:{github_fingerprint(value):value} for key,value in data["observations"].items()},
                "absent_observations":[], "absent_versions":sorted(set(previous["versions"]) - set(data["versions"]))}, [], True
    validate_github_observations(previous)
    if previous["repository"] != data["repository"]: raise ValueError("GitHub repository identity changed")
    old, current = previous["observations"], data["observations"]
    absent = set(previous.get("absent_observations", []))
    if not absent <= old.keys(): raise ValueError("Malformed GitHub retained presence")
    history = {key:dict(values) for key,values in previous.get("observation_history", {}).items()}
    for key, value in old.items():
        history.setdefault(key, {}).setdefault(github_fingerprint(value), value)
    for key, records in history.items():
        if key not in old or not records: raise ValueError("Malformed GitHub retained history")
        for fingerprint, value in records.items():
            if github_fingerprint(value) != fingerprint: raise ValueError("Malformed GitHub retained history")
            validate_github_observations({**previous, "observations":{key:value}})
    changes = []
    def changed(key, kind, before=None, after=None):
        changes.append({"identity":key, "change":kind, "version":(after or before)["version"],
                        "before":github_fingerprint(before) if before else None,
                        "after":github_fingerprint(after) if after else None})
    for key, value in current.items():
        if key not in old: changed(key, "added", after=value)
        else:
            if key in absent: changed(key, "reappeared", old[key], value)
            if value != old[key]: changed(key, "changed", old[key], value)
        history.setdefault(key, {})[github_fingerprint(value)] = value
    for key in old.keys() - current.keys() - absent: changed(key, "disappeared", before=old[key])
    latest = data["latest_stable"]
    if previous["latest_stable"] is not None and (latest is None or stable_key(previous["latest_stable"]) > stable_key(latest)):
        latest = previous["latest_stable"]
    return {**data, "versions":sorted(set(previous["versions"]) | set(data["versions"])), "latest_stable":latest,
            "observations":{**old, **current}, "observation_history":history,
            "legacy_published_versions":list(previous["legacy_published_versions"]),
            "absent_observations":sorted(old.keys() - current.keys()),
            "absent_versions":sorted(set(previous["versions"]) - set(data["versions"]))}, changes, False


def get(url, github=False):
    if not url.startswith("https://"): raise ValueError("HTTPS required")
    headers = {"User-Agent": "VortX-dependency-health/1.0", "Accept": "application/json"}
    if github:
        # CLI handles authentication; never extract or echo credentials. This is a read-only GET.
        result = subprocess.run(["gh", "api", "--hostname", "github.com", "--method", "GET", github_endpoint(url)], capture_output=True, timeout=45)
        if result.returncode: raise ValueError("GitHub metadata read failed")
        raw = result.stdout
    else:
        if url.startswith("https://registry.npmjs.org/"):
            headers["Accept"] = "application/vnd.npm.install-v1+json"
        request = urllib.request.Request(url, headers=headers)
        if url.startswith("https://api.github.com/"):
            github_endpoint(url)
            # No CLI token/config and no redirects on the public-visibility prerequisite.
            with urllib.request.build_opener(GitHubNoRedirect()).open(request, timeout=30) as response:
                raw = response.read(LIMIT + 1)
        else:
            with urllib.request.build_opener(RegistryHTTPSRedirects()).open(request, timeout=30) as response:
                raw = response.read(LIMIT + 1)
    if len(raw) > LIMIT: raise ValueError("Registry response exceeds bound")
    return raw


def maven_versions(raw):
    """Stream the existing version path without DTD/entity expansion or an unbounded tree."""
    if len(raw) > LIMIT: raise ValueError("Maven metadata exceeds bound")
    parser = expat.ParserCreate(namespace_separator="}")
    parser.buffer_text = True
    path, versions, text = [], [], None
    elements, capture = 0, False

    def reject_declaration(*unused):
        raise ValueError("Unsupported Maven metadata declarations")

    def version_path():
        return len(path) == 4 and path[1:] == ["versioning", "versions", "version"]

    def start(name, attributes):
        nonlocal elements, text, capture
        path.append(name)
        elements += 1
        if len(path) > 64 or elements > 200_000:
            raise ValueError("Maven metadata exceeds structure bound")
        if version_path():
            text, capture = [], True
        elif text is not None:
            capture = False  # Match ElementTree node.text: exclude child text and tails.

    def characters(value):
        if capture and version_path(): text.append(value)

    def end(name):
        nonlocal text, capture
        if version_path():
            value = "".join(text)
            if value: versions.append(value)
            text, capture = None, False
        path.pop()

    parser.StartDoctypeDeclHandler = reject_declaration
    parser.EntityDeclHandler = reject_declaration
    parser.ExternalEntityRefHandler = reject_declaration
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    parser.StartElementHandler, parser.EndElementHandler = start, end
    parser.CharacterDataHandler = characters
    try:
        parser.Parse(raw, True)
    except expat.ExpatError as error:
        raise ValueError("Invalid Maven metadata XML") from error
    return versions


def releases(ecosystem, name):
    quote = urllib.parse.quote
    if ecosystem == "npm":
        source = f"https://registry.npmjs.org/{quote(name, safe='')}"
        data = json.loads(get(source)); versions = list(data["versions"])
        latest = data.get("dist-tags", {}).get("latest")
        if latest is not None and stable_key(latest) is None:
            stable = [version for version in versions if stable_key(version) is not None]
            latest = max(stable, key=stable_key) if stable else None
    elif ecosystem == "cargo":
        if not CARGO_PACKAGE.fullmatch(name): raise ValueError("Invalid Cargo package identity")
        name = name.lower()
        part = "1" if len(name) == 1 else "2" if len(name) == 2 else f"3/{name[0]}" if len(name) == 3 else f"{name[:2]}/{name[2:4]}"
        source = f"https://index.crates.io/{part}/{name}"
        rows = [json.loads(line) for line in get(source).splitlines() if line]
        versions = [row["vers"] for row in rows]
        stable = [row["vers"] for row in rows if not row.get("yanked") and stable_key(row["vers"]) is not None]
        latest = max(stable, key=stable_key) if stable else None
    elif ecosystem in ("maven", "plugin"):
        group, artifact = name.split(":", 1) if ecosystem == "maven" else (name, f"{name}.gradle.plugin")
        path = f"{group.replace('.', '/')}/{artifact}/maven-metadata.xml"
        bases = ["https://dl.google.com/dl/android/maven2/", "https://repo.maven.apache.org/maven2/"] if group.startswith(("androidx.", "com.android.", "com.google.android.")) else ["https://repo.maven.apache.org/maven2/", "https://plugins.gradle.org/m2/"]
        if ecosystem == "plugin": bases = ["https://plugins.gradle.org/m2/"]
        if name in ("com.android.application", "com.android.library"):
            path = "com/android/tools/build/gradle/maven-metadata.xml"; bases = ["https://dl.google.com/dl/android/maven2/"]
        failure = None
        for base in bases:
            source = base + path
            try: versions = maven_versions(get(source)); break
            except urllib.error.HTTPError as error:
                if error.code != 404: raise
                failure = error
        else: raise ValueError("Maven metadata unavailable") from failure
        stable = [version for version in versions if stable_key(version) is not None]
        latest = max(stable, key=stable_key) if stable else None
    elif ecosystem == "github":
        return github_releases(name)
    else:
        raise ValueError("Component requires a release-source adapter")
    if not versions: raise ValueError("No release versions returned")
    if latest is not None and latest not in versions: raise ValueError("Latest release absent from version list")
    return {"versions": sorted(set(versions)), "latest_stable": latest, "source": source}


def compare(inventory_result, prior, workers, checkpoint=None, reuse=None):
    identities = sorted(set((entry["ecosystem"], entry["name"]) for entry in inventory_result["entries"]))
    # A temporarily missing source is not explicit component retirement. Preserve its cursor.
    result, errors, changes, enrolled, observations = dict(prior.get("releases", {})), [], [], [], []
    def fetch(identity):
        ecosystem, name = identity; key = f"{ecosystem}:{name}"
        try:
            metadata = dict(reuse[key]) if reuse and key in reuse else releases(ecosystem, name)
            if ecosystem == "github":
                validate_github_observations(metadata)
                if metadata["legacy_published_versions"]: raise ValueError("Fresh observation contains retained provenance")
                if metadata["repository"] != github_repository(name): raise ValueError("Unexpected GitHub repository")
            metadata = {**metadata, "observed_at":metadata.get("observed_at", dt.datetime.now(dt.timezone.utc).isoformat())}
            return key, metadata, None
        except Exception as error: return key, None, type(error).__name__
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for key, data, error in pool.map(fetch, identities):
            fetched = data
            previous = prior.get("releases", {}).get(key)
            history_enrolled, events = False, []
            if not error and previous is not None and key.startswith("github:"):
                try: data, events, history_enrolled = merge_github_observations(previous, data)
                except Exception as failure: error = type(failure).__name__
            if checkpoint is not None: checkpoint(key, fetched if not error else None, error)
            if error:
                errors.append({"component": key, "reason": error})
                # No partial pages, malformed metadata, or failed refresh may erase the cursor.
                if previous is not None: result[key] = previous
                continue
            if previous is not None:
                if history_enrolled:
                    enrolled.append({"component":key, "latest_stable":data["latest_stable"], "source":data["source"],
                                     "kind":"github-history-baseline"})
                if key.startswith("github:"):
                    # A tag is an observation, not proof a release was published. Legacy
                    # cursors contain release-only versions; rich cursors retain release IDs.
                    published = {record["version"] for record in fetched["observations"].values()
                                 if record["kind"] == "release"}
                    known_published = (set(previous["versions"]) if history_enrolled else
                                       set(previous["legacy_published_versions"]) |
                                       {record["version"] for record in previous["observations"].values()
                                        if record["kind"] == "release"})
                    new = sorted(published - known_published)
                else:
                    new = sorted(set(data["versions"]) - set(previous["versions"]))
                if new: changes.append({"component": key, "new_versions": new, "source": data["source"]})
                observations.extend({"component":key, **event} for event in events)
                data = {**data, "versions": sorted(set(previous["versions"]) | set(data["versions"]))}
            elif prior:
                enrolled.append({"component": key, "latest_stable": data["latest_stable"], "source": data["source"]})
            result[key] = data
    contractions = [{"component":key, "missing_observations":metadata.get("absent_observations", []),
                     "missing_versions":metadata.get("absent_versions", [])}
                    for key,metadata in sorted(result.items()) if metadata.get("absent_observations") or metadata.get("absent_versions")]
    for entry in inventory_result["entries"]:
        key = f"{entry['ecosystem']}:{entry['name']}"; metadata = result.get(key, {})
        entry["latest_stable"] = metadata.get("latest_stable")
        declared = entry.get("kind") in {"dependencies", "devDependencies", "optionalDependencies",
                                             "peerDependencies", "build-dependencies", "workspace", "target"}
        constraint = declared and (entry["ecosystem"] == "cargo" or (
            entry["ecosystem"] == "npm" and not re.fullmatch(
                r"v?\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?", entry["current"])))
        current = None if constraint else stable_key(entry["current"])
        latest = stable_key(metadata.get("latest_stable") or "")
        entry["status"] = "unverified" if key in {e["component"] for e in errors} or not metadata or metadata.get("absent_observations") or metadata.get("absent_versions") else "latest-comparison-needs-resolution"
        if entry["status"] != "unverified" and current is not None and latest is not None:
            entry["status"] = "outdated" if current < latest else "current-or-newer"
        elif entry["status"] != "unverified" and not constraint and entry["current"].lstrip("v") == (metadata.get("latest_stable") or "").lstrip("v"):
            entry["status"] = "current"
    unresolved = sum(entry["status"] in {"unverified", "latest-comparison-needs-resolution"}
                     for entry in inventory_result["entries"])
    return {**inventory_result, "checked_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "releases": result, "registry_errors": errors, "new_releases": changes, "newly_tracked": enrolled,
            "baseline": not bool(prior), "unresolved_entries": unresolved,
            "github_observation_changes": observations, "history_contractions": contractions,
            "complete": not errors and not contractions and not inventory_result["coverage_gaps"] and unresolved == 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--inventory-only", action="store_true")
    parser.add_argument("--journal", type=Path, help="New append-only per-component evidence; never overwrites prior evidence")
    parser.add_argument("--reuse-journal", type=Path, help="Resume only successful observations less than two hours old; not for normal daily refresh")
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=4)
    args = parser.parse_args()
    if args.report.resolve() in {args.config.resolve(), args.previous.resolve() if args.previous else None}:
        parser.error("Report must be a new artifact, not configuration or prior evidence")
    if args.report.exists(): parser.error("Refusing to overwrite an existing report")
    if args.journal and args.journal.exists(): parser.error("Refusing to overwrite an existing journal")
    reused = {}
    if args.reuse_journal:
        now = dt.datetime.now(dt.timezone.utc)
        with args.reuse_journal.open() as source:
            for line in source:
                record = json.loads(line); metadata = record.get("metadata")
                if record.get("error") is not None or not isinstance(metadata, dict): continue
                stamp = metadata.get("observed_at", record["checked_at"])
                age = (now - dt.datetime.fromisoformat(stamp)).total_seconds()
                if not 0 <= age <= 7200: continue
                if not isinstance(metadata.get("versions"), list) or not all(isinstance(v, str) for v in metadata["versions"]):
                    parser.error("Malformed retained release observation")
                metadata = dict(metadata); metadata["observed_at"] = stamp
                reused[record["component"]] = metadata
    data = inventory(json.loads(args.config.read_text()))
    data["monitor_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    data["config_sha256"] = hashlib.sha256(args.config.read_bytes()).hexdigest()
    if not args.inventory_only:
        journal = args.journal.open("x") if args.journal else None
        completed = 0
        def record(key, metadata, error):
            nonlocal completed
            completed += 1
            if journal:
                journal.write(json.dumps({"component":key,"metadata":metadata,"error":error,
                                          "checked_at":dt.datetime.now(dt.timezone.utc).isoformat()}) + "\n")
                journal.flush()
            if completed % 100 == 0: print(f"Checked {completed} distinct registry components", flush=True)
        try:
            data = compare(data, json.loads(args.previous.read_text()) if args.previous else {}, args.workers, record, reused)
        finally:
            if journal: journal.close()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("x") as output: json.dump(data, output, indent=2); output.write("\n")
    print(json.dumps({"entries": len(data["entries"]), "manifests": len(data["manifests"]),
                      "components": len({(e["ecosystem"], e["name"]) for e in data["entries"]}),
                      "coverage_gaps": len(data["coverage_gaps"]), "registry_errors": len(data.get("registry_errors", [])),
                      "new_release_components": len(data.get("new_releases", [])), "complete": data.get("complete", False)}))


if __name__ == "__main__":
    main()
