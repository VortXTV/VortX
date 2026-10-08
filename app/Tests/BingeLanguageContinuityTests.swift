import Foundation

final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID?
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }

@main enum BingeLanguageContinuityTests {
    static func main() async throws {
        typealias P = BingeAudioContinuityPolicy
        precondition(P.canonical(" ENG ") == "en")
        precondition(P.canonical("en-US") == "en")
        precondition(P.canonical("fre") == "fr")
        precondition(P.canonical("unknown") == nil)
        precondition(P.inventoryLacksDesired(["fre", "jpn"], desired: "eng"))
        precondition(!P.inventoryLacksDesired(["eng", "jpn"], desired: "en"))
        precondition(!P.inventoryLacksDesired(["fre", "und"], desired: "en"))
        precondition(!P.inventoryLacksDesired([], desired: "en"))
        precondition(!P.inventoryLacksDesired([""], desired: "en"))
        precondition(P.maximumRejectedSources == 3)
        precondition(P.shouldRetry(newlyRejected: true, rejectedCount: 1))
        precondition(P.shouldRetry(newlyRejected: true, rejectedCount: 2))
        precondition(!P.shouldRetry(newlyRejected: true, rejectedCount: 3))
        precondition(!P.shouldRetry(newlyRejected: false, rejectedCount: 1))
        precondition(!P.shouldRetry(newlyRejected: false, rejectedCount: 0))
        for explicit in [false, true] {
            for resume in [false, true] {
                for accepted in [false, true] {
                    precondition(P.shouldRecordManualSource(explicit: explicit, resume: resume, accepted: accepted)
                                 == (explicit && !resume && accepted))
                }
            }
        }

        // Isolated randomly named profiles; no real viewer's preferences are read or modified.
        let profileA = UUID(), profileB = UUID(), series = "fixture-series"
        defer {
            for profile in [profileA, profileB] {
                UserDefaults.standard.removeObject(forKey: "stremiox.seriesSourceSticky.\(profile.uuidString)")
            }
        }
        ProfileStore.shared.activeID = profileA
        SeriesSourceSticky.record(seriesKey: series, addon: "Actual source group", bingeGroup: "opaque-pack")
        SeriesSourceSticky.recordAudio(seriesKey: series, language: "eng")
        let first = SeriesSourceSticky.snapshot(for: series)
        precondition(first.addon == "Actual source group" && first.audioLanguage == "en")
        let warm = await SeriesSourceSticky.$resolvingChoice.withValue(first) {
            await Task.yield()
            return SeriesSourceSticky.snapshot(for: series)
        }
        precondition(warm == first, "prepare and admission share frozen choice")
        SeriesSourceSticky.recordAudio(seriesKey: series, language: "jpn")
        precondition(SeriesSourceSticky.snapshot(for: series) != warm, "manual audio change retires prepared source")
        precondition(SeriesSourceSticky.preference(for: series)?.addon == first.addon,
                     "audio change must not learn automatic source provenance")
        ProfileStore.shared.activeID = profileB
        precondition(SeriesSourceSticky.snapshot(for: series).audioLanguage == nil)
        let otherProfile = SeriesSourceSticky.$resolvingChoice.withValue(first) {
            SeriesSourceSticky.snapshot(for: series)
        }
        precondition(otherProfile.profile == profileB.uuidString && otherProfile.addon == nil,
                     "frozen choice cannot cross profiles")
        ProfileStore.shared.activeID = profileA
        precondition(SeriesSourceSticky.snapshot(for: series).audioLanguage == "ja")
        let old = Data(#"{"addon":"legacy","bingeGroup":"old-pack","ts":0}"#.utf8)
        let decoded = try JSONDecoder().decode(SeriesSourceSticky.Choice.self, from: old)
        precondition(decoded.addon == "legacy" && decoded.audioLanguage == nil,
                     "old source-only preferences remain decodable")

        let player = try String(contentsOfFile: "app/Sources/PlayerScreen.swift", encoding: .utf8)
        let tv = try String(contentsOfFile: "app/SourcesTV/TVPlayerView.swift", encoding: .utf8)
        for source in [player, tv] {
            precondition(source.contains("guard admitIncomingEpisodeAudio(loadToken: event.loadToken) else { return }"))
            precondition(source.contains("languageRejectedStreams.insert($0.id).inserted"))
            let admission = source.components(separatedBy: "private func admitIncomingEpisodeAudio").last!
                .components(separatedBy: "private func").first!
            precondition(admission.contains("guard !pending.terminal else { return false }"))
            precondition(admission.contains("coordinator.player?.invalidateLoadToken()"),
                         "rejected file's queued frames must not terminate or commit its replacement")
            precondition(source.contains("rememberSeriesAudio(track.lang, explicit: true)"))
            precondition(!source.contains("rememberSeriesAudio(selectedSubtitle"))
        }
        precondition(player.contains("initialSourceAddon"))
        precondition(player.contains("preparedEpisodeChoice == seriesStickyKey.map"))
        precondition(player.contains("await SeriesSourceSticky.$rejectedStreams.withValue(rejectedStreams)"))
        precondition(tv.contains("preloaded?.choice == choice"))
        let detailTV = try String(contentsOfFile: "app/SourcesTV/DetailView.swift", encoding: .utf8)
        precondition(!detailTV.contains("SeriesSourceSticky.record("))
        precondition(detailTV.components(separatedBy: "sourceAddon: sourceAddon").count >= 3)
        let rootTV = try String(contentsOfFile: "app/SourcesTV/RootTabView.swift", encoding: .utf8)
        precondition(rootTV.contains("initialSourceAddon: req.sourceAddon"))
        print("PASS actual audio inventory, bounded retry policy, manual-source admission, profile isolation, Codable migration, frozen prepare/admit choice, player wiring")
    }
}
