#!/usr/bin/env python3
"""Read-only adapter for the VortX native dependency manifest.

This module deliberately does not fetch anything.  It turns the reviewed native
operator manifest into the generic monitor's existing GitHub identities and a
complete, honest coverage ledger.  A caller can pass the returned identities to
the existing GitHub tag/release/asset observer; no GitHub implementation is
duplicated here.

The manifest describes source and candidate pins, not shipped binaries.  The
adapter therefore never reports a native component as current merely because a
public upstream release exists.  Non-GitHub lanes stay explicitly UNVERIFIED
until their own adapter and retained readback have been reviewed.
"""

from __future__ import annotations

from copy import deepcopy
from hashlib import sha256
import json
from pathlib import Path
import re
from typing import Any, Iterable, Mapping
from urllib.parse import parse_qsl, urlsplit


EXPECTED_COUNTS = {
    "original_inventory_lanes": 63,
    "supplemental_runtime_observations": 4,
    "unique_upstream_sources": 69,
    "omitted_original_rows": 0,
}
GITHUB_MODES = {"github-tags+releases"}
SUPPORTED_MODES = GITHUB_MODES | {
    "official-archive/feed",
    "parent-registry",
    "rolling-commit",
    "internal",
}
_REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$")
_LANE = re.compile(r"^native-(?:0[1-9]|[1-5][0-9]|6[0-3])$")
_MAX_NATIVE_JOURNAL_REFS = 8
_MAX_NATIVE_JOURNAL_REF_LENGTH = 256
_GITHUB_KEY_PREFIX = "github:"
_SOURCE_EVIDENCE_HASH_KEYS = ("inventory", "pin_map", "original_readme", "central_config_snapshot")
_DOVI_SCOPE = {
    "repository_surface": "quietvoid/dovi_tool CLI 2.x tags/releases",
    "underlying_component": "libdovi 3.x",
    "immutable_source": "dolby_vision/Cargo.toml",
    "version_field": "[package].version",
    "status": "UNVERIFIED",
    "reason": "Repository tags/releases identify the CLI only; the libdovi version requires a separate immutable-file observation.",
}
_SAFE_MAPPING_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+&(),:/-]{0,159}$")
_MAPPING_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")

# These are the only parent-registry identities this adapter is allowed to
# borrow from the generic monitor.  The keys are the exact public endpoints in
# the reviewed native manifest; the values are the exact generic compare
# identities produced by dependency-health.py.  Keeping this table explicit
# prevents an endpoint or package-name typo from silently becoming a fresh
# native observation.
_PARENT_REGISTRY_IDENTITIES = {
    "media3": {
        "https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer/maven-metadata.xml":
            "maven:androidx.media3:media3-exoplayer",
        "https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-hls/maven-metadata.xml":
            "maven:androidx.media3:media3-exoplayer-hls",
        "https://dl.google.com/dl/android/maven2/androidx/media3/media3-ui/maven-metadata.xml":
            "maven:androidx.media3:media3-ui",
        "https://dl.google.com/dl/android/maven2/androidx/media3/media3-session/maven-metadata.xml":
            "maven:androidx.media3:media3-session",
    },
    "agp": {
        "https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml":
            "plugin:com.android.application",
    },
    "aws-lc-rust": {
        "https://crates.io/api/v1/crates/aws-lc-rs": "cargo:aws-lc-rs",
        "https://crates.io/api/v1/crates/aws-lc-sys": "cargo:aws-lc-sys",
    },
    "rquickjs": {
        "https://crates.io/api/v1/crates/rquickjs": "cargo:rquickjs",
        "https://crates.io/api/v1/crates/rquickjs-sys": "cargo:rquickjs-sys",
    },
    "ring": {
        "https://crates.io/api/v1/crates/ring": "cargo:ring",
    },
    "rust-build-helpers": {
        "https://crates.io/api/v1/crates/cc": "cargo:cc",
        "https://crates.io/api/v1/crates/cmake": "cargo:cmake",
    },
    "pyyaml-runtime": {
        "https://pypi.org/pypi/PyYAML/json": "pypi:PyYAML",
    },
}


class NativeManifestError(ValueError):
    """Raised when the operator manifest cannot be safely mapped."""


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def manifest_sha256(manifest: Mapping[str, Any]) -> str:
    """Return a stable digest without exposing local paths or private inputs."""
    return sha256(_canonical(manifest)).hexdigest()


