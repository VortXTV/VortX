import Foundation

final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID?
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }

@main enum BingeLanguageContinuityTests {
    @MainActor static func main() async throws {
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
        // Production first-frame gate: a frame can beat the asynchronous audio topology by 9 ms.
        // Empty discovery may never publish progress/watch, and an actual untagged row is different.
        var inventory = BingeAudioInventoryAdmission<String>()
        precondition(inventory.evaluate(owner: "E27-old", languages: [], desired: "en", now: 100) == .waiting)
        precondition(!inventory.permitsCommit(owner: "E27-old"))
        precondition(inventory.evaluate(owner: "E27-old", languages: ["fre", "jpn"], desired: "en", now: 100.009) == .mismatch)
        precondition(!inventory.permitsCommit(owner: "E27-old"), "late French topology cannot commit the first frame")
        precondition(inventory.evaluate(owner: "E27-replacement", languages: [], desired: "en", now: 101) == .waiting)
        precondition(!inventory.permitsCommit(owner: "E27-old"), "retired topology cannot admit a replacement")
        precondition(inventory.evaluate(owner: "E27-replacement", languages: ["eng", "jpn"], desired: "en", now: 101.2) == .accepted)
        precondition(inventory.permitsCommit(owner: "E27-replacement"))
        precondition(inventory.evaluate(owner: "untagged", languages: [""], desired: "en", now: 102) == .accepted)
        precondition(inventory.evaluate(owner: "no-inventory", languages: [], desired: "en", now: 103) == .waiting)
        precondition(inventory.evaluate(owner: "no-inventory", languages: [], desired: "en", now: 105.999) == .waiting)
        precondition(inventory.evaluate(owner: "no-inventory", languages: [], desired: "en", now: 106) == .unavailable)
        precondition(!inventory.permitsCommit(owner: "no-inventory"), "bounded missing topology retries; it is not fabricated unknown audio")
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

        // Exercise the production asynchronous admission gate with a resolver that deliberately ignores
        // cancellation. The user changes audio while E2 is suspended; E2 is restarted immediately, not E3
        // and not an EOF-driven request. Releasing the old completion must not publish/watch its result.
        SeriesSourceSticky.recordAudio(seriesKey: series, language: "eng")
        let frozen = SeriesSourceSticky.currentSnapshot(for: series)
        let exactEpisode = "fixture-series:1:27"
        var releaseOld: CheckedContinuation<String?, Never>?
        let oldResolution = Task { @MainActor in
            await SeriesSourceSticky.$resolvingChoice.withValue(frozen) {
                await SeriesSourceSticky.resolveIfCurrent(frozen) {
                    await withCheckedContinuation { releaseOld = $0 }
                }
            }
        }
        for _ in 0..<1_000 where releaseOld == nil { await Task.yield() }
        precondition(releaseOld != nil, "delayed resolver must have started before changing audio")
        SeriesSourceSticky.recordAudio(seriesKey: series, language: "jpn")
        let replacementChoice = SeriesSourceSticky.currentSnapshot(for: series)
        precondition(!SeriesSourceSticky.admits(nil), "nil cannot waive an automatic episode's requirement")
        let oldContextAdmitted = SeriesSourceSticky.$resolvingChoice.withValue(frozen) {
            SeriesSourceSticky.admits(frozen)
        }
        precondition(!oldContextAdmitted, "live admission must bypass the old task-local snapshot")
        let restarted = await SeriesSourceSticky.resolveIfCurrent(replacementChoice) { exactEpisode }
        releaseOld?.resume(returning: exactEpisode)
        let retired = await oldResolution.value
        precondition(retired == nil && restarted == exactEpisode,
                     "late completion is rejected while the exact episode can resolve with the new choice")
        let acceptedEpisodeIDs = [retired, restarted].compactMap { $0 }
        precondition(acceptedEpisodeIDs == [exactEpisode], "only the replacement may publish progress/watch")
        ProfileStore.shared.activeID = profileB
        let crossedProfile = await SeriesSourceSticky.resolveIfCurrent(replacementChoice) { exactEpisode }
        precondition(crossedProfile == nil, "even an unchanged language cannot cross profile ownership")
        ProfileStore.shared.activeID = profileA

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
            precondition(source.contains("restartEpisodeResolutionForAudioChoice(choice)"))
            precondition(source.contains("currentPickWasExplicit || SeriesSourceSticky.admits(incomingEpisodeChoice)"))
            precondition(source.contains("incomingAudioInventory.permitsCommit(owner: loadToken)"))
            precondition(source.contains("assetSanityDeferredStartPosition = d\n                    guard admitIncomingEpisodeAudio"),
                         "an owned late track receipt must re-enter the held first frame")
            precondition(admission.contains("pendingAdvance?.loadToken == loadToken else { return }"),
                         "inventory timeout must not act on a replacement episode")
            precondition(!source.contains("if explicit { incomingEpisodeChoice = nil }"))
            precondition(!source.contains("rememberSeriesAudio(selectedSubtitle"))
        }
        precondition(player.contains("initialSourceAddon"))
        precondition(player.contains("preparedEpisodeChoice == seriesStickyKey.map"))
        precondition(player.contains("await SeriesSourceSticky.$rejectedStreams.withValue(rejectedStreams)"))
        precondition(tv.contains("preloaded?.choice == choice"))
        precondition(player.contains("await SeriesSourceSticky.resolveIfCurrent(choice)"))
        precondition(tv.contains("let wantedAddon = choice?.addon"))
        let detailTV = try String(contentsOfFile: "app/SourcesTV/DetailView.swift", encoding: .utf8)
        precondition(!detailTV.contains("SeriesSourceSticky.record("))
        precondition(detailTV.components(separatedBy: "sourceAddon: sourceAddon").count >= 3)
        let rootTV = try String(contentsOfFile: "app/SourcesTV/RootTabView.swift", encoding: .utf8)
        precondition(rootTV.contains("initialSourceAddon: req.sourceAddon"))
        print("PASS actual/delayed/empty audio inventory, bounded retry, manual-source admission, profiles, migration, delayed resolver/audio-change admission, exact-episode restart, player wiring")
    }
}
