#!/usr/bin/env python3
"""Compile actual tvOS seek/watchdog methods with inert transport and scheduler ports."""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "app/Sources/Player/MPVMetalViewController.swift").read_text()


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


methods = [
    "func seek(to seconds:", "func seek(by seconds:",
    "private func seekTargetOutsideCache(", "private func armSeekCacheHold(",
    "private func releaseSeekCacheHoldIfArmed(", "private func armSeekRefillWatchdog(",
    "private func cancelSeekRefillWatchdog(", "private func scheduleSeekRefillWatchdogCheck(",
]
if "private func seekRefillCommandState(" in source:
    methods.append("private func seekRefillCommandState(")
if "private func releaseSeekCacheHoldAfterBuffering(" in source:
    methods.append("private func releaseSeekCacheHoldAfterBuffering(")
    assert "let rawSeekCommandGeneration = self.seekSettlement.lastAcceptedCommandGeneration" in source
    assert "owner: callbackToken, commandGeneration: rawSeekCommandGeneration," in source
    assert "seekObserved: rawSeekCommandObserved)" in source
fields_start = source.index("    private var seekCacheHoldArmed")
fields_end = source.index("    /// True when an absolute seek target", fields_start)
controller = source[fields_start:fields_end] + "\n" + "\n".join(
    declaration(source, marker) for marker in methods
)
# The extracted methods are the tvOS production path; only the platform gate changes.
controller = controller.replace("#if os(tvOS)", "#if !os(Windows)")
fixture = (root / "app/Tests/MPVSeekRefillControllerTests.swift").read_text()
fixture = fixture.replace("// EXTRACTED_CONTROLLER_METHODS", controller)
build = root / "app/build/mpv-seek-refill"
build.mkdir(parents=True, exist_ok=True)
(build / "ControllerTests.swift").write_text(fixture)
subprocess.run([
    "swiftc", "-parse-as-library", "-warnings-as-errors",
    str(root / "app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift"),
    str(build / "ControllerTests.swift"), "-o", str(build / "controller-tests")
], check=True)
sys.exit(subprocess.run([str(build / "controller-tests")], env=os.environ).returncode)