def load_manifest(path: str | Path) -> dict[str, Any]:
    """Load and validate one manifest; invalid input fails before any query."""
    source = Path(path)
    try:
        value = json.loads(source.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NativeManifestError(f"Unable to read native manifest: {type(error).__name__}") from error
    return validate_manifest(value)


def _public_https(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = urlsplit(value)
        return (parsed.scheme == "https" and bool(parsed.hostname) and
                parsed.username is None and parsed.password is None and
                parsed.port in (None, 443) and not parsed.fragment)
    except ValueError:
        return False


def _github_endpoint(value: Any) -> dict[str, str] | None:
    """Parse only the exact public API form consumed by dependency-health.py."""
    if not _public_https(value):
        return None
    parsed = urlsplit(value)
    if parsed.hostname != "api.github.com":
        return None
    parts = parsed.path.split("/")
    if len(parts) != 5 or parts[1] != "repos" or parts[4] not in {"releases", "tags"}:
        return None
    repository = f"{parts[2]}/{parts[3]}".lower()
    if not _REPOSITORY.fullmatch(repository):
        return None
    if parse_qsl(parsed.query, keep_blank_values=True) != [("per_page", "100"), ("page", "{page}")]:
        return None
    return {"repository": repository, "kind": parts[4], "url": value}


def _canonical_github_key(value: Any) -> str | None:
    """Canonicalize only a valid GitHub repository observation key.

    Generic component identities are intentionally left untouched.  A malformed
    ``github:`` key returns ``None`` so reconciliation can preserve it and report
    an explicit conflict instead of silently changing an unvalidated identity.
    """
    if not isinstance(value, str) or not value.startswith(_GITHUB_KEY_PREFIX):
        return None
    repository = value[len(_GITHUB_KEY_PREFIX):]
    if not _REPOSITORY.fullmatch(repository) or repository.split("/")[1] in {".", ".."}:
        return None
    return _GITHUB_KEY_PREFIX + repository.lower()


def _github_release_source(repository: str) -> str:
    return f"https://api.github.com/repos/{repository}/releases"


def _source_repository(value: Any) -> str | None:
    """Read the exact public GitHub release-source identity from a cursor."""
    if not isinstance(value, str):
        return None
    try:
        parsed = urlsplit(value)
    except ValueError:
        # A malformed retained URL is an identity conflict, not a fatal
        # monitor-level parse error.  The caller preserves the raw cursor and
        # blocks comparison for that component.
        return None
    if parsed.scheme != "https" or parsed.netloc != "api.github.com" or parsed.query or parsed.fragment:
        return None
    match = re.fullmatch(r"/repos/([^/]+/[^/]+)/releases", parsed.path)
    if not match:
        return None
    repository = match.group(1)
    return repository.lower() if _REPOSITORY.fullmatch(repository) else None


def _normalize_github_record(key: str, value: Mapping[str, Any]) -> tuple[str, dict[str, Any]]:
    """Normalize one validated cursor while retaining alias provenance.

    Only repository spelling and source URL casing are normalized.  Rich release,
    retag, asset, and publication-history fields remain byte-for-byte equivalent
    in the canonical record.  Invalid or foreign metadata raises so callers can
    preserve both aliases and block comparison.
    """
    canonical = _canonical_github_key(key)
    if canonical is None:
        raise NativeManifestError("Malformed GitHub observation key")
    if not isinstance(value, Mapping):
        raise NativeManifestError("Malformed retained GitHub observation")
    repository = canonical[len(_GITHUB_KEY_PREFIX):]
    record = deepcopy(dict(value))
    declared = record.get("repository")
    from_source = _source_repository(record.get("source"))
    if declared is not None:
        if not isinstance(declared, str) or not _REPOSITORY.fullmatch(declared):
            raise NativeManifestError("Malformed retained GitHub repository")
        declared = declared.lower()
    if from_source is not None and from_source != repository:
        raise NativeManifestError("Retained GitHub source identity changed")
    if declared is not None and declared != repository:
        raise NativeManifestError("Retained GitHub repository identity changed")
    if from_source is None:
        raise NativeManifestError("Malformed retained GitHub source")
    record["repository"] = repository
    if record.get("source") is not None:
        record["source"] = _github_release_source(repository)
    aliases = record.get("vortx_identity_aliases", [])
    if not isinstance(aliases, list) or not all(isinstance(alias, str) for alias in aliases):
        raise NativeManifestError("Malformed retained GitHub aliases")
    alias_values = set(aliases)
    if key != canonical:
        alias_values.add(key)
    if alias_values:
        record["vortx_identity_aliases"] = sorted(alias_values)
    observed_at = record.get("observed_at")
    alias_observed = record.get("vortx_alias_observed_at", {})
    if not isinstance(alias_observed, Mapping) or not all(
            isinstance(alias, str) and isinstance(stamp, str)
            for alias, stamp in alias_observed.items()):
        raise NativeManifestError("Malformed retained GitHub alias timestamps")
    alias_observed = dict(alias_observed)
    if key != canonical and isinstance(observed_at, str):
        alias_observed[key] = observed_at
    if alias_observed:
        record["vortx_alias_observed_at"] = dict(sorted(alias_observed.items()))
    return canonical, record


def _history_projection(value: Mapping[str, Any]) -> dict[str, Any]:
    """Exclude only alias bookkeeping and observation timestamps from conflict checks."""
    projected = deepcopy(dict(value))
    projected.pop("observed_at", None)
    projected.pop("vortx_identity_aliases", None)
    projected.pop("vortx_alias_observed_at", None)
    return projected


def _merge_equivalent_github_records(items: list[tuple[str, Mapping[str, Any]]]) -> dict[str, Any]:
    """Merge aliases only when their validated histories are equivalent."""
    if not items:
        raise NativeManifestError("No GitHub cursor records")
    canonical, first = _normalize_github_record(items[0][0], items[0][1])
    baseline = _canonical(_history_projection(first))
    merged = deepcopy(first)
    aliases = set(merged.get("vortx_identity_aliases", []))
    observed = dict(merged.get("vortx_alias_observed_at", {}))
    for alias, value in items[1:]:
        candidate_key, candidate = _normalize_github_record(alias, value)
        if candidate_key != canonical or _canonical(_history_projection(candidate)) != baseline:
            raise NativeManifestError("Conflicting GitHub alias histories")
        aliases.update(candidate.get("vortx_identity_aliases", []))
        candidate_stamp = candidate.get("observed_at")
        if alias != canonical and isinstance(candidate_stamp, str):
            observed[alias] = candidate_stamp
        observed.update(candidate.get("vortx_alias_observed_at", {}))
    if aliases:
        merged["vortx_identity_aliases"] = sorted(aliases)
    if observed:
        merged["vortx_alias_observed_at"] = dict(sorted(observed.items()))
    return merged


def _reconcile_keyed_github_records(records: Mapping[str, Any], scope: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Canonicalize GitHub keys and reject ambiguous alias histories."""
    if not isinstance(records, Mapping):
        return {}, []
    grouped: dict[str, list[tuple[str, Any]]] = {}
    passthrough: dict[str, Any] = {}
    for key, value in records.items():
        canonical = _canonical_github_key(key)
        if canonical is None:
            passthrough[key] = deepcopy(value)
        else:
            grouped.setdefault(canonical, []).append((key, value))
    output = dict(passthrough)
    conflicts: list[dict[str, Any]] = []
    for canonical, items in sorted(grouped.items()):
        try:
            output[canonical] = _merge_equivalent_github_records(items)
        except NativeManifestError as error:
            for key, value in items:
                output[key] = deepcopy(value)
            conflicts.append({"component": canonical, "scope": scope,
                              "keys": sorted(key for key, _ in items),
                              "reason": "conflicting-github-identity-history",
                              "detail": str(error)})
    return output, conflicts


def reconcile_github_state(prior_report: Mapping[str, Any] | None,
                           reused: Mapping[str, Any] | None) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    """Reconcile mixed-case prior and reuse keys before generic comparison.

    Non-GitHub identities are untouched.  A conflict leaves every original alias
    intact and returns a blocked canonical component for the monitor to report;
    no query or history selection is permitted for that component.
    """
    report = deepcopy(dict(prior_report or {}))
    releases, prior_conflicts = _reconcile_keyed_github_records(report.get("releases", {}), "prior")
    if "releases" in report:
        report["releases"] = releases
    reused_records, reuse_conflicts = _reconcile_keyed_github_records(reused or {}, "reuse")
    conflicts = prior_conflicts + reuse_conflicts
    conflicts.sort(key=lambda item: (item["component"], item["scope"], item["keys"]))
    return report, reused_records, conflicts


def _lane_index(manifest: Mapping[str, Any]) -> dict[str, list[dict[str, Any]]]:
    lanes: dict[str, list[dict[str, Any]]] = {name: [] for name in manifest["upstreams"]}
    for lane_name, lane in manifest["lanes"].items():
        for group in lane["upstreams"]:
            evidence = lane.get("evidence", {})
            lanes[group].append({
                "lane": lane_name,
                "row": lane["row"],
                "component": lane["component"],
                "pin_map": evidence.get("pin_map"),
                "tsv_data_row": evidence.get("tsv_data_row"),
            })
    for group in lanes:
        lanes[group].sort(key=lambda item: item["lane"])
    return lanes


def _supplemental_index(manifest: Mapping[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """Index every supplemental observation attribution by native group."""
    groups: dict[str, list[dict[str, Any]]] = {name: [] for name in manifest["upstreams"]}
    for observation, spec in manifest["supplemental_observations"].items():
        attribution = deepcopy(dict(spec))
        attribution["observation"] = observation
        for group in spec["upstreams"]:
            groups[group].append(attribution)
    for group in groups:
        groups[group].sort(key=lambda item: item["observation"])
    return groups


def _safe_mapping_label(value: Any, fallback: str = "unlabelled") -> str:
    """Keep bounded display labels; replace obvious paths and unsafe values."""
    if isinstance(value, str):
        if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
            return "redacted-" + sha256(value.encode("utf-8", "replace")).hexdigest()[:16]
        candidate = value.strip()
        path_like = (
            not candidate
            or candidate.startswith(("/", "\\", "~"))
            or re.match(r"^[A-Za-z]:[\\/]", candidate)
            or _MAPPING_SCHEME.match(candidate)
        )
        if not path_like and _SAFE_MAPPING_LABEL.fullmatch(candidate):
            return candidate
    if value is None:
        return fallback
    return "redacted-" + sha256(str(value).encode("utf-8", "replace")).hexdigest()[:16]


def _lane_mapping_projection(lane_evidence: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Project only row/component/PIN labels; never retain paths or raw evidence."""
    return [
        {
            "lane": _safe_mapping_label(item.get("lane")),
            "row": item.get("row"),
            "component": _safe_mapping_label(item.get("component")),
            "pin_map": _safe_mapping_label(item.get("pin_map")),
        }
        for item in sorted(lane_evidence, key=lambda value: (value.get("lane", ""), value.get("row", 0)))
    ]


def _supplemental_mapping_projection(supplemental_evidence: Iterable[Mapping[str, Any]]) -> list[dict[str, str]]:
    """Project supplemental observation labels onto every affected group."""
    return [
        {
            "observation": _safe_mapping_label(item.get("observation")),
            "component": _safe_mapping_label(item.get("component")),
        }
        for item in sorted(supplemental_evidence, key=lambda value: value.get("observation", ""))
    ]


def _source_evidence_digest_map(manifest: Mapping[str, Any]) -> dict[str, str]:
    """Return declared evidence digests only; paths and values stay out of the ledger."""
    source_evidence = manifest.get("source_evidence", {})
    output: dict[str, str] = {}
    if not isinstance(source_evidence, Mapping):
        return output
    for name in _SOURCE_EVIDENCE_HASH_KEYS:
        value = source_evidence.get(name)
        if isinstance(value, Mapping) and isinstance(value.get("sha256"), str):
            output[name] = value["sha256"]
    return dict(sorted(output.items()))


def _source_evidence_fingerprint(manifest: Mapping[str, Any]) -> str:
    return sha256(_canonical(_source_evidence_digest_map(manifest))).hexdigest()


def validate_manifest(manifest: Mapping[str, Any], expected_counts: Mapping[str, int] | None = None) -> dict[str, Any]:
    """Validate structure, lane coverage, and public endpoint safety.

    This checks completeness and identity safety only.  It intentionally does
    not validate that a source is reachable or that any artifact was shipped.
    """
    if not isinstance(manifest, Mapping):
        raise NativeManifestError("Native manifest must be an object")
    if manifest.get("schema_version") != 1:
        raise NativeManifestError("Unsupported native manifest schema")
    upstreams = manifest.get("upstreams")
    lanes = manifest.get("lanes")
    supplemental = manifest.get("supplemental_observations")
    if not isinstance(upstreams, Mapping) or not isinstance(lanes, Mapping) or not isinstance(supplemental, Mapping):
        raise NativeManifestError("Native manifest is missing upstreams, lanes, or supplemental observations")

    counts = manifest.get("counts")
    actual = {
        "original_inventory_lanes": len(lanes),
        "supplemental_runtime_observations": len(supplemental),
        "unique_upstream_sources": len(upstreams),
        "omitted_original_rows": counts.get("omitted_original_rows") if isinstance(counts, Mapping) else None,
    }
    if not isinstance(counts, Mapping) or any(counts.get(key) != value for key, value in actual.items()):
        raise NativeManifestError("Native manifest counts do not match its contents")
    expected = dict(EXPECTED_COUNTS if expected_counts is None else expected_counts)
    if any(actual.get(key) != value for key, value in expected.items()):
        raise NativeManifestError("Native manifest does not match the reviewed inventory counts")

    for group, spec in upstreams.items():
        if not isinstance(group, str) or not group or not isinstance(spec, Mapping):
            raise NativeManifestError("Malformed native upstream group")
        mode = spec.get("mode")
        if mode not in SUPPORTED_MODES:
            raise NativeManifestError(f"Unsupported native upstream mode for {group}")
        endpoints = spec.get("endpoints")
        if not isinstance(endpoints, list) or not all(isinstance(endpoint, str) for endpoint in endpoints):
            raise NativeManifestError(f"Malformed endpoint list for {group}")
        if mode == "internal" and endpoints:
            raise NativeManifestError(f"Internal upstream exposes an endpoint for {group}")
        if mode != "internal" and not all(_public_https(endpoint) for endpoint in endpoints):
            raise NativeManifestError(f"Non-public endpoint in native upstream {group}")

    expected_lanes = {f"native-{index:02d}" for index in range(1, 64)}
    if set(lanes) != expected_lanes:
        raise NativeManifestError("Native lane keys are not exactly native-01 through native-63")
    for lane_name, lane in lanes.items():
        if not _LANE.fullmatch(lane_name) or not isinstance(lane, Mapping):
            raise NativeManifestError("Malformed native lane")
        row = lane.get("row")
        evidence = lane.get("evidence")
        if not isinstance(row, int) or row != int(lane_name[-2:]) or not isinstance(evidence, Mapping):
            raise NativeManifestError(f"Lane evidence does not match {lane_name}")
        if evidence.get("tsv_data_row") != row:
            raise NativeManifestError(f"Lane TSV evidence does not match {lane_name}")
        groups = lane.get("upstreams")
        modes = lane.get("modes")
        if (not isinstance(groups, list) or not groups or not all(group in upstreams for group in groups)
                or not isinstance(modes, list) or not all(upstreams[group]["mode"] in modes for group in groups)):
            raise NativeManifestError(f"Lane upstream mapping is incomplete for {lane_name}")
    for observation, spec in supplemental.items():
        if not isinstance(observation, str) or not isinstance(spec, Mapping):
            raise NativeManifestError("Malformed supplemental observation")
        groups = spec.get("upstreams")
        if not isinstance(groups, list) or not groups or not all(group in upstreams for group in groups):
            raise NativeManifestError(f"Supplemental observation mapping is incomplete for {observation}")
    referenced = {group for lane in lanes.values() for group in lane["upstreams"]}
    referenced.update(group for spec in supplemental.values() for group in spec["upstreams"])
    if referenced != set(upstreams):
        raise NativeManifestError("Native upstream groups are silently omitted from lane or supplemental mappings")
    return dict(manifest)


def github_upstream_identities(manifest: Mapping[str, Any]) -> dict[str, Any]:
    """Map all valid GitHub groups to deduplicated generic observer identities."""
    manifest = validate_manifest(manifest)
    lanes = _lane_index(manifest)
    by_repository: dict[str, dict[str, Any]] = {}
    invalid: list[dict[str, str]] = []
    group_to_repository: dict[str, str] = {}
    for group, spec in sorted(manifest["upstreams"].items()):
        if spec["mode"] not in GITHUB_MODES:
            continue
        parsed = [_github_endpoint(endpoint) for endpoint in spec["endpoints"]]
        release_sources = sorted({item["url"] for item in parsed if item and item["kind"] == "releases"})
        tag_sources = sorted({item["url"] for item in parsed if item and item["kind"] == "tags"})
        repositories = sorted({item["repository"] for item in parsed if item})
        if len(repositories) != 1 or not release_sources or not tag_sources:
            invalid.append({"group": group, "reason": "requires-one-public-releases-and-tags-endpoint-pair"})
            continue
        repository = repositories[0]
        group_to_repository[group] = repository
        identity = by_repository.setdefault(repository, {
            "repository": repository,
            "groups": [],
            "lanes": [],
            "lane_evidence": [],
            "release_sources": [],
            "tags_sources": [],
        })
        identity["groups"].append(group)
        identity["lanes"].extend(item["lane"] for item in lanes[group])
        identity["lane_evidence"].extend(lanes[group])
        identity["release_sources"].extend(release_sources)
        if group == "dovi":
            identity["repository_observation_scope"] = "repository-metadata-only"
            identity["underlying_library"] = deepcopy(_DOVI_SCOPE)
        identity["tags_sources"].extend(tag_sources)
    identities = []
    repository_to_groups: dict[str, list[str]] = {}
    repository_to_lanes: dict[str, list[str]] = {}
    for repository, identity in sorted(by_repository.items()):
        identity = dict(identity)
        for key in ("groups", "lanes", "release_sources", "tags_sources"):
            identity[key] = sorted(set(identity[key]))
        identity["lane_evidence"] = sorted(identity["lane_evidence"], key=lambda item: item["lane"])
        identities.append(identity)
        repository_to_groups[repository] = identity["groups"]
        repository_to_lanes[repository] = identity["lanes"]
    return {
        "identities": identities,
        "invalid_groups": sorted(invalid, key=lambda item: item["group"]),
        "group_to_repository": dict(sorted(group_to_repository.items())),
        "repository_to_groups": repository_to_groups,
        "repository_to_lanes": repository_to_lanes,
    }


def native_lane_map(manifest: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Return all 63 lane-to-source mappings in a deterministic table."""
    manifest = validate_manifest(manifest)
    output = []
    for lane_name, lane in sorted(manifest["lanes"].items()):
        output.append({
            "lane": lane_name,
            "row": lane["row"],
            "component": lane["component"],
            "pin_map": lane["evidence"].get("pin_map"),
            "upstreams": list(lane["upstreams"]),
            "modes": list(lane["modes"]),
        })
    return output


def augment_inventory(inventory: Mapping[str, Any], manifest: Mapping[str, Any], prior_native: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Add one generic entry per unique GitHub repo without duplicate queries."""
    manifest = validate_manifest(manifest)
    mapping = github_upstream_identities(manifest)
    entries = deepcopy(list(inventory.get("entries", [])))
    by_key: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for entry in entries:
        ecosystem, name = entry.get("ecosystem"), entry.get("name")
        if ecosystem == "github" and isinstance(name, str):
            canonical = name.lower()
            if name != canonical:
                aliases = set(entry.get("name_aliases", [])) if isinstance(entry.get("name_aliases"), list) else set()
                aliases.add(name)
                entry["name_aliases"] = sorted(alias for alias in aliases if isinstance(alias, str))
                entry["name"] = canonical
            name = canonical
        by_key.setdefault((ecosystem, name), []).append(entry)
    for identity in mapping["identities"]:
        key = ("github", identity["repository"])
        matches = by_key.get(key, [])
        if not matches:
            entry = {
                "ecosystem": "github",
                "name": identity["repository"],
                "current": "native-pin-unverified",
                "repository": "native-monitor/" + ",".join(identity["groups"]),
                "source": identity["release_sources"][0],
                "kind": "native-github-upstream",
            }
            entry["native_upstream_groups"] = identity["groups"]
            entry["native_lanes"] = identity["lanes"]
            if "underlying_library" in identity:
                entry["native_underlying_library"] = deepcopy(identity["underlying_library"])
            entries.append(entry)
            by_key[key] = [entry]
        else:
            for entry in matches:
                entry["native_upstream_groups"] = sorted(set(entry.get("native_upstream_groups", [])) | set(identity["groups"]))
                entry["native_lanes"] = sorted(set(entry.get("native_lanes", [])) | set(identity["lanes"]))
                if "underlying_library" in identity:
                    entry["native_underlying_library"] = deepcopy(identity["underlying_library"])
    coverage = build_native_coverage(manifest, prior_native=prior_native)
    result = dict(inventory)
    result["entries"] = entries
    result["native_monitor"] = coverage
    result["coverage_gaps"] = sorted({
        (gap.get("source"), gap.get("reason")): gap
        for gap in list(inventory.get("coverage_gaps", [])) + coverage["coverage_gaps"]
    }.values(), key=lambda item: (item.get("source", ""), item.get("reason", "")))
    return result


def reconcile_top_level_coverage_gaps(existing_gaps: Iterable[Mapping[str, Any]],
                                      current_native: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Refresh native gaps in the report without hiding unrelated gaps.

    ``augment_inventory`` runs before the generic compare, so its native
    parent-registry gaps can still be present in the top-level report after
    ``coverage_after_compare`` proves a group in the same run.  The native
    ledger is authoritative for exact known group gaps; subordinate gaps and
    non-native/unknown-source gaps remain visible.
    """
    current = current_native if isinstance(current_native, Mapping) else {}
    current_groups = current.get("groups", {})
    if not isinstance(current_groups, Mapping):
        current_groups = {}
    merged: dict[tuple[str, str], dict[str, Any]] = {}
    current_gap_sources: set[str] = set()
    for item in current.get("coverage_gaps", []):
        if isinstance(item, Mapping) and isinstance(item.get("source"), str) and isinstance(item.get("reason"), str):
            value = dict(item)
            merged[(value["source"], value["reason"])] = value
            current_gap_sources.add(value["source"])
    for item in existing_gaps or ():
        if not isinstance(item, Mapping) or not isinstance(item.get("source"), str) or not isinstance(item.get("reason"), str):
            continue
        value = dict(item)
        source = value["source"]
        if source.startswith("native/"):
            suffix = source[len("native/"):]
            group = suffix.split("/", 1)[0]
            group_record = current_groups.get(group)
            if "/" not in suffix and isinstance(group_record, Mapping) and group in current_groups:
                # Current native coverage owns this exact group.  An observed
                # group has no unresolved exact gap; an unverified group is
                # replaced only when the current ledger emitted a new exact
                # gap.  A pending GitHub observation may emit no gap, so keep
                # that prior unresolved signal rather than hiding it.
                if group_record.get("status") == "observed" or source in current_gap_sources:
                    continue
            # A subordinate native gap (for example dovi/libdovi), a removed
            # group, or an unknown future group remains explicit.
        merged.setdefault((source, value["reason"]), value)
    return sorted(merged.values(), key=lambda item: (item["source"], item["reason"]))


def native_inventory_entries(manifest: Mapping[str, Any], existing_entries: Iterable[Mapping[str, Any]] = ()) -> list[dict[str, Any]]:
    """Return the merged entry table for callers that do not hold full inventory."""
    return augment_inventory({"entries": list(existing_entries), "coverage_gaps": []}, manifest)["entries"]


def native_coverage_state(manifest: Mapping[str, Any], prior_native: Mapping[str, Any] | None = None,
                          releases: Mapping[str, Any] | None = None,
                          errors: Iterable[str] | None = None,
                          incomplete: Iterable[str] | None = None) -> dict[str, Any]:
    """Named compatibility wrapper for integrations that prefer a state API."""
    return build_native_coverage(manifest, prior_native=prior_native, releases=releases,
                                 errors=errors, incomplete=incomplete)


def _reuse_keys(spec: Mapping[str, Any]) -> list[str]:
    """Record possible same-run registry identities without performing a query."""
    keys: set[str] = set()
    for endpoint in spec.get("endpoints", []):
        if not isinstance(endpoint, str):
            continue
        match = re.search(r"/maven2/(.+?)/maven-metadata\.xml(?:\?|$)", endpoint)
        if match:
            parts = match.group(1).strip("/").split("/")
            if len(parts) >= 2:
                keys.add("maven:" + ".".join(parts[:-1]) + ":" + parts[-1])
        if "crates.io" in endpoint:
            keys.add("cargo:registry-source")
    return sorted(keys)


def _parent_registry_mapping(group: str, spec: Mapping[str, Any]) -> list[dict[str, str]]:
    """Return an exact, public endpoint-to-identity mapping for one parent lane.

    The native manifest is source evidence, not a query plan.  A parent lane is
    eligible only when its mode and endpoint list exactly match the reviewed
    public mapping above.  Unknown, extra, duplicated, or otherwise changed
    endpoints are left unverified rather than guessed from a URL suffix.
    """
    if spec.get("mode") != "parent-registry":
        return []
    expected = _PARENT_REGISTRY_IDENTITIES.get(group)
    endpoints = spec.get("endpoints")
    if not expected or not isinstance(endpoints, list) or any(not isinstance(value, str) for value in endpoints):
        return []
    if len(endpoints) != len(expected) or len(set(endpoints)) != len(endpoints):
        return []
    if set(endpoints) != set(expected):
        return []
    return [{"source": endpoint, "component": expected[endpoint]} for endpoint in endpoints]


def _cargo_index_source(name: str) -> str:
    """Return the exact public sparse-index source used by releases()."""
    name = name.lower()
    part = "1" if len(name) == 1 else "2" if len(name) == 2 else (
        f"3/{name[0]}" if len(name) == 3 else f"{name[:2]}/{name[2:4]}"
    )
    return f"https://index.crates.io/{part}/{name}"


def _parent_registry_source_is_exact(source: Any, endpoint: str, component: str) -> bool:
    """Validate generic metadata against the reviewed public source identity."""
    if not isinstance(source, str):
        return False
    if component.startswith("cargo:"):
        return source == _cargo_index_source(component.split(":", 1)[1])
    return source == endpoint


def _parent_metadata_reason(metadata: Any, endpoint: str, component: str) -> str | None:
    """Fail closed on malformed or retained-only generic metadata."""
    if not isinstance(metadata, Mapping):
        return "parent-registry-observation-missing"
    required = {"versions", "latest_stable", "source", "observed_at"}
    if not required <= set(metadata):
        return "parent-registry-observation-metadata-incomplete"
    versions = metadata.get("versions")
    if (not isinstance(versions, list) or not versions or
            any(not isinstance(version, str) or not version for version in versions) or
            versions != sorted(set(versions))):
        return "parent-registry-observation-versions-invalid"
    latest = metadata.get("latest_stable")
    if latest is not None and (not isinstance(latest, str) or latest not in versions):
        return "parent-registry-observation-latest-invalid"
    if not isinstance(metadata.get("observed_at"), str) or not metadata["observed_at"]:
        return "parent-registry-observation-timestamp-invalid"
    if not _parent_registry_source_is_exact(metadata.get("source"), endpoint, component):
        return "parent-registry-observation-source-mismatch"
    if metadata.get("absent_observations") or metadata.get("absent_versions"):
        return "parent-registry-observation-incomplete"
    return None


def _parent_success_evidence_reason(evidence: Any, metadata: Mapping[str, Any]) -> str | None:
    """Require compare's explicit same-run success marker for one component."""
    if not isinstance(metadata, Mapping):
        return "parent-registry-success-evidence-invalid"
    if (not isinstance(metadata.get("observed_at"), str) or not metadata["observed_at"] or
            not isinstance(metadata.get("source"), str) or not metadata["source"]):
        return "parent-registry-success-evidence-invalid"
    if not isinstance(evidence, Mapping):
        return "parent-registry-success-evidence-missing"
    required = {"observed_at", "source", "kind"}
    if not required <= set(evidence):
        return "parent-registry-success-evidence-invalid"
    kind = evidence.get("kind")
    if not isinstance(kind, str) or kind not in {"fresh", "reused"}:
        return "parent-registry-success-evidence-invalid"
    if evidence.get("observed_at") != metadata.get("observed_at"):
        return "parent-registry-success-evidence-mismatch"
    if evidence.get("source") != metadata.get("source"):
        return "parent-registry-success-evidence-mismatch"
    return None


def _parent_registry_observation(group: str, spec: Mapping[str, Any], releases: Mapping[str, Any] | None,
                                 error_keys: set[str], incomplete_keys: set[str],
                                 compare_checked_at: str | None,
                                 successful_observations: Mapping[str, Any] | None,
                                 compare_collections_valid: bool) -> dict[str, Any]:
    """Project only successful current generic observations into a native lane.

    ``releases`` is intentionally accepted only from the same compare result;
    prior_native is never consulted here.  The compare-level success map is the
    freshness boundary: its exact component keys prove that each endpoint was
    refreshed or explicitly reused in this invocation.  A checked-at stamp and
    per-component observed-at/source stamps make that boundary auditable.
    """
    mapping = _parent_registry_mapping(group, spec)
    keys = sorted(item["component"] for item in mapping)
    base = {"registry_reuse_keys": keys}
    if not mapping:
        base.update({"status": "unverified", "reason": "parent-registry-source-not-allowlisted"})
        return base
    if not isinstance(compare_checked_at, str) or not compare_checked_at:
        base.update({"status": "unverified", "reason": "parent-registry-compare-timestamp-missing"})
        return base
    if not isinstance(releases, Mapping):
        base.update({"status": "unverified", "reason": "parent-registry-observation-not-run"})
        return base
    if not compare_collections_valid:
        base.update({"status": "unverified", "reason": "parent-registry-compare-collections-malformed"})
        return base
    if not isinstance(successful_observations, Mapping):
        base.update({"status": "unverified", "reason": "parent-registry-success-evidence-missing"})
        return base
    observations: dict[str, str] = {}
    for item in mapping:
        component = item["component"]
        if component in error_keys:
            base.update({"status": "unverified", "reason": "parent-registry-observation-failed"})
            return base
        if component in incomplete_keys:
            base.update({"status": "unverified", "reason": "parent-registry-observation-incomplete"})
            return base
        metadata = releases.get(component)
        reason = _parent_metadata_reason(metadata, item["source"], component)
        if reason is not None:
            base.update({"status": "unverified", "reason": reason})
            return base
        reason = _parent_success_evidence_reason(successful_observations.get(component), metadata)
        if reason is not None:
            base.update({"status": "unverified", "reason": reason})
            return base
        observations[component] = metadata["observed_at"]
    base.update({
        "status": "observed",
        "observation_source": "same-run-generic-registry-observer",
        "observation_checked_at": compare_checked_at,
        "registry_observed_at": dict(sorted(observations.items())),
        "registry_sources": [
            {"component": item["component"],
             "manifest_endpoint": item["source"],
             "observation_source": releases[item["component"]]["source"]}
            for item in mapping
        ],
    })
    return base


def _unsupported_reason(mode: str, review: str) -> str:
    if mode == "internal":
        return "internal-source-not-disclosed"
    if mode == "parent-registry":
        return "adapter-not-implemented-parent-registry-reuse"
    if mode == "rolling-commit":
        return "adapter-not-implemented-rolling-source"
    if review.startswith("EXPLICIT_"):
        return "explicit-upstream-review-required"
    return "adapter-not-implemented-official-feed"


def _bounded_journal_refs(previous: Mapping[str, Any]) -> list[str]:
    """Retain only opaque external journal references, never prior group state."""
    values: list[Any] = []
    raw = previous.get("journal_refs")
    if isinstance(raw, str):
        values.append(raw)
    elif isinstance(raw, list):
        values.extend(raw)
    scalar = previous.get("journal_ref")
    if isinstance(scalar, str):
        values.append(scalar)
    output: list[str] = []
    for value in values:
        if not isinstance(value, str) or not value or len(value) > _MAX_NATIVE_JOURNAL_REF_LENGTH:
            continue
        if value not in output:
            output.append(value)
    return output[-_MAX_NATIVE_JOURNAL_REFS:]


def _retain_previous_cursor(record: dict[str, Any], previous: Mapping[str, Any]) -> None:
    """Carry one flat cursor and bounded journal refs; never clone prior state."""
    record["retained_previous_state"] = True
    record["previous_status"] = previous.get("status")
    cursor = previous.get("last_success")
    if isinstance(cursor, Mapping):
        record["last_success"] = deepcopy(dict(cursor))
    refs = _bounded_journal_refs(previous)
    if refs:
        record["journal_refs"] = refs


def _incomplete_observation_keys(comparison: Mapping[str, Any]) -> set[str]:
    """Return generic identities whose retained data is stale or contracted."""
    contractions = comparison.get("history_contractions", [])
    if not isinstance(contractions, list):
        contractions = []
    keys = {
        item.get("component")
        for item in contractions
        if isinstance(item, Mapping) and isinstance(item.get("component"), str)
    }
    releases = comparison.get("releases", {})
    if not isinstance(releases, Mapping):
        return keys
    for key, metadata in releases.items():
        if isinstance(key, str) and isinstance(metadata, Mapping) and (
                metadata.get("absent_observations") or metadata.get("absent_versions")):
            keys.add(key)
    return keys


def build_native_coverage(manifest: Mapping[str, Any], prior_native: Mapping[str, Any] | None = None,
                         releases: Mapping[str, Any] | None = None,
                         errors: Iterable[str] | None = None,
                         incomplete: Iterable[str] | None = None,
                         observation_checked_at: str | None = None,
                         successful_observations: Mapping[str, Any] | None = None,
                         compare_collections_valid: bool = True) -> dict[str, Any]:
    """Build a 69-group ledger; unsupported groups remain explicit UNVERIFIED."""
    manifest = validate_manifest(manifest)
    mapping = github_upstream_identities(manifest)
    group_to_identity = {}
    for identity in mapping["identities"]:
        for group in identity["groups"]:
            group_to_identity[group] = identity
    error_keys = {key for key in (errors or ()) if isinstance(key, str)}
    incomplete_keys = {key for key in (incomplete or ()) if isinstance(key, str)}
    prior_groups = (prior_native or {}).get("groups", {}) if isinstance(prior_native, Mapping) else {}
    lane_index = _lane_index(manifest)
    supplemental_index = _supplemental_index(manifest)
    source_evidence = _source_evidence_digest_map(manifest)
    groups: dict[str, dict[str, Any]] = {}
    gaps: list[dict[str, str]] = []
    for group, spec in sorted(manifest["upstreams"].items()):
        mode, review = spec["mode"], spec.get("review", "UNREVIEWED")
        lane_evidence = lane_index[group]
        lanes = [item["lane"] for item in lane_evidence]
        supplemental_evidence = supplemental_index[group]
        record: dict[str, Any] = {
            "mode": mode,
            "review": review,
            "lanes": sorted(lanes),
            "lane_mappings": _lane_mapping_projection(lane_evidence),
            "supplemental_mappings": _supplemental_mapping_projection(supplemental_evidence),
            "source_fingerprint": sha256(_canonical({
                "mode": mode,
                "endpoints": spec.get("endpoints", []),
                "lane_evidence": lane_evidence,
                "supplemental_attribution": supplemental_evidence,
            })).hexdigest(),
        }
        identity = group_to_identity.get(group)
        if identity:
            key = "github:" + identity["repository"]
            record.update({
                "repository": identity["repository"],
                "observation_key": key,
                "observation_source": "existing-github-tag-release-asset-observer",
            })
            if key in error_keys:
                record["status"] = "unverified"
                record["reason"] = "existing-github-observer-failed"
            elif key in incomplete_keys:
                record["status"] = "unverified"
                record["reason"] = "existing-github-observer-incomplete"
            elif releases is not None and not isinstance(releases, Mapping):
                record["status"] = "unverified"
                record["reason"] = "existing-github-observer-observation-malformed"
            elif isinstance(releases, Mapping) and key in releases:
                if not compare_collections_valid:
                    record["status"] = "unverified"
                    record["reason"] = "native-compare-collections-malformed"
                elif not isinstance(successful_observations, Mapping):
                    record["status"] = "unverified"
                    record["reason"] = "existing-github-observer-success-evidence-missing"
                else:
                    evidence_reason = _parent_success_evidence_reason(
                        successful_observations.get(key), releases[key]
                    )
                    if evidence_reason is None:
                        record["status"] = "observed"
                    else:
                        record["status"] = "unverified"
                        record["reason"] = "existing-github-observer-" + evidence_reason.removeprefix(
                            "parent-registry-"
                        )
            else:
                record["status"] = "pending-observation"
                record["reason"] = "existing-github-observer-not-run"
        elif mode == "parent-registry":
            parent = _parent_registry_observation(
                group, spec, releases, error_keys, incomplete_keys, observation_checked_at,
                successful_observations, compare_collections_valid,
            )
            record.update(parent)
            if parent["status"] != "observed":
                gaps.append({"source": "native/" + group, "reason": parent["reason"]})
        else:
            record["status"] = "unverified"
            record["reason"] = _unsupported_reason(mode, review)
            reuse = _reuse_keys(spec)
            if reuse:
                record["registry_reuse_keys"] = reuse
            gaps.append({"source": "native/" + group, "reason": record["reason"]})
        if group == "dovi":
            record["repository_observation_scope"] = "repository-metadata-only"
            record["underlying_library"] = deepcopy(_DOVI_SCOPE)
            gaps.append({"source": "native/dovi/libdovi", "reason": "underlying-library-version-unverified"})
        previous = prior_groups.get(group)
        if isinstance(previous, Mapping):
            _retain_previous_cursor(record, previous)
        groups[group] = record
    for invalid in mapping["invalid_groups"]:
        record = groups[invalid["group"]]
        record["status"] = "unverified"
        record["reason"] = invalid["reason"]
        gaps.append({"source": "native/" + invalid["group"], "reason": invalid["reason"]})
    return {
        "schema_version": 1,
        "manifest_sha256": manifest_sha256(manifest),
        "counts": dict(manifest["counts"]),
        "github_identity_count": len(mapping["identities"]),
        "source_evidence_digests": source_evidence,
        "source_evidence_fingerprint": _source_evidence_fingerprint(manifest),
        "groups": groups,
        "coverage_gaps": sorted(gaps, key=lambda item: (item["source"], item["reason"])),
        "all_groups_present": set(groups) == set(manifest["upstreams"]),
        "source_changes": [],
    }


def merge_native_coverage(previous: Mapping[str, Any] | None, current: Mapping[str, Any]) -> dict[str, Any]:
    """Merge coverage without erasing a cursor or recursively copying prior state."""
    prior = deepcopy(dict(previous or {}))
    merged = deepcopy(dict(current))
    groups = deepcopy(prior.get("groups", {}))
    for group, record in current.get("groups", {}).items():
        old = groups.get(group)
        value = deepcopy(record)
        value.pop("previous_state", None)
        if isinstance(old, Mapping):
            _retain_previous_cursor(value, old)
        groups[group] = value
    merged["groups"] = dict(sorted(groups.items()))
    current_gaps = {
        (item.get("source"), item.get("reason")): item
        for item in current.get("coverage_gaps", []) if isinstance(item, Mapping)
    }
    current_gap_sources = {
        item.get("source") for item in current.get("coverage_gaps", [])
        if isinstance(item, Mapping) and isinstance(item.get("source"), str)
    }
    gap_map = dict(current_gaps)
    current_groups = current.get("groups", {})
    for item in prior.get("coverage_gaps", []):
        if not isinstance(item, Mapping):
            continue
        source = item.get("source")
        if not isinstance(source, str) or not source.startswith("native/"):
            gap_map.setdefault((item.get("source"), item.get("reason")), item)
            continue
        suffix = source.removeprefix("native/")
        group = suffix.split("/", 1)[0]
        # A current group-level gap is authoritative.  Drop its old reasons so
        # an observed parent cannot remain blocked by a stale adapter gap.  If
        # a pending GitHub row emitted no replacement gap, retain its prior
        # unresolved signal.  Keep subordinate gaps (for example dovi/libdovi)
        # and gaps for removed or otherwise unknown groups explicit.
        current_record = current_groups.get(group) if isinstance(current_groups, Mapping) else None
        if "/" in suffix or not isinstance(current_groups, Mapping) or group not in current_groups:
            gap_map.setdefault((item.get("source"), item.get("reason")), item)
        elif (isinstance(current_record, Mapping)
              and current_record.get("status") != "observed"
              and source not in current_gap_sources):
            gap_map.setdefault((item.get("source"), item.get("reason")), item)
    merged["coverage_gaps"] = sorted(gap_map.values(), key=lambda item: (item.get("source", ""), item.get("reason", "")))
    return merged


def coverage_after_compare(manifest: Mapping[str, Any], previous_native: Mapping[str, Any] | None,
                           comparison: Mapping[str, Any]) -> dict[str, Any]:
    """Attach generic compare results while retaining the native cursor contract."""
    registry_errors = comparison.get("registry_errors", [])
    identity_conflicts = comparison.get("identity_conflicts", [])
    compare_collections_valid = True
    for name in ("registry_errors", "identity_conflicts", "history_contractions"):
        if name not in comparison:
            continue
        collection = comparison.get(name)
        if not isinstance(collection, list) or any(
                not isinstance(item, Mapping) or
                not isinstance(item.get("component"), str) or not item.get("component")
                for item in collection):
            compare_collections_valid = False
    successful_observations = comparison.get("successful_observations")
    if "successful_observations" in comparison and not isinstance(successful_observations, Mapping):
        compare_collections_valid = False
    if not isinstance(registry_errors, list):
        registry_errors = []
    if not isinstance(identity_conflicts, list):
        identity_conflicts = []
    errors = [item.get("component") for item in registry_errors
              if isinstance(item, Mapping) and isinstance(item.get("component"), str)]
    errors.extend(item.get("component") for item in identity_conflicts
                  if isinstance(item, Mapping) and isinstance(item.get("component"), str))
    incomplete = _incomplete_observation_keys(comparison)
    current = build_native_coverage(
        manifest,
        releases=comparison.get("releases", {}),
        errors=errors,
        incomplete=incomplete,
        observation_checked_at=comparison.get("checked_at"),
        successful_observations=successful_observations,
        compare_collections_valid=compare_collections_valid,
    )
    merged = merge_native_coverage(previous_native, current)
    merged["source_changes"] = detect_source_changes(previous_native, current)
    return merged


def detect_source_changes(previous_native: Mapping[str, Any] | None,
                          current_native: Mapping[str, Any]) -> list[dict[str, str]]:
    """Report manifest source changes separately from release notifications."""
    previous_groups = (previous_native or {}).get("groups", {}) if isinstance(previous_native, Mapping) else {}
    changes = []
    previous_evidence = previous_native.get("source_evidence_fingerprint") if isinstance(previous_native, Mapping) else None
    current_evidence = current_native.get("source_evidence_fingerprint")
    if previous_evidence and current_evidence and previous_evidence != current_evidence:
        changes.append({"group": "__manifest__", "scope": "source-evidence",
                        "before": previous_evidence, "after": current_evidence})
    for group, current in sorted(current_native.get("groups", {}).items()):
        old = previous_groups.get(group, {}) if isinstance(previous_groups, Mapping) else {}
        before, after = old.get("source_fingerprint"), current.get("source_fingerprint")
        if before and after and before != after:
            changes.append({"group": group, "before": before, "after": after})
    return changes
