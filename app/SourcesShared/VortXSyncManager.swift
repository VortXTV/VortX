import Foundation
import CoreFoundation
#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE
import SwiftUI
import CryptoKit   // Curve25519 for the QR sign-in pairing session (QrJoinSession.ephemeral)
#if canImport(UIKit) && !os(macOS)
import UIKit       // UIApplication.beginBackgroundTask for the on-background sync grace window (iOS + tvOS)
#endif
#endif

#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE

/// Bridges the thread-agnostic `VortXSyncManager.addonOrderChangedNote` to a `@Published` the add-on list
/// READS in its body, so a reorder re-sorts the live list immediately. A never-read `@State` bumped from
/// `.onReceive` did not survive the Reorder screen's NavigationStack push/pop (SwiftUI snapshots the covered
/// root); an `@ObservedObject` whose value is read in body does, because SwiftUI re-renders a reappearing
/// view when a tracked dependency changed while it was covered. Small + dedicated so views observing it do
/// not also re-render on VortXSyncManager's unrelated account/sign-in @Published churn.
@MainActor
final class AddonOrderObserver: ObservableObject {
    static let shared = AddonOrderObserver()
    @Published private(set) var revision = 0
    private init() {
        NotificationCenter.default.addObserver(forName: VortXSyncManager.addonOrderChangedNote, object: nil, queue: .main) { [weak self] _ in
            // NotificationCenter's block is not actor-isolated. Only this wake counter crosses to
            // the main executor; the original order write and synchronous notification stay unchanged.
            DispatchQueue.main.async { [weak self] in
                self?.revision &+= 1
            }
        }
    }
}

/// The VortX end-to-end-encrypted account on-device: create / sign in / recover / sign out, plus
/// push and pull the encrypted sync document. Mirrors the website (vortx-site/src/lib/vault.ts) and
/// the Cloudflare Worker contract through VortXSyncCrypto. The session token, account, and the data
/// key are persisted in the Keychain (the data key is sensitive, never UserDefaults). Optional: VortX
/// works fully signed out; this only adds cross-device sync, backup, and recovery.
@MainActor
final class VortXSyncManager: ObservableObject {
    static let shared = VortXSyncManager()

    struct Account: Codable, Equatable, Sendable {
        let id: String
        let email: String
        var username: String
        var twoFactorEnabled: Bool
    }

    @Published private(set) var account: Account?
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountRestoreState: AccountRestoreState = .idle
    /// Wall-clock time of the LAST successful sync round-trip for the signed-in account: stamped on every
    /// ACCEPTED push (pushSyncDocAt) and on every applied / definitively-empty pull (syncDown). Persisted
    /// per account (lastSyncKey(for:)) so a relaunch still shows "last synced 2 hours ago", and published so
    /// the seeding banner / SyncSettingsView repaint live. nil = this account has never completed a sync
    /// from this device (or signed out).
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var backupUploadFailure: SyncBackupUploadFailure?

    /// Transport success does not mean every locally retained preference has converged.
    var pendingSettingsMessage: String? {
        guard isSignedIn else { return nil }
        if let backupUploadFailure { return backupUploadFailure.message }
        return !nativeUnsupportedSettings.isEmpty || !dirtySettings.isEmpty || nativePreferenceIntentStatus != "idle"
            ? "Some changes still need to sync." : nil
    }
    var synchronizationIsComplete: Bool { isSignedIn && lastSyncAt != nil && !hasPendingPush && pendingSettingsMessage == nil }

    private let base = "https://api.vortx.tv"
    private let kcAccount = "vortx.sync.session.v1"
    private var token: String?
    private var dataKey: Data?
    private var nativeCheckpointTask: Task<Bool, Never>?
    private var nativeCheckpointCapture: CredentialScopeRegistry.Capture?
    private var nativeCheckpointProfile: UUID?
    private var nativeCheckpointGeneration = UUID()
    private var nativeRecoveryFailure: (capture: CredentialScopeRegistry.Capture, profileID: UUID?, backoff: NativeForegroundSyncPolicy.RecoveryBackoff)?
    @Published private(set) var nativeCheckpointStatus = "not_started"
    @Published private(set) var nativeProfileEditConflicts: [VortxNativeProfileEditHost.Conflict] = []
    @Published private(set) var nativeAddonEditConflicts: [VortxNativeWebsiteAddonEdits.Conflict] = []
    @Published private(set) var nativeOwnAccountResyncUnavailable: [UUID] = []
    @Published private(set) var nativeOwnAccountOverlayPending: [UUID] = []
    @Published private(set) var nativeWatchedMigrationPending: [UUID] = []
    private var nativeWatchedPendingTask: Task<Void, Never>?
    private var nativeWatchedPendingGeneration = UUID()
    @Published private(set) var nativeUnsupportedSettings: [String] = []
    private var nativeLegacyWatchlistPending = Set<String>()
    @Published private(set) var nativeOwnAccountOverlayUnattributed: [UUID] = []
    private var nativePreparedSeedCapture: CredentialScopeRegistry.Capture?
    @Published private(set) var nativePreferenceIntentStatus = "idle"
    private struct NativePreferenceLocalAdmission {
        let target: PlaybackMutationTarget
        let intent: NativePreferenceIntentStore.Intent
    }
    private var nativePreferenceLocalAdmissions: [UUID: [NativePreferenceIntentStore.Group: NativePreferenceLocalAdmission]] = [:]
    private let nativePreferenceAdmissionGate = NativePreferenceIntentStore.AdmissionGate()
    /// An account-only legacy dirty stamp is not evidence of the profile that authored it.
    /// Remember its exact stamp before a new native installation replaces the flat projection.
    private func quarantineNativePreferenceStamps() -> Bool {
        var legacy = dirtySettings.filter { Self.nativePreferenceProjectionKeys.contains($0.key) }
        guard !legacy.isEmpty else { return true }
        do {
            let capture = credentialAuthority.capture()
            let store = try nativePreferenceStore(capture: capture)
            // Only a saved, authenticated exact stamp exempts an edit from quarantine. The
            // journal survives native ACK until cloud ACK; an account-only flag never suffices.
            let target = CoreBridge.shared.captureNativePlaybackTarget()
            for intent in try store.pending() {
                guard let id = UUID(uuidString: intent.authority.profileID),
                      let context = try? nativePreferenceContext(profileID: id, target: target),
                      context.authority == intent.authority else { continue }
                for (name, stamp) in intent.projectionStamps where legacy[name] == stamp { legacy.removeValue(forKey: name) }
            }
            let preserved = try store.quarantined()
            let values = try legacy.filter { name, stamp in !preserved.contains(where: { $0.key == name && $0.stamp == stamp }) }.map { name, stamp in
                // Property-list bytes retain the exact original defaults type (including Data).
                // This is evidence only, never an inferred edit to the incoming native profile.
                let raw = try UserDefaults.standard.object(forKey: name).map {
                    try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
                }
                return NativePreferenceIntentStore.QuarantinedProjection(key: name, stamp: stamp,
                    value: raw.map { .object(["binaryPropertyList": .string($0.base64EncodedString())]) } ?? .null)
            }
            try store.quarantine(values)
        } catch { nativePreferenceIntentStatus = "unavailable"; return false }
        let key = "vortx.sync.unattributedPreferenceStamps." + (account?.id ?? "")
        var retained = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        for (name, stamp) in legacy { retained[name] = stamp }
        UserDefaults.standard.set(retained, forKey: key)
        return true
    }
    private static var nativePreferenceProjectionKeys: Set<String> {
        ProfileStore.nativePlaybackProjectionKeys.union(ProfileStore.nativeThemeProjectionKeys)
            .union(ProfileDiscoveryPreferencesStore.activeProjectionKeys)
    }
    nonisolated static func nativePreferenceProjectionWillMount() -> Bool {
        if Thread.isMainThread { return MainActor.assumeIsolated { shared.quarantineNativePreferenceStamps() } }
        return DispatchQueue.main.sync { shared.quarantineNativePreferenceStamps() }
    }
    private func nativePreferenceStampIsAttributed(_ key: String) -> Bool {
        let slot = "vortx.sync.unattributedPreferenceStamps." + (account?.id ?? "")
        let retained = (UserDefaults.standard.dictionary(forKey: slot) as? [String: Double]) ?? [:]
        return dirtySettings[key] == nil || retained[key] != dirtySettings[key]
    }
    private func nativePreferenceStore(capture: CredentialScopeRegistry.Capture) throws -> NativePreferenceIntentStore {
        guard isSignedIn, isCurrent(capture), case .account = capture.scope,
              let key = dataKey, key.count == 32 else { throw VortxNativeError.superseded }
        let root = try VortxNativeStorage.root()
            .appendingPathComponent("VortX/native-preference-intents", isDirectory: true)
        return NativePreferenceIntentStore(directoryURL: root, key: key, namespace: capture.namespace)
    }
    private struct NativePreferenceContext {
        let authority: NativePreferenceIntentStore.Authority
        let profile: UserProfile
        let state: VortxJSON
        let host: VortxJSON
    }
    private func nativePreferenceContext(profileID: UUID, target: PlaybackMutationTarget) throws -> NativePreferenceContext {
        guard case .native(let binding?) = target, isCurrent(binding.credential), target.stillOwnsCurrentContext(core: .shared),
              let registry = CoreBridge.shared.nativeRegistryBinding, registry.scope.account == binding.credential.namespace,
              let stateBytes = CoreBridge.shared.stateData("native_state"),
              let hostBytes = CoreBridge.shared.stateData("native_host_preferences") else { throw VortxNativeError.superseded }
        let state = try JSONDecoder().decode(VortxJSON.self, from: stateBytes)
        let host = try JSONDecoder().decode(VortxJSON.self, from: hostBytes)
        guard let stateAgain = CoreBridge.shared.stateData("native_state"), let hostAgain = CoreBridge.shared.stateData("native_host_preferences"),
              state == (try? JSONDecoder().decode(VortxJSON.self, from: stateAgain)),
              host == (try? JSONDecoder().decode(VortxJSON.self, from: hostAgain)),
              target.stillOwnsCurrentContext(core: .shared) else { throw VortxNativeError.superseded }
        return try Self.makeNativePreferenceContext(state: state, host: host, profileID: profileID, scope: registry.scope)
    }
    nonisolated private static func makeNativePreferenceContext(state: VortxJSON, host: VortxJSON, profileID: UUID,
                                                                scope: VortxAccountScope) throws -> NativePreferenceContext {
        guard let profile = try VortxNativeProfiles.project(state: state, host: host, baseline: []).first(where: { $0.id == profileID }),
              host["scope"] == .string(scope.account), host["ownerProfileId"] == .string(scope.ownerProfileID) else { throw VortxNativeError.invalidSnapshot }
        let receipt = try VortxNativeProfiles.expectedBinding(state: state, profileID: profileID)
        let authority = NativePreferenceIntentStore.Authority(account: scope.account, ownerProfileID: scope.ownerProfileID,
            profileID: profileID.uuidString, profileBinding: .object(["accountBinding": receipt.document,
                "deletionClock": state["nativeSync"]?["profiles"]?[profileID.uuidString]?["fieldClocks"]?["deleted"] ?? .null]))
        return .init(authority: authority, profile: profile, state: state, host: host)
    }
    nonisolated private static func nativePreferenceValue(_ profile: UserProfile, group: NativePreferenceIntentStore.Group) throws -> VortxJSON {
        let value = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(profile))
        switch group {
        case .playback: return .object(["playback": value["playback"] ?? .null, "addonPreferences": value["addonPreferences"] ?? .null])
        case .discovery: return value["discovery"] ?? .null
        case .theme:
            let theme = VortxJSON.object(["accentID": .string(profile.accentID), "oled": .bool(profile.oled),
                "textScale": .number((profile.textScale * 1_000).rounded() / 1_000)])
            // JSON has one numeric value domain; round-trip to its canonical integer/double
            // representation before retaining an exact equality/readback witness.
            return try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(theme))
        }
    }
    nonisolated private static func nativePreferenceSnapshot(_ context: NativePreferenceContext, group: NativePreferenceIntentStore.Group) throws -> NativePreferenceIntentStore.Snapshot {
        let id = context.profile.id.uuidString
        let revision: VortxJSON
        switch group {
        case .theme:
            let clocks = context.state["nativeSync"]?["profiles"]?[id]?["fieldClocks"]
            revision = .object(Dictionary(uniqueKeysWithValues: ["accent", "oled", "textScale"].map { ($0, clocks?[$0] ?? .null) }))
        case .playback:
            let fields = context.host["profiles"]?[id]?["fields"]
            revision = .object(["playback": fields?["playback"] ?? .null, "addonPreferences": fields?["addonPreferences"] ?? .null])
        case .discovery: revision = context.host["profiles"]?[id]?["fields"]?["discovery"] ?? .null
        }
        return .init(value: try nativePreferenceValue(context.profile, group: group), revision: revision)
    }
    /// Captured values only: the facade evaluates this after prior queued work, before committing.
    /// It must not reach MainActor, defaults, credentials or the file system from its FIFO lock.
    func nativePreferenceAdmission(_ intents: [NativePreferenceIntentStore.Intent], profile: UserProfile,
                                   target: PlaybackMutationTarget) throws -> @Sendable (VortxJSON, VortxJSON) -> Bool {
        guard case .native(let binding?) = target else { throw VortxNativeError.superseded }
        let store = try nativePreferenceStore(capture: binding.credential)
        let gate = nativePreferenceAdmissionGate
        return try gate.withJournal(read: { try store.pending() }) {
        let context = try nativePreferenceContext(profileID: profile.id, target: target)
        let authority = context.authority
        var expected: [NativePreferenceIntentStore.Group: NativePreferenceIntentStore.Snapshot] = [:]
        for group in NativePreferenceIntentStore.Group.allCases {
            let snapshot = try Self.nativePreferenceSnapshot(context, group: group)
            let desired = try Self.nativePreferenceValue(profile, group: group)
            if let intent = intents.first(where: { $0.group == group }) {
                guard intent.authority == authority, intent.desired == desired,
                      NativePreferenceIntentStore.decision(intent, current: snapshot, authority: authority) != .conflict else { throw VortxNativeError.superseded }
            } else {
                // A stale presentation baseline must not turn an unchanged replay group into
                // an unguarded write of some other group's older values.
                guard snapshot.value == desired else { throw VortxNativeError.superseded }
            }
            expected[group] = snapshot
        }
        let captured = expected
        return { state, host in
            gate.admits(intents) {
            guard let id = UUID(uuidString: authority.profileID),
                  let current = try? Self.makeNativePreferenceContext(state: state, host: host, profileID: id,
                    scope: .init(account: authority.account, ownerProfileID: authority.ownerProfileID)),
                  current.authority == authority else { return false }
            return NativePreferenceIntentStore.Group.allCases.allSatisfy { group in
                guard let snapshot = try? Self.nativePreferenceSnapshot(current, group: group) else { return false }
                if let intent = intents.first(where: { $0.group == group }) {
                    return NativePreferenceIntentStore.decision(intent, current: snapshot, authority: authority) != .conflict
                }
                return snapshot == captured[group]
            }
            }
        }
        }
    }
    /// Unedited presentation fields are not save intent. Carry the current native values for
    /// those groups, including absent/inherited fields, through the older profile-diff adapter.
    func normalizedNativePreferenceSubmission(_ profile: UserProfile, intents: [NativePreferenceIntentStore.Intent],
                                              target: PlaybackMutationTarget) throws -> UserProfile {
        let current = try nativePreferenceContext(profileID: profile.id, target: target).profile
        var submitted = profile
        let groups = Set(intents.map(\.group))
        if !groups.contains(.playback) { submitted.playback = current.playback; submitted.addonPreferences = current.addonPreferences }
        if !groups.contains(.discovery) { submitted.discovery = current.discovery }
        if !groups.contains(.theme) { submitted.accentID = current.accentID; submitted.oled = current.oled; submitted.textScale = current.textScale }
        return submitted
    }
    /// A current-value revert needs positive same-installation local edit evidence. Merely
    /// mounting defaults after a restart, or submitting another group, must not cancel a journal.
    func nativePreferenceIsLocalRevert(_ profile: UserProfile, group: NativePreferenceIntentStore.Group,
                                      target: PlaybackMutationTarget) -> Bool {
        guard let admitted = nativePreferenceLocalAdmissions[profile.id]?[group], admitted.target == target,
              ProfileStore.shared.nativePreferenceProjectionMatches(target),
              case .native(let binding?) = target,
              let context = try? nativePreferenceContext(profileID: profile.id, target: target),
              context.authority == admitted.intent.authority,
              let desired = try? Self.nativePreferenceValue(profile, group: group), desired != admitted.intent.desired,
              desired == (try? Self.nativePreferenceValue(context.profile, group: group)),
              let store = try? nativePreferenceStore(capture: binding.credential),
              let pending = try? store.pending() else { return false }
        return pending.contains { $0.id == admitted.intent.id && $0.authority == context.authority }
    }
    /// Persist while the original authenticated target is still known, before queuing its save.
    /// An explicit group comes only from its own local capture path; ordinary profile submissions
    /// are diffed against the published profile, never against newer, unpublished native fields.
    func prepareNativePreferenceIntents(_ profile: UserProfile, target: PlaybackMutationTarget,
                                        editedGroups: Set<NativePreferenceIntentStore.Group>? = nil,
                                        baseline: UserProfile? = nil) throws -> [NativePreferenceIntentStore.Intent] {
        guard case .native(let binding?) = target else { throw VortxNativeError.superseded }
        let store = try nativePreferenceStore(capture: binding.credential)
        return try nativePreferenceAdmissionGate.withJournal(read: { try store.pending() }) {
        let context = try nativePreferenceContext(profileID: profile.id, target: target)
        guard let published = baseline ?? ProfileStore.shared.profiles.first(where: { $0.id == profile.id }),
              published.id == profile.id else { throw VortxNativeError.superseded }
        let pending = try store.pending()
        let pendingIDs = Set(pending.map(\.id))
        nativePreferenceLocalAdmissions = nativePreferenceLocalAdmissions.mapValues {
            $0.filter { $0.value.target == target && pendingIDs.contains($0.value.intent.id) }
        }.filter { !$0.value.isEmpty }
        let canAttributeFlat = binding.profileID == profile.id && ProfileStore.shared.nativePreferenceProjectionMatches(target)
        if canAttributeFlat, !isApplyingRemote { _ = noteLocalSettingsChange() }
        var result: [NativePreferenceIntentStore.Intent] = []
        var conflicted = false
        for group in NativePreferenceIntentStore.Group.allCases {
            let base = try Self.nativePreferenceSnapshot(context, group: group)
            let desired = try Self.nativePreferenceValue(profile, group: group)
            let presented = try Self.nativePreferenceValue(published, group: group)
            guard editedGroups?.contains(group) ?? (desired != presented) else { continue }
            // Preserve a stale edited draft without rebasing it onto a peer's newer choice.
            // Its actual authenticated current snapshot remains the base; the conflict flag
            // prevents replay unless that exact desired value is subsequently represented.
            let requiresResolution = base.value != presented && base.value != desired
            let keys: Set<String>
            switch group {
            case .playback: keys = ProfileStore.nativePlaybackProjectionKeys
            case .discovery: keys = ProfileDiscoveryPreferencesStore.activeProjectionKeys
            case .theme: keys = ProfileStore.nativeThemeProjectionKeys
            }
            let stamps = canAttributeFlat ? dirtySettings.filter { keys.contains($0.key) && nativePreferenceStampIsAttributed($0.key) } : [:]
            let intent = try store.prepare(authority: context.authority, group: group, base: base, desired: desired,
                                           projectionStamps: stamps, requiresResolution: requiresResolution)
            nativePreferenceLocalAdmissions[profile.id, default: [:]][group] = .init(target: target, intent: intent)
            conflicted = conflicted || NativePreferenceIntentStore.decision(intent, current: base, authority: context.authority) == .conflict
            result.append(intent)
        }
        if !result.isEmpty {
            nativePreferenceIntentStatus = "pending"
            // A failed/conflicted existing intent remains visible, but must not re-arm the
            // transport generation forever while an unrelated native carrier is accepted.
            if result.contains(where: { intent in !pending.contains(where: { $0.id == intent.id }) }) { requestSyncSoon() }
        }
        if conflicted { nativePreferenceIntentStatus = "conflict"; throw VortxNativeError.superseded }
        return result
        }
    }
    func finishNativePreferenceIntents(_ intents: [NativePreferenceIntentStore.Intent], target: PlaybackMutationTarget) throws {
        guard !intents.isEmpty else { return }
        guard case .native(let binding?) = target else { throw VortxNativeError.superseded }
        let store = try nativePreferenceStore(capture: binding.credential)
        for intent in intents {
            guard let id = UUID(uuidString: intent.authority.profileID) else { throw VortxNativeError.invalidSnapshot }
            let context = try nativePreferenceContext(profileID: id, target: target)
            guard context.authority == intent.authority else { throw VortxNativeError.superseded }
            guard try store.recordCommitted(intent, current: Self.nativePreferenceSnapshot(context, group: intent.group)) else {
                nativePreferenceIntentStatus = "pending"; throw VortxNativeError.superseded
            }
        }
        nativePreferenceIntentStatus = try store.pending().isEmpty ? "idle" : "pending"
    }
    private func pendingNativePreferenceReceipts(capture: CredentialScopeRegistry.Capture) -> [NativePreferenceIntentStore.Intent] {
        do { return try nativePreferenceStore(capture: capture).pending() }
        catch { nativePreferenceIntentStatus = "unavailable"; return [] }
    }
    private func acknowledgeNativePreferenceCloud(_ sentDocument: [String: Any], receipts: [NativePreferenceIntentStore.Intent],
                                                 capture: CredentialScopeRegistry.Capture,
                                                 sentPreferenceAckData: Data? = nil) {
        guard !receipts.isEmpty, isCurrent(capture) else { return }
        do {
            let bytes = try sentPreferenceAckData ?? JSONSerialization.data(withJSONObject: sentDocument)
            let document = try JSONDecoder().decode(VortxJSON.self, from: bytes)
            guard let native = document["nativeSync"], let host = document["nativeHostPreferences"],
                  case .object(let records) = native["profiles"] else { throw VortxNativeError.invalidSnapshot }
            let profiles = records.compactMapValues { $0["profile"] }
            let state = VortxJSON.object(["nativeSync": native, "roster": .object(["profiles": .object(profiles)])])
            let store = try nativePreferenceStore(capture: capture)
            try nativePreferenceAdmissionGate.withJournal(read: { try store.pending() }) {
            for sent in receipts {
                guard isCurrent(capture), let id = UUID(uuidString: sent.authority.profileID),
                      let context = try? Self.makeNativePreferenceContext(state: state, host: host, profileID: id,
                        scope: .init(account: capture.namespace, ownerProfileID: sent.authority.ownerProfileID)),
                      context.authority == sent.authority,
                      let current = try? nativePreferenceContext(profileID: id, target: CoreBridge.shared.captureNativePlaybackTarget()),
                      current.authority == sent.authority else { continue }
                let exported = try Self.nativePreferenceSnapshot(context, group: sent.group)
                // Validate the immutable receipt before clearing any stamp. Keep that witness
                // durable until after defaults are cleared: either crash ordering is retryable.
                guard try store.authorizesAcknowledgement(sent, current: exported) else { continue }
                withRemoteApplySuppressed {
                    var dirty = dirtySettings
                    SettingsDirtyKeys.clearPushed(sent.projectionStamps, from: &dirty)
                    dirtySettings = dirty
                }
                _ = try store.acknowledge(sent, current: exported)
            }
            nativePreferenceIntentStatus = try store.pending().isEmpty ? "idle" : "pending"
            }
        } catch { nativePreferenceIntentStatus = "unavailable" }
    }
    /// A failed save replays only after the peer carrier has merged. A changed group revision is
    /// a conflict, not permission to manufacture a newer local clock over the peer's choice.
    private func replayNativePreferenceIntents(capture: CredentialScopeRegistry.Capture) async -> Bool {
        guard isCurrent(capture) else { return false }
        do {
            let store = try nativePreferenceStore(capture: capture)
            var changed = false, conflict = false
            for intent in try store.pending() {
                let target = CoreBridge.shared.captureNativePlaybackTarget()
                guard isCurrent(capture), case .native(let binding?) = target, binding.credential == capture,
                      let id = UUID(uuidString: intent.authority.profileID) else { throw VortxNativeError.superseded }
                let context: NativePreferenceContext
                do { context = try nativePreferenceContext(profileID: id, target: target) }
                catch { conflict = true; continue }
                let current = try Self.nativePreferenceSnapshot(context, group: intent.group)
                switch NativePreferenceIntentStore.decision(intent, current: current, authority: context.authority) {
                case .conflict: conflict = true; continue
                case .alreadyApplied: try finishNativePreferenceIntents([intent], target: target)
                case .apply:
                    var profile = context.profile
                    switch intent.group {
                    case .playback:
                        profile.playback = intent.desired["playback"] == .null ? nil : try intent.desired["playback"]?.decode(UserProfile.PlaybackPrefs.self)
                        profile.addonPreferences = intent.desired["addonPreferences"] == .null ? nil : try intent.desired["addonPreferences"]?.decode(ProfileAddonPreferences.self)
                    case .discovery: profile.discovery = intent.desired == .null ? nil : try intent.desired.decode(ProfileDiscoveryPreferences.self)
                    case .theme:
                        profile.accentID = try intent.desired["accentID"]!.decode(String.self)
                        profile.oled = try intent.desired["oled"]!.decode(Bool.self)
                        profile.textScale = try intent.desired["textScale"]!.decode(Double.self)
                    }
                    guard await ProfileStore.shared.saveNative(profile, creating: false, target: target, preferenceIntents: [intent]),
                          isCurrent(capture) else { nativePreferenceIntentStatus = "pending"; return changed }
                    changed = true
                }
            }
            nativePreferenceIntentStatus = conflict ? "conflict" : (try store.pending().isEmpty ? "idle" : "pending")
            return changed
        } catch { nativePreferenceIntentStatus = "unavailable"; return false }
    }
    private func nativePreferenceIntentsNeedReplay() -> Bool {
        do {
            let pending = try !nativePreferenceStore(capture: credentialAuthority.capture()).pending().isEmpty
            if pending { nativePreferenceIntentStatus = "pending" }
            return pending
        } catch { nativePreferenceIntentStatus = "unavailable"; return false }
    }
    private func nativeProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials {
        guard isCurrent(capture) else { throw VortxNativeError.superseded }
        let bytes: Data?
        switch Keychain.confirmedString("vortx.native.providerState." + capture.namespace) {
        case .missing: bytes = nil
        case .value(let value): bytes = Data(value.utf8)
        case .failure:
            // An uncertain intent write may leave a complete prior prepared journal or complete
            // finalized value. Recertify only those exact durable bytes; never infer absence.
            let slot = "vortx.native.providerState." + capture.namespace
            guard case .value(let retained) = Keychain.durableString(slot) else { throw VortxNativeError.unavailable }
            _ = try VortxNativeProviderCredentials(scope: capture.namespace, actor: nativeHostActor(capture: capture), sealed: Data(retained.utf8))
            try VortxNativeProviderCredentials.withStoreLock {
                guard Keychain.set(retained, for: slot) == .success,
                      case .value(let confirmed) = Keychain.confirmedString(slot), confirmed == retained else { throw VortxNativeError.unavailable }
            }
            bytes = Data(retained.utf8)
        }
        return try VortxNativeProviderCredentials(scope: capture.namespace, actor: nativeHostActor(capture: capture), sealed: bytes)
    }
    private func saveNativeProviderState(_ value: VortxNativeProviderCredentials, capture: CredentialScopeRegistry.Capture) throws {
        guard isCurrent(capture) else { throw VortxNativeError.superseded }
        let slot = "vortx.native.providerState." + capture.namespace
        let encoded = String(decoding: try value.encoded(), as: UTF8.self)
        try VortxNativeProviderCredentials.withStoreLock {
            guard Keychain.set(encoded, for: slot) == .success, Keychain.string(slot) == encoded else { throw VortxNativeError.unavailable }
        }
    }
    func prepareNativeProviderMutation(_ fields: [String: VortxJSON], capture: CredentialScopeRegistry.Capture) -> [String: VortxNativeProviderCredentials.Register]? {
        guard isCurrent(capture) else { return nil }
        guard case .account = capture.scope else { return [:] }
        do {
            var state = try nativeProviderState(capture: capture)
            let events = try state.prepare(fields)
            try saveNativeProviderState(state, capture: capture)
            return events
        } catch { return nil }
    }
    func finishNativeProviderMutation(_ events: [String: VortxNativeProviderCredentials.Register], capture: CredentialScopeRegistry.Capture) -> Bool {
        if events.isEmpty { return isCurrent(capture) }
        do {
            var state = try nativeProviderState(capture: capture)
            try state.finishPrepared(events); try saveNativeProviderState(state, capture: capture)
            requestSyncSoon(); return true
        } catch { return false } // prepared secure intent remains; no remote hydration/export may pass it
    }
    /// Only an auth actor that has not attempted its tuple mutation may abort this exact event.
    func abortNativeProviderMutation(_ events: [String: VortxNativeProviderCredentials.Register], capture: CredentialScopeRegistry.Capture) -> Bool {
        if events.isEmpty { return true }
        guard case .account = capture.scope else { return false }
        // The receipt authorizes cleanup of this never-attempted local operation even after account
        // retirement. It does NOT restore authority to mutate credentials, document, pending events,
        // account settings or cloud state. Match the original namespace and every event exactly.
        return VortxNativeProviderCredentials.withStoreLock {
            let slot = "vortx.native.providerState." + capture.namespace
            guard case .value(let encoded) = Keychain.confirmedString(slot) else { return false }
            do {
                var state = try VortxNativeProviderCredentials(scope: capture.namespace,
                    actor: "00000000-0000-0000-0000-000000000001", sealed: Data(encoded.utf8))
                try state.abortPrepared(events)
                let repaired = String(decoding: try state.encoded(), as: UTF8.self)
                guard Keychain.set(repaired, for: slot) == .success,
                      case .value(let confirmed) = Keychain.confirmedString(slot), confirmed == repaired else { return false }
                return true
            } catch { return false }
        }
    }
    /// Synchronous credential mutation linearization: the provider register cannot change between
    /// this exact-event check and the secure tuple mutation. Never hold this lock across an await.
    nonisolated static func withNativeProviderEvents(_ events: [String: VortxNativeProviderCredentials.Register],
        capture: CredentialScopeRegistry.Capture, mutation: () -> Bool) -> Bool {
        VortxNativeProviderCredentials.withStoreLock {
            guard CredentialScopeRegistry.shared.isCurrent(capture),
                  case .value(let encoded) = Keychain.confirmedString("vortx.native.providerState." + capture.namespace),
                  let state = try? VortxNativeProviderCredentials(scope: capture.namespace,
                    actor: "00000000-0000-0000-0000-000000000001", sealed: Data(encoded.utf8)),
                  state.authorizes(events) else { return false }
            return mutation()
        }
    }
    nonisolated static func withNativeProviderSnapshot(_ expected: VortxNativeProviderCredentials.Document,
        capture: CredentialScopeRegistry.Capture, mutation: () -> Bool) -> Bool {
        VortxNativeProviderCredentials.withStoreLock {
            guard CredentialScopeRegistry.shared.isCurrent(capture),
                  case .value(let encoded) = Keychain.confirmedString("vortx.native.providerState." + capture.namespace),
                  let state = try? VortxNativeProviderCredentials(scope: capture.namespace,
                    actor: "00000000-0000-0000-0000-000000000001", sealed: Data(encoded.utf8)),
                  !state.hasPreparedMutation, state.local.document == expected else { return false }
            return mutation()
        }
    }
    /// Called only after a successful account-scoped secure mutation, never on bind/sign-out.
    /// The caller rolls its mutation back if the durable explicit intent cannot be recorded.
    private func settleNativeProviderJournal(capture: CredentialScopeRegistry.Capture) async -> Bool {
        do {
            let state = try nativeProviderState(capture: capture)
            guard state.hasPreparedMutation else { return true }
            for (index, group) in VortxNativeProviderCredentials.groups.enumerated() {
                let events = (state.local.prepared ?? [:]).filter { group.contains($0.key) }
                guard !events.isEmpty else { continue }
                let certified: Bool
                if index == 0 { certified = await TraktAuth.shared.certifiesNativePrepared(events, capture: capture) }
                else { certified = await SIMKLAuth.shared.certifiesNativePrepared(events, capture: capture) }
                guard certified, isCurrent(capture), finishNativeProviderMutation(events, capture: capture) else { return false }
            }
            return try !nativeProviderState(capture: capture).hasPreparedMutation
        } catch { return false }
    }
    func nativeProviderRevision(_ keys: [String], capture: CredentialScopeRegistry.Capture) -> [String: String]? {
        guard let state = try? nativeProviderState(capture: capture) else { return nil }
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, state.local.document.fields[key].map { String($0.clock) + ":" + $0.actor } ?? "absent")
        })
    }
    func noteNativeProviderMutation(_ fields: [String: VortxJSON], capture: CredentialScopeRegistry.Capture,
                                    expectedRevision: [String: String]? = nil, suppressImportedApply: Bool = true) -> Bool {
        guard isCurrent(capture) else { return false }
        guard (!suppressImportedApply || !isApplyingRemote), case .account = capture.scope else { return true }
        do {
            var state = try nativeProviderState(capture: capture)
            if let expectedRevision {
                guard nativeProviderRevision(Array(fields.keys), capture: capture) == expectedRevision else { return false }
            }
            try state.edit(fields); try saveNativeProviderState(state, capture: capture)
            requestSyncSoon()
            if isApplyingRemote { Task { @MainActor [weak self] in guard let self, self.isCurrent(capture) else { return }; self.requestSyncSoon() } }
            return true
        } catch { return false }
    }
    private func mergedNativeProviderState(_ document: [String: Any], capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials {
        var state = try nativeProviderState(capture: capture)
        guard !state.hasPreparedMutation else { throw VortxNativeError.unavailable }
        if let raw = document["nativeProviderCredentials"] {
            let wire = try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: raw))
            // A legacy peer editing a registered key without its event is not silently promoted.
            let remote = try wire.decode(VortxNativeProviderCredentials.Document.self)
            let keys = (document["apiKeys"] as? [String: Any]) ?? [:]
            let metadata = (keys["metadata"] as? [String: Any]) ?? [:]
            for (key, event) in remote.fields {
                let aliases = [keys[key], ["tmdb", "mdblist", "fanart"].contains(key) ? metadata[key] : nil].compactMap { $0 }
                if case .string(let value) = event.value {
                    guard !aliases.isEmpty, aliases.allSatisfy({
                        guard let alias = $0 as? String else { return false }
                        return alias.utf8.elementsEqual(value.utf8)
                    }) else { throw VortxNativeError.invalidSnapshot }
                } else { guard aliases.isEmpty else { throw VortxNativeError.invalidSnapshot } }
            }
            try state.merge(wire)
        }
        return state
    }
    private func mirrorNativeProviderKeys(_ state: VortxNativeProviderCredentials, original: Any?) throws -> [String: Any] {
        guard original == nil || original is [String: Any] else { throw VortxNativeError.invalidSnapshot }
        var keys = (original as? [String: Any]) ?? [:]
        guard keys["metadata"] == nil || keys["metadata"] is [String: Any] else { throw VortxNativeError.invalidSnapshot }
        var metadata = (keys["metadata"] as? [String: Any]) ?? [:]
        for (key, event) in state.local.document.fields {
            let value: String? = if case .string(let value) = event.value { value } else { nil }
            keys[key] = value
            if ["tmdb", "mdblist", "fanart"].contains(key) { metadata[key] = value }
        }
        if keys["metadata"] != nil || !metadata.isEmpty { keys["metadata"] = metadata }
        return keys
    }
    private func acknowledgeNativeProviders(_ document: [String: Any], capture: CredentialScopeRegistry.Capture) throws {
        guard let raw = document["nativeProviderCredentials"] else { return }
        let sent = try JSONDecoder().decode(VortxNativeProviderCredentials.Document.self, from: JSONSerialization.data(withJSONObject: raw))
        guard sent.scope == capture.namespace else { throw VortxNativeError.invalidSnapshot }
        var state = try nativeProviderState(capture: capture)
        state.acknowledge(sent.fields); try saveNativeProviderState(state, capture: capture)
    }
    private func persistMergedNativeProviders(_ candidate: VortxNativeProviderCredentials, capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials {
        // A credential edit can arrive during the kernel await. Never replace that newer intent
        // with the pre-await copy; merge again against the current secure state before publishing.
        var current = try nativeProviderState(capture: capture)
        try current.merge(candidate.document)
        try saveNativeProviderState(current, capture: capture)
        return current
    }
    private func retireNativeProviderApply(_ service: ProviderApplyService, capture: CredentialScopeRegistry.Capture) {
        guard let pending = pendingProviderApply, pending.capture == capture else { return }
        var values = pending.values; values.removeValue(forKey: service)
        var failures = pending.failedServices; failures.remove(service)
        pendingProviderApply = values.isEmpty ? nil : PendingProviderApply(capture: capture, version: pending.version, values: values, failedServices: failures)
    }
    private func nativeGlobalEdits() throws -> [VortxNativeHostPreferences.Edit] {
        var fields: [String: VortxJSON] = [:]
        var unsupported = Array(nativeLegacyWatchlistPending)
        for key in dirtySettings.keys {
            // Old installations can retain dirty stamps for values now explicitly device-local.
            // They neither enter a shared carrier nor prevent unrelated native state from syncing.
            if !SettingsBackup.isSyncable(key) || ["stremiox.profiles.active", "stremiox.activeProfileId"].contains(key) { continue }
            if ProfileStore.nativePlaybackProjectionKeys.contains(key) || ProfileStore.nativeThemeProjectionKeys.contains(key)
                || ProfileDiscoveryPreferencesStore.activeProjectionKeys.contains(key) {
                // A queued/failed profile preference is not a global edit. Keep its dirty stamp
                // until the profile transaction commits, but do not hold unrelated durable
                // Watchlist/history/library changes behind that presentation projection.
                if !nativePreferenceStampIsAttributed(key) || !ProfileStore.shared.nativePreferenceIsAcknowledged(key) { unsupported.append(key) }
                continue
            }
            guard VortxNativeHostPreferences.knownGlobals.contains(key) else {
                unsupported.append(key); continue // Retain dirty data; never acknowledge an unexported value.
            }
            guard let value = nativeGlobalValue(key) else {
                // A malformed local value is not a deletion and must not hold unrelated
                // durable native edits (or the receives waiting on their push) pending.
                unsupported.append(key); continue
            }
            fields[key] = value
        }
        nativeUnsupportedSettings = Array(Set(unsupported)).sorted()
        return fields.isEmpty ? [] : [.init(profileID: nil, fields: fields)]
    }
    private func nativeGlobalValue(_ key: String) -> VortxJSON? {
        guard let object = UserDefaults.standard.object(forKey: key) else { return .null }
        // Foundation raises an Objective-C exception for values such as Data/Date;
        // Swift try? cannot catch that. Validate in an array to also admit JSON scalars.
        guard JSONSerialization.isValidJSONObject([object]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed),
              let value = try? JSONDecoder().decode(VortxJSON.self, from: data),
              VortxNativeHostPreferences.validGlobal(key, value: value) else { return nil }
        return value
    }
    private func nativeDirtySettingsForExport(_ edits: [VortxNativeHostPreferences.Edit], snapshot: [String: Double]) -> [String: Double] {
        let exportedGlobals = Set(edits.filter { $0.profileID == nil }.flatMap { $0.fields.keys })
        return snapshot.filter {
            if SettingsBackup.isSyncable($0.key), VortxNativeHostPreferences.knownGlobals.contains($0.key) {
                return exportedGlobals.contains($0.key)
            }
            return nativeDirtySettingIsExported($0.key)
        }
    }
    private func nativeLegacyWatchlists(_ document: [String: Any]) throws -> [UUID: [VortxNativeWatchlist.Entry]] {
        guard let raw = document["settings"] else { return [:] }
        guard let encoded = raw as? String, let bytes = Data(base64Encoded: encoded),
              let roster = Self.resolveRoster(from: document, fullOnly: true) else { throw VortxNativeError.invalidSnapshot }
        let domain = try SettingsBackup.decodeDomain(from: bytes)
        var result: [UUID: [VortxNativeWatchlist.Entry]] = [:]
        var pending = Set<String>()
        for (key, raw) in domain where key == "vortx.watchlist" || key.hasPrefix("vortx.watchlist.") {
            do {
                guard let profile = roster.profiles.first(where: { key == "vortx.watchlist." + $0.id.uuidString }),
                      let data = raw as? Data else { throw VortxNativeError.invalidSnapshot }
                let entries = try JSONDecoder().decode([VortxNativeWatchlist.Entry].self, from: data)
                guard entries.count <= VortxNativeWatchlist.displayCap else { throw VortxNativeError.invalidSnapshot }
                var identities = Set<String>()
                for entry in entries {
                    let field = try VortxNativeWatchlist.field(id: entry.id, type: entry.type)
                    _ = try VortxNativeWatchlist.value(entry)
                    guard identities.insert(field).inserted else { throw VortxNativeError.invalidSnapshot }
                }
                result[profile.id] = entries
            } catch {
                // Keep the original authenticated settings blob unchanged. An unqualified,
                // malformed or unknown-profile ledger does not authorize an empty replacement.
                pending.insert(key)
            }
        }
        nativeLegacyWatchlistPending = pending
        nativeUnsupportedSettings = Array(pending.union(dirtySettings.keys.filter { !nativeDirtySettingIsExported($0) })).sorted()
        return result
    }
    private func nativeDirtySettingIsExported(_ key: String) -> Bool {
        if SettingsBackup.isSyncable(key), VortxNativeHostPreferences.knownGlobals.contains(key) {
            return nativeGlobalValue(key) != nil
        }
        return VortxNativeSyncExportPolicy.acknowledgesSetting(key, syncable: SettingsBackup.isSyncable(key),
            profileProjection: ProfileStore.nativePlaybackProjectionKeys.contains(key) || ProfileStore.nativeThemeProjectionKeys.contains(key)
                || ProfileDiscoveryPreferencesStore.activeProjectionKeys.contains(key),
            projectionAcknowledged: nativePreferenceStampIsAttributed(key) && ProfileStore.shared.nativePreferenceIsAcknowledged(key))
    }
    private func applyNativeGlobals(_ host: VortxJSON) {
        guard case .object(let fields) = host["globals"]?["fields"] else { return }
        withRemoteApplySuppressed {
            var appliedHomeRailLayout = false
            var appliedCatalogAppearance = false
            let catalogAppearanceKeys: Set<String> = [CatalogPrefsStore.landscapeKey,
                CatalogPrefsStore.widthKey, CatalogPrefsStore.radiusKey,
                CatalogPrefsStore.hideLabelsKey, CatalogPrefsStore.homeLayoutKey]
            for (key, register) in fields where dirtySettings[key] == nil {
                guard let value = register["value"], VortxNativeHostPreferences.validGlobal(key, value: value) else { continue }
                if value == .null { UserDefaults.standard.removeObject(forKey: key) }
                else {
                    guard let data = try? JSONEncoder().encode(value),
                          let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { continue }
                    UserDefaults.standard.set(object, forKey: key)
                }
                if key == HomeRailStore.orderKey || key == HomeRailStore.hiddenKey { appliedHomeRailLayout = true }
                if catalogAppearanceKeys.contains(key) { appliedCatalogAppearance = true }
            }
            if appliedHomeRailLayout { HomeRailPreferences.shared.reloadFromDefaults() }
            // These observable properties are cached at init. Profile/discovery application can run
            // before global registers (or be deferred for a local edit), so refresh after the actual
            // global writes, inside remote-apply suppression, rather than waiting for an app restart.
            if appliedCatalogAppearance { CatalogPreferences.shared.reloadFromDefaults() }
        }
    }
    // A seen authenticated document blocks seeding even if no receipt byte could be written.
    // This process-only floor never certifies a successful pull/upload or replaces the durable floor.
    // Never evict a known account to make another eligible: saturation blocks all unproven seeds.
    private static let nativeObservedBackupAccountLimit = 64
    private var nativeObservedBackupAccounts: Set<String> = []
    private var nativeBackupObservationOverflow = false
    private enum NativeBackupHistory: Equatable { case seen, confirmedAbsent, unavailable }
    private func nativeBackupHistory(capture: CredentialScopeRegistry.Capture) -> NativeBackupHistory {
        guard isCurrent(capture), case .account = capture.scope else { return .unavailable }
        let result = Keychain.confirmedString("vortx.native.backupSeen." + capture.namespace)
        guard isCurrent(capture) else { return .unavailable }
        switch result {
        case .value("1"): return .seen
        case .missing:
            return nativeBackupObservationOverflow || nativeObservedBackupAccounts.contains(capture.namespace) ? .unavailable : .confirmedAbsent
        case .value, .failure: return .unavailable
        }
    }
    private func rememberNativeBackup(capture: CredentialScopeRegistry.Capture) -> Bool {
        guard isCurrent(capture), case .account = capture.scope else { return false }
        if nativeObservedBackupAccounts.count < Self.nativeObservedBackupAccountLimit {
            nativeObservedBackupAccounts.insert(capture.namespace)
        } else if !nativeObservedBackupAccounts.contains(capture.namespace) {
            nativeBackupObservationOverflow = true
        }
        let slot = "vortx.native.backupSeen." + capture.namespace
        let prior = Keychain.confirmedString(slot)
        guard isCurrent(capture) else { return false }
        switch prior {
        case .value("1"): return true // A certified monotonic floor needs no new mutation.
        case .value, .failure: return false // Failure may hide unknown target or invalidation bytes.
        case .missing: break
        }
        // Only certified absence permits creating this receipt. confirmedString deliberately
        // collapses unknown/invalidated/unreadable state; it cannot authorize repair or overwrite.
        // Neither a failed write nor its volatile override certifies the new receipt.
        guard Keychain.set("1", for: slot) == .success,
              Keychain.confirmedString(slot) == .value("1") else { return false }
        return isCurrent(capture)
    }
    private func nativeHostActor(capture: CredentialScopeRegistry.Capture) throws -> String {
        guard isCurrent(capture) else { throw VortxNativeError.superseded }
        let slot = "vortx.native.hostActor." + capture.namespace
        switch Keychain.confirmedString(slot) {
        case .value(let actor):
            guard VortxNativeHostPreferences.validActor(actor) else { throw VortxNativeError.invalidSnapshot }
            return actor
        case .failure: throw VortxNativeError.unavailable
        case .missing: break
        }
        let actor = UUID().uuidString.lowercased()
        guard Keychain.set(actor, for: slot) == .success,
              case .value(let confirmed) = Keychain.confirmedString(slot),
              confirmed.utf8.elementsEqual(actor.utf8) else { throw VortxNativeError.unavailable }
        return actor
    }

    private static func nativeLegacyMaterial(_ document: [String: Any]) throws -> Data {
        guard let roster = resolveRoster(from: document, fullOnly: true),
              roster.profiles.filter(\.isOwner).count == 1,
              let owner = roster.profiles.first(where: \.isOwner) else { throw VortxNativeError.invalidSnapshot }
        _ = try nativeWebsiteEvents(document)
        _ = try nativeWebsiteAddonEvents(document)
        return try VortxLegacyBootstrapMaterial.encode(document: JSONSerialization.data(withJSONObject: document),
                                                       roster: roster.profiles, ownerProfileID: owner.id,
                                                       rosterModifiedSeconds: roster.modified, deferProfileEdits: true)
    }
    private struct NativeLegacyPreparation {
        let material: Data
        let authority: VortxNativeOwnAccountProducer.Authority?
        let sourceArchive: Data?
        var initialPendingOwnProfileIDs: Set<UUID> = []
    }
    /// Keys this device's own native export writes; a change in them is never a 0.4 change.
    private static let nativeExportKeys = ["nativeSync", "nativeHostPreferences", "profileEditResults",
                                           "nativeProviderCredentials", "apiKeys", "nativeOwnerHistorySources"]
    /// Fingerprint of the document's 0.4 fields, the conversion's only input besides linked Stremio accounts.
    /// The native carrier is left out: every device's merge rewrites it, so including it made each sync look
    /// changed and re-converted forever. Nil when the document cannot be read, which always converts. See
    /// `NativeForegroundSyncPolicy.LegacyConversionRecord.digest`.
    private func nativeLegacyConversionDigest(_ document: [String: Any]) -> String? {
        NativeForegroundSyncPolicy.LegacyConversionRecord.digest(of: document, excluding: Self.nativeExportKeys)
    }
    private func nativeLegacyConversionKey(_ capture: CredentialScopeRegistry.Capture) -> String {
        "vortx.native.legacyConversion." + SHA256.hash(data: Data(capture.namespace.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    /// Whether this sync must convert the 0.4 data again, and the fingerprint to record once it has.
    private func nativeLegacyConversionDecision(_ document: [String: Any], capture: CredentialScopeRegistry.Capture,
                                                logging: Bool = true) -> (convert: Bool, digest: String?) {
        let digest = nativeLegacyConversionDigest(document)
        let record = UserDefaults.standard.data(forKey: nativeLegacyConversionKey(capture))
            .flatMap { try? JSONDecoder().decode(NativeForegroundSyncPolicy.LegacyConversionRecord.self, from: $0) }
        let linked = Self.resolveRoster(from: document, fullOnly: true)?.profiles.contains { !$0.isOwner && $0.usesOwnAccount } ?? true
        let decision = NativeForegroundSyncPolicy.LegacyConversionRecord.decide(record, digest: digest, hasLinkedAccounts: linked, now: Date())
        if logging, decision != .skip { DiagnosticsLog.log("native-profiles", "legacy_conversion run reason=\(decision.rawValue)") }
        return (decision != .skip, digest)
    }
    /// The second half of a fast open: the conversion started at launch while the account opened from its
    /// checkpoint; once it finishes it is applied as an ordinary pulled-document commit, so it holds, records and
    /// republishes exactly like a sync.
    private var deferredLegacyConversion: Task<Void, Never>?
    /// Bumped whenever a pulled or merged account document starts committing. The deferred launch conversion
    /// holds the launch document; if a newer one starts committing first, that sync runs its own conversion
    /// decision on the newer document and the deferred one stands down instead of merging older 0.4 data.
    private var nativeDocumentCommitGeneration: UInt64 = 0
    private func applyLaunchNativeLegacyConversion(_ conversion: Task<NativeLegacyPreparation, Error>,
                                                   document: [String: Any], capture: CredentialScopeRegistry.Capture) {
        deferredLegacyConversion?.cancel()
        DiagnosticsLog.log("native-profiles", "legacy_conversion opened_before_finish stage=launch")
        let generation = nativeDocumentCommitGeneration
        deferredLegacyConversion = Task { @MainActor [weak self] in
            do {
                let prepared = try await conversion.value
                guard let self, !Task.isCancelled, self.isCurrent(capture) else { return }
                guard self.nativeDocumentCommitGeneration == generation else {
                    DiagnosticsLog.log("native-profiles", "legacy_conversion result=superseded stage=deferred")
                    return
                }
                _ = try await self.commitNativePulledDocument(document, capture: capture, preparedAtLaunch: prepared,
                                                              standDownIfSuperseded: true)
                DiagnosticsLog.log("native-profiles", "legacy_conversion result=done stage=deferred")
            } catch {
                // A failed or superseded pass records no fingerprint, so the next sync that commits a document converts.
                DiagnosticsLog.log("native-profiles", "legacy_conversion result=failed stage=deferred reason=\(VortxNativeError.diagnosticCode(error))")
            }
        }
    }
    private func recordNativeLegacyConversion(_ digest: String?, capture: CredentialScopeRegistry.Capture) {
        guard let digest, isCurrent(capture),
              let data = try? JSONEncoder().encode(NativeForegroundSyncPolicy.LegacyConversionRecord(digest: digest, convertedAt: Date())) else { return }
        UserDefaults.standard.set(data, forKey: nativeLegacyConversionKey(capture))
    }
    func updateNativeOwnAccountAvailability(missing: [UUID], profiles: [UserProfile], capture: CredentialScopeRegistry.Capture) {
        guard isCurrent(capture) else { return }
        let ownIDs = Set(profiles.filter { !$0.isOwner && $0.usesOwnAccount }.map(\.id))
        nativeOwnAccountResyncUnavailable = Array(Set(nativeOwnAccountResyncUnavailable).intersection(ownIDs).union(missing)).sorted { $0.uuidString < $1.uuidString }
    }
    func nativeOwnAccountReconnected(_ profileID: UUID, capture: CredentialScopeRegistry.Capture) {
        guard isCurrent(capture) else { return }
        nativeOwnAccountResyncUnavailable.removeAll { $0 == profileID }
    }
    private func retireNativeWatchedPendingProjection() {
        nativeWatchedPendingTask?.cancel()
        nativeWatchedPendingTask = nil
        nativeWatchedPendingGeneration = UUID()
    }
    func publishNativeWatchedPending(_ archive: Data?, scope: VortxAccountScope,
        capture: CredentialScopeRegistry.Capture, isCurrentSource: @escaping @Sendable () -> Bool) throws {
        guard isCurrent(capture), scope.account == capture.namespace, isCurrentSource() else { throw VortxNativeError.superseded }
        retireNativeWatchedPendingProjection()
        let generation = nativeWatchedPendingGeneration
        let worker = VortxNativeWatchedArchive.RecoveryWorker(scope: scope,
            isCurrent: { CredentialScopeRegistry.shared.isCurrent(capture) && isCurrentSource() })
        nativeWatchedPendingTask = Task { @MainActor [weak self] in
            do {
                let pending = try await worker.pendingProfileIDs(archive)
                guard let self, !Task.isCancelled, self.isCurrent(capture), isCurrentSource(),
                      self.nativeWatchedPendingGeneration == generation else { return }
                self.nativeWatchedMigrationPending = pending
                self.nativeWatchedPendingTask = nil
            } catch {
                // Failed inspection is not evidence that previously pending work completed.
                guard let self, self.nativeWatchedPendingGeneration == generation else { return }
                self.nativeWatchedPendingTask = nil
            }
        }
    }
    func retryNativeWatchedMigration() async {
        if CoreBridge.shared.hasNativeSession { _ = await syncDown(force: true) }
        else { _ = await retryAccountRestore() }
    }
    func publishNativeOwnOverlayPending(_ value: VortxJSON, capture: CredentialScopeRegistry.Capture) throws {
        guard isCurrent(capture), case .object(let records) = value else { throw VortxNativeError.superseded }
        let ids = try records.keys.map { id in
            guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { throw VortxNativeError.invalidSnapshot }
            return uuid
        }.sorted { $0.uuidString < $1.uuidString }
        if nativeOwnAccountOverlayPending != ids { nativeOwnAccountOverlayPending = ids }
        nativeOwnAccountOverlayUnattributed = ids.filter { records[$0.uuidString]?["verifiedStreamingUid"] == nil }
    }
    private var loggedNativeLegacyReconciliation: VortxNativeSession.LegacyReconciliation?
    /// A held legacy delta no longer blocks native mount/export, so make each transition visible
    /// in diagnostics (once, not on every sync) together with the kernel's sanitized reason.
    private func noteNativeLegacyReconciliation(_ outcome: VortxNativeSession.LegacyReconciliation?, stage: String) {
        guard let outcome, outcome != loggedNativeLegacyReconciliation else { return }
        defer { loggedNativeLegacyReconciliation = outcome }
        switch outcome {
        case .held(let reason, let delta):
            DiagnosticsLog.log("native-profiles", "legacy_reconcile result=held stage=\(stage) reason=\(reason) delta=\(delta)")
        case .accepted where loggedNativeLegacyReconciliation != nil:
            DiagnosticsLog.log("native-profiles", "legacy_reconcile result=accepted stage=\(stage)")
        case .accepted: break
        }
    }
    private func prepareNativeLegacyMaterial(_ document: [String: Any], capture: CredentialScopeRegistry.Capture,
                                             enforceMountedFence: Bool = true,
                                             ownerHistoryRead: VortxNativeSession.OwnerHistoryCheckpointRead? = nil) async throws -> NativeLegacyPreparation {
        guard isCurrent(capture), let roster = Self.resolveRoster(from: document, fullOnly: true),
              let owner = roster.profiles.first(where: \.isOwner), roster.profiles.filter(\.isOwner).count == 1 else { throw VortxNativeError.invalidSnapshot }
        let profiles = roster.profiles.filter { !$0.isOwner && $0.usesOwnAccount }
        let selectedProfile = ProfileStore.shared.activeID
        let mountedSourceFence = CoreBridge.shared.captureNativeSourceFence()
        guard let keyBytes = dataKey, keyBytes.count == 32 else { throw VortxNativeError.unavailable }
        let scope = VortxAccountScope(account: capture.namespace, ownerProfileID: owner.id.uuidString)
        let directory = try VortxNativeStorage.root()
            .appendingPathComponent("VortX/native-engine-v1", isDirectory: true)
        let probe = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: keyBytes),
                                                     installationKey: VortxNativeInstallationKey.loadOrCreate())
        if let ownerHistoryRead {
            guard ownerHistoryRead.scope == scope else { throw VortxNativeError.superseded }
            try ownerHistoryRead.originalRead.withActive {}
        }
        let recoveryCheckpoint: @Sendable () async throws -> Void = { @MainActor [weak self] in
            guard let self, self.isCurrent(capture), ProfileStore.shared.activeID == selectedProfile,
                  !enforceMountedFence || mountedSourceFence() else { throw VortxNativeError.superseded }
            try ownerHistoryRead?.originalRead.withActive {}
        }
        let initialRecovery = VortxNativeWatchedArchive.RecoveryWorker(scope: scope,
            isCurrent: { CredentialScopeRegistry.shared.isCurrent(capture) && (!enforceMountedFence || mountedSourceFence()) },
            checkpoint: recoveryCheckpoint)
        let validatedSync: VortxJSON?
        if let ownerHistoryRead {
            // Only a narrow interpretation projection of the SAME validated checkpoint.
            // Never hydrate a generic runtime or downgrade a real native document.
            validatedSync = try await OwnerHistoryRawAccountPreparationWorker.shared.legacyNativeProjection(ownerHistoryRead.snapshotData)
            try ownerHistoryRead.originalRead.withActive {}
        } else {
            let checkpoint = try await initialRecovery.authenticatedCheckpoint(probe)
            let remote = try document["nativeSync"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
            validatedSync = try VortxNativeSession.authenticatedAccountSync(scope: scope, ownerName: owner.name,
                snapshot: checkpoint, nativeSync: remote, abi: VortxCABI())
        }
        let retainedBaseline = try validatedSync?["legacyImport"]?["baseline"].flatMap { baseline in
            guard [VortxJSON.integer(1), .unsigned(1), .integer(2), .unsigned(2)].contains(baseline["schemaVersion"] ?? .null) else { throw VortxNativeError.invalidSnapshot }
            return try JSONEncoder().encode(baseline)
        }
        let origins = try VortxLegacyBootstrapMaterial.accountOrigins(retainedBaseline)
        let isolatedOrigins = Set(origins.compactMap { $0.value == .isolated ? $0.key : nil })
        let retainedSlots = try validatedSync.flatMap { native in
            ([VortxJSON.integer(4), .unsigned(4), .integer(5), .unsigned(5)].contains(native["schemaVersion"] ?? .null)
                || (ownerHistoryRead != nil && [.integer(6), .unsigned(6)].contains(native["schemaVersion"] ?? .null)))
                ? try VortxNativeProfiles.activeOwnAccountSlotBaselines(nativeSync: native) : nil
        } ?? []
        var preferredSources: [String: VortxJSON] = [:]
        if case .object(let historical) = validatedSync?["legacyImport"]?["baseline"]?["ownAccountSources"] {
            preferredSources = historical
        }
        for slot in retainedSlots {
            if origins[slot.profileID] == .shared || origins[slot.profileID] == .isolated { continue }
            let carrier = try JSONDecoder().decode(VortxJSON.self, from: slot.sourceBaseline)
            guard let source = carrier["source"] else { throw VortxNativeError.invalidSnapshot }
            let historical = preferredSources[slot.profileID.uuidString]
            // A current B slot is never evidence for the historical UUID-only A overlay.
            if historical == nil || historical?["verifiedStreamingUid"] == source["verifiedStreamingUid"] {
                preferredSources[slot.profileID.uuidString] = source
            }
        }
        var retainedEnvelopes: [VortxLegacyBootstrapMaterial.RetainedOwnAccountSourceEnvelope] = []
        var pendingOverlays: [String: VortxJSON] = [:]
        var priorSourceArchive: Data?
        let priorWatchedDraft = try await initialRecovery.readDraft(probe)
        if validatedSync == nil, let priorWatchedDraft {
            let draftHost = try await initialRecovery.hostDocument(priorWatchedDraft)
            if let pending = draftHost["ownAccountOverlayPending"] {
                guard case .object(let values) = pending else { throw VortxNativeError.invalidSnapshot }
                pendingOverlays = values
            }
        }
        priorSourceArchive = priorWatchedDraft
        var watchedArchive = priorWatchedDraft
        let installedSourceArchive: Data?
        if let ownerHistoryRead {
            installedSourceArchive = try await OwnerHistoryRawAccountPreparationWorker.shared.legacyHostSourceArchive(
                ownerHistoryRead.hostPreferencesData, scope: scope)
            try ownerHistoryRead.originalRead.withActive {}
        } else { installedSourceArchive = try await initialRecovery.authenticatedSourceArchive(probe) }
        if let archive = installedSourceArchive {
            priorSourceArchive = try await initialRecovery.retainingUnattributed(archive,
                prior: priorSourceArchive, document: Data("{}".utf8), profileIDs: [])
            watchedArchive = try await initialRecovery.retaining(archive, prior: watchedArchive)
            let host = try await initialRecovery.hostDocument(archive)
            if case .object(let pending) = host["ownAccountOverlayPending"] {
                for (id, record) in pending {
                    // An unattributed draft remains unattributed even if the current host map
                    // has a different source. Its immutable raw records remain in quarantine.
                    if pendingOverlays[id] == nil || pendingOverlays[id]?["verifiedStreamingUid"] != nil { pendingOverlays[id] = record }
                }
            }
            if case .object(let retained) = host["ownAccountSources"] {
                for (id, source) in retained {
                    if let profile = UUID(uuidString: id), case .string(let encoded) = source["sourceDocumentBase64"], let data = Data(base64Encoded: encoded) {
                        let envelope = VortxLegacyBootstrapMaterial.RetainedOwnAccountSourceEnvelope(profileID: profile, sourceDocument: data)
                        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        if preferredSources[id]?["sourceDocumentSha256"] == .string(digest) {
                            retainedEnvelopes.append(envelope)
                        }
                    }
                }
            }
        }
        let documentBytes = try VortxNativeBootstrapArchive.credentialFreeDocument(document, diagnostics: {
            DiagnosticsLog.log("native-profiles", $0)
        })
        let sourceDocument = try JSONDecoder().decode(VortxJSON.self, from: documentBytes)
        let firstImportRecovery = try await initialRecovery.firstImportRecovery(priorSourceArchive)
        let resumedPendingOwn = validatedSync == nil ? Set(firstImportRecovery.pending.keys.compactMap(UUID.init(uuidString:))) : []
        if validatedSync == nil {
            // A changed/removed roster cannot reinterpret a sealed own slice as shared or owner.
            guard firstImportRecovery.quarantinedProfiles.isSubset(of: Set(profiles.map(\.id))) else { throw VortxNativeError.invalidSnapshot }
            for (id, record) in firstImportRecovery.pending { pendingOverlays[id] = record }
        }
        func hasAttribution(_ profileID: UUID) throws -> Bool {
            try VortxNativeOwnAccountProducer.hasOverlayAttribution(proof: preferredSources[profileID.uuidString],
                sealedEnvelope: retainedEnvelopes.first(where: { $0.profileID == profileID })?.sourceDocument)
        }
        struct Captured: Sendable { let profileID: UUID; let slot: String; let token: String; let generation: VortxNativeOwnAccountProducer.Generation; let framing: VortxNativeOwnAccountProducer.SourceFraming }
        var unavailable: [UUID] = []
        var missingOwn = Set<UUID>()
        var newlyMissingOwn = Set<UUID>()
        var missingOwnCredentials: [String: VortxNativeOwnAccountProducer.Generation] = [:]
        var resumedPendingCredentials: [VortxNativeOwnAccountProducer.Generation] = []
        let captured = try profiles.compactMap { profile -> Captured? in
            if resumedPendingOwn.contains(profile.id) {
                // Resume the sealed first-import decision. Credential availability cannot bind
                // the old UUID slice; only an explicit post-import account CAS may connect it.
                let slot = ProfileStore.legacyKeychainAccount(for: profile)
                guard slot != ProfileStore.primaryTokenAccount else { throw VortxNativeError.invalidSnapshot }
                resumedPendingCredentials.append(VortxNativeOwnAccountProducer.capture(slot: slot))
                missingOwn.insert(profile.id); unavailable.append(profile.id)
                return nil
            }
            if origins[profile.id] == .shared || origins[profile.id] == .isolated { return nil }
            // After a rebind the old legacy carrier belongs to its original source, not the
            // currently active external UID. Refresh active own slots only through explicit CAS.
            if validatedSync?["accountSlots"]?[profile.id.uuidString] != nil { return nil }
            let attributed = try hasAttribution(profile.id)
                && !(pendingOverlays[profile.id.uuidString] != nil && pendingOverlays[profile.id.uuidString]?["verifiedStreamingUid"] == nil)
            if validatedSync != nil && !attributed {
                let slice = try VortxNativeOwnAccountProducer.overlay(document: sourceDocument, profileID: profile.id)
                if !(try VortxProfileOverlayWitness.decodeObject(json: slice)).isEmpty {
                    unavailable.append(profile.id); return nil
                }
            }
            let slot: String
            if let native = validatedSync, let account = native["profiles"]?[profile.id.uuidString]?["profile"]?["account"] {
                let binding = VortxJSON.object(["account": account, "revision": .integer(0), "transactionId": .null])
                slot = try VortxNativeAccountCredentials.selectedSlot(scope: capture.namespace, profileID: profile.id, binding: binding)
                    ?? "vortx.native.streaming.unavailable." + profile.id.uuidString
            } else if validatedSync == nil { slot = ProfileStore.legacyKeychainAccount(for: profile) }
            else { slot = "vortx.native.streaming.unavailable." + profile.id.uuidString }
            guard slot != ProfileStore.primaryTokenAccount else { throw VortxNativeError.invalidSnapshot }
            let credential = Keychain.confirmedString(slot)
            guard case .value(let token) = credential, !token.isEmpty else {
                if validatedSync == nil {
                    guard case .missing = credential else { throw VortxNativeError.unavailable }
                    newlyMissingOwn.insert(profile.id)
                    missingOwn.insert(profile.id); unavailable.append(profile.id)
                    missingOwnCredentials[slot] = VortxNativeOwnAccountProducer.capture(slot: slot)
                    return nil
                }
                guard preferredSources[profile.id.uuidString] != nil else {
                    // Name this exact failure (issue #262): the whole restore stops here when a profile linked to
                    // its own Stremio account has no credential on this device and no earlier source copy.
                    DiagnosticsLog.log("native-profiles", "legacy_prepare result=failed reason=own_account_credential_missing "
                        + "profile=\(VXProbeRedaction.identityToken(profile.id.uuidString)) first_import=\(validatedSync == nil)")
                    throw VortxNativeError.unavailable
                }
                unavailable.append(profile.id); return nil
            }
            // An old schema-1 journal is recovery evidence only. In the absence of a native
            // baseline or typed pending origin it cannot be retroactively authenticated by UUID.
            if validatedSync == nil && firstImportRecovery.quarantinedProfiles.contains(profile.id) { throw VortxNativeError.unavailable }
            return Captured(profileID: profile.id, slot: slot, token: token, generation: VortxNativeOwnAccountProducer.capture(slot: slot),
                framing: validatedSync == nil || attributed ? .authenticatedOverlay : .independentNetworkOnly)
        }
        let missingCredentialBindings = missingOwnCredentials
        let authority = VortxNativeOwnAccountProducer.Authority(generations: captured.map(\.generation) + Array(missingCredentialBindings.values) + resumedPendingCredentials, validate: {
            CredentialScopeRegistry.shared.isCurrent(capture) && (!enforceMountedFence || mountedSourceFence()) && captured.allSatisfy {
                if case .value(let current) = Keychain.confirmedString($0.slot) { return current == $0.token }; return false
            } && missingCredentialBindings.keys.allSatisfy {
                if case .missing = Keychain.confirmedString($0) { return true }; return false
            }
        })
        var sources: [VortxLegacyBootstrapMaterial.OwnAccountSource] = []
        let recovery = VortxNativeWatchedArchive.RecoveryWorker(scope: scope,
            isCurrent: { (try? authority.withActive {}) != nil }, checkpoint: recoveryCheckpoint)
        // The classifier's admission token binds these exact bytes. Reuse them at encode rather
        // than serializing an unordered dictionary twice across the asynchronous source fetch.
        for binding in captured {
            do {
                sources.append(try await VortxNativeOwnAccountProducer.fetch(profileID: binding.profileID, authKey: binding.token, authority: authority,
                    profileOverlay: VortxNativeOwnAccountProducer.overlay(document: sourceDocument, profileID: binding.profileID), framing: binding.framing))
            } catch {
                try authority.withActive {} // Cancellation/account/token retirement never falls back.
                guard preferredSources[binding.profileID.uuidString] != nil else { throw error }
                unavailable.append(binding.profileID)
            }
            guard isCurrent(capture), ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
        }
        try authority.withActive {}
        _ = try Self.nativeWebsiteEvents(document)
        _ = try Self.nativeWebsiteAddonEvents(document)
        let freshIDs = Set(sources.map(\.profileID))
        let envelopes = retainedEnvelopes.filter { !freshIDs.contains($0.profileID) }
        let deferred = try VortxLegacyBootstrapMaterial.classifyDeferredOwnAccountOverlays(document: documentBytes,
            roster: roster.profiles, ownerProfileID: owner.id, rosterModifiedSeconds: roster.modified,
            retainedOwnAccountBaseline: retainedBaseline, retainedOwnAccountSourceEnvelopes: envelopes,
            retainedOwnAccountSlotBaselines: retainedSlots).filter { !freshIDs.contains($0.profileID) && !missingOwn.contains($0.profileID) }
        for id in missingOwn.union(isolatedOrigins) where pendingOverlays[id.uuidString] == nil {
            let slice = try VortxNativeOwnAccountProducer.overlay(document: sourceDocument, profileID: id)
            pendingOverlays[id.uuidString] = .object(["profileOverlayBase64": .string(slice.base64EncodedString()), "reason": .string("missing_witness")])
        }
        for disposition in deferred {
            switch disposition.status {
            case .matchedWitness, .matchedSealedEnvelope:
                if pendingOverlays[disposition.profileID.uuidString]?["verifiedStreamingUid"] != nil {
                    pendingOverlays.removeValue(forKey: disposition.profileID.uuidString)
                }
            case .missingWitness, .changedWitness:
                guard disposition.sourceDocumentSHA256 != nil,
                      case .string(let uid) = preferredSources[disposition.profileID.uuidString]?["verifiedStreamingUid"] else { throw VortxNativeError.invalidSnapshot }
                let slice = try VortxNativeOwnAccountProducer.overlay(document: sourceDocument, profileID: disposition.profileID)
                if pendingOverlays[disposition.profileID.uuidString] != nil && pendingOverlays[disposition.profileID.uuidString]?["verifiedStreamingUid"] == nil { continue }
                pendingOverlays[disposition.profileID.uuidString] = try VortxNativeOwnAccountProducer.pendingRecord(disposition: disposition,
                    verifiedUID: uid, overlay: slice, attributed: hasAttribution(disposition.profileID), previous: pendingOverlays[disposition.profileID.uuidString])
            case .missingRetainedSource:
                DiagnosticsLog.log("native-profiles", "legacy_prepare result=failed reason=own_account_source_missing "
                    + "profile=\(VXProbeRedaction.identityToken(disposition.profileID.uuidString))")
                throw VortxNativeError.unavailable
            }
        }
        for source in sources {
            let slice = try VortxNativeOwnAccountProducer.overlay(document: sourceDocument, profileID: source.profileID)
            // Omitted carriers do not acknowledge a previously pending edit. An explicit current
            // slice consumed by this verified source may replace its older pending version.
            if !(try VortxProfileOverlayWitness.decodeObject(json: slice)).isEmpty,
               pendingOverlays[source.profileID.uuidString]?["verifiedStreamingUid"] != nil {
                pendingOverlays.removeValue(forKey: source.profileID.uuidString)
            }
        }
        // Progress drafts contain exact watched evidence and original missing-own disposition,
        // never an unimported fresh own source. They do not alter the native source fence.
        let pendingSources = try await recovery.retainingUnattributed(
            VortxNativeOwnAccountProducer.archive([], pendingOverlays: pendingOverlays), prior: priorSourceArchive,
            document: documentBytes, profileIDs: Set(pendingOverlays.compactMap { key, value in
                value["verifiedStreamingUid"] == nil ? UUID(uuidString: key) : nil
            }), pendingOriginProfileIDs: newlyMissingOwn)
        watchedArchive = try await recovery.retaining(pendingSources, prior: watchedArchive)
        let progress = VortxNativeWatchedArchive.DraftPublisher(expected: priorWatchedDraft) { archive, expected in
            try await probe.retainMigrationDraftCooperatively(archive, scope: scope, expected: expected,
                authority: authority, checkpoint: recoveryCheckpoint)
        }
        watchedArchive = try await VortxNativeWatchedArchive.retryHistorical(watchedArchive, scope: scope,
            isCurrent: { (try? authority.withActive {}) != nil }, fetch: { try await VortxLegacyWatchedMetadataTransport.fetch($0) },
            persist: { try await progress.publish($0) }, checkpoint: recoveryCheckpoint)
        let receiptStream = try await recovery.stream(archive: watchedArchive!, persist: { try await progress.publish($0) })
        let watchedLookup = try await recovery.evidenceLookup(watchedArchive)
        try authority.withActive {}
        let watched = try await VortxLegacyWatchedMigration.prepare(accountID: capture.namespace, ownerProfileID: owner.id,
            document: documentBytes, profileIDs: roster.profiles.filter {
                $0.isOwner || origins[$0.id] == .shared || (origins[$0.id] == nil && !$0.usesOwnAccount)
            }.map(\.id),
            ownAccountSources: sources, archivedEvidenceLookup: watchedLookup,
            receiptSink: { try await receiptStream.append($0, pending: $1) },
            isCurrent: { (try? authority.withActive {}) != nil }, fetch: { try await VortxLegacyWatchedMetadataTransport.fetch($0) })
        let watchedJournal = try await receiptStream.finish()
        try authority.withActive {}
        let unattributedIDs = Set(pendingOverlays.compactMap { key, value in value["verifiedStreamingUid"] == nil ? UUID(uuidString: key) : nil })
        let baseArchive = try await recovery.retainingUnattributed(
            VortxNativeOwnAccountProducer.archive(sources, pendingOverlays: pendingOverlays), prior: priorSourceArchive,
            document: documentBytes, profileIDs: unattributedIDs, pendingOriginProfileIDs: newlyMissingOwn)
        let archive = try await recovery.retaining(baseArchive, prior: watchedJournal)
        if !watched.unresolved.isEmpty {
            // Never pair an unimported own source with the existing kernel receipt. Only the
            // self-contained metadata/pending sidecars enter this no-op checkpoint transaction.
            let pendingArchive = try await recovery.retaining(pendingSources, prior: watchedJournal)
            let pendingIDs = try await recovery.pendingProfileIDs(pendingArchive)
            if ownerHistoryRead == nil, enforceMountedFence, CoreBridge.shared.hasNativeSession {
                _ = try await CoreBridge.shared.mergeNativeAccountDocument(nil, hostRemote: nil, capture: capture,
                    legacyMaterial: nil, sourceAuthority: authority, authenticatedSourceArchive: pendingArchive)
            } else {
                try await progress.publish(pendingArchive)
            }
            guard isCurrent(capture), !Task.isCancelled, ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
            retireNativeWatchedPendingProjection()
            nativeWatchedMigrationPending = pendingIDs
            throw VortxNativeWatchedArchive.Failure.pending
        }
        let preparation = try VortxLegacyBootstrapMaterial.prepare(document: documentBytes,
            roster: roster.profiles, ownerProfileID: owner.id, rosterModifiedSeconds: roster.modified,
            deferProfileEdits: true, ownAccountSources: sources, retainedOwnAccountBaseline: retainedBaseline,
            retainedOwnAccountSourceEnvelopes: envelopes, retainedOwnAccountSlotBaselines: retainedSlots,
            deferredOwnAccountOverlays: deferred, missingOwnAccountProfileIDs: missingOwn,
            accountID: capture.namespace, watchedEvidence: watched.rows)
        // Historical orphan receipts are not permission to fetch/reinstall an add-on or guess a
        // removed title's type. Retain them atomically with this account's encrypted checkpoint.
        // Native exports continue to preserve every original legacy cloud carrier unchanged.
        let preparedArchive = try await recovery.appendingMembership(preparation.pendingMembershipReceipts,
            to: archive, sourceDocument: documentBytes)
        guard isCurrent(capture), ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
        try authority.withActive {}
        // Held units (issue #262) stay only in the retained original document; name them without values.
        let held = preparation.held.isEmpty ? "" : " held=\(preparation.held.count) held_units=" + VortxLegacyBootstrapMaterial.heldSummary(preparation.held)
        DiagnosticsLog.log("native-profiles", "prepare result=ready pending_membership_receipts=\(preparation.pendingCount)\(held)")
        nativeOwnAccountResyncUnavailable = unavailable
        for source in sources {
            guard let binding = captured.first(where: { $0.profileID == source.profileID }) else { throw VortxNativeError.invalidSnapshot }
            try CoreBridge.stageNativeCredential(token: binding.token, source: source, transactionID: nil, capture: capture, authority: authority)
        }
        return .init(material: preparation.material, authority: authority, sourceArchive: preparedArchive,
                     initialPendingOwnProfileIDs: missingOwn)
    }
    private static func nativeWebsiteEvents(_ document: [String: Any]) throws -> [VortxJSON] {
        let carrier = try document["profileEditEvents"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
        var events = try VortxNativeProfileEditHost.events(carrier)
        if let raw = document["profileEdits"] {
            let aggregate = try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: raw))
            let hasRows = !(aggregate["roster"]?.array ?? []).isEmpty
            let hasAdds: Bool
            if case .object(let adds) = aggregate["libraryAdds"] { hasAdds = !adds.isEmpty } else { hasAdds = false }
            if hasRows || hasAdds {
                // An aggregate has no per-user authoring evidence. Retain it separately; neither
                // the v2 queue nor a receipt timestamp can retroactively certify its carried fields.
                events.append(.object(["eventId": .string("legacy-aggregate-" + (try VortxNativeProfileEditHost.valueHash(aggregate))), "legacyAggregate": aggregate]))
            }
        }
        try VortxNativeProfileEditHost.validateSource(events)
        return events
    }
    private static func nativeWebsiteAddonEvents(_ document: [String: Any]) throws -> [VortxJSON] {
        let carrier = try document["webAddonEdits"].map {
            try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]))
        }
        return try VortxNativeWebsiteAddonEdits.events(carrier)
    }
    private func publishNativeWebsiteOutcome(_ outcome: VortxJSON, capture: CredentialScopeRegistry.Capture) throws {
        guard isCurrent(capture) else { throw VortxNativeError.superseded }
        nativeProfileEditConflicts = try outcome["conflicts"]?.decode([VortxNativeProfileEditHost.Conflict].self) ?? []
        nativeAddonEditConflicts = try outcome["addonConflicts"]?.decode([VortxNativeWebsiteAddonEdits.Conflict].self) ?? []
    }

    /// Used only after a successful authenticated empty response, before any accepted version.
    /// Reopens the exact first bootstrap across a crash between local commit and initial upload.
    private func nativeEmptyAccountDocument(capture: CredentialScopeRegistry.Capture) throws -> [String: Any] {
        guard isCurrent(capture), lastSyncedVersion == 0, account != nil,
              let keyBytes = dataKey, keyBytes.count == 32 else { throw VortxNativeError.invalidSnapshot }
        switch nativeBackupHistory(capture: capture) {
        case .confirmedAbsent: break
        case .seen: throw NativeRestoreAdmissionFailure.backupAlreadySeen
        case .unavailable: throw NativeRestoreAdmissionFailure.backupHistoryUnavailable
        }
        let directory = try VortxNativeStorage.root()
            .appendingPathComponent("VortX/native-engine-v1", isDirectory: true)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: keyBytes), installationKey: VortxNativeInstallationKey.loadOrCreate())
        if let recovery = try store.recovery(account: capture.namespace) {
            guard let archive = try JSONSerialization.jsonObject(with: recovery.bootstrap) as? [String: Any],
                  let document = archive["hostDocument"] as? [String: Any],
                  document["nativeAccountBootstrap"] as? String == "authenticated-empty-v1" else { throw VortxNativeError.invalidSnapshot }
            return document
        }
        // The constant owner belongs to this new account scope. No pre-existing global profile,
        // watched item, addon, or preference is silently attributed to the new account.
        let owner = UserProfile(id: UserProfile.ownerID, name: "Main", avatar: "🍿", isOwner: true)
        guard let roster = ProfileRosterSnapshot.wire([owner]) else { throw VortxNativeError.invalidSnapshot }
        return ["nativeAccountBootstrap": "authenticated-empty-v1", "vortx": ["roster": roster, "rosterModified": 0]]
    }

    /// Never install a provisional owner before the server accepts its create-only seed. A
    /// rejected/ambiguous PUT is followed by authenticated readback, not a higher-version retry.
    private func publishDetachedNativeSeed(_ baseline: [String: Any], capture: CredentialScopeRegistry.Capture) async throws -> [String: Any]? {
        guard isCurrent(capture), let keyBytes = dataKey, keyBytes.count == 32,
              let roster = Self.resolveRoster(from: baseline, fullOnly: true),
              let owner = roster.profiles.first(where: \.isOwner) else { throw VortxNativeError.invalidSnapshot }
        let scope = VortxAccountScope(account: capture.namespace, ownerProfileID: owner.id.uuidString)
        let directory = try VortxNativeStorage.root()
            .appendingPathComponent("VortX/native-engine-v1", isDirectory: true)
        let probe = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: keyBytes), installationKey: VortxNativeInstallationKey.loadOrCreate())
        // Preserve historical, already-mounted provisional checkpoints and every edit in them.
        if try probe.authenticatedCheckpoint(scope: scope) != nil { return baseline }
        var candidate = baseline
        let sync = try VortxNativeSession.detachedLegacySync(scope: scope, ownerName: owner.name,
                                                            material: Self.nativeLegacyMaterial(baseline), abi: VortxCABI())
        candidate["nativeSync"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sync))
        let host = try VortxNativeHostPreferences(scope: scope, actor: nativeHostActor(capture: capture))
        candidate["nativeHostPreferences"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host.document))
        guard isCurrent(capture), !Task.isCancelled else { throw VortxNativeError.superseded }
        let seedGeneration = nativeCheckpointGeneration
        let outcome = await pushSyncDocAt(candidate, version: 0, baseRevision: nil, credentialCapture: capture,
            sourceIsCurrent: { self.nativeCheckpointGeneration == seedGeneration })
        if case .upgradeRequired = outcome { return nil }
        guard isCurrent(capture), !Task.isCancelled else { throw VortxNativeError.superseded }
        switch await pullDocVersionedResult(credentialCapture: capture) {
        case .doc(let document, let version, _, _) where version >= lastSyncedVersion: return document
        default: return nil
        }
    }

    private func restoreOfflineNativeCheckpoint(capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UUID) async -> Bool {
        guard let keyBytes = dataKey, keyBytes.count == 32, let selectedProfile,
              isCurrent(capture), !Task.isCancelled else { return false }
        do {
            let directory = try VortxNativeStorage.root()
                .appendingPathComponent("VortX/native-engine-v1", isDirectory: true)
            let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: keyBytes), installationKey: VortxNativeInstallationKey.loadOrCreate())
            if let typed = try store.ownerHistoryRecovery(account: capture.namespace) {
                return try await restoreOwnerHistoryCheckpoint(typed, store: store, capture: capture,
                    selectedProfile: selectedProfile, generation: generation, offline: true)
            }
            guard let recovery = try store.recovery(account: capture.namespace) else { throw VortxNativeError.invalidSnapshot }
            let state = try recovery.scope.validateSnapshot(recovery.state)
            guard let profile = state["roster"]?["profiles"]?[selectedProfile.uuidString], profile["deleted"] != .bool(true),
                  case .string(let ownerName) = state["roster"]?["profiles"]?[recovery.scope.ownerProfileID]?["name"],
                  let archive = try JSONSerialization.jsonObject(with: recovery.bootstrap) as? [String: Any],
                  let material = archive["legacyImportMaterial"] as? [String: Any] else { throw VortxNativeError.invalidSnapshot }
            try VortxNativeSession.validateLegacyCompatibility(scope: recovery.scope, ownerName: ownerName,
                snapshot: recovery.state, nativeSync: nil, material: JSONSerialization.data(withJSONObject: material), abi: VortxCABI())
            let resourceRestore = CoreBridge.shared.captureNativeResourceRestore(capture: capture, profileID: selectedProfile)
            await CoreBridge.shared.closeNativeSession()
            guard isCurrent(capture), !Task.isCancelled, nativeCheckpointGeneration == generation,
                  ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
            let session = try VortxNativeSession(scope: recovery.scope, ownerName: ownerName, abi: VortxCABI(), store: store,
                                                transport: VortxCResourceTransport(), hostActor: nativeHostActor(capture: capture),
                                                diagnostics: { DiagnosticsLog.log("native-profiles", $0) },
                                                ownerHistoryLocalCheckpointPreparation: makeOwnerHistoryLocalCheckpointPreparation(capture: capture, scope: recovery.scope))
            do {
                if state["activeProfileId"] != .string(selectedProfile.uuidString) {
                    let action = VortxJSON.object(["type": .string("switch_profile"), "id": .string(selectedProfile.uuidString)])
                    _ = try await session.dispatch([String(decoding: JSONEncoder().encode(action), as: UTF8.self)], now: UInt64(Date().timeIntervalSince1970))
                }
                let registry = try await session.resourceRegistry()
                let acceptedHost = try await session.hostPreferencesDocument()
                let websiteOutcome = try await session.websiteEditOutcome()
                guard isCurrent(capture), !Task.isCancelled, nativeCheckpointGeneration == generation,
                      ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
                try store.rememberAuthenticatedScope(recovery.scope)
                let sourceDocument = archive["hostDocument"] as? [String: Any] ?? [:]
                let hostProfiles = Self.resolveRoster(from: sourceDocument, fullOnly: true)?.profiles ?? []
                try await CoreBridge.shared.installNativeSession(session, registry: registry, capture: capture, hostProfiles: hostProfiles)
                guard isCurrent(capture), !Task.isCancelled, nativeCheckpointGeneration == generation,
                      ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
                applyNativeGlobals(acceptedHost)
                try publishNativeWebsiteOutcome(websiteOutcome, capture: capture)
                nativeCheckpointStatus = "mounted_offline"
                DiagnosticsLog.log("native-profiles", "restore result=mounted mode=offline")
                CoreBridge.shared.replayNativeResourceRestore(resourceRestore, target: CoreBridge.shared.captureNativePlaybackTarget())
                return true
            } catch { await session.close(); throw error }
        } catch {
            if isCurrent(capture), nativeCheckpointGeneration == generation { nativeCheckpointStatus = "offline_checkpoint_unavailable" }
            return false
        }
    }

    /// A picker retry prepares only a missing session; selection remains a separate acknowledged action.
    @MainActor
    func prepareNativeProfileSelection(credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool {
        let profileID = ProfileStore.shared.activeID
        return await NativeForegroundSyncPolicy.ensureSession(isCurrent: {
            self.isCurrent(capture) && ProfileStore.shared.activeID == profileID
        }, hasCertifiedSession: {
            CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: profileID)
        }, settleResident: {
            await CoreBridge.shared.settleResidentNativeSession(capture: capture)
        }, restore: {
            await self.restoreNativeCheckpoint(credentialCapture: capture, userInitiated: true)
        })
    }

    /// Routine foreground hydration keeps a certified current session and its resource selections.
    @MainActor
    @discardableResult
    private func ensureNativeCheckpoint(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async -> Bool {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        let profileID = ProfileStore.shared.activeID
        return await NativeForegroundSyncPolicy.ensureSession(isCurrent: {
            self.isCurrent(capture) && ProfileStore.shared.activeID == profileID
        }, hasCertifiedSession: {
            CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: profileID)
        }, settleResident: {
            await CoreBridge.shared.settleResidentNativeSession(capture: capture)
        }, restore: {
            await self.restoreNativeCheckpoint(credentialCapture: capture)
        })
    }

    /// The key never leaves this account owner. Only an absent checkpoint permits a complete
    /// authenticated import/native-carrier adoption; failed reads/decryption never mean absence.
    private enum NativeRestoreAdmissionFailure: String, Error {
        case superseded, cancelled
        case accountDocumentUnavailable = "account_document_unavailable"
        case unexpectedUnchanged = "unexpected_unchanged"
        case staleDocument = "stale_document"
        case backupAlreadySeen = "backup_already_seen"
        case backupHistoryUnavailable = "backup_history_unavailable"
        case emptyBootstrapRejected = "empty_bootstrap_rejected"
        case emptySeedRejected = "empty_seed_rejected"
        case emptySeedUnconfirmed = "empty_seed_unconfirmed"
        case rosterUnavailable = "full_roster_unavailable"
        case keyUnavailable = "data_key_unavailable"
        case invalidKey = "data_key_invalid"
        case ownersUnavailable = "owner_attribution_unavailable"
        case selectionUnavailable = "profile_selection_unavailable"

        var stage: String {
            switch self {
            case .accountDocumentUnavailable, .unexpectedUnchanged, .staleDocument: return "account_pull"
            case .backupAlreadySeen, .backupHistoryUnavailable, .emptyBootstrapRejected: return "empty_account_history"
            case .emptySeedRejected, .emptySeedUnconfirmed: return "empty_account_seed"
            default: return "account_admission"
            }
        }
        var status: String {
            switch self {
            case .backupAlreadySeen, .backupHistoryUnavailable, .emptyBootstrapRejected,
                 .emptySeedRejected, .emptySeedUnconfirmed: return "empty_account_attribution_unavailable"
            case .ownersUnavailable, .selectionUnavailable: return "profile_attribution_unavailable"
            default: return "account_document_unavailable"
            }
        }
        var retired: Bool { self == .superseded || self == .cancelled }
    }
    private struct NativeRestoreDocument {
        let document: [String: Any]
        /// Original authenticated plaintext. Never reconstruct a complete account budget or
        /// owner-history source from the Foundation projection above.
        let plaintext: Data
        let observation: UUID?
        let roster: ProfileRosterSnapshot
        let keyBytes: Data
        let owners: [UserProfile]
        let selectedProfile: UUID
    }
    /// The unchanged admission gates are explicit so every preflight refusal has a fixed,
    /// non-sensitive reason. This does not mount, acknowledge, or relax empty-account authority.
    private func nativeRestoreDocument(_ pulled: VersionedPull,
        capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UUID) async throws -> NativeRestoreDocument {
        func requireCurrent() throws {
            guard isCurrent(capture), nativeCheckpointGeneration == generation,
                  ProfileStore.shared.activeID == selectedProfile else { throw NativeRestoreAdmissionFailure.superseded }
            guard !Task.isCancelled else { throw NativeRestoreAdmissionFailure.cancelled }
        }
        try requireCurrent()
        let document: [String: Any]
        let plaintext: Data
        let observation: UUID?
        switch pulled {
        case .doc(let value, let version, let original, let observed):
            guard version >= lastSyncedVersion else { throw NativeRestoreAdmissionFailure.staleDocument }
            document = value; plaintext = original; observation = observed
        case .empty:
            let value: [String: Any]
            do { value = try nativeEmptyAccountDocument(capture: capture) }
            catch let failure as NativeRestoreAdmissionFailure { throw failure }
            catch { throw NativeRestoreAdmissionFailure.emptyBootstrapRejected }
            try requireCurrent()
            let accepted: [String: Any]?
            do { accepted = try await publishDetachedNativeSeed(value, capture: capture) }
            catch {
                try requireCurrent()
                throw NativeRestoreAdmissionFailure.emptySeedRejected
            }
            try requireCurrent()
            guard let accepted else { throw NativeRestoreAdmissionFailure.emptySeedUnconfirmed }
            document = accepted
            // This is our newly created, non-source-bearing empty seed, not a decoded peer.
            plaintext = try JSONSerialization.data(withJSONObject: accepted, options: [.sortedKeys, .withoutEscapingSlashes])
            observation = nil // Fresh non-source-bearing seed; never peer admission authority.
        case .ownerHistory: throw NativeRestoreAdmissionFailure.accountDocumentUnavailable
        case .unchanged: throw NativeRestoreAdmissionFailure.unexpectedUnchanged
        case .failed: throw NativeRestoreAdmissionFailure.accountDocumentUnavailable
        }
        try requireCurrent()
        guard let roster = Self.resolveRoster(from: document, fullOnly: true) else { throw NativeRestoreAdmissionFailure.rosterUnavailable }
        guard let keyBytes = dataKey else { throw NativeRestoreAdmissionFailure.keyUnavailable }
        guard keyBytes.count == 32 else { throw NativeRestoreAdmissionFailure.invalidKey }
        let owners = roster.profiles.filter(\.isOwner)
        guard owners.count == 1 else { throw NativeRestoreAdmissionFailure.ownersUnavailable }
        guard let selectedProfile else { throw NativeRestoreAdmissionFailure.selectionUnavailable }
        return NativeRestoreDocument(document: document, plaintext: plaintext, observation: observation, roster: roster, keyBytes: keyBytes, owners: owners, selectedProfile: selectedProfile)
    }

    @discardableResult
    private static func elapsedMs(since start: Date) -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }

    func restoreNativeCheckpoint(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                                 userInitiated: Bool = false) async -> Bool {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        let selectedProfile = ProfileStore.shared.activeID
        guard isSignedIn, isCurrent(capture), case .account = capture.scope else {
            DiagnosticsLog.log("native-profiles", "restore result=not_started reason=account_not_ready")
            return false
        }
        if let pending = nativeCheckpointTask, nativeCheckpointCapture == capture, nativeCheckpointProfile == selectedProfile {
            let joinedGeneration = nativeCheckpointGeneration
            DiagnosticsLog.log("native-profiles", "restore result=joined reason=in_flight")
            let result = await pending.value
            guard isCurrent(capture), !Task.isCancelled, nativeCheckpointGeneration == joinedGeneration,
                  ProfileStore.shared.activeID == selectedProfile else {
                DiagnosticsLog.log("native-profiles", "restore result=joined_complete outcome=unavailable reason=superseded_or_cancelled")
                return false
            }
            DiagnosticsLog.log("native-profiles", "restore result=joined_complete outcome=\(result ? "ready" : "unavailable")")
            return result
        }
        if let failure = nativeRecoveryFailure, failure.capture == capture, failure.profileID == selectedProfile,
           !failure.backoff.permitsAttempt(at: Date(), userInitiated: userInitiated) {
            DiagnosticsLog.log("native-profiles", "restore result=not_started reason=backoff")
            return false
        }
        let generation = UUID(); nativeCheckpointGeneration = generation; nativeProfileEditConflicts = []; nativeAddonEditConflicts = []; nativeOwnAccountResyncUnavailable = []; nativeOwnAccountOverlayPending = []; nativeOwnAccountOverlayUnattributed = []; retireNativeWatchedPendingProjection(); nativeWatchedMigrationPending = []
        nativeUnsupportedSettings = []; nativeLegacyWatchlistPending = []
        let previous = nativeCheckpointTask; previous?.cancel(); _ = await previous?.value
        guard isCurrent(capture), nativeCheckpointGeneration == generation else {
            DiagnosticsLog.log("native-profiles", "restore result=not_started reason=superseded")
            return false
        }
        nativeCheckpointCapture = capture; nativeCheckpointProfile = selectedProfile
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else {
                DiagnosticsLog.log("native-profiles", "restore result=not_started reason=owner_released")
                return false
            }
            defer {
                if self.nativeCheckpointGeneration == generation {
                    if self.isCurrent(capture), ProfileStore.shared.activeID == selectedProfile {
                        if self.nativeCheckpointStatus == "mounted" {
                            self.nativeRecoveryFailure = nil
                        } else {
                            var backoff = self.nativeRecoveryFailure.flatMap {
                                $0.capture == capture && $0.profileID == selectedProfile ? $0.backoff : nil
                            } ?? .init()
                            backoff.recordFailure(at: Date())
                            self.nativeRecoveryFailure = (capture, selectedProfile, backoff)
                        }
                    }
                    self.nativeCheckpointTask = nil; self.nativeCheckpointCapture = nil; self.nativeCheckpointProfile = nil
                }
            }
            guard self.isCurrent(capture), !Task.isCancelled else {
                DiagnosticsLog.log("native-profiles", "restore result=not_started reason=superseded_or_cancelled")
                return false
            }
            self.nativeCheckpointStatus = "restoring"
            DiagnosticsLog.log("native-profiles", "restore result=started")
            let restoreStarted = Date()
            // Launch and profile switches open the account from this device's own checkpoint first and catch up
            // with the cloud right after (owner, 2026-10-21). Waiting for the download, decrypt, admission and
            // merge first held the splash for ~10 s with nothing new, and launch downloaded and merged the
            // account twice: syncDown pulls, asks for a session, and this restore pulled and merged again. A
            // first open, a checkpoint without its 0.4 copy, or an explicit retry still takes the full online
            // restore below. RemoteConfig `localFirstOpen` switches it off fleet-wide.
            if !userInitiated, RemoteConfig.snapshot.isFeatureOn("localFirstOpen", default: true) {
                if await self.restoreOfflineNativeCheckpoint(capture: capture, selectedProfile: selectedProfile,
                                                             generation: generation) {
                    self.nativeCheckpointStatus = "mounted"
                    DiagnosticsLog.log("native-profiles", "restore result=mounted mode=local_first ms=\(Self.elapsedMs(since: restoreStarted))")
                    // Cloud catch-up. A no-op while the syncDown that asked for this session is still committing
                    // its own pulled document, which it applies right after this returns.
                    Task { @MainActor [weak self] in _ = await self?.syncDown(credentialCapture: capture) }
                    return true
                }
                guard self.isCurrent(capture), !Task.isCancelled, self.nativeCheckpointGeneration == generation else {
                    DiagnosticsLog.log("native-profiles", "restore result=aborted stage=local_first reason=superseded_or_cancelled")
                    return false
                }
                self.nativeCheckpointStatus = "restoring"
                DiagnosticsLog.log("native-profiles", "restore stage=local_first result=unavailable ms=\(Self.elapsedMs(since: restoreStarted))")
            }
            // Global ProfileStore is not account-attribution evidence. Pin the owner from this
            // freshly authenticated/decrypted account roster, including historical PIN-bound IDs.
            let pulled = await self.pullDocVersionedResult(credentialCapture: capture)
            DiagnosticsLog.log("native-profiles", "restore stage=pulled ms=\(Self.elapsedMs(since: restoreStarted))")
            if case .failed(retryable: true) = pulled {
                let restored = await self.restoreOfflineNativeCheckpoint(capture: capture, selectedProfile: selectedProfile, generation: generation)
                if !restored {
                    if !self.isCurrent(capture) || Task.isCancelled || self.nativeCheckpointGeneration != generation
                        || ProfileStore.shared.activeID != selectedProfile {
                        DiagnosticsLog.log("native-profiles", "restore result=aborted stage=offline_restore reason=superseded_or_cancelled")
                    } else { DiagnosticsLog.log("native-profiles", "restore result=failed stage=offline_restore reason=checkpoint_unavailable") }
                }
                return restored
            }
            do {
                if let typed = try await self.restoreOwnerHistoryPulledIfNeeded(pulled,
                    capture: capture, selectedProfile: selectedProfile, generation: generation) { return typed }
            } catch {
                if self.isCurrent(capture), self.nativeCheckpointGeneration == generation {
                    self.nativeCheckpointStatus = "native_checkpoint_unavailable"
                }
                DiagnosticsLog.log("native-profiles", "restore result=failed stage=typed_account reason=\(VortxNativeError.diagnosticCode(error))")
                return false
            }
            let admitted: NativeRestoreDocument
            do {
                admitted = try await self.nativeRestoreDocument(pulled, capture: capture, selectedProfile: selectedProfile, generation: generation)
            } catch {
                let failure: NativeRestoreAdmissionFailure
                if !self.isCurrent(capture) || self.nativeCheckpointGeneration != generation || ProfileStore.shared.activeID != selectedProfile {
                    failure = .superseded
                } else if Task.isCancelled { failure = .cancelled }
                else { failure = (error as? NativeRestoreAdmissionFailure) ?? .accountDocumentUnavailable }
                if !failure.retired, self.isCurrent(capture), self.nativeCheckpointGeneration == generation,
                   ProfileStore.shared.activeID == selectedProfile { self.nativeCheckpointStatus = failure.status }
                DiagnosticsLog.log("native-profiles", "restore result=\(failure.retired ? "aborted" : "failed") stage=\(failure.stage) reason=\(failure.rawValue)")
                return false
            }
            guard self.isCurrent(capture), !Task.isCancelled, self.nativeCheckpointGeneration == generation,
                  ProfileStore.shared.activeID == selectedProfile else {
                DiagnosticsLog.log("native-profiles", "restore result=aborted stage=account_admission reason=superseded_or_cancelled")
                return false
            }
            let document = admitted.document, roster = admitted.roster, keyBytes = admitted.keyBytes
            let owners = admitted.owners, selectedProfile = admitted.selectedProfile
            var stage = "account_preflight"
            do {
                let scope = VortxAccountScope(account: capture.namespace, ownerProfileID: owners[0].id.uuidString)
                _ = try self.mergedNativeProviderState(document, capture: capture) // validate before any native checkpoint commit
                let directory = try VortxNativeStorage.root()
                    .appendingPathComponent("VortX/native-engine-v1", isDirectory: true)
                let documentBytes = admitted.plaintext
                let probe = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: keyBytes), installationKey: VortxNativeInstallationKey.loadOrCreate())
                let checkpoint = try probe.authenticatedCheckpoint(scope: scope)
                let preparationHost = try probe.readHostPreferences(scope: scope)
                let hadCheckpoint = checkpoint != nil
                // Every open checks the complete legacy projection, including pending web edits.
                // Native authority cannot silently ignore a later old-client membership/watch edit.
                stage = "legacy_preparation"
                // A device that already holds this account never waits for the conversion: when one is due it starts
                // right now, alongside opening the account from its checkpoint (which keeps the original 0.4 copy a
                // commit never replaces), and is applied as soon as both are done (applyLaunchNativeLegacyConversion).
                // Only a first open, or a checkpoint without that copy, converts before the account can open.
                var openFromCheckpoint = false
                if hadCheckpoint { openFromCheckpoint = try probe.readLegacyMaterial(scope: scope) != nil }
                var prepared: NativeLegacyPreparation?
                var launchConversion: Task<NativeLegacyPreparation, Error>?
                if !openFromCheckpoint {
                    prepared = try await self.prepareNativeLegacyMaterial(document, capture: capture, enforceMountedFence: false)
                } else if self.nativeLegacyConversionDecision(document, capture: capture).convert {
                    launchConversion = Task { @MainActor in
                        try await self.prepareNativeLegacyMaterial(document, capture: capture, enforceMountedFence: false)
                    }
                }
                guard self.isCurrent(capture), !Task.isCancelled, self.nativeCheckpointGeneration == generation,
                      ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
                guard try probe.authenticatedCheckpoint(scope: scope) == checkpoint,
                      try probe.readHostPreferences(scope: scope) == preparationHost else { throw VortxNativeError.superseded }
                let material = prepared?.material
                let remoteNative = try document["nativeSync"].map {
                    try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0))
                }
                if let material, hadCheckpoint || remoteNative != nil {
                    stage = "legacy_compatibility"
                    let reconciliation = try VortxNativeSession.validateLegacyCompatibility(scope: scope, ownerName: owners[0].name,
                                                                       snapshot: checkpoint, nativeSync: remoteNative,
                                                                       material: material, abi: VortxCABI(), baselineMaterial: probe.readLegacyMaterial(scope: scope),
                                                                       onStage: { stage = "legacy_compatibility_" + $0.rawValue })
                    self.noteNativeLegacyReconciliation(reconciliation, stage: "restore")
                }
                let didImportLegacy = !hadCheckpoint && remoteNative == nil
                var initialActions: [String] = []
                if !hadCheckpoint {
                    guard let material else { throw VortxNativeError.invalidSnapshot }   // a first open always converts
                    let initial: VortxJSON
                    if let native = remoteNative {
                        initial = .object(["type": .string("merge_native_sync"), "document": native])
                    } else {
                        initial = .object(["type": .string("import_legacy_sync"), "scope": .string(scope.account),
                                           "ownerProfileId": .string(scope.ownerProfileID),
                                           "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
                    }
                    initialActions = [String(decoding: try JSONEncoder().encode(initial), as: UTF8.self)]
                    if remoteNative == nil {
                        initialActions += try VortxNativeProfiles.pendingLegacyImportActions(material: material,
                            profileIDs: prepared?.initialPendingOwnProfileIDs ?? [], scope: scope)
                    }
                }
                let archive = try material.map { try VortxNativeBootstrapArchive.encode(document: documentBytes, material: $0, authenticatedSourceArchive: prepared?.sourceArchive) }
                // Keep an already validated session visible while authentication/source parsing
                // is pending or fails. Only retire it once the replacement has passed preflight.
                stage = "session_replacement"
                let resourceRestore = CoreBridge.shared.captureNativeResourceRestore(capture: capture,
                                                                                     profileID: selectedProfile)
                await CoreBridge.shared.closeNativeSession()
                guard self.isCurrent(capture), !Task.isCancelled, self.nativeCheckpointGeneration == generation,
                      ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
                let finalCheckpoint = try probe.authenticatedCheckpoint(scope: scope)
                // This opener deliberately retires its old facade. Its equivalent source fence
                // is exact pre-fetch checkpoint+sidecar equality after retirement, not isAvailable.
                guard finalCheckpoint == checkpoint, try probe.readHostPreferences(scope: scope) == preparationHost else { throw VortxNativeError.superseded }
                stage = "checkpoint_creation"
                let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: keyBytes),
                                                               installationKey: VortxNativeInstallationKey.loadOrCreate(),
                                                               bootstrap: archive, bootstrapScope: scope)
                stage = "session_creation"
                let session = try VortxNativeSession(scope: scope, ownerName: owners[0].name, abi: VortxCABI(), store: store,
                                                    transport: VortxCResourceTransport(), allowNewAccount: !hadCheckpoint, initialActions: initialActions,
                                                    hostActor: self.nativeHostActor(capture: capture), sourceAuthority: prepared?.authority,
                                                    authenticatedSourceArchive: !hadCheckpoint ? prepared?.sourceArchive : nil,
                                                    initialLegacyMaterial: !hadCheckpoint && remoteNative != nil ? material : nil,
                                                    diagnostics: { DiagnosticsLog.log("native-profiles", $0) },
                                                    ownerHistoryLocalCheckpointPreparation: self.makeOwnerHistoryLocalCheckpointPreparation(capture: capture, scope: scope))
                do {
                    stage = "account_merge"
                    let hostRemote = try document["nativeHostPreferences"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
                    let watchlists = try self.nativeLegacyWatchlists(document)
                    let websiteEvents = try Self.nativeWebsiteEvents(document)
                    let websiteAddonEvents = try Self.nativeWebsiteAddonEvents(document)
                    if hadCheckpoint || remoteNative != nil || hostRemote != nil || !websiteEvents.isEmpty || !websiteAddonEvents.isEmpty || !watchlists.isEmpty {
                        let action = remoteNative.map { VortxJSON.object(["type": .string("merge_native_sync"), "document": $0]) } ?? .object(["type": .string("get_state")])
                        _ = try await session.dispatch([String(decoding: JSONEncoder().encode(action), as: UTF8.self)], now: UInt64(Date().timeIntervalSince1970), legacyMaterial: material, hostRemote: hostRemote,
                            legacyWatchlists: watchlists, websiteEvents: websiteEvents, websiteAddonEvents: websiteAddonEvents, websiteBaseline: VortxNativeProfileEditHost.baselines(roster.profiles),
                            sourceAuthority: prepared?.authority, authenticatedSourceArchive: prepared?.sourceArchive)
                    }
                    guard self.isCurrent(capture), !Task.isCancelled, ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
                    let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
                    let selectedRecord = state["roster"]?["profiles"]?[selectedProfile.uuidString]
                    // A first mount cannot attribute another account's global picker selection.
                    // Prefer it only when present in this authenticated roster; otherwise its owner.
                    let installationProfile = (selectedRecord == nil || selectedRecord?["deleted"] == .bool(true)) ? owners[0].id : selectedProfile
                    if state["activeProfileId"] != .string(installationProfile.uuidString) {
                        stage = "active_profile_selection"
                        let action = VortxJSON.object(["type": .string("switch_profile"), "id": .string(installationProfile.uuidString)])
                        _ = try await session.dispatch([String(decoding: JSONEncoder().encode(action), as: UTF8.self)], now: UInt64(Date().timeIntervalSince1970))
                    }
                    stage = "profile_projection"
                    let registry = try await session.resourceRegistry()
                    let acceptedHost = try await session.hostPreferencesDocument()
                    let websiteOutcome = try await session.websiteEditOutcome()
                    guard self.isCurrent(capture), !Task.isCancelled, ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
                    try store.rememberAuthenticatedScope(scope)
                    stage = "session_installation"
                    try await CoreBridge.shared.installNativeSession(session, registry: registry, capture: capture, hostProfiles: roster.profiles)
                    guard self.isCurrent(capture), !Task.isCancelled, self.nativeCheckpointGeneration == generation,
                          ProfileStore.shared.activeID == installationProfile else { throw VortxNativeError.superseded }
                    if prepared != nil { self.recordNativeLegacyConversion(self.nativeLegacyConversionDigest(document), capture: capture) }
                    else if let launchConversion { self.applyLaunchNativeLegacyConversion(launchConversion, document: document, capture: capture) }
                    self.applyNativeGlobals(acceptedHost)
                    try self.publishNativeWebsiteOutcome(websiteOutcome, capture: capture)
                    // Upload only the new nativeSync carrier. The archive never enters the wire,
                    // and adopting an existing remote carrier must not create an echo push.
                    if didImportLegacy || !websiteEvents.isEmpty || !websiteAddonEvents.isEmpty { self.requestSyncSoon() }
                    self.nativeCheckpointStatus = "mounted"
                    CoreBridge.shared.replayNativeResourceRestore(resourceRestore, target: CoreBridge.shared.captureNativePlaybackTarget())
                    DiagnosticsLog.log("native-profiles", "restore result=mounted ms=\(Self.elapsedMs(since: restoreStarted))")
                    return true
                } catch { await session.close(); throw error }
            } catch {
                if self.isCurrent(capture), self.nativeCheckpointGeneration == generation,
                   ProfileStore.shared.activeID == selectedProfile { self.nativeCheckpointStatus = (error as? VortxNativeWatchedArchive.Failure) == .pending ? "watched_migration_pending" : "native_checkpoint_unavailable" }
                // A system error has no VortX code; its domain and number (never paths) name the failing layer.
                let system = error is VortxNativeError ? "" : " domain=\((error as NSError).domain) code=\((error as NSError).code)"
                // A whole-account stop names its reconciliation reason, scrubbed of source values.
                let detail = (error as? VortxLegacyBootstrapMaterial.ReconciliationRequired).map { " detail=" + VortxLegacyBootstrapMaterial.scrubbedReason($0.reason) } ?? ""
                DiagnosticsLog.log("native-profiles", "restore result=failed stage=\(stage) reason=\(VortxNativeError.diagnosticCode(error))\(system)\(detail)")
                return false // No empty account, legacy token dispatch, or destructive repair fallback.
            }
        }
        nativeCheckpointTask = task
        return await task.value
    }
    /// Shared account-owner epoch. Every async sync/auth operation captures this before its first await and
    /// must still own it before applying a result, so an account switch cannot commit A's pull into B.
    private let credentialAuthority = CredentialScopeRegistry.shared
    private var authOperationGeneration: UInt64 = 0
    private var restoreTaskCapture: CredentialScopeRegistry.Capture?
    private var qrOperation: AuthOperationCapture?

    private struct AuthOperationCapture: Sendable, Equatable {
        let generation: UInt64
        let credential: CredentialScopeRegistry.Capture
    }
    private var credentialOwnerRetryTask: Task<Void, Never>?
    private var credentialOwnerRetryFence: AuthOperationCapture?
    private let credentialOwnerMaximumAttempts = 3
    private let credentialOwnerRetryNanos: UInt64 = 100_000_000
    /// Newest doc version this device has pushed or applied. Persisted to UserDefaults per account (see
    /// versionKey(for:)) so the version-wins guard stays consistent across relaunches: an in-memory 0 after a
    /// cold launch would treat
    /// the account's current doc as "newer" and re-apply it once on every launch (harmless but wasteful, and
    /// it re-runs the restore). Seeded from UserDefaults at init.
    /// MIGRATION flip for the version-bound sync-document format (see VortXSyncCrypto.sealDocument). Stays
    /// FALSE until the dual-read build is broadly adopted: a v2 doc is unreadable by any client that predates
    /// openDocument, so writing v2 before then breaks sync for a user whose OTHER device/surface is still on
    /// an older build. openDocument always reads BOTH formats regardless of this flag; only WRITE is gated.
    ///
    /// DO NOT flip to true until ALL of the following hold (each is a hard gate; a premature flip either
    /// breaks or fails to protect real accounts):
    ///   1. Dual-read shipped + adopted on EVERY sync client: this app, the vortx-site dashboard
    ///      (vortx.tv), AND the web client (webapp/, web.vortx.tv) - all three, each with WRITE_SYNC_DOC_V2
    ///      still false. (Dual-read + the decrypt-fail guard is DONE on all three as of this change.)
    ///   2. H-1, a per-account "seen v2" ratchet: once an account's doc has opened as v2 (or this client
    ///      wrote v2), REFUSE a bare-legacy doc for that account thereafter - else a backend can serve an
    ///      archived pre-flip legacy ciphertext under a forged higher version and the legacy read path opens
    ///      it, so the rollback protection is theatre for every account that ever had a legacy doc. NOT DONE.
    ///   3. H-2, a per-account version high-water floor: reject a pulled doc whose version is below the last
    ///      version this device applied FOR THAT ACCOUNT (lastSyncedVersion is currently global, so this
    ///      needs per-account keying to avoid breaking account-switch), so an honest-label replay of an old
    ///      (ciphertext, version) pair cannot become a stale merge base that drops other surfaces' writes.
    ///      NOT DONE.
    /// Flip this AND WRITE_SYNC_DOC_V2 in vortx-site vault.ts AND webapp/src/lib/vault.ts together.
    static let writeSyncDocV2 = false
    // H-2: the newest doc version this device has pushed or applied, keyed PER ACCOUNT so the version-wins
    // guard and the merge-base floor follow the signed-in account. A single global int broke on account-switch
    // (sign out of A at v1000, into B at v5 -> B's pulls would look stale). A fresh per-account key starts at
    // 0, so the first pull is treated as newer and applied once, then stamps the key - the same harmless
    // self-heal the global value had on a cold launch. The computed setter persists immediately.
    private func versionKey(for accountId: String?) -> String { "vortx.sync.lastSyncedVersion." + (accountId ?? "") }
    private var lastSyncedVersion: Int {
        get { UserDefaults.standard.integer(forKey: versionKey(for: account?.id)) }
        set { UserDefaults.standard.set(newValue, forKey: versionKey(for: account?.id)) }
    }
    private func persistLastSyncedVersion() { /* the computed setter above persists per-account; no-op kept so
        the advance-then-persist call sites read unchanged */ }
    // #145 ORDERING GATE. "Has this device positively SEEN this account's document yet?", keyed PER ACCOUNT
    // exactly like versionKey(for:). It is the single authority behind one rule: A DEVICE THAT HAS NOT YET
    // APPLIED THE ACCOUNT'S DOC MUST NOT PUSH OVER IT, EVER. syncUp refuses while this is false, and syncDown
    // treats false as an implicit `force` so neither the pending-push guard nor the version-wins guard can
    // starve the very first restore.
    //
    // Why a SEPARATE key instead of `lastSyncedVersion == 0`: lastSyncedVersion is advanced by an accepted
    // PUSH (pushSyncDocAt), not only by an apply, so on a device that already pushed once it reads "up to
    // date" while having applied nothing. That is precisely the state that makes the #145 loss permanent (the
    // next unforced pull dies at `pulled.version <= lastSyncedVersion`). This flag is written ONLY by syncDown,
    // and only after the account's doc has actually been read: either a decrypted doc was applied, or the pull
    // definitively reported the account HAS no doc (404 / empty), in which case there is nothing to push over
    // and seeding is legitimate. A FAILED or undecryptable pull never sets it, so the fail-safe direction is
    // "this device stays blocked from pushing" rather than "this device wipes the account".
    //
    // A fresh install starts at false because UserDefaults is empty, which is exactly the reinstall case. It is
    // deliberately NOT cleared on signOut: per-account keying already isolates accounts, matching the
    // lastSyncedVersion / lastAppliedProfileEditsAt precedent above.
    private func appliedDocKey(for accountId: String?) -> String { "vortx.sync.didApplyAccountDoc." + (accountId ?? "") }
    private var hasAppliedAccountDoc: Bool {
        get { UserDefaults.standard.bool(forKey: appliedDocKey(for: account?.id)) }
        set { UserDefaults.standard.set(newValue, forKey: appliedDocKey(for: account?.id)) }
    }
    /// Per-account "last successful sync" wall-clock stamp behind the published `lastSyncAt`. Keyed per
    /// account exactly like versionKey(for:) so an account switch shows that account's own stamp. Under the
    /// `vortx.sync.` prefix so SettingsBackup.deviceLocalKeyPrefixes keeps it out of every synced blob.
    private func lastSyncKey(for accountId: String?) -> String { "vortx.sync.lastSuccessAt." + (accountId ?? "") }
    /// Re-seed the published `lastSyncAt` from the persisted per-account stamp (sign-in / Keychain restore).
    private func reloadLastSyncStamp() {
        backupUploadFailure = nil // A transport issue belongs to the previous session, not another account.
        let t = UserDefaults.standard.double(forKey: lastSyncKey(for: account?.id))
        lastSyncAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    /// Record a successful sync round-trip NOW. The UserDefaults write rides the remote-apply suppression
    /// window (nested calls are re-entrancy-safe, see withRemoteApplySuppressed) so stamping a push can
    /// never arm ANOTHER push via the global didChange observer (a self-echo loop).
    private func stampSyncSuccess() {
        let now = Date()
        withRemoteApplySuppressed {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastSyncKey(for: account?.id))
        }
        lastSyncAt = now
    }
    /// The Phase-0 seeding signal for the com.vortx move: this device is signed in AND has completed at
    /// least one REAL sync round-trip with the account (an accepted push or an applied pull), so an
    /// encrypted doc exists server-side and a future reinstall/bundle-id move restores it on sign-in.
    /// `lastSyncedVersion > 0` backfills installs that synced before this build existed (it advances only
    /// on an accepted push or an applied pull, never on an `.empty` account); `lastSyncAt` covers the
    /// fresh path going forward. Deliberately NOT `hasAppliedAccountDoc`, which also flips on an `.empty`
    /// pull, where nothing is backed up yet.
    var hasCompletedFirstSync: Bool {
        isSignedIn && (lastSyncAt != nil || lastSyncedVersion > 0)
    }
    /// In-flight guaranteed restore, so the sign-in kick, the Keychain-restored relaunch kick, and a syncUp
    /// that is blocked by the gate all await ONE restore instead of racing several forced pulls at once.
    private var restoreTask: Task<Bool, Never>?
    /// The provider token migrations have an actor-bound publication step after their synchronous raw-slot
    /// claim. Keep one captured task so a later owner generation cancels the old retry before it can publish.
    private var providerLegacyMigrationTask: Task<Bool, Never>?
    private var providerLegacyMigrationCapture: CredentialScopeRegistry.Capture?
    private var providerLegacyMigrationGeneration: UInt64 = 0
    private let providerLegacyMigrationMaximumAttempts = 3
    private let providerLegacyMigrationRetryNanos: UInt64 = 100_000_000
    private let providerRemoteApplyMaximumAttempts = 3
    private let providerRemoteApplyRetryNanos: UInt64 = 100_000_000
    /// LWW stamp of the last web profileEdits applied, keyed PER ACCOUNT (mirroring versionKey(for:)) so an
    /// account switch cannot skip the new account's dashboard edits against the previous account's high-water
    /// mark. Persisted to UserDefaults so a sign-out / re-login for the SAME account does not re-window an old
    /// dashboard edit (e.g. a delete the app has already honored); a fresh per-account key starts at 0, and
    /// re-apply is idempotent regardless. The per-account key RETAINS each account's high-water mark across
    /// re-login, so signOut deliberately does NOT reset it.
    private func editsAtKey(for accountId: String?) -> String { "vortx.sync.lastAppliedProfileEditsAt." + (accountId ?? "") }
    private var lastAppliedProfileEditsAt: Double {
        get { UserDefaults.standard.double(forKey: editsAtKey(for: account?.id)) }
        set { UserDefaults.standard.set(newValue, forKey: editsAtKey(for: account?.id)) }
    }
    /// The syncable keys the LAST account document this device APPLIED actually wrote, in migrated form (it
    /// mirrors what SettingsBackup.restore persisted). Keyed PER ACCOUNT like the gates above, and stored under
    /// the `vortx.sync.` prefix so SettingsBackup.deviceLocalKeyPrefixes already keeps it out of every synced blob
    /// and backup file. SettingsBackup.mergedSyncBlob reads it on push to distinguish a setting the user
    /// deliberately CLEARED on this device (absent locally AND in this baseline => delete from the push, so a
    /// pull cannot re-pin it) from a key a peer authored after this device's last apply (absent AND not in the
    /// baseline => keep). A fresh install has an EMPTY baseline, which is exactly why the reinstall guard still
    /// holds: nothing is ever "absent AND in baseline", so no account key is deleted. Not reset on signOut
    /// (per-account keying isolates accounts), matching lastSyncedVersion / hasAppliedAccountDoc above.
    private func settingsBaselineKey(for accountId: String?) -> String { "vortx.sync.appliedSettingsKeys." + (accountId ?? "") }
    private var appliedSettingsBaseline: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: settingsBaselineKey(for: account?.id)) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: settingsBaselineKey(for: account?.id)) }
    }
    /// LOCAL-WINS dirty set: syncable settings keys the user changed on THIS device that have NOT been confirmed
    /// onto the account yet, as `key -> dirtyAt` (epoch). Keyed PER ACCOUNT exactly like the gates above and
    /// under the `vortx.sync.` prefix so `SettingsBackup.deviceLocalKeyPrefixes` already keeps it out of every
    /// synced blob and backup file. The PULL path (syncDown) skips these keys when applying the account's
    /// settings blob, so a just-made local change is never clobbered by the account's older value before this
    /// device pushes it; the mark clears only after a CONFIRMED push (see `clearPushedDirtySettings`). Per-account
    /// keying is what satisfies "a device switching accounts must not carry another account's dirty set": account
    /// B reads its own (empty) slot and applies B's values normally. Not reset on signOut (per-account keying
    /// isolates accounts), matching lastSyncedVersion / appliedSettingsBaseline above; that also protects a
    /// sign-out / re-login for the SAME account, whose reconcile pull would otherwise re-clobber the unpushed edit.
    private func dirtySettingsKey(for accountId: String?) -> String { "vortx.sync.dirtySettings." + (accountId ?? "") }
    private var dirtySettings: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: dirtySettingsKey(for: account?.id)) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: dirtySettingsKey(for: account?.id)) }
    }
    /// The last SYNCABLE defaults snapshot the differ reconciled. In-memory only: it tracks the physical
    /// `UserDefaults` domain (account-independent), while the dirty SET above is per-account. Seeded at init and
    /// re-baselined after every remote-apply / housekeeping window (so a suppressed non-user write is never
    /// mis-attributed to a later user edit). There is no per-key UserDefaults change signal, so a change is
    /// detected by diffing this shadow against the live domain in the global didChange observer.
    private var settingsShadow: [String: Any] = [:]

    /// The app's OWN syncable defaults right now (the exact set `SettingsBackup` pushes), used as both the
    /// differ input and the shadow baseline. Mirrors `makeBackup` / `mergedSyncBlob`'s domain read.
    private func currentSyncableDomain() -> [String: Any] {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        return (UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:])
            .filter {
                SettingsBackup.isSyncable($0.key)
                    && !ProfileDiscoveryPreferencesStore.activeProjectionKeys.contains(
                        SettingsBackup.migratedKey($0.key))
            }
    }
    /// Re-baseline the differ shadow to the live domain. Called after a remote apply / suppressed housekeeping
    /// window so those non-user writes become the baseline, never a future user edit's phantom diff.
    private func refreshSettingsShadow() { settingsShadow = currentSyncableDomain() }
    /// A genuine LOCAL settings write landed (the global didChange observer, already gated on !isApplyingRemote,
    /// so a remote-apply / housekeeping write never reaches here). Diff the live domain against the shadow, mark
    /// any changed syncable key dirty, and re-baseline the shadow. No-op when signed out (nothing to protect).
    @discardableResult
    private func noteLocalSettingsChange() -> Bool {
        guard isSignedIn else { return false }
        let current = currentSyncableDomain()
        let changed = SettingsDirtyKeys.changedSyncableKeys(from: settingsShadow, to: current,
                                                            isSyncable: SettingsBackup.isSyncable)
        settingsShadow = current
        guard !changed.isEmpty else { return false }
        var dirty = dirtySettings
        SettingsDirtyKeys.mark(changed, at: Date().timeIntervalSince1970, into: &dirty)
        dirtySettings = dirty
        return true
    }

    private func observeDefaultsChange() {
        guard !isApplyingRemote else { return }
        // Only a real syncable delta may defer receiving peer profile edits.
        if noteLocalSettingsChange() { requestSyncSoon() }
    }
    private var pendingLocalRosterPush: CredentialScopeRegistry.Capture?
    private var pendingNativeMutationPush: CredentialScopeRegistry.Capture?

    /// Stronger than a defaults notification: a kernel mutation was committed to its checkpoint.
    /// A remote projection's notification-suppression turn must not drop this upload admission.
    func nativeMutationDidCommit(credentialCapture capture: CredentialScopeRegistry.Capture, progressOnly: Bool = false) {
        guard isSignedIn, isCurrent(capture) else { return }
        // Record the generation immediately, including the suppression turn. Otherwise an older
        // upload could clear the durable flag before this deferred admission reaches its worker.
        nativePushQueue.request(progressOnly: progressOnly)
        nativeDurablePushPending = true
        if isApplyingRemote { pendingNativeMutationPush = capture }
        else { requestSyncSoon(progressOnly: progressOnly) }
    }

    private func drainNativeMutationPush() {
        guard !isApplyingRemote, let capture = pendingNativeMutationPush else { return }
        pendingNativeMutationPush = nil
        guard isSignedIn, isCurrent(capture) else { return }
        requestSyncSoon()
    }

    /// Explicit local persistence is stronger evidence than a queued defaults notification.
    /// The caller excludes housekeeping and remote profile-edit application.
    private func noteLocalRosterMutation() {
        guard isSignedIn else { return }
        let capture = credentialAuthority.capture()
        guard isCurrent(capture) else { return }
        let keys: Set<String> = ["stremiox.profiles", "stremiox.profiles.modified"]
        var dirty = dirtySettings
        SettingsDirtyKeys.mark(keys, at: Date().timeIntervalSince1970, into: &dirty)
        dirtySettings = dirty
        let current = currentSyncableDomain()
        for key in keys { settingsShadow[key] = current[key] }
        if isApplyingRemote { pendingLocalRosterPush = capture }
        else { requestSyncSoon() }
    }

    private func drainLocalRosterPush() {
        guard !isApplyingRemote, let capture = pendingLocalRosterPush else { return }
        pendingLocalRosterPush = nil
        guard isSignedIn, isCurrent(capture) else { return }
        requestSyncSoon()
    }

    nonisolated static func localRosterDidPersist() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.noteLocalRosterMutation() }
        } else {
            DispatchQueue.main.sync { shared.noteLocalRosterMutation() }
        }
    }
    /// Clear the keys a CONFIRMED push carried up, guarded by the stamp `snapshot` taken when that push began so a
    /// key re-edited mid-push stays protected (see `SettingsDirtyKeys.clearPushed`). Under the suppression window:
    /// it is a `vortx.sync.` UserDefaults write and must not arm a self-echo push.
    private func clearPushedDirtySettings(_ snapshot: [String: Double]) {
        guard !snapshot.isEmpty else { return }
        // Preference stamps are cleared only by their exact accepted journal receipt. A
        // predecessor upload can complete after a successor has committed another field.
        let snapshot = snapshot.filter { !Self.nativePreferenceProjectionKeys.contains($0.key) && nativeDirtySettingIsExported($0.key) }
        withRemoteApplySuppressed {
            var dirty = dirtySettings
            SettingsDirtyKeys.clearPushed(snapshot, from: &dirty)
            dirtySettings = dirty
        }
    }
    /// After a startup pull, a still-dirty settings key (a change made in a previous session whose debounced push
    /// never landed) needs a push so the account and the rest of the fleet heal. syncUp reads local, so the dirty
    /// value (local wins) rides up and the confirmed push clears the dirty mark. Debounced via requestSyncSoon so
    /// it coalesces with any other pending change. No-op when there is nothing unpushed.
    private func flushDirtySettingsIfNeeded() {
        guard isSignedIn, hasPendingPush || !dirtySettings.isEmpty || pendingAddonOrderIntent != nil || nativePreferenceIntentsNeedReplay() else { return }
        requestSyncSoon()
    }
    private var pendingAddonOrderIntent: AddonOrderIntent? {
        get {
            guard let id = account?.id,
                  let data = UserDefaults.standard.data(forKey: "vortx.sync.pendingAddonOrder." + id),
                  let intent = try? JSONDecoder().decode(AddonOrderIntent.self, from: data),
                  intent.accountID == id else { return nil }
            return intent
        }
        set {
            guard let id = account?.id else { return }
            let key = "vortx.sync.pendingAddonOrder." + id
            if let newValue, newValue.accountID == id, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    private var activeSyncUp: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    private var syncUpCompletionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    private func finishSyncUp(_ operationID: UUID) {
        if activeSyncUp?.id == operationID { activeSyncUp = nil }
        let waiters = syncUpCompletionWaiters.removeValue(forKey: operationID) ?? [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// Join the exact upload, without polling or cancelling the uploader when UIKit expires our lease.
    private func awaitSyncUpCompletion(_ operationID: UUID) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, activeSyncUp?.id == operationID else {
                    continuation.resume(); return
                }
                syncUpCompletionWaiters[operationID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.syncUpCompletionWaiters[operationID]?.removeValue(forKey: waiterID)?.resume()
                if self?.syncUpCompletionWaiters[operationID]?.isEmpty == true {
                    self?.syncUpCompletionWaiters.removeValue(forKey: operationID)
                }
            }
        }
    }
    /// Last shared add-on ORDER applied from the account (Bug B). Persisted normalized transportUrls in the
    /// converged priority order. Read by ownedAddons(from:) as the ordering spine when a pulled doc does not
    /// itself carry addonOrder, so a device that hydrates after (but not during) an order change still lands
    /// the converged order. Empty means "no shared order yet" (fall back to the descriptor spine).
    nonisolated private static let kAddonOrderKey = "vortx.sync.appliedAddonOrder"
    /// Upper bound on the persisted order length. A real account has a few dozen add-ons; this only exists so a
    /// malicious/garbage synced `doc.addonOrder` can't balloon UserDefaults. Applied in the setter, which is the
    /// single chokepoint for both the in-app reorder and the syncDown apply.
    nonisolated private static let maxAddonOrderEntries = 1024
    /// `nonisolated`: it only touches thread-safe `UserDefaults` (and Sendable `let` backing constants), so
    /// nonisolated read sites like `CoreMetaDetails.meta` (the #144 detail-language pick, a plain Decodable
    /// evaluated off the main actor) can consult the shared order without an actor hop. All existing
    /// main-actor callers keep working (nonisolated members are callable from any context).
    nonisolated static var appliedAddonOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: AddonOwnerStorage.currentKey(kAddonOrderKey)) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(maxAddonOrderEntries)), forKey: AddonOwnerStorage.currentKey(kAddonOrderKey)) }
    }
    /// Posted (main thread) whenever the shared add-on order changes: an in-app Reorder drag or a remote
    /// pull that carried a newer order. Views showing the add-on list observe it to re-sort live, since
    /// appliedAddonOrder is a plain UserDefaults static (not @Published) and gives SwiftUI no other signal.
    nonisolated static let addonOrderChangedNote = Notification.Name("vortx.addonOrderChanged")
    /// Posted after the process-wide VortX credential namespace changes. CoreBridge uses this
    /// non-secret generation receipt to retire queued engine history before a new owner hydrates.
    static let credentialScopeDidChangeNote = Notification.Name("vortx.credentialScopeDidChange")

    private func publishAppliedAddonOrder(_ order: [String]) {
        let normalized = AddonOrderSyncPolicy.unique(order.map(AddonTombstones.normalize))
        guard normalized != Self.appliedAddonOrder else { return }
        Self.appliedAddonOrder = normalized
        CoreBridge.shared.addonOrderDidChange()
        NotificationCenter.default.post(name: Self.addonOrderChangedNote, object: nil)
    }

    /// Sort a live list of items by the shared `appliedAddonOrder` (the in-app / dashboard reorder), keyed
    /// by each item's transport URL. Items present in the order come first, in that order; any not yet in it
    /// (a fresh install) keep their original relative order at the END so they are never hidden. An empty
    /// order returns the input unchanged, so this is a no-op until the user actually reorders.
    static func orderedByApplied<T>(_ items: [T], url: (T) -> String) -> [T] {
        ProfileAddonPreferencesPolicy.sorted(items,
            order: ProfileStore.activeAddonOrder(accountOrder: appliedAddonOrder), key: url)
    }

    /// Persist a user-chosen add-on order (the in-app Reorder screen) and push it to the account IMMEDIATELY
    /// so the dashboard and the user's other devices converge, mirroring the dashboard's doc.addonOrder write.
    /// The immediate push avoids the debounce-starvation that delayed removals (see uninstallAddon).
    func applyInAppAddonOrder(_ transportUrls: [String]) {
        let normalized = AddonOrderSyncPolicy.unique(transportUrls.map { AddonTombstones.normalize($0) })
        guard normalized != Self.appliedAddonOrder else { return }
        Self.appliedAddonOrder = normalized
        let capture = credentialAuthority.capture()
        if isSignedIn, hasAppliedAccountDoc, isCurrent(capture), !hasPendingAccountDocApply(for: capture),
           let id = account?.id {
            pendingAddonOrderIntent = AddonOrderIntent(accountID: id, order: normalized)
        }
        CoreBridge.shared.addonOrderDidChange()
        // Refresh any live add-on list NOW: appliedAddonOrder is a plain UserDefaults static, not @Published,
        // so views showing the list have no other signal to re-run orderedByApplied on their current body.
        NotificationCenter.default.post(name: Self.addonOrderChangedNote, object: nil)
        Task {
            guard self.isCurrent(capture) else { return }
            let ok = await pushThisDevice()
            NSLog("[addon] in-app reorder pushed to sync (%d add-ons, ok=%@)", normalized.count, ok ? "yes" : "no")
        }
    }

    /// Called only after CoreBridge has owner-fenced a confirmed atomic engine replacement.  Keep the
    /// previous URL's explicit priority slot rather than letting the new descriptor fall through to last.
    func replaceInAppAddonOrder(oldTransportURL: String, newTransportURL: String) {
        applyInAppAddonOrder(AddonOrderSyncPolicy.replacing(
            Self.appliedAddonOrder, oldURL: oldTransportURL, newURL: newTransportURL))
    }
    private var nativePushQueue = NativeForegroundSyncPolicy.PushQueue()
    private var nativeDurablePushPending: Bool {
        get {
            guard let id = account?.id else { return false }
            return UserDefaults.standard.bool(forKey: "vortx.sync.pendingNativePush." + id)
        }
        set {
            guard let id = account?.id else { return }
            UserDefaults.standard.set(newValue, forKey: "vortx.sync.pendingNativePush." + id)
        }
    }
    private var hasPendingPush: Bool { nativePushQueue.hasPendingPush || nativeDurablePushPending }
    private var activeSyncDown: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    private struct PendingDebridApply: Equatable {
        let capture: CredentialScopeRegistry.Capture
        let version: Int
        let values: [String: String]
        let failedServices: Set<DebridService>
    }
    private enum ProviderApplyService: Hashable {
        case trakt
        case simkl
    }
    private enum ProviderApplyValue: Equatable {
        case none
        case trakt(access: String, refresh: String, expiryUnix: Int)
        case simkl(access: String, expiryUnix: Int)
    }
    private struct PendingProviderApply: Equatable {
        let capture: CredentialScopeRegistry.Capture
        let version: Int
        let values: [ProviderApplyService: ProviderApplyValue]
        let failedServices: Set<ProviderApplyService>
    }
    /// A remote Debrid value that was not certified is stronger than the ordinary local-push guard: until the
    /// same remote truth is applied successfully, no local snapshot may be pushed over it.
    private var pendingDebridApply: PendingDebridApply?
    private var pendingProviderApply: PendingProviderApply?

    private func hasPendingDebridApply(for capture: CredentialScopeRegistry.Capture) -> Bool {
        guard let pending = pendingDebridApply else { return false }
        guard pending.capture == capture else {
            pendingDebridApply = nil
            return false
        }
        return true
    }
    private func hasPendingProviderApply(for capture: CredentialScopeRegistry.Capture) -> Bool {
        guard let pending = pendingProviderApply else { return false }
        guard pending.capture == capture else {
            pendingProviderApply = nil
            return false
        }
        return true
    }
    private func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool {
        let hasDebrid = hasPendingDebridApply(for: capture)
        let hasProviders = hasPendingProviderApply(for: capture)
        return hasDebrid || hasProviders
    }

    /// The same doc retries only the values whose certified adoption failed. A newer doc replaces a present
    /// provider tuple but carries a failed older tuple forward when the newer document omits that provider.
    private func providerApplyIntent(
        keys: [String: String]?,
        capture: CredentialScopeRegistry.Capture,
        version: Int
    ) -> PendingProviderApply? {
        // Native retries are reconstructed from the current merged register snapshot. Retaining an
        // older value-only plan could resurrect a tuple superseded by a local reconnect or clear.
        let priorValues: [ProviderApplyService: ProviderApplyValue] = [:]
        var values: [ProviderApplyService: ProviderApplyValue] = [:]
        if let keys {
            if let access = keys["traktAccess"], let refresh = keys["traktRefresh"],
               !access.isEmpty, !refresh.isEmpty {
                values[.trakt] = .trakt(
                    access: access,
                    refresh: refresh,
                    expiryUnix: Int(keys["traktExpiry"] ?? "") ?? 0)
            } else if let retained = priorValues[.trakt] {
                values[.trakt] = retained
            }
            if let access = keys["simklAccess"], !access.isEmpty {
                values[.simkl] = .simkl(
                    access: access,
                    expiryUnix: Int(keys["simklExpiry"] ?? "") ?? 0)
            } else if let retained = priorValues[.simkl] {
                values[.simkl] = retained
            }
        } else {
            values = priorValues
        }
        guard !values.isEmpty else { return nil }
        return PendingProviderApply(
            capture: capture,
            version: version,
            values: values,
            failedServices: Set(values.keys))
    }
    /// Set while syncDown is applying a remote pull (the SettingsBackup.restore + apiKeys + overlays +
    /// tombstones region) and while ProfileStore is doing touch:false launch housekeeping. The global
    /// UserDefaults.didChangeNotification observer early-returns while this is true, so applying a pull
    /// (which rewrites every stremiox.* key) no longer self-echoes into requestSyncSoon(), which would
    /// re-arm hasPendingPush and push the just-applied peer values straight back, starving syncDown's
    /// guard at line ~471 so a receiving device never applies a peer's settings. A genuine user edit
    /// (touch:true) is NEVER wrapped in this, so real settings toggles still push and sync.
    private var isApplyingRemote = false

    // MARK: - Real-time sync state (WebSocket + while-active poll)
    /// The live SyncRoom socket; nil whenever disconnected. Receives {"type":"updated","version":N}
    /// pushes from other devices and triggers a pull within ~1s.
    private var ws: URLSessionWebSocketTask?
    private var wsCapture: CredentialScopeRegistry.Capture?
    private var wsBackoff: TimeInterval = 1          // reconnect delay, doubled per failure (capped)
    private var wsReconnect: Task<Void, Never>?      // pending reconnect attempt
    private var wsKeepAlive: Task<Void, Never>?      // periodic "ping" so the room never idles us out
    private var pollTask: Task<Void, Never>?         // while-active fallback poll
    private var wsHeardAt: Date?                     // last frame from the live socket (pongs every 30 s)
    private var lastPollPullAt: Date?                // last pull the while-active poll made
    /// A process-local receipt for a fully published receive, never a websocket or PUT version.
    private struct NativeReceiveReceipt {
        let capture: CredentialScopeRegistry.Capture
        let target: PlaybackMutationTarget
        let key: Data
        let version: Int
    }
    private var nativeReceiveReceipt: NativeReceiveReceipt?

    private func conditionalReceiveVersion(_ capture: CredentialScopeRegistry.Capture) -> Int? {
        guard let receipt = nativeReceiveReceipt, receipt.capture == capture, isCurrent(capture),
              receipt.key == dataKey, receipt.version == lastSyncedVersion,
              hasAppliedAccountDoc, !hasPendingPush, !hasPendingAccountDocApply(for: capture),
              CoreBridge.shared.nativePlaybackTargetIsCurrent(receipt.target),
              CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: ProfileStore.shared.activeID)
        else { nativeReceiveReceipt = nil; return nil }
        return receipt.version
    }

    private func rememberCompletedNativeReceive(version: Int, capture: CredentialScopeRegistry.Capture,
                                                target: PlaybackMutationTarget?) {
        guard isCurrent(capture), !Task.isCancelled, let key = dataKey, !hasPendingPush,
              let target, CoreBridge.shared.nativePlaybackTargetIsCurrent(target),
              !hasPendingAccountDocApply(for: capture),
              CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: ProfileStore.shared.activeID)
        else { nativeReceiveReceipt = nil; return }
        nativeReceiveReceipt = .init(capture: capture, target: target, key: key, version: version)
    }
    private var realtimeActive = false               // true between startRealtime() and stopRealtime()
    private let wsMaxBackoff: TimeInterval = 30
    private let pollIntervalNanos: UInt64 = 3_000_000_000    // bounded native fallback while active
    private let keepAliveNanos: UInt64 = 30_000_000_000      // 30s ping to hold the room open

    private init() {
        restore()
        _ = DebridKeys.shared
        // Auto-sync: profiles and settings persist to UserDefaults, so one observer catches every change
        // and schedules a debounced push (no-op when signed out). Metadata keys (Keychain) push via ApiKeys.
        // SUPPRESSION: while isApplyingRemote is true the write came from applying a remote pull or from
        // routine touch:false launch housekeeping, NOT a user edit, so it must not arm a push. Without this,
        // the receiving device's syncDown re-arms hasPendingPush (self-echo) and starves its own pull guard,
        // so peer settings never apply (the Beta 8/9 settings-sync regression). The notification is delivered
        // on the main queue, so reading the @MainActor flag here is safe.
        // Seed the LOCAL-WINS differ baseline from the current domain BEFORE the observer is armed, so the first
        // real user edit diffs against a true snapshot rather than an empty one (which would mark every existing
        // key dirty). Refreshed after every remote-apply / housekeeping window (see withRemoteApplySuppressed).
        refreshSettingsShadow()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Stay in this main-queue delivery turn: a second Task could outlive suppression.
                self?.observeDefaultsChange()
            }
        }
        // T-2: give TraktAuth a cross-device lookup for the refresh-401 recovery path. When a refresh 401s
        // because a SIBLING device already rotated the (shared) refresh token, TraktAuth consults the freshest
        // synced doc.apiKeys mirror here and re-adopts that token instead of signing this device out.
        Task { @MainActor in
            await TraktAuth.shared.setSyncedTokenProvider {
                let capture = CredentialScopeRegistry.shared.capture()
                return await VortXSyncManager.shared.syncedTraktCredentials(credentialCapture: capture)
            }
        }
    }

    /// A credential lookup does not decide backup ownership or seed an empty account. Keep the untyped
    /// decrypted document on its main owner and return only the tuple under the original ingress capture.
    private func syncedTraktCredentials(
        credentialCapture capture: CredentialScopeRegistry.Capture
    ) async -> (access: String, refresh: String, expiryUnix: Int)? {
        guard isCurrent(capture),
              let document = await pullCredentialLookupDocument(credentialCapture: capture),
              isCurrent(capture),
              let keys = document["apiKeys"] as? [String: String],
              let access = keys["traktAccess"], let refresh = keys["traktRefresh"],
              !access.isEmpty, !refresh.isEmpty else { return nil }
        return (access, refresh, Int(keys["traktExpiry"] ?? "") ?? 0)
    }

    // MARK: - Keychain persistence

    private struct Persisted: Codable, Sendable { let token: String; let account: Account; let dataKey: String }

    private func cancelCredentialOwnerRetry() {
        credentialOwnerRetryTask?.cancel()
        credentialOwnerRetryTask = nil
        credentialOwnerRetryFence = nil
    }

    private func currentCredentialOwnerIntent() -> AuthOperationCapture {
        AuthOperationCapture(
            generation: authOperationGeneration,
            credential: credentialAuthority.capture())
    }

    /// Every new user auth intent supersedes a pending init restore or sign-out retry before it can acquire
    /// the owner boundary. The generation is checked before every retry and again before protected state apply.
    private func beginCredentialOwnerIntent() -> AuthOperationCapture {
        authOperationGeneration &+= 1
        cancelCredentialOwnerRetry()
        return currentCredentialOwnerIntent()
    }

    private func beginAuthOperation() -> AuthOperationCapture {
        beginCredentialOwnerIntent()
    }

    private func isCurrent(_ operation: AuthOperationCapture) -> Bool {
        operation.generation == authOperationGeneration
            && credentialAuthority.isCurrent(operation.credential)
    }

    private func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool {
        credentialAuthority.isCurrent(capture)
    }

    private func logCredentialOwnerAcquisitionDenied(_ operation: String, attempt: Int) {
        NSLog(
            "[credentials] %@ owner acquisition denied (attempt %d/%d)",
            operation,
            attempt,
            credentialOwnerMaximumAttempts)
    }

    private func logCredentialOwnerAcquisitionExhausted(_ operation: String) {
        NSLog(
            "[credentials] %@ owner acquisition exhausted after %d attempts",
            operation,
            credentialOwnerMaximumAttempts)
    }

    private func logCredentialOwnerRetryDropped(_ operation: String) {
        NSLog("[credentials] %@ owner acquisition retry cancelled or superseded", operation)
    }

    private func logSignOutCompletionDenied(attempt: Int) {
        NSLog(
            "[credentials] sign-out owner or durable session deletion denied (attempt %d/%d)",
            attempt,
            credentialOwnerMaximumAttempts)
    }

    private func logSignOutCompletionExhausted() {
        NSLog(
            "[credentials] sign-out did not reach durable completion after %d attempts",
            credentialOwnerMaximumAttempts)
    }

    private func waitForCredentialOwnerRetry(
        operation: String,
        fence: AuthOperationCapture
    ) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: credentialOwnerRetryNanos)
        } catch {
            return false
        }
        return isCurrent(fence) && !Task.isCancelled
    }

    private func waitForSignOutCompletionRetry(fence: AuthOperationCapture) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: credentialOwnerRetryNanos)
        } catch {
            return false
        }
        return isCurrent(fence) && !Task.isCancelled
    }

    /// Retry only by suspension. The main actor never blocks or spins, and a newer auth generation or owner
    /// capture drops this exact intent before it can mutate a dependent store or session field.
    private func acquireCredentialOwner(
        scope: CredentialScope,
        operation: String,
        fence: AuthOperationCapture,
        certifying: @escaping @MainActor () -> CredentialMutationResult = { .success },
        startingAt firstAttempt: Int = 1,
        delayBeforeFirstAttempt: Bool = false
    ) async -> CredentialScopeRegistry.Capture? {
        guard firstAttempt >= 1, firstAttempt <= credentialOwnerMaximumAttempts else { return nil }
        let outcome = await CredentialRetryCoordinator.acquireOwner(
            attempts: firstAttempt...credentialOwnerMaximumAttempts,
            delayBeforeFirstAttempt: delayBeforeFirstAttempt,
            isCurrent: { [weak self] in self?.isCurrent(fence) == true },
            tryAcquire: { [weak self] _ in self?.bindCredentialOwner(scope, certifying: certifying) },
            denied: { [weak self] attempt in
                self?.logCredentialOwnerAcquisitionDenied(operation, attempt: attempt)
            },
            exhausted: { [weak self] in
                self?.logCredentialOwnerAcquisitionExhausted(operation)
            },
            dropped: { [weak self] in
                self?.logCredentialOwnerRetryDropped(operation)
            },
            sleepBeforeRetry: { [weak self] in
                guard let self else { return false }
                return await self.waitForCredentialOwnerRetry(operation: operation, fence: fence)
            })
        switch outcome {
        case let .acquired(capture):
            return capture
        case .exhausted, .superseded:
            return nil
        }
    }

    /// Linearize the owner transition before publishing account state. Legacy claims happen only after the
    /// session layer has established that this capture belongs to an authenticated VortX account.
    @discardableResult
    private func bindCredentialOwner(_ scope: CredentialScope) -> CredentialScopeRegistry.Capture? {
        // A busy publication boundary is a hard composition failure. Do not let any dependent store, source
        // index, or session field observe a partial owner transition; the caller leaves all of them untouched.
        guard let capture = credentialAuthority.tryBind(scope) else { return nil }
        nativeProfileEditConflicts = []
        nativeAddonEditConflicts = []
        nativeOwnAccountResyncUnavailable = []
        nativeOwnAccountOverlayPending = []
        retireNativeWatchedPendingProjection()
        nativeWatchedMigrationPending = []
        nativeUnsupportedSettings = []; nativeLegacyWatchlistPending = []
        nativeOwnAccountOverlayUnattributed = []
        if case .account = scope { CoreBridge.excludeAccountHistoryFromGuestRecommendations() }
        cancelProviderLegacyMigration(except: capture)
        ApiKeys.shared.bind(owner: scope)
        DebridKeys.shared.bind(owner: scope)
        OwnerResumeStore.bind(ownerID: scope.keychainOwnerID)
        OwnerHistoryStore.bind(ownerID: scope.keychainOwnerID)
        OwnerWatchedIntentStore.bind(ownerID: scope.keychainOwnerID)
        NotificationCenter.default.post(
            name: Self.credentialScopeDidChangeNote,
            object: nil,
            userInfo: ["generation": capture.generation])
        return capture
    }

    /// The interactive adoption path certifies its complete session record while the owner publication
    /// boundary is held. A failed write leaves the previous scope and every dependent store untouched.
    @discardableResult
    private func bindCredentialOwner(
        _ scope: CredentialScope,
        certifying: @MainActor () -> CredentialMutationResult
    ) -> CredentialScopeRegistry.Capture? {
        guard let capture = credentialAuthority.tryBind(scope, certifying: certifying) else { return nil }
        nativeProfileEditConflicts = []
        nativeAddonEditConflicts = []
        nativeOwnAccountResyncUnavailable = []
        nativeOwnAccountOverlayPending = []
        retireNativeWatchedPendingProjection()
        nativeWatchedMigrationPending = []
        nativeUnsupportedSettings = []; nativeLegacyWatchlistPending = []
        nativeOwnAccountOverlayUnattributed = []
        if case .account = scope { CoreBridge.excludeAccountHistoryFromGuestRecommendations() }
        cancelProviderLegacyMigration(except: capture)
        ApiKeys.shared.bind(owner: scope)
        DebridKeys.shared.bind(owner: scope)
        OwnerResumeStore.bind(ownerID: scope.keychainOwnerID)
        OwnerHistoryStore.bind(ownerID: scope.keychainOwnerID)
        OwnerWatchedIntentStore.bind(ownerID: scope.keychainOwnerID)
        NotificationCenter.default.post(
            name: Self.credentialScopeDidChangeNote,
            object: nil,
            userInfo: ["generation": capture.generation])
        return capture
    }

    private struct RestoredSessionIntent: Sendable {
        let persisted: Persisted
        let dataKey: Data
        let scope: CredentialScope
    }

    private func finishCredentialOwnerRetry(_ fence: AuthOperationCapture) {
        guard credentialOwnerRetryFence == fence else { return }
        credentialOwnerRetryTask = nil
        credentialOwnerRetryFence = nil
    }

    /// Apply the retained, already-certified Keychain payload only after the exact retry fence acquired the
    /// owner generation. This is the sole restore mutation point for both the init attempt and later retries.
    @discardableResult
    private func completeRestoredSession(
        _ intent: RestoredSessionIntent,
        capture: CredentialScopeRegistry.Capture,
        fence: AuthOperationCapture
    ) -> Bool {
        guard fence.generation == authOperationGeneration,
              capture.scope == intent.scope,
              isCurrent(capture) else { return false }
        guard establishCredentialOwner(capture) else { return false }
        SourceIndexLifecycleScope.shared.sessionWillMutate()
        token = intent.persisted.token
        account = intent.persisted.account
        dataKey = intent.dataKey
        isSignedIn = true
        reloadLastSyncStamp()
        // `restore()` can now finish from a retry task after init. Always hop once before opening realtime so
        // singleton construction is complete; startRealtime remains idempotent for the immediate-success path.
        Task { @MainActor [weak self] in self?.startRealtime() }
        return true
    }

    private func scheduleRestoreCredentialOwnerRetry(
        _ intent: RestoredSessionIntent,
        fence: AuthOperationCapture,
        startingAt firstAttempt: Int
    ) {
        cancelCredentialOwnerRetry()
        credentialOwnerRetryFence = fence
        let task = CredentialRetryCoordinator.launch { [weak self] in
            guard let self else { return }
            guard let capture = await self.acquireCredentialOwner(
                scope: intent.scope,
                operation: "restore",
                fence: fence,
                startingAt: firstAttempt,
                delayBeforeFirstAttempt: true
            ) else {
                self.finishCredentialOwnerRetry(fence)
                return
            }
            guard self.credentialOwnerRetryFence == fence else { return }
            guard self.completeRestoredSession(intent, capture: capture, fence: fence) else {
                self.finishCredentialOwnerRetry(fence)
                return
            }
            self.finishCredentialOwnerRetry(fence)
        }
        credentialOwnerRetryTask = task
    }

    /// This is the sole published sign-out mutation point. The persisted session is deleted while the exact
    /// pre-sign-out owner capture remains current. A failed delete or later busy owner bind leaves every live
    /// store and session field untouched, and the same retained fence retries the idempotent transaction.
    @discardableResult
    private func completeSignOut(fence: AuthOperationCapture) -> Bool {
        CredentialSignOutCoordinator.complete(
            isPreSignOutCurrent: { self.isCurrent(fence) },
            deletePersistedSession: { Keychain.set(nil, for: self.kcAccount) },
            bindSignedOutOwner: {
                self.bindCredentialOwner(.signedOutDevice) != nil
            },
            publishSignedOutState: {
                SourceIndexLifecycleScope.shared.sessionWillMutate()
                self.stopRealtime()
                self.restoreTask?.cancel()
                self.restoreTask = nil
                self.restoreTaskCapture = nil
                self.accountRestoreState = .idle
                self.token = nil
                self.account = nil
                self.dataKey = nil
                self.isSignedIn = false
                self.lastSyncAt = nil
                self.backupUploadFailure = nil
            })
    }

    private func scheduleSignOutCredentialOwnerRetry(
        fence: AuthOperationCapture,
        startingAt firstAttempt: Int
    ) {
        cancelCredentialOwnerRetry()
        credentialOwnerRetryFence = fence
        let task = CredentialRetryCoordinator.launch { [weak self] in
            guard let self else { return }
            _ = await CredentialRetryCoordinator.acquireOwner(
                attempts: firstAttempt...self.credentialOwnerMaximumAttempts,
                delayBeforeFirstAttempt: true,
                isCurrent: { [weak self] in
                    self?.isCurrent(fence) == true
                },
                tryAcquire: { [weak self] _ -> Bool? in
                    guard let self else { return nil }
                    return self.completeSignOut(fence: fence) ? true : nil
                },
                denied: { [weak self] attempt in
                    self?.logSignOutCompletionDenied(attempt: attempt)
                },
                exhausted: { [weak self] in
                    self?.logSignOutCompletionExhausted()
                },
                dropped: { [weak self] in
                    self?.logCredentialOwnerRetryDropped("sign-out")
                },
                sleepBeforeRetry: { [weak self] in
                    guard let self else { return false }
                    return await self.waitForSignOutCompletionRetry(fence: fence)
                })
            self.finishCredentialOwnerRetry(fence)
        }
        credentialOwnerRetryTask = task
    }

    /// Only a confirmed absence or a destination-complete raw claim may proceed for that provider. A failed
    /// claim remains independently retryable and cannot delay the other provider's successful finalization.
    private func providerClaimSucceeded(_ result: CredentialLegacyClaim.Result) -> Bool {
        switch result {
        case .noSource, .targetPresent, .migrated:
            return true
        case .durableReadFailed, .claimWriteFailed, .claimConflict, .claimedByOtherOwner,
             .sourceLostAfterClaim, .sourceDeleteFailed, .targetReadbackMismatch:
            return false
        }
    }

    /// A provider with no legacy source has no session to finalize. A claimed or already-present owner tuple
    /// must still traverse the actor's explicit finalization boundary before passive reads may expose it.
    private func providerClaimNeedsFinalization(_ result: CredentialLegacyClaim.Result) -> Bool {
        switch result {
        case .targetPresent, .migrated:
            return true
        case .noSource, .durableReadFailed, .claimWriteFailed, .claimConflict, .claimedByOtherOwner,
             .sourceLostAfterClaim, .sourceDeleteFailed, .targetReadbackMismatch:
            return false
        }
    }

    /// A capture is a generation fence, not simply an account identifier. Clearing the task on a successful
    /// bind both cancels work immediately and prevents an old completion from clearing a newer task's state.
    private func cancelProviderLegacyMigration(except capture: CredentialScopeRegistry.Capture? = nil) {
        if pendingProviderApply?.capture != capture {
            pendingProviderApply = nil
        }
        guard providerLegacyMigrationCapture != capture else { return }
        providerLegacyMigrationGeneration &+= 1
        providerLegacyMigrationTask?.cancel()
        providerLegacyMigrationTask = nil
        providerLegacyMigrationCapture = nil
    }

    private func waitForProviderLegacyMigrationRetry() async -> Bool {
        do {
            try await Task.sleep(nanoseconds: providerLegacyMigrationRetryNanos)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func waitForProviderRemoteApplyRetry(
        capture: CredentialScopeRegistry.Capture
    ) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: providerRemoteApplyRetryNanos)
        } catch {
            return false
        }
        return isCurrent(capture) && !Task.isCancelled
    }

    /// Retry each provider's raw claim and actor finalization independently under one owner capture. Retrying
    /// a claim can finish a source-delete or certification failure on the next turn; once one provider has
    /// finalized, its completion is retained while only the unfinished provider consumes later attempts.
    private func runProviderLegacyMigration(
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async -> Bool {
        let outcome = await CredentialRetryCoordinator.finalizeProviders(
            maximumAttempts: providerLegacyMigrationMaximumAttempts,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.isCurrent(capture)
                    && self.credentialAuthority.isMigrationEligible(capture)
            },
            firstClaim: {
                TraktTokenSlots.claimLegacyGlobal(owner: capture.scope, capture: capture)
            },
            firstClaimSucceeded: { [weak self] in self?.providerClaimSucceeded($0) == true },
            firstNeedsFinalization: { [weak self] in self?.providerClaimNeedsFinalization($0) == true },
            firstFinalize: {
                await TraktAuth.shared.finalizeLegacyMigration(ownerCapture: capture) == .success
            },
            secondClaim: {
                SIMKLTokenSlots.claimLegacyGlobal(owner: capture.scope, capture: capture)
            },
            secondClaimSucceeded: { [weak self] in self?.providerClaimSucceeded($0) == true },
            secondNeedsFinalization: { [weak self] in self?.providerClaimNeedsFinalization($0) == true },
            secondFinalize: {
                await SIMKLAuth.shared.finalizeLegacyMigration(ownerCapture: capture) == .success
            },
            sleepBeforeRetry: { [weak self] in
                guard let self else { return false }
                return await self.waitForProviderLegacyMigrationRetry()
            })
        return outcome.completed
    }

    /// Restore and adopt both finish their state transition on the main actor. Retain provider finalization in
    /// a named task instead of launching a detached best-effort call. Every false result is retried boundedly;
    /// an exhausted current capture is logged so a later authenticated boundary can retry it.
    private func scheduleProviderLegacyMigration(ownerCapture capture: CredentialScopeRegistry.Capture) {
        guard isCurrent(capture), credentialAuthority.isMigrationEligible(capture) else { return }
        if providerLegacyMigrationCapture == capture, providerLegacyMigrationTask != nil { return }
        cancelProviderLegacyMigration()
        providerLegacyMigrationCapture = capture
        providerLegacyMigrationGeneration &+= 1
        let taskGeneration = providerLegacyMigrationGeneration
        let task = CredentialRetryCoordinator.launch { [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.providerLegacyMigrationGeneration == taskGeneration,
                  self.providerLegacyMigrationCapture == capture else { return false }
            let completed = await self.runProviderLegacyMigration(ownerCapture: capture)
            guard self.providerLegacyMigrationGeneration == taskGeneration,
                  self.providerLegacyMigrationCapture == capture else { return false }
            self.providerLegacyMigrationTask = nil
            self.providerLegacyMigrationCapture = nil
            if !completed, self.isCurrent(capture) {
                NSLog("[credentials] provider legacy migration did not finalize after %d attempts", self.providerLegacyMigrationMaximumAttempts)
            }
            return completed
        }
        providerLegacyMigrationTask = task
    }

    /// Consume legacy provider slots only at an authenticated session boundary. A namespace bind alone is not
    /// proof of account ownership: signed-out binds and unproven first-account binds must leave the global
    /// migration opportunity untouched. The raw claims and their actor finalization are fenced from this
    /// main-actor `adopt`/`restore` boundary by the captured task above.
    @discardableResult
    private func establishCredentialOwner(_ capture: CredentialScopeRegistry.Capture) -> Bool {
        guard let established = credentialAuthority.establishAuthenticatedOwner(capture),
              case .account = established.scope else { return false }
        NotificationCenter.default.post(
            name: Self.credentialScopeDidChangeNote,
            object: nil,
            userInfo: ["generation": established.generation])
        let owner = established.scope
        withRemoteApplySuppressed {
            AddonOwnerStorage.migrateLegacy(namespace: established.namespace,
                authenticated: credentialAuthority.isMigrationEligible(established))
        }
        _ = ApiKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)
        _ = DebridKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)
        guard isCurrent(established) else { return false }
        scheduleProviderLegacyMigration(ownerCapture: established)
        return true
    }

    private func persist(
        token: String,
        account: Account,
        dataKey: Data
    ) -> CredentialMutationResult {
        guard let data = try? JSONEncoder().encode(
            Persisted(token: token, account: account, dataKey: dataKey.base64EncodedString())),
              let str = String(data: data, encoding: .utf8) else { return .failure }
        return Keychain.set(str, for: kcAccount)
    }

    @discardableResult
    private func persist() -> CredentialMutationResult {
        guard let token, let account, let dataKey else { return .failure }
        return persist(token: token, account: account, dataKey: dataKey)
    }

    private func restore() {
        let persisted: String
        switch Keychain.confirmedString(kcAccount) {
        case .failure:
            return
        case .missing:
            return
        case let .value(value):
            persisted = value
        }
        guard let data = persisted.data(using: .utf8),
              let p = try? JSONDecoder().decode(Persisted.self, from: data),
              let dk = Data(base64Encoded: p.dataKey),
              let scope = CredentialScope(canonicalRemoteAccountID: p.account.id),
              !p.token.isEmpty else {
            // An invalid persisted owner cannot safely select a credential namespace. Drop only this
            // unusable VortX session; leave unrelated signed-out provider state untouched.
            _ = Keychain.set(nil, for: kcAccount)
            return
        }
        let intent = RestoredSessionIntent(persisted: p, dataKey: dk, scope: scope)
        let fence = currentCredentialOwnerIntent()
        if let boundCapture = bindCredentialOwner(scope),
           completeRestoredSession(intent, capture: boundCapture, fence: fence) {
            return
        }
        logCredentialOwnerAcquisitionDenied("restore", attempt: 1)
        scheduleRestoreCredentialOwnerRetry(intent, fence: fence, startingAt: 2)
    }

    func signOut() {
        let fence = beginCredentialOwnerIntent()
        if completeSignOut(fence: fence) {
            return
        }
        logSignOutCompletionDenied(attempt: 1)
        scheduleSignOutCredentialOwnerRetry(fence: fence, startingAt: 2)
    }

    // MARK: - HTTP

    private func request(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        auth: Bool = false,
        bearer: String? = nil,
        credentialCapture: CredentialScopeRegistry.Capture? = nil,
        ifNoneMatch: Int? = nil,
        receiveETag: ((String?) -> Void)? = nil
    ) async -> (Int, [String: Any]?) {
        if let credentialCapture, !isCurrent(credentialCapture) { return (0, nil) }
        guard let url = URL(string: base + path) else { return (0, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let ifNoneMatch, method == "GET", path == "/v1/backup" {
            req.setValue("\"\(ifNoneMatch)\"", forHTTPHeaderField: "If-None-Match")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        // `bearer` is a one-off token override (the QR joiner calls /me with the freshly issued session
        // token BEFORE it is adopted); otherwise `auth` uses the stored session token.
        if let t = bearer ?? (auth ? token : nil) { req.setValue("Bearer " + t, forHTTPHeaderField: "authorization") }
        // Only the exact encrypted account snapshot endpoint needs the bounded 8 MiB allowance. Auth,
        // recovery, QR, and /me control envelopes stay under the transport's 64 KiB control cap.
        let maxResponseBytes = path == "/v1/backup"
            ? AuthenticatedHTTPTransport.snapshotResponseLimit
            : AuthenticatedHTTPTransport.controlResponseLimit
        do {
            let response = try await AuthenticatedHTTPTransport.shared.send(
                req,
                allowedHosts: ["api.vortx.tv"],
                maxResponseBytes: maxResponseBytes
            )
            if let credentialCapture, !isCurrent(credentialCapture) { return (0, nil) }
            receiveETag?(response.etag)
            if response.statusCode == 304 { return response.data.isEmpty ? (304, nil) : (0, nil) }
            let json = (try? AuthenticatedHTTPTransport.jsonObject(from: response.data)) as? [String: Any]
            return (response.statusCode, json)
        } catch { return (0, nil) }
    }

    @discardableResult
    private func adopt(
        token: String,
        account acct: [String: Any],
        dataKey: Data,
        expectedOperation: AuthOperationCapture? = nil
    ) async -> Bool {
        let operation = expectedOperation ?? currentCredentialOwnerIntent()
        guard isCurrent(operation) else { return false }
        guard !token.isEmpty,
              let id = acct["id"] as? String,
              let scope = CredentialScope(canonicalRemoteAccountID: id),
              let email = acct["email"] as? String,
              let username = acct["username"] as? String else { return false }
        let candidateAccount = Account(
            id: id,
            email: email,
            username: username,
            twoFactorEnabled: acct["twoFactorEnabled"] as? Bool ?? false)
        guard let adoptedCapture = await acquireCredentialOwner(
            scope: scope,
            operation: "adopt",
            fence: operation,
            certifying: {
                self.persist(token: token, account: candidateAccount, dataKey: dataKey)
            }
        ) else { return false }
        guard operation.generation == authOperationGeneration,
              isCurrent(adoptedCapture) else { return false }
        guard establishCredentialOwner(adoptedCapture) else { return false }
        SourceIndexLifecycleScope.shared.sessionWillMutate()
        self.token = token
        self.dataKey = dataKey
        self.account = candidateAccount
        self.accountRestoreState = .restoring
        self.isSignedIn = true
        reloadLastSyncStamp()   // a re-sign-in to a known account restores its persisted "last synced"
        // A fresh sign-in is a foreground action, so open the real-time channel immediately (if the app
        // is active it would also be opened by scenePhase, but adopting here covers the in-place sign-in
        // flow where the scene never re-activates). Even same-account re-sign-in replaces the bearer.
        stopRealtime()
        startRealtime()
        // ONE interactive sign-in must restore everything: hydrate the engine from the account's owned
        // add-ons + recover the owner library HERE, at the single chokepoint every sign-in entry point
        // funnels through (password, create, recover, QR joiner), instead of waiting for a background/
        // foreground cycle to re-run the degraded-engine check. Hydration remains an owned async kick because
        // it is network-bound. Cannot zero anything by construction: hydrate acts
        // only on a real .doc pull (.failed/.empty do nothing), add-on installs are an install-only
        // union, and owner-library recovery requires the engine to have POSITIVELY reported an empty
        // account library first (see hydrateEngineFromOwnedAddons / recoverOwnerLibraryIfEmpty).
        //
        // #145 M1: RESTORE BEFORE HYDRATE, and kick it here rather than relying on startRealtime() above, which
        // is idempotent and no-ops when the channel is already live (a re-sign-in without a sign-out), leaving
        // its restore kick unfired. Ordering: hydrate installs add-ons into the engine, which writes UserDefaults
        // and arms a push, so restoring first means the account's doc is applied before anything can try to push
        // over it. Both are single-flight / idempotent, so overlapping with startRealtime's kick is a no-op.
        Task {
            guard self.isCurrent(adoptedCapture) else { return }
            _ = await self.restoreAccountDocIfNeeded(credentialCapture: adoptedCapture)
            guard self.isCurrent(adoptedCapture) else { return }
            await self.hydrateEngineFromOwnedAddons(credentialCapture: adoptedCapture)
        }
        // Reconciliation is decided by the UI after sign-in (reconcileAfterSignIn), so a sign-in never
        // blindly overwrites either side. A new account just gets seeded.
        return true
    }

    enum AuthResult: Equatable { case ok, totpRequired, failed(String) }

    // MARK: - Flows

    func register(email: String, username: String, password: String) async -> (result: AuthResult, recoveryCode: String?) {
        let operation = beginAuthOperation()
        guard let kdfSalt = VortXSecureEntropy.randomBytes(16),
              let dataKey = VortXSecureEntropy.randomBytes(32),
              let recoveryCode = VortXSecureEntropy.makeRecoveryCode() else {
            return (.failed("Could not create secure encryption keys. Try again."), nil)
        }
        let iters = VortXSyncCrypto.defaultIters
        let masterKey = VortXSyncCrypto.masterKey(password: password, kdfSalt: kdfSalt, iters: iters)
        let recoveryKey = VortXSyncCrypto.recoveryKey(recoveryCode: recoveryCode, kdfSalt: kdfSalt, iters: iters)
        guard let wrappedPw = VortXSyncCrypto.seal(key: masterKey, dataKey),
              let wrappedRec = VortXSyncCrypto.seal(key: recoveryKey, dataKey) else {
            return (.failed("Could not set up encryption."), nil)
        }
        let body: [String: Any] = [
            "email": email, "username": username,
            "kdfSalt": kdfSalt.base64EncodedString(), "kdfIters": iters,
            "authVerifier": VortXSyncCrypto.authVerifier(masterKey: masterKey, password: password),
            "wrappedKeyPassword": wrappedPw, "wrappedKeyRecovery": wrappedRec,
            "recVerifier": VortXSyncCrypto.recVerifier(recoveryKey: recoveryKey, recoveryCode: recoveryCode),
            // Sent ONLY so the worker can put it in the welcome email; it is never stored server-side
            // (index.ts marks it "NEVER written to the DB"), and the website register sends it the same way.
            // Without this the welcome email falls back to a generic "save your code" note (the regression).
            "recoveryCode": recoveryCode,
        ]
        let (code, json) = await request(
            "POST", "/v1/auth/register", body: body,
            credentialCapture: operation.credential
        )
        guard isCurrent(operation) else { return (.failed("Sign-in was superseded."), nil) }
        if code == 200, let token = json?["token"] as? String, let acct = json?["account"] as? [String: Any] {
            guard await adopt(token: token, account: acct, dataKey: dataKey, expectedOperation: operation) else {
                return (.failed("Could not create the account."), nil)
            }
            return (.ok, recoveryCode)
        }
        switch json?["error"] as? String {
        case "email_taken": return (.failed("That email is already registered."), nil)
        case "username_taken": return (.failed("That username is taken."), nil)
        default: return (.failed("Could not create the account."), nil)
        }
    }

    func signIn(login: String, password: String, totp: String? = nil) async -> AuthResult {
        let operation = beginAuthOperation()
        let (_, pre) = await request(
            "POST", "/v1/auth/prelogin", body: ["login": login],
            credentialCapture: operation.credential
        )
        guard isCurrent(operation) else { return .failed("Sign-in was superseded.") }
        guard let saltStr = pre?["kdfSalt"] as? String, let salt = Data(base64Encoded: saltStr),
              let iters = pre?["kdfIters"] as? Int else { return .failed("Could not reach VortX. Try again.") }
        // Reject a downgraded work factor from the UNAUTHENTICATED prelogin response before deriving the key.
        guard iters >= VortXSyncCrypto.minIters else { return .failed("Could not verify VortX security parameters. Try again.") }
        let masterKey = VortXSyncCrypto.masterKey(password: password, kdfSalt: salt, iters: iters)
        var body: [String: Any] = ["login": login, "authVerifier": VortXSyncCrypto.authVerifier(masterKey: masterKey, password: password)]
        if let totp, !totp.isEmpty { body["totp"] = totp }
        let (code, json) = await request(
            "POST", "/v1/auth/login", body: body,
            credentialCapture: operation.credential
        )
        guard isCurrent(operation) else { return .failed("Sign-in was superseded.") }
        if code == 401, (json?["error"] as? String) == "totp_required" { return .totpRequired }
        guard code == 200, let token = json?["token"] as? String, let acct = json?["account"] as? [String: Any],
              let wrappedPw = json?["wrappedKeyPassword"] as? String,
              let dk = VortXSyncCrypto.open(key: masterKey, wrappedPw) else {
            return .failed(code == 401 ? "Wrong login or password." : "Could not sign in.")
        }
        guard await adopt(token: token, account: acct, dataKey: dk, expectedOperation: operation) else {
            return .failed("Could not sign in.")
        }
        return .ok
    }

    func recover(email: String, recoveryCode: String, newPassword: String) async -> AuthResult {
        let operation = beginAuthOperation()
        let trimmed = recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, start) = await request(
            "POST", "/v1/auth/recover-start", body: ["email": email],
            credentialCapture: operation.credential
        )
        guard isCurrent(operation) else { return .failed("Recovery was superseded.") }
        guard let saltStr = start?["kdfSalt"] as? String, let salt = Data(base64Encoded: saltStr),
              let iters = start?["kdfIters"] as? Int, let wrappedRec = start?["wrappedKeyRecovery"] as? String else {
            return .failed("No recovery is set up for that email.")
        }
        // Same downgrade guard as signIn: recover-start is unauthenticated too.
        guard iters >= VortXSyncCrypto.minIters else { return .failed("Could not verify VortX security parameters. Try again.") }
        let recoveryKey = VortXSyncCrypto.recoveryKey(recoveryCode: trimmed, kdfSalt: salt, iters: iters)
        guard let dk = VortXSyncCrypto.open(key: recoveryKey, wrappedRec) else { return .failed("That recovery code is not correct.") }
        // Keep the existing kdfSalt (it also derives the recovery key); derive the new master from it.
        let newMaster = VortXSyncCrypto.masterKey(password: newPassword, kdfSalt: salt, iters: iters)
        guard let wrappedPw = VortXSyncCrypto.seal(key: newMaster, dk) else { return .failed("Could not re-encrypt.") }
        let body: [String: Any] = [
            "email": email,
            "recVerifier": VortXSyncCrypto.recVerifier(recoveryKey: recoveryKey, recoveryCode: trimmed),
            "newAuthVerifier": VortXSyncCrypto.authVerifier(masterKey: newMaster, password: newPassword),
            "newWrappedKeyPassword": wrappedPw,
        ]
        let (code, json) = await request(
            "POST", "/v1/auth/recover-complete", body: body,
            credentialCapture: operation.credential
        )
        guard isCurrent(operation) else { return .failed("Recovery was superseded.") }
        if code == 200, let token = json?["token"] as? String, let acct = json?["account"] as? [String: Any] {
            guard await adopt(token: token, account: acct, dataKey: dk, expectedOperation: operation) else {
                return .failed("Recovery failed.")
            }
            return .ok
        }
        return .failed("Recovery failed.")
    }

    // MARK: - Encrypted sync document

    // H-1 downgrade ratchet (per account): once this account's doc has opened as v2 (or this client wrote v2),
    // a bare-legacy blob is treated as TAMPER and never opened. A legacy blob authenticates at ANY version, so
    // without this a backend could replay an archived pre-flip legacy ciphertext under a forged higher version
    // and defeat the version binding. Dormant until v2 docs exist (post-flip). Keyed by accountId.
    private static func sawDocV2(_ accountId: String) -> Bool {
        !accountId.isEmpty && UserDefaults.standard.bool(forKey: "vortx.sync.sawDocV2." + accountId)
    }
    private static func markSawDocV2(_ accountId: String) {
        guard !accountId.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: "vortx.sync.sawDocV2." + accountId)
    }
    /// Open a pulled sync document, enforcing the H-1 ratchet. Returns nil (tamper / undecryptable) rather than
    /// ever surfacing an empty doc, so a caller never clobbers the account from a refused or failed open.
    private func openSyncDocument(_ stored: String, version: Int) -> Data? {
        guard let dataKey else { return nil }
        let acctId = account?.id ?? ""
        let isV2 = stored.hasPrefix(VortXSyncCrypto.docV2Prefix)
        if !isV2, Self.sawDocV2(acctId) { return nil }             // legacy after v2 seen -> tamper
        let pt = VortXSyncCrypto.openDocument(dataKey: dataKey, stored: stored, accountId: acctId, version: version)
        if pt != nil, isV2 { Self.markSawDocV2(acctId) }           // this account is now on v2
        return pt
    }

    private static func decodeDecryptedSyncDocument(_ plaintext: Data) throws -> [String: Any] {
        // Validate original numeric lexemes, duplicate keys and Unicode before Foundation can
        // round/drop them. Those values later become authenticated per-profile overlay witnesses.
        return try VortxProfileOverlayWitness.decodeObject(json: plaintext)
    }

    /// DEPRECATED single-state pull: collapses "no backup yet", "network/server failure", and
    /// "undecryptable/ratchet-refused doc" into one nil, so a caller cannot tell a fresh account from a
    /// blip and can misroute a failure into a seed/push decision. Kept only for callers not yet migrated;
    /// everything in this type now goes through pullSyncDocResult() (tri-state .doc/.empty/.failed).
    @available(*, deprecated, message: "nil conflates 'no backup yet' with 'pull failed'; use pullSyncDocResult() (or a tri-state wrapper like accountHasSyncData/rosterConflictWithAccount) so a network blip is never misread as an empty account")
    func pullSyncDoc(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async -> [String: Any]? {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        return await pullCredentialLookupDocument(credentialCapture: capture)
    }

    /// Behavior-preserving read for credential fallback only. Unlike the strict backup/merge pull below,
    /// this does not establish a durable backup-seen floor or make a seed/push decision.
    private func pullCredentialLookupDocument(
        credentialCapture capture: CredentialScopeRegistry.Capture
    ) async -> [String: Any]? {
        guard isCurrent(capture), dataKey != nil else { return nil }
        let (code, json) = await request("GET", "/v1/backup", auth: true, credentialCapture: capture)
        guard isCurrent(capture) else { return nil }
        if code == 200 || code == 404 { Self.xperienceExportObservation.observe() }
        guard code == 200, let doc = json?["document"] as? String,
              let pt = openSyncDocument(doc, version: (json?["version"] as? Int) ?? 0) else { return nil }
        return try? Self.decodeDecryptedSyncDocument(pt)
    }

    /// Tri-state pull used by `syncUp`'s data-loss guard: distinguishes "the account has no backup yet"
    /// (safe to start from an empty doc) from "the pull failed" (must NOT push, or it clobbers the
    /// account's existing document). A non-200/non-404 response or an undecryptable document is a failure.
    private enum SyncDocPull { case doc([String: Any]); case empty; case failed }
    private static func documentVersion(_ raw: Any?) -> Int? {
        guard let value = ProfileRosterSyncPolicy.validClock(raw), value <= 9_007_199_254_740_991,
              value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    private func pullSyncDocResult(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async -> SyncDocPull {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        guard isCurrent(capture), dataKey != nil else { return .failed }
        let (code, json) = await request("GET", "/v1/backup", auth: true, credentialCapture: capture)
        guard isCurrent(capture) else { return .failed }
        if code == 200 || code == 404 { Self.xperienceExportObservation.observe() }
        if code == 404 { return .empty }                 // no backup yet
        guard code == 200 else { return .failed }        // network/server error: do not clobber
        guard let json else { return .failed }
        guard let docStr = json["document"] as? String, !docStr.isEmpty else { return .failed }
        guard let pulledVersion = Self.documentVersion(json["version"]) else { return .failed }
        // H-2: refuse an honest-label replay of a doc OLDER than what this account has already applied. syncUp
        // uses this as its merge base, so a stale base would drop newer writes made on another surface. A real
        // server only ever returns a version >= what we last stamped, so this only fires on rollback/replay.
        if pulledVersion < lastSyncedVersion { return .failed }
        guard let pt = openSyncDocument(docStr, version: pulledVersion),
              let obj = try? Self.decodeDecryptedSyncDocument(pt) else { return .failed } // undecryptable / ratchet-refused: do not clobber
        guard rememberNativeBackup(capture: capture) else { return .failed }
        return .doc(obj)
    }

    /// Pull the doc plus its server version, so the foreground pull can apply only changes that are
    /// newer than what this device already has (and not re-apply its own last push).
    ///
    /// TRI-STATE (#145 M1), mirroring pullSyncDocResult: the old single-nil return collapsed "this account has
    /// no doc yet", "the network blipped", and "the doc would not decrypt" into one value, so syncDown could not
    /// tell "nothing to restore" from "I failed to read the account" and silently returned false either way.
    /// That silent false is what let ONE unretried pull lose the reinstall race against the debounced push.
    ///  - .doc:    decrypted, ready to apply.
    ///  - .empty:  the authenticated canonical endpoint returns 404 for an absent backup.
    ///             There is nothing to restore and nothing to push over.
    ///  - .failed: we did NOT read the account. `retryable` separates a transient transport/server fault (worth
    ///             another attempt) from a deterministic decrypt/parse refusal (retrying re-fails identically).
    ///             Either way the caller must NOT treat this as an empty account.
    private enum VersionedPull {
        case doc(doc: [String: Any], version: Int, plaintext: Data, observation: UUID?)
        case ownerHistory(plaintext: Data, version: Int, observation: UUID)
        case unchanged(version: Int)
        case empty
        case failed(retryable: Bool)
    }
    private func pullDocVersionedResult(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                                        ifNoneMatch: Int? = nil) async -> VersionedPull {
        enum FailureReason: String {
            case superseded
            case dataKeyUnavailable = "data_key_unavailable"
            case conditionalResponseInvalid = "conditional_response_invalid"
            case responseInvalid = "response_invalid"
            case documentMissing = "document_missing"
            case versionInvalid = "version_invalid"
            case backupMarkerUnavailable = "backup_marker_unavailable"
        }
        func failed(_ reason: FailureReason) -> VersionedPull {
            DiagnosticsLog.log("sync", "operation=pull result=failed reason=\(reason.rawValue)")
            return .failed(retryable: false)
        }
        let capture = suppliedCapture ?? credentialAuthority.capture()
        guard isCurrent(capture) else { return failed(.superseded) }
        guard dataKey != nil else { return failed(.dataKeyUnavailable) }
        let originalKey = dataKey
        var etag: String?
        let (code, json) = await request("GET", "/v1/backup", auth: true, credentialCapture: capture,
                                         ifNoneMatch: ifNoneMatch, receiveETag: { etag = $0 })
        guard isCurrent(capture) else { return failed(.superseded) }
        if code == 304 {
            guard let ifNoneMatch, etag == "\"\(ifNoneMatch)\"" else { return failed(.conditionalResponseInvalid) }
            return .unchanged(version: ifNoneMatch)
        }
        // A newly observed source retires an older full-export witness before any mutation.
        let observation: UUID? = (code == 200 || code == 404) ? Self.xperienceExportObservation.observe() : nil
        if code == 404 { return .empty }                                  // no backup yet
        // request() returns code 0 for a thrown URLSession error (offline / DNS / TLS / timeout) and 5xx is a
        // server fault: both are transient, and both are exactly the "silently returns false" case of #145.
        guard code == 200 else {
            DiagnosticsLog.log("sync", "operation=pull result=failed httpStatus=\(code)")
            return .failed(retryable: code == 0 || code >= 500)
        }
        guard let json else { return failed(.responseInvalid) }
        guard let docStr = json["document"] as? String, !docStr.isEmpty else { return failed(.documentMissing) }
        // `version` stays `as? Int` (Swift's Int is 64-bit on every platform this app targets), so an epoch-ms
        // version is carried whole. Never narrow this to a 32-bit type: a truncated version corrupts the AAD and
        // GCM auth then fails on every Apple / web doc.
        guard let version = Self.documentVersion(json["version"]) else { return failed(.versionInvalid) }
        // A doc we cannot open is NOT an empty account. Refusing it (rather than falling through to a nil that
        // reads as "nothing there") is what keeps a decrypt-miss / ratchet refusal from being pushed over.
        guard let pt = openSyncDocument(docStr, version: version) else {
            DiagnosticsLog.log("sync", "operation=pull result=failed reason=document_authentication_or_decode")
            return .failed(retryable: false)
        }
        do {
            if try await VortxNativeOwnerHistoryIngress.shared.requiresTypedRoute(pt) {
                guard isCurrent(capture), dataKey == originalKey, let observation else { return failed(.superseded) }
                try Self.xperienceExportObservation.withCurrent(observation) {}
                guard rememberNativeBackup(capture: capture) else { return failed(.backupMarkerUnavailable) }
                return .ownerHistory(plaintext: pt, version: version, observation: observation)
            }
        } catch {
            DiagnosticsLog.log("sync", "operation=pull result=failed reason=document_authentication_or_decode")
            return .failed(retryable: false)
        }
        guard isCurrent(capture), dataKey == originalKey else { return failed(.superseded) }
        guard let obj = try? Self.decodeDecryptedSyncDocument(pt) else {
            DiagnosticsLog.log("sync", "operation=pull result=failed reason=document_authentication_or_decode")
            return .failed(retryable: false)
        }
        guard rememberNativeBackup(capture: capture) else { return failed(.backupMarkerUnavailable) }
        return .doc(doc: obj, version: version, plaintext: pt, observation: observation)
    }

    /// pullDocVersionedResult with a bounded retry on TRANSIENT faults only (#145 M1). The reinstall restore was
    /// a race between one unretried pull and a 2.5s-debounced destructive push: a single dropped packet on a
    /// device still joining Wi-Fi lost it. Deterministic refusals (undecryptable doc, no data key) are not
    /// retried because the retry re-fails identically; they stay .failed so the caller stays blocked rather than
    /// seeding over a doc it never read. Bounded and short (~1.2s worst case) so the 10s while-active poll and
    /// the foreground pull never stack up behind it.
    private func pullDocVersionedRetrying(attempts: Int = 3, credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                                          ifNoneMatch: Int? = nil) async -> VersionedPull {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        guard isCurrent(capture) else { return .failed(retryable: false) }
        var delayNanos: UInt64 = 400_000_000
        for attempt in 0..<max(1, attempts) {
            let result = await pullDocVersionedResult(credentialCapture: capture, ifNoneMatch: ifNoneMatch)
            guard isCurrent(capture) else { return .failed(retryable: false) }
            switch result {
            case .doc, .empty, .unchanged: return result
            case .ownerHistory: return result
            case .failed(let retryable):
                guard retryable, attempt < attempts - 1 else { return result }
                try? await Task.sleep(nanoseconds: delayNanos)
                guard isCurrent(capture) else { return .failed(retryable: false) }
                delayNanos *= 2
            }
        }
        return .failed(retryable: true)
    }

    /// Push a doc at an explicit version. Returns the worker's optimistic-concurrency verdict so the
    /// caller can react to a lost race, NOT a bare Bool that conflates "stored" with "rejected". The
    /// worker replies `{ accepted:true }` when the exact base comparison stored the candidate, or `{ accepted:false,
    /// version:<current stored> }` when a concurrent write already won. lastSyncedVersion advances ONLY on
    /// accepted==true: advancing it on a rejected write (the old bug) suppressed the recovery pull, so a
    /// write that LOST the race was silently dropped and the device stayed diverged.
    private enum PushOutcome { case accepted(version: Int); case rejected(storedVersion: Int?); case upgradeRequired; case error }
    private func pushSyncDocAt(_ obj: [String: Any], version: Int, baseRevision: Int?,
                               credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                               plaintextData: Data? = nil,
                               sourceIsCurrent: () -> Bool = { true }) async -> PushOutcome {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        let capturedAccountID = account?.id ?? ""
        guard isCurrent(capture), sourceIsCurrent(), !Task.isCancelled,
              SyncDocumentRevisionPolicy.next(after: baseRevision) == version,
              !hasPendingAccountDocApply(for: capture), let capturedDataKey = dataKey,
              let pt = plaintextData ?? (try? JSONSerialization.data(withJSONObject: obj)),
              let ct = VortXSyncCrypto.sealDocument(dataKey: capturedDataKey, plaintext: pt, accountId: capturedAccountID, version: version, writeV2: Self.writeSyncDocV2) else {
            DiagnosticsLog.log("sync", "upload result=blocked stage=local_preflight")
            return .error
        }
        let (code, json) = await request("PUT", "/v1/backup", body: ["document": ct, "version": version,
            "baseRevision": baseRevision.map { $0 as Any } ?? NSNull()], auth: true, credentialCapture: capture)
        guard isCurrent(capture), sourceIsCurrent(), !Task.isCancelled, dataKey == capturedDataKey,
              !hasPendingAccountDocApply(for: capture) else { return .error }
        guard code == 200 else {
            let failure = SyncBackupUploadFailure.classify(status: code, serverCode: json?["error"] as? String)
            backupUploadFailure = failure
            DiagnosticsLog.log("sync", "upload result=failed stage=transport status=\(code) reason=\(failure.diagnosticCode) plaintextBytes=\(pt.count) ciphertextBytes=\(ct.utf8.count)")
            return failure == .upgradeRequired ? .upgradeRequired : .error
        }
        // Every target needs an explicit Boolean verdict. A missing/malformed response is
        // ambiguous delivery, never permission to retire durable intent or stamp success.
        guard let verdict = json?["accepted"] as? NSNumber, CFGetTypeID(verdict) == CFBooleanGetTypeID() else {
            DiagnosticsLog.log("sync", "upload result=failed stage=verdict")
            return .error
        }
        let accepted = verdict.boolValue
        if accepted {
            guard rememberNativeBackup(capture: capture) else {
                DiagnosticsLog.log("sync", "upload result=accepted_remote_unacknowledged stage=local_backup")
                return .error
            }
            do { try acknowledgeNativeProviders(obj, capture: capture) } catch {
                DiagnosticsLog.log("sync", "upload result=accepted_remote_unacknowledged stage=provider_receipt")
                return .error
            }
            lastSyncedVersion = max(lastSyncedVersion, version)
            persistLastSyncedVersion()   // survive relaunch so the version guard stays consistent
            if Self.writeSyncDocV2 { Self.markSawDocV2(capturedAccountID) }  // H-1: account's stored doc is now v2
            backupUploadFailure = nil // Clear only after actual acceptance and local durable receipts.
            stampSyncSuccess()           // the account now holds this device's doc: "last synced" = now
            DiagnosticsLog.log("sync", "upload result=accepted plaintextBytes=\(pt.count) ciphertextBytes=\(ct.utf8.count)")
            return .accepted(version: version)
        }
        // This echo is diagnostic only; only a new authenticated read can supply another base.
        let stored = Self.documentVersion(json?["version"])
        DiagnosticsLog.log("sync", "upload result=rejected reason=concurrent_write")
        return .rejected(storedVersion: stored)
    }

    private struct DerivedSyncDoc {
        let document: [String: Any]
        let baseRevision: Int?
        let credentialCapture: CredentialScopeRegistry.Capture
        let sourceIsCurrent: () -> Bool
        // Only the typed, accepted complete-account exporter supplies this. `document`
        // remains a small host/provider ACK projection; it must never round-trip raw
        // owner-history/native slices through Foundation's numeric representation.
        var plaintextData: Data? = nil
        // Interpretation-only preference fields sliced from THAT plaintext, before the PUT.
        // Retried DerivedSyncDocs retain their own projection; never substitute current state.
        var nativePreferenceAckData: Data? = nil
        // Captured with the host edits actually submitted to the native merge. In
        // particular, later repair of an omitted key cannot acknowledge its old stamp.
        var nativeDirtySettings: [String: Double] = [:]
    }

    /// Keep each merged document together with the revision it actually read. Two writers from
    /// the same base propose the same revision, so the loser must pull and merge the winner.
    /// The relay's echoed revision cannot substitute for the base of a later rebuilt document.
    private func pushDerivedDoc(_ initial: DerivedSyncDoc, credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                                onAccepted: (DerivedSyncDoc) -> Void = { _ in },
                                rebuild: () async -> DerivedSyncDoc?) async -> Bool {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        guard isCurrent(capture), !hasPendingAccountDocApply(for: capture) else { return false }
        let maxRetries = 3
        var doc = initial
        for attempt in 0..<maxRetries {
            guard isCurrent(capture), doc.credentialCapture == capture, doc.sourceIsCurrent(),
                  !hasPendingAccountDocApply(for: capture),
                  let version = SyncDocumentRevisionPolicy.next(after: doc.baseRevision) else { return false }
            switch await pushSyncDocAt(doc.document, version: version, baseRevision: doc.baseRevision,
                                      credentialCapture: capture, plaintextData: doc.plaintextData,
                                      sourceIsCurrent: doc.sourceIsCurrent) {
            case .accepted:
                onAccepted(doc)
                return true
            case .error, .upgradeRequired:
                return false   // network / server / encode failure: do not advance, next pull reconciles
            case .rejected:
                // A concurrent write won. Re-pull, re-merge the local pending changes onto it (same merge as
                // the first attempt), and retry strictly above the winner's version. If the rebuild can no
                // longer produce a doc (e.g. the account pull now fails), abort WITHOUT advancing so the next
                // pull reconciles rather than clobbering the winner.
                guard attempt < maxRetries - 1, isCurrent(capture), !hasPendingAccountDocApply(for: capture),
                      let rebuilt = await rebuild(), isCurrent(capture), !hasPendingAccountDocApply(for: capture) else { return false }
                doc = rebuilt
            }
        }
        return false   // exhausted retries: leave lastSyncedVersion unadvanced, next pull reconciles
    }

    /// A small JSON view of local state the website dashboard can read (the binary-plist `settings`
    /// blob is opaque to a browser). Profiles let the dashboard show the family roster + the real count.
    /// `existingVortx` is the `doc["vortx"]` just pulled from the account (nil on a fresh/empty doc). It
    /// is used for the READ-SIDE UNION GUARD: a momentarily-degraded engine (no add-ons / empty library)
    /// must never SHRINK the account-owned set on push. Mirrors the existing roster-union and apiKeys
    /// read-merge guards.
    private func vortxSummary(existingVortx: [String: Any]? = nil) -> [String: Any] {
        let store = ProfileStore.shared
        let ownerWatched = OwnerWatchedIntentStore.wire(merging: existingVortx?["ownerWatched"])
        let profiles: [[String: Any]] = store.profiles.map { p in
            // pinHash is the salted SHA-256 (salt = the profile id, already here), never the raw PIN,
            // so the dashboard can verify a PIN entry by re-hashing without ever seeing the digits.
            // `settings` mirrors the per-profile app settings so the dashboard can show + manage them
            // (it writes them back via doc.profileEdits[].settings, applied by ProfileStore.applyProfileEdits).
            var settings: [String: Any] = ["avatar": p.avatar, "accent": p.accentID, "oled": p.oled, "textScale": p.textScale, "isKids": p.isKids]
            if let pb = p.playback {
                var playback: [String: Any] = ["audioLang": pb.audioLang, "subtitleLang": pb.subtitleLang,
                    "forced": pb.forcedPolicy, "subFont": pb.subFont, "subSize": pb.subSize,
                    "subColor": pb.subColor, "subBackground": pb.subBackground]
                if let s = pb.subSizeScale { playback["subSizeScale"] = s }
                if let b = pb.subBrightness { playback["subBrightness"] = b }
                if let o = pb.sourceTypeOrder { playback["sourceTypeOrder"] = o }
                if let u = pb.useAddonOrder { playback["useAddonOrder"] = u }
                if let v = pb.safetyMode { playback["safetyMode"] = v }
                if let v = pb.instantOnly { playback["instantOnly"] = v }
                if let v = pb.hideDeadTorrents { playback["hideDeadTorrents"] = v }
                if let v = pb.hdrOnly { playback["hdrOnly"] = v }
                if let v = pb.excludeAV1 { playback["excludeAV1"] = v }
                if let v = pb.excludeKeywords { playback["excludeKeywords"] = v }
                if let v = pb.includeKeywords { playback["includeKeywords"] = v }
                if let v = pb.keywordsAreRegex { playback["keywordsAreRegex"] = v }
                if let v = pb.maxResolution { playback["maxResolution"] = v }
                if let v = pb.maxFileSizeGB { playback["maxFileSizeGB"] = v }
                if let v = pb.minResolution { playback["minResolution"] = v }
                if let v = pb.hideUnknownResolution { playback["hideUnknownResolution"] = v }
                if let v = pb.preferredAudioOnly { playback["preferredAudioOnly"] = v }
                if let v = pb.preferKeywords { playback["preferKeywords"] = v }
                if let v = pb.avoidBehavior { playback["avoidBehavior"] = v }
                if let v = pb.autoPickBest { playback["autoPickBest"] = v }
                settings["playback"] = playback
            }
            return ["id": p.id.uuidString, "name": p.name, "locked": p.pin != nil, "main": p.isOwner,
                    "familyEdit": p.familyEdit, "pinHash": p.pin ?? "", "settings": settings,
                    "disabledAddons": p.disabledAddons ?? []]
        }
        // Per-profile library / Continue Watching, so the dashboard shows each profile's titles instead
        // of "no titles yet". Overlay profiles only (the owner profile's history lives in the account
        // library, not a watch overlay). The dashboard derives CW from each item's t/d progress.
        // Preserve foreign/per-profile sibling fields from the pulled document. This summary replaces the
        // whole vortx object at the caller, so rebuilding buckets from only library/removal would erase fields
        // authored by a newer client. We own only these two keys inside each live profile's bucket.
        var byProfile = existingVortx?["byProfile"] as? [String: Any] ?? [:]
        for p in store.profiles where !p.isOwner {
            let priorBucket = byProfile[p.id.uuidString] as? [String: Any] ?? [:]
            let priorRemovals: [OverlayWatchRemoval] = (priorBucket["removed"] as? [[String: Any]] ?? []).compactMap {
                guard let keys = $0["keys"] as? [String], !keys.isEmpty else { return nil }
                let stamp = ($0["removedAt"] as? Double) ?? Double(($0["removedAt"] as? Int) ?? 0)
                return stamp.isFinite && stamp > 0 ? OverlayWatchRemoval(keys: keys, removedAt: stamp) : nil
            }
            let resolved = store.watchOverlayForSync(for: p.id, merging: priorRemovals)
            let snapshot = resolved.entries
            let cache: [String: WatchEntry] = snapshot.count <= 120 ? snapshot : Dictionary(uniqueKeysWithValues:
                snapshot.sorted { $0.value.lastWatched > $1.value.lastWatched }
                    .prefix(120).map { ($0.key, $0.value) }
            )
            let removals = resolved.removals
            let library: [[String: Any]] = cache.map { (metaId, e) in
                // t/d in seconds for the dashboard; v (resume episode/movie id) + w (watched episode ids)
                // + ma/ua (per-video mark/unmark clocks, wall-clock ms) so syncDown can rebuild the FULL
                // overlay on another device, not just library membership — and so an unmark converges.
                var row: [String: Any] = ["id": metaId, "name": e.name, "type": e.type, "poster": e.poster ?? "",
                     "t": e.timeOffsetMs / 1000, "d": e.durationMs / 1000, "lastWatched": e.lastWatched,
                     "v": e.videoId ?? "", "w": e.watchedVideoIds]
                if let ma = e.markedAt, !ma.isEmpty { row["ma"] = ma }
                if let ua = e.unmarkedAt, !ua.isEmpty { row["ua"] = ua }
                return row
            }
            // DURABLE watched-history carrier, separate from the 120-row CW-rail trim above: the rail
            // bound is a RENDER bound, and sharing it with durable history silently dropped every
            // watched id below the 120 cut on fresh devices (history "disappeared"). This map carries
            // every profile entry's watched ids + clocks (bounded far higher, still doc-safe), so a
            // reinstall converges its full watched set. Rows inside `library` also carry the same data,
            // so the read side unions both.
            let durableOrder = snapshot.sorted { $0.value.lastWatched > $1.value.lastWatched }
            var watchedMap: [String: Any] = [:]
            for (metaId, e) in durableOrder
            where !e.watchedVideoIds.isEmpty || !(e.markedAt ?? [:]).isEmpty || !(e.unmarkedAt ?? [:]).isEmpty {
                guard watchedMap.count < OverlayWatchMergePolicy.durableWatchedEntryLimit else { break }
                var row: [String: Any] = ["w": e.watchedVideoIds]
                if let ma = e.markedAt, !ma.isEmpty { row["ma"] = ma }
                if let ua = e.unmarkedAt, !ua.isEmpty { row["ua"] = ua }
                watchedMap[metaId] = row
            }
            let removed: [[String: Any]] = removals.map { ["keys": $0.keys, "removedAt": $0.removedAt] }
            var bucket = priorBucket
            bucket["library"] = library
            bucket["watched"] = watchedMap
            bucket["removed"] = removed
            byProfile[p.id.uuidString] = bucket
        }
        // Playback history is deliberately separate from the owner library.  The engine manufactures
        // temporary/removed rows for an unsaved first play and initializes ordinary adds with a synthetic
        // `lastWatched`, so neither kind of native membership state may author this carrier.  Android uses
        // this fixed owner bucket too; keep all unknown sibling fields while replacing only our array.
        let ownerHistoryProfileID = "00000000-0000-0000-0000-00000000A11C"
        var ownerHistoryBucket = byProfile[ownerHistoryProfileID] as? [String: Any] ?? [:]
        let priorOwnerHistory = ownerHistoryBucket["ownerHistory"]
        if let mergedOwnerHistory = OwnerHistoryStore.wire(merging: priorOwnerHistory) {
            ownerHistoryBucket["ownerHistory"] = mergedOwnerHistory
            byProfile[ownerHistoryProfileID] = ownerHistoryBucket
        }
        // The owner/main profile's library lives in the account (not a watch overlay), so it was absent
        // from the dashboard, which only received the byProfile overlay libraries above. Emit it as
        // vortx.library from the engine's account library so the dashboard's main-profile Library is
        // populated (excluding removed/temp, which are not "in the library"). Safe here: this type is
        // @MainActor, so reading CoreBridge's @Published state is on the main actor. Enriched with
        // `lastWatched`+`videoId` (Step 4) so another device can rebuild CW resume, not just membership.
        let engineLibrary: [[String: Any]] = (CoreBridge.shared.library?.catalog ?? [])
            .filter { !($0.removed ?? false) && !($0.temp ?? false) }
            .map { item in
                ["id": item.id, "name": item.name, "type": item.type, "poster": item.poster ?? "",
                 "t": Int(item.state.timeOffset / 1000), "d": Int(item.state.duration / 1000),
                 "v": item.state.videoId ?? "", "lastWatched": item.state.lastWatched ?? ""]
            }
        // FLOOR vs MIRROR for the owner library, per the "Mirror library from Stremio" toggle. FLOOR (OFF,
        // default) = UNION the account's already-owned `doc.vortx.library` with the engine library, so a
        // Stremio removal never removes from VortX and an empty/degraded engine can never SHRINK it. This
        // toggle governs MEMBERSHIP; the per-item resume POSITION (t / d / v) is governed separately by the
        // "Mirror Continue Watching" floor below. MIRROR (ON) = REPLACE: the live Stremio set is authoritative
        // so removals propagate - but ONLY with a live Stremio session AND a non-empty engine library, so a
        // logged-out / mid-pull shrunken set can never propagate the shrink to every device (the add-on
        // guard's clobber fix; the library has no official-defaults concept, so no `!engineIsDefaultOnly`).
        var libraryByID: [String: [String: Any]] = [:]
        let mirrorReplaceLibrary = MirrorSettings.mirrorLibrary && !engineLibrary.isEmpty && CoreBridge.shared.isLoggedIn()
        if !mirrorReplaceLibrary, let prior = (existingVortx?["library"] as? [[String: Any]]) {
            for entry in prior { if let id = entry["id"] as? String, !id.isEmpty { libraryByID[id] = entry } }
        }
        // FLOOR vs MIRROR for the owner's RESUME POSITIONS, per the "Mirror Continue Watching from Stremio"
        // toggle. Read the prior doc positions into their OWN map rather than reusing `libraryByID`, because the
        // two toggles are independent categories: with "Mirror library" ON the membership map is deliberately
        // empty (REPLACE), and the CW floor must still be able to compare against VortX's owned position. This
        // map is used for POSITIONS ONLY and never re-adds prior-only membership.
        //
        // The gate is inert without a live Stremio session (see ContinueWatchingMirror.swift): the engine's
        // library bucket carries this device's own playback as well as a Stremio pull, so with no session there
        // is nothing to floor and every entry below takes the engine value exactly as it does today.
        var priorPositions: [String: [String: Any]] = [:]
        for entry in (existingVortx?["library"] as? [[String: Any]]) ?? [] {
            if let id = entry["id"] as? String, !id.isEmpty { priorPositions[id] = entry }
        }
        let stremioMayReplaceCW = MirrorSettings.stremioMayReplaceContinueWatching(
            stremioSessionLive: CoreBridge.shared.isLoggedIn())
        // Retire local-rewind exemptions the account doc has already absorbed. An id is stamped by
        // `CoreBridge.finishedWatching` and is only needed until the doc carries its zero; once the doc says
        // t == 0 (or has no entry for the title at all, in which case the floor cannot engage for it anyway)
        // the stamp is dead weight. UNCONDITIONAL, deliberately: a device that never has a live Stremio session
        // never enters the floor branch below, so a retire that only ran there would let the log grow by one id
        // per finished title forever.
        for id in LocalRewindLog.all() where Self.libSeconds(priorPositions[id]?["t"]) == 0 {
            LocalRewindLog.forget(id)
        }
        for entry in engineLibrary {
            guard let id = entry["id"] as? String else { continue }
            if let prior = libraryByID[id] {
                // CLOCK-DECIDED, atomic position resolution (cross-device CW defect): when either side
                // carries a real `lastWatched` clock, the NEWER row's t/d/v/lastWatched win together —
                // a warm device's OLDER positive engine position can no longer overwrite a NEWER remote
                // playback, a newer rewind / finish-0 propagates, and a bare re-add (no clock) can never
                // manufacture or erase a watch clock (the prior position + clock survive onto the fresh
                // metadata). With no clock on either side the legacy guards below still decide.
                let engineClock = OwnerLibraryPositionPolicy.lastWatchedMillis(entry["lastWatched"])
                let priorClock = OwnerLibraryPositionPolicy.lastWatchedMillis(prior["lastWatched"])
                if engineClock > 0 || priorClock > 0 {
                    libraryByID[id] = OwnerLibraryPositionPolicy.resolve(engine: entry, prior: prior)
                    continue
                }
            }
            // Wave 4 clobber guard (Finding 1): do NOT let a bare, progress-less engine item (t == 0 AND d == 0,
            // the signature of a freshly AddToLibrary'd title on a cold / recovered / post-import device whose
            // engine re-adds owner titles at time 0) OVERWRITE a prior doc entry that already carries a resume
            // offset. Without this, a second VortX-only device pushing 0 would destroy device A's stored progress
            // for that title across the whole account. A genuine finish / rewind keeps d > 0 (only t goes to 0),
            // so it still propagates the zero; only the "no state at all" case is preserved, merged onto the
            // fresh engine metadata (name / poster / type) so the doc keeps both the offset and current title info.
            if let prior = libraryByID[id],
               Self.libSeconds(entry["t"]) == 0, Self.libSeconds(entry["d"]) == 0,
               (Self.libSeconds(prior["t"]) > 0 || Self.libSeconds(prior["d"]) > 0) {
                var merged = entry
                merged["t"] = prior["t"]; merged["d"] = prior["d"]; merged["v"] = prior["v"]
                libraryByID[id] = merged
                continue
            }
            // The Continue Watching FLOOR. Only engages with a live Stremio session and the toggle OFF, and even
            // then only when the engine's position moves BACKWARDS from the VortX-owned one (a stale Stremio
            // copy, a title finished on an official Stremio client, a Stremio rewind). Local playback always
            // moves the position forward, so it passes through untouched; a local FINISH also zeroes it, so
            // `finishedWatching` stamps `LocalRewindLog` and the resolver lets that zero through.
            if !stremioMayReplaceCW, let prior = priorPositions[id] {
                let locallyRewound = LocalRewindLog.contains(id)
                let resolved = MirrorSettings.resolveContinueWatching(
                    engine: MirrorSettings.CWPosition(t: Double(Self.libSeconds(entry["t"])),
                                                      d: Double(Self.libSeconds(entry["d"])),
                                                      v: entry["v"] as? String),
                    owned: MirrorSettings.CWPosition(t: Double(Self.libSeconds(prior["t"])),
                                                     d: Double(Self.libSeconds(prior["d"])),
                                                     v: prior["v"] as? String),
                    mayReplace: false,
                    locallyRewound: locallyRewound)
                var merged = entry     // keep the engine's fresh name / poster / type; only the position is floored
                merged["t"] = Int(resolved.t); merged["d"] = Int(resolved.d); merged["v"] = resolved.v ?? ""
                libraryByID[id] = merged
                continue
            }
            libraryByID[id] = entry
        }
        // SUBTRACT the durable removal tombstones from the library union (the library analogue of subtracting
        // deletedAddons from the add-on union): a title the user removed must NOT come back, even if the engine
        // still briefly holds it OR a peer device's prior doc.vortx.library still carries it. Compared on the
        // same normalized id the tombstone is stored under. A legitimate re-add stamped a newer add time
        // (LibraryTombstones.forget), so `all()` returns only the effectively-removed ids and this only ever
        // drops genuinely-removed titles.
        let removedLibrary = LibraryTombstones.all()
        if !removedLibrary.isEmpty {
            for id in libraryByID.keys where removedLibrary.contains(LibraryTombstones.normalize(id)) {
                libraryByID.removeValue(forKey: id)
            }
        }
        let ownerLibrary = Array(libraryByID.values)
        // Installed add-ons, so the dashboard Add-ons page is populated AND the account can re-hydrate
        // the engine network-free. We now emit the FULL descriptor `{transportUrl, name, manifest,
        // flags}` (Step 2) instead of the old `{transportUrl, name}`: hydration needs the manifest +
        // flags to InstallAddon without a fetch. dash-ui keeps reading transportUrl/name (extra keys are
        // additive and ignored). The Stremio token never enters this; only descriptors do (they already
        // ride doc.addons + apiKeys E2E today).
        let engineAddons: [[String: Any]] = CoreBridge.shared.rawAddonDescriptorsOrdered().compactMap { raw in
            guard let url = raw["transportUrl"] as? String, !url.isEmpty else { return nil }
            var entry = raw
            // The dashboard reads `name`; lift it out of the manifest so the old summary shape is a subset.
            if entry["name"] == nil, let manifest = raw["manifest"] as? [String: Any], let n = manifest["name"] as? String {
                entry["name"] = n
            }
            return entry
        }
        // READ-SIDE GUARD on the owned add-on set. Two modes, decided per the owner's per-category
        // "Mirror add-ons from Stremio" toggle:
        //   FLOOR (toggle OFF, the default) = UNION: union the live engine descriptors with the account's
        //   already-owned `doc.vortx.addons` by transportUrl, so a Stremio removal NEVER removes from VortX
        //   and a degraded engine can never SHRINK the owned set.
        //   MIRROR (toggle ON) = REPLACE: the engine (which reflects the live Stremio set after a pull) is
        //   authoritative, so a Stremio removal propagates (adds AND removes tracked).
        // NEVER-ZERO, independent of the toggle: REPLACE only applies when the engine actually has a
        // non-empty add-on set; a degraded/empty engine falls back to UNION so a failed pull can never
        // zero the category. Engine entries win on conflict in both modes (freshest descriptor).
        // ORDER-PRESERVING merge (AIOManager-compat: the AddonCollectionSet array order = Stremio
        // priority, so sync must not scramble it). The engine collection order is authoritative and is
        // the spine; in UNION mode the VortX-doc-only add-ons (in the prior sync but not the engine)
        // append after, in their own order. The engine descriptor wins on a URL in both (freshest).
        // CLOBBER GUARD (data-loss fix): a Stremio logout / token-expiry resets the engine to the DEFAULT
        // official add-ons - a NON-EMPTY set - so "non-empty" is the wrong REPLACE signal: REPLACE would
        // overwrite the owned mirror with defaults and propagate that loss to every device. Only let
        // REPLACE (the live-Stremio-is-authoritative path) win when there IS a live Stremio session AND the
        // engine holds a genuinely user-owned set (not the official defaults). Otherwise UNION preserves the
        // owned mirror, so a logout can never shrink doc.vortx.addons to defaults.
        let engineIsDefaultOnly = engineAddons.allSatisfy { (($0["flags"] as? [String: Any])?["official"] as? Bool) == true }
        let mirrorReplaceAddons = MirrorSettings.mirrorAddons && !engineAddons.isEmpty
            && CoreBridge.shared.isLoggedIn() && !engineIsDefaultOnly
        // SUBTRACT the durable removal tombstones from the union (the add-on analogue of subtracting
        // deletedProfiles from the roster union): an add-on the user removed must NOT come back, even if
        // the engine still briefly holds it OR a peer device's prior doc.vortx.addons still carries it.
        // PROTECTED stubs (Cinemeta, Local Files) are never tombstoned, so this never drops an essential
        // default; a removable official add-on the user deleted IS dropped (#137). Compared on the same
        // normalized (trim+lowercase) transportUrl the tombstone is stored under.
        let removedAddons = AddonTombstones.all()
        var addonList: [[String: Any]] = []
        var seenAddonURLs = Set<String>()
        for entry in engineAddons {
            guard let url = entry["transportUrl"] as? String,
                  !removedAddons.contains(AddonTombstones.normalize(url)),
                  seenAddonURLs.insert(AddonTombstones.normalize(url)).inserted else { continue }
            addonList.append(entry)
        }
        if !mirrorReplaceAddons, let prior = (existingVortx?["addons"] as? [[String: Any]]) {
            for entry in prior {
                guard let url = entry["transportUrl"] as? String, !url.isEmpty,
                      !removedAddons.contains(AddonTombstones.normalize(url)),
                      seenAddonURLs.insert(AddonTombstones.normalize(url)).inserted else { continue }
                addonList.append(entry)
            }
        }

        var v: [String: Any] = ["profiles": profiles, "updatedAt": Int(Date().timeIntervalSince1970 * 1000)]
        // Match Android's lossless carrier; the dashboard summary above deliberately omits bindings.
        if let roster = ProfileRosterSnapshot.wire(store.profiles) {
            v["roster"] = roster
            v["rosterModified"] = store.rosterModified.timeIntervalSince1970
        }
        if !ownerWatched.isEmpty { v["ownerWatched"] = ownerWatched }
        if !byProfile.isEmpty { v["byProfile"] = byProfile }
        if !ownerLibrary.isEmpty { v["library"] = ownerLibrary }
        if !addonList.isEmpty {
            v["addons"] = addonList
            // addonsOwnedAt distinguishes "owns an empty set" from "never snapshotted". Set ONCE, the
            // first time a non-empty owned set is written; preserved verbatim thereafter (carried from the
            // pulled doc), so it anchors ownership age without being reset on every push.
            if let priorOwnedAt = existingVortx?["addonsOwnedAt"] {
                v["addonsOwnedAt"] = priorOwnedAt
            } else {
                v["addonsOwnedAt"] = Int(Date().timeIntervalSince1970 * 1000)
            }
        } else if let priorOwnedAt = existingVortx?["addonsOwnedAt"] {
            v["addonsOwnedAt"] = priorOwnedAt   // never lose the anchor even on an empty push
        }
        if let active = store.activeID { v["activeProfile"] = active.uuidString }
        // Durable cross-device delete tombstones (the app owns this; the dashboard only READS it). Carries
        // the set of deleted profile ids so a peer device drops them on its next union-merge instead of
        // resurrecting them. Empty set is omitted so a fresh account never writes the key.
        //
        // READ-MERGE, never rebuild-from-local (#145 M6): UNION the account's already-owned tombstones
        // (existingVortx) with the local set so a push can NEVER SHRINK the deleted-profiles set, symmetric
        // with how foldDocTombstones protects deletedLibrary / deletedAddons. `v` is built FRESH here and
        // wholesale REPLACES doc["vortx"] at the call site, so emitting only the LOCAL set silently DROPS
        // every tombstone this device has not folded: a device that never saw a peer's delete republishes a
        // doc without that tombstone, and the next peer union-merge RESURRECTS the deleted profile (with its
        // watch overlay). A device whose local set is momentarily empty (a fresh reinstall before its first
        // syncDown fold) erased the account's whole set in one push. This device may only ADD tombstones,
        // never retract one another device authored; a profile is never un-deleted (the owner is never
        // tombstoned), so the union only ever grows.
        // The owner id is dropped defensively (it is never tombstoned; a stray one would erase the account
        // owner). Ids read back out of the doc are normalized to the uppercase `uuidString` form this set is
        // keyed on (UserProfile.normalizeID), exactly as Android's buildVortx normalizes the same read, so a
        // foreign-cased id cannot fork into a second tombstone that matches no live profile. The owner id is
        // filtered AFTER normalizing, so a lowercase owner id is caught rather than slipping through.
        // Sorted so the emitted array is deterministic across pushes and byte-identical to Android's
        // buildVortx for the same set (Set iteration order is otherwise arbitrary on both platforms).
        var deleted = store.deletedProfileIDs
        if let priorDeleted = existingVortx?["deletedProfiles"] as? [String] {
            deleted.formUnion(priorDeleted.map { UserProfile.normalizeID($0) }
                .filter { $0 != UserProfile.ownerID.uuidString })
        }
        if !deleted.isEmpty { v["deletedProfiles"] = deleted.sorted() }
        // Durable cross-device add-on REMOVAL tombstones (app-authoritative, exactly like deletedProfiles;
        // the dashboard only READS it). Carries the normalized transportUrls the user removed so a peer
        // device uninstalls them on its next pull instead of re-hydrating them. Empty set is omitted.
        if !removedAddons.isEmpty { v["deletedAddons"] = Array(removedAddons) }
        // Last-writer-wins companion for the add-on tombstones above: per-url {removedAt, addedAt} stamps
        // under the same app namespace, so a peer folds a genuine reinstall's addedAt and stops re-emitting
        // (and re-uninstalling) a stale removal. Additive: the dashboard and clients that do not know the
        // field keep reading deletedAddons as before.
        let removedAddonsTs = AddonTombstones.timestampsForSync()
        if !removedAddonsTs.isEmpty { v["deletedAddonsTs"] = removedAddonsTs }
        // Durable cross-device library REMOVAL tombstones (app-authoritative, exactly like deletedAddons; the
        // dashboard only READS it). Carries the normalized ids the user removed so a peer device drops them on
        // its next pull instead of re-hydrating / recovering them. Empty set is omitted.
        if !removedLibrary.isEmpty { v["deletedLibrary"] = Array(removedLibrary) }
        // Last-writer-wins companion for the tombstones above: per-id {removedAt, addedAt} stamps under the
        // same app namespace, so a peer folds a genuine re-add's addedAt and stops re-emitting a stale removal.
        // Additive: the dashboard and clients that do not know the field keep reading deletedLibrary as before.
        let removedLibraryTs = LibraryTombstones.timestampsForSync()
        if !removedLibraryTs.isEmpty { v["deletedLibraryTs"] = removedLibraryTs }
        return LegacySyncRetention.summary(existing: existingVortx, replacement: v)
    }

    /// Decode just the profile roster out of a doc's `settings` blob (the base64 SettingsBackup
    /// envelope, whose payload is a binary-plist of the UserDefaults domain). Returns nil when the
    /// blob is absent or carries no roster key, so callers can skip the union when there is nothing
    /// to merge. Reads the same `stremiox.profiles` JSON the ProfileStore persists.
    static func decodeRoster(fromSettingsBlob blob: Any?) -> [UserProfile]? {
        guard let b64 = blob as? String, let data = Data(base64Encoded: b64),
              let domain = try? SettingsBackup.decodeDomain(from: data),
              let rosterData = domain["stremiox.profiles"] as? Data,
              let roster = try? JSONDecoder().decode([UserProfile].self, from: rosterData) else { return nil }
        return roster
    }

    static func resolveRoster(from doc: [String: Any], fullOnly: Bool = false) -> ProfileRosterSnapshot? {
        let domain = (doc["settings"] as? String).flatMap { Data(base64Encoded: $0) }
            .flatMap { try? SettingsBackup.decodeDomain(from: $0) }
        var vortx = doc["vortx"] as? [String: Any]
        if fullOnly { vortx?.removeValue(forKey: "profiles") }
        return ProfileRosterSnapshot.resolve(settingsDomain: domain, vortx: vortx)
    }

    /// Web patches are independent of the native carrier and must be consumed before we acknowledge
    /// them by publishing a fresh native mirror. The store protects newer native fields separately.
    @discardableResult
    private func applyPendingProfileEdits(_ doc: [String: Any]) -> Bool {
        guard let edits = doc["profileEdits"] as? [String: Any],
              let editedAt = ProfileRosterSyncPolicy.validClock(edits["editedAt"]),
              editedAt > lastAppliedProfileEditsAt else { return false }
        ProfileStore.shared.applyProfileEdits(edits,
            mirrorUpdatedAt: (doc["vortx"] as? [String: Any])?["updatedAt"])
        lastAppliedProfileEditsAt = editedAt
        return true
    }

    // MARK: - Profiles + settings sync (reuses the SettingsBackup serialization as the doc payload)

    /// Push this device's profiles + settings to the account. MERGES into the existing doc (preserving
    /// keys other surfaces wrote, e.g. the website's Stremio import) instead of replacing it, and carries
    /// the metadata keys explicitly because they live in the Keychain (SettingsBackup excludes them).
    ///
    /// `afterUserChoseThisDevice` is the ONE legitimate way past the restore gate below, and it exists only for
    /// the three-way conflict prompt's "Keep this device" button. That prompt is shown only after
    /// accountHasSyncData() positively READ the account's doc and the user, seeing that the account holds data,
    /// chose to overwrite it. Never pass true from an automatic or engine-driven path: #145 is precisely what
    /// happens when an unattended push decides on the user's behalf.
    @discardableResult
    func syncUp(afterUserChoseThisDevice: Bool = false) async -> Bool {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture), backupUploadFailure != .upgradeRequired else { return false }
        guard await settleNativeProviderJournal(capture: capture), isCurrent(capture) else { return false }
        guard !hasPendingAccountDocApply(for: capture) else {
            NSLog("[sync] push refused: a remote credential apply is pending certification")
            return false
        }
        // #145 M1, THE ORDERING RULE: A DEVICE THAT HAS NOT YET APPLIED THE ACCOUNT'S DOC MUST NOT PUSH OVER IT.
        // Restore first, then push. Every destructive-push path in the bug funnels through here (the debounced
        // observer push, the engine-driven pushThisDevice calls, the background push), so this one gate closes
        // all of them, and it does not depend on the restore winning a race: if the restore has not landed, the
        // push does not happen at all. It is a REFUSAL, not a deferral: the local edit is not queued for later,
        // because after the restore lands the account's state is the truth and re-pushing this device's
        // pre-restore snapshot over it is the bug. A genuine post-restore edit arms its own push as usual.
        if !hasAppliedAccountDoc, !afterUserChoseThisDevice {
            // Try to satisfy the gate right now rather than dropping the push forever: on the reinstall path
            // this is what turns "push over the account" into "restore, then push". Single-flight, so several
            // blocked pushes plus the sign-in kick await ONE restore instead of stampeding the endpoint.
            _ = await restoreAccountDocIfNeeded(credentialCapture: capture)
            guard isCurrent(capture), hasAppliedAccountDoc else {
                NSLog("[sync] push refused: this device has not applied the account's doc yet (#145 gate)")
                return false
            }
        }
        // Dirty stamps clear only after a confirmed export, unless re-edited since.
        // Native merges attach their eligible stamps to each DerivedSyncDoc so omitted
        // settings stay protected even when their local value is repaired during upload.
        // Serialize this device's derived pushes. Otherwise an older in-flight snapshot can land after
        // an acknowledged reorder. Other accounts are isolated by the credential capture and operation id.
        if activeSyncUp?.capture == capture {
            requestSyncSoon()
            return false
        }
        if activeSyncDown?.capture == capture {
            requestSyncSoon()
            return false
        }
        let operationID = UUID()
        activeSyncUp = (operationID, capture)
        defer { finishSyncUp(operationID) }
        // An already-restored account may have lost its resident native session. A queued
        // upload must repair that binding itself: ordinary pulls defer to this pending push.
        guard await ensureNativeCheckpoint(credentialCapture: capture), isCurrent(capture) else { return false }
        guard isCurrent(capture),
              VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: (try? nativeGlobalEdits()) == nil,
                                                                hasLegacyAddonOrderIntent: pendingAddonOrderIntent != nil,
                                                                overridingLegacySource: afterUserChoseThisDevice) else { return false }
        let orderIntent = pendingAddonOrderIntent
        // Build the merged doc from the current account base, then push with optimistic-concurrency
        // recovery: if a concurrent write wins the race, re-run this exact merge onto the winner's doc and
        // retry (bounded). The rebuild closure re-pulls a fresh base each attempt so the recovered push
        // never clobbers the winner; it returns nil on a failed pull so the retry aborts safely.
        guard isCurrent(capture), !hasPendingAccountDocApply(for: capture),
              let initial = await mergeLocalIntoDoc(orderIntent: orderIntent, credentialCapture: capture),
              isCurrent(capture), !hasPendingAccountDocApply(for: capture) else { return false }
        let preferenceReceipts = pendingNativePreferenceReceipts(capture: capture)
        if nativePreparedSeedCapture == capture {
            // Deployed worker: version zero INSERT succeeds only while no row exists. Never
            // escalate a rejected/unknown first insert to an epoch version over a peer's seed.
            guard initial.baseRevision == nil, initial.credentialCapture == capture else { return false }
            switch await pushSyncDocAt(initial.document, version: 0, baseRevision: initial.baseRevision,
                                      credentialCapture: capture, plaintextData: initial.plaintextData,
                                      sourceIsCurrent: initial.sourceIsCurrent) {
            case .accepted:
                guard isCurrent(capture) else { return false }
                acknowledgeNativePreferenceCloud(initial.document, receipts: preferenceReceipts, capture: capture,
                    sentPreferenceAckData: initial.nativePreferenceAckData)
                clearPushedDirtySettings(initial.nativeDirtySettings); return true
            case .upgradeRequired: return false
            case .rejected, .error:
                guard isCurrent(capture) else { return false }
                _ = await syncDown(force: true, credentialCapture: capture)
                return false
            }
        }
        let pushed = await pushDerivedDoc(initial, credentialCapture: capture, onAccepted: { [weak self] sent in
            guard let self, self.isCurrent(capture), let id = self.account?.id else { return }
            let sentDoc = sent.document
            self.acknowledgeNativePreferenceCloud(sentDoc, receipts: preferenceReceipts, capture: capture,
                sentPreferenceAckData: sent.nativePreferenceAckData)
            self.clearPushedDirtySettings(sent.nativeDirtySettings)
            self.withRemoteApplySuppressed {
                if AddonOrderSyncPolicy.acknowledges(self.pendingAddonOrderIntent, sent: orderIntent, accountID: id) {
                    self.pendingAddonOrderIntent = nil
                }
                // A push can learn a peer's newer order even when our next pull is version-skipped.
                if self.pendingAddonOrderIntent == nil, let order = sentDoc["addonOrder"] as? [String] {
                    self.publishAppliedAddonOrder(order)
                }
            }
        }) { [weak self] in
            guard let self, self.isCurrent(capture), !self.hasPendingAccountDocApply(for: capture) else { return nil }
            return await self.mergeLocalIntoDoc(orderIntent: orderIntent, credentialCapture: capture)
        }
        guard isCurrent(capture) else { return false }
        return pushed
    }

    /// Build the doc to push by MERGING this device's profiles + settings + keys + add-on order onto a
    /// freshly pulled account base (preserving keys other surfaces wrote). Extracted from syncUp so the
    /// optimistic-concurrency retry can re-run the EXACT same merge onto the winner's doc after a lost
    /// race, with identical LWW / union / never-clobber-libraryItem semantics on every attempt. The order
    /// intent is captured once per push; a newer edit stays pending until its own push is acknowledged.
    /// Returns nil on a FAILED pull (network error / undecryptable doc): a failed pull must NEVER overwrite
    /// the account's existing document, or it wipes keys other surfaces wrote.
    private func mergeLocalIntoDoc(orderIntent: AddonOrderIntent?, credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                                   exportReadWitness: (@MainActor () -> Void)? = nil) async -> DerivedSyncDoc? {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        guard isCurrent(capture), isSignedIn else { return nil }
        let capturedKey = dataKey
        let capturedTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let sourceIsCurrent = { self.dataKey == capturedKey && CoreBridge.shared.nativePlaybackTargetIsCurrent(capturedTarget) }
        nativePreparedSeedCapture = nil
        var doc: [String: Any]
        let baseRevision: Int?
        let candidateRead = await pullDocVersionedResult(credentialCapture: capture)
        guard isCurrent(capture), sourceIsCurrent() else { return nil }
        exportReadWitness?()
        switch candidateRead {
        case .failed, .unchanged: return nil
        case .ownerHistory(let plaintext, let version, let observation):
            return await mergeOwnerHistoryForExport(plaintext: plaintext, version: version,
                observation: observation, capture: capture, orderIntent: orderIntent)
        case .empty:
            baseRevision = nil
            guard let initial = try? nativeEmptyAccountDocument(capture: capture) else { return nil }
            doc = initial; nativePreparedSeedCapture = capture
        case .doc(let existing, let version, let plaintext, let observation):
            guard version >= lastSyncedVersion else { return nil }
            if CoreBridge.shared.hasOwnerHistorySession {
                guard let observation else { return nil }
                return await mergeOwnerHistoryForExport(plaintext: plaintext, version: version,
                    observation: observation, capture: capture, orderIntent: orderIntent)
            }
            doc = existing; baseRevision = version
        }
        guard isCurrent(capture), sourceIsCurrent() else { return nil }
        // The native CRDT is a TOP-LEVEL sibling of the full legacy/host preference carriers.
        // Merge the freshly pulled peer state through the kernel before exporting; never assign
        // a stale local snapshot over it, and never upload device-local activeProfileId or tokens.
        // Recheck on every optimistic-concurrency retry. Never clear an unexported host edit merely
        // because the independent native carrier was pushed successfully.
        guard VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: (try? nativeGlobalEdits()) == nil,
                                                                hasLegacyAddonOrderIntent: orderIntent != nil || pendingAddonOrderIntent != nil) else { return nil }
        var exportedDirtySettings: [String: Double] = [:]
        var exportStage = "provider_prepare"
        do {
            var providers = try mergedNativeProviderState(doc, capture: capture)
            exportStage = "legacy_prepare"
            nativeDocumentCommitGeneration &+= 1
            let conversion = nativeLegacyConversionDecision(doc, capture: capture)
            var prepared: NativeLegacyPreparation?
            if conversion.convert { prepared = try await prepareNativeLegacyMaterial(doc, capture: capture) }
            guard isCurrent(capture), sourceIsCurrent() else { return nil }
            let remote = try doc["nativeSync"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
            let hostRemote = try doc["nativeHostPreferences"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
            exportedDirtySettings = dirtySettings
            var globalEdits = try nativeGlobalEdits()
            exportedDirtySettings = nativeDirtySettingsForExport(globalEdits, snapshot: exportedDirtySettings)
            exportStage = "native_merge"
            var merged = try await CoreBridge.shared.mergeNativeAccountDocument(remote, hostRemote: hostRemote, capture: capture,
                                                                               legacyMaterial: prepared?.material, hostEdits: globalEdits, websiteEvents: Self.nativeWebsiteEvents(doc), websiteAddonEvents: Self.nativeWebsiteAddonEvents(doc), legacyWatchlists: self.nativeLegacyWatchlists(doc),
                                                                               sourceAuthority: prepared?.authority, authenticatedSourceArchive: prepared?.sourceArchive)
            guard isCurrent(capture), sourceIsCurrent() else { return nil }
            if prepared != nil { recordNativeLegacyConversion(conversion.digest, capture: capture) }
            exportStage = "preference_replay"
            let replayed = await replayNativePreferenceIntents(capture: capture)
            guard isCurrent(capture), sourceIsCurrent() else { return nil }
            // Only still-owned warm projections are eligible; unknown cold stamps stay quarantined.
            _ = await ProfileStore.shared.retryNativePreferenceProjection(keys: Set(dirtySettings.keys.filter { nativePreferenceStampIsAttributed($0) }))
            guard isCurrent(capture), sourceIsCurrent() else { return nil }
            // Export the acknowledged state after replay, never the pre-replay merge snapshot.
            if replayed || !dirtySettings.isEmpty {
                exportedDirtySettings = dirtySettings
                globalEdits = try nativeGlobalEdits()
                exportedDirtySettings = nativeDirtySettingsForExport(globalEdits, snapshot: exportedDirtySettings)
                exportStage = "native_remerge"
                merged = try await CoreBridge.shared.mergeNativeAccountDocument(nil, hostRemote: nil, capture: capture,
                    legacyMaterial: prepared?.material, hostEdits: globalEdits, websiteEvents: [], websiteAddonEvents: [],
                    legacyWatchlists: [:], sourceAuthority: prepared?.authority, authenticatedSourceArchive: prepared?.sourceArchive)
                guard isCurrent(capture), sourceIsCurrent() else { return nil }
            }
            exportStage = "export_projection"
            doc["nativeSync"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(merged["nativeSync"]!))
            doc["nativeHostPreferences"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(merged["nativeHostPreferences"]!))
            doc["profileEditResults"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(merged["profileEditResults"]!))
            try publishNativeWebsiteOutcome(merged["profileEditResults"]!, capture: capture)
            exportStage = "provider_persist"
            providers = try persistMergedNativeProviders(providers, capture: capture)
            doc["nativeProviderCredentials"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(providers.document))
            doc["apiKeys"] = try mirrorNativeProviderKeys(providers, original: doc["apiKeys"])
            applyNativeGlobals(merged["nativeHostPreferences"]!)
        } catch {
            let detail = (error as? VortxLegacyBootstrapMaterial.ReconciliationRequired).map { " detail=" + VortxLegacyBootstrapMaterial.scrubbedReason($0.reason) } ?? ""
            DiagnosticsLog.log("sync", "operation=native_sync_export result=failed stage=\(exportStage) reason=\(VortxNativeError.diagnosticCode(error))\(detail)")
            return nil
        }
        // Never rewrite the legacy migration baseline from native/profile/overlay mirrors. Until
        // a versioned bidirectional adapter exists, native exports only its own accepted carrier.
        guard sourceIsCurrent() else { return nil }
        return DerivedSyncDoc(document: doc, baseRevision: baseRevision, credentialCapture: capture,
                              sourceIsCurrent: sourceIsCurrent, nativeDirtySettings: exportedDirtySettings)
    }

    /// The current add-on order this device holds, as normalized transportUrls in the engine's true
    /// priority order (the same `rawAddonDescriptorsOrdered` spine `vortxSummary` uses). Removed add-ons
    /// (tombstoned) are excluded so the shared order never re-lists a removed add-on. Normalized on the
    /// same trim+lowercase as the tombstone + doc.addonOrder read side so cross-surface comparison holds.
    static func currentAddonOrder() -> [String] {
        let removed = AddonTombstones.all()
        var seen = Set<String>()
        var live: [String] = []
        for raw in CoreBridge.shared.rawAddonDescriptorsOrdered() {
            guard let url = raw["transportUrl"] as? String, !url.isEmpty else { continue }
            let normalized = AddonTombstones.normalize(url)
            guard !removed.contains(normalized), seen.insert(normalized).inserted else { continue }
            live.append(normalized)
        }
        // Missing engine entries do not prove uninstall: hydration may still be in flight. Retain the
        // full applied spine and remove only timestamp-tombstoned URLs; new installs append stably.
        let applied = appliedAddonOrder
        guard !applied.isEmpty else { return live }
        return AddonOrderSyncPolicy.unique((applied + live).filter { !removed.contains($0) })
    }

    /// Explicit Retry/Sync now may try immediately; automatic catch-up obeys failed-import
    /// backoff. Neither path clears a poisoned session or treats unreadable data as empty.
    func retryAccountRestore() async -> Bool {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return false }
        if !CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: ProfileStore.shared.activeID) {
            guard await restoreNativeCheckpoint(credentialCapture: capture, userInitiated: true), isCurrent(capture) else { return false }
        }
        return await restoreAccountDocIfNeeded()
    }

    /// GUARANTEED RESTORE (#145 M1). Make this device apply the account's document before it is ever allowed to
    /// push over it. Returns true once the gate is open: either a doc was applied, or the account definitively
    /// has none.
    ///
    /// This replaces a RACE with an ORDER. The old restore was one unforced syncDown() fired at sign-in, which
    /// returned false silently on any transient network fault and bailed outright whenever hasPendingPush was
    /// armed, while the sign-in flow itself guaranteed a UserDefaults write that armed it. So restore-vs-destroy
    /// came down to whether one pull beat one 2.5s debounce. Here the restore is forced (syncDown treats a shut
    /// gate as force, so neither the pending-push guard nor the version-wins guard can turn it away), retried
    /// with backoff across transient faults, and, decisively, the push side WAITS on the outcome instead of
    /// racing it: syncUp refuses while the gate is shut.
    ///
    /// Failure is safe by construction. If every attempt fails (offline, server down, undecryptable doc), the
    /// gate stays shut, so this device keeps its local state and pushes nothing. It retries on the next launch,
    /// foreground, poll tick, or blocked push. The cost of staying shut is that a user who is offline (or whose
    /// doc will not open) cannot push until it opens; that is the correct trade against wiping their account,
    /// and "Keep this device" in the conflict prompt remains the explicit, user-chosen way through.
    @discardableResult
    func restoreAccountDocIfNeeded(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async -> Bool {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return false }
        // Single-flight: adopt(), startRealtime(), and any blocked syncUp can all arrive at once. Assigning
        // restoreTask before the first await means concurrent callers join this task rather than starting their
        // own forced pulls. Safe on the main actor: the Task body cannot begin until this function suspends.
        if let inFlight = restoreTask, restoreTaskCapture == capture { return await inFlight.value }
        restoreTask?.cancel()
        accountRestoreState = .restoring
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer {
                if self.restoreTaskCapture == capture {
                    self.restoreTask = nil
                    self.restoreTaskCapture = nil
                    if self.isCurrent(capture), self.isSignedIn {
                        let documentApplied = self.hasAppliedAccountDoc && !self.hasPendingAccountDocApply(for: capture)
                        let sessionReady = CoreBridge.shared.hasCertifiedNativeSession(
                            capture: capture, profileID: ProfileStore.shared.activeID)
                        self.accountRestoreState = documentApplied && sessionReady ? .ready : .failed
                    }
                }
            }
            if self.hasAppliedAccountDoc, !self.hasPendingAccountDocApply(for: capture) {
                // A historical sync receipt opens the account-document gate, not the current
                // engine. A re-sign-in still needs its own certified checkpoint before UI handoff.
                let sessionReady = await self.ensureNativeCheckpoint(credentialCapture: capture)
                return sessionReady && self.isCurrent(capture) && self.isSignedIn
            }
            var delayNanos: UInt64 = 1_000_000_000
            for attempt in 0..<5 {
                guard self.isCurrent(capture), self.isSignedIn else { return false }
                _ = await self.syncDown(force: true, credentialCapture: capture)
                guard self.isCurrent(capture) else { return false }
                if self.hasAppliedAccountDoc, !self.hasPendingAccountDocApply(for: capture) {
                    // A definitively empty account also opens this gate. Mount its native
                    // session before reporting setup/ready, exactly as for a remembered document.
                    let sessionReady = await self.ensureNativeCheckpoint(credentialCapture: capture)
                    return sessionReady && self.isCurrent(capture) && self.isSignedIn
                }
                guard attempt < 4 else { break }
                try? await Task.sleep(nanoseconds: delayNanos)
                guard self.isCurrent(capture) else { return false }
                delayNanos = min(delayNanos * 2, 8_000_000_000)
            }
            guard self.isCurrent(capture) else { return false }
            if !self.hasAppliedAccountDoc || self.hasPendingAccountDocApply(for: capture) {
                NSLog("[sync] account doc not restored yet (#145 gate stays shut; pushes refused until it opens)")
            }
            guard self.hasAppliedAccountDoc, !self.hasPendingAccountDocApply(for: capture), self.isSignedIn else { return false }
            let sessionReady = await self.ensureNativeCheckpoint(credentialCapture: capture)
            return sessionReady && self.isCurrent(capture) && self.isSignedIn
        }
        restoreTaskCapture = capture
        restoreTask = task
        return await task.value
    }

    /// A mount alone cannot acknowledge a pulled document. Merge both carriers against its exact
    /// current profile/credential receipt, durably commit, and publish the accepted host projections.
    @discardableResult
    private func commitNativePulledDocument(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture,
                                            preparedAtLaunch: NativeLegacyPreparation? = nil,
                                            standDownIfSuperseded: Bool = false) async throws -> PlaybackMutationTarget {
        let profileID = ProfileStore.shared.activeID
        guard isCurrent(capture), CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: profileID),
              case .native(let initialBinding?) = CoreBridge.shared.captureNativePlaybackTarget() else {
            throw VortxNativeError.superseded
        }
        nativeDocumentCommitGeneration &+= 1
        let commitGeneration = nativeDocumentCommitGeneration
        let conversion = preparedAtLaunch == nil ? nativeLegacyConversionDecision(doc, capture: capture)
            : (convert: true, digest: nativeLegacyConversionDigest(doc))
        var prepared = preparedAtLaunch
        if prepared == nil, conversion.convert { prepared = try await prepareNativeLegacyMaterial(doc, capture: capture) }
        guard isCurrent(capture), ProfileStore.shared.activeID == profileID,
              CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: profileID) else { throw VortxNativeError.superseded }
        if standDownIfSuperseded, nativeDocumentCommitGeneration != commitGeneration { throw VortxNativeError.superseded }
        let remote = try doc["nativeSync"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
        let hostRemote = try doc["nativeHostPreferences"].map { try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0)) }
        let merged = try await CoreBridge.shared.mergeNativeAccountDocument(remote, hostRemote: hostRemote, capture: capture,
            legacyMaterial: prepared?.material, websiteEvents: Self.nativeWebsiteEvents(doc), websiteAddonEvents: Self.nativeWebsiteAddonEvents(doc),
            legacyWatchlists: nativeLegacyWatchlists(doc), sourceAuthority: prepared?.authority, authenticatedSourceArchive: prepared?.sourceArchive)
        guard isCurrent(capture), ProfileStore.shared.activeID == profileID else { throw VortxNativeError.superseded }
        if prepared != nil { recordNativeLegacyConversion(conversion.digest, capture: capture) }
        applyNativeGlobals(merged["nativeHostPreferences"]!)
        try publishNativeWebsiteOutcome(merged["profileEditResults"]!, capture: capture)
        guard let joinedNative = merged["nativeSync"], let joinedHost = merged["nativeHostPreferences"] else {
            throw VortxNativeError.invalidResponse
        }
        if NativeForegroundSyncPolicy.requiresCausalRepublish(pulledNative: remote, pulledHost: hostRemote,
                                                              joinedNative: joinedNative, joinedHost: joinedHost) {
            // A legacy epoch writer can replace these siblings with an older carrier. The local
            // checkpoint retains the join; repair via fresh pull/base+1, preserving legacy siblings.
            nativeMutationDidCommit(credentialCapture: capture)
        }
        let committedTarget = CoreBridge.shared.captureNativePlaybackTarget()
        guard case .native(let committedBinding?) = committedTarget,
              committedBinding.sessionGeneration == initialBinding.sessionGeneration,
              committedBinding.credential == capture, committedBinding.profileID == profileID,
              CoreBridge.shared.nativePlaybackTargetIsCurrent(committedTarget) else { throw VortxNativeError.superseded }
        return committedTarget
    }

    /// Pull the account's profiles + settings (and metadata keys) and apply them locally. True if anything
    /// was restored.
    /// Pull the account's profiles + settings and apply them locally. Version-aware so it only applies
    /// changes NEWER than what this device already has (and skips while a local push is queued, so it
    /// never clobbers a fresh local edit). `force` ignores both guards (used by the manual "Sync now"
    /// and by sign-in reconciliation). True if anything was restored.
    @discardableResult
    func syncDown(force: Bool = false, credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                  reportOutcome: ((ConflictResolutionOutcome) -> Void)? = nil, routineReceive: Bool = false) async -> Bool {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        let capturedDataKey = dataKey
        var outcome: ConflictResolutionOutcome = .failed
        defer { reportOutcome?(isCurrent(capture) && dataKey == capturedDataKey && !Task.isCancelled ? outcome : .failed) }
        guard isSignedIn, isCurrent(capture), backupUploadFailure != .upgradeRequired else { return false }
        // One pulled document may commit at a time, and a pull may not project an older host
        // document over an in-flight export. A refused operation leaves its ACK/version untouched.
        guard activeSyncDown?.capture != capture, activeSyncUp?.capture != capture else {
            outcome = .pending; return false
        }
        let pullID = UUID()
        activeSyncDown = (pullID, capture)
        defer { if activeSyncDown?.id == pullID { activeSyncDown = nil } }
        // PENDING-EDIT GUARD. When a GENUINE local edit is queued (a settings toggle, a profile delete: the
        // observer armed hasPendingPush), defer this pull until that edit's debounced push lands. Without it an
        // interleaved pull re-applies the account's pre-edit value and the change the user just made flips back
        // within a second: the ERDB / fanart toggle that would not stay off, and the deleted profile that came
        // straight back. This is SAFE from the Beta 8/9 starvation now that routine touch:false launch
        // housekeeping is suppressed and no longer arms hasPendingPush (see the observer + suppressHousekeeping):
        // an idle receiving device has hasPendingPush == false, so it still applies a peer's newer settings. The
        // queued push fires on its own debounce and syncUp read-merges, so deferring here never loses anything.
        //
        // #145 M1: this guard is CONDITIONAL ON HAVING ALREADY RESTORED. Both of the reasons it exists (do not
        // revert the edit the user just made, the queued push will read-merge anyway) presuppose that this
        // device already holds the account's state. On a device that has never applied the account's doc,
        // neither holds: there is no "pre-edit value" to protect, and the queued push is the destructive one.
        // Deferring to it is exactly the reinstall race, and it is armed unconditionally because the sign-in
        // flow itself writes UserDefaults. So while the restore gate is closed, a never-restored device pulls
        // regardless of a queued push, and syncUp refuses to let that push land first.
        let mustRestore = !hasAppliedAccountDoc || hasPendingAccountDocApply(for: capture)
        let effectiveForce = force || mustRestore
        if !effectiveForce, hasPendingPush { outcome = .pending; return false }
        var conditionalVersion: Int? = nil
        if effectiveForce { nativeReceiveReceipt = nil }
        conditionalVersion = routineReceive && !effectiveForce ? conditionalReceiveVersion(capture) : nil
        let pulled: (doc: [String: Any], version: Int)
        var ownerHistoryPeer: (plaintext: Data, observation: UUID)?
        let received = await pullDocVersionedRetrying(credentialCapture: capture, ifNoneMatch: conditionalVersion)
        guard isCurrent(capture), dataKey == capturedDataKey, !Task.isCancelled,
              backupUploadFailure != .upgradeRequired else { return false }
        switch received {
        case .unchanged(let version):
            guard routineReceive, !effectiveForce, conditionalVersion == version,
                  conditionalReceiveVersion(capture) == version, !Task.isCancelled else { return false }
            outcome = .completed
            return false
        case .doc(let doc, let version, let plaintext, let observation):
            pulled = (doc, version)
            if !CoreBridge.shared.hasNativeSession {
                do {
                    _ = try await restoreOwnerHistoryPulledIfNeeded(received, capture: capture,
                        selectedProfile: ProfileStore.shared.activeID, generation: nativeCheckpointGeneration)
                } catch { return false }
            }
            if CoreBridge.shared.hasOwnerHistorySession {
                guard let observation else { return false }
                ownerHistoryPeer = (plaintext, observation)
            }
        case .ownerHistory(let plaintext, let version, let observation):
            nativeReceiveReceipt = nil
            do {
                let host = try await OwnerHistoryRawAccountPreparationWorker.shared.peerHostProjection(plaintext)
                pulled = (try Self.decodeDecryptedSyncDocument(host), version)
                ownerHistoryPeer = (plaintext, observation)
            } catch { return false }
        case .empty:
            // The account definitively HAS no document. Nothing to restore, and nothing this device could push
            // over, so open the gate: a genuinely fresh account must still be seedable (reconcileAfterSignIn's
            // .seededFromDevice path pushes through syncUp). Stamped inside the suppression window because it is
            // a UserDefaults write, and an unsuppressed write here would arm the very push we are ordering.
            guard isCurrent(capture), !hasPendingAccountDocApply(for: capture) else { return false }
            nativeReceiveReceipt = nil
            withRemoteApplySuppressed { hasAppliedAccountDoc = true }
            outcome = .completed
            return false
        case .failed:
            nativeReceiveReceipt = nil
            // We did NOT read the account (transient fault already retried, or an undecryptable doc). Leave the
            // gate shut: syncUp stays blocked, so a failed read can never become a destructive push.
            return false
        }
        guard isCurrent(capture) else { return false }
        // A first routine full response must establish this mount's completed receive receipt.
        // A persisted push/applied integer alone cannot admit the next bodyless response.
        let requireNativeReceipt = routineReceive && conditionalReceiveVersion(capture) == nil
        nativeReceiveReceipt = nil
        // VERSION-WINS: once no local edit is pending, apply only a STRICTLY NEWER remote; a stale or equal pull
        // is a no-op. lastSyncedVersion is persisted per account (versionKey(for:)) so this holds across relaunches.
        //
        // #145 M1/M3: `effectiveForce` (not `force`) so a device that has never applied the account's doc is
        // never turned away here. lastSyncedVersion is advanced by an accepted PUSH, not only by an apply, so on
        // a device that already pushed once this guard reads "you are up to date" about a doc it has never read
        // and returns false forever. That is what makes the loss permanent on the client, and with no peer to
        // publish a newer version a single-device user never escapes it. Gating on hasAppliedAccountDoc instead
        // of on the version is what breaks that: the version can lie about whether we restored, the flag cannot.
        switch AddonSyncPullPolicy.decision(
            pulledVersion: pulled.version,
            lastSyncedVersion: lastSyncedVersion,
            effectiveForce: effectiveForce || requireNativeReceipt,
            hasAppliedAccountDoc: hasAppliedAccountDoc,
            hasPendingAccountDocApply: hasPendingAccountDocApply(for: capture),
            credentialIsCurrent: isCurrent(capture)
        ) {
        case .reject:
            return false
        case .warmHydrate:
            // An equal document is never reapplied, but a certified current owner may still need its
            // already-pulled descriptors materialized after a warm engine lost them. Do not fetch again.
            CoreBridge.shared.hydrateAddonsFromAccount(Self.ownedAddons(from: pulled.doc))
            outcome = .completed
            return false
        case .apply:
            break
        }
        var doc = pulled.doc
        var nativeAccountDocumentCommitted = false
        var nativeCommittedTarget: PlaybackMutationTarget?
        let nativeProviderApplySnapshot: VortxNativeProviderCredentials.Document
        guard await settleNativeProviderJournal(capture: capture), isCurrent(capture) else { return false }
        do {
            if let peer = ownerHistoryPeer {
                guard pulled.version >= lastSyncedVersion else { throw VortxNativeError.superseded }
                if !CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: ProfileStore.shared.activeID) {
                    try await mountOwnerHistoryPulled(plaintext: peer.plaintext, observation: peer.observation,
                        capture: capture, selectedProfile: ProfileStore.shared.activeID, generation: nativeCheckpointGeneration)
                }
                let accepted = try await commitOwnerHistoryPulled(plaintext: peer.plaintext, version: pulled.version,
                    observation: peer.observation, capture: capture)
                CoreBridge.shared.cancelNativeOwnerHistoryRead(accepted.read)
                doc = accepted.document
                nativeCommittedTarget = accepted.target
                nativeAccountDocumentCommitted = true
            }
            var providers = try mergedNativeProviderState(doc, capture: capture)
            if !nativeAccountDocumentCommitted,
               CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: ProfileStore.shared.activeID) {
                nativeCommittedTarget = try await commitNativePulledDocument(doc, capture: capture)
                nativeAccountDocumentCommitted = true
            }
            providers = try persistMergedNativeProviders(providers, capture: capture)
            let pulledProviders = try pulled.doc["nativeProviderCredentials"].map {
                try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            if try providers.requiresCausalRepublish(pulled: pulledProviders) {
                // Even an already-ACKed local register needs durable repair after a legacy
                // rollback. This admission survives failed sends/restarts without a new edit.
                nativeMutationDidCommit(credentialCapture: capture)
            }
            let mirrored = try mirrorNativeProviderKeys(providers, original: doc["apiKeys"])
            var keys = mirrored.compactMapValues { $0 as? String }
            if providers.local.document.fields["traktAccess"]?.value == .null {
                let events = providers.local.document.fields.filter { VortxNativeProviderCredentials.groups[0].contains($0.key) }
                guard await TraktAuth.shared.applyNativeCredentialClear(capture: capture, events: events), isCurrent(capture) else { return false }
                retireNativeProviderApply(.trakt, capture: capture)
            }
            if providers.local.document.fields["simklAccess"]?.value == .null {
                let events = providers.local.document.fields.filter { VortxNativeProviderCredentials.groups[1].contains($0.key) }
                guard await SIMKLAuth.shared.applyNativeCredentialClear(capture: capture, events: events), isCurrent(capture) else { return false }
                retireNativeProviderApply(.simkl, capture: capture)
            }
            // OAuth boundaries suspend. A newer local edit/prepared transaction invalidates this
            // entire apply snapshot, including metadata/Debrid and any queued provider plan.
            let currentProviders = try nativeProviderState(capture: capture)
            guard !currentProviders.hasPreparedMutation, currentProviders.local.document == providers.local.document else { return false }
            nativeProviderApplySnapshot = currentProviders.local.document
            // Empty strings are a local secure-store apply instruction, never emitted on wire.
            for (key, event) in providers.local.document.fields where event.value == .null { keys[key] = "" }
            doc["apiKeys"] = keys
        } catch {
            DiagnosticsLog.log("sync", "operation=native_pull_prepare result=failed reason=\(VortxNativeError.diagnosticCode(error))")
            return false
        }
        var restored = false
        var restoredSettings = false
        var pendingDebridValues = pendingDebridApply?.values ?? [:]
        var pendingDebridServices: Set<DebridService> = []
        var providerPlan: PendingProviderApply?
        guard isCurrent(capture) else { return false }
        // SUPPRESS THE OBSERVER for the whole apply region. SettingsBackup.restore + the apiKeys/overlay/
        // tombstone/profileEdits writes below all hit UserDefaults; without suppression each fires the
        // global didChangeNotification observer, which calls requestSyncSoon() -> re-arms hasPendingPush and
        // schedules a push of the just-applied peer values straight back up (the self-echo). That keeps the
        // receiving device permanently inside the hasPendingPush window, so its next syncDown bails at the
        // guard and the peer's settings are never applied. The body is fully synchronous (no awaits), so the
        // coalesced notifications drain on the next main-queue turn while the flag is still set.
        withRemoteApplySuppressed {
        providerPlan = providerApplyIntent(
            keys: doc["apiKeys"] as? [String: String],
            capture: capture,
            version: pulled.version)
        let applyLegacyBaseline = !CoreBridge.shared.hasNativeSession
        if applyLegacyBaseline {
        if let b64 = doc["settings"] as? String, let data = Data(base64Encoded: b64) {
            // Roster records are merged separately by their own clocks, never wholesale-restored.
            // This also protects a still-dirty local edit while admitting cloud-only profile ids.
            // These dictionaries are CRDT state, not replaceable scalar preferences. An older client's
            // settings blob may contain older/empty maps even when this device has newer removals.
            // LOCAL-WINS: skip any syncable key the user changed on THIS device and has not pushed yet, so the
            // account's OLDER value cannot overwrite a just-made local edit before this device's push carries it
            // up (the durable, per-key successor to the in-memory hasPendingPush guard; see SettingsDirtyKeys and
            // the "would not stay" interplay at :1175-1182). A restored/fresh device has an empty set, so a full
            // restore is unchanged. The skipped keys keep their local value, which flushDirtySettingsIfNeeded then
            // pushes so the account heals.
            if ((try? AddonTombstones.preservingLocalSyncStamps {
                try SettingsBackup.restore(
                    from: data,
                    skipping: Set(dirtySettings.keys),
                    excluding: ProfileDiscoveryPreferencesStore.activeProjectionKeys.union([
                        "stremiox.profiles", "stremiox.profiles.modified", "stremiox.profiles.active"]))
            }) ?? 0) > 0 {
                restored = true
                restoredSettings = true
                // Stamp the applied-blob BASELINE (#145 resurrection fix): the syncable keys this pulled doc just
                // wrote, in the SAME migrated form restore used. mergedSyncBlob reads it on the next push so a
                // setting the user later clears on THIS device (absent locally AND in this baseline) is deleted
                // from the push instead of being resurrected by the account on the following pull. This is a
                // UserDefaults write under the vortx.sync. prefix, so it stays inside this suppression window (no
                // self-echo push) and never travels in a synced blob. REPLACE-not-union: the baseline tracks the
                // LATEST applied doc's key set, not a growing history.
                appliedSettingsBaseline = SettingsBackup.appliedKeys(
                    from: data,
                    excluding: ProfileDiscoveryPreferencesStore.activeProjectionKeys)
                LastStreamStore.invalidateCache()                    // the restore wrote new lastStream behind the cache; re-read it
                // Every OTHER store that reads UserDefaults once at init is just as blind to the restore:
                // UserDefaults KVO does not fire for our dotted keys, so nothing above re-reads them. Worse,
                // each re-persists its stale in-memory value on the next change (ThemeManager's didSet fires on
                // ANY write, including a profile switch's applyTheme), flushing the pre-restore value straight
                // back over the pulled one and making the loss permanent. Re-read them here, synchronously and
                // inside the suppression window, so those writes cannot arm a self-echo push. Runs AFTER the
                // roster settles: the per-profile stores key off ProfileStore.activeID.
            }
        }
        // A valid lossless roster can exist without a settings blob (Android/partial document).
        if let cloud = Self.resolveRoster(from: doc) {
            ProfileStore.shared.mergeInRoster(cloud.profiles,
                incomingModified: cloud.modified.map(Date.init(timeIntervalSince1970:)))
            ProfileStore.shared.applyLocalTombstones()
            restored = true
        }
        ProfileStore.shared.applyLocalTombstones()
        if restoredSettings {
            // The roster itself was excluded from restore. Reapply this device's active viewer
            // even on an equal-roster pull, before singletons read a peer's flat preference projection.
            ProfileStore.shared.reloadFromDefaults()
            SettingsBackup.reloadLiveStores()
        }
        }
        if let keys = doc["apiKeys"] as? [String: String] {
            guard isCurrent(capture) else { return }
            let debridSlots: Set<String> = ["realDebrid", "allDebrid", "premiumize", "torBox"]
            var debridAccepted = false
            if let t = keys["tmdb"] { ApiKeys.shared.tmdb = t }
            if let m = keys["mdblist"] { ApiKeys.shared.mdblist = m }
            if let f = keys["fanart"] { ApiKeys.shared.fanart = f }
            // Debrid keys: apply only when present so a doc without them never clears a locally-entered key.
            // Pending failed values are included when a later document omits the slot: an un-applied remote
            // truth remains the restore authority until its own certified retry succeeds.
            var remoteDebridValues = pendingDebridValues
            for service in DebridService.allCases {
                if let value = keys[service.rawValue] {
                    remoteDebridValues[service.rawValue] = value
                }
            }
            if !remoteDebridValues.isEmpty {
                let result = DebridKeys.shared.applyRemoteKeys(remoteDebridValues, capture: capture)
                if result.succeeded {
                    debridAccepted = true
                    pendingDebridValues.removeAll()
                } else {
                    pendingDebridServices = result.failedServices
                    pendingDebridValues = remoteDebridValues.filter {
                        guard let service = DebridService(rawValue: $0.key) else { return false }
                        return result.failedServices.contains(service)
                    }
                }
            }
            // `applyRemoteKeys` uses setKey for every slot, so each certified mutation publishes one snapshot
            // and reloads the resolver cache itself. The remote path therefore has no second reload boundary.
            // External sync provider tokens (Trakt Lane C, SIMKL Lane D): adopt a connection authored on
            // another device. Apply only when present so a doc without them never clears a locally-connected
            // session (mirrors the debrid guard just above; never delete on absence). Their capture-bound
            // plan settles directly after this synchronous suppression region, before this doc is stamped.
            // Media servers (lane E): adopt a server connected on another device. applySyncBlob union-merges by
            // id, honors removal tombstones, and writes a synced token to the Keychain only when the local slot
            // is empty (Keychain stays authoritative). Apply only when present so a doc without it never clears
            // a locally-connected server (the same never-delete-on-absence guard as the tokens above).
            if let blob = keys["vortx.mediaServers"] {
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(capture) else { return }
                    MediaServerStore.shared.applySyncBlob(blob)
                }
            }
            // IPTV playlists (Live TV): adopt a playlist registered on another device, and re-seed the Keychain
            // credentials a reinstall dropped, which is what makes a restored playlist live again instead of a
            // dead row. Union-merges by slug, honors removal tombstones, and writes a synced credential to the
            // Keychain only when the local slot is empty (Keychain stays authoritative). Apply only when present
            // so a doc without it never clears a locally-added playlist. Called SYNCHRONOUSLY (unlike the media
            // servers above): the store is @MainActor and so is this region, so its UserDefaults writes stay
            // inside the suppression window and cannot arm a self-echo push.
            if let blob = keys["vortx.iptv"] { IPTVPlaylistStore.shared.applySyncBlob(blob) }
            restored = restored || !debridSlots.isSuperset(of: Set(keys.keys)) || debridAccepted
        }
        if doc["apiKeys"] == nil, !pendingDebridValues.isEmpty {
            let result = DebridKeys.shared.applyRemoteKeys(pendingDebridValues, capture: capture)
            if result.succeeded {
                pendingDebridValues.removeAll()
            } else {
                pendingDebridServices = result.failedServices
                pendingDebridValues = pendingDebridValues.filter {
                    guard let service = DebridService(rawValue: $0.key) else { return false }
                    return result.failedServices.contains(service)
                }
            }
        }
        if let searches = doc["searches"] as? [String: [String]] {
            for (key, terms) in searches {
                // "default" is the no-profile bucket (nil); everything else is a profile UUID. Merge keeps
                // each profile's own list separate, so one profile's searches never leak to another.
                let profileID = key == "default" ? nil : UUID(uuidString: key)
                if key != "default", profileID == nil { continue }
                SearchHistoryStore.merge(terms, for: profileID)
            }
            restored = true
        }
        if !pendingDebridServices.isEmpty {
            pendingDebridApply = PendingDebridApply(
                capture: capture,
                version: pulled.version,
                values: pendingDebridValues,
                failedServices: pendingDebridServices)
        } else {
            pendingDebridApply = nil
        }
        // Publish this capture/version plan before leaving the synchronous region so no local push can race the
        // pending durable provider adoption. A Debrid failure also retains the plan, but defers its settlement.
        pendingProviderApply = providerPlan
        }   // end withRemoteApplySuppressed
        guard isCurrent(capture), pendingDebridServices.isEmpty else { return false }
        if let keys = doc["apiKeys"] as? [String: String] {
            for (name, slot) in [("tmdb", ApiKeySlots.tmdb(capture.scope)), ("mdblist", ApiKeySlots.mdblist(capture.scope)), ("fanart", ApiKeySlots.fanart(capture.scope))] {
                guard let expected = keys[name] else { continue }
                switch Keychain.confirmedString(slot) {
                case .missing where expected.isEmpty: break
                case .value(let actual) where actual == expected: break
                default: return false
                }
            }
        }
        let providerSettlement: CredentialProviderRetryOutcome
        if let pending = providerPlan {
            providerSettlement = await CredentialRetryCoordinator.finalizeProviders(
                maximumAttempts: providerRemoteApplyMaximumAttempts,
                isCurrent: { [weak self] in
                    self?.isCurrent(pending.capture) == true
                },
                firstClaim: {
                    pending.values[.trakt] ?? .none
                },
                firstClaimSucceeded: { _ in true },
                firstNeedsFinalization: {
                    if case .trakt = $0 { return true }
                    return false
                },
                firstFinalize: {
                    guard case let .trakt(access, refresh, expiryUnix) = pending.values[.trakt] ?? .none else {
                        return false
                    }
                    return await TraktAuth.shared.adoptTokens(access: access, refresh: refresh,
                        expiryUnix: expiryUnix, ownerCapture: pending.capture, mutationGuard: { mutate in
                            Self.withNativeProviderSnapshot(nativeProviderApplySnapshot, capture: pending.capture, mutation: mutate)
                        }) == .success
                },
                secondClaim: {
                    pending.values[.simkl] ?? .none
                },
                secondClaimSucceeded: { _ in true },
                secondNeedsFinalization: {
                    if case .simkl = $0 { return true }
                    return false
                },
                secondFinalize: {
                    guard case let .simkl(access, expiryUnix) = pending.values[.simkl] ?? .none else {
                        return false
                    }
                    return await SIMKLAuth.shared.adoptTokens(access: access, expiryUnix: expiryUnix,
                        ownerCapture: pending.capture, mutationGuard: { mutate in
                            Self.withNativeProviderSnapshot(nativeProviderApplySnapshot, capture: pending.capture, mutation: mutate)
                        }) == .success
                },
                sleepBeforeRetry: { [weak self] in
                    guard let self else { return false }
                    return await self.waitForProviderRemoteApplyRetry(capture: pending.capture)
                })
        } else {
            providerSettlement = CredentialProviderRetryOutcome(
                firstCompleted: true,
                secondCompleted: true,
                superseded: false)
        }
        guard isCurrent(capture), dataKey == capturedDataKey, !providerSettlement.superseded,
              backupUploadFailure != .upgradeRequired else { return false }
        if !providerSettlement.completed {
            guard let pending = providerPlan else { return false }
            let failedProviderValues = pending.values.filter {
                switch $0.key {
                case .trakt: return !providerSettlement.firstCompleted
                case .simkl: return !providerSettlement.secondCompleted
                }
            }
            withRemoteApplySuppressed {
                guard isCurrent(capture) else { return }
                pendingProviderApply = PendingProviderApply(
                    capture: pending.capture,
                    version: pending.version,
                    values: failedProviderValues,
                    failedServices: Set(failedProviderValues.keys))
            }
            return false
        }
        guard await NativeForegroundSyncPolicy.mayAcknowledgeDocument(
            nativeDocumentCommitted: nativeAccountDocumentCommitted,
            isCurrent: {
                self.isCurrent(capture) && (nativeCommittedTarget.map { CoreBridge.shared.nativePlaybackTargetIsCurrent($0) } ?? true)
            },
            ensureSession: { await self.ensureNativeCheckpoint(credentialCapture: capture) },
            commitDocument: {
                do {
                    if CoreBridge.shared.hasOwnerHistorySession {
                        let plaintext: Data, observation: UUID
                        switch received {
                        case .doc(_, _, let bytes, let observed):
                            guard let observed else { return false }
                            plaintext = bytes; observation = observed
                        case .ownerHistory(let bytes, _, let observed):
                            plaintext = bytes; observation = observed
                        default: return false
                        }
                        let accepted = try await self.commitOwnerHistoryPulled(plaintext: plaintext, version: pulled.version,
                            observation: observation, capture: capture)
                        CoreBridge.shared.cancelNativeOwnerHistoryRead(accepted.read)
                        nativeCommittedTarget = accepted.target
                    } else {
                        nativeCommittedTarget = try await self.commitNativePulledDocument(pulled.doc, capture: capture)
                    }
                    return true
                }
                catch {
                    DiagnosticsLog.log("sync", "operation=native_pull_commit result=failed reason=\(VortxNativeError.diagnosticCode(error))")
                    return false
                }
            }
        ) else { return false }
        guard isCurrent(capture), dataKey == capturedDataKey, backupUploadFailure != .upgradeRequired else { return false }
        withRemoteApplySuppressed {
            guard isCurrent(capture) else { return }
            pendingProviderApply = nil
            // Stamp the applied version inside a short suppression window: these UserDefaults writes must not
            // self-echo into a local push, and they occur only after the remote credential plan has settled.
            lastSyncedVersion = max(lastSyncedVersion, pulled.version)
            persistLastSyncedVersion()
            // #145 M1: OPEN THE RESTORE GATE only after every durable credential surface from this doc settled.
            hasAppliedAccountDoc = true
            stampSyncSuccess()
        }
        guard isCurrent(capture) else { return false }
        // Materialize this exact, just-settled document while its credential owner is still current.
        // This is deliberately after provider settlement and reuses `doc`: no second GET can race a
        // newer owner or an equal/lower version.
        // OwnerResumeStore changed without an engine event, so publish its new resume positions now. This stays
        // unconditional because refreshOwnerResumeCache does not contribute to `restored`.
        guard isCurrent(capture) else { return false }
        CoreBridge.shared.rebuildContinueWatching()
        rememberCompletedNativeReceive(version: pulled.version, capture: capture, target: nativeCommittedTarget)
        outcome = .completed
        return restored
    }

    // MARK: - Account owns everything (hydrate-from-doc + snapshot-on-import)

    /// Hydrate the engine from the VortX account's OWNED add-ons + recover the owner library, so a
    /// logged-out / degraded Stremio session shows the account's add-ons + sources + library instead of
    /// zero (the "post-update: 0 sources / 0 add-ons" fix). This is the load-bearing new capability.
    ///
    /// NEVER-ZERO INVARIANT: a `.failed` or `.empty` account pull does NOTHING (we never hydrate-then-
    /// empty). Only a real `.doc` triggers hydration. Not gated by the mirror toggles; the VortX-owned
    /// set always hydrates when the engine is empty/degraded; the toggles only control the snapshot
    /// DIRECTION (Stremio -> VortX), not the floor.
    ///
    /// Owned add-ons = `doc.vortx.addons` UNION `doc.addons` (the website Stremio import) by transportUrl.
    /// Hydration installs only descriptors the engine lacks (idempotent). Library recovery is gated to
    /// "engine account library empty AND the account owns one" so it runs at most once per fresh install.
    func hydrateEngineFromOwnedAddons(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async {
        _ = await ensureNativeCheckpoint(credentialCapture: suppliedCapture)
    }

    /// Compute the account-owned add-on descriptors from a pulled doc: `doc.vortx.addons` (the app's
    /// full descriptors) UNIONed with `doc.addons` (the website's Stremio import) by transportUrl.
    /// vortx.addons wins on conflict (it carries the freshest app descriptor). Legacy `{transportUrl,
    /// name}`-only entries (no manifest) are dropped: without a manifest the engine cannot InstallAddon.
    static func ownedAddons(from doc: [String: Any]) -> [VortXOwnedAddon] {
        var byUrl: [String: VortXOwnedAddon] = [:]
        var order: [String] = []   // preserve install order (AIOManager-compat: collection order = priority)
        // EXCLUDE durable removal tombstones so hydrateEngineFromOwnedAddons never REINSTALLS an add-on the
        // user removed (the install-only hydrate was the gap that let a removal come back). The doc's
        // deletedAddons subset was already folded into this local set on syncDown; we read the local set so
        // even a doc that predates the removal is honored. Same normalized transportUrl the set is keyed by.
        let removedAddons = AddonTombstones.all()
        func add(_ a: VortXOwnedAddon) {
            guard !removedAddons.contains(AddonTombstones.normalize(a.transportUrl)) else { return }
            // First sight wins both the order slot AND the descriptor, so the app/engine-owned set (added
            // first below) defines the order spine and its richer descriptor is kept for a shared URL.
            if byUrl[a.transportUrl] == nil { order.append(a.transportUrl); byUrl[a.transportUrl] = a }
        }
        // doc.vortx.addons (the app/engine-owned set) FIRST, so it defines the order spine - matching the
        // write-side spine in vortxSummary - and its richer descriptor wins a URL present in both; then the
        // web-import-only URLs append after.
        if let vortx = doc["vortx"] as? [String: Any], let appAddons = vortx["addons"] as? [[String: Any]] {
            for raw in appAddons { if let a = VortXOwnedAddon(json: raw) { add(a) } }
        }
        if let webAddons = doc["addons"] as? [[String: Any]] {
            for raw in webAddons { if let a = VortXOwnedAddon(json: raw) { add(a) } }
        }
        // Apply the shared cross-surface add-on ORDER (Bug B) as the ordering spine when the doc carries
        // one: a reorder made on any surface (app or web dashboard) converges here so a fresh/cold device
        // hydrates add-ons in the user's chosen priority. Compared on the same normalized transportUrl the
        // order is stored under. Any owned add-on NOT named in the order (newly installed elsewhere,
        // pre-order docs) keeps its existing relative slot AFTER the ordered ones, so nothing is dropped.
        let addonOrder = (doc["addonOrder"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? appliedAddonOrder
        if !addonOrder.isEmpty {
            var normalizedToUrl: [String: String] = [:]
            for url in order { normalizedToUrl[AddonTombstones.normalize(url)] = url }
            var ordered: [String] = []
            var placed = Set<String>()
            for normalized in addonOrder {
                guard let url = normalizedToUrl[normalized], byUrl[url] != nil, placed.insert(url).inserted
                else { continue }
                ordered.append(url)
            }
            for url in order where !placed.contains(url) { ordered.append(url) }
            return ordered.compactMap { byUrl[$0] }
        }
        return order.compactMap { byUrl[$0] }
    }

    /// Rebuild the OWNER (account) library on a cold Stremio-less device, ONLY when the engine's account
    /// library is empty AND the account doc owns one. Goes exclusively through the engine
    /// `AddToLibrary`/`addCatalogItemToAccount` path (real Cinemeta meta = schema-safe). NEVER writes app
    /// data into a libraryItem doc (the poisoned-account incident). Owner-profile semantics only: items
    /// land in the account library, which is the owner profile's history.
    private func recoverOwnerLibraryIfEmpty(
        from doc: [String: Any], credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil
    ) async {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        guard isCurrent(capture) else { return }
        guard let vortx = doc["vortx"] as? [String: Any] else { return }
        // doc.vortx.library is the owner library; fall back to doc.library (web Stremio import) if present.
        let ownedLibrary = (vortx["library"] as? [[String: Any]]) ?? (doc["library"] as? [[String: Any]]) ?? []
        guard !ownedLibrary.isEmpty || !OwnerHistoryStore.validRows().isEmpty else { return }
        // SKIP any id the user removed (the library analogue of ownedAddons(from:) excluding AddonTombstones):
        // a cold/empty engine must not RE-ADD a title the user explicitly removed, which was the exact
        // resurrection path. The doc's deletedLibrary/deletedLibraryTs were folded into this local set on
        // syncDown AND, on a cold launch, by hydrateEngineFromOwnedAddons right before this runs, so even a
        // doc that predates the removal is honored.
        let removedLibrary = LibraryTombstones.all()
        // Wave 4 (Finding 1a): the engine re-adds each title at time 0 (AddToLibrary has no offset, and
        // stremio-core exposes no action to inject one), so cache the VortX-owned resume offsets from the doc
        // UNCONDITIONALLY, before the engine-empty gate below. This is what lets a cold / recovered / post-import
        // device resume exactly where device A left off; it must populate even when the engine still reports a
        // (stale, mid-Logout) library, so it runs before the recovery guards. Never destroys.
        refreshOwnerResumeCache(from: doc)
        // Require the engine to have POSITIVELY reported a library first (`library != nil`): a nil library is the
        // not-yet-loaded state, and treating that transient zero as "missing everything" would re-add a full
        // account library while the engine is still loading its real one. A nil library defers recovery to a
        // later call.
        guard let engineLibrary = CoreBridge.shared.library?.catalog else { return }
        // DIFF-BASED recovery, not empty-only: a WARM engine (titles already present) used to early-exit
        // here, so a title added on device A landed in doc.vortx.library but NEVER appeared in device B's
        // engine library / Library rail / Continue-Watching until a cold relaunch or data reset. Diff the
        // account's owned ids against the engine's KNOWN identities (normalized, ignoring removed/temp
        // markers) and install ONLY the missing ones. Tombstones were already consulted above and keep
        // explicitly removed titles out; this is a machine membership re-add, never an ordinary install
        // intent, and the account fence (`isCurrent`) re-validates around every await.
        let knownIDs = Set(engineLibrary.filter { !($0.removed ?? false) }
            .map { LibraryTombstones.normalize($0.id) }).subtracting([""])
        // stampIntent: false because this is a machine re-add of account-owned titles: stamping an addedAt here
        // could mint a machine timestamp that beats a real removedAt this device has not folded yet, durably
        // resurrecting a removed title.
        var recovered = 0
        for item in ownedLibrary {
            guard isCurrent(capture) else { return }
            guard let id = item["id"] as? String, !id.isEmpty,
                  !removedLibrary.contains(LibraryTombstones.normalize(id)),
                  // Real catalog ids only (tt… / tmdb…); never a synthetic id, or it poisons account sync.
                  id.hasPrefix("tt") || id.hasPrefix("tmdb"),
                  // Warm-engine diff: only the account-owned titles the engine does NOT already hold.
                  !knownIDs.contains(LibraryTombstones.normalize(id)) else { continue }
            let type = (item["type"] as? String) == "series" ? "series" : "movie"
            if await CoreBridge.shared.addCatalogItemLocalOnly(id: id, type: type, credentialCapture: capture) {
                recovered += 1
            }
            guard isCurrent(capture) else { return }
        }
        if recovered > 0 {
            DiagnosticsLog.log("sync", "recovered \(recovered) owner-library title(s) from the VortX account on a cold device")
        }
    }

    /// Fold a pulled doc's app-owned tombstones (profile + library + add-on; for library/add-on both the
    /// effective-removed arrays and the {removedAt, addedAt} stamp companions) into the local
    /// last-writer-wins stores. Profile tombstones are a plain union (no stamp companion). Shared by the push-path
    /// read-merge (mergeLocalIntoDoc) and the cold-launch hydrate so both honor the stamps the doc already
    /// carries; the max-fold is idempotent, so calling it on paths that also fold elsewhere is safe. Never
    /// passes webAddonRemovals (syncDown is the single mint chokepoint for stamp-less web removals). Callers
    /// wrap this in withRemoteApplySuppressed.
    private func foldDocTombstones(_ doc: [String: Any]) {
        let vortx = doc["vortx"] as? [String: Any]
        // PROFILE tombstones FIRST (#145 M6): the doc's deletedProfiles must land in the local set BEFORE
        // the callers act on the roster, and both callers do act on it.
        //  - mergeLocalIntoDoc: mergeInRoster (called right after this) SUBTRACTS deletedProfileIDs from the
        //    union, so folding first is what stops the pulled cloud roster from re-seeding a profile a peer
        //    deleted and pushing it straight back up (resurrection). vortxSummary then emits the folded set.
        //  - hydrateEngineFromOwnedAddons: a cold-launched device (no prior syncDown) honors the deletes the
        //    doc already carries instead of treating every cloud profile as live.
        // mergeDeletedTombstones is a union that also prunes the live roster, so it is monotone and
        // idempotent exactly like the library/add-on folds below: folding a stale doc can only ADD a
        // tombstone that a newer pull would add too, and can never retract one. That is why this needs no
        // version gate. The owner id is dropped inside mergeDeletedTombstones. Callers suppress the push arm.
        let profileIDs = (vortx?["deletedProfiles"] as? [String]) ?? []
        if !profileIDs.isEmpty {
            ProfileStore.shared.mergeDeletedTombstones(profileIDs)
        }
        let libIDs = (vortx?["deletedLibrary"] as? [String]) ?? []
        let libTs = (vortx?["deletedLibraryTs"] as? [String: Any]) ?? [:]
        let libraryAdvance = Self.libraryTombstoneIDsAdvancing(legacyIDs: libIDs, stampsRaw: libTs)
        OwnerResumeStore.recordReadds(libraryAdvance.readdedAddedAt)
        if !libIDs.isEmpty || !libTs.isEmpty {
            LibraryTombstones.merge(legacyIDs: libIDs, stampsRaw: libTs)
        }
        // A tombstone is the only authoritative absence receipt available to a paged owner-library response.
        // Do this inside the same suppression window as the fold so every caller, including syncUp's read-merge,
        // cannot retain an old episode/offset after it learned a peer's removal.
        OwnerResumeStore.evict(libraryIDs: LibraryTombstones.all().union(libraryAdvance.invalidatingIDs))
        let addonIDs = (vortx?["deletedAddons"] as? [String]) ?? []
        let addonTs = (vortx?["deletedAddonsTs"] as? [String: Any]) ?? [:]
        if !addonIDs.isEmpty || !addonTs.isEmpty {
            AddonTombstones.merge(legacyIDs: addonIDs, stampsRaw: addonTs)
        }
    }

    private static let addonBaselineStampedKey = "vortx.sync.addonBaselineStampedV2"
    /// One-shot on first b172 run: stamp addedAt = now for every currently-installed non-official, non-protected
    /// add-on, so a stale pre-b172 peer array (which for a b171-reinstalled add-on carries a removal but no
    /// addedAt) cannot re-uninstall an add-on the user demonstrably has. Skips WITHOUT setting the flag when the
    /// engine has not hydrated its add-ons yet, so a later call retries; self-suppressed so the stamping writes
    /// do not arm a push. Accepted trade-off: a genuine new removal made on a still-b171 peer will not beat
    /// these baseline stamps until that peer updates.
    private func baselineInstalledAddonsOnce() {
        let baselineKey = AddonOwnerStorage.currentKey(Self.addonBaselineStampedKey)
        guard !UserDefaults.standard.bool(forKey: baselineKey) else { return }
        let installed = CoreBridge.shared.addons.filter { !$0.isOfficial && !$0.isProtected }
        guard !installed.isEmpty else { return }   // engine not hydrated yet: retry on a later call, flag unset
        // #145 M1: the flag write belongs INSIDE the suppression window, with the stamping it guards. It used to
        // sit outside, so this housekeeping (which is not a user edit and must not sync) still fired the global
        // didChangeNotification observer, which armed hasPendingPush. That mattered far beyond a stray push: it
        // runs on the sign-in path (adopt -> hydrateEngineFromOwnedAddons -> here), so every sign-in GUARANTEED
        // the armed push that the old restore's hasPendingPush guard then deferred to. This one unsuppressed
        // line is what made the reinstall race fire every time instead of occasionally.
        withRemoteApplySuppressed {
            AddonTombstones.baselineInstalled(installed.map { $0.transportUrl })
            UserDefaults.standard.set(true, forKey: baselineKey)
        }
    }

    /// Snapshot the engine's CURRENT add-ons (full descriptors) into the account doc, anchoring
    /// ownership on Stremio sign-in (and once on an already-synced launch when addonsOwnedAt is unset).
    /// UNION-not-shrink with the never-zero guard: only runs when the engine actually has add-ons, and a
    /// `.failed` account pull aborts (never clobbers the account doc). The add-on union + addonsOwnedAt
    /// are handled by vortxSummary's read-side guard; this just forces a push so the snapshot lands.
    func snapshotOwnedFromEngine() async {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return }
        guard !CoreBridge.shared.addons.isEmpty else { return }   // never-zero: nothing to anchor
        // Confirm the account doc is reachable before pushing (a .failed pull means a degraded network:
        // syncUp's own guard would already abort, but checking here avoids a wasted makeBackup).
        if case .failed = await pullSyncDocResult(credentialCapture: capture) { return }
        guard isCurrent(capture) else { return }
        _ = await syncUp()   // vortxSummary unions the engine descriptors into doc.vortx.addons + sets addonsOwnedAt
    }

    /// Wave 4: one-time-per-account import of the engine's (Stremio-synced) OWNER library + Continue Watching
    /// into the VortX account doc, after which `CoreBridge.bootstrapAuth` stops seeding the engine with the
    /// Stremio token and `StremioAccount.saveProgress`/`resumeOffset` stop hitting api.strem.io by default.
    ///
    /// Data-safe migration (design step 4 ordering): CAPTURE first, RECORD only after a confirmed non-failed
    /// push, so the VortX copy is PROVEN to exist before the token-load is dropped. Never deletes: `vortxSummary`
    /// FLOOR-unions the engine add-ons + owner library into `doc.vortx.*` (never shrinks, subtracts only the
    /// user's own removal tombstones), so this can only ADD. Idempotent: once the per-account flag is set this
    /// is a fast no-op, and a re-run after a reinstall (flag cleared) re-captures additively, losing nothing.
    ///
    /// `stremioToken` is the live Stremio authKey (Keychain-only; used solely to key the per-account flag and
    /// is never written to the account doc).
    func importOwnerLibraryFromStremioOnce(stremioToken: String) async {
        guard !stremioToken.isEmpty else { return }
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return }                                             // need a VortX account to import INTO
        guard !ProfileSync.libraryImportedFromStremio(authKey: stremioToken) else { return }   // already migrated
        // Make the engine load its account library into the readable `library` field so `vortxSummary` captures
        // the FULL set (the engine persists its bucket locally, so this reflects the Stremio-pulled library).
        await CoreBridge.shared.loadLibraryAndAwait()
        guard isCurrent(capture) else { return }
        // Require the engine to have POSITIVELY reported a library (`library != nil`): a nil library is "still
        // loading / unknown", not "empty", so we never confirm the import against an unknown state. Retry next launch.
        guard CoreBridge.shared.library != nil else { return }
        // Confirm the VortX account doc is reachable (a `.failed`/`.empty` pull means a degraded network: retry
        // next launch rather than mark imported while unreachable), then push the FLOOR union.
        guard case .doc = await pullSyncDocResult(credentialCapture: capture), isCurrent(capture) else { return }
        guard await syncUp(), isCurrent(capture) else { return }   // push failed: do NOT record the import
        // The VortX copy is confirmed on the server. Record it so the next launch can stop loading the Stremio
        // token. The Keychain token is left intact (opt-in reconnect / two-way sync).
        ProfileSync.markLibraryImportedFromStremio(authKey: stremioToken)
        DiagnosticsLog.log("sync", "imported the Stremio-owned library into the VortX account (one-time); the engine can now run local")
    }

    /// Coerce a JSON numeric (Int / Double / NSNumber, or nil) to a whole-second Int, for owner-library
    /// offset comparisons in the summary union guard.
    private static func libSeconds(_ v: Any?) -> Int {
        safeOverlaySeconds(v)
    }

    /// Decode a per-video mark/unmark clock map (`"ma"`/`"ua"`: videoId -> wall-clock ms) from a doc
    /// row. Tolerant of NSNumber/Double boxing and drops non-positive stamps (never a real clock).
    private static func clockMap(_ raw: Any?) -> [String: Double]? {
        guard let dict = raw as? [String: Any], !dict.isEmpty else { return nil }
        var out: [String: Double] = [:]
        for (k, v) in dict {
            let ms: Double
            if let d = v as? Double { ms = d }
            else if let n = v as? NSNumber { ms = n.doubleValue }
            else if let i = v as? Int { ms = Double(i) }
            else { continue }
            if ms.isFinite, ms > 0, !k.isEmpty { out[k] = ms }
        }
        return out.isEmpty ? nil : out
    }

    private static func safeOverlaySeconds(_ raw: Any?) -> Int {
        let value: Double
        if let i = raw as? Int { value = Double(i) }
        else if let d = raw as? Double { value = d }
        else if let n = raw as? NSNumber { value = n.doubleValue }
        else { return 0 }
        guard value.isFinite, value >= 0, value <= 2_000_000 else { return 0 }
        return Int(value)
    }

    /// Return only incoming tombstone identities whose wire stamp advances what this device already knows.
    /// `timestampsForSync` retains historical removedAt *and* addedAt records, so evicting every key from every
    /// pull would repeatedly erase a valid re-added resume whenever a later paged library response omitted it.
    /// The result is computed before `LibraryTombstones.merge`; callers merge, then evict effective removals plus
    /// these newly advanced ids. A legacy id without a valid stamp advances only when it is previously unknown.
    private struct LibraryTombstoneAdvance {
        var invalidatingIDs = Set<String>()
        var readdedAddedAt = [String: Double]()
    }

    private static func libraryTombstoneIDsAdvancing(
        legacyIDs: [String], stampsRaw: [String: Any]
    ) -> LibraryTombstoneAdvance {
        let prior = LibraryTombstones.timestampsForSync()
        var result = LibraryTombstoneAdvance()
        var validStamped = Set<String>()
        for (rawID, rawValue) in stampsRaw {
            let id = LibraryTombstones.normalize(rawID)
            guard !id.isEmpty, let raw = rawValue as? [String: Any] else { continue }
            let previous = prior[id] ?? [:]
            var valid = false
            var nextRemovedAt = previous["removedAt"] ?? 0
            var nextAddedAt = previous["addedAt"] ?? 0
            if let removedAt = (raw["removedAt"] as? NSNumber)?.doubleValue, removedAt.isFinite {
                valid = true
                nextRemovedAt = max(nextRemovedAt, removedAt)
            }
            if let addedAt = (raw["addedAt"] as? NSNumber)?.doubleValue, addedAt.isFinite {
                valid = true
                nextAddedAt = max(nextAddedAt, addedAt)
            }
            if nextRemovedAt > nextAddedAt {
                result.invalidatingIDs.insert(id)
            } else if nextRemovedAt > 0, nextAddedAt > nextRemovedAt,
                      (prior[id] == nil || (previous["removedAt"] ?? 0) > (previous["addedAt"] ?? 0)) {
                result.invalidatingIDs.insert(id)
                result.readdedAddedAt[id] = nextAddedAt
            }
            if valid { validStamped.insert(id) }
        }
        for rawID in legacyIDs {
            let id = LibraryTombstones.normalize(rawID)
            guard !id.isEmpty, !validStamped.contains(id), prior[id] == nil else { continue }
            result.invalidatingIDs.insert(id)
        }
        return result
    }

    /// True when the VortX account doc is currently pullable (a decryptable `.doc`). Used as a pre-flight gate
    /// before the post-import engine Logout so we NEVER unload the engine's Stremio session (which resets the
    /// engine profile, wiping its local library) unless we can immediately rebuild the owner library from the
    /// account doc this launch. On an unreachable launch we keep the session and retry next launch: no empty UI.
    func accountDocReachable() async -> Bool {
        let capture = credentialAuthority.capture()
        guard isCurrent(capture), case .doc = await pullSyncDocResult(credentialCapture: capture) else { return false }
        return isCurrent(capture)
    }

    /// Wave 4: refresh the local owner-resume cache (`OwnerResumeStore`) from a pulled doc's owner library.
    /// stremio-core re-adds owner titles at time 0 (it has no action to inject a saved offset), so this cache is
    /// the VortX-owned resume source. Called BOTH from recoverOwnerLibraryIfEmpty (cold device) AND from syncDown
    /// (so a WARM device with a non-empty engine, which skips the re-add, still converges its resume offsets to
    /// the account truth without a cold relaunch). A library response is not proven complete, so it only UPSERTS
    /// known ids. Explicit local/remote library tombstones evict removed ids before this method and before any
    /// CW rebuild. A doc t==0 (a finished / rewound title) caches 0, which the resume reads treat as "no resume",
    /// so a finish propagates correctly.
    private func refreshOwnerResumeCache(from doc: [String: Any]) {
        let vortx = doc["vortx"] as? [String: Any]
        let ownedLibrary = (vortx?["library"] as? [[String: Any]]) ?? (doc["library"] as? [[String: Any]]) ?? []
        guard !ownedLibrary.isEmpty || !OwnerHistoryStore.validRows().isEmpty else { return }
        let removed = LibraryTombstones.all()
        var entries: [(id: String, t: Double, d: Double, v: String?, lastWatched: String?)] = ownedLibrary.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  !removed.contains(LibraryTombstones.normalize(id)) else { return nil }
            return (id: id,
                    t: Double(Self.libSeconds(item["t"])),
                    d: Double(Self.libSeconds(item["d"])),
                    v: item["v"] as? String,
                    lastWatched: item["lastWatched"] as? String)
        }
        // Membership-neutral history gives a cold device a usable resume/CW observation without
        // calling AddToLibrary.  It is not filtered through LibraryTombstones: a library removal says
        // nothing about a genuine prior playback event.
        entries += OwnerHistoryStore.validRows().compactMap { item in
            guard let id = item["id"] as? String,
                  let t = Self.historySeconds(item["t"]),
                  let d = Self.historySeconds(item["d"]), d > 0,
                  let v = item["v"] as? String,
                  let lastWatched = item["lastWatched"] as? String else { return nil }
            return (id: id, t: t, d: d, v: v, lastWatched: lastWatched)
        }
        OwnerResumeStore.merge(entries)
    }

    private static func historySeconds(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0,
              value.doubleValue <= 2_000_000 else { return nil }
        return value.doubleValue
    }

    /// True when the account doc has NOT yet anchored an owned add-on set (`addonsOwnedAt` unset), so an
    /// already-synced launch can snapshot-on-import exactly once. A `.failed`/`.empty` pull returns false
    /// (nothing to do / no doc), so we never snapshot before the account is reachable.
    func ownedAddonsNeverSnapshotted() async -> Bool {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return false }
        guard case let .doc(doc) = await pullSyncDocResult(credentialCapture: capture), isCurrent(capture) else { return false }
        let vortx = doc["vortx"] as? [String: Any]
        return vortx?["addonsOwnedAt"] == nil
    }

    // MARK: - Reconciliation (no blind last-writer-wins)

    enum SignInReconcile: Equatable { case seededFromDevice, hasAccountData, unreachable }

    /// Tri-state probe: does the account already hold synced data (so a sign-in is a merge/conflict,
    /// not a seed)? Built on pullSyncDocResult() instead of the nil-collapsing pullSyncDoc() so "the
    /// pull FAILED" surfaces as a distinct `.unreachable`: the old Bool collapsed a network blip into
    /// "no data", which routed reconcileAfterSignIn into `.seededFromDevice`, whose syncUp could push
    /// this device over an account doc that was never actually read.
    enum AccountDataProbe: Equatable { case hasData, empty, unreachable }
    func accountHasSyncData() async -> AccountDataProbe {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return .unreachable }
        switch await pullSyncDocResult(credentialCapture: capture) {
        case .failed: return .unreachable
        case .empty: return isCurrent(capture) ? .empty : .unreachable
        case .doc(let doc):
            guard isCurrent(capture) else { return .unreachable }
            return (doc["settings"] != nil || doc["apiKeys"] != nil) ? .hasData : .empty
        }
    }

    /// Call right after a successful sign-in. A fresh (empty) account is seeded from this device; if the
    /// account already has data, the UI must ASK the user which side to keep (useAccountData vs
    /// pushThisDevice); and when the doc cannot be pulled the caller gets `.unreachable`, a distinct
    /// retry state in which NOTHING is pushed (a blip must never be treated as a fresh account).
    func reconcileAfterSignIn() async -> SignInReconcile {
        let capture = credentialAuthority.capture()
        let capturedDataKey = dataKey
        let probe = await accountHasSyncData()
        guard isCurrent(capture), dataKey == capturedDataKey, !Task.isCancelled else { return .unreachable }
        switch probe {
        case .hasData: return .hasAccountData
        case .unreachable: return .unreachable
        case .empty:
            guard await syncUp(), isCurrent(capture), dataKey == capturedDataKey, !Task.isCancelled else { return .unreachable }
            return .seededFromDevice
        }
    }

    /// Conflict resolution: replace this device's profiles + settings with the account's (forced).
    /// Even this "use account" path still UNIONs profiles (syncDown merges the local roster back in),
    /// so it can never delete a local-only profile; it only adopts the account's settings + fields.
    enum ConflictResolutionOutcome: Equatable { case completed, pending, failed }

    @discardableResult func useAccountData() async -> ConflictResolutionOutcome {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return .failed }
        withRemoteApplySuppressed { pendingAddonOrderIntent = nil }
        var outcome: ConflictResolutionOutcome = .failed
        await syncDown(force: true, credentialCapture: capture, reportOutcome: { outcome = $0 })
        return isCurrent(capture) ? outcome : .failed
    }
    /// Conflict resolution / "Sync now": push this device's profiles + settings to the account.
    /// STAYS BEHIND THE #145 RESTORE GATE. Most callers are automatic, not user choices (the engine-driven
    /// pushes in CoreBridge, the in-app add-on reorder, "Sync now" once rosterConflictWithAccount reports no
    /// conflict), so on a reinstall this restores first and then pushes, which is the intended order. The
    /// deliberate "Keep this device" button calls keepThisDeviceOverridingAccount() instead.
    @discardableResult func pushThisDevice() async -> Bool { await syncUp() }

    /// The user saw the three-way conflict prompt (shown only after accountHasSyncData() positively READ the
    /// account's doc and reported .hasData) and explicitly chose to overwrite the account with this device.
    /// That informed choice is the one legitimate push before this device has APPLIED the doc, so it is the only
    /// caller allowed past the restore gate. It stamps the gate open first: the user has now decided this
    /// device's state IS the account's state, so subsequent automatic pushes are no longer at risk of the #145
    /// blind overwrite. Never wire this to an automatic path.
    @discardableResult func keepThisDeviceOverridingAccount() async -> Bool {
        // An unsupported legacy override must not stamp restore acknowledgement or persist an
        // add-on-order intent that would poison subsequent native uploads, even across restart.
        // Existing intents are not silently erased: explicit account restore owns that choice.
        return false
    }

    /// Push this device's state when the app BACKGROUNDS, with a real time budget. A bare
    /// `Task { syncUp() }` on scenePhase == .background is an UNEXTENDED task the OS can suspend the instant
    /// the scene backgrounds, so a library removal / rewind made moments earlier can lose its 2-round-trip
    /// push if a sideload UPDATE then kills the process before it finishes (the Continue-Watching
    /// resurrection race). Wrapping the push in a UIKit background task asks the OS for the seconds it needs.
    /// macOS has no such API (and no jetsam on background), so it falls back to a plain push there. Called
    /// from BOTH app entry points (tvOS + iOS/Mac) for parity.
    func syncUpOnBackground() {
        // Write playback progress the native session is holding back before the app may be suspended. It
        // queues ahead of the push below, which therefore waits for it.
        CoreBridge.shared.flushNativeProgress()
        let capture = credentialAuthority.capture()
        let capturedDataKey = dataKey
        #if canImport(UIKit) && !os(macOS)
        let app = UIApplication.shared
        let lease = BackgroundSyncLease(app: app)
        lease.id = app.beginBackgroundTask(withName: "vortx.sync.background") {
            Task { @MainActor in lease.expire() }
        }
        guard lease.id != .invalid else { return }
        lease.worker = Task { @MainActor in
            await self.flushBackgroundSync(capture: capture, dataKey: capturedDataKey)
            lease.finish()
        }
        #else
        Task { await self.flushBackgroundSync(capture: capture, dataKey: capturedDataKey) }
        #endif
    }

    #if canImport(UIKit) && !os(macOS)
    @MainActor private final class BackgroundSyncLease {
        let app: UIApplication
        var id: UIBackgroundTaskIdentifier = .invalid
        var worker: Task<Void, Never>?
        init(app: UIApplication) { self.app = app }
        func expire() { worker?.cancel(); finish() }
        func finish() {
            if id != .invalid { app.endBackgroundTask(id); id = .invalid }
            worker = nil
        }
    }
    #endif

    private func flushBackgroundSync(capture: CredentialScopeRegistry.Capture, dataKey capturedDataKey: Data?) async {
        guard isSignedIn, isCurrent(capture), dataKey == capturedDataKey, !Task.isCancelled else { return }
        // Preserve the queued request when an older snapshot already owns the upload slot.
        if activeSyncUp?.capture == capture { requestSyncSoon() }
        while isSignedIn, isCurrent(capture), dataKey == capturedDataKey, !Task.isCancelled {
            if let active = activeSyncUp, active.capture == capture {
                await awaitSyncUpCompletion(active.id)
                continue
            }
            let generation = nativePushQueue.generation
            let accepted = await syncUp()
            guard isCurrent(capture), dataKey == capturedDataKey, !Task.isCancelled else { return }
            // syncUp may suspend before acquiring its slot. If another upload won during that
            // suspension, its queued refusal still needs this lease until the exact winner finishes.
            if !accepted, activeSyncUp?.capture == capture { continue }
            nativePushQueue.acknowledge(generation, accepted: accepted)
            if accepted, !nativePushQueue.hasPendingPush { nativeDurablePushPending = false }
            // Only a successful upload with a newer edit warrants another immediate export.
            guard accepted, nativePushQueue.hasPendingPush else { return }
        }
    }

    /// Conflict resolution (the RECOMMENDED choice on an explicit "Sync now" when the rosters differ):
    /// union both ways so EVERY profile from both sides survives, then push. syncDown unions the cloud
    /// roster into this device, and syncUp re-unions and pushes, so afterwards both the device and the
    /// account hold the full set of profiles.
    @discardableResult func mergeBoth() async -> Bool {
        let capture = credentialAuthority.capture()
        var outcome: ConflictResolutionOutcome = .failed
        await syncDown(force: true, credentialCapture: capture, reportOutcome: { outcome = $0 })
        guard isCurrent(capture), outcome == .completed else { return false }
        return await syncUp()
    }

    /// Whether this device's live roster differs (by the set of profile ids) from the account's, so the
    /// explicit "Sync now" button can decide between a silent push and the three-way conflict prompt.
    /// Tri-state (pullSyncDocResult, not the nil-collapsing pullSyncDoc): `.unreachable` means the doc
    /// could not be pulled, so the caller must surface a retry instead of misreading the blip as
    /// `.noConflict` and silently pushing over a roster it never actually compared against.
    enum RosterProbe: Equatable { case conflict, noConflict, unreachable }
    func rosterConflictWithAccount() async -> RosterProbe {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture) else { return .unreachable }
        switch await pullSyncDocResult(credentialCapture: capture) {
        case .failed: return .unreachable
        case .empty: return isCurrent(capture) ? .noConflict : .unreachable   // no doc yet: nothing to conflict with; a push is the seed
        case .doc(let doc):
            guard isCurrent(capture) else { return .unreachable }
            guard let cloudRoster = Self.decodeRoster(fromSettingsBlob: doc["settings"]) else { return .noConflict }
            return ProfileStore.shared.rosterDiffers(from: cloudRoster) ? .conflict : .noConflict
        }
    }

    /// Refresh account fields from /me (e.g. two-factor was toggled on the website), so the app's view
    /// of the account is not stuck at whatever sign-in returned (Bug 1).
    func refreshAccount() async {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture), var a = account else { return }
        let (code, json) = await request("GET", "/v1/auth/me", auth: true, credentialCapture: capture)
        guard isCurrent(capture) else { return }
        guard code == 200, let acct = json?["account"] as? [String: Any] else { return }
        a.username = acct["username"] as? String ?? a.username
        a.twoFactorEnabled = acct["twoFactorEnabled"] as? Bool ?? a.twoFactorEnabled
        account = a
        // This is a metadata refresh on an already-published session. Its write cannot authorize a new owner
        // or signed-in projection, so preserve the current best-effort refresh behavior on a later failure.
        _ = persist()
    }

    // MARK: - VortX-account QR sign-in (device pairing)
    //
    // A device with no keyboard (Apple TV) signs into the VortX account by showing a QR/code. A device
    // already signed into VortX (a phone, or web.vortx.tv) approves it and hands over the sync data key,
    // ECDH-wrapped to the TV's ephemeral key. The relay (/v1/qr/*) never sees the key.
    //
    // JOINER (TV):    POST /v1/qr/start {devicePublicKey} -> {pairingID, code}; then poll
    //                 GET /v1/qr/status?id=... -> {pending} | {token, payload} | 404/410 expired.
    // HOLDER (phone/web, signed in): POST /v1/qr/authorize {code, wrappedPayload} (Bearer).
    //
    // The worker mints the session `token` itself; the joiner wraps NOTHING and the holder wraps only the
    // raw 32-byte `dataKey`. The opaque `payload` string is a JSON envelope so the holder's ephemeral
    // public key travels with the sealed key: {"claim": <b64url holder pubkey>, "wrapped": <b64url iv‖ct‖tag>}.
    // Both the app holder (qrApprove) and the web holder (vortx-site vault.ts qrApprove) MUST emit this exact
    // envelope, and both joiners MUST parse it. Crypto contract: PairingCrypto (salt vortx-pairing-salt-v1,
    // info vortx-pairing-v1, base64url, iv‖ct‖tag), identical across app + web.

    /// A live joiner pairing: the id to poll, the human code to show, and our ephemeral key kept in memory
    /// only (never persisted) until the handoff completes. `devicePublicKey` is embedded in the shown QR.
    struct QrJoinSession {
        let pairingID: String
        let code: String
        let devicePublicKey: String
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
    }

    enum QrJoinResult: Equatable { case pending, transportError, expired, failed, signedIn(email: String) }

    /// Pure disposition of a `/v1/qr/status` poll from its HTTP status and whether the body already
    /// carries an approval. Split out (no crypto, no network) so the joiner's poll loop is unit-testable
    /// off device; VortX's Apple app has no XCTest bundle (see app/Tests/QRJoinerFlowTests.swift):
    ///  - 404 / 410           -> the pairing aged out server-side; the joiner re-mints a fresh code.
    ///  - 0 / 429 / >= 500    -> transport or relay trouble (offline, DNS/TLS, timeout, rate-limit, 5xx).
    ///                           RETRIABLE: the joiner keeps polling, but must stop pretending it is merely
    ///                           "waiting for approval" once it recurs, so the screen is never silently stuck.
    ///  - 200 + approval      -> ready to unwrap the data key and adopt.
    ///  - anything else       -> still pending (keep polling).
    enum QrPollDisposition: Equatable { case ready, pending, expired, retriableError }
    static func qrPollDisposition(status: Int, hasApproval: Bool) -> QrPollDisposition {
        if status == 404 || status == 410 { return .expired }
        if status == 0 || status == 429 || status >= 500 { return .retriableError }
        if status == 200 && hasApproval { return .ready }
        return .pending
    }

    /// JOINER (TV): open a pairing. Returns the session to poll, or nil on a transport failure.
    func qrStart() async -> QrJoinSession? {
        let operation = beginAuthOperation()
        let eph = PairingCrypto.newEphemeral()
        let pub = eph.publicKeyBase64URL
        let (code, json) = await request("POST", "/v1/qr/start", body: ["devicePublicKey": pub], credentialCapture: operation.credential)
        guard isCurrent(operation) else { return nil }
        guard code == 200, let id = json?["pairingID"] as? String, let human = json?["code"] as? String else { return nil }
        qrOperation = operation
        return QrJoinSession(pairingID: id, code: human, devicePublicKey: pub, ephemeral: eph.privateKey)
    }

    /// JOINER (TV): poll once. On approval, unwrap the data key, fetch the account via /me with the freshly
    /// issued token, and adopt. Security: the token is DISCARDED (never adopted) if the unwrap fails, so a
    /// session with no decryptable data key can never leave a half-signed-in device.
    func qrPoll(_ session: QrJoinSession) async -> QrJoinResult {
        let operation = qrOperation ?? AuthOperationCapture(
            generation: authOperationGeneration,
            credential: credentialAuthority.capture())
        guard isCurrent(operation) else { return .failed }
        let (code, json) = await request("GET", "/v1/qr/status?id=\(session.pairingID)", credentialCapture: operation.credential)
        guard isCurrent(operation) else { return .failed }
        let token = json?["token"] as? String
        let payloadStr = json?["payload"] as? String
        let isPending = (json?["pending"] as? Bool) == true
        let hasApproval = token != nil && payloadStr != nil && !isPending
        switch Self.qrPollDisposition(status: code, hasApproval: hasApproval) {
        case .expired:        return .expired
        case .retriableError: return .transportError   // relay unreachable / 5xx / rate-limited; keep polling
        case .pending:        return .pending
        case .ready:
            guard let token, let payloadStr else { return .pending }
            // Parse the {"claim","wrapped"} envelope and unwrap the sync data key with our ephemeral private key.
            guard let pData = payloadStr.data(using: .utf8),
                  let env = (try? JSONSerialization.jsonObject(with: pData)) as? [String: Any],
                  let claim = env["claim"] as? String, let wrapped = env["wrapped"] as? String,
                  let dk = PairingCrypto.unwrapDataKey(wrapped: wrapped, holderPublicKey: claim, using: session.ephemeral)
            else { return .failed }
            // Fetch the account this session belongs to, authing with the freshly issued token (not yet adopted).
            let (mc, mj) = await request("GET", "/v1/auth/me", bearer: token, credentialCapture: operation.credential)
            guard isCurrent(operation) else { return .failed }
            guard mc == 200, let acct = mj?["account"] as? [String: Any] else { return .failed }
            guard await adopt(token: token, account: acct, dataKey: dk, expectedOperation: operation) else { return .failed }
            qrOperation = nil
            return .signedIn(email: acct["email"] as? String ?? "")
        }
    }

    /// HOLDER (a signed-in device, and the shared shape the web holder mirrors): approve a joining device's
    /// `code`, wrapping our data key to the device's ephemeral public key (from the QR's `k` param). Returns
    /// false if we are not signed in (no data key), the wrap fails, or the relay rejects it.
    func qrApprove(code: String, devicePublicKey: String) async -> Bool {
        let capture = credentialAuthority.capture()
        guard isSignedIn, isCurrent(capture), let dataKey else { return false }
        guard let (claim, wrapped) = PairingCrypto.wrapDataKey(dataKey, toJoinerPublicKey: devicePublicKey),
              let envData = try? JSONSerialization.data(withJSONObject: ["claim": claim, "wrapped": wrapped]),
              let envelope = String(data: envData, encoding: .utf8) else { return false }
        let (c, _) = await request("POST", "/v1/qr/authorize",
            body: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), "wrappedPayload": envelope],
            auth: true, credentialCapture: capture)
        return isCurrent(capture) && c == 200
    }

    /// Auto-sync: a debounced push, called whenever a setting / profile / key changes. Coalesces a burst
    /// of edits into one push a couple of seconds later, so every change propagates without spamming.
    private var pendingSync: Task<Void, Never>?
    private var pendingSyncCapture: CredentialScopeRegistry.Capture?
    private var pendingSyncID: UUID?
    /// The worker is only waiting out a playback-progress window (no upload in flight).
    private var pendingSyncAwaitsProgressWindow = false
    func requestSyncSoon(progressOnly: Bool = false) {
        guard isSignedIn else { return }
        // Universal "do not schedule a push from this write" gate. While syncDown is applying a remote pull
        // (isApplyingRemote), the writes it makes must NOT arm a push, or the receiving device re-pushes the
        // peer values and starves its own pull guard (the Beta 8/9 settings-sync starvation). The
        // UserDefaults.didChangeNotification observer already checks this, but apiKeys (ApiKeys.didSet) and
        // debrid keys (DebridKeys.setKey) call requestSyncSoon() DIRECTLY, bypassing the observer, so the gate
        // must live here too to cover every call path. A genuine user edit never runs inside the apply window.
        guard !isApplyingRemote else { return }
        let capture = credentialAuthority.capture()
        guard isCurrent(capture) else { return }
        if pendingSyncCapture != capture {
            pendingSync?.cancel()
            pendingSync = nil
            nativePushQueue = .init()
        }
        nativePushQueue.request(progressOnly: progressOnly)
        nativeDurablePushPending = true
        guard backupUploadFailure != .upgradeRequired else { return }
        // A real edit must not wait behind a playback-progress window. Only a worker that is
        // merely sleeping on that window is replaced; an executing upload is never cancelled.
        if !progressOnly, pendingSync != nil, pendingSyncAwaitsProgressWindow {
            pendingSync?.cancel()
            pendingSync = nil
            pendingSyncID = nil
            pendingSyncAwaitsProgressWindow = false
        }
        // Do not cancel an executing upload for a later local edit. Its captured generation
        // will ACK only itself; the same worker exports the newer checkpoint next.
        guard pendingSync == nil else { return }
        let workerID = UUID()
        pendingSyncCapture = capture
        pendingSyncID = workerID
        pendingSync = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pendingSyncID == workerID {
                    self.pendingSync = nil
                    self.pendingSyncID = nil
                    self.pendingSyncAwaitsProgressWindow = false
                }
            }
            var failureBackoff: TimeInterval?
            while self.isSignedIn, self.isCurrent(capture), !Task.isCancelled {
                guard let delay = self.nativePushQueue.nextUploadDelay(now: Date(), failureBackoff: failureBackoff) else { return }
                self.pendingSyncAwaitsProgressWindow = !self.nativePushQueue.hasUrgentPush
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard self.isCurrent(capture), self.pendingSyncID == workerID else { return }
                // Newer progress moves a quiet window later; wait out the remainder first.
                if failureBackoff == nil, let remaining = self.nativePushQueue.nextUploadDelay(now: Date(), failureBackoff: nil),
                   remaining > 0.05, !self.nativePushQueue.hasUrgentPush { continue }
                self.pendingSyncAwaitsProgressWindow = false
                let generation = self.nativePushQueue.generation
                let accepted = await self.syncUp()
                guard self.isCurrent(capture), self.pendingSyncID == workerID else { return }
                guard self.backupUploadFailure != .upgradeRequired else { return }
                self.nativePushQueue.acknowledge(generation, accepted: accepted)
                failureBackoff = accepted ? nil : NativeForegroundSyncPolicy.PushQueue.nextFailureBackoff(after: failureBackoff)
                if !self.nativePushQueue.hasPendingPush {
                    self.nativeDurablePushPending = false
                    return
                }
                // Keep durable edits pending while backgrounded; foreground catch-up resumes
                // their worker. An offline active device retries without fabricating a sync badge.
                if !self.realtimeActive { return }
            }
        }
    }

    /// Run a SYNCHRONOUS block of UserDefaults writes that should NOT arm an auto-push: applying a remote
    /// pull (the self-echo case) or routine touch:false launch housekeeping. Sets isApplyingRemote for the
    /// duration AND across the next main-queue turn, because UserDefaults.didChangeNotification is delivered
    /// asynchronously on the main queue (queue: .main): the notifications generated by the writes are
    /// coalesced and run AFTER this returns, so the flag must stay set until they drain. Clearing it via a
    /// trailing DispatchQueue.main.async keeps it true while the queued observer block runs, then clears it.
    /// Must be called on the main actor with a synchronous body (no awaits inside, or notifications could
    /// leak past the window).
    func withRemoteApplySuppressed(_ body: () -> Void) {
        let wasSuppressing = isApplyingRemote
        isApplyingRemote = true
        body()
        // If we were already inside an outer suppression window, let the outer one clear it.
        guard !wasSuppressing else { return }
        DispatchQueue.main.async { [weak self] in
            // Re-baseline the LOCAL-WINS differ shadow to the just-applied domain BEFORE clearing the flag, so
            // none of the suppressed writes (a remote apply, or touch:false housekeeping) is ever mis-read as a
            // user edit by the next real didChange diff. A key that was SKIPPED as dirty kept its local value, so
            // the snapshot captures the user's value for it and it stays dirty until its own push confirms.
            self?.refreshSettingsShadow()
            self?.isApplyingRemote = false
            self?.drainLocalRosterPush()
            self?.drainNativeMutationPush()
        }
    }

    /// ProfileStore entry point: wrap a touch:false housekeeping persist so its UserDefaults writes do not
    /// arm a push. Static + main-actor-hopped so the synchronous, possibly-off-main `persist(touch:false)`
    /// can call it without itself being @MainActor; the actual flag flip + clear happen on the main actor
    /// where the observer is delivered. touch:true persists are never routed here, so user edits still sync.
    nonisolated static func suppressHousekeeping(_ writes: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.withRemoteApplySuppressed(writes) }
        } else {
            DispatchQueue.main.sync { shared.withRemoteApplySuppressed(writes) }
        }
    }

    // MARK: - Real-time pull (WebSocket SyncRoom) + while-active poll fallback

    /// Open the real-time channel: connect to the worker SyncRoom and start the while-active poll.
    /// Called on scene .active and on sign-in. Fail-soft and idempotent: no-op when signed out or
    /// already running, and a missing/failed WebSocket never breaks the existing foreground pull.
    func startRealtime() {
        guard isSignedIn else { return }
        let capture = credentialAuthority.capture()
        if realtimeActive {
            guard wsCapture != capture else { return }
            stopRealtime()
        }
        realtimeActive = true
        wsBackoff = 1
        connectWebSocket()
        startPoll()
        // Catch up immediately on the way in (matches the scenePhase foreground pull), so a change made
        // while this device was backgrounded applies right away rather than waiting for the next push.
        // #145 M1: the restore runs FIRST and is the one that must not be lost. This is the entry point that
        // covers the reinstall case with no sign-in UI at all: the session token lives in the Keychain, which
        // survives an app delete, so restore() adopts the session while UserDefaults comes back empty. That is
        // the device the old code let push its near-empty local domain over the account. It is a no-op once the
        // gate is open, and the routine catch-up below then costs one cheap version-guarded pull.
        let profileID = ProfileStore.shared.activeID
        Task {
            // A certified mount may fall back to the account owner when the saved profile was
            // deleted. Keep the profile guards below, but do not strand an account's durable
            // upload behind them after a process restart. The mutation admission also survives
            // a remote-projection suppression turn; a plain defaults push would be dropped.
            defer {
                if self.isCurrent(capture), self.realtimeActive, self.nativeDurablePushPending {
                    self.nativeMutationDidCommit(credentialCapture: capture)
                }
            }
            await self.restoreAccountDocIfNeeded(credentialCapture: capture)
            guard self.isCurrent(capture), ProfileStore.shared.activeID == profileID else { return }
            await self.syncDown(credentialCapture: capture)
            guard self.isCurrent(capture), ProfileStore.shared.activeID == profileID else { return }
            _ = await self.ensureNativeCheckpoint(credentialCapture: capture)
            guard self.isCurrent(capture), ProfileStore.shared.activeID == profileID else { return }
            // Generic native edits are checkpoint-durable, not UserDefaults dirty keys. A process
            // death after checkpoint commit but before cloud ACK must get another export on resume.
            self.nativeMutationDidCommit(credentialCapture: capture)
            // A settings change from a PREVIOUS session whose debounced push never landed (relaunch, offline, or a
            // crash before the 2.5s push) is still marked dirty and survived the pull above untouched. Arm a push
            // now so the account and the rest of the fleet converge on it. No-op when nothing is unpushed.
            self.flushDirtySettingsIfNeeded()
        }
    }

    /// Close the real-time channel: tear down the socket, reconnect, keep-alive, and the poll. Called on
    /// scene .background and on sign-out. Safe to call repeatedly.
    func stopRealtime() {
        realtimeActive = false
        wsReconnect?.cancel(); wsReconnect = nil
        wsKeepAlive?.cancel(); wsKeepAlive = nil
        pollTask?.cancel(); pollTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        wsCapture = nil
        wsHeardAt = nil
    }

    private func connectWebSocket() {
        let capture = credentialAuthority.capture()
        guard realtimeActive, isSignedIn, let token,
              // https -> wss for the SyncRoom upgrade endpoint.
              let url = URL(string: base.replacingOccurrences(of: "https://", with: "wss://") + "/v1/sync/connect")
        else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        wsCapture = capture
        wsHeardAt = nil   // a new socket counts as live only once it answers
        task.resume()
        startKeepAlive()
        receiveNext()
    }

    /// One receive at a time, re-armed after each message. A failure means the socket dropped: schedule a
    /// backoff reconnect (the while-active poll keeps changes flowing in the meantime).
    private func receiveNext() {
        guard let task = ws, let capture = wsCapture, isCurrent(capture) else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.ws === task, self.wsCapture == capture, self.isCurrent(capture) else { return }
                switch result {
                case .success(let message):
                    self.wsHeardAt = Date()
                    self.handle(message, credentialCapture: capture)
                    self.wsBackoff = 1   // a clean message means the link is healthy; reset backoff
                    self.receiveNext()
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, credentialCapture capture: CredentialScopeRegistry.Capture) {
        let text: String?
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "updated" else { return }
        // Only pull when the broadcast version is genuinely newer than what we hold. This is the same
        // version guard syncDown() enforces, checked up front so our own push echo (and the keep-alive
        // pong) never triggers a redundant pull or a feedback loop with requestSyncSoon.
        guard let version = Self.documentVersion(obj["version"]),
              NativeForegroundSyncPolicy.shouldPullBroadcast(version: version, lastAcknowledgedVersion: lastSyncedVersion,
                                                            ownerIsCurrent: isCurrent(capture)) else { return }
        Task { await syncDown(credentialCapture: capture, routineReceive: true) }
    }

    private func scheduleReconnect() {
        guard let capture = wsCapture, isCurrent(capture) else { return }
        ws?.cancel(with: .abnormalClosure, reason: nil)
        ws = nil
        wsHeardAt = nil
        wsKeepAlive?.cancel(); wsKeepAlive = nil
        guard realtimeActive, isSignedIn else { return }
        let delay = wsBackoff
        wsBackoff = min(wsBackoff * 2, wsMaxBackoff)
        wsReconnect?.cancel()
        wsReconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self, self.isCurrent(capture), self.realtimeActive else { return }
            self.connectWebSocket()
        }
    }

    /// Periodic "ping" so an idle room (Hibernation API) keeps our socket; the worker replies "pong".
    private func startKeepAlive() {
        guard let task = ws, let capture = wsCapture else { return }
        wsKeepAlive?.cancel()
        wsKeepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.keepAliveNanos ?? 30_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.ws === task, self.wsCapture == capture, self.isCurrent(capture) else { return }
                task.send(.string("ping")) { [weak self] error in
                    if error != nil {
                        Task { @MainActor in
                            guard let self, self.ws === task, self.wsCapture == capture, self.isCurrent(capture) else { return }
                            self.scheduleReconnect()
                        }
                    }
                }
            }
        }
    }

    /// Lightweight fallback: while active, pull every ~3s (native) / ~10s (legacy) when the WebSocket is down,
    /// and every five minutes while it answers (`NativeForegroundSyncPolicy.ActivePoll`). Cancelled on background.
    private func startPoll() {
        let capture = credentialAuthority.capture()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 3_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.isCurrent(capture) else { return }
                let now = Date()
                guard NativeForegroundSyncPolicy.ActivePoll.shouldPull(now: now, lastPull: self.lastPollPullAt,
                                                                      socketHeardAt: self.ws == nil ? nil : self.wsHeardAt) else { continue }
                self.lastPollPullAt = now
                await self.syncDown(credentialCapture: capture, routineReceive: true)
            }
        }
    }
}
#endif

// MARK: - Complete account sizing witness for confirmed manual collection save
extension VortXSyncManager {
    nonisolated private static let xperienceExportObservation = XperienceExportObservationFence()
    /// Called ONLY after explicit Save confirmation, never for file selection or preview.
    /// Reuses the real account export preparation, including authenticated pull, peer/event
    /// reconciliation and provider projection. Ordinary synchronization MAY checkpoint before
    /// the collection edit. This method does not upload and never follows a collection URL.
    @MainActor func prepareXperienceExportBudget(capture: CredentialScopeRegistry.Capture,
        sourceIsCurrent: @MainActor () -> Bool) async throws -> XperiencePreparedExport {
        guard isSignedIn, isCurrent(capture), sourceIsCurrent(), case .account = capture.scope,
              let key = dataKey, key.count == 32 else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        var observedGeneration: UUID?
        guard let prepared = await mergeLocalIntoDoc(orderIntent: nil, credentialCapture: capture,
            exportReadWitness: { observedGeneration = Self.xperienceExportObservation.capture() }) else {
            throw XperiencePersistenceFailure.exportBaseUnavailable
        }
        try Task.checkCancellation()
        guard isCurrent(capture), dataKey == key, sourceIsCurrent(), prepared.credentialCapture == capture,
              prepared.sourceIsCurrent(), let observedGeneration else { throw XperiencePersistenceFailure.staleContext }
        let full: VortxJSON
        if let raw = prepared.plaintextData {
            let hostOnly = try await OwnerHistoryRawAccountPreparationWorker.shared.peerHostProjection(raw)
            try Task.checkCancellation()
            guard prepared.sourceIsCurrent(), isCurrent(capture), dataKey == key else {
                throw XperiencePersistenceFailure.staleContext
            }
            full = try JSONDecoder().decode(VortxJSON.self, from: hostOnly)
        } else {
            full = try JSONDecoder().decode(VortxJSON.self,
                from: JSONSerialization.data(withJSONObject: prepared.document))
        }
        // Capture secure provider evidence under the existing store lock. The preparation and
        // capture contain no await here; a worker-visible change is still detected by exact bytes.
        let witness = try VortxNativeProviderCredentials.withStoreLock { () throws -> XperienceExportWitnessAuthority in
            let state = try nativeProviderState(capture: capture)
            guard XperienceExactEvidence.json(try state.document, full["nativeProviderCredentials"]),
                  case .value(let bytes) = Keychain.confirmedString("vortx.native.providerState." + capture.namespace) else {
                throw XperiencePersistenceFailure.exportBaseUnavailable
            }
            return .init(observation: Self.xperienceExportObservation, generation: observedGeneration,
                providerSlot: "vortx.native.providerState." + capture.namespace, providerBytes: bytes)
        }
        // Verified official BACKUP_CHUNK_WRITES capability is a release prerequisite. Custom
        // servers need a separately verified cap rather than inheriting this official contract.
        let budget: XperienceExportBudget
        if let raw = prepared.plaintextData {
            budget = try .init(completeAccountPlaintext: raw,
                maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: Self.writeSyncDocV2)
        } else {
            budget = try .init(completeAccountDocument: full,
                maximumSealedBytes: XperienceExportBudget.officialMaximumSealedBytes, writeV2: Self.writeSyncDocV2)
        }
        return .init(budget: budget, authority: witness)
    }
}

// Append to VortXSyncManager.swift, after its current complete-account extension. It must
// remain in that SAME file to reuse the existing private pull/key/observation authorities.
#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE
/// The real original FIFO object, not merely a same-scope identifier. Session must unwrap
/// against its own retained read before entering the ordinary witness -> lease -> source
/// -> FIFO -> store lock order. No source lock is nested/re-entered by this wrapper.
struct OwnerHistoryAccountPreparation: Sendable {
    let originalAcknowledgedRead: VortxNativeSession.OwnerHistoryAcknowledgedRead
    private let prepared: OwnerHistoryPreparedExport
    fileprivate init(acknowledged: VortxNativeSession.OwnerHistoryAcknowledgedRead,
                     prepared: OwnerHistoryPreparedExport) {
        originalAcknowledgedRead = acknowledged; self.prepared = prepared
    }
    func transaction(for read: VortxNativeFIFOAdmission.ReadCapability) throws -> OwnerHistoryPreparedExport {
        try Task.checkCancellation()
        guard read === originalAcknowledgedRead.originalRead else { throw VortxNativeError.superseded }
        // Queue-only: Session owns the enclosing original lease/source at final commit.
        try read.queueAuthority.withActive {}
        return prepared
    }
}

#endif

extension VortXSyncManager {
    /// Certified absence is the only permission to initialize this existing register.
    /// No edit, credential value, outbox ACK or cloud receipt is created. Return the
    /// actual confirmed secure bytes for the same witness used by all raw factories.
    @MainActor private func ownerHistoryProviderWitness(capture: CredentialScopeRegistry.Capture)
        throws -> (bytes: String, actor: String) {
        guard isCurrent(capture), case .account = capture.scope else { throw VortxNativeError.superseded }
        let actor = try nativeHostActor(capture: capture)
        let empty = try VortxNativeProviderCredentials(scope: capture.namespace, actor: actor)
        let initial = String(decoding: try empty.encoded(), as: UTF8.self)
        let providerSlot = "vortx.native.providerState." + capture.namespace
        let actorSlot = "vortx.native.hostActor." + capture.namespace
        return try VortxNativeProviderCredentials.withStoreLock {
            guard isCurrent(capture), case .value(let confirmedActor) = Keychain.confirmedString(actorSlot),
                  confirmedActor.utf8.elementsEqual(actor.utf8) else { throw VortxNativeError.superseded }
            switch Keychain.confirmedString(providerSlot) {
            case .value(let bytes): return (bytes, confirmedActor)
            case .failure: throw VortxNativeError.unavailable
            case .missing:
                guard Keychain.set(initial, for: providerSlot) == .success,
                      case .value(let bytes) = Keychain.confirmedString(providerSlot),
                      bytes.utf8.elementsEqual(initial.utf8) else { throw VortxNativeError.unavailable }
                return (bytes, confirmedActor)
            }
        }
    }

    /// Raw account preparation ONLY. The private-construction Session bundle owns ONE
    /// original acknowledged read and its exact encrypted-store CAS, never a later recapture.
    /// Heavy pure preparation runs on its own actor with NO authority held across any await.
    @MainActor func prepareOwnerHistoryAccountExport(capture: CredentialScopeRegistry.Capture,
        acknowledged: VortxNativeSession.OwnerHistoryAcknowledgedRead) async throws
        -> OwnerHistoryAccountPreparation {
        let source = acknowledged.source
        let read = acknowledged.originalRead
        if let retained = acknowledged.accountBase {
            try read.withActive {}
            let base = try await OwnerHistoryRawAccountPreparationWorker.shared.acknowledgedBase(retained,
                source: source, snapshot: acknowledged.snapshotData, host: acknowledged.hostPreferencesData,
                local: acknowledged.ownerHistoryLocalData, readOwnerUID: acknowledged.readOwnerUID)
            try read.withActive {}
            let prepared = try await prepareOwnerHistoryLocalCheckpoint(base: base,
                scope: .init(account: source.scope, ownerProfileID: source.ownerProfileID.uuidString), source: read)
            try read.withActive {}
            return OwnerHistoryAccountPreparation(acknowledged: acknowledged, prepared: prepared)
        }
        try Task.checkCancellation()
        try read.withActive {}
        guard isSignedIn, isCurrent(capture), case .account = capture.scope,
              OwnerHistoryExactJSON.sameText(source.scope, capture.namespace),
              let originalKey = dataKey, originalKey.count == 32,
              let originalAccount = account?.id, let originalToken = token, !originalToken.isEmpty,
              let url = URL(string: base + "/v1/backup"), url.scheme == "https", url.host == "api.vortx.tv",
              url.path == "/v1/backup", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil else {
            throw XperiencePersistenceFailure.exportBaseUnavailable
        }
        let originalCommitGeneration = nativeDocumentCommitGeneration
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = 20
        request.setValue("Bearer " + originalToken, forHTTPHeaderField: "authorization")
        let response = try await AuthenticatedHTTPTransport.shared.send(request,
            allowedHosts: ["api.vortx.tv"], maxResponseBytes: AuthenticatedHTTPTransport.snapshotResponseLimit)
        try Task.checkCancellation()
        try read.withActive {}
        guard isSignedIn, isCurrent(capture), dataKey == originalKey,
              account.map({ OwnerHistoryExactJSON.sameText($0.id, originalAccount) }) == true,
              token.map({ OwnerHistoryExactJSON.sameText($0, originalToken) }) == true,
              nativeDocumentCommitGeneration == originalCommitGeneration else {
            throw XperiencePersistenceFailure.staleContext
        }
        let observedGeneration: UUID
        if response.statusCode == 200 || response.statusCode == 404 {
            observedGeneration = Self.xperienceExportObservation.observe()
        } else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        guard response.statusCode == 200 else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        let worker = OwnerHistoryRawAccountPreparationWorker.shared
        let envelope = try await worker.envelope(response.data)
        try Task.checkCancellation()
        try read.withActive {}
        guard isSignedIn, isCurrent(capture), dataKey == originalKey,
              account.map({ OwnerHistoryExactJSON.sameText($0.id, originalAccount) }) == true,
              token.map({ OwnerHistoryExactJSON.sameText($0, originalToken) }) == true,
              nativeDocumentCommitGeneration == originalCommitGeneration,
              envelope.version >= lastSyncedVersion else { throw XperiencePersistenceFailure.staleContext }
        try Self.xperienceExportObservation.withCurrent(observedGeneration) {}
        // Real key/AAD/ratchet remain on their existing owner. Only immutable decrypted Data
        // crosses to the pure worker; no key, bearer, Session bundle or authority crosses.
        guard let plaintext = openSyncDocument(envelope.document, version: envelope.version) else {
            throw XperiencePersistenceFailure.exportBaseUnavailable
        }
        let providerSlot = "vortx.native.providerState." + capture.namespace
        let actorSlot = "vortx.native.hostActor." + capture.namespace
        let secure = try ownerHistoryProviderWitness(capture: capture)
        let complete = try await worker.prepare(.init(plaintext: plaintext, source: source,
            snapshotData: acknowledged.snapshotData, hostPreferencesData: acknowledged.hostPreferencesData,
            ownerHistoryLocalData: acknowledged.ownerHistoryLocalData, readOwnerUID: acknowledged.readOwnerUID,
            providerBytes: secure.bytes, providerActor: secure.actor, writeV2: Self.writeSyncDocV2))
        try Task.checkCancellation()
        try read.withActive {}
        guard isSignedIn, isCurrent(capture), dataKey == originalKey,
              account.map({ OwnerHistoryExactJSON.sameText($0.id, originalAccount) }) == true,
              token.map({ OwnerHistoryExactJSON.sameText($0, originalToken) }) == true,
              nativeDocumentCommitGeneration == originalCommitGeneration,
              envelope.version >= lastSyncedVersion else {
            throw XperiencePersistenceFailure.staleContext
        }
        var result: OwnerHistoryAccountPreparation?
        try Self.xperienceExportObservation.withCurrent(observedGeneration) {
            result = try VortxNativeProviderCredentials.withStoreLock { () throws -> OwnerHistoryAccountPreparation in
                guard case .value(let current) = Keychain.confirmedString(providerSlot),
                      current.utf8.elementsEqual(secure.bytes.utf8),
                      case .value(let actor) = Keychain.confirmedString(actorSlot),
                      actor.utf8.elementsEqual(secure.actor.utf8) else {
                    throw XperiencePersistenceFailure.exportBaseUnavailable
                }
                let witness = XperienceExportWitnessAuthority(observation: Self.xperienceExportObservation,
                    generation: observedGeneration, providerSlot: providerSlot, providerBytes: secure.bytes)
                let prepared = OwnerHistoryPreparedExport(completeAccount: complete,
                    scope: .init(account: source.scope, ownerProfileID: source.ownerProfileID.uuidString),
                    writeV2: Self.writeSyncDocV2, authority: witness)
                return .init(acknowledged: acknowledged, prepared: prepared)
            }
        }
        try Task.checkCancellation()
        try read.withActive {}
        guard isSignedIn, isCurrent(capture), dataKey == originalKey,
              account.map({ OwnerHistoryExactJSON.sameText($0.id, originalAccount) }) == true,
              token.map({ OwnerHistoryExactJSON.sameText($0, originalToken) }) == true,
              nativeDocumentCommitGeneration == originalCommitGeneration,
              envelope.version >= lastSyncedVersion, let result else {
            throw XperiencePersistenceFailure.staleContext
        }
        return result
    }
}

// Same-file append to VortXSyncManager.swift. Authenticated pull caller supplies
// its original plaintext/version, never a Foundation reconstruction or raw user input.
#if !CREDENTIAL_RETRY_COORDINATOR_STANDALONE
struct OwnerHistoryPeerPreparation: Sendable {
    let acknowledged: VortxNativeSession.OwnerHistoryCheckpointRead
    let nativeDocument: Data
    let localArchive: Data
    let peerCapabilities: Data
    let hostPreferencesData: Data?
    let legacyMaterial: Data?
    let websiteEvents: [VortxJSON]
    let websiteAddonEvents: [VortxJSON]
    let legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]]
    let authenticatedSourceArchive: Data?
    let websiteBaseline: VortxNativeProfileEditHost.Baselines
    let sourceAuthority: (any VortxMutationAuthority)?
    let legacyConversionDigest: String?
    let transaction: OwnerHistoryPreparedExport
    fileprivate init(acknowledged: VortxNativeSession.OwnerHistoryCheckpointRead,
        material: OwnerHistoryPeerMaterial, transaction: OwnerHistoryPreparedExport,
        legacyMaterial: Data?, websiteEvents: [VortxJSON], websiteAddonEvents: [VortxJSON],
        legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]], authenticatedSourceArchive: Data?,
        websiteBaseline: VortxNativeProfileEditHost.Baselines, sourceAuthority: (any VortxMutationAuthority)?,
        legacyConversionDigest: String?) {
        self.acknowledged = acknowledged
        nativeDocument = material.nativeDocument; localArchive = material.localArchive
        peerCapabilities = material.peerCapabilities
        hostPreferencesData = material.hostPreferencesData; self.transaction = transaction
        self.legacyMaterial = legacyMaterial; self.websiteEvents = websiteEvents
        self.websiteAddonEvents = websiteAddonEvents; self.legacyWatchlists = legacyWatchlists
        self.authenticatedSourceArchive = authenticatedSourceArchive
        self.websiteBaseline = websiteBaseline; self.sourceAuthority = sourceAuthority
        self.legacyConversionDigest = legacyConversionDigest
    }
}

#endif

extension VortXSyncManager {
    /// No network-per-control/action. This only prepares the existing sync's authenticated
    /// peer response; Session consumes the ORIGINAL FIFO read and encrypted-envelope CAS.
    @MainActor private func prepareOwnerHistoryPeer(plaintext: Data, version: Int, observation observed: UUID,
        capture: CredentialScopeRegistry.Capture,
        acknowledged: VortxNativeSession.OwnerHistoryCheckpointRead) async throws -> OwnerHistoryPeerPreparation {
        let scope = acknowledged.scope, read = acknowledged.originalRead
        try Task.checkCancellation()
        try read.withActive {}
        try Self.xperienceExportObservation.withCurrent(observed) {}
        guard isSignedIn, isCurrent(capture), case .account = capture.scope,
              OwnerHistoryExactJSON.sameText(scope.account, capture.namespace),
              version >= lastSyncedVersion,
              let originalKey = dataKey, originalKey.count == 32,
              let originalAccount = account?.id, let originalToken = token else {
            throw XperiencePersistenceFailure.exportBaseUnavailable
        }
        let commit = nativeDocumentCommitGeneration
        let providerSlot = "vortx.native.providerState." + capture.namespace
        let actorSlot = "vortx.native.hostActor." + capture.namespace
        let secure = try ownerHistoryProviderWitness(capture: capture)
        let worker = OwnerHistoryRawAccountPreparationWorker.shared
        let material = try await worker.peerMaterial(plaintext, scope: scope)
        let hostBytes = try await worker.peerHostProjection(plaintext)
        let document = try Self.decodeDecryptedSyncDocument(hostBytes)
        try read.withActive {}
        guard isCurrent(capture), dataKey == originalKey, version >= lastSyncedVersion,
              nativeDocumentCommitGeneration == commit else { throw XperiencePersistenceFailure.staleContext }
        let legacy: NativeLegacyPreparation?
        let conversion = nativeLegacyConversionDecision(document, capture: capture)
        if conversion.convert {
            legacy = try await prepareNativeLegacyMaterial(document, capture: capture, ownerHistoryRead: acknowledged)
        } else { legacy = nil }
        try read.withActive {}
        let websiteEvents = try Self.nativeWebsiteEvents(document)
        let addonEvents = try Self.nativeWebsiteAddonEvents(document)
        let watchlists = try nativeLegacyWatchlists(document)
        guard nativeLegacyWatchlistPending.isEmpty,
              let roster = Self.resolveRoster(from: document, fullOnly: true) else {
            throw VortxNativeError.invalidSnapshot
        }
        let baselines = try VortxNativeProfileEditHost.baselines(roster.profiles)
        // Retain all unowned peer slices. The actual full native merge and complete journal
        // UNION replace owned fields only after native validation and a durable checkpoint.
        let complete = try await worker.peerCheckpointBase(plaintext, scope: scope,
            providerBytes: secure.0, providerActor: secure.1, writeV2: Self.writeSyncDocV2)
        try Task.checkCancellation()
        try read.withActive {}
        guard isSignedIn, isCurrent(capture), dataKey == originalKey,
              account.map({ OwnerHistoryExactJSON.sameText($0.id, originalAccount) }) == true,
              token.map({ OwnerHistoryExactJSON.sameText($0, originalToken) }) == true,
              nativeDocumentCommitGeneration == commit, version >= lastSyncedVersion else {
            throw XperiencePersistenceFailure.staleContext
        }
        var result: OwnerHistoryPeerPreparation?
        try Self.xperienceExportObservation.withCurrent(observed) {
            try VortxNativeProviderCredentials.withStoreLock {
                guard case .value(let provider) = Keychain.confirmedString(providerSlot),
                      provider.utf8.elementsEqual(secure.0.utf8),
                      case .value(let actor) = Keychain.confirmedString(actorSlot),
                      actor.utf8.elementsEqual(secure.1.utf8) else {
                    throw XperiencePersistenceFailure.exportBaseUnavailable
                }
                let witness = XperienceExportWitnessAuthority(observation: Self.xperienceExportObservation,
                    generation: observed, providerSlot: providerSlot, providerBytes: secure.0)
                let transaction = OwnerHistoryPreparedExport(completeAccount: complete,
                    scope: scope, writeV2: Self.writeSyncDocV2, authority: witness)
                result = .init(acknowledged: acknowledged, material: material, transaction: transaction,
                    legacyMaterial: legacy?.material, websiteEvents: websiteEvents, websiteAddonEvents: addonEvents,
                    legacyWatchlists: watchlists, authenticatedSourceArchive: legacy?.sourceArchive,
                    websiteBaseline: baselines, sourceAuthority: legacy?.authority,
                    legacyConversionDigest: legacy == nil ? nil : conversion.digest)
            }
        }
        try read.withActive {}
        guard let result else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        return result
    }
}

// Append in VortXSyncManager.swift alongside the raw-account factory. No network call.
extension VortXSyncManager {
    /// Actor-confined weak owner; the injected Sendable closure captures only this adapter.
    /// Installation never requires fresh login/key material, preserving read-only cold reopen.
    @MainActor private final class OwnerHistoryLocalCheckpointAdapter {
        private weak var manager: VortXSyncManager?
        private let capture: CredentialScopeRegistry.Capture
        private let scope: VortxAccountScope
        private let originalAccount: String?
        init(manager: VortXSyncManager, capture: CredentialScopeRegistry.Capture,
             scope: VortxAccountScope, originalAccount: String?) {
            self.manager = manager; self.capture = capture; self.scope = scope
            self.originalAccount = originalAccount
        }
        private func requireOriginal(_ manager: VortXSyncManager, requested: VortxAccountScope) throws {
            guard requested == scope, manager.isSignedIn, manager.isCurrent(capture),
                  case .account = capture.scope,
                  OwnerHistoryExactJSON.sameText(scope.account, capture.namespace),
                  let originalAccount,
                  manager.account.map({ OwnerHistoryExactJSON.sameText($0.id, originalAccount) }) == true else {
                throw VortxNativeError.superseded
            }
        }
        func prepare(base: Data, scope requested: VortxAccountScope,
                     source: any VortxMutationAuthority) async throws -> OwnerHistoryPreparedExport {
            guard let manager else { throw VortxNativeError.unavailable }
            try Task.checkCancellation()
            try requireOriginal(manager, requested: requested)
            try source.withActive {}
            // Keep the genuine factory body and all provider/key/token/commit witnesses intact.
            let prepared = try await manager.prepareOwnerHistoryLocalCheckpoint(
                base: base, scope: requested, source: source)
            try Task.checkCancellation()
            try source.withActive {}
            try requireOriginal(manager, requested: requested)
            return prepared
        }
    }
    @MainActor private func makeOwnerHistoryLocalCheckpointPreparation(
        capture: CredentialScopeRegistry.Capture, scope: VortxAccountScope)
        -> VortxNativeSession.OwnerHistoryLocalCheckpointPreparation {
        // Bind the ORIGINAL opener epoch/account, not a future same-account sign-in.
        // nil account is retained as nil: a read-only open can succeed, mutation cannot upgrade it.
        let adapter = OwnerHistoryLocalCheckpointAdapter(manager: self, capture: capture,
            scope: scope, originalAccount: account?.id)
        return { base, requested, source in
            try await adapter.prepare(base: base, scope: requested, source: source)
        }
    }

    /// The base is privately sourced from the SAME installed encrypted checkpoint, not
    /// a UI DTO, cloud cache, caller budget, or a newly captured rejected pull response.
    /// Own ACKs replace its owned projections atomically; unrelated raw siblings survive.
    @MainActor func prepareOwnerHistoryLocalCheckpoint(base: Data, scope: VortxAccountScope,
        source: any VortxMutationAuthority, authenticatedPeer: Bool = false) async throws -> OwnerHistoryPreparedExport {
        try source.withActive {}
        let capture = CredentialScopeRegistry.shared.capture()
        guard isSignedIn, isCurrent(capture), case .account = capture.scope,
              OwnerHistoryExactJSON.sameText(capture.namespace, scope.account),
              let originalKey = dataKey, originalKey.count == 32,
              let originalAccount = account?.id, let originalToken = token else {
            throw XperiencePersistenceFailure.exportBaseUnavailable
        }
        let commit = nativeDocumentCommitGeneration
        let observation = Self.xperienceExportObservation.capture()
        let providerSlot = "vortx.native.providerState." + capture.namespace
        let actorSlot = "vortx.native.hostActor." + capture.namespace
        let secure = try ownerHistoryProviderWitness(capture: capture)
        let complete: OwnerHistoryAccountExport
        if authenticatedPeer {
            complete = try await OwnerHistoryRawAccountPreparationWorker.shared.peerCheckpointBase(
                base, scope: scope, providerBytes: secure.0, providerActor: secure.1, writeV2: Self.writeSyncDocV2)
        } else {
            complete = try await OwnerHistoryRawAccountPreparationWorker.shared.localCheckpointBase(
                base, scope: scope, providerBytes: secure.0, providerActor: secure.1, writeV2: Self.writeSyncDocV2)
        }
        try Task.checkCancellation()
        try source.withActive {}
        guard isSignedIn, isCurrent(capture), dataKey == originalKey,
              account.map({ OwnerHistoryExactJSON.sameText($0.id, originalAccount) }) == true,
              token.map({ OwnerHistoryExactJSON.sameText($0, originalToken) }) == true,
              nativeDocumentCommitGeneration == commit else { throw XperiencePersistenceFailure.staleContext }
        var result: OwnerHistoryPreparedExport?
        try Self.xperienceExportObservation.withCurrent(observation) {
            try VortxNativeProviderCredentials.withStoreLock {
                guard case .value(let provider) = Keychain.confirmedString(providerSlot),
                      provider.utf8.elementsEqual(secure.0.utf8),
                      case .value(let actor) = Keychain.confirmedString(actorSlot),
                      actor.utf8.elementsEqual(secure.1.utf8) else {
                    throw XperiencePersistenceFailure.exportBaseUnavailable
                }
                let witness = XperienceExportWitnessAuthority(observation: Self.xperienceExportObservation,
                    generation: observation, providerSlot: providerSlot, providerBytes: secure.0)
                result = OwnerHistoryPreparedExport(completeAccount: complete, scope: scope,
                    writeV2: Self.writeSyncDocV2, authority: witness)
            }
        }
        try source.withActive {}
        guard let result else { throw XperiencePersistenceFailure.exportBaseUnavailable }
        return result
    }
}

// Integrate before generic store.recovery/validateSnapshot in the existing offline opener.
// Exact new Store/Session APIs must be placed first. Root owns this same-file Manager slice.
extension VortXSyncManager {
    private struct OwnerHistoryColdSelection {
        let savedProfile: UUID
        let ownerName: String
        let target: OwnerHistorySessionCoordinator.Target
        let readOnly: Bool
        let credentialGeneration: VortxNativeOwnAccountProducer.Generation
    }
    /// Small validated profile/binding projection only. Source archives and native watches
    /// never pass through the presentation JSON decoder to choose a cold target.
    @MainActor private func ownerHistoryColdSelection(
        _ recovery: VortxEncryptedCheckpointStore.OwnerHistoryRecovery) throws -> OwnerHistoryColdSelection {
        typealias Exact = OwnerHistoryExactJSON
        let scope = recovery.scope, checkpoint = recovery.checkpoint
        guard let owner = UUID(uuidString: scope.ownerProfileID),
              let preservedUID = checkpoint.preservedOwnerUID, !preservedUID.isEmpty else {
            throw VortxNativeError.invalidSnapshot
        }
        let root = try Exact.Object(checkpoint.snapshot)
        let savedID = try root.text("activeProfileId")
        guard let saved = UUID(uuidString: savedID), saved.uuidString == savedID else { throw VortxNativeError.invalidSnapshot }
        let profiles = try Exact.Object(Exact.Object(root.required("roster")).required("profiles"))
        let ownerRecord = try Exact.Object(profiles.required(scope.ownerProfileID))
        let profile = try Exact.Object(profiles.required(savedID))
        guard try profile.required("deleted") == Data("false".utf8),
              try ownerRecord.required("owner") == Data("true".utf8),
              try ownerRecord.required("deleted") == Data("false".utf8) else { throw VortxNativeError.invalidSnapshot }
        let ownerName = try ownerRecord.text("name")
        let native = try Exact.Object(root.required("nativeSync"))
        var projectedNative: [String: VortxJSON] = [:]
        if let slots = native["accountSlots"], let slot = try Exact.Object(slots)[savedID],
           let active = try Exact.Object(slot)["activeBinding"] {
            projectedNative["accountSlots"] = .object([savedID:
                .object(["activeBinding": try JSONDecoder().decode(VortxJSON.self, from: active)])])
        }
        let projectedProfile: VortxJSON = .object([
            "account": try JSONDecoder().decode(VortxJSON.self, from: profile.required("account"))
        ])
        let state: VortxJSON = .object(["nativeSync": .object(projectedNative),
            "roster": .object(["profiles": .object([savedID: projectedProfile])])])
        let binding = try VortxNativeProfiles.expectedBinding(state: state, profileID: saved)
        func confirmed(_ slot: String) throws -> String? {
            switch Keychain.confirmedString(slot) {
            case .value(let value): return value
            case .missing: return nil
            case .failure: throw VortxNativeError.unavailable
            }
        }
        let uid: String, readOnly: Bool, generationSlot: String
        switch binding.account["kind"] {
        case .string("own")?:
            guard case .string(let ownUID) = binding.account["value"], !ownUID.isEmpty,
                  let slot = try VortxNativeAccountCredentials.selectedSlot(scope: scope.account,
                    profileID: saved, binding: binding.document) else { throw VortxNativeError.invalidSnapshot }
            uid = ownUID; readOnly = try confirmed(slot).map(\.isEmpty) ?? true; generationSlot = slot
        case .string("shared")?:
            guard binding.account["value"] == .string(scope.ownerProfileID) else { throw VortxNativeError.invalidSnapshot }
            fallthrough
        case .string("local_only")?, .string("pending_own")?:
            let selected = try VortxNativeAccountCredentials.selectedOwnerIdentity(scope: scope.account,
                ownerProfileID: owner, read: confirmed)
            uid = selected?.verifiedUID ?? preservedUID
            readOnly = selected == nil
            if let selected { generationSlot = selected.slot }
            else { generationSlot = try VortxNativeAccountCredentials.ownerSelectionKey(scope: scope.account, ownerProfileID: owner) }
        default: throw VortxNativeError.invalidSnapshot
        }
        return .init(savedProfile: saved, ownerName: ownerName,
            target: .init(profileID: saved, verifiedUID: uid), readOnly: readOnly,
            credentialGeneration: VortxNativeOwnAccountProducer.capture(slot: generationSlot))
    }

    @MainActor private func restoreOwnerHistoryCheckpoint(
        _ recovery: VortxEncryptedCheckpointStore.OwnerHistoryRecovery,
        store: VortxEncryptedCheckpointStore, capture: CredentialScopeRegistry.Capture,
        selectedProfile: UUID, generation: UUID, offline: Bool) async throws -> Bool {
        guard isCurrent(capture), recovery.scope.account == capture.namespace,
              nativeCheckpointGeneration == generation, ProfileStore.shared.activeID == selectedProfile else {
            throw VortxNativeError.superseded
        }
        let selection = try ownerHistoryColdSelection(recovery)
        let stored = try OwnerHistoryExactJSON.Object(recovery.checkpoint.snapshot)
        let roster = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(stored.required("roster")).required("profiles"))
        let publishProfile: UUID
        if let bytes = roster[selectedProfile.uuidString],
           try OwnerHistoryExactJSON.Object(bytes).required("deleted") == Data("false".utf8) {
            publishProfile = selectedProfile
        } else { publishProfile = selection.savedProfile }
        let source = VortxNativeOwnAccountProducer.Authority(generations: [selection.credentialGeneration], validate: {
            CredentialScopeRegistry.shared.isCurrent(capture)
        })
        let latch = VortxNativeHostFieldCommitLatch(source: source)
        return try await withTaskCancellationHandler {
            try latch.withActive { try store.requireCurrentOwnerHistory(recovery.checkpoint, scope: recovery.scope) }
            let resourceRestore = CoreBridge.shared.captureNativeResourceRestore(capture: capture, profileID: selectedProfile)
            await CoreBridge.shared.closeNativeSession()
            guard isCurrent(capture), nativeCheckpointGeneration == generation,
                  ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
            let session = try VortxNativeSession(scope: recovery.scope, ownerName: selection.ownerName,
                abi: VortxCABI(), store: store, transport: VortxCResourceTransport(),
                hostActor: nativeHostActor(capture: capture), sourceAuthority: latch,
                diagnostics: { DiagnosticsLog.log("native-profiles", $0) },
                ownerHistoryColdTarget: selection.target, ownerHistoryColdCheckpoint: recovery.checkpoint,
                ownerHistoryReadOnly: selection.readOnly,
                ownerHistoryLocalCheckpointPreparation: makeOwnerHistoryLocalCheckpointPreparation(capture: capture, scope: recovery.scope))
            do {
                guard let accountBase = recovery.checkpoint.ownerHistoryAccountBase else {
                    throw VortxNativeError.invalidSnapshot
                }
                try await settleOwnerHistoryCheckpointProviders(accountBase, capture: capture, source: latch)
                try latch.withActive { try store.requireCurrentOwnerHistory(recovery.checkpoint, scope: recovery.scope) }
                let registry = try await session.resourceRegistry()
                try latch.withActive {}
                guard isCurrent(capture), nativeCheckpointGeneration == generation,
                      ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
                // The optional prepublication switch uses the real Facade FIFO + checkpoint;
                // the selected global profile is never projected as a fabricated native ACK.
                try await CoreBridge.shared.installNativeSession(session, registry: registry, capture: capture,
                    initialProfileID: publishProfile, initialProfileSource: latch)
                try latch.withActive {}
                guard isCurrent(capture), nativeCheckpointGeneration == generation,
                      ProfileStore.shared.activeID == publishProfile else { throw VortxNativeError.superseded }
                let acceptedHost = try await session.hostPreferencesDocument()
                let websiteOutcome = try await session.websiteEditOutcome()
                try latch.withActive {}
                applyNativeGlobals(acceptedHost)
                try publishNativeWebsiteOutcome(websiteOutcome, capture: capture)
                // Typed Session publishes its authenticated locator using the same
                // encrypted-envelope CAS. The generic locator re-opens the old format.
                nativeCheckpointStatus = offline ? "mounted_offline" : "mounted"
                CoreBridge.shared.replayNativeResourceRestore(resourceRestore,
                    target: CoreBridge.shared.captureNativePlaybackTarget())
                DiagnosticsLog.log("native-profiles", "restore result=mounted mode=typed_\(offline ? "offline" : "local")")
                return true
            } catch { await session.close(); throw error }
        } onCancel: { latch.cancel() }
    }

    /// A real typed constructor has already accepted this encrypted checkpoint. Secure
    /// provider registers must join it before an ordinary initial profile switch budgets
    /// its next local checkpoint. External token application/cloud ACK still belongs to
    /// common syncDown; this only uses the existing durable native provider-register sink.
    @MainActor private func settleOwnerHistoryCheckpointProviders(_ accountBase: Data,
        capture: CredentialScopeRegistry.Capture, source: any VortxMutationAuthority) async throws {
        try source.withActive {}
        let host = try await OwnerHistoryRawAccountPreparationWorker.shared.peerHostProjection(accountBase)
        try source.withActive {}
        guard isCurrent(capture) else { throw VortxNativeError.superseded }
        let document = try Self.decodeDecryptedSyncDocument(host)
        _ = try persistMergedNativeProviders(mergedNativeProviderState(document, capture: capture), capture: capture)
        try source.withActive {}
    }

    /// Native format selection happens before the generic JSON/native decoder. A local
    /// typed checkpoint always wins over a legacy peer as the reopening base; the peer is
    /// joined afterwards and cannot erase its retained source history.
    @MainActor private func restoreOwnerHistoryPulledIfNeeded(_ pulled: VersionedPull,
        capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UUID) async throws -> Bool? {
        guard let key = dataKey, key.count == 32, isCurrent(capture),
              nativeCheckpointGeneration == generation else { throw VortxNativeError.superseded }
        let directory = try VortxNativeStorage.root().appendingPathComponent("VortX/native-engine-v1", isDirectory: true)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: key),
            installationKey: VortxNativeInstallationKey.loadOrCreate())
        let recovery = try store.ownerHistoryRecovery(account: capture.namespace)
        let plaintext: Data, version: Int, observation: UUID
        switch pulled {
        case .ownerHistory(let bytes, let revision, let observed):
            plaintext = bytes; version = revision; observation = observed
        case .doc(_, let revision, let bytes, let observed):
            guard recovery != nil else { return nil }
            guard let observed else { throw VortxNativeError.superseded }
            plaintext = bytes; version = revision; observation = observed
        default: return nil
        }
        guard version >= lastSyncedVersion else { throw VortxNativeError.superseded }
        try Self.xperienceExportObservation.withCurrent(observation) {}
        if let recovery {
            guard let selectedProfile else { throw VortxNativeError.invalidSnapshot }
            _ = try await restoreOwnerHistoryCheckpoint(recovery, store: store, capture: capture,
                selectedProfile: selectedProfile, generation: generation, offline: false)
        } else {
            try await mountOwnerHistoryPulled(plaintext: plaintext, observation: observation,
                capture: capture, selectedProfile: selectedProfile, generation: generation)
        }
        let accepted = try await commitOwnerHistoryPulled(plaintext: plaintext, version: version,
            observation: observation, capture: capture)
        defer { CoreBridge.shared.cancelNativeOwnerHistoryRead(accepted.read) }
        guard isCurrent(capture), dataKey == key, nativeCheckpointGeneration == generation,
              CoreBridge.shared.nativePlaybackTargetIsCurrent(accepted.target) else { throw VortxNativeError.superseded }
        nativeCheckpointStatus = "mounted"
        // The common syncDown provider settlement, not opening a profile, owns cloud ACKs.
        DiagnosticsLog.log("native-profiles", "restore result=mounted mode=typed_peer")
        return true
    }

    /// Mount only; neither version nor applied/synced receipts advance here. The caller
    /// subsequently applies this SAME authenticated response through the real peer FIFO.
    @MainActor private func mountOwnerHistoryPulled(plaintext: Data, observation: UUID,
        capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UUID) async throws {
        guard isCurrent(capture), nativeCheckpointGeneration == generation,
              ProfileStore.shared.activeID == selectedProfile, let key = dataKey, key.count == 32 else {
            throw VortxNativeError.superseded
        }
        try Self.xperienceExportObservation.withCurrent(observation) {}
        let worker = OwnerHistoryRawAccountPreparationWorker.shared
        let scope = try await worker.peerScope(plaintext, account: capture.namespace)
        let material = try await worker.peerMaterial(plaintext, scope: scope)
        let hostBytes = try await worker.peerHostProjection(plaintext)
        let document = try Self.decodeDecryptedSyncDocument(hostBytes)
        guard let uid = material.readOwnerUID, let owner = UUID(uuidString: scope.ownerProfileID),
              let roster = Self.resolveRoster(from: document, fullOnly: true),
              roster.profiles.filter({ $0.isOwner }).map(\.id) == [owner],
              let ownerRecord = roster.profiles.first(where: { $0.id == owner }) else {
            throw VortxNativeError.invalidSnapshot
        }
        let directory = try VortxNativeStorage.root().appendingPathComponent("VortX/native-engine-v1", isDirectory: true)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: key),
            installationKey: VortxNativeInstallationKey.loadOrCreate())
        if let recovery = try store.ownerHistoryRecovery(account: capture.namespace) {
            guard recovery.scope == scope, let selectedProfile else { throw VortxNativeError.invalidSnapshot }
            _ = try await restoreOwnerHistoryCheckpoint(recovery, store: store, capture: capture,
                selectedProfile: selectedProfile, generation: generation, offline: false)
            return
        }
        // An existing generic checkpoint belongs to the real warm-transfer path, never
        // create-only replacement. The generic restore opens that original state first.
        if try store.authenticatedCheckpoint(scope: scope) != nil {
            guard selectedProfile != nil,
                  await restoreOfflineNativeCheckpoint(capture: capture, selectedProfile: selectedProfile,
                    generation: generation) else { throw VortxNativeError.unavailable }
            return // The caller performs the one authenticated peer upgrade; no export here.
        }
        guard await settleNativeProviderJournal(capture: capture), isCurrent(capture) else {
            throw VortxNativeError.superseded
        }
        let accountSource = VortxNativeOwnAccountProducer.Authority(generations: [], validate: {
            CredentialScopeRegistry.shared.isCurrent(capture)
        })
        let latch = VortxNativeHostFieldCommitLatch(source: accountSource)
        try await withTaskCancellationHandler {
            let actor = try nativeHostActor(capture: capture)
            var preferences = try VortxNativeHostPreferences(scope: scope, actor: actor)
            if let host = material.hostPreferencesData {
                let value = try JSONDecoder().decode(VortxJSON.self, from: host)
                guard try OwnerHistoryExactJSON.canonical(host) ==
                    OwnerHistoryExactJSON.canonical(JSONEncoder().encode(value)) else { throw VortxNativeError.invalidSnapshot }
                try preferences.merge(value, scope: scope)
            }
            let transaction = try await prepareOwnerHistoryLocalCheckpoint(base: plaintext, scope: scope,
                source: latch, authenticatedPeer: true)
            let bootstrap = try VortxNativeBootstrapArchive.encode(document: hostBytes)
            try latch.withActive {}
            try Self.xperienceExportObservation.withCurrent(observation) {}
            guard isCurrent(capture), dataKey == key, nativeCheckpointGeneration == generation,
                  ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
            let resourceRestore = CoreBridge.shared.captureNativeResourceRestore(capture: capture, profileID: selectedProfile)
            await CoreBridge.shared.closeNativeSession()
            try latch.withActive {}
            try Self.xperienceExportObservation.withCurrent(observation) {}
            guard isCurrent(capture), dataKey == key, nativeCheckpointGeneration == generation,
                  ProfileStore.shared.activeID == selectedProfile else { throw VortxNativeError.superseded }
            let session = try VortxNativeSession(scope: scope, ownerName: ownerRecord.name,
                abi: VortxCABI(), store: store, transport: VortxCResourceTransport(),
                hostActor: actor, sourceAuthority: latch, diagnostics: { DiagnosticsLog.log("native-profiles", $0) },
                ownerHistoryColdPeer: .init(target: .init(profileID: owner, verifiedUID: uid),
                    preservedOwnerUID: uid, nativeDocument: material.nativeDocument, localArchive: material.localArchive,
                    hostPreferences: preferences.encoded(), bootstrap: bootstrap, transaction: transaction, readOnly: true),
                ownerHistoryLocalCheckpointPreparation: makeOwnerHistoryLocalCheckpointPreparation(capture: capture, scope: scope))
            do {
                try await settleOwnerHistoryCheckpointProviders(transaction.completeAccount.encoded(),
                    capture: capture, source: latch)
                let registry = try await session.resourceRegistry()
                let requested = selectedProfile.flatMap { selected in roster.profiles.contains(where: { $0.id == selected }) ? selected : nil } ?? owner
                try await CoreBridge.shared.installNativeSession(session, registry: registry, capture: capture,
                    hostProfiles: roster.profiles, initialProfileID: requested, initialProfileSource: latch)
                try latch.withActive {}
                guard isCurrent(capture), dataKey == key, nativeCheckpointGeneration == generation,
                      ProfileStore.shared.activeID == requested else { throw VortxNativeError.superseded }
                CoreBridge.shared.replayNativeResourceRestore(resourceRestore, target: CoreBridge.shared.captureNativePlaybackTarget())
            } catch { await session.close(); throw error }
        } onCancel: { latch.cancel() }
    }
}

// Same-file Manager callers. Unplaced until final source review and typed foundations.
extension VortXSyncManager {
    private struct OwnerHistoryMergedAccount {
        let document: [String: Any] // host/provider ACK projection ONLY
        let plaintext: Data
        let target: PlaybackMutationTarget
        let read: CoreBridge.NativeOwnerHistoryRead
    }

    /// One original authenticated GET -> original read -> actual native/FIFO peer merge
    /// -> its own durable ACK -> a new export read of that accepted checkpoint. Failure
    /// never recaptures an authority to retry the rejected transaction.
    @MainActor private func commitOwnerHistoryPulled(plaintext: Data, version: Int, observation: UUID,
        capture: CredentialScopeRegistry.Capture, hostEdits: [VortxNativeHostPreferences.Edit] = [])
        async throws -> OwnerHistoryMergedAccount {
        guard isCurrent(capture), version >= lastSyncedVersion,
              let key = dataKey else { throw VortxNativeError.superseded }
        try Self.xperienceExportObservation.withCurrent(observation) {}
        guard await settleNativeProviderJournal(capture: capture), isCurrent(capture), dataKey == key else {
            throw VortxNativeError.superseded
        }
        nativeDocumentCommitGeneration &+= 1
        let generation = nativeDocumentCommitGeneration
        let allowLegacyUpgrade: Bool
        if CoreBridge.shared.hasOwnerHistorySession { allowLegacyUpgrade = false }
        else {
            let worker = OwnerHistoryRawAccountPreparationWorker.shared
            let scope = try await worker.peerScope(plaintext, account: capture.namespace)
            let material = try await worker.peerMaterial(plaintext, scope: scope)
            guard material.carriesHistory, material.readOwnerUID != nil else { throw VortxNativeError.invalidSnapshot }
            allowLegacyUpgrade = true // SAME authenticated source6 pair, never a generic export fallback.
        }
        let original = try await CoreBridge.shared.captureNativeOwnerHistoryRead(capture: capture,
            allowLegacyUpgrade: allowLegacyUpgrade)
        defer { CoreBridge.shared.cancelNativeOwnerHistoryRead(original) }
        let prepared = try await prepareOwnerHistoryPeer(plaintext: plaintext, version: version,
            observation: observation, capture: capture, acknowledged: original.acknowledged)
        let target = try await CoreBridge.shared.mergeNativeOwnerHistoryPeer(prepared,
            original: original, capture: capture, hostEdits: hostEdits)
        guard isCurrent(capture), dataKey == key, nativeDocumentCommitGeneration == generation,
              CoreBridge.shared.nativePlaybackTargetIsCurrent(target) else { throw VortxNativeError.superseded }
        let read = try await CoreBridge.shared.captureNativeOwnerHistoryRead(capture: capture)
        do {
            let accepted = try await CoreBridge.shared.nativeOwnerHistoryCompleteAccount(read, writeV2: Self.writeSyncDocV2)
            let worker = OwnerHistoryRawAccountPreparationWorker.shared
            let host = try await worker.peerHostProjection(accepted)
            let document = try Self.decodeDecryptedSyncDocument(host)
            let joined = try await worker.requiresCausalOwnerHistoryRepublish(pulled: plaintext, accepted: accepted)
            try read.acknowledged.originalRead.withActive {}
            try Self.xperienceExportObservation.withCurrent(observation) {}
            guard isCurrent(capture), dataKey == key, nativeDocumentCommitGeneration == generation,
                  CoreBridge.shared.nativePlaybackTargetIsCurrent(target) else { throw VortxNativeError.superseded }
            // Every caller (including profile restore) leaves secure native registers
            // joined AFTER the real account ACK and original post-await authority checks.
            // External token application and cloud receipts still belong to syncDown.
            _ = try persistMergedNativeProviders(mergedNativeProviderState(document, capture: capture), capture: capture)
            try read.acknowledged.originalRead.withActive {}
            if prepared.legacyMaterial != nil {
                recordNativeLegacyConversion(prepared.legacyConversionDigest, capture: capture)
            }
            if let raw = document["nativeHostPreferences"] {
                applyNativeGlobals(try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: raw)))
            }
            if let raw = document["profileEditResults"] {
                try publishNativeWebsiteOutcome(JSONDecoder().decode(VortxJSON.self,
                    from: JSONSerialization.data(withJSONObject: raw)), capture: capture)
            }
            if joined || !hostEdits.isEmpty { nativeMutationDidCommit(credentialCapture: capture) }
            return .init(document: document, plaintext: accepted, target: target, read: read)
        } catch { CoreBridge.shared.cancelNativeOwnerHistoryRead(read); throw error }
    }

    @MainActor private func mergeOwnerHistoryForExport(plaintext: Data, version: Int, observation: UUID,
        capture: CredentialScopeRegistry.Capture, orderIntent: AddonOrderIntent?) async -> DerivedSyncDoc? {
        guard VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: (try? nativeGlobalEdits()) == nil,
            hasLegacyAddonOrderIntent: orderIntent != nil || pendingAddonOrderIntent != nil), let key = dataKey else { return nil }
        var acceptedRead: CoreBridge.NativeOwnerHistoryRead?
        do {
            var edits = try nativeGlobalEdits()
            var dirty = nativeDirtySettingsForExport(edits, snapshot: dirtySettings)
            var accepted = try await commitOwnerHistoryPulled(plaintext: plaintext, version: version,
                observation: observation, capture: capture, hostEdits: edits)
            acceptedRead = accepted.read
            // An accepted peer merge is not an ACK for profile preference intents which
            // were still waiting in the existing FIFO. Retire its read before replaying;
            // the next read is captured only after those genuine local ACKs have settled.
            CoreBridge.shared.cancelNativeOwnerHistoryRead(accepted.read)
            acceptedRead = nil
            let replayed = await replayNativePreferenceIntents(capture: capture)
            guard isCurrent(capture), dataKey == key else { throw VortxNativeError.superseded }
            _ = await ProfileStore.shared.retryNativePreferenceProjection(
                keys: Set(dirtySettings.keys.filter { nativePreferenceStampIsAttributed($0) }))
            guard isCurrent(capture), dataKey == key else { throw VortxNativeError.superseded }
            if replayed || !dirtySettings.isEmpty {
                edits = try nativeGlobalEdits()
                dirty = nativeDirtySettingsForExport(edits, snapshot: dirtySettings)
                accepted = try await commitOwnerHistoryPulled(plaintext: plaintext, version: version,
                    observation: observation, capture: capture, hostEdits: edits)
            } else {
                let read = try await CoreBridge.shared.captureNativeOwnerHistoryRead(capture: capture)
                do {
                    let raw = try await CoreBridge.shared.nativeOwnerHistoryCompleteAccount(read, writeV2: Self.writeSyncDocV2)
                    let host = try await OwnerHistoryRawAccountPreparationWorker.shared.peerHostProjection(raw)
                    accepted = .init(document: try Self.decodeDecryptedSyncDocument(host), plaintext: raw,
                        target: accepted.target, read: read)
                } catch { CoreBridge.shared.cancelNativeOwnerHistoryRead(read); throw error }
            }
            acceptedRead = accepted.read
            // Provider persistence follows the durable account merge, exactly as for the
            // existing path. Its ACK projection must match the actual raw candidate.
            let state = try persistMergedNativeProviders(mergedNativeProviderState(accepted.document, capture: capture), capture: capture)
            let wire = try accepted.document["nativeProviderCredentials"].map {
                try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            guard XperienceExactEvidence.json(try state.document, wire) else { throw VortxNativeError.superseded }
            let providerSlot = "vortx.native.providerState." + capture.namespace
            let actorSlot = "vortx.native.hostActor." + capture.namespace
            let secure = try VortxNativeProviderCredentials.withStoreLock { () throws -> (String, String) in
                guard case .value(let provider) = Keychain.confirmedString(providerSlot),
                      case .value(let actor) = Keychain.confirmedString(actorSlot) else { throw VortxNativeError.unavailable }
                return (provider, actor)
            }
            let preferenceAckData = try await OwnerHistoryRawAccountPreparationWorker.shared
                .nativePreferenceAckProjection(accepted.plaintext)
            let finalAccepted = accepted
            let current = { [weak self] () -> Bool in
                guard let self, self.isCurrent(capture), self.dataKey == key,
                      CoreBridge.shared.nativePlaybackTargetIsCurrent(finalAccepted.target) else { return false }
                do {
                    try finalAccepted.read.acknowledged.originalRead.withActive {}
                    return VortxNativeProviderCredentials.withStoreLock {
                        guard case .value(let provider) = Keychain.confirmedString(providerSlot),
                              case .value(let actor) = Keychain.confirmedString(actorSlot) else { return false }
                        return provider.utf8.elementsEqual(secure.0.utf8) && actor.utf8.elementsEqual(secure.1.utf8)
                    }
                } catch { return false }
            }
            guard current() else { throw VortxNativeError.superseded }
            return .init(document: accepted.document, baseRevision: version, credentialCapture: capture,
                sourceIsCurrent: current, plaintextData: accepted.plaintext,
                nativePreferenceAckData: preferenceAckData, nativeDirtySettings: dirty)
        } catch {
            if let acceptedRead { CoreBridge.shared.cancelNativeOwnerHistoryRead(acceptedRead) }
            DiagnosticsLog.log("sync", "operation=typed_account_export result=failed reason=\(VortxNativeError.diagnosticCode(error))")
            return nil
        }
    }
}
