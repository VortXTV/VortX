#!/usr/bin/env python3
"""Generate only genuine pinned scalar/JSON declarations; never import app/native code."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys


def digest(value):
    return hashlib.sha256(value).hexdigest()


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract-apple-playlist-store-host.py REPO OUTPUT")
    repo = Path(sys.argv[1]).resolve(strict=True)
    output = Path(sys.argv[2]).resolve()
    allowed_output = (repo / "app/build/apple-playlist-store-host").resolve()
    if not allowed_output.is_relative_to(repo) or not output.is_relative_to(allowed_output):
        raise SystemExit("output must be inside the repo's owned host fixture build directory")
    manifest_path = repo / "scripts/fixtures/apple-playlist-store-host-inputs.json"
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    loaded = {}
    identities = []
    for row in manifest["inputs"] + manifest["fixtures"]:
        relative = PurePosixPath(row["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise SystemExit("invalid source path")
        path = (repo / relative).resolve(strict=True)
        if not path.is_relative_to(repo):
            raise SystemExit("source path escapes repository")
        body = path.read_bytes()
        actual = digest(body)
        if actual != row["sha256"]:
            raise SystemExit("reviewed source identity changed: " + row["path"])
        loaded[row["path"]] = body
        identities.append({"path": row["path"], "sha256": actual})
    selected = {}
    ranges = []
    for row in manifest["definitions"]:
        body = loaded[row["source"]]
        if "literal" in row:
            literal = row["literal"].encode("utf-8")
            if body.count(literal) != 1:
                raise SystemExit("missing or ambiguous literal: " + row["name"])
            start = body.index(literal)
            value = literal
        else:
            opening = row["start"].encode("utf-8")
            closing = row["end"].encode("utf-8")
            if body.count(opening) != 1 or body.count(closing) != 1:
                raise SystemExit("missing or ambiguous fence: " + row["name"])
            start = body.index(opening)
            end = body.index(closing)
            if end <= start:
                raise SystemExit("reversed source fences: " + row["name"])
            value = body[start:end]
        if digest(value) != row["sha256"]:
            raise SystemExit("reviewed source range changed: " + row["name"])
        selected[row["name"]] = value
        ranges.append({"name": row["name"], "source": row["source"], "offset": start,
                       "bytes": len(value), "sha256": digest(value)})
    if set(selected) != {"VortxJSON", "VortxNativeError", "maxClock", "validActor"}:
        raise SystemExit("unexpected definition set")
    generated = (b"import Foundation\n\n"
                 + selected["VortxJSON"] + b"\n" + selected["VortxNativeError"]
                 + b"\n// Host fixture namespace shell; both bodies below are exact source slices.\n"
                 + b"enum VortxNativeHostPreferences {\n"
                 + selected["maxClock"] + selected["validActor"] + b"}\n")
    output.mkdir(parents=True, exist_ok=False)
    (output / "GenuineStoreHostDefinitions.swift").write_bytes(generated)
    receipt = {"manifestSHA256": digest(manifest_bytes), "inputs": identities,
               "selectedRanges": ranges, "generatedSHA256": digest(generated),
               "extractorSHA256": digest(Path(__file__).read_bytes()),
               "runnerSHA256": digest((repo / "scripts/test-apple-playlist-store-host.sh").read_bytes()),
               "scope": "Full genuine Store/domain/ledger/worker; synthetic authority/queue/transport; no native SDK"}
    (output / "SOURCE-RECEIPT.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
