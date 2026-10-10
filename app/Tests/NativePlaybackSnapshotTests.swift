import Foundation

// Generated fixture inserts exact declarations; no mirrored snapshot/binding predicates.
// PRODUCTION_JSON
// PRODUCTION_POLICY
typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target

struct VortxAccountScope: Equatable, Sendable { let ownerProfileID: String }
final class FixtureSession: Sendable {
    let scope = VortxAccountScope(ownerProfileID: "synthetic-owner")
}
final class CredentialScopeRegistry: @unchecked Sendable {
    struct Capture: Hashable { let generation: UUID }
    static let shared = CredentialScopeRegistry()
    var current = Capture(generation: UUID())
    func isCurrent(_ capture: Capture) -> Bool { capture == current }
}
final class ProfileStore: @unchecked Sendable {
    static let shared = ProfileStore()
    var activeID: UUID?
}

/// Peripheral scheduler only: a controlled owner change immediately after the captured
/// binding's lock transaction. Production declarations and their internal predicates are intact.
final class FixtureBridgeLock {
    private let lock = NSLock()
    var calls = 0
    var afterSecondUnlock: (() -> Void)?
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        calls += 1
        let ordinal = calls
        let value: T
        do { value = try body() } catch { lock.unlock(); throw error }
        lock.unlock()
        if ordinal == 2 { let action = afterSecondUnlock; afterSecondUnlock = nil; action?() }
        return value
    }
}

final class VortxNativeCoreFacade: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let session = FixtureSession()
    private var values: [String: VortxJSON]
    private var closed = false
    private var pendingProfileTransitions = 0
    private var accountEpoch = UUID()
    private var watchlistProfileGeneration = UUID()
    private var registryGeneration = UUID()
    init(profile: UUID, projection: VortxJSON?) {
        values = ["native_state": .object(["activeProfileId": .string(profile.uuidString)])]
        values["native_playback"] = projection
    }
    // PRODUCTION_FACADE
    func replaceProjection(_ projection: VortxJSON?) { lock.withLock { values["native_playback"] = projection } }
    func setPending(_ value: Int) { lock.withLock { pendingProfileTransitions = value } }
    func rotateAccount() { lock.withLock { accountEpoch = UUID() } }
    func select(_ profile: String) {
        lock.withLock {
            values["native_state"] = .object(["activeProfileId": .string(profile)])
            watchlistProfileGeneration = UUID()
        }
    }
    func revoke() { lock.withLock { closed = true; values.removeAll() } }
}

class FixtureBridge {
    let nativeFacadeLock = FixtureBridgeLock()
    var nativeFacadeStorage: VortxNativeCoreFacade?
    var nativeCredentialCapture: CredentialScopeRegistry.Capture?
    var nativeInstallGeneration = UUID()
    var nativePublishedAccountGeneration: UUID?
    init(facade: VortxNativeCoreFacade) {
        nativeFacadeStorage = facade
        nativeCredentialCapture = CredentialScopeRegistry.shared.current
        nativePublishedAccountGeneration = facade.accountGeneration
    }
}
final class CoreBridge: FixtureBridge {
    // PRODUCTION_BRIDGE
}
final class LegacyCoreBridge: FixtureBridge {
    // PRODUCTION_BASELINE_BRIDGE
}

