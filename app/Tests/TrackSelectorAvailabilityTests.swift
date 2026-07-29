// Executable contract for unavailable source-track behavior.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/track-selector-availability-test \
//     app/Sources/Player/MPVTrack.swift \
//     app/Sources/Player/TrackSelector.swift \
//     app/Tests/TrackSelectorAvailabilityTests.swift && \
//     /tmp/track-selector-availability-test

import Foundation

struct TrackPreferences {
    enum ForcedPolicy {
        case off
        case forced
        case always
    }

    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let forcedPolicy: ForcedPolicy
    let rejectTerms: [String]

    static let subtitlesOnlyPreferred = false
    static let current = TrackPreferences(
        audioLanguages: ["en"],
        subtitleLanguages: ["en"],
        forcedPolicy: .always,
        rejectTerms: [])
}

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func track(
    _ id: Int,
    type: String,
    lang: String,
    title: String? = nil,
    selected: Bool = false,
    forced: Bool = false,
    unavailable: String? = nil
) -> MPVTrack {
    MPVTrack(
        id: id,
        type: type,
        title: title ?? "Track \(id)",
        lang: lang,
        selected: selected,
        forced: forced,
        unavailableReason: unavailable)
}

private func sourceSection(_ source: String?, from start: String, to end: String) -> String? {
    guard let source,
          let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func functionBodyBeginsWithGuardReturn(_ source: String?, condition: String) -> Bool {
    guard let source, let openingBrace = source.firstIndex(of: "{") else { return false }
    let body = source[source.index(after: openingBrace)...]
    let normalized = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return normalized.hasPrefix("guard \(condition) else { return }")
}

@MainActor @main
enum TrackSelectorAvailabilityTests {
    static func main() {
        let preferences = TrackPreferences(
            audioLanguages: ["en"],
            subtitleLanguages: ["en"],
            forcedPolicy: .always,
            rejectTerms: [])
        let audio = [track(10, type: "audio", lang: "en")]
        let bitmap = track(
            20,
            type: "sub",
            lang: "en",
            unavailable: "Image subtitle is not available in AVPlayer")
        let text = track(21, type: "sub", lang: "en")

        let equivalentAudio = [
            track(1, type: "audio", lang: "en"),
            track(2, type: "audio", lang: "eng", selected: true),
        ]
        check(
            "audio: an already-selected equivalent row stays selected",
            TrackSelector.select(
                audio: equivalentAudio,
                subtitles: [],
                preferences: preferences).audio == 2)
        check(
            "audio: applying that already-selected row is an explicit no-op",
            !TrackSelector.shouldApplyAudioSelection(2, to: equivalentAudio))
        check(
            "audio: a different unselected row remains an actionable selection",
            TrackSelector.shouldApplyAudioSelection(1, to: equivalentAudio))

        let priorityPreferences = TrackPreferences(
            audioLanguages: ["ja", "en"],
            subtitleLanguages: ["en"],
            forcedPolicy: .always,
            rejectTerms: [])
        check(
            "audio: language priority still outranks a selected lower-priority row",
            TrackSelector.select(
                audio: [
                    track(3, type: "audio", lang: "en", selected: true),
                    track(4, type: "audio", lang: "ja"),
                ],
                subtitles: [],
                preferences: priorityPreferences).audio == 4)

        let rejectingPreferences = TrackPreferences(
            audioLanguages: ["en"],
            subtitleLanguages: ["en"],
            forcedPolicy: .always,
            rejectTerms: ["commentary"])
        check(
            "audio: a selected rejected row cannot displace an eligible equivalent",
            TrackSelector.select(
                audio: [
                    track(5, type: "audio", lang: "en"),
                    track(
                        6,
                        type: "audio",
                        lang: "en",
                        title: "Director commentary",
                        selected: true),
                ],
                subtitles: [],
                preferences: rejectingPreferences).audio == 5)

        check(
            "audio: a selected unavailable row cannot displace an eligible equivalent",
            TrackSelector.select(
                audio: [
                    track(
                        9,
                        type: "audio",
                        lang: "en",
                        selected: true,
                        unavailable: "Source cannot be remuxed"),
                    track(10, type: "audio", lang: "eng"),
                ],
                subtitles: [],
                preferences: preferences).audio == 10)

        let fallbackPreferences = TrackPreferences(
            audioLanguages: ["tr"],
            subtitleLanguages: ["en"],
            forcedPolicy: .always,
            rejectTerms: [])
        check(
            "audio: the selected equivalent is also preserved inside English fallback",
            TrackSelector.select(
                audio: [
                    track(7, type: "audio", lang: "en"),
                    track(8, type: "audio", lang: "eng", selected: true),
                ],
                subtitles: [],
                preferences: fallbackPreferences).audio == 8)

        check(
            "subtitles: selected-row stability remains audio-only",
            TrackSelector.select(
                audio: audio,
                subtitles: [
                    track(30, type: "sub", lang: "en"),
                    track(31, type: "sub", lang: "eng", selected: true),
                ],
                preferences: preferences).subtitle == 30)

        let availableWins = TrackSelector.select(
            audio: audio,
            subtitles: [bitmap, text],
            preferences: preferences)
        check(
            "selection: available text wins when an unavailable language match comes first",
            availableWins.subtitle == text.id)

        let bitmapOnly = TrackSelector.select(
            audio: audio,
            subtitles: [bitmap],
            preferences: preferences)
        check(
            "selection: an unavailable-only inventory resolves to Off",
            bitmapOnly.subtitle == -1)
        check(
            "fallback: an unavailable language match does not suppress external subtitles",
            TrackSelector.wantsExternalSubtitle(
                audio: audio,
                subtitles: [bitmap],
                preferences: preferences))

        let forcedPreferences = TrackPreferences(
            audioLanguages: ["en"],
            subtitleLanguages: ["en"],
            forcedPolicy: .forced,
            rejectTerms: [])
        let forcedBitmap = track(
            22,
            type: "sub",
            lang: "en",
            forced: true,
            unavailable: "Image subtitle is not available in AVPlayer")
        check(
            "selection: an unavailable forced row cannot be auto-selected",
            TrackSelector.select(
                audio: audio,
                subtitles: [forcedBitmap],
                preferences: forcedPreferences).subtitle == -1)

        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let avEngine = try? String(
            contentsOf: appRoot.appendingPathComponent("Sources/Player/AVPlayerEngine.swift"),
            encoding: .utf8)
        let mpvEngine = try? String(
            contentsOf: appRoot.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"),
            encoding: .utf8)
        let avSetter = sourceSection(
            avEngine,
            from: "func setAudioTrack(_ id: Int)",
            to: "func setSubtitleTrack(_ id: Int)")
        let mpvSetter = sourceSection(
            mpvEngine,
            from: "func setAudioTrack(_ id: Int)",
            to: "func setSubtitleTrack(_ id: Int)")
        check(
            "audio wiring: AVPlayer suppresses a selected-row no-op before remount intent",
            functionBodyBeginsWithGuardReturn(
                avSetter,
                condition: "TrackSelector.shouldApplyAudioSelection(id, to: audioTracks)")
                && avSetter?.contains("capturePlaybackIntent(from:") == true)
        check(
            "audio wiring: MPV suppresses a selected-row no-op before seek-cache hold",
            functionBodyBeginsWithGuardReturn(
                mpvSetter,
                condition: "TrackSelector.shouldApplyAudioSelection(id, to: tracks(ofType: \"audio\"))")
                && mpvSetter?.contains("armSeekCacheHold()") == true)

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
