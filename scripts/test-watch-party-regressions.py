#!/usr/bin/env python3
"""Run the actual Session and panel-model regressions on macOS, sequentially."""
from pathlib import Path
import fcntl
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path("app/SourcesShared")
TESTS = Path("app/Tests/WatchPartyRegression")
BUILD = ROOT / "app/_build/watch-party-regressions"
COMMON = [SOURCE / name for name in (
    "CredentialScope.swift", "LegacyWatchOwnership.swift", "AuthenticatedHTTPTransport.swift",
    "WatchPartyWire.swift", "WatchPartyClientAdmissionPolicy.swift", "WatchPartyClientSession.swift")]
HELPERS = [TESTS / "PlaybackFacades.swift", TESTS / "ControlledTransport.swift"]
WATCHED = COMMON + HELPERS + [
    SOURCE / "VortXSyncManager.swift", SOURCE / "WatchPartyRoomPanel.swift",
    SOURCE / "WatchPartyReplayObligation.swift", SOURCE / "WatchPartyInviteLink.swift",
    TESTS / "WatchPartyClientSessionAsyncTests.swift", TESTS / "WatchPartyPanelModelAsyncTests.swift",
    TESTS / "README.md", Path("scripts/test-watch-party-regressions.py"),
    Path("app/_build/watch-party-regressions/.gitignore")]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_sources():
    sources = {}
    for relative in WATCHED:
        path = ROOT / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT):
            raise RuntimeError("missing or nonlocal source: " + relative.as_posix())
        sources[relative.as_posix()] = path.read_bytes()
    return sources


def identities(sources):
    return {name: {"bytes": len(data), "sha256": digest(data)}
            for name, data in sources.items()}


def unique(data, marker):
    if data.count(marker) != 1:
        raise RuntimeError("missing or ambiguous production source-region fence")
    return data.index(marker)


