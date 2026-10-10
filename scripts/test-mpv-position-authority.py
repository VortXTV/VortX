#!/usr/bin/env python3
"""Exercise the real queued emit path with production position, provenance and seek policies."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "app/Sources/Player/MPVMetalViewController.swift").read_text()
models = (root / "app/SourcesShared/CoreModels.swift").read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


methods = ["private func acceptsCurrentSeekEvent(", "private func acceptsSettledPosition(", "private func emit("]
if "private func acceptsCurrentPosition(" in source:
    methods.append("private func acceptsCurrentPosition(")
fixture = (root / "app/Tests/MPVPositionAuthorityControllerTests.swift").read_text()
fixture = fixture.replace("// EXTRACTED_MODELS", "\n".join(declaration(models, marker) for marker in [
    "struct PlayerLoadToken:", "struct PlayerTimePositionEvent:", "struct PlayerLoadProvenanceState {"
]))
fixture = fixture.replace("// EXTRACTED_CONTROLLER_METHODS", "\n".join(declaration(source, marker) for marker in methods))
build = root / "app/build/mpv-position-authority"
build.mkdir(parents=True, exist_ok=True)
(build / "ControllerTests.swift").write_text(fixture)
subprocess.run([
    "swiftc", "-parse-as-library", "-warnings-as-errors",
    str(root / "app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift"),
    str(build / "ControllerTests.swift"), "-o", str(build / "controller-tests")
], check=True)
sys.exit(subprocess.run([str(build / "controller-tests")]).returncode)
