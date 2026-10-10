import Foundation

#if TORBOX_USENET_BASELINE
// Reproduce the pre-fix coordinator admission condition for the baseline run. It ignored an already
// acknowledged job and treated a stale negative cache snapshot as terminal for this source.
enum TorBoxUsenetCacheGate {
    static func permitsResolve(nzbURL: String, confirmedUsenetURLs: Set<String>?,
                               hasAcknowledgedJob _: Bool) -> Bool {
        confirmedUsenetURLs?.contains(nzbURL) ?? true
    }
}
#endif

// Actual TorBox resolver, request builder, selector and public-URL policy; URLProtocol intercepts every
// API request. The inert gateway never starts the app, contacts a provider, or downloads media.
enum CommunityStreamGateway {
    static let shared = Gateway()
    actor Gateway {
        func registerNativeDebrid(upstream: URL) throws -> URL { upstream }
    }
}
enum VXProbe {
    static let enabled = true
    static func log(_ category: StaticString, _ text: @autoclosure () -> String) {
        ProbeLines.shared.append(text())
    }
}
final class ProbeLines: @unchecked Sendable {
    static let shared = ProbeLines()
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func snapshot() -> [String] { lock.withLock { lines } }
}
final class TorBoxFixture: @unchecked Sendable {
    static let shared = TorBoxFixture()
    let lock = NSLock()
    struct Video: Sendable {
        let id: Int
        let name: String
        let size: Int
        var shortName: String? = nil
    }
    struct State {
        var requests: [URLRequest] = []
        var creates = 0
        var polls = 0
        var readyAt = Int.max
        var hash = "fixture-hash"
        var existing = false
        var omitCreatedID = false
        var lookupStatus = 200
        var jobState: String? = nil
        var videos: [Video] = [
            .init(id: 7, name: "Show.S02E33.mkv", size: 3000),
            .init(id: 9, name: "Show.S02E34.mkv", size: 2000)
        ]
        var expectedFileID: Int? = 9
        var onLookup: (@Sendable () -> Void)? = nil
        var onRequestDL: (@Sendable () -> Void)? = nil
    }
    private var state = State()
    func reset(_ value: State = .init()) { lock.withLock { state = value } }
    func snapshot() -> State { lock.withLock { state } }
    func ready() { lock.withLock { state.readyAt = 0 } }
    func setStatus(_ status: Int) { lock.withLock { state.lookupStatus = status } }
    func response(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            state.requests.append(request)
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let body: [String: Any]
            switch url.lastPathComponent {
            case "createusenetdownload":
                state.creates += 1
                body = ["success": true, "data": state.omitCreatedID ? [:] : ["usenetdownload_id": "42"]]
            case "mylist":
                state.onLookup?()
                if state.lookupStatus != 200 { return (state.lookupStatus, Data("{}".utf8)) }
                if query.contains(where: { $0.name == "id" }) || state.creates > 0 {
                    state.polls += 1
                }
                let ready = state.polls >= state.readyAt
                let item: [String: Any] = [
                    "id": 42, "hash": state.hash, "download_finished": ready,
                    "download_present": ready, "download_state": state.jobState ?? (ready ? "completed" : "downloading"),
                    "files": ready ? state.videos.map { video -> [String: Any] in
                        var file: [String: Any] = ["id": video.id, "name": video.name, "size": video.size]
                        if let shortName = video.shortName { file["short_name"] = shortName }
                        return file
                    } : []
                ]
                if query.contains(where: { $0.name == "id" }) {
                    precondition(query.first(where: { $0.name == "id" })?.value == "42")
                    body = ["success": true, "data": item]
                } else {
                    body = ["success": true, "data": state.existing || state.creates > 0 ? [item] : []]
                }
            case "requestdl":
                state.onRequestDL?()
                precondition(query.first(where: { $0.name == "usenet_id" })?.value == "42")
                if let expected = state.expectedFileID {
                    precondition(query.first(where: { $0.name == "file_id" })?.value == String(expected),
                                 "must preserve semantic episode choice")
                }
                body = ["success": true, "data": "https://1.1.1.1/fixture-video.mkv"]
            default: preconditionFailure("Unexpected API request \(url.path)")
            }
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }
    }
}
final class FixtureOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    func retire() { lock.withLock { current = false } }
    func isCurrent() -> Bool { lock.withLock { current } }
}
final class FixtureAuthority: @unchecked Sendable {
    struct Capture: Equatable, Sendable { let key: String; let revision: UInt64 }
    private let lock = NSLock()
    private var current = Capture(key: "fixture-key-a", revision: 1)
    func capture() -> Capture { lock.withLock { current } }
    func rotate(key: String) { lock.withLock { current = Capture(key: key, revision: current.revision &+ 1) } }
    func matches(_ capture: Capture) -> Bool { lock.withLock { current == capture } }
}
final class TorBoxFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = TorBoxFixture.shared.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main private enum TorBoxUsenetRecoveryTests {
    static let nzb = "https://fixture.invalid/selected.nzb?apikey=secret-fixture"
    static let fixture = TorBoxFixture.shared
    static func resolve(_ resolver: TorBoxUsenetResolver) async throws -> URL {
        try await resolver.resolve(nzbUrl: nzb, knownHash: "fixture-hash", fileMustInclude: nil,
                                   fileIdx: 0, episode: .init(season: 2, episode: 34))
    }
    static func selectorCase(_ label: String, selector: String?, selected: Int?,
                             videos: [TorBoxFixture.Video], session: URLSession,
                             invalid: Bool = false, episode: DebridEpisode? = nil) async throws {
        fixture.reset(.init(readyAt: 0, existing: true, videos: videos, expectedFileID: nil))
        let resolver = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        var noMatch = false
        do {
            _ = try await resolver.resolve(nzbUrl: nzb, knownHash: "fixture-hash",
                                           fileMustInclude: selector, fileIdx: 0, episode: episode)
        } catch {
            guard error as? DebridError == .noMatchingFile else { throw error }
            noMatch = true
        }
        let state = fixture.snapshot()
        let downloads = state.requests.filter { $0.url?.lastPathComponent == "requestdl" }
        let picked = downloads.first.flatMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "file_id" })?.value
        }
        let correct = selected.map { !noMatch && downloads.count == 1 && picked == String($0) }
            ?? (noMatch && downloads.isEmpty)
        guard correct, state.creates == 0, !invalid || state.requests.isEmpty else {
            print("FAIL file selector: \(label), expected=\(selected.map(String.init) ?? "no match"), actual=\(picked ?? "none")")
            exit(1)
        }
        print("PASS file selector: \(label)")
    }

    static func selectorCases(session: URLSession) async throws {
        let videos: [TorBoxFixture.Video] = [
            .init(id: 7, name: "Movie.mkv", size: 3000),
            .init(id: 9, name: "Special.mkv", size: 2000)
        ]
        try await selectorCase("absent selector retains ordinary largest-file choice", selector: nil,
                               selected: 7, videos: videos, session: session)
        try await selectorCase("slash-delimited i chooses Special rather than larger Movie",
                               selector: "/special/i", selected: 9, videos: videos, session: session)
        try await selectorCase("bare selector is case-sensitive", selector: "^Special\\.mkv$",
                               selected: 9, videos: videos, session: session)
        try await selectorCase("bare nonmatching case cannot borrow unrelated Movie", selector: "^special\\.mkv$",
                               selected: nil, videos: videos, session: session)
        try await selectorCase("slash-delimited no-flags selector", selector: "/^Special\\.mkv$/",
                               selected: 9, videos: videos, session: session)
        try await selectorCase("escaped slash matches provider path", selector: "/Folder\\/Special\\.mkv/",
                               selected: 9, videos: [
                                .init(id: 7, name: "Movie.mkv", size: 3000),
                                .init(id: 9, name: "Folder/Special.mkv", size: 2000, shortName: "Special.mkv")
                               ], session: session)
        try await selectorCase("m anchors match a line", selector: "/^Special\\.mkv$/m",
                               selected: 9, videos: [
                                .init(id: 7, name: "Movie.mkv", size: 3000),
                                .init(id: 9, name: "Title\nSpecial.mkv", size: 2000)
                               ], session: session)
        try await selectorCase("s dot matches newline", selector: "/^Title.Special\\.mkv$/s",
                               selected: 9, videos: [
                                .init(id: 7, name: "Movie.mkv", size: 3000),
                                .init(id: 9, name: "Title\nSpecial.mkv", size: 2000)
                               ], session: session)
        try await selectorCase("all supported flags", selector: "/^special\\.mkv$/ims",
                               selected: 9, videos: videos, session: session)
        try await selectorCase("valid selector without matching file never falls through", selector: "/Missing/i",
                               selected: nil, videos: videos, session: session)
        for (label, selector) in [
            ("invalid flag", "/Special/g"), ("duplicate flag", "/Special/ii"),
            ("empty pattern", "//i"), ("missing delimiter", "/Special"),
            ("invalid regex", "/[/i"), ("empty supplied selector", ""),
            ("overlong supplied selector", String(repeating: "x", count: 513))
        ] {
            try await selectorCase(label, selector: selector, selected: nil, videos: videos,
                                   session: session, invalid: true)
        }
        try await selectorCase("selector precedes semantic episode without provider-array fileIdx",
                               selector: "/S02E34/i", selected: 9, videos: [
                                .init(id: 7, name: "Show.S02E33.mkv", size: 3000),
                                .init(id: 9, name: "Show.S02E34.mkv", size: 2000)
                               ], session: session, episode: .init(season: 2, episode: 34))
        try await conflictingEpisodeCase(session: session)
        for name in ["Show.S02E34E35.mkv", "Show.S02E34-35.mkv", "Show.S02E34 and E35.mkv",
                     "Show.2x34x35.mkv", "Show.S02E34.S02E34.mkv", "Show.S02E34000.mkv",
                     "Show.Season 2 Episode 33.mkv"] {
            try await selectorCase("explicit selector cannot admit ambiguous/wrong episode: \(name)",
                                   selector: "/Show/i", selected: nil,
                                   videos: [.init(id: 9, name: name, size: 2000)], session: session,
                                   episode: .init(season: 2, episode: 34))
        }
        try await selectorCase("explicit selector admits unique opaque anime filename",
                               selector: "/Naruto - 034/i", selected: 9,
                               videos: [.init(id: 9, name: "Naruto - 034.mkv", size: 2000)],
                               session: session, episode: .init(season: 2, episode: 34))
        try await selectorCase("short_name alone satisfies explicit anchored selector",
                               selector: "/^Special\\.mkv$/", selected: 9,
                               videos: [.init(id: 9, name: "Folder/Special.mkv", size: 2000,
                                              shortName: "Special.mkv")], session: session)
        try await selectorCase("same episode folder plus basename is not a combined episode",
                               selector: "/S02E34/i", selected: 9,
                               videos: [.init(id: 9, name: "Show.S02E34/Show.S02E34.mkv", size: 2000,
                                              shortName: "Show.S02E34.mkv")], session: session,
                               episode: .init(season: 2, episode: 34))
        try await selectorCase("pack folder cannot override authoritative episode basename",
                               selector: "/Show/i", selected: 9,
                               videos: [.init(id: 9, name: "Show.S02E01-E40/Show.S02E34.mkv", size: 2000,
                                              shortName: "Show.S02E34.mkv")], session: session,
                               episode: .init(season: 2, episode: 34))
        try await selectorCase("matching folder cannot conceal wrong episode basename",
                               selector: "/Show/i", selected: nil,
                               videos: [.init(id: 9, name: "Show.S02E34/Show.S02E33.mkv", size: 2000,
                                              shortName: "Show.S02E33.mkv")], session: session,
                               episode: .init(season: 2, episode: 34))
        try await selectorCase("contradictory provider basenames fail closed",
                               selector: "/Show/i", selected: nil,
                               videos: [.init(id: 9, name: "Show.S02E34.mkv", size: 2000,
                                              shortName: "Show.S02E33.mkv")], session: session,
                               episode: .init(season: 2, episode: 34))
        try await pendingSelectorCase(session: session)
    }

    static func conflictingEpisodeCase(session: URLSession) async throws {
        try await selectorCase("selector cannot substitute S02E33 for requested S02E34",
                               selector: "/S02E33/i", selected: nil, videos: [
                                .init(id: 7, name: "Show.S02E33.mkv", size: 3000),
                                .init(id: 9, name: "Show.S02E34.mkv", size: 2000)
                               ], session: session, episode: .init(season: 2, episode: 34))
    }

    static func pendingSelectorCase(session: URLSession) async throws {
        fixture.reset()
        let resolver = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session,
                                           pollInterval: .zero, pollAttempts: 3)
        do { _ = try await resolve(resolver); preconditionFailure("fixture must remain pending") }
        catch { precondition(error as? DebridError == .notReady) }
        let requestsBefore = fixture.snapshot().requests.count
        let waitingBefore = await resolver.isWaiting(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(waitingBefore && fixture.snapshot().creates == 1)
        do {
            _ = try await resolver.resolve(nzbUrl: nzb, knownHash: "fixture-hash", fileMustInclude: "/Special/g",
                                           fileIdx: 0, episode: .init(season: 2, episode: 34))
            preconditionFailure("invalid local selector must fail")
        } catch {
            guard error as? DebridError == .noMatchingFile else {
                print("FAIL invalid local selector must reject before polling pending job: \(error)")
                exit(1)
            }
        }
        let waitingAfter = await resolver.isWaiting(nzbURL: nzb, knownHash: "fixture-hash")
        let acknowledged = await resolver.hasJob(nzbURL: nzb, knownHash: "fixture-hash")
        guard waitingAfter && acknowledged && fixture.snapshot().requests.count == requestsBefore else {
            print("FAIL invalid local selector retired or polled an existing pending job")
            exit(1)
        }
        fixture.ready()
        _ = try await resolve(resolver)
        precondition(fixture.snapshot().creates == 1)
        print("PASS invalid local selector preserves pending job and same-ID Retry")
    }

    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TorBoxFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        if CommandLine.arguments.dropFirst().first == "--pending-selector-state" {
            try await pendingSelectorCase(session: session)
            return
        }
        if CommandLine.arguments.dropFirst().first == "--conflicting-episode-selector" {
            try await conflictingEpisodeCase(session: session)
            return
        }

        #if TORBOX_USENET_BASELINE
        fixture.reset(.init(readyAt: 0, existing: true))
        let baseline = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session)
        _ = try await resolve(baseline)
        if fixture.snapshot().creates != 0 {
            print("FAIL baseline POSTs create for an already-completed job instead of adopting it")
            exit(1)
        }
        fixture.reset()
        let pendingBaseline = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session,
                                                   pollInterval: .zero, pollAttempts: 3)
        do { _ = try await resolve(pendingBaseline); preconditionFailure("pending job must not mint media") }
        catch { precondition(error as? DebridError == .notReady) }
        let baselineOwnsPendingJob = await pendingBaseline.hasJob(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(baselineOwnsPendingJob)
        let negativeSnapshot: Set<String> = ["https://fixture.invalid/different-source.nzb"]
        precondition(TorBoxUsenetCacheGate.permitsResolve(nzbURL: nzb,
                                                           confirmedUsenetURLs: negativeSnapshot,
                                                           hasAcknowledgedJob: baselineOwnsPendingJob),
                     "baseline incorrectly lets a stale negative cache snapshot hide its acknowledged job")
        #else
        try await selectorCases(session: session)
        fixture.reset()
        let resolver = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero, pollAttempts: 3)
        do { _ = try await resolve(resolver); preconditionFailure("pending must not mint media") }
        catch { precondition(error as? DebridError == .notReady) }
        let waiting = await resolver.isWaiting(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(waiting && fixture.snapshot().creates == 1)
        fixture.setStatus(401)
        do { _ = try await resolve(resolver); preconditionFailure("auth failure must be terminal") }
        catch { precondition(error as? DebridError == .invalidKey) }
        let waitingAfterAuthFailure = await resolver.isWaiting(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(!waitingAfterAuthFailure, "failed polling must not leave a stale preparation message")
        fixture.setStatus(200)
        fixture.ready()
        _ = try await resolve(resolver)
        precondition(fixture.snapshot().creates == 1, "Retry must reuse the acknowledged job, no second create")
        precondition(fixture.snapshot().requests.last?.url?.lastPathComponent == "requestdl")
        print("PASS pending timeout -> completion -> Retry uses same job and requested episode")

        fixture.reset(.init(readyAt: 0, existing: true))
        let fresh = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        _ = try await resolve(fresh)
        precondition(fixture.snapshot().creates == 0, "existing authoritative hash must skip create")
        precondition(fixture.snapshot().requests.count == 2, "completed lookup should mint directly without redundant poll")
        print("PASS pre-existing completed job adopted by hash without create")

        fixture.reset(.init(readyAt: 11))
        let boundary = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        _ = try await resolve(boundary)
        precondition(fixture.snapshot().polls == 11 && fixture.snapshot().creates == 1)
        print("PASS final polling observation can resolve a newly ready job")

        fixture.reset(.init(readyAt: 3, omitCreatedID: true))
        let noID = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        _ = try await resolve(noID)
        let requests = fixture.snapshot().requests
        precondition(requests.filter { $0.url?.lastPathComponent == "mylist" && $0.url?.query?.contains("id=42") == true }.count == 2,
                     "promote discovered pending hash to exact ID before ready")
        print("PASS missing create ID adopts pending list ID before completion")

        fixture.reset()
        let cancelled = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .seconds(30))
        let task = Task { try await resolve(cancelled) }
        while fixture.snapshot().polls == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancelled resolve returned media") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        precondition(fixture.snapshot().polls == 1 && fixture.snapshot().creates == 1,
                     "cancel during polling sleep must not send one last request")
        fixture.ready()
        _ = try await resolve(cancelled)
        precondition(fixture.snapshot().creates == 1)
        print("PASS cancellation stops polling immediately and later Retry reuses job")

        // A manual same-source tap carries a possibly stale negative cache snapshot. Preserve the explicit
        // cold/uncached gate when no job exists, but let the owned resolver resume its acknowledged job.
        fixture.reset()
        let cacheRetry = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session,
                                              pollInterval: .zero, pollAttempts: 3)
        do { _ = try await resolve(cacheRetry); preconditionFailure("pending job must not mint media") }
        catch { precondition(error as? DebridError == .notReady) }
        let negativeSnapshot: Set<String> = ["https://fixture.invalid/different-source.nzb"]
        precondition(!TorBoxUsenetCacheGate.permitsResolve(nzbURL: nzb,
                                                           confirmedUsenetURLs: negativeSnapshot,
                                                           hasAcknowledgedJob: false),
                     "a cold not-confirmed source must remain zero-network")
        let ownsPendingJob = await cacheRetry.hasJob(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(ownsPendingJob)
        precondition(TorBoxUsenetCacheGate.permitsResolve(nzbURL: nzb,
                                                          confirmedUsenetURLs: negativeSnapshot,
                                                          hasAcknowledgedJob: ownsPendingJob),
                     "a stale negative cache snapshot must not suppress the same owned pending job")
        fixture.ready()
        let cacheRetriedURL = try await resolve(cacheRetry)
        precondition(cacheRetriedURL.path == "/fixture-video.mkv")
        let afterCacheRetry = fixture.snapshot()
        precondition(afterCacheRetry.creates == 1, "same-source cache retry must not duplicate the job")
        precondition(afterCacheRetry.requests.filter { $0.url?.lastPathComponent == "requestdl" }.count == 1)
        precondition(afterCacheRetry.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key-a"
        })
        print("PASS stale negative cache snapshot cannot hide same-account pending source; cold uncached gate remains")

        let differentOwner = TorBoxUsenetResolver(apiKey: "fixture-key-b", session: session, pollInterval: .zero)
        let inherited = await differentOwner.hasJob(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(!inherited, "credential replacement must not inherit account-scoped IDs")
        fixture.reset(.init(readyAt: 0))
        _ = try await resolve(differentOwner)
        precondition(fixture.snapshot().creates == 1)
        precondition(fixture.snapshot().requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key-b" })
        print("PASS account resolver replacement starts with no inherited job")

        fixture.reset(.init(lookupStatus: 401))
        let denied = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        do { _ = try await resolve(denied); preconditionFailure("failed lookup permitted create") }
        catch { precondition(error as? DebridError == .invalidKey) }
        precondition(fixture.snapshot().creates == 0)
        print("PASS failed existing-job lookup never creates another download")

        let owner = FixtureOwner()
        fixture.reset(.init(onLookup: { owner.retire() }))
        let retired = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        do {
            _ = try await retired.resolve(nzbUrl: nzb, knownHash: "fixture-hash", fileMustInclude: nil,
                                          fileIdx: 0, episode: .init(season: 2, episode: 34),
                                          ownerIsCurrent: { owner.isCurrent() })
            preconditionFailure("retired owner submitted cloud work")
        } catch is CancellationError {}
        precondition(fixture.snapshot().creates == 0)
        print("PASS owner retired during existing-job lookup cannot submit a new cloud job")

        // Model the coordinator's captured credential scope/revision across a resolver await. The same
        // credential value returning after an A -> B -> A switch is not the original authority: revision
        // 3 must not satisfy the captured A/revision-1 admission closure.
        let authority = FixtureAuthority()
        let capturedAuthority = authority.capture()
        fixture.reset(.init(onLookup: {
            authority.rotate(key: "fixture-key-b")
            authority.rotate(key: "fixture-key-a")
        }))
        let abaResolver = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        do {
            _ = try await abaResolver.resolve(nzbUrl: nzb, knownHash: "fixture-hash", fileMustInclude: nil,
                                              fileIdx: 0, episode: .init(season: 2, episode: 34),
                                              ownerIsCurrent: { authority.matches(capturedAuthority) })
            preconditionFailure("A -> B -> A credential ABA must invalidate the original resolve")
        } catch is CancellationError {}
        let abaState = fixture.snapshot()
        precondition(authority.capture().key == capturedAuthority.key
                     && authority.capture().revision != capturedAuthority.revision,
                     "fixture must return to the original key with a newer authority revision")
        precondition(abaState.creates == 0 && abaState.requests.count == 1,
                     "stale A/revision-1 work must stop after the awaited lookup, before create")
        precondition(abaState.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key-a"
        })
        print("PASS controlled A -> B -> A credential ABA fences create after awaited lookup")

        // A newly captured B resolver is likewise not usable by an intent that retained A/revision-1.
        // This is the cloud-only case: no native-owner lease exists to provide a second fence.
        authority.rotate(key: "fixture-key-b")
        fixture.reset()
        let replacementResolver = TorBoxUsenetResolver(apiKey: "fixture-key-b", session: session,
                                                       pollInterval: .zero)
        do {
            _ = try await replacementResolver.resolve(
                nzbUrl: nzb, knownHash: "fixture-hash", fileMustInclude: nil,
                fileIdx: 0, episode: .init(season: 2, episode: 34),
                ownerIsCurrent: { authority.matches(capturedAuthority) }
            )
            preconditionFailure("old cloud intent must not admit the replacement account resolver")
        } catch is CancellationError {}
        precondition(fixture.snapshot().requests.isEmpty && fixture.snapshot().creates == 0,
                     "old cloud intent must not send a request using the replacement key")
        print("PASS cloud-only old intent cannot admit replacement credential resolver")

        // The provider may finish requestdl after authority changes. Its syntactically valid link must not
        // escape the resolver under the original capture, including an A -> B -> A key-value ABA.
        authority.rotate(key: "fixture-key-a")
        let linkCapture = authority.capture()
        fixture.reset(.init(readyAt: 0, onRequestDL: {
            authority.rotate(key: "fixture-key-b")
            authority.rotate(key: "fixture-key-a")
        }))
        let linkResolver = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        do {
            _ = try await linkResolver.resolve(
                nzbUrl: nzb, knownHash: "fixture-hash", fileMustInclude: nil,
                fileIdx: 0, episode: .init(season: 2, episode: 34),
                ownerIsCurrent: { authority.matches(linkCapture) }
            )
            preconditionFailure("stale requestdl response must not return its media link")
        } catch is CancellationError {}
        let linkState = fixture.snapshot()
        precondition(linkState.requests.filter { $0.url?.lastPathComponent == "requestdl" }.count == 1)
        precondition(authority.capture().key == linkCapture.key
                     && authority.capture().revision != linkCapture.revision)
        print("PASS credential ABA after requestdl fences returned playback link")

        fixture.reset(.init(readyAt: 0))
        let concurrent = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        async let first = resolve(concurrent)
        async let second = resolve(concurrent)
        _ = try await (first, second)
        precondition(fixture.snapshot().creates == 1)
        print("PASS concurrent resolves serialize creation without duplicating the job")

        fixture.reset(.init(jobState: "failed"))
        let failed = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session, pollInterval: .zero)
        do { _ = try await resolve(failed); preconditionFailure("failed job must stop") }
        catch { precondition(error as? DebridError == .providerError("TorBox Usenet job failed")) }
        let stillWaiting = await failed.isWaiting(nzbURL: nzb, knownHash: "fixture-hash")
        let failedJobResumable = await failed.hasJob(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(!stillWaiting && !failedJobResumable && fixture.snapshot().polls == 1)
        let negativeAfterFailure: Set<String> = ["https://fixture.invalid/different-source.nzb"]
        precondition(!TorBoxUsenetCacheGate.permitsResolve(nzbURL: nzb,
                                                           confirmedUsenetURLs: negativeAfterFailure,
                                                           hasAcknowledgedJob: failedJobResumable),
                     "terminal failed jobs must not bypass the cold negative-cache gate")
        print("PASS failed provider job is terminal, not displayed as still preparing")

        fixture.reset(.init(jobState: "cancelled"))
        let providerCancelled = TorBoxUsenetResolver(apiKey: "fixture-key-a", session: session,
                                                     pollInterval: .zero)
        do { _ = try await resolve(providerCancelled); preconditionFailure("cancelled provider job must stop") }
        catch { precondition(error as? DebridError == .providerError("TorBox Usenet job failed")) }
        let cancelledJobResumable = await providerCancelled.hasJob(nzbURL: nzb, knownHash: "fixture-hash")
        precondition(!cancelledJobResumable)
        print("PASS provider-cancelled job is retired from retry admission")

        let secretError = NSError(domain: NSURLErrorDomain, code: -1001,
                                  userInfo: [NSLocalizedDescriptionKey: "secret-fixture https://fixture.invalid/?key=secret-fixture"])
        DebridProbe.log("usenet-cloud", DebridProbe.usenetFailure(secretError))
        DebridProbe.log("usenet-local", UsenetNodeClient.failureReason(UsenetNodeClient.ClientError.unsupportedArchive))
        let lines = ProbeLines.shared.snapshot()
        precondition(lines.contains { $0.contains("network_-1001") })
        precondition(lines.contains { $0.contains("unsupported_archive") })
        precondition(!lines.joined().contains("secret-fixture") && !lines.joined().contains("fixture-key"))
        print("PASS exported diagnostics contain fixed reasons and no credentials or source URL")
        #endif
    }
}
