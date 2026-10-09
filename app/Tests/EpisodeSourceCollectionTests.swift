import Foundation

// Provider/host seams only. The collector, deadline/pool and ordering under test are production source.
struct CoreStream: Codable, Equatable, Sendable { let id: String; var isTorrent = false }
struct CoreStreamSourceGroup: Equatable, Sendable { let id: String; let addon: String; let streams: [CoreStream] }
struct StreamSource: Equatable, Sendable { let base: String; let name: String }
enum PlaybackSettings { nonisolated(unsafe) static var directLinksOnly = false }
@MainActor final class ProfileStore { static let shared = ProfileStore(); var activeID: UUID? = UUID() }
@MainActor enum ContinueWatchingPreferences { static var selectionEpoch: UInt64 = 0 }
final class CredentialScopeRegistry: Sendable {
    static let shared = CredentialScopeRegistry()
    func capture() -> Int { 1 }
    func isCurrent(_ capture: Int) -> Bool { capture == 1 }
}
@MainActor final class StremioAccount { var credentialBoundaryGeneration: UInt64 = 0; var streamSources: [StreamSource] = [] }
@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    var registryData: Data?
    var generation = UUID()
    func captureNativeEpisodeSourceRegistry() -> (data: Data, isCurrent: @MainActor () -> Bool)? {
        guard let data = registryData else { return nil }
        let captured = generation
        return (data, { self.generation == captured && self.registryData != nil })
    }
}
@MainActor class FixtureAuxiliary {
    static var neverSettles = false
    static var foreignPublication = false
    static var clearCount = 0
    var publishedTarget: SourceIndexIdentity.PublicationTarget?
    var streams: [CoreStream] { publishedTarget.map { [CoreStream(id: "E\($0.episode ?? -1)")] } ?? [] }
    func settlementState(for: SourceIndexIdentity.TargetResolution?) -> SourceContributorSettlement { Self.neverSettles ? .pending : .terminal }
    func clearResults() { Self.clearCount += 1; publishedTarget = nil }
    func begin(_ target: SourceIndexIdentity.TargetResolution) {
        publishedTarget = Self.foreignPublication ? SourceIndexIdentity.publicationTarget(.init(catalogID: "tt9999999", defaultVideoID: nil, currentVideoID: "E7", kind: .series), season: 1, episode: 7).target : target.target
    }
    static func merge(authorizedBy: SourceIndexIdentity.MergeAuthorization?, _ streams: [CoreStream], into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        authorizedBy != nil ? groups + [CoreStreamSourceGroup(id: "aux", addon: "aux", streams: streams)] : groups
    }
}
@MainActor final class TorBoxSearchSource: FixtureAuxiliary {}
@MainActor final class SourceIndexServeSource: FixtureAuxiliary {}
@MainActor final class MediaServerSource {
    var publishedTarget: SourceIndexIdentity.MediaServerTarget?
    var groups: [CoreStreamSourceGroup] = []
    func settlementState(for: SourceIndexIdentity.MediaServerTarget?) -> SourceContributorSettlement { FixtureAuxiliary.neverSettles ? .pending : .terminal }
    func clearResults() { FixtureAuxiliary.clearCount += 1; publishedTarget = nil; groups = [] }
    func refresh(imdb: String?, season: Int?, episode: Int?, title: String?, publicationTarget: SourceIndexIdentity.MediaServerTarget?) {
        publishedTarget = FixtureAuxiliary.foreignPublication ? SourceIndexIdentity.mediaServerTarget(metaID: "foreign-E7") : publicationTarget
        groups = [.init(id: "media", addon: "media", streams: [.init(id: "E\(episode ?? -1)")])]
    }
    static func merge(authorizedBy: SourceIndexIdentity.MediaServerMergeAuthorization?, _ incoming: [CoreStreamSourceGroup], into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        authorizedBy != nil ? groups + incoming : groups
    }
}
@MainActor enum AuxiliarySourcePipeline {
    static func refresh(target: SourceIndexIdentity.TargetResolution, torBox: TorBoxSearchSource, sourceIndex: SourceIndexServeSource, isSignedIn: Bool) {
        torBox.begin(target); sourceIndex.begin(target)
    }
}
actor FetchProbe {
    var active = 0, peak = 0
    var starts: [String] = []
    func fetch(_ source: StreamSource, episode: String, timeout: TimeInterval) async -> CoreStreamSourceGroup? {
        active += 1; peak = max(peak, active); starts.append(source.name)
        defer { active -= 1 }
        do { try await Task.sleep(for: .milliseconds(source.name == "0" ? 70 : 5)) } catch { return nil }
        guard source.name != "failure" else { return nil }
        return .init(id: source.base, addon: source.name, streams: [.init(id: episode)])
    }
}
@main enum EpisodeSourceCollectionTests {
    @MainActor static func main() async {
        func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
        let sources = (0..<8).map { StreamSource(base: "https://fixture.invalid/\($0)", name: "\($0)") } + [.init(base: "https://fixture.invalid/failure", name: "failure")]
        func registry(_ sources: [StreamSource]) -> Data {
            try! JSONSerialization.data(withJSONObject: sources.map {
                ["transportUrl": $0.base + "/manifest.json", "manifest": ["name": $0.name, "resources": ["stream"], "types": ["series"]]] as [String: Any]
            })
        }
        CoreBridge.shared.registryData = registry(sources)
        let probe = FetchProbe()
        let fetch: EpisodeSourceCollection.Fetch = { await probe.fetch($0, episode: $1, timeout: $2) }
        let mountedE7 = [CoreStreamSourceGroup(id: "mounted", addon: "mounted", streams: [.init(id: "E7")])]
        let account = StremioAccount(); account.streamSources = sources
        let seriesID = "tt1234567"
        let owner = EpisodeSourceOwner(account: account)
        var completed = false
        let complete = Task { @MainActor in
            let result = await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: "Fixture",
                sources: owner.sources(for: "E8"), wantedAddon: "7", deadline: ProcessInfo.processInfo.systemUptime + 1,
                isSignedIn: false, fetch: fetch, isCurrent: { owner.isCurrent })
            completed = true
            return result
        }
        try? await Task.sleep(for: .milliseconds(20))
        check(!completed, "fast leg cannot open incomplete source set")
        let result = await complete.value!
        check(result.prefix(8).map(\.addon) == (0..<8).map(String.init), "registry order survives sticky priority, completion order and failed peer")
        check(result.flatMap(\.streams).allSatisfy { $0.id == "E8" }, "raw and auxiliary results belong only to E8")
        check(mountedE7[0].streams[0].id == "E7", "mounted E7 remains unchanged without a shared-slot input")
        let peak = await probe.peak, starts = await probe.starts
        check(peak == 5 && starts.prefix(5).contains("7"), "five-wide pool prioritizes remembered provider")
        let mixed = [CoreStreamSourceGroup(id: "mixed", addon: "mixed", streams: [.init(id: "torrent", isTorrent: true), .init(id: "direct")]),
                     CoreStreamSourceGroup(id: "torrent-only", addon: "torrent-only", streams: [.init(id: "torrent", isTorrent: true)])]
        PlaybackSettings.directLinksOnly = true
        check(EpisodeSourceCollection.displayGroups(mixed).flatMap(\.streams).map(\.id) == ["direct"], "direct-only removes torrent candidates and empty provider groups")
        PlaybackSettings.directLinksOnly = false
        check(EpisodeSourceCollection.displayGroups(mixed) == mixed, "normal mode preserves original direct and torrent inventory order")
        let preload = await EpisodeSourceCollection.rawGroups(sources: sources, episodeID: "E8", wantedAddon: "7",
            deadline: ProcessInfo.processInfo.systemUptime + 1, fetch: fetch)
        check(Array(result.prefix(8)) == preload, "preload and fallback share exact ordered raw candidates")

