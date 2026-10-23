import Foundation
import CryptoKit

private final class PreferenceCheckpointGate: VortxCheckpointStore, @unchecked Sendable {
    let backing: VortxEncryptedCheckpointStore
    private let condition = NSCondition()
    private var held = false
    private var entered = false
    init(_ backing: VortxEncryptedCheckpointStore) { self.backing = backing }
    func holdNext() { condition.withLock { held = true; entered = false } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
    func waitUntilEntered() async throws {
        for _ in 0..<400 {
            if condition.withLock({ entered }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw VortxNativeError.superseded
    }
    private func wait() {
        condition.lock(); defer { condition.unlock() }
        if held { entered = true; while held { condition.wait() } }
    }
    func read(scope: VortxAccountScope) throws -> String? { try backing.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { try backing.readHostPreferences(scope: scope) }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { try backing.readLegacyMaterial(scope: scope) }
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? { try backing.readLegacyProfileEdits(scope: scope) }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws { wait(); try backing.commit(snapshot, scope: scope) }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        wait(); try backing.commit(snapshot, scope: scope, hostPreferences: hostPreferences)
    }
}

/// Mechanism proof against the actual packaged C ABI. The sync lane separately tests its pure
/// group-specific predicate. No app, customer account, Keychain, provider or media is involved.
@main @MainActor enum NativeProfilePreferenceAdmissionLiveTests {
    enum Failure: Error { case assertion(String) }
    nonisolated static let owner = "10000000-0000-0000-0000-000000000031"
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func host(_ facade: VortxNativeCoreFacade) throws -> VortxJSON {
        try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_host_preferences")!)
    }
    static func waitForQueuedProfile(_ facade: VortxNativeCoreFacade) async throws {
        for _ in 0..<400 {
            if facade.registryBinding == nil { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure.assertion("profile replay did not reach the real FIFO behind the held peer mutation")
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL native preference FIFO: \(error)"); exit(1) }
    }
    static func run() async throws {
        let scope = VortxAccountScope(account: "synthetic.profile-preference-fifo", ownerProfileID: owner)
        let store = try VortxEncryptedCheckpointStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]), key: SymmetricKey(size: .bits256))
        let gate = PreferenceCheckpointGate(store)
        let transport = try VortxCResourceTransport()
        let session = try VortxNativeSession(scope: scope, ownerName: "Synthetic Owner", abi: VortxCABI(), store: gate, transport: transport, allowNewAccount: true)
        let localPreferences = UserProfile.PlaybackPrefs(audioLang: "en", subtitleLang: "en", forcedPolicy: "auto", subFont: "system", subSize: "medium", subColor: "white", subBackground: "off")
        let localValue = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(localPreferences))
        _ = try await session.dispatch([raw(.object(["type": .string("get_state")]))], now: 1000,
                                      hostEdits: [.init(profileID: owner, fields: ["playback": localValue])])
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: session.resourceRegistry(), changed: { _ in })
        let epoch = facade.accountGeneration
        let credential = CredentialScopeRegistry.Capture(generation: 1)
        let authorityCore = CoreBridge(facade, credential)
        let installAuthority = authorityCore.captureAuthority()
        try check(installAuthority(), "exact Bridge authority did not accept its installation")
        authorityCore.rotateInstallation()
        try check(!installAuthority(), "exact Bridge authority accepted a superseding installation")
        let credentialAuthority = authorityCore.captureAuthority()
        CredentialScopeRegistry.shared.rotate()
        try check(!credentialAuthority(), "exact Bridge authority accepted stale credential generation")
        let newCore = CoreBridge(facade, .init(generation: 2))
        let facadeAuthority = newCore.captureAuthority()
        try check(facadeAuthority(), "fresh synthetic authority did not accept")
        newCore.retireFacade()
        try check(!facadeAuthority(), "exact Bridge authority accepted retired facade")
        print("Exact Bridge admission authority strict Swift6 proof: synthetic credential/install/facade fences; no actual credential access")
        let originalHost = try host(facade)
        let savedRegister = originalHost["profiles"]?[owner]?["fields"]?["playback"]
        try check(savedRegister != nil, "missing saved preference revision")
        var peer = try VortxNativeHostPreferences(scope: scope, actor: "30000000-0000-0000-0000-000000000031")
        try peer.merge(originalHost, scope: scope)
        var peerPreferences = localPreferences; peerPreferences.audioLang = "hi"
        let peerValue = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(peerPreferences))
        try peer.edit(profileID: owner, fields: ["playback": peerValue], scope: scope)
        let peerDocument = try peer.document
        gate.holdNext()
        let precedingPeer = Task { try await facade.mergeAccountDocument(nil, hostRemote: peerDocument, legacyMaterial: nil) }
        try await gate.waitUntilEntered()
        // This immutable saved revision is deliberately not recaptured after the queued peer lands.
        let admission: @Sendable (VortxJSON, VortxJSON) -> Bool = { state, currentHost in
            state["activeProfileId"] == .string(owner) && currentHost["profiles"]?[owner]?["fields"]?["playback"] == savedRegister
        }
        let staleReplay = Task { () throws -> Bool in
            do {
                try await facade.mutateProfiles([], hostEdits: [.init(profileID: owner, fields: ["playback": localValue])],
                                                expectedProfileID: owner, expectedAccountGeneration: epoch, preferenceAdmission: admission)
                return true
            } catch VortxNativeError.superseded { return false }
        }
        try await waitForQueuedProfile(facade)
        gate.release()
        _ = try await precedingPeer.value
        let staleAccepted = try await staleReplay.value
        let afterPeer = try host(facade)
        try check(!staleAccepted && afterPeer["profiles"]?[owner]?["fields"]?["playback"]?["value"] == peerValue,
                  "queued stale preference replay overwrote the preceding accepted peer register")
        print("GREEN actual native FIFO: queued peer host register commits first; stale immutable preference receipt rejects before checkpoint")
        let currentRegister = afterPeer["profiles"]?[owner]?["fields"]?["playback"]
        let freshAdmission: @Sendable (VortxJSON, VortxJSON) -> Bool = { state, currentHost in
            state["activeProfileId"] == .string(owner) && currentHost["profiles"]?[owner]?["fields"]?["playback"] == currentRegister
        }
        gate.holdNext()
        let progress: VortxJSON = .object(["type": .string("report_progress"), "metaId": .string("synthetic.movie"), "name": .string("Synthetic Movie"),
            "positionMs": .integer(10000), "durationMs": .integer(100000), "metadata": .object(["type": .string("movie")])])
        try check(facade.dispatchForProfile(progress, profileID: owner, expectedAccountGeneration: epoch), "unrelated progress was not admitted")
        try await gate.waitUntilEntered()
        let currentReplay = Task {
            try await facade.mutateProfiles([], hostEdits: [.init(profileID: owner, fields: ["playback": localValue])],
                                            expectedProfileID: owner, expectedAccountGeneration: epoch, preferenceAdmission: freshAdmission)
        }
        try await waitForQueuedProfile(facade)
        gate.release(); try await currentReplay.value
        try check(try host(facade)["profiles"]?[owner]?["fields"]?["playback"]?["value"] == localValue, "unrelated native progress wrongly rejected current preference intent")
        let rename: VortxJSON = .object(["type": .string("patch_profile"), "id": .string(owner),
            "edits": .array([.object(["field": .string("name"), "value": .string("Ordinary UI Owner")])])])
        try await facade.mutateProfiles([rename], hostEdits: [], expectedProfileID: owner, expectedAccountGeneration: epoch)
        let ordinaryState = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_state")!)
        try check(ordinaryState["roster"]?["profiles"]?[owner]?["name"]?["value"] == .string("Ordinary UI Owner") ||
                  ordinaryState["roster"]?["profiles"]?[owner]?["name"] == .string("Ordinary UI Owner"), "ordinary default-nil profile API changed")
        do {
            try await facade.mutateProfiles([], hostEdits: [.init(profileID: owner, fields: ["playback": peerValue])],
                                            expectedProfileID: owner, expectedAccountGeneration: UUID(), preferenceAdmission: freshAdmission)
            throw Failure.assertion("foreign account epoch admitted")
        } catch VortxNativeError.superseded {}
        print("GREEN current revision survives unrelated real native progress; ordinary nil-admission profile edit unchanged; foreign account epoch rejects")
        await facade.shutdown()
    }
}
