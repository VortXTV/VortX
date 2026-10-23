#!/usr/bin/env python3
"""Render EVERY component in a retained dependency-health report, without truncation."""
import argparse
from collections import defaultdict
import html
import json
from pathlib import Path
import re


def cell(value):
    text = html.escape(str(value), quote=False).replace("\n", " ").replace("\r", " ")
    return re.sub(r"([\\`*_{}\[\]()|!#])", r"\\\1", text)


def render(data):
    groups = defaultdict(list)
    for entry in data["entries"]:
        groups[(entry["ecosystem"], entry["name"])].append(entry)
    lines = ["# Complete recorded dependency comparison", "",
             f"Checked: {cell(data.get('checked_at', 'source inventory only'))}", "",
             f"{len(groups)} distinct ecosystem/package identities; {len(data['entries'])} declaration/lock/location records.", "",
             f"Complete: {bool(data.get('complete'))}; unresolved records: {data.get('unresolved_entries', 'not evaluated')}; coverage gaps: {len(data['coverage_gaps'])}; registry failures: {len(data.get('registry_errors', []))}.", "",
             "This is a source inventory, NOT a claim of installed or signed binary contents. Canonical, candidate, vendored and WIP contexts may differ. Declared ranges are not installed versions. No component row is intentionally omitted.", "",
             "## Every recorded component", "",
             "| Ecosystem | Component | Recorded values (kinds retained) | Latest stable | Result(s) | Owning source contexts |",
             "| --- | --- | --- | --- | --- | --- |"]
    for (ecosystem, name), entries in sorted(groups.items()):
        versions = sorted({f"{e['current']} [{e['kind']}]" for e in entries})
        statuses = sorted({e.get("status", "not checked") for e in entries})
        owners = sorted({e["repository"] for e in entries})
        latest = sorted({e["latest_stable"] for e in entries if e.get("latest_stable")})
        lines.append("| " + " | ".join(cell(v) for v in (ecosystem, name, "; ".join(versions), "; ".join(latest) or "UNVERIFIED", "; ".join(statuses), "; ".join(owners))) + " |")
    lines += ["", "## Every source location and recorded result", "",
              "The following records retain the exact mapping hidden by an identity-level summary. Different contexts are not silently merged into a shipping version.", "",
              "| Ecosystem | Component | Context | Source | Kind | Recorded value | Latest stable | Result |",
              "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for entry in data["entries"]:
        values = [entry["ecosystem"], entry["name"], entry["repository"], entry["source"], entry["kind"],
                  entry["current"], entry.get("latest_stable") or "UNVERIFIED", entry.get("status", "not checked")]
        lines.append("| " + " | ".join(cell(value) for value in values) + " |")
    lines += ["", "## Every newly observed release", ""]
    for release in data.get("new_releases", []):
        lines.append(f"- {cell(release['component'])}: {', '.join(cell(v) for v in release['new_versions'])}. Source: {cell(release['source'])}")
    if not data.get("new_releases"):
        lines.append("Initial baseline, or no new versions compared with the retained cursor; this does not mean all current versions are latest.")
    lines += ["", "## Every GitHub metadata observation change", ""]
    for event in data.get("github_observation_changes", []):
        lines.append(f"- {cell(event['component'])}: {cell(event['change'])} {cell(event['identity'])}; version {cell(event['version'])}; before {cell(event.get('before'))}; after {cell(event.get('after'))}.")
    if not data.get("github_observation_changes"): lines.append("None compared with the retained metadata cursor.")
    lines += ["", "## History enrollment (not newly released versions)", ""]
    for entry in data.get("newly_tracked", []):
        lines.append(f"- {cell(entry['component'])}: {cell(entry.get('kind', 'component-baseline'))}; source {cell(entry['source'])}.")
    if not data.get("newly_tracked"): lines.append("None recorded.")
    lines += ["", "## Retained GitHub history contractions", ""]
    for entry in data.get("history_contractions", []):
        lines.append(f"- {cell(entry['component'])}: missing identities {', '.join(cell(v) for v in entry['missing_observations']) or 'none'}; missing versions {', '.join(cell(v) for v in entry['missing_versions']) or 'none'}. Historical values remain retained; this component is unverified.")
    if not data.get("history_contractions"): lines.append("None recorded.")
    lines += ["", "## All registry failures", ""]
    for error in data.get("registry_errors", []):
        lines.append(f"- {cell(error['component'])}: {cell(error['reason'])}")
    if not data.get("registry_errors"): lines.append("None recorded.")
    lines += ["", "## All coverage gaps", ""]
    for gap in data["coverage_gaps"]:
        lines.append(f"- {cell(gap['source'])}: {cell(gap['reason'])}")
    lines += ["", "Native/player/system components are additionally recorded in the operator's native inventory. This registry report does not silently declare those manual or OS-owned components covered.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists(): parser.error("Refusing to overwrite retained report")
    text = render(json.loads(args.report.read_text()))
    with args.output.open("x") as output: output.write(text)
    print(f"Rendered all components to {args.output}")


if __name__ == "__main__": main()
