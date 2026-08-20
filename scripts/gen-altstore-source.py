#!/usr/bin/env python3
"""Rebuild the Apple install source from verified release metadata.

This is an operator backfill, not the release write path. Every selected release must carry
complete iOS and tvOS metadata. A failed lookup or malformed record aborts before the existing
source is changed.
"""

from __future__ import annotations

import base64
import copy
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

REPO = "VortXTV/VortX"
OUT = Path(__file__).resolve().parent.parent / "altstore" / "source.json"
SOURCE_HISTORY_LIMIT = 8
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)


class MetadataError(RuntimeError):
    """A release record was unavailable or failed the feed contract."""


def gh_json(*args: str):
    result = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or f"gh exited {result.returncode}"
        raise MetadataError(f"metadata command failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise MetadataError(f"metadata command returned invalid JSON: {error}") from error


def recent_releases() -> list[dict]:
    records = gh_json(
        "release",
        "list",
        "--repo",
        REPO,
        "--limit",
        str(SOURCE_HISTORY_LIMIT * 2),
        "--json",
        "tagName,name,publishedAt,isPrerelease",
    )
    if not isinstance(records, list):
        raise MetadataError("release list was not an array")
    candidates = []
    for listed in records:
        tag = listed.get("tagName")
        if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
            continue
        detail = release_detail(tag)
        detail["build"] = int(tag_build(tag))
        candidates.append(detail)
    candidates.sort(key=lambda release: release["build"], reverse=True)
    builds = [release["build"] for release in candidates]
    if len(builds) != len(set(builds)):
        raise MetadataError(f"release metadata contains duplicate numeric builds: {builds}")
    if not candidates:
        raise MetadataError("no strict release tags were returned")
    return candidates[:SOURCE_HISTORY_LIMIT]


def release_detail(tag: str) -> dict:
    record = gh_json(
        "release",
        "view",
        "--repo",
        REPO,
        tag,
        "--json",
        "tagName,name,publishedAt,body,assets,isPrerelease,isDraft",
    )
    if not isinstance(record, dict) or record.get("tagName") != tag:
        raise MetadataError(f"release detail identity mismatch for {tag}")
    if record.get("isDraft") is True:
        raise MetadataError(f"release {tag} is still a draft")
    return record


def tag_build(tag: str) -> str:
    result = gh_json("api", f"repos/{REPO}/contents/app/project.yml?ref={tag}")
    try:
        content = base64.b64decode(result["content"]).decode("utf-8")
    except (KeyError, ValueError, UnicodeDecodeError, TypeError) as error:
        raise MetadataError(f"project metadata for {tag} could not be decoded") from error
    matches = re.findall(r'CURRENT_PROJECT_VERSION:\s*"([0-9]+)"', content)
    if len(matches) != 6:
        raise MetadataError(f"project metadata for {tag} has {len(matches)} build values (need six)")
    if len(set(matches)) != 1:
        raise MetadataError(f"project metadata for {tag} has inconsistent build values: {matches}")
    return matches[0]


def asset_by_name(assets: list[dict], name: str) -> dict:
    matches = [asset for asset in assets if asset.get("name") == name]
    if len(matches) != 1:
        raise MetadataError(f"release asset {name} is missing or duplicated")
    asset = matches[0]
    if asset.get("state") != "uploaded":
        raise MetadataError(f"release asset {name} is not uploaded")
    return asset


def digest(asset: dict, name: str) -> str:
    value = str(asset.get("digest") or "").removeprefix("sha256:").lower()
    if not SHA_RE.fullmatch(value):
        raise MetadataError(f"release asset {name} has no trusted SHA-256 digest")
    return value


def asset_size(asset: dict, name: str) -> int:
    value = asset.get("size")
    if not isinstance(value, int) or value <= 0:
        raise MetadataError(f"release asset {name} has no positive byte size")
    return value


def release_asset_url(tag: str, name: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{tag}/{name}"


def notes(body: str | None, name: str, tag: str) -> str:
    source = (body or "").split("## Install", 1)[0].strip()
    source = re.sub(r"[\u2012\u2013\u2014\u2015\u2212]", "-", source)
    source = re.sub(r"\s+", " ", source).strip()
    return (source[:600].rstrip() + ("..." if len(source) > 600 else "")) or f"{name or tag}. One-tap update over any earlier build, nothing resets."


def version_from_tag(tag: str) -> str:
    return tag.removeprefix("v").split("-", 1)[0]


def validate_existing_source(source: dict) -> None:
    if not isinstance(source, dict) or not isinstance(source.get("apps"), list):
        raise MetadataError("existing AltStore source has no apps[] array")
    bundles = {app.get("bundleIdentifier") for app in source["apps"] if isinstance(app, dict)}
    required = {"com.stremiox.app.native", "com.stremiox.tv"}
    if not required.issubset(bundles):
        raise MetadataError("existing AltStore source is missing a required Apple app")


def current_top_build(source: dict) -> int:
    builds = []
    for bundle in ("com.stremiox.app.native", "com.stremiox.tv"):
        app = next(app for app in source["apps"] if app.get("bundleIdentifier") == bundle)
        versions = app.get("versions")
        if not isinstance(versions, list) or not versions or not isinstance(versions[0], dict):
            raise MetadataError(f"existing source has no current version for {bundle}")
        try:
            build = int(versions[0]["buildVersion"])
        except (KeyError, TypeError, ValueError) as error:
            raise MetadataError(f"existing source has a non-numeric current build for {bundle}") from error
        if build <= 0:
            raise MetadataError(f"existing source has a non-positive current build for {bundle}")
        builds.append(build)
    if len(set(builds)) != 1:
        raise MetadataError(f"existing source Apple tops disagree: {builds}")
    return builds[0]


def make_entry(release: dict, asset: dict, min_os: str, note: str) -> dict:
    tag = release["tagName"]
    name = asset["name"]
    return {
        "version": version_from_tag(tag),
        "buildVersion": str(release["build"]),
        "date": (release.get("publishedAt") or "")[:10],
        "localizedDescription": note,
        "downloadURL": release_asset_url(tag, name),
        "size": asset_size(asset, name),
        "sha256": digest(asset, name),
        "minOSVersion": min_os,
    }


def build_source(existing: dict, releases: list[dict]) -> dict:
    source = copy.deepcopy(existing)
    ios_entries = []
    tvos_entries = []
    for release in releases:
        tag = release["tagName"]
        assets = release.get("assets")
        if not isinstance(assets, list):
            raise MetadataError(f"release {tag} has no assets array")
        ios_name = f"VortX-iOS-{tag}-ci.ipa"
        tvos_name = f"VortX-tvOS-{tag}-ci.ipa"
        ios = asset_by_name(assets, ios_name)
        tvos = asset_by_name(assets, tvos_name)
        description = notes(release.get("body"), release.get("name") or tag, tag)
        ios_entries.append(make_entry(release, ios, "16.0", description))
        tvos_entries.append(make_entry(release, tvos, "18.0", description))
    for app, entries in (
        (next(app for app in source["apps"] if app.get("bundleIdentifier") == "com.stremiox.app.native"), ios_entries),
        (next(app for app in source["apps"] if app.get("bundleIdentifier") == "com.stremiox.tv"), tvos_entries),
    ):
        app["versions"] = entries
    return source


def atomic_write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    except Exception:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    if not OUT.exists():
        raise MetadataError(f"existing source does not exist: {OUT}")
    try:
        existing = json.loads(OUT.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MetadataError(f"existing source could not be read: {error}") from error
    validate_existing_source(existing)
    previous_build = current_top_build(existing)
    releases = recent_releases()
    by_build = {}
    for release in releases:
        build = release.get("build")
        tag = release.get("tagName")
        if not isinstance(build, int) or not isinstance(tag, str):
            raise MetadataError("backfill candidate lacks immutable build/tag identity")
        if build in by_build and by_build[build] != tag:
            raise MetadataError(f"backfill candidates bind build {build} to different tags: {by_build[build]}, {tag}")
        by_build[build] = tag
    newest_build = releases[0]["build"]
    if newest_build < previous_build:
        raise MetadataError(f"backfill build {newest_build} is older than existing top build {previous_build}")
    rebuilt = build_source(existing, releases)
    rebuilt_top = current_top_build(rebuilt)
    if rebuilt_top != newest_build:
        raise MetadataError(f"rebuilt source top {rebuilt_top} does not match newest release {newest_build}")
    atomic_write(OUT, rebuilt)
    print(f"wrote {OUT} with {len(releases)} verified releases through build {newest_build}")


if __name__ == "__main__":
    try:
        main()
    except MetadataError as error:
        raise SystemExit(f"gen-altstore-source: {error}") from error
