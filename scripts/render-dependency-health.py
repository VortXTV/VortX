#!/usr/bin/env python3
"""Render EVERY component in a retained dependency-health report, without truncation."""
import argparse
from collections import defaultdict
import html
import json
from pathlib import Path
import re


_PUBLIC_REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$")
_GITHUB_KEY = re.compile(r"^github:[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$", re.I)
_DIGEST = re.compile(r"^[0-9a-f]{64}$", re.I)
_PUBLIC_MAPPING_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+&(),:/-]{0,159}$")
_MAPPING_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def cell(value):
    text = html.escape(str(value), quote=False).replace("\n", " ").replace("\r", " ")
    return re.sub(r"([\\`*_{}\[\]()|!#])", r"\\\1", text)


def _safe_strings(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, (list, tuple)):
        return sorted({item for item in value if isinstance(item, str)})
    return []


def _safe_repository(value):
    return value if isinstance(value, str) and _PUBLIC_REPOSITORY.fullmatch(value) else "redacted"


def _safe_github_key(value):
    return value if isinstance(value, str) and _GITHUB_KEY.fullmatch(value) else "redacted"


def _safe_digest(value):
    return value if isinstance(value, str) and _DIGEST.fullmatch(value) else "redacted"


def _safe_mapping_value(value):
    if not isinstance(value, str):
        return "redacted"
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        return "redacted"
    candidate = value.strip()
    path_like = (
        not candidate
        or candidate.startswith(("/", "\\", "~"))
        or re.match(r"^[A-Za-z]:[\\/]", candidate)
        or _MAPPING_SCHEME.match(candidate)
    )
    if path_like or not _PUBLIC_MAPPING_LABEL.fullmatch(candidate):
        return "redacted"
    return candidate[:160]


def _native_group_rows(native):
    groups = native.get("groups") if isinstance(native, dict) else None
    if not isinstance(groups, dict):
        return []
    rows = []
    for name, record in sorted(groups.items(), key=lambda item: str(item[0])):
        if not isinstance(name, str):
            continue
        if not isinstance(record, dict):
            record = {}
            status = "unverified"
            reason = "malformed native record"
        else:
            status = record.get("status") if isinstance(record.get("status"), str) else "not evaluated"
            reason = record.get("reason") if isinstance(record.get("reason"), str) else ""
        lane_values = []
        for lane in _safe_strings(record.get("lanes")):
            lane_values.append(_safe_mapping_value(lane))
        if isinstance(record.get("lanes"), list):
            for lane in record["lanes"]:
                if isinstance(lane, dict) and isinstance(lane.get("lane"), str):
                    lane_values.append(_safe_mapping_value(lane["lane"]))
        lane_mappings = record.get("lane_mappings")
        if isinstance(lane_mappings, list):
            for mapping in lane_mappings:
                if not isinstance(mapping, dict) or not isinstance(mapping.get("lane"), str):
                    continue
                detail = _safe_mapping_value(mapping["lane"])
                if isinstance(mapping.get("row"), int):
                    detail += f" row {mapping['row']}"
                component = _safe_mapping_value(mapping.get("component"))
                pin_map = _safe_mapping_value(mapping.get("pin_map"))
                detail += f" component {component} pin {pin_map}"
                lane_values.append(detail)
        lane_values = sorted(set(lane_values))
        supplemental = record.get("supplemental_observations", record.get("supplemental", []))
        supplemental_values = [_safe_mapping_value(value) for value in _safe_strings(supplemental)]
        if isinstance(supplemental, list):
            for item in supplemental:
                if isinstance(item, dict) and isinstance(item.get("observation"), str):
                    supplemental_values.append(_safe_mapping_value(item["observation"]))
        supplemental_mappings = record.get("supplemental_mappings")
        if isinstance(supplemental_mappings, list):
            for mapping in supplemental_mappings:
                if not isinstance(mapping, dict) or not isinstance(mapping.get("observation"), str):
                    continue
                observation_name = _safe_mapping_value(mapping["observation"])
                component = _safe_mapping_value(mapping.get("component"))
                supplemental_values.append(f"{observation_name} ({component})")
        observation = []
        for key in ("repository", "observation_key"):
            if isinstance(record.get(key), str):
                observation.append(record[key])
        rows.append({
            "group": name,
            "mode": record.get("mode") if isinstance(record.get("mode"), str) else "UNVERIFIED",
            "status": status,
            "reason": reason or "none recorded",
            "lanes": ", ".join(sorted(set(lane_values))) or "none recorded",
            "observation": "; ".join(
                _safe_repository(value) if not value.startswith("github:") else _safe_github_key(value)
                for value in observation
            ) or "none recorded",
            "source": record.get("observation_source") if isinstance(record.get("observation_source"), str) else "none recorded",
            "supplemental": ", ".join(sorted(set(supplemental_values))) or "none recorded",
            "underlying_library": record.get("underlying_library") if isinstance(record.get("underlying_library"), dict) else None,
            "repository_scope": record.get("repository_observation_scope") if isinstance(record.get("repository_observation_scope"), str) else None,
        })
    return rows


