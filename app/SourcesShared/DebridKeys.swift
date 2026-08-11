import SwiftUI

/// A debrid service VortX can hold an API key for. A debrid key turns cached torrents into instant
/// direct links; the roadmap's "in-app debrid" means the user pastes the key ONCE here, with no separate
/// add-on configuration site.
enum DebridService: String, CaseIterable, Identifiable, Sendable {
    case realDebrid, allDebrid, premiumize, torBox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .allDebrid:  return "AllDebrid"
        case .premiumize: return "Premiumize"
        case .torBox:     return "TorBox"
        }
    }

    /// The Singularity pool provider tag for this service (the closed rd/tb/pm/ad enum the source-index worker
    /// validates). Used to contribute the FACT "this provider had the source cached" alongside a torrent hash.
    var poolProviderTag: String {
        switch self {
        case .realDebrid: return "rd"
        case .allDebrid:  return "ad"
        case .premiumize: return "pm"
        case .torBox:     return "tb"
        }
    }

    /// Where to get the key, shown as a hint under the field.
    var hint: String {
        switch self {
        case .realDebrid: return "real-debrid.com, My Account then API."
        case .allDebrid:  return "alldebrid.com, Account then API keys."
        case .premiumize: return "premiumize.me, Account then API."
        case .torBox:     return "torbox.app, Settings then API."
        }
    }

    /// Keychain account this service's key is stored under (credentials, never UserDefaults), SCOPED TO ONE
    /// VortX account.
    ///
    /// The scope is the fix for a real cross-account leak: this used to be one global entry per service, and
    /// sign-out cleared the VortX token without clearing these, so the next account to sign in on the device
    /// inherited the previous account's debrid credentials and could spend them. Keying by owner means one
    /// account can never read another's, while each account keeps its own keys across a sign-out and back in.
    func keychainAccount(owner: CredentialScope) -> String {
        "vortx.debrid." + rawValue + "." + owner.keychainOwnerID
    }

    /// The pre-scoping global entry. Read once so an existing user does not have to re-paste, then removed.
    /// Never written.
    var legacyGlobalKeychainAccount: String { "vortx.debrid." + rawValue }
}

/// The immutable value handed from the main-actor store to the resolver actor. `revision` advances on every
/// owner bind and key mutation, so an older task cannot rebuild resolvers after a newer owner snapshot wins.
struct DebridCredentialSnapshot: Sendable, Equatable {
    let owner: CredentialScope
    let authorityCapture: CredentialScopeRegistry.Capture
    let revision: UInt64
    let keys: [DebridService: String]
}

/// The typed durable-credential boundary used by DebridKeys. The production adapter is composed with the
/// ApiKeys lane's certified Keychain results; executable tests inject a failure-capable store here without
/// editing the shared Keychain implementation. A read failure is never representable as missing.
protocol DebridCredentialStorage: Sendable {
    func confirmedRead(_ account: String) -> CredentialDurableReadResult
    func durableRead(_ account: String) -> CredentialDurableReadResult
    @discardableResult
    func mutate(_ value: String?, for account: String) -> CredentialMutationResult
}

private struct KeychainDebridCredentialStorage: DebridCredentialStorage {
    func confirmedRead(_ account: String) -> CredentialDurableReadResult {
        Keychain.confirmedString(account)
    }

    func durableRead(_ account: String) -> CredentialDurableReadResult {
        Keychain.durableString(account)
    }

    @discardableResult
    func mutate(_ value: String?, for account: String) -> CredentialMutationResult {
        Keychain.set(value, for: account)
    }
}

struct DebridRemoteApplyResult: Equatable, Sendable {
    let failedServices: Set<DebridService>

    var succeeded: Bool { failedServices.isEmpty }
}

private enum DebridLegacyMigrationResult {
    case noSource
    case targetPresent
    case migrated
    case retryableFailure
}

private struct DebridLegacyMigrationMarker: Codable, Equatable {
    static let currentFormat = 1

    let format: Int
    let ownerNamespace: String
    let sourceAccount: String

