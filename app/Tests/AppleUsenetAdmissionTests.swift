// Actual CoreStream, ranking admission/best and iOS Watch-disable expression, with inert environment doubles.
// Scoring/filter dependencies are identity/add-on-order stubs: this tests eligibility, not ranking weights.
import Foundation

final class UsenetAdmissionEnvironment: @unchecked Sendable {
    static let shared = UsenetAdmissionEnvironment()
    struct State {
        var nativeSelected = true
        var nativeSupported = true
        var legacyEndpointAvailable = true
        var savedProvider = false
        var endpoint: UsenetNodeClient.Endpoint?
    }
    private let lock = NSLock()
    private var value = State()
    private var reads = 0
    var state: State { lock.withLock { value } }
    func set(_ state: State) { lock.withLock { value = state } }
    var providerReads: Int { lock.withLock { reads } }
    func readSavedProvider() -> Bool { lock.withLock { reads += 1; return value.savedProvider } }
}
enum Bundle {
    static let main = FixtureBundle()
    struct FixtureBundle: Sendable {
        func path(forResource: String, ofType: String?) -> String? {
            UsenetAdmissionEnvironment.shared.state.nativeSupported ? "/inert/vortx-streaming-server" : nil
        }
    }
}
enum VortxNativeServerFlag {
    static var isSupported: Bool { UsenetAdmissionEnvironment.shared.state.nativeSupported }
}
enum StremioServer {
    static var nativeTransportSelected: Bool { UsenetAdmissionEnvironment.shared.state.nativeSelected }
    static var usenetNodeBase: String? {
        let state = UsenetAdmissionEnvironment.shared.state
        #if VORTX_NO_EMBEDDED_SERVER
        return nil
        #else
        return !state.nativeSelected && state.legacyEndpointAvailable ? "http://127.0.0.1:11470" : nil
        #endif
    }
    static var usenetEndpoint: UsenetNodeClient.Endpoint? { UsenetAdmissionEnvironment.shared.state.endpoint }
    static let trailerResolverBase = "https://trailer.invalid"
    static let base = "http://127.0.0.1:11470"
}
enum UsenetProviderStore {
    static var isConfigured: Bool { UsenetAdmissionEnvironment.shared.readSavedProvider() }
}
enum PlaybackSettings { static let torrentsDisabled = false }
struct CommunityStreamGateway: Sendable {
    static let shared = CommunityStreamGateway()
    func localURLIfReady(for stream: CoreStream, upstream: URL) -> URL? { nil }
}
struct ResolvedPin {}
enum SourcePreferences {
    struct Reading { let useAddonOrder = true }
    static var reading: Reading { Reading() }
}
extension StreamRanking {
    static func applyUserFilters(_ groups: [CoreStreamSourceGroup], debridCachedHashes: Set<String>) -> [CoreStreamSourceGroup] { groups }
    static func firstPinned(_ groups: [CoreStreamSourceGroup], pin: ResolvedPin?) -> CoreStream? { nil }
    static func score(_ stream: CoreStream, debridCachedHashes: Set<String>) -> Int { 0 }
    static func pinBonus(_ stream: CoreStream, addon: String, pin: ResolvedPin?) -> Int { 0 }
}