@main struct NativePlaybackSnapshotTests {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL \(label)") }
    }
    static func projection(titles: Int) throws -> VortxJSON {
        var watched: [String: VortxJSON] = [:]
        var resume: [String: VortxJSON] = [:]
        var history: [VortxJSON] = []
        for i in 0..<titles {
            let id = "synthetic-title-\(i)"
            watched[id] = .array((0..<24).map { .string("\(id):1:\($0)") })
            resume[id] = .object(["offsetMs": .integer(Int64(i * 1000)), "durationMs": .integer(1_440_000), "videoId": .string("\(id):1:24")])
            history.append(.object(["metaId": .string(id), "videoId": .string("\(id):1:24"), "title": .string("Synthetic title \(i)"), "poster": .string("https://synthetic.invalid/poster/\(i)"), "progress": .number(0.125), "watched": .bool(false), "optional": .null]))
        }
        // Native playbackProjection decodes VortxJSON from JSON. Keep numeric representation
        // canonical in the same way, instead of inventing an unrepresentable in-memory payload.
        return try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(VortxJSON.object([
            "watchedVideoIdsByTitle": .object(watched), "resumeById": .object(resume),
            "history": .array(history), "continueWatching": .array(history),
            "largeUnsigned": .unsigned(UInt64.max), "negative": .integer(-2)
        ])))
    }
    @MainActor static func context(_ value: VortxJSON?) -> (UUID, VortxNativeCoreFacade, CoreBridge) {
        // Explicit alphabetic digits make the exact-case rejection deterministic.
        let profile = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        ProfileStore.shared.activeID = profile
        CredentialScopeRegistry.shared.current = .init(generation: UUID())
        let facade = VortxNativeCoreFacade(profile: profile, projection: value)
        return (profile, facade, CoreBridge(facade: facade))
    }
    @MainActor static func facadeTests(_ value: VortxJSON) throws {
        let (profile, facade, bridge) = context(value)
        let receipt = facade.watchlistBinding!
        let legacy = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_playback")!)
        check(facade.playbackSnapshot(expected: receipt) == legacy, "typed snapshot equals actual legacy roundtrip")
        check(bridge.nativePlaybackSnapshot() == legacy, "actual bridge returns identical legacy value")
        let retained = facade.playbackSnapshot(expected: receipt)!
        guard case .object(var changed) = retained else { fatalError("fixture root") }
        changed["watchedVideoIdsByTitle"] = .object(["synthetic-title-0": .array([.string("new-episode")])])
        facade.replaceProjection(.object(changed))
        check(retained == legacy, "retained owned snapshot survives facade replacement")
        check(bridge.nativePlaybackSnapshot() == .object(changed), "fresh change is read without a stale cache")
        changed["history"] = .array([])
        check(facade.playbackSnapshot(expected: receipt)?["history"] == legacy["history"], "caller COW mutation cannot change facade")
        facade.replaceProjection(.null)
        check(bridge.nativePlaybackSnapshot() == .null, "present JSON null remains present")
        facade.replaceProjection(nil)
        check(bridge.nativePlaybackSnapshot() == nil, "missing projection remains missing")
        facade.replaceProjection(value)
        facade.setPending(1)
        check(facade.playbackSnapshot(expected: receipt) == nil, "typed accessor rejects pending transition")
        check(bridge.nativePlaybackSnapshot() == nil, "bridge rejects pending transition")
        facade.setPending(0)
        check(facade.playbackSnapshot(expected: receipt) == value, "cleared pending transition remains fresh")
        let wrongProfile = VortxNativeCoreFacade.WatchlistBinding(scope: receipt.scope, profileID: "wrong-profile", accountGeneration: receipt.accountGeneration, profileGeneration: receipt.profileGeneration)
        check(facade.playbackSnapshot(expected: wrongProfile) == nil, "profile mismatch rejected independently of generations")
        let wrongCase = VortxNativeCoreFacade.WatchlistBinding(scope: receipt.scope, profileID: profile.uuidString.lowercased(), accountGeneration: receipt.accountGeneration, profileGeneration: receipt.profileGeneration)
        check(facade.playbackSnapshot(expected: wrongCase) == nil, "profile spelling checked without generation mismatch")
        facade.select(profile.uuidString.lowercased())
        check(facade.playbackSnapshot(expected: receipt) == nil, "exact profile string required")
        facade.select(profile.uuidString)
        check(facade.playbackSnapshot(expected: receipt) == nil, "profile ABA cannot revive old receipt")
        check(bridge.nativePlaybackSnapshot() == value, "new read captures acknowledged profile generation")
        let selected = facade.watchlistBinding!
        let wrongScope = VortxNativeCoreFacade.WatchlistBinding(scope: .init(ownerProfileID: "other-owner"), profileID: selected.profileID, accountGeneration: selected.accountGeneration, profileGeneration: selected.profileGeneration)
        check(facade.playbackSnapshot(expected: wrongScope) == nil, "scope mismatch rejected")
        facade.rotateAccount(); facade.rotateAccount()
        check(facade.playbackSnapshot(expected: selected) == nil, "account ABA rejects old receipt")
        check(bridge.nativePlaybackSnapshot() == nil, "unpublished account generation rejected by bridge")
        bridge.nativePublishedAccountGeneration = facade.accountGeneration
        check(bridge.nativePlaybackSnapshot() == value, "acknowledged new account gets fresh value")
        let beforeClose = facade.watchlistBinding!
        facade.revoke()
        check(facade.playbackSnapshot(expected: beforeClose) == nil, "revoked facade rejected")
        check(bridge.nativePlaybackSnapshot() == nil, "bridge rejects revoked facade")
        check(retained == legacy, "held owned value survives revocation without reauthorization")
    }
    @MainActor static func bridgeRaces(_ value: VortxJSON) {
        for scenario in 0..<7 {
            let (profile, facade, bridge) = context(value)
            var fired = false
            bridge.nativeFacadeLock.afterSecondUnlock = {
                fired = true
                switch scenario {
                case 0: CredentialScopeRegistry.shared.current = .init(generation: UUID())
                case 1: bridge.nativeFacadeStorage = VortxNativeCoreFacade(profile: profile, projection: value)
                case 2: bridge.nativeInstallGeneration = UUID()
                case 3: facade.setPending(1)
                case 4: facade.rotateAccount(); bridge.nativePublishedAccountGeneration = facade.accountGeneration
                case 5:
                    facade.select(UUID().uuidString); facade.select(profile.uuidString)
                    // Real host profile acknowledgement retires the installation generation too.
                    bridge.nativeInstallGeneration = UUID()
                default: ProfileStore.shared.activeID = UUID()
                }
            }
            let result = bridge.nativePlaybackSnapshot()
            check(fired, "race \(scenario) scheduled after actual captured binding")
            check(result == nil, "race \(scenario) cannot accept another owner/transition snapshot")
        }
    }
    @MainActor static func benchmark() throws {
        let value = try projection(titles: 1_500)
        let (_, facade, current) = context(value)
        let legacy = LegacyCoreBridge(facade: facade)
        let bytes = try JSONEncoder().encode(value).count
        check(current.nativePlaybackSnapshot() == legacy.nativePlaybackSnapshot(), "large independently decoded projection matches old value")
        let legacyIterations = 20, typedIterations = 10_000
        var checksum = 0
        let legacyStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<legacyIterations { checksum += legacy.nativePlaybackSnapshot()?["history"]?.array?.count ?? -1 }
        let legacyNS = DispatchTime.now().uptimeNanoseconds - legacyStart
        let typedStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<typedIterations { checksum += current.nativePlaybackSnapshot()?["history"]?.array?.count ?? -1 }
        let typedNS = DispatchTime.now().uptimeNanoseconds - typedStart
        check(checksum == (legacyIterations + typedIterations) * 1_500, "benchmark values consumed")
        print(String(format: "TIMING titles=1500 watchedIDs=36000 bytes=%d legacyIterations=%d typedIterations=%d legacyMeanMs=%.6f candidateMeanMs=%.6f", bytes, legacyIterations, typedIterations, Double(legacyNS) / Double(legacyIterations) / 1e6, Double(typedNS) / Double(typedIterations) / 1e6))
    }
    @MainActor static func main() throws {
        let value = try projection(titles: 3)
        try facadeTests(value)
        bridgeRaces(value)
        if failures == 0 && ProcessInfo.processInfo.environment["VORTX_SNAPSHOT_SKIP_BENCHMARK"] != "1" { try benchmark() }
        print("Native playback snapshot: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