    init(ownerNamespace: String, sourceAccount: String) {
        format = Self.currentFormat
        self.ownerNamespace = ownerNamespace
        self.sourceAccount = sourceAccount
    }
}

/// The user's debrid API keys. Keychain-backed (they are credentials) and synced end-to-end to the
/// VortX account, so one key reaches every Apple device, no per-device re-paste. Mirrors `ApiKeys`.
/// This is the foundation of native in-app debrid: the resolver/cache-check layers read keys from here.
@MainActor
final class DebridKeys: ObservableObject {
    static let shared = DebridKeys()

    private let storage: any DebridCredentialStorage

    /// In-memory mirror of the Keychain, keyed by `DebridService.rawValue`. Published so Settings + any
    /// resolver UI react to changes.
    @Published private(set) var keys: [String: String] = [:]

    /// Owner scope for a device with nobody signed in. Its keys are real and usable (debrid does not require a
    /// VortX account), they simply belong to the signed-out device rather than to any account.
    static let signedOutOwner = "local"

    /// The account these in-memory keys belong to. Every Keychain read and write goes through it, so a stale
    /// value cannot leak one account's credentials to another.
    private(set) var owner: CredentialScope = .signedOutDevice
    private(set) var revision: UInt64 = 0

    /// Loads the CURRENT scope only. It must never adopt legacy state, because the singleton is constructed
    /// before `VortXSyncManager.restore()` has bound the restored account, so at this moment `owner` is still
    /// `signedOutOwner`. An earlier version adopted here and did precisely the damage the comment above warns
    /// about: an upgrading signed-in user's key was filed under the signed-out scope, their account then saw
    /// nothing, and the credential stayed readable by anyone using the device signed out. Legacy adoption is
    /// therefore a separate operation after the session layer has proved the account owner.
    init(storage: any DebridCredentialStorage = KeychainDebridCredentialStorage()) {
        self.storage = storage
        loadScope()
        publishPlaybackAvailability()
    }

    /// Point the store at an account (or at `signedOutOwner`). Call on sign-in, sign-out and account switch.
    /// Republishes and rebuilds the resolvers, so a switched-in account never keeps the previous one's keys
    /// in memory either.
    func bind(owner newOwner: CredentialScope) {
        // A provider cannot select a namespace independently of the shared account authority. This also
        // prevents a raw first-account bind from consuming global legacy state before VortX auth proves it.
        let capture = CredentialScopeRegistry.shared.capture()
        bind(owner: newOwner, capture: capture)
    }

