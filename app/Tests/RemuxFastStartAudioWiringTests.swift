// Focused production-wiring and hostile-mutation contract for initial remux audio selection.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/remux-fast-start-audio-wiring-test \
//     app/Tests/RemuxFastStartAudioWiringTests.swift && \
//     /tmp/remux-fast-start-audio-wiring-test
//
// Pure behavior is executed by MultiAudioPolicyTests and DVPlaybackContractTests. This suite covers the
// framework and FFmpeg call sites that cannot participate in those standalone binaries. Every rule includes
// one hostile source mutation and proves the governed wiring turns red.

import Foundation

private struct WiringRule {
    let name: String
    let relativePath: String
    let start: String
    let end: String
    let required: [String]
    let mutationTarget: String
    let mutationReplacement: String
}

private func compact(_ source: String) -> String {
    source.filter { !$0.isWhitespace }
}

private func section(_ source: String, from start: String, to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func passes(_ rule: WiringRule, source: String) -> Bool {
    guard let scoped = section(source, from: rule.start, to: rule.end) else { return false }
    var remainder = compact(scoped)[...]
    for required in rule.required {
        guard let match = remainder.range(of: compact(required)) else { return false }
        remainder = remainder[match.upperBound...]
    }
    return true
}

private func applyingMutation(_ rule: WiringRule, to source: String) -> String? {
    guard let scopedRange = source.range(of: rule.start)
        .flatMap({ start in
            source.range(of: rule.end, range: start.upperBound..<source.endIndex).map {
                start.lowerBound..<$0.lowerBound
            }
        }),
          let target = source.range(of: rule.mutationTarget, range: scopedRange) else {
        return nil
    }
    var mutated = source
    mutated.replaceSubrange(target, with: rule.mutationReplacement)
    return mutated
}

@MainActor private enum Harness {
    static var failures = 0
}

@MainActor private func check(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        Harness.failures += 1
        print("FAIL  \(name)")
    }
}

