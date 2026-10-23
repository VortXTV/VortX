#!/usr/bin/env python3
"""Enforce direct-dependency advisory policy without changing cargo-audit's exit status."""
import argparse
import json
from pathlib import Path
import re
import sys
import tomllib

PACKAGE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
ADVISORY = re.compile(r"RUSTSEC-[0-9]{4}-[0-9]{4}")
IGNORE = ["RUSTSEC-2024-0429"]
TABLES = ("dependencies", "dev-dependencies", "build-dependencies")


class PolicyError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PolicyError(message)


def direct_packages(manifest):
    """All direct tables/targets, including package aliases; no Cargo metadata/source fetch."""
    require(isinstance(manifest, dict), "Invalid Cargo manifest")
    targets = manifest.get("target", {})
    require(isinstance(targets, dict), "Invalid target dependency tables")
    names = set()
    for owner in (manifest, *targets.values()):
        require(isinstance(owner, dict), "Invalid target dependency table")
        for kind in TABLES:
            dependencies = owner.get(kind, {})
            require(isinstance(dependencies, dict), "Invalid dependency table")
            for alias, value in dependencies.items():
                require(isinstance(alias, str) and PACKAGE.fullmatch(alias), "Invalid dependency identity")
                require(isinstance(value, (str, dict)), "Unsupported dependency declaration")
                if isinstance(value, dict):
                    # Resolving inherited aliases requires the owning workspace manifest.
                    # Fail visibly instead of silently checking the wrong package identity.
                    require("workspace" not in value, "Inherited workspace dependency needs explicit resolution")
                    name = value.get("package", alias)
                else:
                    require(bool(value), "Empty dependency version")
                    name = alias
                require(isinstance(name, str) and PACKAGE.fullmatch(name), "Invalid dependency package alias")
                names.add(name)
    return names


def direct_unmaintained(report, manifest, policy):
    """Return direct unmaintained warnings after validating the exact current audit policy."""
    require(isinstance(policy, dict) and isinstance(policy.get("advisories"), dict), "Missing advisory policy")
    advisory_policy = policy["advisories"]
    require(advisory_policy.get("version") == 2
            and advisory_policy.get("unmaintained") == "workspace"
            and advisory_policy.get("yanked") == "deny"
            and advisory_policy.get("ignore") == IGNORE, "Unsupported advisory policy")
    require(isinstance(report, dict), "Invalid audit report")
    database, lockfile, settings = (report.get(key) for key in ("database", "lockfile", "settings"))
    require(isinstance(database, dict) and type(database.get("advisory-count")) is int
            and database["advisory-count"] > 0, "Missing advisory database coverage")
    require(isinstance(lockfile, dict) and type(lockfile.get("dependency-count")) is int
            and lockfile["dependency-count"] > 0, "Missing lockfile audit coverage")
    require(isinstance(settings, dict) and settings.get("ignore") == IGNORE
            and settings.get("target_arch") == [] and settings.get("target_os") == []
            and settings.get("severity", "missing") is None
            and settings.get("informational_warnings") == ["unmaintained", "unsound", "notice"],
            "Unexpected audit filters or warning coverage")
    vulnerabilities, warnings = report.get("vulnerabilities"), report.get("warnings")
    require(isinstance(vulnerabilities, dict) and type(vulnerabilities.get("found")) is bool
            and type(vulnerabilities.get("count")) is int and vulnerabilities["count"] >= 0
            and isinstance(vulnerabilities.get("list"), list)
            and vulnerabilities["count"] == len(vulnerabilities["list"])
            and vulnerabilities["found"] == bool(vulnerabilities["count"]), "Invalid vulnerability report")
    require(isinstance(warnings, dict) and set(warnings) <= {"unmaintained", "unsound", "notice", "yanked"}
            and all(isinstance(rows, list) for rows in warnings.values()), "Invalid warning report")
    names, blocked = direct_packages(manifest), []
    for warning in warnings.get("unmaintained", []):
        require(isinstance(warning, dict) and warning.get("kind") == "unmaintained", "Invalid unmaintained warning")
        package, advisory = warning.get("package"), warning.get("advisory")
        require(isinstance(package, dict) and isinstance(package.get("name"), str)
                and PACKAGE.fullmatch(package["name"]) and isinstance(package.get("version"), str)
                and bool(package["version"]), "Invalid warning package identity")
        require(isinstance(advisory, dict) and advisory.get("package") == package["name"]
                and advisory.get("informational") == "unmaintained"
                and isinstance(advisory.get("id"), str) and ADVISORY.fullmatch(advisory["id"]),
                "Invalid unmaintained advisory identity")
        if package["name"] in names:
            blocked.append({"name": package["name"], "version": package["version"], "advisory": advisory["id"]})
    return blocked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        blocked = direct_unmaintained(json.loads(args.report.read_text()),
                                      tomllib.loads(args.manifest.read_text()),
                                      tomllib.loads(args.policy.read_text()))
    except (OSError, ValueError, TypeError, KeyError):
        print("Rust audit policy/report validation failed", file=sys.stderr)
        return 2
    if blocked:
        print(json.dumps({"direct_unmaintained": blocked}, sort_keys=True), file=sys.stderr)
        return 1
    print("Rust audit direct-unmaintained policy: no direct warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
