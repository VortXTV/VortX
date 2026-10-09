// Inert native installation/profile environment for the mechanically extracted production owner check.
import Foundation

final class CredentialScopeRegistry: @unchecked Sendable {
    struct Capture: Sendable, Equatable { let generation: UUID }
    static let shared = CredentialScopeRegistry()
    private let lock = NSLock()
    private var generation = UUID()
    func capture() -> Capture { lock.withLock { .init(generation: generation) } }
    func isCurrent(_ capture: Capture) -> Bool { lock.withLock { capture.generation == generation } }
    func retire() { lock.withLock { generation = UUID() } }
}
@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID? = UUID()
}
@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    var generation = UUID()
    var resolveJob = UUID()
}
struct PlaybackMutationTarget: Sendable {
    let generation: UUID
    @MainActor static func capture(core: CoreBridge) -> Self { .init(generation: core.generation) }
    @MainActor func stillOwnsCurrentContext(core: CoreBridge) -> Bool { core.generation == generation }
}
#if NZB_OPERATION_FIXTURE
typealias CoreStream = FixtureStream
typealias DebridEpisode = UsenetNodeClient.Selection.Episode
typealias DebridCoordinator = CoordinatorFixture
actor FixtureWarmGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
enum DebridService: String, Sendable { case torBox }
enum DebridError: Error, Equatable { case noKey, sessionChanged, notReady, providerError(String) }
enum DebridPlaybackAvailability {
    struct Availability { let canResolveUsenetRemotely = true }
    static let shared = Availability()
}
enum UsenetProviderStore { static let isConfigured = false }
actor FixtureCloudResolver {
    static let shared = FixtureCloudResolver()
    private(set) var calls = 0
    private var outputGate: FixtureWarmGate?
    private var existingJob = false
    private var delay: Duration?
    private var responseError: DebridError?
    func setExistingJob(_ value: Bool) { existingJob = value }
    func setDelay(_ value: Duration?) { delay = value }
    func setError(_ value: DebridError?) { responseError = value }
    func hasJob(nzbURL: String, knownHash: String?) -> Bool { existingJob }
    func isWaiting(nzbURL: String, knownHash: String?) -> Bool { existingJob && responseError == .notReady }
    func gateOutput(_ gate: FixtureWarmGate?) { outputGate = gate }
    func resolve(nzbUrl: String, knownHash: String?, fileMustInclude: String?, fileIdx: Int?, episode: DebridEpisode?,
                 ownerIsCurrent: @escaping @Sendable () async -> Bool = { true }) async throws -> URL {
        calls += 1
        if let delay { try await Task.sleep(for: delay) }
        if let responseError { throw responseError }
        let gate = outputGate; outputGate = nil
        await gate?.wait()
        return URL(string: "https://fixture.invalid/cloud")!
    }
}
actor ProviderCircuitBreaker {
    enum Phase { case resolve }
    static let shared = ProviderCircuitBreaker()
    private var admissionGate: FixtureWarmGate?
    func gateAdmission(_ gate: FixtureWarmGate?) { admissionGate = gate }
    func shouldAttempt(provider: String, sourceID: String) async -> Bool {
        let gate = admissionGate; admissionGate = nil
        await gate?.wait()
        return true
    }
    func recordSuccess(provider: String, sourceID: String) {}
}
struct FixtureStream: Sendable {
    let usenetURLs: [String]
    let usenetServers: [String]
    let fileIdx: Int?
    let fileMustInclude: String?
    var isUsenet: Bool { !usenetURLs.isEmpty }
    var url: URL? { nil }
    var usenetKnownHash: String? { nil }
}
enum DebridProbe {
    static func log(_ category: String, _ text: String) {}
    static func h8(_ text: String) -> String { "fixture" }
    static func since(_ start: Date) -> Int { 0 }
    static func usenetFailure(_ error: Error) -> String { UsenetNodeClient.failureReason(error) }
}
enum StremioServer {
    static let nativeTransportSelected = true
    nonisolated(unsafe) static var usenetEndpoint: UsenetNodeClient.Endpoint?
}
extension DebridPlaybackRef {
    init(nativeUsenetLease: UsenetNodeClient.OperationLease?) {
        self.init(url: URL(string: "http://127.0.0.1:1/nzb/stream")!, service: .torBox, infoHash: "",
                  torrentId: nil, fileId: nil, fileIdx: nil, nativeUsenetLease: nativeUsenetLease)
    }
}
#endif
