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
                    "files": ready ? [
                        ["id": 7, "name": "Show.S02E33.mkv", "size": 3000],
                        ["id": 9, "name": "Show.S02E34.mkv", "size": 2000]
                    ] : []
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
                precondition(query.first(where: { $0.name == "file_id" })?.value == "9", "must preserve semantic episode choice")
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
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TorBoxFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

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
