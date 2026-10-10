import Foundation
import CryptoKit
import CoreFoundation

// Only environment collaborators are fixtures. The test driver extracts the production
// manager's admission, merge, encryption/ACK and revision-retry methods verbatim below.
// Native state uses the real static C ABI and production encrypted checkpoint/session.
private enum CredentialScopeRegistry {
    enum Scope { case account }
    struct Capture: Equatable { let generation: Int; var namespace: String { "account.apple-sync-fixture" }; var scope: Scope { .account } }
}
private struct ManagerPlaybackBinding: Equatable { let credential: CredentialScopeRegistry.Capture; let profileID: UUID }
private enum ManagerPlaybackMutationTarget: Equatable {
    case native(ManagerPlaybackBinding?)
    var binding: ManagerPlaybackBinding? { if case .native(let binding) = self { return binding }; return nil }
    var generation: Int {
        switch self { case .native(let binding): binding?.credential.generation ?? -1 }
    }
    @MainActor func stillOwnsCurrentContext(core: CoreBridge) -> Bool { generation == core.generation }
}
@MainActor private final class FixtureAuthority {
    var generation = 1
    func capture() -> CredentialScopeRegistry.Capture { .init(generation: generation) }
}
private enum DiagnosticsLog { static func log(_ category: String, _ text: String) {} }
@MainActor private enum UserDefaults {
    static let standard = FixtureDefaults()
    final class FixtureDefaults {
        private(set) var values: [String: Any] = [:]
        func object(forKey: String) -> Any? { values[forKey] }
        func dictionary(forKey: String) -> [String: Any]? { values[forKey] as? [String: Any] }
        func persistentDomain(forName: String) -> [String: Any]? { values }
        func set(_ value: Any?, forKey: String) { values[forKey] = value }
        func removeObject(forKey: String) { values.removeValue(forKey: forKey) }
    }
}
private enum SettingsBackup {
    static func isSyncable(_ key: String) -> Bool { true }
    static func migratedKey(_ key: String) -> String { key }
}
// ProfileStore's fixture environment and its production acknowledgement/retry methods are
// appended by the extractor. Its save handler below performs an actual native transaction.
private struct AddonOrderIntent {}
private enum AddonOrderSyncPolicy {
    static func acknowledges(_ pending: AddonOrderIntent?, sent: AddonOrderIntent?, accountID: String) -> Bool { false }
}
private struct NativePreferenceLocalAdmission {
    let target: ManagerPlaybackMutationTarget
    let intent: NativePreferenceIntentStore.Intent
}
private struct FixtureProviders { var document: VortxJSON { .object([:]) } }

@MainActor private final class CoreBridge {
    static let shared = CoreBridge()
    var session: VortxNativeSession?
    var generation = 1
    private var snapshots: [String: Data] = [:]
    struct RegistryBinding { let scope: VortxAccountScope }
    var nativeRegistryBinding: RegistryBinding? {
        session.map { _ in RegistryBinding(scope: VortxAccountScope(account: AppleSyncManagerPeer.account, ownerProfileID: AppleSyncManagerPeer.owner)) }
    }
    func stateData(_ name: String) -> Data? { snapshots[name] }
    func captureNativePlaybackTarget() -> ManagerPlaybackMutationTarget {
        .native(.init(credential: .init(generation: generation), profileID: UUID(uuidString: AppleSyncManagerPeer.owner)!))
    }
    func capture(_ data: Data, for name: String) { snapshots[name] = data }
    func saveNativeProfile(_ profile: UserProfile, creating: Bool, target: ManagerPlaybackMutationTarget,
                           preferenceAdmission: (@Sendable (VortxJSON, VortxJSON) -> Bool)? = nil) async throws {
        ProfileStore.shared.saves += 1
        if let preferenceAdmission {
            guard let stateBytes = stateData("native_state"), let hostBytes = stateData("native_host_preferences"),
                  let state = try? JSONDecoder().decode(VortxJSON.self, from: stateBytes),
                  let host = try? JSONDecoder().decode(VortxJSON.self, from: hostBytes), preferenceAdmission(state, host) else {
                throw VortxNativeError.superseded
            }
        }
        guard target.stillOwnsCurrentContext(core: self), let save = ProfileStore.shared.saveHandler,
              await save(profile), target.stillOwnsCurrentContext(core: self) else { throw VortxNativeError.superseded }
    }
    func reportNativeProfileFailure(_ operation: String, error: Error) {}
    var hasNativeSession: Bool { session != nil }
    func hasCertifiedNativeSession(capture: CredentialScopeRegistry.Capture, profileID: UUID?) -> Bool {
        session != nil && capture.generation == generation && profileID == ProfileStore.shared.activeID
    }
    func settleResidentNativeSession(capture: CredentialScopeRegistry.Capture) async {}
    func mergeNativeAccountDocument(_ remote: VortxJSON?, hostRemote: VortxJSON?, capture: CredentialScopeRegistry.Capture,
        legacyMaterial: Data, hostEdits: [VortxNativeHostPreferences.Edit] = [], websiteEvents: [Int], websiteAddonEvents: [Int],
        legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]], sourceAuthority: Int?, authenticatedSourceArchive: Data?) async throws -> VortxJSON {
        guard capture.generation == generation, let session else { throw VortxNativeError.superseded }
        let action = remote.map { VortxJSON.object(["type": .string("merge_native_sync"), "document": $0]) }
            ?? .object(["type": .string("get_state")])
        _ = try await session.dispatch([String(decoding: JSONEncoder().encode(action), as: UTF8.self)], now: 100,
                                       hostRemote: hostRemote, hostEdits: hostEdits)
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        let host = try await session.hostPreferencesDocument()
        snapshots["native_state"] = try JSONEncoder().encode(state)
        snapshots["native_host_preferences"] = try JSONEncoder().encode(host)
        return .object(["nativeSync": state["nativeSync"]!, "nativeHostPreferences": host,
                        "profileEditResults": .object([:])])
    }
}