def prefix(data, start, end, declarations):
    if unique(data, start) != 0:
        raise RuntimeError("production prefix must start at the beginning of its file")
    stop = unique(data, end)
    for declaration in declarations:
        if unique(data, declaration) >= stop:
            raise RuntimeError("production declaration is outside the extracted region")
    return data[:stop], {"byteRangeHalfOpen": [0, stop], "sha256": digest(data[:stop]),
                         "beforeFenceSHA256": digest(data[max(0, stop - 128):stop]),
                         "afterFenceSHA256": digest(data[stop:stop + 128])}


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main():
    if sys.platform != "darwin" or platform.machine() not in ("arm64", "x86_64"):
        raise RuntimeError("requires macOS with an Apple Swift 6 toolchain and macOS SDK")
    for path in (ROOT / "app", ROOT / "app/_build", BUILD):
        if path.is_symlink():
            raise RuntimeError("build output symlinks are not supported")
    ignore_marker = BUILD / ".gitignore"
    if ignore_marker.is_symlink() or not ignore_marker.is_file():
        raise RuntimeError("place the complete regression sources, including the build ignore marker")
    BUILD.mkdir(parents=True, exist_ok=True)
    if not BUILD.resolve().is_relative_to(ROOT):
        raise RuntimeError("build output must remain in this repository")
    lock_path = BUILD / "runner.lock"
    if lock_path.is_symlink():
        raise RuntimeError("build lock symlink is not supported")
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("another watch-party regression runner owns the module cache") from None
        run = Path(tempfile.mkdtemp(prefix="run-", dir=BUILD))
        cache = BUILD / "module-cache"
        if cache.is_symlink():
            raise RuntimeError("module cache symlink is not supported")
        cache.mkdir(exist_ok=True)
        temporary = run / "tmp"
        temporary.mkdir()
        environment = os.environ.copy()
        environment.update(TMPDIR=str(temporary), CLANG_MODULE_CACHE_PATH=str(cache),
                           SWIFT_MODULE_CACHE_PATH=str(cache))
        before = read_sources()
        result = {"scope": "12 actual Session and4 actual panel-model schedules; synthetic external boundaries",
                  "steps": [], "exit": 1}
        try:
            auth, auth_record = prefix(before[str(SOURCE / "VortXSyncManager.swift")],
                b"import Foundation\nimport CoreFoundation\n#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE\n",
                b"#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE\n\n/// Bridges the thread-agnostic",
                (b"struct VortXWatchPartyAuthSnapshot:", b"enum VortXWatchPartyAuthCapturePolicy {",
                 b"final class VortXWatchPartyProfileEpoch:"))
            model, model_record = prefix(before[str(SOURCE / "WatchPartyRoomPanel.swift")],
                b"import SwiftUI\n", b"struct WatchPartyRoomPanel: View {\n",
                (b"@MainActor\nfinal class WatchPartyPanelModel: ObservableObject {",))
            auth_path, model_path = run / "AuthHelpers.swift", run / "WatchPartyPanelModel.swift"
            for path, data in ((auth_path, auth), (model_path, model)):
                with path.open("xb") as stream:
                    stream.write(data)
                if path.read_bytes() != data:
                    raise RuntimeError("generated genuine source readback failed")
            auth_record.update(sourcePath=str(SOURCE / "VortXSyncManager.swift"),
                               generatedPath=str(auth_path.relative_to(ROOT)))
            model_record.update(sourcePath=str(SOURCE / "WatchPartyRoomPanel.swift"),
                                generatedPath=str(model_path.relative_to(ROOT)))
            write_json(run / "sources.json", {"wholeSources": identities(before),
                "auth": auth_record, "model": model_record, "sourceRewritten": False})
            compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "swiftc"], text=True).strip()
            sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            flags = ["-j", "1", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                     "-target", platform.machine() + "-apple-macos13.0", "-parse-as-library",
                     "-D", "CREDENTIAL_RETRY_COORDINATOR_STANDALONE", "-D", "WATCH_PARTY_ASYNC_TESTS",
                     "-sdk", sdk, "-module-cache-path", str(cache.relative_to(ROOT))]
            result["toolchain"] = {"compiler": compiler, "sdk": sdk, "flags": flags}
            common = COMMON[:3] + [auth_path.relative_to(ROOT)] + COMMON[3:]
            suites = [
                ("session", common + HELPERS + [TESTS / "WatchPartyClientSessionAsyncTests.swift"]),
                ("model", common + [SOURCE / "WatchPartyReplayObligation.swift", SOURCE / "WatchPartyInviteLink.swift",
                                    model_path.relative_to(ROOT)] + HELPERS + [TESTS / "WatchPartyPanelModelAsyncTests.swift"])]
            for name, sources in suites:
                binary = run / (name + "-tests")
                commands = [(name + "-compile", [compiler] + flags + [str(path) for path in sources] +
                             ["-o", str(binary.relative_to(ROOT))]), (name + "-run", [str(binary)])]
                for label, argv in commands:
                    result["phase"] = label
                    log = run / (label + ".log")
                    with log.open("xb") as stream:
                        completed = subprocess.run(argv, cwd=ROOT, env=environment, stdout=stream,
                                                   stderr=subprocess.STDOUT, timeout=180)
                    result["steps"].append({"name": label, "exit": completed.returncode,
                                            "log": str(log.relative_to(ROOT))})
                    print(label + ": exit " + str(completed.returncode), flush=True)
                    if completed.returncode != 0:
                        print(log.read_text(errors="replace"), end="")
                        return 1
            result["exit"] = 0
            result["phase"] = "complete"
        finally:
            after = read_sources()
            result["sourcesConserved"] = identities(after) == identities(before)
            if not result["sourcesConserved"]:
                result["exit"] = 1
            write_json(run / "result.json", result)
            print("Retained regression receipt: " + str(run.relative_to(ROOT)), flush=True)
        return result["exit"]


if __name__ == "__main__":
    sys.exit(main())
