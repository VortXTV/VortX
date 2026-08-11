// Production-linked executable for the sealed media-server target and merge capability.
//
//   xcrun swiftc -D SOURCE_INDEX_IDENTITY_TESTING -swift-version 6 \
//     -strict-concurrency=complete -warnings-as-errors -o /tmp/media-server-identity-boundary \
//     app/SourcesShared/SourceIndexContract.swift \
//     app/SourcesShared/SourceIndexIdentity.swift \
//     app/SourcesShared/MediaServerSource.swift \
//     app/Tests/MediaServerIdentityBoundaryTests.swift && /tmp/media-server-identity-boundary

import Foundation

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

protocol ObservableObject: AnyObject {}

struct CoreStream: Codable, Equatable, Sendable {
    var name: String?
    var description: String?
    var url: String?
    var infoHash: String?
    var nzbUrl: String?
    var vortxProvider: String?
    var behaviorHints: [String: String]?
}

struct CoreStreamSourceGroup: Equatable, Sendable {
    let id: String
    let addon: String
    let streams: [CoreStream]
}

struct MediaServerHit: Sendable, Equatable {
    let serverId: UUID
    let serverName: String
    let fileName: String?
    let container: String?
    let resolution: Int?
    let sizeBytes: Int64?
    let streamURL: URL
}

@MainActor
final class MediaServerStore: ObservableObject {
    static let shared = MediaServerStore()
    var servers: [String] = []
}

@MainActor
final class MediaServerCoordinator {
    static let shared = MediaServerCoordinator()
    var hits: [MediaServerHit] = []
    var calls = 0
    var hold = false
    private var continuation: CheckedContinuation<[MediaServerHit], Never>?
    private var scriptedMode = false
    private var nextScriptedID = 0
    private var scriptedRequests: [(id: Int, key: String)] = []
    private var scriptedPending: [Int: CheckedContinuation<[MediaServerHit], Never>] = [:]
    private var scriptedCancellations: Set<Int> = []

    func find(imdb: String?, season: Int?, episode: Int?, title: String?, year: Int?) async
        -> [MediaServerHit] {
        calls += 1
        if scriptedMode {
            let request = (id: nextScriptedID,
                           key: "\(imdb ?? "")|\(season ?? -1)|\(episode ?? -1)|\(title ?? "")|\(year ?? -1)")
            nextScriptedID += 1
            scriptedRequests.append(request)
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    scriptedPending[request.id] = continuation
                }
            }, onCancel: {
                Task { @MainActor in self.scriptedCancellations.insert(request.id) }
            })
        }
        if hold {
            return await withCheckedContinuation { continuation = $0 }
        }
        return hits
    }

    func release() {
        continuation?.resume(returning: hits)
        continuation = nil
        hold = false
    }

    func beginScripted() {
        scriptedMode = true
        nextScriptedID = 0
        scriptedRequests = []
        scriptedPending = [:]
        scriptedCancellations = []
    }

    func scriptedRequestIDs() -> [Int] { scriptedRequests.map(\.id) }
    func scriptedCancellationCount() -> Int { scriptedCancellations.count }

    func releaseScripted(_ id: Int, hits: [MediaServerHit]) {
        scriptedPending.removeValue(forKey: id)?.resume(returning: hits)
    }
}

enum SourceContributorSettlement: Equatable, Sendable {
    case inactive
    case pending
    case terminal
}

private func target(_ titleID: String, season: Int? = nil, episode: Int? = nil)
    -> SourceIndexIdentity.TargetResolution {
    SourceIndexIdentity.publicationTarget(
        SourceIndexIdentity.Roles(
            catalogID: titleID, defaultVideoID: nil, currentVideoID: nil,
            kind: season == nil && episode == nil ? .movie : .series
        ),
        season: season, episode: episode
    )
}