@MainActor @main
enum RemuxFastStartAudioWiringTests {
    static func main() {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rules = [
            WiringRule(
                name: "policy explicit source precedence",
                relativePath: "Sources/Player/MultiAudioPolicy.swift",
                start: "static func initialSourceTrack(",
                end: "/// Canonical base language",
                required: ["return explicit"],
                mutationTarget: "return explicit",
                mutationReplacement: "return nil"),
            WiringRule(
                name: "policy canonical language matching",
                relativePath: "Sources/Player/MultiAudioPolicy.swift",
                start: "static func initialSourceTrack(",
                end: "/// Canonical base language",
                required: ["canonicalLanguage($0.language) == language"],
                mutationTarget: "canonicalLanguage($0.language) == language",
                mutationReplacement: "languageKey($0.language) == language"),
            WiringRule(
                name: "initial policy uses the shared audio-language canonicalizer",
                relativePath: "Sources/Player/MultiAudioPolicy.swift",
                start: "static func canonicalLanguage(",
                end: "private static func initialTrackRanksBefore(",
                required: ["AudioLanguagePolicy.canonical(raw)"],
                mutationTarget: "AudioLanguagePolicy.canonical(raw)",
                mutationReplacement: "raw.lowercased()"),
            WiringRule(
                name: "post-load selector uses the shared audio-language canonicalizer",
                relativePath: "Sources/Player/TrackSelector.swift",
                start: "static func canonical(_ code: String)",
                end: "\n}",
                required: ["AudioLanguagePolicy.canonical(code)"],
                mutationTarget: "AudioLanguagePolicy.canonical(code)",
                mutationReplacement: "String(code.prefix(2))"),
            WiringRule(
                name: "policy reject-term enforcement",
                relativePath: "Sources/Player/MultiAudioPolicy.swift",
                start: "static func initialSourceTrack(",
                end: "/// Canonical base language",
                required: ["!rejected.contains { title.contains($0) }"],
                mutationTarget: "!rejected.contains { title.contains($0) }",
                mutationReplacement: "true"),
            WiringRule(
                name: "policy Atmos precedence",
                relativePath: "Sources/Player/MultiAudioPolicy.swift",
                start: "private static func initialTrackRanksBefore(",
                end: "/// Selects the one metadata-qualified alternate",
                required: ["if lhsAtmos != rhsAtmos { return lhsAtmos }"],
                mutationTarget: "if lhsAtmos != rhsAtmos { return lhsAtmos }",
                mutationReplacement: "if lhsAtmos != rhsAtmos { return rhsAtmos }"),
            WiringRule(
                name: "policy stream-copy precedence",
                relativePath: "Sources/Player/MultiAudioPolicy.swift",
                start: "private static func initialTrackRanksBefore(",
                end: "/// Selects the one metadata-qualified alternate",
                required: [
                    "if lhs.isStreamCopy != rhs.isStreamCopy { return lhs.isStreamCopy }",
                ],
                mutationTarget:
                    "if lhs.isStreamCopy != rhs.isStreamCopy { return lhs.isStreamCopy }",
                mutationReplacement:
                    "if lhs.isStreamCopy != rhs.isStreamCopy { return rhs.isStreamCopy }"),
            WiringRule(
                name: "protocol optional preference compatibility",
                relativePath: "SourcesShared/VortXEngineProtocol.swift",
                start: "struct SessionRequest:",
                end: "struct SessionResponse:",
                required: [
                    "let preferredAudioLanguages: [String]?",
                    "let audioRejectTerms: [String]?",
                ],
                mutationTarget: "let preferredAudioLanguages: [String]?",
                mutationReplacement: "let preferredAudioLanguages: [String]"),
            WiringRule(
                name: "protocol preference input bounds",
                relativePath: "SourcesShared/VortXEngineProtocol.swift",
                start: "static func normalizedAudioSelectionPreferences(",
                end: "struct SessionRequest:",
                required: [
                    "rawValues.count <= maximumAudioPreferenceCount",
                    "raw.unicodeScalars.count <= maximumAudioPreferenceScalars",
                    "seen.insert(normalized).inserted",
                ],
                mutationTarget: "rawValues.count <= maximumAudioPreferenceCount",
                mutationReplacement: "true"),
            WiringRule(
                name: "client protocol payload forwarding",
                relativePath: "SourcesShared/VortXExternalEngine.swift",
                start: "func openSession(",
                end: "func status(",
                required: [
                    "preferredAudioLanguages: [String]? = nil",
                    "audioRejectTerms: [String]? = nil",
                    "preferredAudioLanguages: preferredAudioLanguages",
                    "audioRejectTerms: audioRejectTerms",
                ],
                mutationTarget: "preferredAudioLanguages: preferredAudioLanguages",
                mutationReplacement: "preferredAudioLanguages: nil"),
            WiringRule(
                name: "remote mount preference forwarding",
                relativePath: "Sources/Player/VortXRemoteRemuxMount.swift",
                start: "static func open(",
                end: "/// Begin steady-state polling",
                required: [
                    "preferredAudioLanguages: preferredAudioLanguages",
                    "audioRejectTerms: audioRejectTerms",
                ],
                mutationTarget: "audioRejectTerms: audioRejectTerms",
                mutationReplacement: "audioRejectTerms: nil"),
            WiringRule(
                name: "host preference forwarding",
                relativePath: "SourcesShared/VortXEngineHost.swift",
                start: "private func handleCreateSession(",
                end: "private func handleStatus(",
                required: [
                    "VortXEngineProtocol.normalizedAudioSelectionPreferences(",
                    "preferredLanguages: request.preferredAudioLanguages",
                    "rejectTerms: request.audioRejectTerms",
                    "preferredAudioLanguages: audioPreferences.preferredLanguages",
                    "audioRejectTerms: audioPreferences.rejectTerms",
                ],
                mutationTarget: "preferredAudioLanguages: audioPreferences.preferredLanguages",
                mutationReplacement: "preferredAudioLanguages: request.preferredAudioLanguages"),
            WiringRule(
                name: "HLS server preference forwarding",
                relativePath: "Sources/Player/VortXRemuxHLSServer.swift",
                start: "static func make(input:",
                end: "private init?(stream:",
                required: [
                    "preferredAudioLanguages: preferredAudioLanguages",
                    "audioRejectTerms: audioRejectTerms",
                ],
                mutationTarget: "audioRejectTerms: audioRejectTerms",
                mutationReplacement: "audioRejectTerms: nil"),
            WiringRule(
                name: "stream immutable preference snapshot",
                relativePath: "Sources/Player/VortXMKVRemuxStream.swift",
                start: "init(input: String,",
                end: "// MARK: - HLS output index",
                required: [
                    "self.preferredAudioLanguages = preferredAudioLanguages",
                    "self.audioRejectTerms = audioRejectTerms",
                ],
                mutationTarget: "self.preferredAudioLanguages = preferredAudioLanguages",
                mutationReplacement: "self.preferredAudioLanguages = nil"),
            WiringRule(
                name: "legacy resource loader preference forwarding",
                relativePath: "Sources/Player/VortXRemuxResourceLoader.swift",
                start: "static func make(input: URL,",
                end: "/// Begin remuxing.",
                required: [
                    "selectedAudioStreamIndex: Int? = nil",
                    "preferredAudioLanguages: [String]? = nil",
                    "audioRejectTerms: [String]? = nil",
                    "selectedAudioStreamIndex: selectedAudioStreamIndex",
                    "preferredAudioLanguages: preferredAudioLanguages",
                    "audioRejectTerms: audioRejectTerms",
                ],
                mutationTarget: "preferredAudioLanguages: preferredAudioLanguages",
                mutationReplacement: "preferredAudioLanguages: nil"),
            WiringRule(
                name: "early display uses initial selected source",
                relativePath: "Sources/Player/VortXMKVRemuxStream.swift",
                start: "private func containerHeaderDisplayIntent(",
                end: "private func publishDisplayIntentIfAbsent(",
                required: [
                    "let initialAudio = MultiAudioPolicy.initialSourceTrack(",
                    "preferredLanguages: preferredAudioLanguages",
                    "rejectTerms: audioRejectTerms",
                    "let selectedAudioIsStreamCopy = initialAudio?.isStreamCopy",
                ],
                mutationTarget:
                    "let selectedAudioIsStreamCopy = initialAudio?.isStreamCopy",
                mutationReplacement:
                    "let selectedAudioIsStreamCopy = audioTracks.first?.isStreamCopy"),
            WiringRule(
                name: "classifier uses same initial source policy",
                relativePath: "Sources/Player/VortXMKVRemuxStream.swift",
                start: "let copyablePolicyAudioTracks =",
                end: "let publishedAudioTracks:",
                required: [
                    "codecRank: $0.rank",
                    "let requestedAudio = MultiAudioPolicy.initialSourceTrack(",
                    "preferredLanguages: preferredAudioLanguages",
                    "rejectTerms: audioRejectTerms",
                ],
                mutationTarget: "preferredLanguages: preferredAudioLanguages",
                mutationReplacement: "preferredLanguages: nil"),
            WiringRule(
                name: "main-actor preference capture precedes mount",
                relativePath: "Sources/Player/AVPlayerEngine.swift",
                start: "func loadFile(",
                end: "private func pendingLoadIsCurrent(",
                required: [
                    "let preferences = TrackPreferences.current",
                    "VortXEngineProtocol.normalizedAudioSelectionPreferences(",
                    "preferredLanguages: preferences.audioLanguages",
                    "rejectTerms: preferences.rejectTerms",
                    "remuxPreferredAudioLanguages = normalized.preferredLanguages",
                    "remuxAudioRejectTerms = normalized.rejectTerms",
                    "preferredAudioLanguages: remuxPreferredAudioLanguages",
                    "audioRejectTerms: remuxAudioRejectTerms",
                ],
                mutationTarget: "let preferences = TrackPreferences.current",
                mutationReplacement: "let preferences = remuxFallbackPreferences"),
            WiringRule(
                name: "post-load active source publication",
                relativePath: "Sources/Player/AVPlayerEngine.swift",
                start: "private func refreshRemuxSourceAudioTracks()",
                end: "/// Poll independently of player-time progress",
                required: [
                    "selectedRemuxAudioSourceIndex = actual",
                    "audioTracks = sourceAudioMPVTracks()",
                ],
                mutationTarget: "selectedRemuxAudioSourceIndex = actual",
                mutationReplacement: "_ = actual"),
            WiringRule(
                name: "Apple player screen suppresses only automatic remux audio",
                relativePath: "Sources/PlayerScreen.swift",
                start: "private func autoSelectTracks()",
                end: "/// Push a resume/progress position",
                required: [
                    "let remuxOwnsInitialAudio =",
                    "(coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true",
                    "TrackSelector.automaticAudioSelection(",
                    "remuxOwnsInitialSelection: remuxOwnsInitialAudio",
                    "if let automaticAudio { coordinator.player?.setAudioTrack(automaticAudio) }",
                ],
                mutationTarget: "remuxOwnsInitialSelection: remuxOwnsInitialAudio",
                mutationReplacement: "remuxOwnsInitialSelection: false"),
            WiringRule(
                name: "tvOS player screen suppresses only automatic remux audio",
                relativePath: "SourcesTV/TVPlayerView.swift",
                start: "private func autoSelectTracks()",
                end: "// Restore the viewer's OWN last manual sync offset",
                required: [
                    "let remuxOwnsInitialAudio =",
                    "(coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true",
                    "TrackSelector.automaticAudioSelection(",
                    "remuxOwnsInitialSelection: remuxOwnsInitialAudio",
                    "if let automaticAudio { coordinator.player?.setAudioTrack(automaticAudio) }",
                ],
                mutationTarget: "remuxOwnsInitialSelection: remuxOwnsInitialAudio",
                mutationReplacement: "remuxOwnsInitialSelection: false"),
            WiringRule(
                name: "automatic selected-row no-op preserves explicit remount path",
                relativePath: "Sources/Player/AVPlayerEngine.swift",
                start: "func setAudioTrack(_ id: Int)",
                end: "func setSubtitleTrack(_ id: Int)",
                required: [
                    "guard TrackSelector.shouldApplyAudioSelection(id, to: audioTracks) else { return }",
                    "audioReplacement = RemuxAudioReplacementPolicy.State(",
                    "mountCurrentAudioReplacement(reason: \"audio source selected\")",
                ],
                mutationTarget:
                    "guard TrackSelector.shouldApplyAudioSelection(id, to: audioTracks) else { return }",
                mutationReplacement:
                    "guard true else { return }"),
        ]

        var sources: [String: String] = [:]
        for rule in rules {
            if sources[rule.relativePath] == nil {
                let url = appRoot.appendingPathComponent(rule.relativePath)
                sources[rule.relativePath] = try? String(contentsOf: url, encoding: .utf8)
            }
            guard let source = sources[rule.relativePath] else {
                check("\(rule.name): source is readable", false)
                continue
            }
            check(rule.name, passes(rule, source: source))
            let catchesMutation = applyingMutation(rule, to: source).map {
                !passes(rule, source: $0)
            } ?? false
            check("\(rule.name): hostile mutation turns red", catchesMutation)
        }

        print("")
        if Harness.failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(Harness.failures) FAILED")
        exit(1)
    }
}