        FixtureAuxiliary.neverSettles = true
        let started = ProcessInfo.processInfo.systemUptime
        let deadlineResult = await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: nil,
            sources: sources, wantedAddon: nil, deadline: started + 0.025, isSignedIn: false, fetch: fetch, isCurrent: { true })
        check(deadlineResult != nil && ProcessInfo.processInfo.systemUptime - started < 0.5, "deadline returns bounded settled subset despite pending contributor")
        FixtureAuxiliary.neverSettles = false
        FixtureAuxiliary.foreignPublication = true
        let foreign = await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: nil,
            sources: [], wantedAddon: nil, deadline: ProcessInfo.processInfo.systemUptime + 1, isSignedIn: false, fetch: fetch, isCurrent: { true })
        check(foreign == [], "foreign auxiliary identity is never merged")
        FixtureAuxiliary.foreignPublication = false

        let capturedProfile = ProfileStore.shared.activeID
        let oldA = Task { @MainActor in
            await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: nil,
                sources: sources, wantedAddon: nil, deadline: ProcessInfo.processInfo.systemUptime + 1, isSignedIn: false, fetch: fetch, isCurrent: { owner.isCurrent })
        }
        try? await Task.sleep(for: .milliseconds(10))
        ProfileStore.shared.activeID = UUID(); ContinueWatchingPreferences.selectionEpoch += 1
        ProfileStore.shared.activeID = capturedProfile; ContinueWatchingPreferences.selectionEpoch += 1
        let newOwner = EpisodeSourceOwner(account: account)
        let newA = await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E9", season: 1, episode: 9, title: nil,
            sources: [], wantedAddon: nil, deadline: ProcessInfo.processInfo.systemUptime + 1, isSignedIn: false, fetch: fetch, isCurrent: { newOwner.isCurrent })
        check(await oldA.value == nil && newA?.flatMap(\.streams).allSatisfy { $0.id == "E9" } == true, "profile ABA rejects old output without clearing replacement's sources")
        let cancelled = Task { @MainActor in
            await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: nil,
                sources: sources, wantedAddon: nil, deadline: ProcessInfo.processInfo.systemUptime + 1, isSignedIn: false, fetch: fetch, isCurrent: { true })
        }
        try? await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        check(await cancelled.value == nil, "parent cancellation rejects partial output")
        check(FixtureAuxiliary.clearCount == 18, "each isolated auxiliary owner cleaned exactly once")
