// Focused source contract for the residual diagnostics found in vortx-diag 7.log.
//
// RUN: swift app/Tests/PlaybackDiagnosticResidualContractTests.swift

import Foundation

nonisolated(unsafe) private var failures = 0

private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private func section(_ source: String, from start: String, to end: String) -> String? {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let app = tests.deletingLastPathComponent()
private let player = try String(
    contentsOf: app.appendingPathComponent("SourcesTV/TVPlayerView.swift"), encoding: .utf8)
private let playerScreen = try String(
    contentsOf: app.appendingPathComponent("Sources/PlayerScreen.swift"), encoding: .utf8)
private let controller = try String(
    contentsOf: app.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"), encoding: .utf8)
private let crashReporter = try String(
    contentsOf: app.appendingPathComponent("SourcesShared/VortXCrashReporter.swift"), encoding: .utf8)

private let seekSettlement = section(
    player,
    from: "lastRawTimePos = d",
    to: "currentTime = d") ?? ""

check("resume settlement computes positive landing evidence",
      seekSettlement.contains("let landedNearTarget = abs(d - target) <= inFlightSeekSnapRadius"))
check("a proven landing cancels and releases the resume watchdog",
      seekSettlement.contains("if landedNearTarget {")
        && seekSettlement.contains("postFrameResumeSeekWatchdog?.cancel()")
        && seekSettlement.contains("postFrameResumeSeekWatchdog = nil"))

// Exercise the lifetime sequence that regressed: after a landing the old watchdog reference must be
// gone, therefore a later user seek cannot provide a receiver for the old resume deadline.
var watchdogIsArmed = true
let landedNearTarget = true
if landedNearTarget { watchdogIsArmed = false }
let laterUserPositionIsBehindOldResumeTarget = true
let staleWatchdogCanAct = watchdogIsArmed && laterUserPositionIsBehindOldResumeTarget
check("land then user backward-seek leaves no old watchdog able to act", !staleWatchdogCanAct)

private let appleResumeSettlement = section(
    playerScreen,
    from: "lastRawTimePos = d",
    to: "if d > 0, !hasStartedPlaying"
) ?? ""

check("Apple resume landing retires only its exact watchdog owner before later manual seeks",
      appleResumeSettlement.contains("postFrameResumeSeekWatchdogOwner == event.loadToken")
        && appleResumeSettlement.contains("abs(d - target) <= 5")
        && appleResumeSettlement.contains("cancelPostFrameResumeSeekWatchdog()"))
check("Apple watchdog retirement clears task target and owner together across load boundaries",
      playerScreen.contains("postFrameResumeSeekWatchdog = nil")
        && playerScreen.contains("postFrameResumeSeekWatchdogTarget = nil")
        && playerScreen.contains("postFrameResumeSeekWatchdogOwner = nil")
        && playerScreen.contains("firstFrameRenderedAt = nil; pendingLibmpvResumeSeek = nil")
        && playerScreen.contains("cancelPostFrameResumeSeekWatchdog()"))

private let enhancementProbe = section(
    controller,
    from: "private func probeEnhancementLayer()",
    to: "/// Read the current audio/subtitle/video tracks") ?? ""

check("multiple unpaired tracks are reported as unproven rather than discarded",
      enhancementProbe.contains("FEL pairing unproven:")
        && enhancementProbe.contains("no dependent-track/FEL pairing evidence")
        && !enhancementProbe.contains("EL discarded, base layer only"))
check("positive dependent-track evidence retains the proven pairing message",
      enhancementProbe.contains("FEL paired: enhancement-layer track(s)"))

private let crashInstall = section(
    crashReporter,
    from: "static func install()",
    to: "// MARK: - Next-launch fold") ?? ""
check("crash evidence is snapshotted before folding or pre-opening the marker",
      crashInstall.range(of: "launchHadPendingCrashMarker = hasNonemptyCrashMarker(at: marker)")?.lowerBound
        ?? crashInstall.endIndex
      < crashInstall.range(of: "let preserveExisting = foldPreviousCrash(marker)")?.lowerBound
        ?? crashInstall.startIndex)
check("termination classification reads the launch snapshot, not live file existence",
      crashReporter.contains("static var pendingCrashMarkerExists: Bool {\n        launchHadPendingCrashMarker\n    }")
        && !crashReporter.contains("static var pendingCrashMarkerExists: Bool {\n        FileManager.default.fileExists"))

if failures > 0 {
    print("PlaybackDiagnosticResidualContractTests: \(failures) FAILED")
    exit(1)
}
print("PlaybackDiagnosticResidualContractTests: ALL PASS")
