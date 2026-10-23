#!/usr/bin/env python3
"""Run actual Apple watched/film-exit callsites with inert local ports (no player)."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
base = "eb8be9bef53733add963f86c55d0d2f3fd119282"
def read_source(path):
    if "--baseline" in sys.argv:
        return subprocess.check_output(["git", "-C", str(root), "show", base + ":" + path], text=True)
    return (root / path).read_text()
ios = read_source("app/Sources/PlayerScreen.swift")
tv = read_source("app/SourcesTV/TVPlayerView.swift")


def block(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


new_policy = "private func updateWatchedDwell(" in ios
if new_policy:
    ios_method = block(ios, "private func updateWatchedDwell(")
    tv_method = block(tv, "private func updateWatchedDwell(")
else:
    # The production iOS marker really is inside !scrubbing. Retain that guard.
    ios_mark = block(ios[ios.index("// ~90% in"):], "if assetSanityAccepted, !markedWatched,")
    ios_method = "private func updateWatchedDwell(with event: PlayerTimePositionEvent) { let d = event.seconds; let assetSanityAccepted = assetSanityAttempt.isAccepted(owner: event.loadToken); if !scrubbing { " + ios_mark + " } }"
    tv_start = tv.index("if assetSanityAccepted, !markedWatched, duration > 0, d / duration >= 0.9")
    tv_mark = block(tv[tv_start:], "if assetSanityAccepted")
    suffix = tv[tv_start + len(tv_mark):]
    tv_mark += " " + block(suffix, "else")
    tv_method = "private func updateWatchedDwell(with event: PlayerTimePositionEvent) { let d = event.seconds; let assetSanityAccepted = assetSanityAttempt.isAccepted(owner: event.loadToken); " + tv_mark + " }"
    # Preserve existing outer admission; stale-owner and nonfinite events never
    # reached the original marker. Do not manufacture a baseline failure there.
    for_source_guard = " guard event.loadToken == coordinator.player?.activeLoadToken, event.seconds.isFinite, event.seconds >= 0 else { return }; "
    ios_method = ios_method.replace("{ let d =", "{" + for_source_guard + "let d =", 1)
    tv_method = tv_method.replace("{ let d =", "{" + for_source_guard + "let d =", 1)

exit_mark = block(ios[ios.index("@MainActor private func leavePlayback()"):], "if !persistenceBlockedForExit, assetSanityAccepted, !effectivelyLive,")
eof_ios = block(ios[ios.index("case MPVProperty.endFileEof:"):], "if !markedWatched, !effectivelyLive, let m = curMeta")
eof_tv = block(tv[tv.index("case MPVProperty.endFileEof:"):], "if !markedWatched, let m = curMeta")
models = (root / "app/SourcesShared/CoreModels.swift").read_text()
fixture = (root / "app/Tests/WatchedPlaybackDwellCallsiteTests.swift").read_text()
fixture = fixture.replace("// MODELS", "\n".join(block(models, marker) for marker in ["struct PlayerLoadToken:", "struct PlayerTimePositionEvent:"]))
fixture = fixture.replace("// IOS_METHOD", ios_method).replace("// TV_METHOD", tv_method)
fixture = fixture.replace("// EXIT_MARK", exit_mark).replace("// IOS_EOF", eof_ios).replace("// TV_EOF", eof_tv)
fixture = fixture.replace("NEW_IMPLEMENTATION", str(new_policy).lower())
if not new_policy:
    fixture = fixture.replace("    var watchedDwell = WatchedPlaybackDwell<PlayerLoadToken>()\n", "")
    fixture = fixture.replace("watchedDwell.reset()", "")
if new_policy:
    # Pin integration boundaries too: fixture methods below are actual source,
    # while these assertions prevent a correct isolated helper from going unused.
    for source in (ios, tv):
        timepos = source[source.index("case MPVProperty.timePos:"):]
        assert "updateWatchedDwell(with: event)" in timepos[:2000]
        for marker in ("private func viewerPause()", "private func handleDeferredResumeUserSeek(", "private func resetRawPosition(", "private func resetRuntimeForIssuedSourceSwitch(", "private func resetRuntimeForIssuedEpisode("):
            assert "watchedDwell.reset()" in block(source, marker), marker
        for prop in ("pause", "pausedForCache", "duration"):
            section = source[source.index("case MPVProperty." + prop + ":"):]
            assert "watchedDwell.reset()" in section[:700]
    assert "watchedDwell.reset()" in ios[ios.index("onEditingChanged: { editing in"):][:250]
    assert "watchedDwell.reset()" in block(tv, "private func scrubBy(")
    assert "watchedZoneSince" not in tv
    # True EOF completion code is deliberately not part of this behavior change.
    for path, source in [("app/Sources/PlayerScreen.swift", ios), ("app/SourcesTV/TVPlayerView.swift", tv)]:
        original = subprocess.check_output(["git", "-C", str(root), "show", base + ":" + path], text=True)
        def eof_section(text):
            handler = block(text, "private func handleProperty(")
            tail = handler[handler.index("case MPVProperty.endFileEof:"):]
            return tail.split("\n        case ", 1)[0]
        assert eof_section(source) == eof_section(original), "Owned EOF admission/completion changed"
build = root / "app/build/watched-playback-dwell"
build.mkdir(parents=True, exist_ok=True)
(build / "CallsiteTests.swift").write_text(fixture)
sources = [root / "app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift"]
helper = root / "app/SourcesShared/WatchedPlaybackDwell.swift"
if new_policy:
    sources.append(helper)
subprocess.run(["swiftc", "-parse-as-library", *map(str, sources), str(build / "CallsiteTests.swift"), "-o", str(build / "tests")], check=True)
sys.exit(subprocess.run([str(build / "tests")]).returncode)