#if VORTX_NATIVE_DATA_ENGINE
        account.streamSources = []
        check(newOwner.isCurrent && newOwner.sources(for: "E8") == sources, "native-only inventory works without Stremio token or legacy sources")
        account.streamSources = Array(sources.reversed())
        check(newOwner.isCurrent && newOwner.sources(for: "E8") == sources, "different legacy order cannot replace native profile registry order")
        CoreBridge.shared.generation = UUID()
        check(!newOwner.isCurrent, "acknowledged native registry generation retires old receipt")
        CoreBridge.shared.registryData = nil
        let unavailable = EpisodeSourceOwner(account: account)
        check(!unavailable.isCurrent && unavailable.sources(for: "E8").isEmpty, "absent native registry fails closed without legacy fallback")
        CoreBridge.shared.registryData = registry(sources)
#else
        account.streamSources = Array(sources.reversed())
        check(!newOwner.isCurrent, "legacy provider snapshot change retires captured owner")
        account.streamSources = sources; account.credentialBoundaryGeneration += 1
        check(!newOwner.isCurrent, "same-profile legacy credential rebind retires captured owner")
#endif
        let manifests = Data(#"[{"transportUrl":"https://fixture.invalid/config/manifest.json?key=fixture","manifest":{"name":"first","types":["series"],"idPrefixes":["tt"],"resources":["stream"]}},{"transportUrl":"https://fixture.invalid/movies/manifest.json","manifest":{"name":"movie","types":["movie"],"resources":["stream"]}},{"transportUrl":"https://fixture.invalid/override/manifest.json","manifest":{"name":"override","types":["movie"],"idPrefixes":["movie"],"resources":[{"name":"stream","types":["series"],"idPrefixes":["tt"]}]}},{"transportUrl":"https://fixture.invalid/inherit/manifest.json","manifest":{"name":"inherit","types":["series"],"idPrefixes":["tt"],"resources":[{"name":"stream","types":[]}]}},{"transportUrl":"https://fixture.invalid/meta/manifest.json","manifest":{"name":"meta","types":["series"],"resources":["meta"]}},{"transportUrl":"https://fixture.invalid/all/manifest.json","manifest":{"name":"all","types":["series"],"idPrefixes":["movie"],"resources":[{"name":"stream","idPrefixes":[]}]}}]"#.utf8)
        let inventory = try! JSONDecoder().decode(EpisodeSourceInventory.self, from: manifests)
        var withMalformed = try! JSONSerialization.jsonObject(with: manifests) as! [Any]
        withMalformed.insert(["transportUrl": "https://fixture.invalid/broken", "manifest": ["resources": ["stream"]]], at: 1)
        let partialInventory = try! JSONDecoder().decode(EpisodeSourceInventory.self, from: JSONSerialization.data(withJSONObject: withMalformed))
        check(partialInventory.sources(for: "tt123:1:8") == inventory.sources(for: "tt123:1:8"), "malformed descriptor fails closed per provider without losing valid registry peers")
        check(inventory.sources(for: "tt123:1:8").map(\.name) == ["first", "override", "inherit", "all"], "native resource/type/prefix eligibility preserves exact registry order")
        check(inventory.sources(for: "other").map(\.name) == ["all"], "explicit empty resource prefix overrides manifest constraint")
        let url = EpisodeSourceCollection.resourceURL(base: inventory.sources(for: "tt123")[0].base, episodeID: "tt123:1:8/a?b")!
        check(url.query == "key=fixture" && url.absoluteString.contains("/config/stream/series/tt123:1:8%2Fa%3Fb.json?"), "configured query and path survive exact episode segment escaping")
        let receiptOwner = EpisodeSourceOwner(account: account)
        let receipt = EpisodeSourceReceipt(videoID: "E8", owner: receiptOwner)
        await EpisodeSourceCollection.$receipt.withValue(receipt) {
            _ = await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: nil,
                sources: sources, wantedAddon: nil, deadline: ProcessInfo.processInfo.systemUptime + 1, isSignedIn: false, fetch: fetch, isCurrent: { receiptOwner.isCurrent })
        }
        check(receipt.groups?.count == 11, "task-local cold handoff retains complete source set without changing stream schema")
        let heldReceipt = EpisodeSourceReceipt(videoID: "E8", owner: receiptOwner)
        let replacementReceipt = EpisodeSourceReceipt(videoID: "E8", owner: receiptOwner)
        heldReceipt.accept(mountedE7, videoID: "E7")
        check(heldReceipt.groups == nil && replacementReceipt.groups == nil, "different video and same-video replacement receipts do not share mutable groups")
        let foreignMeta: [String: Any] = ["base": "https://foreign.invalid", "path": ["resource": "meta", "type": "series", "id": "foreign"]]
        let exactBinding = EpisodeEngineBindingRequest.build(libraryID: seriesID, native: true, sourceBase: "https://fixture.invalid",
            residentMetaRequest: foreignMeta, residentSourceBase: "https://foreign.invalid")!
        check((exactBinding.metaRequest["path"] as? [String: Any])?["id"] as? String == seriesID
            && exactBinding.sourceBase == "https://fixture.invalid", "native binding uses exact incoming title rather than unrelated resident detail")
        check(EpisodeEngineBindingRequest.build(libraryID: seriesID, native: true, sourceBase: nil,
            residentMetaRequest: nil, residentSourceBase: nil) != nil, "native episode binding does not require resident detail")
        check(EpisodeEngineBindingRequest.build(libraryID: nil, native: true, sourceBase: nil,
            residentMetaRequest: foreignMeta, residentSourceBase: nil) == nil, "native missing title cannot borrow arbitrary resident attribution")
        check(EpisodeEngineBindingRequest.build(libraryID: seriesID, native: false, sourceBase: nil,
            residentMetaRequest: foreignMeta, residentSourceBase: nil) == nil, "legacy exact-title binding refuses unrelated resident request")
        let firstAttempt = UUID(), nextAttempt = UUID()
        check(EpisodeRefindCompletionPolicy.action(attempt: firstAttempt, active: firstAttempt, sameMediaGeneration: true,
            sameTarget: true, exited: false, cancelled: false) == .restoreFailure, "refind owner retirement restores terminal state for same mounted generation")
        check(EpisodeRefindCompletionPolicy.action(attempt: firstAttempt, active: nextAttempt, sameMediaGeneration: true,
            sameTarget: true, exited: false, cancelled: true) == .ignore, "late cancelled refind never clears successor latch")
        check(EpisodeRefindCompletionPolicy.action(attempt: firstAttempt, active: firstAttempt, sameMediaGeneration: false,
            sameTarget: true, exited: false, cancelled: true) == .clear, "cancelled or replaced media retires only its own old refind latch")
        var activeRefind: UUID? = firstAttempt
        var refinding = true, failed = false
        let heldRefind = Task { @MainActor in
            defer {
                let action = EpisodeRefindCompletionPolicy.action(attempt: firstAttempt, active: activeRefind,
                    sameMediaGeneration: true, sameTarget: true, exited: false, cancelled: Task.isCancelled)
                if action != .ignore { activeRefind = nil; refinding = false; failed = action == .restoreFailure }
            }
            return await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: nil,
                sources: sources, wantedAddon: nil, deadline: ProcessInfo.processInfo.systemUptime + 1,
                isSignedIn: false, fetch: fetch, isCurrent: { receiptOwner.isCurrent })
        }
        try? await Task.sleep(for: .milliseconds(10))
        ContinueWatchingPreferences.selectionEpoch += 1
        check(await heldRefind.value == nil && !refinding && failed, "held refind owner retirement clears overlay and restores same-target terminal failure")
        receipt.accept(mountedE7, videoID: "E8")
        check(receipt.groups?.first?.streams.first?.id == "E8", "retired receipt rejects a same-video late payload after owner ABA")
        let successorOwner = EpisodeSourceOwner(account: account)
        let successorReceipt = EpisodeSourceReceipt(videoID: "E8", owner: successorOwner)
        successorReceipt.accept(result, videoID: "E8")
        activeRefind = firstAttempt; refinding = true; failed = false
        let lateCancellation = Task { @MainActor in
            defer {
                let action = EpisodeRefindCompletionPolicy.action(attempt: firstAttempt, active: activeRefind,
                    sameMediaGeneration: true, sameTarget: true, exited: false, cancelled: Task.isCancelled)
                if action != .ignore { activeRefind = nil; refinding = false; failed = action == .restoreFailure }
            }
            return await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: nil,
                sources: sources, wantedAddon: nil, deadline: ProcessInfo.processInfo.systemUptime + 1,
                isSignedIn: false, fetch: fetch, isCurrent: { successorOwner.isCurrent })
        }
        try? await Task.sleep(for: .milliseconds(10))
        activeRefind = nextAttempt; lateCancellation.cancel()
        check(await lateCancellation.value == nil && refinding && !failed && activeRefind == nextAttempt
            && successorReceipt.groups == result, "held cancelled refind cannot clear successor overlay or source receipt")
        func source(_ path: String) -> String { try! String(contentsOfFile: path, encoding: .utf8) }
        func region(_ text: String, _ start: String, _ end: String) -> String {
            let tail = text.components(separatedBy: start).last!
            precondition(tail != text && tail.contains(end)); return tail.components(separatedBy: end).first!
        }
        let ios = source("app/SourcesiOS/iOSDetailView.swift"), tv = source("app/SourcesTV/TVPlayerView.swift")
        let routes = [region(ios, "func iOSResolveEpisodeStream(", "/// Resolve the frozen ordered list"),
            region(ios, "private func loadEpisodeStream(", "/// Builds a fresh fence"),
            region(tv, "private func play(episode", "/// FIRST-FRAME COMMIT"),
            region(source("app/SourcesTV/TVEpisodePanel.swift"), "func tvResolveEpisodeRequest(", "/// Tell the embedded server")]
        check(routes.allSatisfy { $0.contains("EpisodeSourceCollection.collect(") && !$0.contains("core.loadMeta") && !$0.contains("core.refindSources") && !$0.contains("core.streamLoadProgress") }, "every player/CW episode route uses isolated collection without global slot mutation/wait")
        check(routes.allSatisfy { $0.contains("EpisodeSourceOwner(core: core, account: account)") && $0.contains("SeriesSourceSticky.admits") }, "all episode routes retain owner and frozen source-choice fences")
        let player = source("app/Sources/PlayerScreen.swift")
        let admission = region(player, "private func goToEpisode(", "/// FIRST-FRAME COMMIT")
        check(!admission.contains("core.loadMeta") && admission.contains("EpisodeSourceCollection.$receipt.withValue") && admission.contains("sourceReceipt.groups ?? fallback"), "player admission consumes owned sources without shared detail mutation")
        check(admission.range(of: "let issued = switchStream(")!.lowerBound < admission.range(of: "hydrateEpisodeSources(es.meta")!.lowerBound, "prepared command issues before alternative collection is scheduled")
        let resumeHydration = region(player, "private func hydrateDirectResumeMetadataForPlayerUI()", "private func hydrateDirectResumeSeriesInventory")
        check(resumeHydration.contains("if isEpisodePlaybackContext {") && resumeHydration.contains("hydrateEpisodeSources(current, owner: owner)\n            return"), "current-series resume sources cannot evict shared detail while movie route remains unchanged")
        let tvResume = region(tv, "private func hydrateDirectResumeMetadataForPlayerUI()", "private func hydrateDirectResumeSeriesInventory")
        check(tvResume.contains("EpisodeSourceCollection.collect(") && tvResume.contains("sourceTargetMeta?.videoId == current.videoId")
            && tvResume.contains("return\n        }\n        // Movie"), "TV current-series resume has its own exact-video source task and preserves movie route")
        let refind = region(tv, "private func refindSourcesAndRetry()", "/// Nudge subtitle sync")
        check(refind.contains("defer {") && refind.contains("EpisodeRefindCompletionPolicy.action") && refind.contains("episodeRefindAttempt == attempt"), "TV refind installs attempt-owned cleanup on every return")
        let preparer = source("app/SourcesiOS/iOSNextEpisodePreparer.swift")
        check(preparer.contains("sourceOwner.sources(for: video.id)") && tv.contains("sourceOwner.sources(for: next.id)"), "both preload lanes use the same exact-video native inventory as fallback")
        let explicitLines = (player + tv + ios + source("app/SourcesTV/TVEpisodePanel.swift")).components(separatedBy: "\n")
            .filter { $0.contains("for: ") && $0.contains("videoId:") }
        check(explicitLines.count == 10 && explicitLines.allSatisfy { $0.contains("libraryId:") }, "every owned explicit episode binding carries its exact library identity")
    }
}