@main
struct MediaServerIdentityBoundaryTests {
    @MainActor
    static func main() async {
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                print("PASS \(name)")
            } else {
                print("FAIL \(name)")
                exit(1)
            }
        }

        let validPage = target("tt0903747", season: 1, episode: 1)
        let validMedia = SourceIndexIdentity.mediaServerTarget(page: validPage)!
        let fallback = SourceIndexIdentity.mediaServerTarget(metaID: "library", videoID: "episode")!
        let embeddedSeparator = SourceIndexIdentity.mediaServerTarget(metaID: "library|wrong", videoID: "episode")
        expect(fallback.token == "meta:library|video:episode" && embeddedSeparator == nil,
               "IMDb-less media fallback is injective and rejects separator-bearing parts")

        let mismatchPage = SourceIndexIdentity.publicationTarget(
            SourceIndexIdentity.Roles(
                catalogID: "tt0903747", defaultVideoID: "tt1375666",
                currentVideoID: nil, kind: .movie
            )
        )
        expect(SourceIndexIdentity.mediaServerTarget(
            preferring: mismatchPage, metaID: "library", videoID: "episode"
        ) == nil, "mismatched roles cannot fall back into a media-server target")

        MediaServerStore.shared.servers = ["server"]
        MediaServerCoordinator.shared.hits = [
            MediaServerHit(
                serverId: UUID(), serverName: "Test Server", fileName: "movie.mkv",
                container: "mkv", resolution: 1080, sizeBytes: 1_024,
                streamURL: URL(string: "https://server.example/movie.mkv")!
            )
        ]
        let source = MediaServerSource()
        source.refresh(imdb: "tt0903747", season: 1, episode: 1,
                       title: "Test", publicationTarget: validMedia)
        for _ in 0..<1_000 where source.groups.isEmpty {
            await Task.yield()
        }
        expect(MediaServerCoordinator.shared.calls == 1
               && source.publishedTarget == validMedia
               && !source.groups.isEmpty,
               "media-server rows publish only under the exact fetched target")

        let denied = MediaServerSource.merge(
            authorizedBy: nil, source.groups, into: []
        )
        let authorized = MediaServerSource.merge(
            authorizedBy: SourceIndexIdentity.mediaServerMergeAuthorization(
                published: validMedia, page: validMedia
            ),
            source.groups, into: []
        )
        expect(denied.isEmpty && !authorized.isEmpty,
               "media-server merge requires the exact target capability")

        MediaServerCoordinator.shared.hold = true
        let nextMedia = SourceIndexIdentity.mediaServerTarget(
            page: target("tt0903747", season: 1, episode: 2)
        )!
        source.refresh(imdb: "tt0903747", season: 1, episode: 2,
                       title: "Test", publicationTarget: nextMedia)
        source.refresh(imdb: nil, title: "Test", publicationTarget: nil)
        MediaServerCoordinator.shared.release()
        for _ in 0..<1_000 {
            await Task.yield()
        }
        expect(source.publishedTarget == nil && source.groups.isEmpty,
               "a mismatched replacement clears delayed media-server publication")

        let revisitSource = MediaServerSource()
        let cachedTarget = nextMedia
        let uncachedTarget = SourceIndexIdentity.mediaServerTarget(
            page: target("tt0903747", season: 1, episode: 3)
        )!
        let cachedHit = MediaServerHit(
            serverId: UUID(), serverName: "Cached Server", fileName: "cached.mkv",
            container: "mkv", resolution: 1080, sizeBytes: 1_024,
            streamURL: URL(string: "https://server.example/cached.mkv")!
        )
        let lateHit = MediaServerHit(
            serverId: UUID(), serverName: "Late Server", fileName: "late.mkv",
            container: "mkv", resolution: 720, sizeBytes: 512,
            streamURL: URL(string: "https://server.example/late.mkv")!
        )
        let freshHit = MediaServerHit(
            serverId: UUID(), serverName: "Fresh Server", fileName: "fresh.mkv",
            container: "mkv", resolution: 2160, sizeBytes: 2_048,
            streamURL: URL(string: "https://server.example/fresh.mkv")!
        )
        MediaServerCoordinator.shared.beginScripted()
        revisitSource.refresh(imdb: "tt0903747", season: 1, episode: 2,
                              title: "Test", publicationTarget: cachedTarget)
        for _ in 0..<1_000 where MediaServerCoordinator.shared.scriptedRequestIDs().count < 1 {
            await Task.yield()
        }
        let cachedBRequest = MediaServerCoordinator.shared.scriptedRequestIDs()[0]
        MediaServerCoordinator.shared.releaseScripted(cachedBRequest, hits: [cachedHit])
        for _ in 0..<1_000 where revisitSource.groups.isEmpty {
            await Task.yield()
        }
        revisitSource.refresh(imdb: "tt0903747", season: 1, episode: 2,
                              title: "Test", publicationTarget: cachedTarget)
        await Task.yield()
        expect(MediaServerCoordinator.shared.scriptedRequestIDs().count == 1,
               "repeated media-server cache hits do not duplicate transport")

        revisitSource.refresh(imdb: "tt0903747", season: 1, episode: 3,
                              title: "Test", publicationTarget: uncachedTarget)
        for _ in 0..<1_000 where MediaServerCoordinator.shared.scriptedRequestIDs().count < 2 {
            await Task.yield()
        }
        let oldARequest = MediaServerCoordinator.shared.scriptedRequestIDs()[1]
        revisitSource.refresh(imdb: "tt0903747", season: 1, episode: 2,
                              title: "Test", publicationTarget: cachedTarget)
        for _ in 0..<1_000 where MediaServerCoordinator.shared.scriptedCancellationCount() < 1 {
            await Task.yield()
        }
        let ownerAfterCachedReplacement = revisitSource.ownerStateForTesting
        expect(ownerAfterCachedReplacement.inFlightKey == nil
               && !ownerAfterCachedReplacement.hasTask
               && !revisitSource.groups.isEmpty,
               "cached media-server replacement cancels A and clears its owner state before publishing B")

        revisitSource.refresh(imdb: "tt0903747", season: 1, episode: 3,
                              title: "Test", publicationTarget: uncachedTarget)
        for _ in 0..<1_000 where MediaServerCoordinator.shared.scriptedRequestIDs().count < 3 {
            await Task.yield()
        }
        let freshARequest = MediaServerCoordinator.shared.scriptedRequestIDs()[2]
        let ownerOnFreshA = revisitSource.ownerStateForTesting
        expect(freshARequest != oldARequest
               && ownerOnFreshA.inFlightKey != nil
               && ownerOnFreshA.hasTask,
               "revisiting A after a cached B starts exactly one fresh media-server request")
        MediaServerCoordinator.shared.releaseScripted(oldARequest, hits: [lateHit])
        for _ in 0..<100 { await Task.yield() }
        expect(revisitSource.groups.isEmpty,
               "late canceled media-server A cannot publish after A is revisited")
        MediaServerCoordinator.shared.releaseScripted(freshARequest, hits: [freshHit])
        for _ in 0..<1_000 where revisitSource.groups.isEmpty {
            await Task.yield()
        }
        expect(!revisitSource.groups.isEmpty,
               "fresh revisited media-server A publishes only after its own completion")
        print("ALL PASS")
    }
}