    /// Bind using the exact owner-generation capture that the session transition just created. A delayed
    /// caller cannot bind the right account under a newer generation and publish a stale reload.
    func bind(owner newOwner: CredentialScope, capture: CredentialScopeRegistry.Capture) {
        guard capture.scope == newOwner,
              CredentialScopeRegistry.shared.isCurrent(capture) else { return }
        // A typed read failure means the new owner's credentials are unavailable, not that the owner is
        // invalid. Once the capture is still current, adopt the new owner with an empty published state so
        // an account switch can never retain the previous owner's authority.
        let loaded = readScope(for: newOwner) ?? [:]
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return }
        owner = newOwner
        revision &+= 1
        keys = loaded
        publishPlaybackAvailability()
        reloadResolvers(capture: capture)
    }

    /// Compatibility boundary for callers that still carry a raw account string. Invalid non-empty input
    /// is rejected rather than silently turning into the signed-out namespace.
    func bind(owner rawOwner: String) {
        if rawOwner.isEmpty || rawOwner == Self.signedOutOwner {
            bind(owner: .signedOutDevice)
        } else if let scope = CredentialScope(canonicalRemoteAccountID: rawOwner) {
            bind(owner: scope)
        }
    }

    /// Claim the pre-scoping global entries only after the session layer has proved the currently bound account.
    /// The registry capture is the proof: a caller cannot consume the migration opportunity merely by naming a
    /// first account, and a signed-out bind is never eligible. The claim primitive is retry-safe, so a failed
    /// destination write or source deletion remains available to a later authenticated attempt.
    @discardableResult
    func migrateLegacyIfEligible(
        owner expectedOwner: CredentialScope,
        capture: CredentialScopeRegistry.Capture
    ) -> Bool {
        guard owner == expectedOwner,
              capture.scope == expectedOwner,
              CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }

        var safe = true
        for service in DebridService.allCases {
            guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
            var result: DebridLegacyMigrationResult = .noSource
            var completed = false
            for _ in 0..<2 {
                result = migrateLegacySlot(service: service, owner: expectedOwner, capture: capture)
                switch result {
                case .noSource, .targetPresent, .migrated:
                    completed = true
                case .retryableFailure:
                    break
                }
                if completed { break }
            }
            if !completed { safe = false }
        }
        guard safe,
              owner == expectedOwner,
              CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        guard let loaded = readScope() else { return false }
        guard owner == expectedOwner,
              CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        guard loaded != keys else { return true }
        keys = loaded
        publishPlaybackAvailability()
        revision &+= 1
        reloadResolvers(capture: capture)
        return true
    }

    private func migrateLegacySlot(
        service: DebridService,
        owner: CredentialScope,
        capture: CredentialScopeRegistry.Capture
    ) -> DebridLegacyMigrationResult {
        guard owner == self.owner,
              capture.scope == owner,
              CredentialScopeRegistry.shared.isCurrent(capture) else { return .retryableFailure }

        let sourceAccount = service.legacyGlobalKeychainAccount
        let destinationAccount = service.keychainAccount(owner: owner)
        let markerAccount = sourceAccount + ".migration.owner"
        let expectedMarker = DebridLegacyMigrationMarker(
            ownerNamespace: owner.storageNamespace,
            sourceAccount: sourceAccount)

        switch storage.durableRead(markerAccount) {
        case .failure:
            return .retryableFailure
        case let .value(rawMarker):
            guard let marker = Self.decodeMigrationMarker(rawMarker), marker == expectedMarker else {
                return .retryableFailure
            }
        case .missing:
            switch storage.durableRead(sourceAccount) {
            case .failure:
                return .retryableFailure
            case .missing:
                return .noSource
            case let .value(source) where source.isEmpty:
                return .noSource
            case .value:
                guard let encoded = Self.encodeMigrationMarker(expectedMarker),
                      certifyMutation(encoded, account: markerAccount, durable: true) else {
                    return .retryableFailure
                }
            }
        }

        switch storage.durableRead(destinationAccount) {
        case .failure:
            return .retryableFailure
        case let .value(destination) where !destination.isEmpty:
            switch storage.durableRead(sourceAccount) {
            case .failure:
                return .retryableFailure
            case .missing:
                return .targetPresent
            case let .value(source) where source == destination:
                return certifyMutation(nil, account: sourceAccount, durable: true) ? .targetPresent : .retryableFailure
            case .value:
                return .retryableFailure
            }
        case .value, .missing:
            switch storage.durableRead(sourceAccount) {
            case .failure, .missing:
                return .retryableFailure
            case let .value(source) where source.isEmpty:
                return .retryableFailure
            case let .value(source):
                guard certifyMutation(source, account: destinationAccount, durable: true) else {
                    _ = certifyMutation(nil, account: destinationAccount, durable: true)
                    return .retryableFailure
                }
                guard certifyMutation(nil, account: sourceAccount, durable: true) else {
                    return .retryableFailure
                }
                return .migrated
            }
        }
    }

    private func certifyMutation(_ expected: String?, account: String, durable: Bool) -> Bool {
        guard storage.mutate(expected, for: account) == .success else { return false }
        let read = durable ? storage.durableRead(account) : storage.confirmedRead(account)
        switch read {
        case let .value(actual): return expected == actual
        case .missing: return expected == nil
        case .failure: return false
        }
    }

    private static func encodeMigrationMarker(_ marker: DebridLegacyMigrationMarker) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(marker) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeMigrationMarker(_ raw: String) -> DebridLegacyMigrationMarker? {
        guard let data = raw.data(using: .utf8),
              let marker = try? JSONDecoder().decode(DebridLegacyMigrationMarker.self, from: data),
              marker.format == DebridLegacyMigrationMarker.currentFormat else { return nil }
        return marker
    }

    /// Read the current owner's keys into memory. Pure load: it adopts nothing and writes nothing, so calling
    /// it before an owner is bound cannot consume state belonging to an account that has not restored yet.
    private func readScope(for scopedOwner: CredentialScope) -> [String: String]? {
        var next: [String: String] = [:]
        for service in DebridService.allCases {
            switch storage.confirmedRead(service.keychainAccount(owner: scopedOwner)) {
            case let .value(k) where !k.isEmpty:
                next[service.rawValue] = k
            case .value, .missing:
                break
            case .failure:
                return nil
            }
        }
        return next
    }

    private func readScope() -> [String: String]? {
        readScope(for: owner)
    }

    private func loadScope() {
        if let loaded = readScope() { keys = loaded }
    }

    private func publishPlaybackAvailability() {
        DebridPlaybackAvailability.shared.publish(
            torBoxConfigured: keys[DebridService.torBox.rawValue]?.isEmpty == false
        )
    }

    func key(for service: DebridService) -> String { keys[service.rawValue] ?? "" }
    func isConfigured(_ service: DebridService) -> Bool { !key(for: service).isEmpty }

    /// A Sendable, by-value snapshot of the current keys, keyed by `DebridService`. Hand THIS to
    /// `DebridCoordinator.reload(snapshot:)` instead of the `DebridKeys` reference: the coordinator is an actor
    /// running off the main thread, and `keys` is a plain `@Published` dictionary mutated on the main actor,
    /// so letting the actor read `keys` directly is a concurrent Dictionary read/write. Capture the snapshot
    /// on the main actor (where every writer lives) and pass the immutable copy across the isolation boundary.
    var snapshot: [DebridService: String] {
        var out: [DebridService: String] = [:]
        for service in DebridService.allCases {
            let k = key(for: service)
            if !k.isEmpty { out[service] = k }
        }
        return out
    }

    private func credentialSnapshot(capture: CredentialScopeRegistry.Capture) -> DebridCredentialSnapshot {
        DebridCredentialSnapshot(
            owner: owner,
            authorityCapture: capture,
            revision: revision,
            keys: snapshot)
    }

    var credentialSnapshot: DebridCredentialSnapshot {
        credentialSnapshot(capture: CredentialScopeRegistry.shared.capture())
    }

    /// Persist (or clear, on empty) a service's key in the Keychain and nudge the E2E sync only after the
    /// secure mutation and exact read-back are certified. A failed or unknown attempt leaves every outward
    /// value at its prior state and gets one immediate retry.
    @discardableResult
    func setKey(_ value: String, for service: DebridService) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorityCapture = CredentialScopeRegistry.shared.capture()
        guard authorityCapture.scope == owner,
              CredentialScopeRegistry.shared.isCurrent(authorityCapture) else { return false }
        let boundOwner = owner
        let account = service.keychainAccount(owner: boundOwner)
        let expected: String? = trimmed.isEmpty ? nil : trimmed
        var certified = false
        for _ in 0..<2 {
            guard owner == boundOwner,
                  CredentialScopeRegistry.shared.isCurrent(authorityCapture) else { return false }
            guard storage.mutate(expected, for: account) == .success else { continue }
            switch storage.confirmedRead(account) {
            case let .value(actual) where expected == actual:
                certified = true
            case .missing where expected == nil:
                certified = true
            case .value, .missing, .failure:
                certified = false
            }
            if certified { break }
        }
        guard certified,
              owner == boundOwner,
              CredentialScopeRegistry.shared.isCurrent(authorityCapture) else { return false }
        if let expected { keys[service.rawValue] = expected }
        else { keys.removeValue(forKey: service.rawValue) }
        publishPlaybackAvailability()
        revision &+= 1
        // Rebuild the debrid resolvers so a CHANGED key takes effect: the coordinator's lazy warm only
        // builds on first use, so it would otherwise keep using the OLD key (resolvers already non-empty).
        // Capture the fresh key snapshot HERE, synchronously on this writer's context (serialized with the
        // `keys` mutation just above), then hand the immutable value to the actor: the actor never reads the
        // `@Published` dictionary itself (that would race the main-actor writers).
        let snapshot = self.credentialSnapshot(capture: authorityCapture)
        Task {
            await DebridCoordinator.shared.reload(snapshot: snapshot)
        }
        // Nudge the E2E sync SEPARATELY, not chained behind the actor hop. Keeping it a distinct main-actor
        // task preserves the old enqueue timing: on the sync-apply path the nudge lands while
        // `withRemoteApplySuppressed` is still active, so `requestSyncSoon`'s guard swallows the self-echo.
        // Ordering vs the debounced push is irrelevant (the push reads keys at send time).
        Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }
        return true
    }

    /// Apply only the Debrid portion of a remote account document. The sync manager uses the returned failed
    /// slots as a whole-document acknowledgement gate, so a failed slot remains pending and cannot be replaced
    /// by a push of the old local dictionary.
    @discardableResult
    func applyRemoteKeys(
        _ values: [String: String],
        capture: CredentialScopeRegistry.Capture
    ) -> DebridRemoteApplyResult {
        let remoteServices = Set(values.keys.compactMap(DebridService.init(rawValue:)))
        guard owner == capture.scope,
              capture.scope == owner,
              CredentialScopeRegistry.shared.isCurrent(capture) else {
            return DebridRemoteApplyResult(failedServices: remoteServices)
        }
        var failedServices: Set<DebridService> = []
        for service in DebridService.allCases {
            guard let value = values[service.rawValue] else { continue }
            guard CredentialScopeRegistry.shared.isCurrent(capture), owner == capture.scope else {
                failedServices.formUnion(remoteServices)
                break
            }
            if value != key(for: service), !setKey(value, for: service) {
                failedServices.insert(service)
            }
        }
        return DebridRemoteApplyResult(failedServices: failedServices)
    }

    private func reloadResolvers(capture: CredentialScopeRegistry.Capture) {
        let snapshot = credentialSnapshot(capture: capture)
        Task {
            await DebridCoordinator.shared.reload(snapshot: snapshot)
        }
    }

    /// A SecureField binding that persists on edit (same UX as the metadata-key fields).
    func binding(for service: DebridService) -> Binding<String> {
        Binding(get: { [weak self] in self?.key(for: service) ?? "" },
                set: { [weak self] in self?.setKey($0, for: service) })
    }

    /// Services with a key set, in preference order (Real-Debrid first, the most common).
    var configuredServices: [DebridService] { DebridService.allCases.filter(isConfigured) }
    var hasAnyKey: Bool { !configuredServices.isEmpty }

    /// The first configured service + key, for the single-debrid resolve path the resolver layer uses.
    var primary: (service: DebridService, key: String)? {
        configuredServices.first.map { ($0, key(for: $0)) }
    }
}

/// Settings screen to add or remove debrid API keys, one secure field per service. Mirrors
/// `MetadataKeysView`. Shared by the tvOS and iOS Settings screens.
#if !DEBRID_CREDENTIAL_SECURITY_TESTS
struct DebridKeysView: View {
    @ObservedObject private var debrid = DebridKeys.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Debrid services").screenTitleStyle()
                Text("Add your debrid API keys here. They stay on this device and sync, encrypted, to your VortX account. Cached torrents now play instantly straight from your debrid account, and adding more than one service checks them all at once.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                ForEach(DebridService.allCases) { service in
                    keyField(service)
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    @ViewBuilder private func keyField(_ service: DebridService) -> some View {
        let text = debrid.binding(for: service)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(service.displayName).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if !text.wrappedValue.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.accent)
                }
            }
            // Masked like a password: debrid keys are credentials (Bug 3).
            SecureField("Paste your API key", text: text)
                .font(.system(size: 15, design: .monospaced))
                #if os(iOS)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Text(service.hint).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }
}
#endif
