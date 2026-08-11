// Source contract for the bounded Apple subtitle-timing lifecycle.
//
// Run from this worktree:
//
//   swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/Tests/SubtitleTimingSurfaceContractTests.swift \
//     -o /tmp/subtitle-timing-surface-contract && /tmp/subtitle-timing-surface-contract
//
// This is intentionally a source contract rather than a SwiftUI unit test. The app has no unit-test
// bundle for these two large surfaces, so the contract pins the exact ownership seams and also runs
// hostile in-memory mutants. A mutant must change the checked source and make its relevant predicate fail.

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func source(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func containsInOrder(_ value: String, _ needles: [String]) -> Bool {
    var cursor = value.startIndex
    for needle in needles {
        guard let range = value.range(of: needle, range: cursor..<value.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

private func functionSection(_ value: String, _ marker: String) -> String {
    guard let start = value.range(of: marker) else { return "" }
    let tail = value[start.lowerBound..<value.endIndex]
    let end = tail.range(of: "\n    private ", range: tail.index(after: tail.startIndex)..<tail.endIndex)?.lowerBound
        ?? tail.endIndex
    return String(tail[..<end])
}

private func structureSection(_ value: String, _ marker: String, _ endMarker: String) -> String {
    guard let start = value.range(of: marker),
          let end = value.range(of: endMarker, range: start.upperBound..<value.endIndex) else {
        return ""
    }
    return String(value[start.lowerBound..<end.lowerBound])
}

private func replaceFirstAfter(
    _ value: String,
    marker: String,
    old: String,
    with replacement: String
) -> String {
    guard let markerRange = value.range(of: marker),
          let targetRange = value.range(
            of: old,
            range: markerRange.upperBound..<value.endIndex
          ) else {
        return value
    }
    return value.replacingCharacters(in: targetRange, with: replacement)
}

private func insertAfter(_ value: String, marker: String, insertion: String) -> String {
    guard let markerRange = value.range(of: marker) else { return value }
    return value.replacingCharacters(
        in: markerRange.upperBound..<markerRange.upperBound,
        with: insertion
    )
}

private struct TestCoreStream {
    let releaseDescription: String
}

private struct LateIdentityTimingModel {
    let storedScope = "imdb:tt0000001:1:1|release-a"
    let activeLoadToken = "load-1"
    var scope: String?
    var pendingAdvance = false
    var stagedScope: String?
    var tracksApplied = false
    var pooledSeededOffset = false
    var subDelay = 0.0
    var generation = 0
    var appliedLoadToken: String?
    var restoreCount = 0
    var applyCount = 0

    mutating func sourceEpoch(stream: TestCoreStream?) {
        guard !pendingAdvance else { return }
        if scope == nil, let stream, !stream.releaseDescription.isEmpty {
            scope = "imdb:tt0000001:1:1|\(stream.releaseDescription)"
        }
        guard tracksApplied else { return }
        if !pooledSeededOffset, scope == storedScope {
            subDelay = 3.4
            pooledSeededOffset = true
            restoreCount += 1
        }
        guard subDelay != 0, appliedLoadToken != activeLoadToken else { return }
        appliedLoadToken = activeLoadToken
        applyCount += 1
    }
}

private struct ReplacementIdentityModel {
    let launchMeta = "E1"
    var currentMeta: String?
    var pendingMeta: String?

    var replacementMeta: String? {
        pendingMeta ?? currentMeta
    }

    mutating func commit(_ meta: String) {
        currentMeta = meta
    }
}

private func acceptedReplacementContract(_ value: String) -> Bool {
    let helper = functionSection(value, "private func acceptSubtitleTimingReplacement")
    return containsInOrder(helper, [
        "flushPendingSubOffsetSave()",
        "offsetCaptureTask?.cancel()",
        "offsetCaptureTask = nil",
        "subtitleTimingGeneration &+= 1",
        "subtitleTimingScope = scope",
        "let savedOffset = SubtitleOffsetMemory.savedOffset(for: scope)",
        "subDelay = savedOffset ?? 0",
        "pooledSeededOffset = savedOffset != nil",
        "subtitleDelayAppliedLoadToken = nil",
        "coordinator.player?.setSubDelay(0)"
    ])
}

private func trackListContract(_ value: String) -> Bool {
    let handler = structureSection(value, "case MPVProperty.trackList:", "case MPVProperty.endFileError:")
    return containsInOrder(handler, [
        "autoSelectTracks()",
        "}\n            applyCurrentSubtitleDelayIfReady(force: false)"
    ])
}

private func applyContract(_ value: String) -> Bool {
    let helper = functionSection(value, "private func applyCurrentSubtitleDelayIfReady")
    return containsInOrder(helper, [
        "let loadToken = player.activeLoadToken",
        "subtitleDelayAppliedLoadToken == loadToken",
        "player.setSubDelay(subDelay)",
        "subtitleDelayAppliedLoadToken = loadToken"
    ])
}

private func pendingContract(_ value: String) -> Bool {
    let pending = structureSection(value, "private struct PendingEpisodeAdvance", "private struct EpisodeSourceSnapshot")
    let commit = functionSection(value, "private func commitPendingAdvanceOnFirstFrame")
    return pending.contains("var subtitleTimingScope: SubtitleTimingScope? = nil")
        && value.contains("pendingAdvance?.subtitleTimingScope =")
        && containsInOrder(commit, [
            "let acceptedSubtitleTimingScope = pending.subtitleTimingScope",
            "curMeta",
            "acceptSubtitleTimingReplacement(scope: acceptedSubtitleTimingScope, clearNewEngineDelay: false)",
            "deferredTrackList"
        ])
}

private func preservationContract(_ value: String) -> Bool {
    let names = [
        "private func retryLoad",
        "private func retryResumeSameSource",
        "private func demoteAVPlayerToMPV",
        "private func switchPlayerEngine",
        "private func liveMountURL",
        "private func recoverFromStall",
        "private func refreshSubFingerprint"
    ]
    return names.allSatisfy { !functionSection(value, $0).contains("acceptSubtitleTimingReplacement") }
}

private func lateIdentityContract(_ value: String, requiresRefresh: Bool) -> Bool {
    let establish = functionSection(value, "private func establishSubtitleTimingScopeIfAvailable")
    let body = functionSection(value, "var body: some View")
    let triggerNeedles = requiresRefresh
        ? [
            ".onChange(of: core.streamsEpoch)",
            "refreshSourceOptionCounts()",
            "establishSubtitleTimingScopeIfAvailable()",
            "if appliedAutoTracks",
            "restoreSubtitleTimingOffsetIfReady()",
            "applyCurrentSubtitleDelayIfReady(force: false)"
        ]
        : [
            ".onChange(of: core.streamsEpoch)",
            "establishSubtitleTimingScopeIfAvailable()",
            "if appliedAutoTracks",
            "restoreSubtitleTimingOffsetIfReady()",
            "applyCurrentSubtitleDelayIfReady(force: false)"
    ]
    return containsInOrder(establish, [
        "guard pendingAdvance == nil else { return }",
        "guard subtitleTimingScope == nil else { return }",
        "subtitleTimingScope = subtitleTimingScope(",
        "for: curMeta,"
    ])
        && !establish.contains("pendingAdvance?.meta")
        && containsInOrder(body, triggerNeedles)
        && !body.contains("subtitleTimingGeneration")
        && !body.contains("setSubDelay(0)")
}

private func subtitleCompletionContract(_ value: String) -> Bool {
    let autoAddon = functionSection(value, "private func autoSelectAddonSubtitleIfNeeded")
    let pooled = functionSection(value, "private func selectPooledSubtitle")
    let reapply = functionSection(value, "private func reapplySubtitleChoice")
    let apply = "applyCurrentSubtitleDelayIfReady(force: false)"
    return autoAddon.contains(apply) && pooled.contains(apply) && reapply.contains(apply)
}

private func surfaceContract(_ value: String, requiresPublishedCurrentMeta: Bool = false) -> Bool {
    guard acceptedReplacementContract(value), trackListContract(value), applyContract(value), pendingContract(value),
          preservationContract(value), subtitleCompletionContract(value) else { return false }

    let memoryUse = value.contains("SubtitleOffsetMemory.savedOffset(for: scope")
        && value.contains("SubtitleOffsetMemory.save(pending.delay, for: pending.scope)")
        && !value.contains("savedOffset(forContentKey")
        && !value.contains("save(_ seconds: Double, forContentKey")
    guard memoryUse else { return false }

    let switchSection = functionSection(value, "private func switchStream")
    guard switchSection.contains("acceptSubtitleTimingReplacement(scope:") else { return false }
    if requiresPublishedCurrentMeta {
        guard containsInOrder(switchSection, [
            "let acceptedSubtitleTimingScope = subtitleTimingScope(",
            "for: pendingAdvance?.meta ?? curMeta,"
        ]), !switchSection.contains("recordMeta ?? curMeta") else { return false }
    }

    let engineSection = functionSection(value, "private func switchPlayerEngine")
    guard engineSection.contains("Task.sleep(for: .milliseconds(700))"),
          engineSection.contains("setSpeed"),
          !engineSection.contains("setSubDelay") else { return false }

    let adjust = functionSection(value, "private func adjustSubDelay")
    guard containsInOrder(adjust, [
        "pooledSeededOffset = true",
        "applyCurrentSubtitleDelayIfReady(force: true)",
        "scheduleSubOffsetSave()"
    ]), value.contains("adjustSubDelay(-subDelay)") else { return false }

    let scopeBuilder = functionSection(value, "private func subtitleTimingScope")
    let forbidden = ["curURL", "launch", "debrid", "host", "path", "port", "curTitle", "sourceLabel", "duration", "frameRate"]
    guard containsInOrder(scopeBuilder, [
        "let releaseDescription = StreamRanking.signature(stream)",
        ".trimmingCharacters(in: .whitespacesAndNewlines)",
        "guard !releaseDescription.isEmpty",
        "releaseDescription.caseInsensitiveCompare(\"unknown\") != .orderedSame",
        "let releaseFingerprint = SubtitleReleaseFingerprint.releaseFingerprint("
    ]),
          forbidden.allSatisfy({ !scopeBuilder.contains($0) }) else { return false }

    let contentBuilder = functionSection(value, "private func communityContentKey(for targetMeta: PlaybackMeta?)")
    guard !contentBuilder.isEmpty else { return false }

    let pool = functionSection(value, "private func fetchPooledSubtitles")
    guard containsInOrder(pool, [
        "let poolTimingScope = SubtitleTimingScope(",
        "let capturedTimingGeneration = subtitleTimingGeneration",
        "capturedTimingGeneration == subtitleTimingGeneration",
        "if let poolTimingScope, !pooledSeededOffset",
        "poolTimingScope == SubtitleTimingScope("
    ]) else { return false }

    let capture = functionSection(value, "private func captureSubOffset")
    guard capture.contains("guard let capturedTimingScope = SubtitleTimingScope("),
          containsInOrder(capture, [
        "let capturedTimingScope = SubtitleTimingScope(",
        "let capturedTimingGeneration = subtitleTimingGeneration",
        "capturedTimingGeneration == subtitleTimingGeneration",
        "capturedTimingScope == SubtitleTimingScope(",
        "postOffset(contentKey: capturedContentKey",
        "fingerprint: capturedFingerprint"
    ]) else { return false }

    return value.contains("var subtitleTimingGeneration = 0")
        && value.contains("@State private var subtitleDelayAppliedLoadToken: PlayerLoadToken?")
        && !functionSection(value, "private func resetRuntimeForIssuedSourceSwitch").contains("pooledSeededOffset = false")
        && lateIdentityContract(
            value,
            requiresRefresh: value.contains("refreshSourceOptionCounts()")
        )
}

@MainActor private func requireRejectedMutant(
    _ name: String,
    original: String,
    requiresPublishedCurrentMeta: Bool = false,
    mutation: (String) -> String
) {
    let changed = mutation(original)
    let enforcePublishedCurrentMeta = requiresPublishedCurrentMeta
        || original.contains("for: pendingAdvance?.meta ?? curMeta,")
    check(changed != original, "\(name) mutant changed source")
    check(
        !surfaceContract(changed, requiresPublishedCurrentMeta: enforcePublishedCurrentMeta),
        "\(name) mutant rejected"
    )
}

@MainActor @main
enum SubtitleTimingSurfaceContractTests {
    static func main() {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let app = tests.deletingLastPathComponent()
        let player = app.appendingPathComponent("Sources/Player")
        let scopeSource = source(player.appendingPathComponent("SubtitleTimingScope.swift"))
        let memorySource = source(player.appendingPathComponent("SubtitleOffsetMemory.swift"))
        let tvSource = source(app.appendingPathComponent("SourcesTV/TVPlayerView.swift"))
        let iOSSource = source(app.appendingPathComponent("Sources/PlayerScreen.swift"))

        check(scopeSource.contains("struct SubtitleTimingScope: Hashable, Sendable"), "scope is Hashable and Sendable")
        check(scopeSource.contains("init?(contentKey: String?, releaseFingerprint: String?)"), "scope initializer is failable")
        check(scopeSource.contains("caseInsensitiveCompare(\"unknown\")"), "scope rejects unknown identities")
        check(scopeSource.contains("var storageKey: String"), "scope exposes a composite storage key")

        check(memorySource.contains("storeKey = \"vortx.subtitleOffsetMemory.v2\""), "memory is v2")
        check(memorySource.contains("savedOffset(for scope: SubtitleTimingScope?)"), "memory reads a full scope")
        check(memorySource.contains("save(_ seconds: Double, for scope: SubtitleTimingScope?)"), "memory writes a full scope")
        check(memorySource.contains("scope.storageKey"), "memory keys by the composite scope")
        check(!memorySource.contains("savedOffset(forContentKey"), "memory has no v1 read API")
        check(!memorySource.contains("forContentKey"), "memory has no content-only fallback")

        check(surfaceContract(tvSource), "tvOS surface timing contract")
        check(
            surfaceContract(iOSSource, requiresPublishedCurrentMeta: true),
            "iOS/Mac surface timing contract"
        )

        for (surfaceName, surface) in [("tvOS", tvSource), ("iOS/Mac", iOSSource)] {
            requireRejectedMutant(
                "01 \(surfaceName) accepted-engine-zero",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func acceptSubtitleTimingReplacement",
                        old: "coordinator.player?.setSubDelay(0)",
                        with: "coordinator.player?.setSubDelay(subDelay)"
                    )
                }
            )
            requireRejectedMutant(
                "02 \(surfaceName) content-only-memory",
                original: surface,
                mutation: {
                    $0.replacingOccurrences(
                        of: "SubtitleOffsetMemory.save(pending.delay, for: pending.scope)",
                        with: "SubtitleOffsetMemory.save(pending.delay, forContentKey: nil)"
                    )
                }
            )
            requireRejectedMutant(
                "03 \(surfaceName) pending-scope-field",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private struct PendingEpisodeAdvance",
                        old: "var subtitleTimingScope: SubtitleTimingScope? = nil",
                        with: "var stagedTimingScope: SubtitleTimingScope? = nil"
                    )
                }
            )
            requireRejectedMutant(
                "04 \(surfaceName) preservation-helper-leak",
                original: surface,
                mutation: {
                    insertAfter(
                        $0,
                        marker: "private func retryLoad",
                        insertion: "\n        acceptSubtitleTimingReplacement(scope: nil)\n"
                    )
                }
            )
            requireRejectedMutant(
                "05 \(surfaceName) track-ready-apply-removal",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "case MPVProperty.trackList:",
                        old: "applyCurrentSubtitleDelayIfReady(force: false)",
                        with: "// track-ready apply removed"
                    )
                }
            )
            requireRejectedMutant(
                "05b \(surfaceName) pooled-completion-reapply",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func selectPooledSubtitle",
                        old: "applyCurrentSubtitleDelayIfReady(force: false)",
                        with: "// pooled completion apply removed"
                    )
                }
            )
            requireRejectedMutant(
                "05c \(surfaceName) addon-completion-reapply",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func autoSelectAddonSubtitleIfNeeded",
                        old: "applyCurrentSubtitleDelayIfReady(force: false)",
                        with: "// add-on completion apply removed"
                    )
                }
            )
            requireRejectedMutant(
                "05d \(surfaceName) external-completion-reapply",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func reapplySubtitleChoice",
                        old: "applyCurrentSubtitleDelayIfReady(force: false)",
                        with: "// external completion apply removed"
                    )
                }
            )
            let speedLine = surfaceName == "tvOS"
                ? "if abs(playSpeed - 1.0) > 0.01 { coordinator.player?.setSpeed(playSpeed) }"
                : "if abs(speed - 1.0) > 0.01 { coordinator.player?.setSpeed(speed) }"
            requireRejectedMutant(
                "06 \(surfaceName) engine-switch-delay-write",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func switchPlayerEngine",
                        old: speedLine,
                        with: "\(speedLine)\n            coordinator.player?.setSubDelay(subDelay)"
                    )
                }
            )
            requireRejectedMutant(
                "07 \(surfaceName) token-duplicate-gate",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func applyCurrentSubtitleDelayIfReady",
                        old: "subtitleDelayAppliedLoadToken == loadToken",
                        with: "false"
                    )
                }
            )
            requireRejectedMutant(
                "08 \(surfaceName) reset-seed-closure",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func adjustSubDelay",
                        old: "pooledSeededOffset = true",
                        with: "// pooled seed latch removed"
                    )
                }
            )
            requireRejectedMutant(
                "09a \(surfaceName) pool-generation-fence",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func fetchPooledSubtitles",
                        old: "let timingGenerationMatches = capturedTimingGeneration == subtitleTimingGeneration",
                        with: "let timingGenerationMatches = true"
                    )
                }
            )
            requireRejectedMutant(
                "09b \(surfaceName) capture-full-scope-fence",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func captureSubOffset",
                        old: "capturedTimingScope == SubtitleTimingScope(",
                        with: "communityContentKey == capturedContentKey"
                    )
                }
            )
            requireRejectedMutant(
                "09c \(surfaceName) pool-full-scope-fence",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func fetchPooledSubtitles",
                        old: "poolTimingScope == SubtitleTimingScope(",
                        with: "communityContentKey == contentKey"
                    )
                }
            )
            requireRejectedMutant(
                "10a \(surfaceName) raw-unknown-builder",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func subtitleTimingScope",
                        old: "releaseDescription.caseInsensitiveCompare(\"unknown\") != .orderedSame",
                        with: "true"
                    )
                }
            )
            requireRejectedMutant(
                "10b \(surfaceName) raw-unknown-capture-post",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func captureSubOffset",
                        old: "guard let capturedTimingScope = SubtitleTimingScope(",
                        with: "let capturedTimingScope = SubtitleTimingScope("
                    )
                }
            )
            requireRejectedMutant(
                "10c \(surfaceName) raw-unknown-pool-seed",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func fetchPooledSubtitles",
                        old: "if let poolTimingScope, !pooledSeededOffset",
                        with: "if !pooledSeededOffset"
                    )
                }
            )
            requireRejectedMutant(
                "11 \(surfaceName) unstable-builder-authority",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func subtitleTimingScope",
                        old: "let releaseDescription = StreamRanking.signature(stream)",
                        with: "let releaseDescription = curURL?.absoluteString ?? \"\""
                    )
                }
            )
            requireRejectedMutant(
                "12 \(surfaceName) outgoing-save-flush",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func acceptSubtitleTimingReplacement",
                        old: "flushPendingSubOffsetSave()",
                        with: "// outgoing save flush removed"
                    )
                }
            )
            requireRejectedMutant(
                "H2 \(surfaceName) source-epoch-trigger",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "var body: some View",
                        old: ".onChange(of: core.streamsEpoch)",
                        with: ".onChange(of: core.sourceEpoch)"
                    )
                }
            )
            requireRejectedMutant(
                "H2 \(surfaceName) late-restore-path",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: ".onChange(of: core.streamsEpoch)",
                        old: "restoreSubtitleTimingOffsetIfReady()",
                        with: "// late restore removed"
                    )
                }
            )
            requireRejectedMutant(
                "H3 \(surfaceName) pending-late-identity-guard",
                original: surface,
                mutation: {
                    replaceFirstAfter(
                        $0,
                        marker: "private func establishSubtitleTimingScopeIfAvailable",
                        old: "guard pendingAdvance == nil else { return }",
                        with: "// pending late-identity guard removed"
                    )
                }
            )
        }

        requireRejectedMutant(
            "H4 iOS/Mac launch-metadata replacement-fallback",
            original: iOSSource,
            requiresPublishedCurrentMeta: true,
            mutation: {
                replaceFirstAfter(
                    $0,
                    marker: "private func switchStream",
                    old: "for: pendingAdvance?.meta ?? curMeta,",
                    with: "for: pendingAdvance?.meta ?? (recordMeta ?? curMeta),"
                )
            }
        )

        for surfaceName in ["tvOS", "iOS/Mac"] {
            if surfaceName == "iOS/Mac" {
                var replacementModel = ReplacementIdentityModel()
                replacementModel.currentMeta = replacementModel.launchMeta
                replacementModel.commit("E2")
                check(
                    replacementModel.pendingMeta == nil
                        && replacementModel.replacementMeta == "E2",
                    "iOS/Mac post-advance replacement uses committed current metadata"
                )
            }

            var pendingModel = LateIdentityTimingModel()
            pendingModel.pendingAdvance = true
            pendingModel.stagedScope = pendingModel.storedScope
            pendingModel.tracksApplied = true
            pendingModel.sourceEpoch(stream: TestCoreStream(releaseDescription: "release-a"))
            check(
                pendingModel.scope == nil
                    && pendingModel.subDelay == 0
                    && pendingModel.restoreCount == 0
                    && pendingModel.applyCount == 0
                    && pendingModel.generation == 0
                    && pendingModel.stagedScope == pendingModel.storedScope,
                "\(surfaceName) pending source epoch cannot establish or apply staged identity"
            )

            var model = LateIdentityTimingModel()
            model.tracksApplied = true
            model.sourceEpoch(stream: nil)
            check(
                model.scope == nil && model.applyCount == 0,
                "\(surfaceName) late identity stays unavailable before source arrival"
            )
            model.sourceEpoch(stream: TestCoreStream(releaseDescription: "release-a"))
            check(
                model.scope == model.storedScope
                    && model.subDelay == 3.4
                    && model.restoreCount == 1
                    && model.appliedLoadToken == model.activeLoadToken
                    && model.applyCount == 1
                    && model.generation == 0,
                "\(surfaceName) late identity restores and applies on the active token"
            )
            model.sourceEpoch(stream: TestCoreStream(releaseDescription: "release-a"))
            check(
                model.restoreCount == 1
                    && model.applyCount == 1
                    && model.generation == 0,
                "\(surfaceName) repeated source epoch is idempotent"
            )
        }

        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