@MainActor private final class ManagerHarness {
    static var shared: ManagerHarness!
    struct Command: Decodable {
        let mode: String; let directory: String; let baseURL: String; let actor: String
        var actions: [VortxJSON]?; var edits: [Edit]?; var pendingProjection: Bool?
        var missingSession: Bool?; var restoreFails: Bool?; var retireDuringEnsure: Bool?
        var editDuringPUT: [VortxJSON]?; var retireDuringPUT: Bool?; var keyABA: Bool?
        var projectionSaveFails: Bool?; var pendingPlayback: Bool?; var pendingDiscovery: Bool?
        var preferenceCommand: String?; var preferenceValue: String?
        var projectionStamp: Double?; var projectionValue: String?
    }
    struct Edit: Decodable { let profileID: String?; let fields: [String: VortxJSON] }
    struct Account { let id: String }
    let command: Command
    let credentialAuthority = FixtureAuthority()
    var account: Account? = Account(id: AppleSyncManagerPeer.account)
    var dataKey: Data? = AppleSyncManagerPeer.key
    var isSignedIn = true
    var hasAppliedAccountDoc = true
    var dirtySettings: [String: Double] = [:]
    private var settingsShadow: [String: Any] = [:]
    var nativeLegacyWatchlistPending = Set<String>()
    var nativeUnsupportedSettings: [String] = []
    var pendingAddonOrderIntent: AddonOrderIntent?
    var activeSyncUp: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    var syncUpCompletionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    var activeSyncDown: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    var nativePreparedSeedCapture: CredentialScopeRegistry.Capture?
    var lastSyncedVersion = 0
    var stamped = 0
    var ensureCalls = 0
    var putVersions: [Int] = []
    var isApplyingRemote = false
    var nativePushQueue = NativeForegroundSyncPolicy.PushQueue()
    var nativeDurablePushPending = false
    var pendingSync: Task<Void, Never>?
    var pendingSyncCapture: CredentialScopeRegistry.Capture?
    var pendingSyncID: UUID?
    var realtimeActive = false
    var nativePreferenceIntentStatus = "idle"
    var nativePreferenceLocalAdmissions: [UUID: [NativePreferenceIntentStore.Group: NativePreferenceLocalAdmission]] = [:]
    let nativePreferenceAdmissionGate = NativePreferenceIntentStore.AdmissionGate()
    var hasPendingPush: Bool { nativePushQueue.hasPendingPush || nativeDurablePushPending }
    static let writeSyncDocV2 = true
    init(_ command: Command) {
        self.command = command
        Self.shared = self
        ProfileStore.shared.active = UserProfile(id: UUID(uuidString: AppleSyncManagerPeer.owner)!, name: "Fixture owner", avatar: "", isOwner: true)
    }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { credentialAuthority.capture() == capture }
    private func currentSyncableDomain() -> [String: Any] {
        UserDefaults.standard.persistentDomain(forName: "fixture") ?? [:]
    }
    func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { false }
    func settleNativeProviderJournal(capture: CredentialScopeRegistry.Capture) async -> Bool { isCurrent(capture) }
    func restoreAccountDocIfNeeded(credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool { hasAppliedAccountDoc }
    func syncDown(force: Bool, credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool { false }
    func withRemoteApplySuppressed(_ body: () -> Void) { body() }
    func publishAppliedAddonOrder(_ order: [String]) {}
    func nativeEmptyAccountDocument(capture: CredentialScopeRegistry.Capture) throws -> [String: Any] { ["fixtureSibling": "retained"] }
    func mergedNativeProviderState(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws -> FixtureProviders { FixtureProviders() }
    struct Preparation { let material = Data(); let authority: Int? = nil; let sourceArchive: Data? = nil }
    func prepareNativeLegacyMaterial(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) async throws -> Preparation { Preparation() }
    static func nativeWebsiteEvents(_ doc: [String: Any]) throws -> [Int] { [] }
    static func nativeWebsiteAddonEvents(_ doc: [String: Any]) throws -> [Int] { [] }
    func nativeLegacyWatchlists(_ doc: [String: Any]) throws -> [UUID: [VortxNativeWatchlist.Entry]] { [:] }
    func publishNativeWebsiteOutcome(_ value: VortxJSON, capture: CredentialScopeRegistry.Capture) throws {}
    func persistMergedNativeProviders(_ value: FixtureProviders, capture: CredentialScopeRegistry.Capture) throws -> FixtureProviders { value }
    func mirrorNativeProviderKeys(_ value: FixtureProviders, original: Any?) throws -> [String: Any] { [:] }
    func applyNativeGlobals(_ host: VortxJSON) {}
    func rememberNativeBackup(capture: CredentialScopeRegistry.Capture) -> Bool { isCurrent(capture) }
    func acknowledgeNativeProviders(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws {}
    func persistLastSyncedVersion() {}
    static func markSawDocV2(_ account: String) {}
    func stampSyncSuccess() { stamped += 1 }
    static func documentVersion(_ raw: Any?) -> Int? { raw as? Int }
    static func decodeDecryptedSyncDocument(_ data: Data) throws -> [String: Any] {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VortxNativeError.invalidSnapshot }
        return doc
    }
    func openSyncDocument(_ value: String, version: Int) -> Data? {
        VortXSyncCrypto.openDocument(dataKey: dataKey!, stored: value, accountId: account!.id, version: version)
    }
    func retire() {
        credentialAuthority.generation += 1
        CoreBridge.shared.generation = credentialAuthority.generation
    }
    func restoreNativeCheckpoint(credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool {
        ensureCalls += 1
        if command.retireDuringEnsure == true { retire(); return false }
        if command.restoreFails == true { return false }
        do { try await mount(); return isCurrent(capture) } catch { return false }
    }
    func mount() async throws {
        if CoreBridge.shared.session != nil { return }
        let scope = VortxAccountScope(account: AppleSyncManagerPeer.account, ownerProfileID: AppleSyncManagerPeer.owner)
        let store = try VortxEncryptedCheckpointStore(directory: URL(fileURLWithPath: command.directory),
            key: SymmetricKey(data: AppleSyncManagerPeer.key), installationKey: SymmetricKey(data: Data(repeating: 2, count: 32)))
        CoreBridge.shared.session = try VortxNativeSession(scope: scope, ownerName: "Fixture owner", abi: VortxCABI(), store: store,
            transport: AppleSyncManagerPeer.NoResources(), allowNewAccount: true, hostActor: command.actor)
        try await publishProfiles()
        let profiles = ProfileStore.shared
        if let playback = profiles.active?.playback { profiles.flatPlayback = playback }
        if let discovery = profiles.active?.discovery { profiles.flatDiscovery = discovery }
        ThemeManager.shared.accentID = profiles.active?.accentID ?? "ember"
        ThemeManager.shared.oled = profiles.active?.oled ?? false
        ThemeManager.shared.textScale = profiles.active?.textScale ?? 1
        profiles.establishBaselines()
        try await refreshSnapshots()
        profiles.saveHandler = { [weak self] profile in
            guard let self, let session = CoreBridge.shared.session, !ProfileStore.shared.failSave else { return false }
            do {
                let mutation = try VortxNativeProfiles.mutation(profile, previous: ProfileStore.shared.active, ownerID: AppleSyncManagerPeer.owner)
                _ = try await session.dispatch(mutation.0.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }, now: 100, hostEdits: [mutation.1])
                try await self.publishProfiles()
                return true
            } catch { return false }
        }
    }
    func publishProfiles() async throws {
        guard let session = CoreBridge.shared.session else { throw VortxNativeError.unavailable }
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        let projected = try VortxNativeProfiles.project(state: state, host: await session.hostPreferencesDocument(), baseline: [])
        ProfileStore.shared.active = projected.first { $0.id.uuidString == AppleSyncManagerPeer.owner }
        try await refreshSnapshots()
    }
    func refreshSnapshots() async throws {
        guard let session = CoreBridge.shared.session else { throw VortxNativeError.unavailable }
        CoreBridge.shared.capture(Data(try await session.stateJSON().utf8), for: "native_state")
        CoreBridge.shared.capture(try JSONEncoder().encode(await session.hostPreferencesDocument()), for: "native_host_preferences")
    }
    func nativePreferenceStore(capture: CredentialScopeRegistry.Capture) throws -> NativePreferenceIntentStore {
        guard isCurrent(capture), case .account = capture.scope else { throw VortxNativeError.superseded }
        return NativePreferenceIntentStore(directoryURL: URL(fileURLWithPath: command.directory).appendingPathComponent("intent-journal", isDirectory: true),
            key: AppleSyncManagerPeer.key, namespace: capture.namespace)
    }
    func cancelDebouncedSyncForProcessExit() async {
        pendingSync?.cancel()
        await pendingSync?.value
        pendingSync = nil; pendingSyncCapture = nil; pendingSyncID = nil
        nativePushQueue = .init(); nativeDurablePushPending = false
    }
    func editedTheme(_ accent: String) -> UserProfile {
        var profile = ProfileStore.shared.active!
        profile.accentID = accent
        return profile
    }
    func generationFixtureSnapshots() throws -> (VortxJSON, VortxJSON) {
        guard let state = CoreBridge.shared.stateData("native_state"),
              let host = CoreBridge.shared.stateData("native_host_preferences") else { throw VortxNativeError.invalidSnapshot }
        return (try JSONDecoder().decode(VortxJSON.self, from: state), try JSONDecoder().decode(VortxJSON.self, from: host))
    }
    func generationFixtureExport() throws -> [String: Any] {
        let (state, host) = try generationFixtureSnapshots()
        guard let native = state["nativeSync"] else { throw VortxNativeError.invalidSnapshot }
        let encoded = try JSONEncoder().encode(VortxJSON.object(["nativeSync": native, "nativeHostPreferences": host]))
        guard let document = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw VortxNativeError.invalidSnapshot }
        return document
    }
    func profile(for intent: NativePreferenceIntentStore.Intent) throws -> UserProfile {
        var profile = ProfileStore.shared.active!
        switch intent.group {
        case .theme:
            profile.accentID = try intent.desired["accentID"]!.decode(String.self)
            profile.oled = try intent.desired["oled"]!.decode(Bool.self)
            profile.textScale = try intent.desired["textScale"]!.decode(Double.self)
        case .playback, .discovery: throw VortxNativeError.invalidSnapshot
        }
        return profile
    }
    nonisolated private static func setting(_ value: VortxJSON, path: [String], value replacement: VortxJSON) -> VortxJSON {
        guard let key = path.first, case .object(var object) = value else { return value }
        if path.count == 1 { object[key] = replacement }
        else { object[key] = setting(object[key] ?? .object([:]), path: Array(path.dropFirst()), value: replacement) }
        return .object(object)
    }
    nonisolated private static func bumped(_ value: VortxJSON) -> VortxJSON {
        switch value {
        case .integer(let number): return .integer(number + 1)
        case .unsigned(let number): return .unsigned(number + 1)
        case .number(let number): return .number(number + 1)
        case .string(let string): return .string(string + "-changed")
        case .object(let object):
            guard let key = object.keys.sorted().first else { return .object(["changed": .bool(true)]) }
            var copy = object; copy[key] = bumped(copy[key]!); return .object(copy)
        case .array(let values):
            guard !values.isEmpty else { return .array([.bool(true)]) }
            var copy = values; copy[0] = bumped(copy[0]); return .array(copy)
        case .bool(let flag): return .bool(!flag)
        case .null: return .string("changed")
        }
    }
    func commitWithoutPreferenceAcknowledgement(_ intent: NativePreferenceIntentStore.Intent) async throws {
        guard let binding = CoreBridge.shared.captureNativePlaybackTarget().binding,
              binding.credential == credentialAuthority.capture() else { throw VortxNativeError.superseded }
        var profile = ProfileStore.shared.active!
        switch intent.group {
        case .theme:
            profile.accentID = try intent.desired["accentID"]!.decode(String.self)
            profile.oled = try intent.desired["oled"]!.decode(Bool.self)
            profile.textScale = try intent.desired["textScale"]!.decode(Double.self)
        case .playback:
            profile.playback = try intent.desired["playback"]?.decode(UserProfile.PlaybackPrefs.self)
            profile.addonPreferences = try intent.desired["addonPreferences"]?.decode(ProfileAddonPreferences.self)
        case .discovery:
            profile.discovery = try intent.desired.decode(ProfileDiscoveryPreferences.self)
        }
        try await CoreBridge.shared.saveNativeProfile(profile, creating: false, target: .native(binding))
    }
    func edit(_ actions: [VortxJSON], edits: [Edit] = []) async throws {
        guard let session = CoreBridge.shared.session else { throw VortxNativeError.unavailable }
        _ = try await session.dispatch(actions.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }, now: 100,
            hostEdits: edits.map { .init(profileID: $0.profileID, fields: $0.fields) })
    }
    func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool,
                 credentialCapture capture: CredentialScopeRegistry.Capture) async -> (Int, [String: Any]?) {
        guard isCurrent(capture), let base = URL(string: command.baseURL), base.scheme == "http", base.host == "127.0.0.1",
              let url = URL(string: path, relativeTo: base) else { return (0, nil) }
        do {
            var req = URLRequest(url: url); req.httpMethod = method
            req.setValue("Bearer synthetic-fixture-only", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            if method == "PUT" {
                putVersions.append(body?["version"] as? Int ?? -1)
                if let actions = command.editDuringPUT, putVersions.count == 1 {
                    try await edit(actions)
                    nativePushQueue.request(); nativeDurablePushPending = true
                }
            }
            let (data, response) = try await URLSession.shared.data(for: req)
            if method == "PUT", command.retireDuringPUT == true { retire() }
            if method == "PUT", command.keyABA == true {
                dataKey = Data(repeating: 3, count: 32); retire(); dataKey = AppleSyncManagerPeer.key; retire()
            }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, try JSONSerialization.jsonObject(with: data) as? [String: Any])
        } catch { return (0, nil) }
    }
    func run() async throws -> [String: VortxJSON] {
        if let stamp = command.projectionStamp {
            let key = "stremiox.theme.accent"
            UserDefaults.standard.set(command.projectionValue ?? "violet", forKey: key)
            settingsShadow = currentSyncableDomain()
            dirtySettings[key] = stamp
        }
        if command.pendingProjection == true { dirtySettings["stremiox.theme.accent"] = 1 }
        if command.missingSession != true { try await mount() }
        ProfileStore.shared.failSave = command.projectionSaveFails == true
        if command.pendingProjection == true { ThemeManager.shared.accentID = "violet" }
        if command.pendingPlayback == true { dirtySettings["fixture.playback"] = 1; ProfileStore.shared.flatPlayback.audioLang = "hi" }
        if command.pendingDiscovery == true { dirtySettings["stremiox.catalog.order"] = 1; ProfileStore.shared.flatDiscovery.catalogOrder = ["fixture-catalog"] }
        var result: [String: VortxJSON] = [:]
        if let preferenceCommand = command.preferenceCommand {
            let target = CoreBridge.shared.captureNativePlaybackTarget()
            switch preferenceCommand {
            case "failed-preference-queue-drain":
                // Discovering a new durable intent inside an older upload queues one follow-up.
                // Exercise both actual workers in this process; a new process would reset the
                // transport queue and could hide starvation of the live pending generation.
                let store = try nativePreferenceStore(capture: credentialAuthority.capture())
                requestSyncSoon()
                await pendingSync?.value
                let pending = try store.pending()
                let firstContext = try nativePreferenceContext(profileID: UUID(uuidString: AppleSyncManagerPeer.owner)!, target: target)
                let native = try Self.nativePreferenceSnapshot(firstContext, group: .theme)
                guard stamped == 1, hasPendingPush, pending.count == 1, pending[0].group == .theme,
                      pending[0].desired["accentID"] == .string("violet"),
                      pending[0].projectionStamps["stremiox.theme.accent"] == 1,
                      dirtySettings["stremiox.theme.accent"] == 1,
                      native.value["accentID"] == .string("ember") else { throw VortxNativeError.invalidSnapshot }
                result["queueDrainFirstUploadRetainedNewIntent"] = .bool(true)
                requestSyncSoon()
                await pendingSync?.value
                let after = try store.pending()
                let secondContext = try nativePreferenceContext(profileID: UUID(uuidString: AppleSyncManagerPeer.owner)!, target: target)
                let afterNative = try Self.nativePreferenceSnapshot(secondContext, group: .theme)
                guard stamped == 2, !hasPendingPush, after == pending, afterNative == native,
                      dirtySettings["stremiox.theme.accent"] == 1 else { throw VortxNativeError.invalidSnapshot }
                result["queueDrainRetainedExactPreferenceReceipt"] = .bool(true)
                result["queueDrainNativeUnchanged"] = .bool(true)
                result["accepted"] = .bool(true)
            case "generation-capacity":
                // Actual extracted manager prepare/admit/finish and ProfileStore.saveNative,
                // with the production C ABI/checkpoint. FIFO scheduling is covered separately
                // by the facade harness, not by this environment collaborator.
                let capture = credentialAuthority.capture()
                var previous: (NativePreferenceIntentStore.Intent, @Sendable (VortxJSON, VortxJSON) -> Bool, VortxJSON, VortxJSON)?
                var maximumBytes = 0
                var fullBaseBytes = 0
                for index in 0..<64 {
                    guard var draft = ProfileStore.shared.active else { throw VortxNativeError.invalidSnapshot }
                    var playback = draft.playback ?? ProfileStore.shared.flatPlayback
                    playback.audioLang = "language-\(index)"
                    draft.playback = playback
                    draft.addonPreferences = .init(disabledAddonURLsOverride: (0..<12).map {
                        "https://addon-\($0).example.invalid/catalog/manifest.json"
                    })
                    dirtySettings["fixture.playback"] = Double(index + 1)
                    let intents = try prepareNativePreferenceIntents(draft, target: target, editedGroups: [.playback])
                    guard intents.count == 1, let intent = intents.first else { throw VortxNativeError.invalidSnapshot }
                    let admission = try nativePreferenceAdmission(intents, profile: draft, target: target)
                    let (state, host) = try generationFixtureSnapshots()
                    guard admission(state, host), intent.acceptedBases.isEmpty, intent.supersededIDs.isEmpty,
                          intent.projectionStamps["fixture.playback"] == Double(index + 1) else { throw VortxNativeError.invalidSnapshot }
                    if let previous {
                        // Supplying the predecessor's *own* snapshots avoids a vacuous failure
                        // from revision drift: only the live generation gate rejects it.
                        guard !previous.1(previous.2, previous.3) else { throw VortxNativeError.invalidSnapshot }
                        try finishNativePreferenceIntents([previous.0], target: target)
                    }
                    guard await ProfileStore.shared.saveNative(draft, creating: false, target: target, preferenceIntents: intents) else {
                        throw VortxNativeError.unavailable
                    }
                    await cancelDebouncedSyncForProcessExit()
                    // Construct a fresh store every iteration; the pending receipt must come
                    // from authenticated bytes, not any in-memory gate or native commit ACK.
                    let reopened = try nativePreferenceStore(capture: capture)
                    guard try reopened.pending() == [intent], ProfileStore.shared.active?.playback?.audioLang == playback.audioLang else {
                        throw VortxNativeError.invalidSnapshot
                    }
                    maximumBytes = max(maximumBytes, try JSONEncoder().encode(intent).count)
                    fullBaseBytes = max(fullBaseBytes, try JSONEncoder().encode(intent.base).count)
                    guard maximumBytes < NativePreferenceIntentStore.maximumRecordBytes else { throw VortxNativeError.invalidSnapshot }
                    previous = (intent, admission, state, host)
                }
                guard fullBaseBytes >= 1_509, dirtySettings["fixture.playback"] == 64,
                      let latest = previous?.0, nativePreferenceAdmissionGate.admits([latest], operation: { true }) else {
                    throw VortxNativeError.invalidSnapshot
                }
                result["generationOfflineCommits"] = .integer(64)
                result["generationMaximumRecordBytes"] = .integer(Int64(maximumBytes))
                result["generationFullSnapshotBytes"] = .integer(Int64(fullBaseBytes))
                result["generationLatestPendingStamp"] = .number(64)
            case "generation-late-ack":
                let capture = credentialAuthority.capture()
                let accentKey = "stremiox.theme.accent"
                UserDefaults.standard.set("violet", forKey: accentKey)
                ThemeManager.shared.accentID = "violet"
                settingsShadow = currentSyncableDomain()
                dirtySettings[accentKey] = 101
                let firstDraft = editedTheme("violet")
                let first = try prepareNativePreferenceIntents(firstDraft, target: target, editedGroups: [.theme])
                let firstAdmission = try nativePreferenceAdmission(first, profile: firstDraft, target: target)
                let firstSnapshots = try generationFixtureSnapshots()
                guard first.count == 1, firstAdmission(firstSnapshots.0, firstSnapshots.1),
                      await ProfileStore.shared.saveNative(firstDraft, creating: false, target: target, preferenceIntents: first) else {
                    throw VortxNativeError.invalidSnapshot
                }
                await cancelDebouncedSyncForProcessExit()
                let firstDocument = try generationFixtureExport()
                let firstDirty = dirtySettings
                var secondDraft = editedTheme("violet")
                secondDraft.oled.toggle()
                ThemeManager.shared.oled = secondDraft.oled
                UserDefaults.standard.set(secondDraft.oled, forKey: "theme")
                settingsShadow = currentSyncableDomain()
                dirtySettings["theme"] = 202
                let second = try prepareNativePreferenceIntents(secondDraft, target: target, editedGroups: [.theme])
                guard second.count == 1, second[0].id != first[0].id,
                      second[0].projectionStamps[accentKey] == 101, second[0].projectionStamps["theme"] == 202,
                      !firstAdmission(firstSnapshots.0, firstSnapshots.1),
                      await ProfileStore.shared.saveNative(secondDraft, creating: false, target: target, preferenceIntents: second) else {
                    throw VortxNativeError.invalidSnapshot
                }
                await cancelDebouncedSyncForProcessExit()
                try finishNativePreferenceIntents(first, target: target)
                // Model the projection publication already acknowledged by the completed
                // native save. Without this, the generic exportability guard itself would
                // reject the stamp, hiding the predecessor-ACK dirty-clear regression.
                ProfileStore.shared.establishBaselines()
                guard nativeDirtySettingIsExported(accentKey) else { throw VortxNativeError.invalidSnapshot }
                // Deliver synthetic accepted-transport callbacks through the actual manager
                // ACK and generic dirty-clear methods. This case makes no network claim.
                acknowledgeNativePreferenceCloud(firstDocument, receipts: first, capture: capture)
                clearPushedDirtySettings(firstDirty)
                let reopened = try nativePreferenceStore(capture: capture)
                guard try reopened.pending() == second, dirtySettings[accentKey] == 101, dirtySettings["theme"] == 202 else {
                    throw VortxNativeError.invalidSnapshot
                }
                result["generationLateAckPreservedSuccessor"] = .bool(true)
                let secondDocument = try generationFixtureExport()
                guard nativePreferenceAdmissionGate.admits(second, operation: { true }) else { throw VortxNativeError.invalidSnapshot }
                acknowledgeNativePreferenceCloud(secondDocument, receipts: second, capture: capture)
                clearPushedDirtySettings(dirtySettings)
                guard try reopened.pending().isEmpty, dirtySettings[accentKey] == nil, dirtySettings["theme"] == nil,
                      !nativePreferenceAdmissionGate.admits(second, operation: { true }) else { throw VortxNativeError.invalidSnapshot }
                result["generationExactAckClearedSuccessor"] = .bool(true)
            case "prepare-theme":
                let intents = try prepareNativePreferenceIntents(editedTheme(command.preferenceValue ?? "violet"), target: target, editedGroups: [.theme])
                result["preparationQueuedPush"] = .bool(hasPendingPush)
                await cancelDebouncedSyncForProcessExit()
                result["preparedCount"] = .integer(Int64(intents.count))
            case "commit-prepared-without-ack":
                let store = try nativePreferenceStore(capture: credentialAuthority.capture())
                guard let intent = try store.pending().first(where: { $0.group == .theme }) else { throw VortxNativeError.invalidSnapshot }
                try await commitWithoutPreferenceAcknowledgement(intent)
            case "commit-prepared":
                let store = try nativePreferenceStore(capture: credentialAuthority.capture())
                guard let intent = try store.pending().first(where: { $0.group == .theme }),
                      try await ProfileStore.shared.saveNative(profile(for: intent), creating: false, target: target, preferenceIntents: [intent]) else {
                    throw VortxNativeError.invalidSnapshot
                }
                await cancelDebouncedSyncForProcessExit()
            case "commit-theme-and-push":
                guard await ProfileStore.shared.saveNative(editedTheme(command.preferenceValue ?? "coral"), creating: false, target: target) else {
                    throw VortxNativeError.unavailable
                }
                await cancelDebouncedSyncForProcessExit()
                result["accepted"] = .bool(await syncUp())
            case "startup-flush":
                result["startupHadDirtySettings"] = .bool(!dirtySettings.isEmpty)
                result["startupHadQueuedPush"] = .bool(hasPendingPush)
                flushDirtySettingsIfNeeded()
                result["startupFlushQueuedPush"] = .bool(hasPendingPush)
                await cancelDebouncedSyncForProcessExit()
            case "quarantine-check":
                result["quarantineSucceeded"] = .bool(Self.nativePreferenceProjectionWillMount())
                let quarantined = try nativePreferenceStore(capture: credentialAuthority.capture()).quarantined()
                result["quarantinedProjectionCount"] = .integer(Int64(quarantined.count))
                result["quarantinedProjectionStamps"] = .array(quarantined.map { .number($0.stamp) })
                result["remainingProjectionDirty"] = .bool(dirtySettings["stremiox.theme.accent"] != nil)
                result["projectionStampAttributed"] = .bool(nativePreferenceStampIsAttributed("stremiox.theme.accent"))
            case "admission-checks":
                let intents = try nativePreferenceStore(capture: credentialAuthority.capture()).pending()
                guard let intent = intents.first(where: { $0.group == .theme }),
                      let admission = try? nativePreferenceAdmission(intents, profile: profile(for: intent), target: target),
                      let stateBytes = CoreBridge.shared.stateData("native_state"),
                      let hostBytes = CoreBridge.shared.stateData("native_host_preferences") else { throw VortxNativeError.invalidSnapshot }
                let state = try JSONDecoder().decode(VortxJSON.self, from: stateBytes)
                let host = try JSONDecoder().decode(VortxJSON.self, from: hostBytes)
                let originalClock = state["nativeSync"]?["profiles"]?[AppleSyncManagerPeer.owner]?["fieldClocks"]?["accent"] ?? .null
                let changedRevision = Self.setting(state, path: ["nativeSync", "profiles", AppleSyncManagerPeer.owner,
                    "fieldClocks", "accent"], value: Self.bumped(originalClock))
                let changedBinding = Self.setting(state, path: ["roster", "profiles", AppleSyncManagerPeer.owner, "account"],
                    value: .object(["kind": .string("fixture-aba"), "id": .string("different-account")]))
                let unrelatedProgress = Self.setting(state, path: ["watches", AppleSyncManagerPeer.owner, "fixture-progress"], value: .bool(true))
                let playbackClock = host["profiles"]?[AppleSyncManagerPeer.owner]?["fields"]?["playback"]?["clock"] ?? .null
                let changedPeerGroup = Self.setting(host, path: ["profiles", AppleSyncManagerPeer.owner, "fields", "playback", "clock"],
                    value: Self.bumped(playbackClock))
                result["admissionAcceptsUnrelatedProgress"] = .bool(admission(unrelatedProgress, host))
                result["admissionRejectsGroupRevisionChange"] = .bool(!admission(changedRevision, host))
                result["admissionRejectsBindingABA"] = .bool(!admission(changedBinding, host))
                result["admissionRejectsUnintendedGroupChange"] = .bool(!admission(state, changedPeerGroup))
            case "stale-presentation", "stale-presentation-nil":
                if preferenceCommand == "stale-presentation", var presented = ProfileStore.shared.active {
                    presented.playback = ProfileStore.shared.flatPlayback
                    ProfileStore.shared.active = presented
                } else if var presented = ProfileStore.shared.active {
                    presented.playback = nil
                    ProfileStore.shared.active = presented
                }
                var peerPlayback = ProfileStore.shared.flatPlayback
                peerPlayback.audioLang = "fr"
                let playbackValue = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(peerPlayback))
                try await edit([], edits: [.init(profileID: AppleSyncManagerPeer.owner, fields: ["playback": playbackValue])])
                try await refreshSnapshots()
                result["stalePresentedPlayback"] = ProfileStore.shared.active?.playback.map { .string($0.audioLang) } ?? .null
                if let hostBytes = CoreBridge.shared.stateData("native_host_preferences"),
                   let host = try? JSONDecoder().decode(VortxJSON.self, from: hostBytes),
                   let audio = host["profiles"]?[AppleSyncManagerPeer.owner]?["fields"]?["playback"]?["value"]?["audioLang"] {
                    result["peerPlaybackAtAdmission"] = audio
                }
                let staleProfile = editedTheme("violet")
                let intents = try prepareNativePreferenceIntents(staleProfile, target: target)
                result["staleIntentGroups"] = .array(intents.map { .string($0.group.rawValue) })
                guard await ProfileStore.shared.saveNative(staleProfile, creating: false, target: target, preferenceIntents: intents) else {
                    throw VortxNativeError.unavailable
                }
                await cancelDebouncedSyncForProcessExit()
                result["stalePresentationPushAccepted"] = .bool(await syncUp())
            case "baseline-presentation", "baseline-conflict":
                // Model the open editor explicitly: capture its immutable baseline before a peer
                // changes the authenticated native playback value without publishing profiles.
                guard var original = ProfileStore.shared.active else { throw VortxNativeError.invalidSnapshot }
                // The editor has the published effective playback projection even when the
                // optional profile carrier is still nil (inherited/default playback).
                original.playback = ProfileStore.shared.flatPlayback
                var peerPlayback = ProfileStore.shared.flatPlayback
                peerPlayback.audioLang = "fr"
                let peerValue = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(peerPlayback))
                try await edit([], edits: [.init(profileID: AppleSyncManagerPeer.owner, fields: ["playback": peerValue])])
                try await refreshSnapshots()
                var draft = original
                draft.accentID = "violet"
                if preferenceCommand == "baseline-conflict" {
                    var editedPlayback = original.playback ?? ProfileStore.shared.flatPlayback
                    editedPlayback.audioLang = "de"
                    draft.playback = editedPlayback
                }
                result["editorBaselinePlayback"] = original.playback.map { .string($0.audioLang) } ?? .null
                if let hostBytes = CoreBridge.shared.stateData("native_host_preferences"),
                   let host = try? JSONDecoder().decode(VortxJSON.self, from: hostBytes),
                   let audio = host["profiles"]?[AppleSyncManagerPeer.owner]?["fields"]?["playback"]?["value"]?["audioLang"] {
                    result["peerPlaybackAtAdmission"] = audio
                }
                result["baselineSaveAccepted"] = .bool(await ProfileStore.shared.saveNative(draft, creating: false,
                    target: target, preferenceBaseline: original))
                let baselineStore = try nativePreferenceStore(capture: credentialAuthority.capture())
                let baselineIntents = try baselineStore.pending()
                result["baselineIntentGroups"] = .array(baselineIntents.map { $0.group.rawValue }.sorted().map(VortxJSON.string))
                result["baselinePlaybackRequiresResolution"] = .bool(baselineIntents.first(where: { $0.group == .playback })?.requiresResolution == true)
                result["baselinePlaybackIntentValue"] = baselineIntents.first(where: { $0.group == .playback })
                    .flatMap { try? $0.desired["playback"]?.decode(UserProfile.PlaybackPrefs.self).audioLang }
                    .map(VortxJSON.string) ?? .null
                result["baselineHostPlayback"] = .string(ProfileStore.shared.flatPlayback.audioLang)
                await cancelDebouncedSyncForProcessExit()
            case "stale-playback-edit":
                if var presented = ProfileStore.shared.active {
                    presented.playback = ProfileStore.shared.flatPlayback
                    ProfileStore.shared.active = presented
                }
                var peerPlayback = ProfileStore.shared.flatPlayback
                peerPlayback.audioLang = "fr"
                let playbackValue = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(peerPlayback))
                try await edit([], edits: [.init(profileID: AppleSyncManagerPeer.owner, fields: ["playback": playbackValue])])
                try await refreshSnapshots()
                var draft = ProfileStore.shared.active!
                var editedPlayback = ProfileStore.shared.flatPlayback
                editedPlayback.audioLang = "de"
                draft.playback = editedPlayback
                let store = try nativePreferenceStore(capture: credentialAuthority.capture())
                let intents: [NativePreferenceIntentStore.Intent]
                do {
                    intents = try prepareNativePreferenceIntents(draft, target: target)
                    result["stalePlaybackPrepareRejected"] = .bool(false)
                } catch {
                    intents = try store.pending()
                    result["stalePlaybackPrepareRejected"] = .bool(true)
                }
                result["stalePlaybackEditGroups"] = .array(intents.map { .string($0.group.rawValue) })
                result["stalePlaybackRequiresResolution"] = .bool(intents.first(where: { $0.group == .playback })?.requiresResolution == true)
                await cancelDebouncedSyncForProcessExit()
                result["stalePlaybackSaveAccepted"] = .bool(await ProfileStore.shared.saveNative(draft, creating: false, target: target, preferenceIntents: intents))
                await cancelDebouncedSyncForProcessExit()
            case "local-revert-cycle", "local-revert-prepare", "local-revert-retired":
                let edit = editedTheme("violet")
                let intents = try prepareNativePreferenceIntents(edit, target: target, editedGroups: [.theme])
                ProfileStore.shared.failSave = true
                result["failedNativeSaveAccepted"] = .bool(await ProfileStore.shared.saveNative(edit, creating: false, target: target, preferenceIntents: intents))
                ProfileStore.shared.failSave = false
                if preferenceCommand == "local-revert-cycle" {
                    let reverted = editedTheme("ember")
                    result["sameProcessLocalRevertAuthorized"] = .bool(ProfileStore.shared.nativePreferenceIsLocalRevert(reverted, group: .theme))
                    let replacement = try prepareNativePreferenceIntents(reverted, target: target, editedGroups: [.theme])
                    result["localRevertPendingAccent"] = replacement.first(where: { $0.group == .theme })
                        .flatMap { try? $0.desired["accentID"]?.decode(String.self) }.map(VortxJSON.string) ?? .null
                } else if preferenceCommand == "local-revert-retired" {
                    retire()
                    result["retiredTargetLocalRevertAuthorized"] = .bool(ProfileStore.shared.nativePreferenceIsLocalRevert(editedTheme("ember"), group: .theme))
                }
                await cancelDebouncedSyncForProcessExit()
            case "local-revert-cold-check":
                result["coldStartLocalRevertAuthorized"] = .bool(ProfileStore.shared.nativePreferenceIsLocalRevert(editedTheme("ember"), group: .theme))
            case "capture-revert-cycle":
                guard var current = ProfileStore.shared.active else { throw VortxNativeError.invalidSnapshot }
                // Start from the optional nil carrier with its already-published effective en.
                current.playback = nil
                ProfileStore.shared.active = current
                ProfileStore.shared.nativePublishedPlaybackSource = .init(playback: nil, addonPreferences: current.addonPreferences)
                var local = ProfileStore.shared.flatPlayback
                local.audioLang = "hi"
                ProfileStore.shared.flatPlayback = local
                ProfileStore.shared.capturePlayback()
                guard let firstUpdate = ProfileStore.shared.capturedUpdateProfile,
                      let firstGroups = ProfileStore.shared.capturedUpdateGroups else { throw VortxNativeError.invalidSnapshot }
                let admitted = try prepareNativePreferenceIntents(firstUpdate, target: target, editedGroups: firstGroups)
                result["capturedLocalPlayback"] = .string(firstUpdate.playback?.audioLang ?? "<nil>")
                result["captureIntentGroups"] = .array(admitted.map { .string($0.group.rawValue) })
                ProfileStore.shared.flatPlayback = UserProfile.PlaybackPrefs(audioLang: "en", subtitleLang: "en", forcedPolicy: "forced",
                    subFont: "system", subSize: "medium", subColor: "white", subBackground: "none", subSizeScale: 1,
                    sourceTypeOrder: ["debrid", "torrent"], useAddonOrder: false, safetyMode: "balanced", instantOnly: false)
                ProfileStore.shared.capturePlayback()
                let reverted = ProfileStore.shared.capturedUpdateProfile
                result["captureRevertUpdateCount"] = .integer(Int64(ProfileStore.shared.capturedUpdateCount))
                result["captureRevertedToNilCarrier"] = .bool(reverted?.playback == nil)
                result["captureRevertGroups"] = .array((ProfileStore.shared.capturedUpdateGroups ?? []).map { .string($0.rawValue) })
            case "capture-cold-default-echo":
                ProfileStore.shared.capturePlayback()
                result["coldDefaultEchoUpdateCount"] = .integer(Int64(ProfileStore.shared.capturedUpdateCount))
                result["coldDefaultEchoKeptNilCarrier"] = .bool(ProfileStore.shared.active?.playback == nil)
            default: throw VortxNativeError.invalidResponse
            }
        }
        switch command.mode {
        case "edit": try await edit(command.actions ?? [], edits: command.edits ?? [])
        case "push": result["accepted"] = .bool(await syncUp())
        case "auto":
            requestSyncSoon()
            await pendingSync?.value
            result["accepted"] = .bool(stamped > 0)
        case "pull":
            let capture = credentialAuthority.capture()
            if case .doc(let doc, let version) = await pullDocVersionedResult(credentialCapture: capture) {
                let remote = try doc["nativeSync"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
                let host = try doc["nativeHostPreferences"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
                _ = try await CoreBridge.shared.mergeNativeAccountDocument(remote, hostRemote: host, capture: capture,
                    legacyMaterial: Data(), websiteEvents: [], websiteAddonEvents: [], legacyWatchlists: [:], sourceAuthority: nil, authenticatedSourceArchive: nil)
                try await publishProfiles()
                result["pulledVersion"] = .integer(Int64(version))
            }
        case "inspect": break
        default: throw VortxNativeError.invalidResponse
        }
        result["putVersions"] = .array(putVersions.map { .integer(Int64($0)) })
        result["dirtyProjectionRetained"] = .bool(dirtySettings["stremiox.theme.accent"] != nil)
        result["pendingPush"] = .bool(hasPendingPush)
        result["lastVersion"] = .integer(Int64(lastSyncedVersion))
        result["stamped"] = .integer(Int64(stamped))
        result["ensureCalls"] = .integer(Int64(ensureCalls))
        result["preferenceSaves"] = .integer(Int64(ProfileStore.shared.saves))
        result["preferenceIntentStatus"] = .string(nativePreferenceIntentStatus)
        result["nativeUnsupportedSettings"] = .array(nativeUnsupportedSettings.map(VortxJSON.string))
        if let store = try? nativePreferenceStore(capture: credentialAuthority.capture()), let intents = try? store.pending() {
            result["pendingPreferenceIntentCount"] = .integer(Int64(intents.count))
            result["pendingPreferenceGroups"] = .array(intents.map { .string($0.group.rawValue) })
            result["pendingThemeAccent"] = intents.first(where: { $0.group == .theme }).flatMap { try? $0.desired["accentID"]?.decode(String.self) }
                .map(VortxJSON.string) ?? .null
            result["pendingThemeProjectionStamp"] = intents.first(where: { $0.group == .theme })?.projectionStamps["stremiox.theme.accent"]
                .map(VortxJSON.number) ?? .null
            result["pendingPlaybackRequiresResolution"] = .bool(intents.first(where: { $0.group == .playback })?.requiresResolution == true)
            result["pendingPlaybackAudioLang"] = intents.first(where: { $0.group == .playback })
                .flatMap { try? $0.desired["playback"]?.decode(UserProfile.PlaybackPrefs.self).audioLang }
                .map(VortxJSON.string) ?? .null
        }
        if let session = CoreBridge.shared.session {
            result["state"] = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
            result["host"] = try await session.hostPreferencesDocument()
            result["playback"] = try await session.playbackProjection()
            await session.close()
        }
        return result
    }
}

@main private enum AppleSyncManagerPeer {
    static let account = "account.apple-sync-fixture"
    static let owner = "10000000-0000-0000-0000-000000000001"
    static let key = Data(repeating: 1, count: 32)
    struct NoResources: VortxResourceTransport {
        func makeCancellation() throws -> any VortxResourceCancellation { throw VortxNativeError.unavailable }
        func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String { throw VortxNativeError.unavailable }
    }
    static func main() async throws {
        let command = try JSONDecoder().decode(ManagerHarness.Command.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let result = try await ManagerHarness(command).run()
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
}