def _native_event_lines(native):
    events = native.get("source_changes") if isinstance(native, dict) else None
    if not isinstance(events, list):
        return ["None recorded."]
    lines = []
    for event in events:
        if not isinstance(event, dict) or not isinstance(event.get("group"), str):
            continue
        scope = event.get("scope") if isinstance(event.get("scope"), str) else "group-source-attribution"
        before = _safe_digest(event.get("before"))
        after = _safe_digest(event.get("after"))
        lines.append(f"- {cell(event['group'])}: {cell(scope)} changed from {cell(before)} to {cell(after)}; this is source attribution, not a release notification.")
    return lines or ["None recorded."]


def _identity_conflict_lines(data, native):
    conflicts = data.get("identity_conflicts") if isinstance(data, dict) else None
    if not isinstance(conflicts, list) and isinstance(native, dict):
        conflicts = native.get("identity_conflicts")
    if not isinstance(conflicts, list):
        conflicts = []
    lines = []
    for conflict in conflicts:
        if not isinstance(conflict, dict) or not isinstance(conflict.get("component"), str):
            continue
        aliases = ", ".join(_safe_github_key(value) for value in _safe_strings(conflict.get("keys"))) or "not disclosed"
        scope = conflict.get("scope") if conflict.get("scope") in {"prior", "reuse", "component"} else "component"
        reason = conflict.get("reason") if conflict.get("reason") in {"conflicting-github-identity-history"} else "identity conflict"
        component = _safe_github_key(conflict["component"])
        # Deliberately omit detail/raw cursor fields; reports remain safe to publish.
        lines.append(f"- {cell(component)}: {cell(scope)}; aliases {cell(aliases)}; {cell(reason)}. Query blocked.")
    return lines or ["None recorded."]


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
    native = data.get("native_monitor")
    lines += ["", "## Native, player and system coverage", ""]
    if not isinstance(native, dict):
        lines.append("No native monitor ledger was recorded; native coverage is not evaluated.")
    else:
        refresh = data.get("native_monitor_refresh")
        if not isinstance(refresh, dict):
            refresh = native.get("refresh_state")
        if isinstance(refresh, dict):
            refresh_status = refresh.get("status") if isinstance(refresh.get("status"), str) else "not evaluated"
            fresh = refresh.get("fresh") if isinstance(refresh.get("fresh"), bool) else "not recorded"
            reason = refresh.get("reason") if isinstance(refresh.get("reason"), str) else "not recorded"
            unresolved = refresh.get("unresolved_groups")
            gap_count = refresh.get("coverage_gap_count")
            lines.append(f"Native refresh state: status {cell(refresh_status)}; fresh {cell(fresh)}; reason {cell(reason)}; unresolved groups {cell(unresolved)}; coverage gaps {cell(gap_count)}.")
            if refresh_status == "not-refreshed" and fresh is False:
                lines.append("This is a retained native ledger only: native sources were NOT REFRESHED in this run.")
        else:
            lines.append("Native refresh state: no refresh marker supplied; do not infer freshness from retained rows.")
        rows = _native_group_rows(native)
        lines.append(f"{len(rows)} native upstream groups recorded; rows are not truncated and are not a shipping-binary claim.")
        lines += ["", "| Group | Mode | Status | Reason | Inventory lanes | Observation mapping | Observer source | Supplemental mappings |", "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        for row in rows:
            lines.append("| " + " | ".join(cell(row[field]) for field in ("group", "mode", "status", "reason", "lanes", "observation", "source", "supplemental")) + " |")
        if not rows:
            lines.append("No native upstream groups were recorded.")
        dovi = next((row for row in rows if row["group"] == "dovi"), None)
        if dovi and dovi["underlying_library"]:
            library = dovi["underlying_library"]
            library_status = library.get("status") if isinstance(library.get("status"), str) else "UNVERIFIED"
            immutable_source = library.get("immutable_source") if isinstance(library.get("immutable_source"), str) else "not recorded"
            version_field = library.get("version_field") if isinstance(library.get("version_field"), str) else "not recorded"
            library_reason = library.get("reason") if isinstance(library.get("reason"), str) else "separate library observation required"
            lines += ["", "### Dolby Vision repository/library boundary", "",
                      f"- Repository surface: {cell(dovi['repository_scope'] or 'repository-metadata-only')}; this does not certify libdovi.",
                      f"- Underlying libdovi 3.x: {cell(library_status)} at {cell(immutable_source)}, field {cell(version_field)}; {cell(library_reason)}."]
        lines += ["", "### Native coverage gaps (not release updates)", ""]
        native_gaps = native.get("coverage_gaps")
        if isinstance(native_gaps, list):
            rendered_gaps = [
                f"- {cell(gap.get('source'))}: {cell(gap.get('reason'))}"
                for gap in native_gaps
                if isinstance(gap, dict) and isinstance(gap.get("source"), str)
            ]
            lines.extend(rendered_gaps or ["None recorded."])
        else:
            lines.append("Native coverage-gap metadata was not supplied.")
        lines += ["", "### Native source-attribution events (not release updates)", ""]
        lines.extend(_native_event_lines(native))
    lines += ["", "### Identity conflicts (sanitized; blocked queries)", ""]
    lines.extend(_identity_conflict_lines(data, native))
    lines += ["", "Native/player/system components do not silently become covered or current merely because a generic registry row exists. Retained cursors, credentials and raw source state are intentionally not printed.", ""]
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
