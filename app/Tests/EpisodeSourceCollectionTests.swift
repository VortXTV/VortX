import Foundation

// Provider/host seams only. The collector, deadline/pool and ordering under test are production source.
struct CoreStream: Codable, Equatable, Sendable { let id: String; var isTorrent = false }
struct CoreStreamSourceGroup: Equatable, Sendable { let id: String; let addon: String; let streams: [CoreStream] }
struct StreamSource: Equatable, Sendable { let base: String; let name: String }
enum PlaybackSettings { static let directLinksOnly = false }
@MainActor final class ProfileStore { static let shared = ProfileStore(); var activeID: UUID? = UUID() }
@MainActor enum ContinueWatchingPreferences { static var selectionEpoch: UInt64 = 0 }
final class CredentialScopeRegistry: Sendable {
    static let shared = CredentialScopeRegistry()
    func capture() -> Int { 1 }
    func isCurrent(_ capture: Int) -> Bool { capture == 1 }
}
@MainActor final class StremioAccount { var credentialBoundaryGeneration: UInt64 = 0; var streamSources: [StreamSource] = [] }
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
        let sources = (0..<8).map { StreamSource(base: "fixture:\($0)", name: "\($0)") } + [.init(base: "failure", name: "failure")]
        let probe = FetchProbe()
        let fetch: EpisodeSourceCollection.Fetch = { await probe.fetch($0, episode: $1, timeout: $2) }
        let mountedE7 = [CoreStreamSourceGroup(id: "mounted", addon: "mounted", streams: [.init(id: "E7")])]
        let account = StremioAccount(); account.streamSources = sources
        let seriesID = "tt1234567"
        let owner = EpisodeSourceOwner(account: account)
        var completed = false
        let complete = Task { @MainActor in
            let result = await EpisodeSourceCollection.collect(seriesID: seriesID, videoID: "E8", season: 1, episode: 8, title: "Fixture",
                sources: owner.sources, wantedAddon: "7", deadline: ProcessInfo.processInfo.systemUptime + 1,
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
        account.streamSources = Array(sources.reversed())
        check(!newOwner.isCurrent, "provider snapshot change retires captured owner")
        account.streamSources = sources; account.credentialBoundaryGeneration += 1
        check(!newOwner.isCurrent, "same-profile credential rebind retires captured owner")
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
        check(routes.allSatisfy { $0.contains("EpisodeSourceOwner(account: account)") && $0.contains("SeriesSourceSticky.admits") }, "all episode routes retain owner and frozen source-choice fences")
    }
}
