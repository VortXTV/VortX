import Foundation
typealias ProviderOAuthOriginalManager = VortXSyncManager

// Whole actual Trakt/SIMKL apply, clear and actor turnstile/drain methods are inserted unchanged.
// The publication acquisition adapter, tuple IO and exact-register lookup are declared synthetic.
// Actual manager cloud authority is retained across the actual actor waits. No Keychain, token,
// provider network, installed account or production notification observer is accessed here.
enum ProviderOAuthCloudClearFixture {
    struct Snapshot {
        var clearAttempts = 0, clears = 0, publications = 0, boundaries = 0
        var publicationHeldBoundary = true, publicationReleasedSource = true
        var tokens = ["owner": "synthetic-original", "sibling": "synthetic-retained"]
        var sourceDepth = 0, registerCurrent = true, clearSucceeds = true
    }
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Snapshot()
        private var paused: String?
        private var visited = Set<String>()
        private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
        private var publicationWaiter: CheckedContinuation<Void, Never>?
        func snapshot() -> Snapshot { lock.withLock { value } }
        func arm(_ phase: String) { lock.withLock { paused = phase } }
        func refuseRegister() { lock.withLock { value.registerCurrent = false } }
        func refuseClear() { lock.withLock { value.clearSucceeds = false } }
        func sourceEnter() { lock.withLock { value.sourceDepth += 1 } }
        func sourceLeave() { lock.withLock { value.sourceDepth -= 1 } }
        func mark(_ phase: String) {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                visited.insert(phase); return observers.removeValue(forKey: phase) ?? []
            }
            waiting.forEach { $0.resume() }
        }
        func wait(_ phase: String) async {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> Bool in
                    if visited.contains(phase) { return true }
                    observers[phase, default: []].append(continuation); return false
                }
                if ready { continuation.resume() }
            }
        }
        func publicationAcquire() async {
            if lock.withLock({ paused == "publication" }) {
                await withCheckedContinuation { continuation in
                    let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                        publicationWaiter = continuation; visited.insert("publication")
                        return observers.removeValue(forKey: "publication") ?? []
                    }
                    waiting.forEach { $0.resume() }
                }
            }
            lock.withLock { value.boundaries += 1 }
        }
        func releasePublication() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                paused = nil; let waiting = publicationWaiter; publicationWaiter = nil; return waiting
            }
            waiting?.resume()
        }
        func publicationEnd() { lock.withLock { value.boundaries -= 1 } }
        func clearTuple() -> Bool {
            lock.withLock {
                value.clearAttempts += 1
                guard value.clearSucceeds else { return false }
                value.clears += 1; value.tokens.removeValue(forKey: "owner"); return true
            }
        }
        func publish() {
            lock.withLock {
                value.publications += 1
                value.publicationHeldBoundary = value.publicationHeldBoundary && value.boundaries == 1
                value.publicationReleasedSource = value.publicationReleasedSource && value.sourceDepth == 0
            }
        }
    }
    final class Hub: @unchecked Sendable {
        let lock = NSLock()
        private var current = World()
        func get() -> World { lock.withLock { current } }
        func reset() -> World { lock.withLock { current = World(); return current } }
    }
    static let hub = Hub()
    static var world: World { hub.get() }
    final class ObservedAuthority: VortxMutationAuthority, @unchecked Sendable {
        let original: any VortxMutationAuthority
        let observations: World
        init(_ original: any VortxMutationAuthority, observations: World) { self.original = original; self.observations = observations }
        func withActive(_ operation: () throws -> Void) throws {
            try original.withActive {
                observations.sourceEnter(); defer { observations.sourceLeave() }
                try operation()
            }
        }
    }
    struct VortxNativeProviderCredentials {
        struct Register: Equatable, Sendable { let value: VortxJSON }
    }
    @MainActor final class VortXSyncManager {
        static let shared = VortXSyncManager()
        func prepareNativeProviderMutation(_ values: [String: VortxJSON], capture: CredentialScopeRegistry.Capture)
            -> [String: VortxNativeProviderCredentials.Register]? { preconditionFailure("explicit disconnect outside source-clear fixture") }
        func finishNativeProviderMutation(_ events: [String: VortxNativeProviderCredentials.Register],
            capture: CredentialScopeRegistry.Capture) -> Bool { preconditionFailure("explicit disconnect outside source-clear fixture") }
        nonisolated static func withNativeProviderEvents(_ events: [String: VortxNativeProviderCredentials.Register],
            capture: CredentialScopeRegistry.Capture, mutation: () -> Bool) -> Bool {
            guard CredentialScopeRegistry.shared.isCurrent(capture), world.snapshot().registerCurrent,
                  events.count == 1, events.values.allSatisfy({ $0.value == .null }) else { return false }
            return mutation()
        }
    }
    struct Credentials: Sendable {
        func certifiedRead(_ slot: String) -> Bool { true }
        func recoveryRead(_ slot: String) -> Bool { true }
        func write(_ value: String?, _ slot: String) -> Bool { true }
    }
    struct LoginAttempts: Sendable { func isCurrent(generation: UInt64) -> Bool { true } }
    enum CredentialTupleTransaction {
        static func clear(baseAccounts: [String], activePointer: String, cleanupMarker: String,
            candidateMarker: String, extraAccounts: [String], certifiedRead: (String) -> Bool,
            recoveryRead: (String) -> Bool, write: (String?, String) -> Bool) -> Bool { world.clearTuple() }
    }
    enum CredentialPublicationOutbox {
        enum Acquisition: Equatable { case acquired }
        static func waitForBoundary() async -> Acquisition { await world.publicationAcquire(); return .acquired }
        static func endBoundary() { world.publicationEnd() }
    }
    enum TraktTokenSlots {
        static func active(_ scope: String) -> String { "fixture.trakt.active." + scope }
        static func cleanup(_ scope: String) -> String { "fixture.trakt.cleanup." + scope }
        static func candidate(_ scope: String) -> String { "fixture.trakt.candidate." + scope }
        static func publication(_ scope: String) -> String { "fixture.trakt.publication." + scope }
    }
    enum SIMKLTokenSlots {
        static func active(_ scope: String) -> String { "fixture.simkl.active." + scope }
        static func cleanup(_ scope: String) -> String { "fixture.simkl.cleanup." + scope }
        static func candidate(_ scope: String) -> String { "fixture.simkl.candidate." + scope }
        static func publication(_ scope: String) -> String { "fixture.simkl.publication." + scope }
    }
    enum TraktAuthBoundary { static func publish(_ value: String?) { precondition(value == nil); world.publish() } }
    enum SIMKLAuthBoundary { static func publish(_ value: String?) { precondition(value == nil); world.publish() } }
    protocol ClearDriver: Actor {
        func fixtureArm(_ phase: String)
        func fixtureRelease(_ phase: String)
        func fixtureSettled() -> Bool
        func applyNativeCredentialClear(capture: CredentialScopeRegistry.Capture,
            events: [String: VortxNativeProviderCredentials.Register], sourceAuthority: (any VortxMutationAuthority)?) async -> Bool
    }
    actor TraktAuth: ClearDriver {
        var nativeCredentialGeneration = UUID()
        var session = UUID()
        let credentials = Credentials(), loginAttempts = LoginAttempts()
        static let createdAtAccount = "fixture.created"
        var pendingCredentialBoundaries = 0, activeSessionWrites = 0
        var credentialBoundaryActive = false
        var credentialBoundaryWaiters: [CheckedContinuation<Void, Never>] = [] {
            didSet { if !credentialBoundaryWaiters.isEmpty { world.mark("turnstile") } }
        }
        var sessionWriteDrainWaiters: [CheckedContinuation<Void, Never>] = []
        var sessionWriteDrainObserver: (() -> Void)? = { world.mark("drain") }
        func ownerCapture() -> CredentialScopeRegistry.Capture { CredentialScopeRegistry.shared.capture() }
        func currentSessionID(ownerNamespace: String) -> UUID? { session }
        func tupleAccounts(ownerNamespace: String) -> [String] { ["fixture.trakt.tuple." + ownerNamespace] }
        func slot(_ slot: String, ownerNamespace: String) -> String { slot + ownerNamespace }
        func fixtureArm(_ phase: String) {
            world.arm(phase)
            if phase == "turnstile" { credentialBoundaryActive = true }
            if phase == "drain" { activeSessionWrites = 1 }
        }
        func fixtureRelease(_ phase: String) {
            if phase == "turnstile" { releaseCredentialBoundary() }
            if phase == "drain" { finishSessionWrite() }
            if phase == "publication" { world.releasePublication() }
        }
        func fixtureSettled() -> Bool { pendingCredentialBoundaries == 0 && !credentialBoundaryActive && activeSessionWrites == 0 }
        // @@ACTUAL_TRAKT_CLOUD_CLEAR@@
    }
    actor SIMKLAuth: ClearDriver {
        var nativeCredentialGeneration = UUID()
        var session = UUID()
        let credentials = Credentials(), loginAttempts = LoginAttempts()
        var pendingCredentialBoundaries = 0, activeSessionWrites = 0
        var credentialBoundaryActive = false
        var credentialBoundaryWaiters: [CheckedContinuation<Void, Never>] = [] {
            didSet { if !credentialBoundaryWaiters.isEmpty { world.mark("turnstile") } }
        }
        var sessionWriteDrainWaiters: [CheckedContinuation<Void, Never>] = []
        var sessionWriteDrainObserver: (() -> Void)? = { world.mark("drain") }
        func ownerCapture() -> CredentialScopeRegistry.Capture { CredentialScopeRegistry.shared.capture() }
        func currentSessionID(ownerNamespace: String) -> UUID? { session }
        func tupleAccounts(ownerNamespace: String) -> [String] { ["fixture.simkl.tuple." + ownerNamespace] }
        func fixtureArm(_ phase: String) {
            world.arm(phase)
            if phase == "turnstile" { credentialBoundaryActive = true }
            if phase == "drain" { activeSessionWrites = 1 }
        }
        func fixtureRelease(_ phase: String) {
            if phase == "turnstile" { releaseCredentialBoundary() }
            if phase == "drain" { finishSessionWrite() }
            if phase == "publication" { world.releasePublication() }
        }
        func fixtureSettled() -> Bool { pendingCredentialBoundaries == 0 && !credentialBoundaryActive && activeSessionWrites == 0 }
        // @@ACTUAL_SIMKL_CLOUD_CLEAR@@
    }
    static func driver(_ service: String) -> any ClearDriver {
        if service == "trakt" { return TraktAuth() }
        return SIMKLAuth()
    }
    @MainActor static func cases(makeManager: () throws -> ProviderOAuthOriginalManager) async throws -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        for service in ["trakt", "simkl"] {
            for phase in ["turnstile", "drain", "publication"] {
                for revoked in [false, true] {
                    let manager = try makeManager(), source = AdoptionWorld.current
                    let state = hub.reset()
                    let auth = driver(service)
                    let capture = CredentialScopeRegistry.shared.capture()
                    let original = try manager.fixtureBoundCloudAuthority(plaintext: source.plaintext, revision: source.revision)
                    let authority = ObservedAuthority(original, observations: state)
                    let events = [service + "Access": VortxNativeProviderCredentials.Register(value: .null)]
                    let tokens = state.snapshot().tokens
                    await auth.fixtureArm(phase)
                    let task = Task { await auth.applyNativeCredentialClear(capture: capture, events: events, sourceAuthority: authority) }
                    await state.wait(phase)
                    if revoked {
                        manager.dataKey = Data(repeating: 0x42, count: 32); manager.dataKey = AdoptionWorld.key
                    }
                    await auth.fixtureRelease(phase)
                    let accepted = await task.value, actual = state.snapshot()
                    if revoked {
                        results.append((!accepted && actual.clearAttempts == 0 && actual.clears == 0
                            && actual.publications == 0 && actual.tokens == tokens,
                            "actual \(service) clear rejects retired original source after \(phase) without secure or nil effects"))
                    } else {
                        results.append((accepted && actual.clearAttempts == 1 && actual.clears == 1
                            && actual.publications == 1 && actual.tokens["owner"] == nil && actual.tokens["sibling"] == tokens["sibling"],
                            "actual \(service) clear accepts current original source after \(phase)"))
                    }
                    let actorSettled = await auth.fixtureSettled()
                    results.append((actual.boundaries == 0 && actual.sourceDepth == 0 && actorSettled,
                        "actual \(service) clear releases actor and publication boundaries after \(phase), revoked=\(revoked)"))
                    results.append((actual.publicationHeldBoundary && actual.publicationReleasedSource
                        && CredentialScopeRegistry.shared.capture() == capture && actual.registerCurrent,
                        "\(service) \(phase) source test preserves owner/registers and emits nil only outside source lock under publication boundary"))
                }
            }
            for refusal in ["register", "tuple"] {
                let manager = try makeManager(), source = AdoptionWorld.current
                let state = hub.reset()
                if refusal == "register" { state.refuseRegister() } else { state.refuseClear() }
                let auth = driver(service)
                let capture = CredentialScopeRegistry.shared.capture()
                let authority = try manager.fixtureBoundCloudAuthority(plaintext: source.plaintext, revision: source.revision)
                let tokens = state.snapshot().tokens
                let accepted = await auth.applyNativeCredentialClear(capture: capture,
                    events: [service + "Access": .init(value: .null)], sourceAuthority: authority)
                let actual = state.snapshot()
                results.append((!accepted && actual.clears == 0 && actual.publications == 0 && actual.tokens == tokens,
                    "actual \(service) source admission retains existing \(refusal) refusal"))
            }
            _ = try makeManager(); let state = hub.reset()
            let auth = driver(service)
            let accepted = await auth.applyNativeCredentialClear(capture: CredentialScopeRegistry.shared.capture(),
                events: [service + "Access": .init(value: .null)], sourceAuthority: nil)
            results.append((accepted && state.snapshot().publications == 1 && state.snapshot().boundaries == 0,
                "actual \(service) nil-source local clear retains its existing behavior"))
        }
        return results
    }
}
