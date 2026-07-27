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
    forced: Bool = false,
    unavailable: String? = nil
) -> MPVTrack {
    MPVTrack(
        id: id,
        type: type,
        title: "Track \(id)",
        lang: lang,
        selected: false,
        forced: forced,
        unavailableReason: unavailable)
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

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
