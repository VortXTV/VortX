#!/usr/bin/env python3
"""Generate the AltStore source from immutable GitHub release metadata.

The protected release workflow uses the Node implementation in ``release-feed.mjs`` because it
also performs the remote checks and rollback. This script remains a useful operator backfill,
but follows the same contract: exact release URLs, byte sizes, and SHA-256 digests are required;
an asset with incomplete metadata is skipped rather than emitted with guessed values.
"""

from __future__ import annotations

import json
import re
import subprocess
import base64
from pathlib import Path

REPO = "VortXTV/VortX"
ICON = "https://raw.githubusercontent.com/VortXTV/VortX/main/docs/logo.png"
OUT = Path(__file__).resolve().parent.parent / "altstore" / "source.json"
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?$")


def gh_json(*args: str):
    result = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def recent_releases() -> list[dict]:
    releases = gh_json(
        "release",
        "list",
        "--repo",
        REPO,
        "--limit",
        "16",
        "--json",
        "tagName,name,publishedAt,isPrerelease",
    )
    return [release for release in (releases or []) if TAG_RE.fullmatch(release.get("tagName", ""))]


def release_detail(tag: str) -> dict | None:
    return gh_json(
        "release",
        "view",
        "--repo",
        REPO,
        tag,
        "--json",
        "tagName,name,publishedAt,body,assets,isPrerelease",
    )


def tag_build(tag: str) -> str | None:
    result = subprocess.run(
        ["gh", "api", f"repos/{REPO}/contents/app/project.yml?ref={tag}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    try:
        content = base64.b64decode(json.loads(result.stdout)["content"]).decode("utf-8")
    except (KeyError, ValueError, UnicodeDecodeError):
        return None
    match = re.search(r'CURRENT_PROJECT_VERSION:\s*"([0-9]+)"', content)
    return match.group(1) if match else None


def asset_by_name(assets: list[dict], name: str) -> dict | None:
    return next((asset for asset in assets if asset.get("name") == name), None)


def digest(asset: dict) -> str | None:
    value = str(asset.get("digest") or "").removeprefix("sha256:").lower()
    return value if re.fullmatch(r"[0-9a-f]{64}", value) else None


def release_asset_url(tag: str, name: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{tag}/{name}"


def notes(body: str | None, name: str, tag: str) -> str:
    source = (body or "").split("## Install", 1)[0].strip()
    source = re.sub(r"[\u2012\u2013\u2014\u2015\u2212]", "-", source)
    source = re.sub(r"\s+", " ", source).strip()
    return (source[:600].rstrip() + ("..." if len(source) > 600 else "")) or f"{name or tag}. One-tap update over any earlier build, nothing resets."


def version_from_tag(tag: str) -> str:
    return tag.removeprefix("v").split("-", 1)[0]


def make_app(name: str, bundle: str, subtitle: str, description: str, min_os: str, entries: list[dict]) -> dict:
    return {
        "name": name,
        "bundleIdentifier": bundle,
        "developerName": "Mamaclapper",
        "subtitle": subtitle,
        "localizedDescription": description,
        "iconURL": ICON,
        "tintColor": "C8A24B",
        "category": "entertainment",
        "screenshotURLs": [],
        "versions": entries,
    }


def main() -> None:
    versions: list[dict] = []
    tv_versions: list[dict] = []
    for listed in recent_releases():
        tag = listed["tagName"]
        release = release_detail(tag)
        if not release:
            continue
        assets = release.get("assets") or []
        ios = asset_by_name(assets, f"VortX-iOS-{tag}-ci.ipa")
        tvos = asset_by_name(assets, f"VortX-tvOS-{tag}-ci.ipa")
        if (
            not ios
            or not tvos
            or not digest(ios)
            or not digest(tvos)
            or int(ios.get("size") or 0) <= 0
            or int(tvos.get("size") or 0) <= 0
        ):
            continue
        version = version_from_tag(tag)
        description = notes(release.get("body"), release.get("name") or tag, tag)
        build = tag_build(tag)
        if not build:
            continue
        common = {
            "version": version,
            "buildVersion": build,
            "date": (release.get("publishedAt") or "")[:10],
            "localizedDescription": description,
            "minOSVersion": "16.0",
        }
        versions.append({**common, "downloadURL": release_asset_url(tag, ios["name"]), "size": ios["size"], "sha256": digest(ios)})
        tv_versions.append({**common, "downloadURL": release_asset_url(tag, tvos["name"]), "size": tvos["size"], "sha256": digest(tvos), "minOSVersion": "18.0"})

    versions = versions[:8]
    tv_versions = tv_versions[:8]
    source = {
        "name": "VortX",
        "identifier": "tv.vortx.altstore",
        "subtitle": "Native streaming app for Apple devices.",
        "iconURL": ICON,
        "website": "https://vortx.tv",
        "tintColor": "C8A24B",
        "apps": [
            make_app("VortX", "com.stremiox.app.native", "Stream movies and shows on Apple devices.", "One-tap updates for VortX on Apple devices.", "16.0", versions),
            make_app("VortX (Apple TV)", "com.stremiox.tv", "Stream movies and shows on Apple TV.", "One-tap updates for VortX on Apple TV.", "18.0", tv_versions),
        ],
        "news": [],
    }
    OUT.write_text(json.dumps(source, indent=2) + "\n")
    print(f"wrote {OUT} with {len(versions)} verified releases")


if __name__ == "__main__":
    main()