@main @MainActor private enum AppleUsenetAdmissionTests {
    static var failures = 0
    static func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        if !condition { failures += 1 }
    }
    static func stream(_ fields: [String: Any]) throws -> CoreStream {
        try JSONDecoder().decode(CoreStream.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    static func assertAdmission(_ name: String, stream: CoreStream, expected: Bool) {
        let groups = [CoreStreamSourceGroup(id: "fixture", addon: "Fixture", streams: [stream])]
        check("\(name): actual CoreStream admission", (stream.playableURL != nil) == expected)
        check("\(name): actual ranking admission", !StreamRanking.playablePairs(groups).isEmpty == expected)
        let best = StreamRanking.best(groups)
        check("\(name): actual best/Watch path", (best != nil) == expected
              && watchDisabled(loading: false, preparing: false, best: best) == !expected)
    }
    static func main() async throws {
        #if VORTX_NO_EMBEDDED_SERVER
        let localExpected = false
        let label = "Lite"
        #elseif USENET_ADMISSION_MAC
        let localExpected = true
        let label = "Mac Full"
        #else
        let localExpected = true
        let label = "mobile Full"
        #endif
        let saved = try stream(["nzbUrl": "https://fixture.invalid/episode.nzb"])
        let addon = try stream(["nzbUrls": ["https://fixture.invalid/episode.nzb"],
                                "servers": ["nntps://fixture:synthetic@news.invalid:563/4"]])
        let nzb = addon.usenetURLs[0]
        check("\(label) cached TorBox still bypasses local NNTP", !coordinatorWouldAttemptLocal(
            stream: addon, nzb: nzb, confirmedUsenetURLs: [nzb], usenetSavedServers: []))
        check("\(label) uncached add-on NNTP retains local priority", coordinatorWouldAttemptLocal(
            stream: addon, nzb: nzb, confirmedUsenetURLs: [], usenetSavedServers: []))
        var environment = UsenetAdmissionEnvironment.State()
        environment.savedProvider = true
        UsenetAdmissionEnvironment.shared.set(environment)
        DebridPlaybackAvailability.shared.publish(torBoxConfigured: false)
        assertAdmission("\(label) native saved provider/no TorBox before startup", stream: saved, expected: localExpected)
        environment.savedProvider = false
        UsenetAdmissionEnvironment.shared.set(environment)
        let readsBeforeAddon = UsenetAdmissionEnvironment.shared.providerReads
        assertAdmission("\(label) native add-on NNTP/no TorBox before startup", stream: addon, expected: localExpected)
        check("\(label) validated add-on eligibility does not read saved secrets",
              UsenetAdmissionEnvironment.shared.providerReads == readsBeforeAddon)
        assertAdmission("\(label) no credentials", stream: saved, expected: false)

        environment.nativeSupported = false
        environment.savedProvider = true
        UsenetAdmissionEnvironment.shared.set(environment)
        let readsBeforeUnavailable = UsenetAdmissionEnvironment.shared.providerReads
        assertAdmission("\(label) unavailable native cannot borrow legacy listener", stream: saved, expected: false)
        check("\(label) unavailable local runtime does not read saved secrets during ranking",
              UsenetAdmissionEnvironment.shared.providerReads == readsBeforeUnavailable)
        DebridPlaybackAvailability.shared.publish(torBoxConfigured: true)
        let readsBeforeRemote = UsenetAdmissionEnvironment.shared.providerReads
        assertAdmission("\(label) TorBox remains eligible without native", stream: saved, expected: true)
        check("\(label) remote eligibility retains short-circuit secret-read behavior",
              UsenetAdmissionEnvironment.shared.providerReads == readsBeforeRemote)
        DebridPlaybackAvailability.shared.publish(torBoxConfigured: false)
        environment.nativeSelected = false
        UsenetAdmissionEnvironment.shared.set(environment)
        assertAdmission("\(label) legacy endpoint retains saved-provider behavior", stream: saved, expected: localExpected)
        environment.legacyEndpointAvailable = false
        UsenetAdmissionEnvironment.shared.set(environment)
        assertAdmission("\(label) missing legacy endpoint stays unavailable", stream: addon, expected: false)

        let direct = try stream(["url": "https://fixture.invalid/video.mp4"])
        assertAdmission("\(label) direct playback unchanged", stream: direct, expected: true)
        let torrent = try stream(["infoHash": String(repeating: "a", count: 40), "fileIdx": 2])
        check("\(label) explicit torrent file unchanged", torrent.playableURL(isEpisode: true)?.lastPathComponent == "2")
        check("\(label) Watch loading/preparing gates remain intact",
              watchDisabled(loading: true, preparing: false, best: direct)
                && watchDisabled(loading: false, preparing: true, best: direct))

        // Capability is not readiness: execute the actual bounded resolver with no endpoint published.
        environment.nativeSelected = true
        environment.nativeSupported = true
        environment.savedProvider = true
        UsenetAdmissionEnvironment.shared.set(environment)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await UsenetLocalResolver.resolveRouted(
                nzbURLs: addon.usenetURLs, servers: addon.usenetServers, waitForNode: true)
            check("\(label) failed startup never returns a descriptor as media", false)
        } catch UsenetLocalResolver.ResolveError.unavailable {
            check("\(label) failed startup is bounded and returns no media", ProcessInfo.processInfo.systemUptime - started < 3)
        }
        check("\(label) admission does not publish or start an endpoint", UsenetAdmissionEnvironment.shared.state.endpoint == nil)
        print(failures == 0 ? "ALL PASS \(label)" : "\(failures) FAILURE(S) \(label)")
        exit(failures == 0 ? 0 : 1)
    }
}
