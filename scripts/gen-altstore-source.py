#!/usr/bin/env python3
"""Generate altstore/source.json (AltStore / SideStore source) from the GitHub releases.

Reads the recent VortXTV/VortX releases via `gh`, picks each release's iOS .ipa asset,
and emits a source manifest with one app and a versions[] list (newest first) so a
sideloaded VortX gets one-tap updates. Re-run after publishing a new release.

    python3 scripts/gen-altstore-source.py
"""
import json
import re
import subprocess
from pathlib import Path

REPO = "VortXTV/VortX"
TAGS = ["v0.3.8", "v0.3.7", "v0.3.6", "v0.3.5", "v0.3.4", "v0.3.3"]
ICON = "https://raw.githubusercontent.com/VortXTV/VortX/main/docs/logo.png"
OUT = Path(__file__).resolve().parent.parent / "altstore" / "source.json"


def gh_release(tag: str):
    out = subprocess.run(
        ["gh", "release", "view", tag, "--repo", REPO,
         "--json", "tagName,name,publishedAt,body,assets,isPrerelease"],
        capture_output=True, text=True,
    )
    return json.loads(out.stdout) if out.returncode == 0 else None


def ios_ipa(assets):
    for a in assets or []:
        n = a.get("name", "").lower()
        if n.endswith(".ipa") and "ios" in n and "tvos" not in n:
            return a
    return None


def short_notes(body: str, version: str) -> str:
    if not body:
        return f"VortX {version}."
    cut = re.split(r"##+\s*Install", body)[0].strip()
    return (cut[:600].rstrip() + ("…" if len(cut) > 600 else "")) or f"VortX {version}."


def main() -> None:
    versions = []
    for tag in TAGS:
        rel = gh_release(tag)
        if not rel:
            continue
        asset = ios_ipa(rel.get("assets"))
        if not asset:
            continue
        versions.append({
            "version": tag.lstrip("v"),
            "date": (rel.get("publishedAt") or "")[:10],
            "localizedDescription": short_notes(rel.get("body"), tag.lstrip("v")),
            "downloadURL": asset["url"],
            "size": asset.get("size", 0),
            "minOSVersion": "16.0",
        })

    source = {
        "name": "VortX",
        "identifier": "tv.vortx.altstore",
        "subtitle": "Native streaming app for Apple, on stremio-core + libmpv.",
        "iconURL": ICON,
        "website": "https://vortx.tv",
        "tintColor": "C8A24B",
        "apps": [{
            "name": "VortX",
            "bundleIdentifier": "com.stremiox.app.native",
            "developerName": "Mamaclapper",
            "subtitle": "Stream movies and shows on iPhone, iPad, Apple TV, and Mac.",
            "localizedDescription": (
                "VortX is a native, open-source streaming app for Apple devices, built on the "
                "official stremio-core engine and the libmpv player. Multi-profile (free), HDR and "
                "Dolby Vision tone-mapping, skip intro/outro, stream ranking, in-app add-ons, in-app "
                "debrid keys, and more. Sideload-friendly: this source delivers one-tap updates so you "
                "never re-download an IPA by hand."
            ),
            "iconURL": ICON,
            "tintColor": "C8A24B",
            "category": "entertainment",
            "screenshotURLs": [],
            "versions": versions,
        }],
        "news": [],
    }

    OUT.write_text(json.dumps(source, indent=2) + "\n")
    print(f"wrote {OUT} with {len(versions)} versions: " + ", ".join(v["version"] for v in versions))


if __name__ == "__main__":
    main()
