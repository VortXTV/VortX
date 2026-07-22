import SwiftUI

/// The user's debrid API keys. Keychain-backed (they are credentials) and synced end-to-end to the
/// VortX account, so one key reaches every Apple device, no per-device re-paste. Mirrors `ApiKeys`.
/// This is the foundation of native in-app debrid: the resolver/cache-check layers read keys from here.
@MainActor
final class DebridKeys: ObservableObject {
    static let shared = DebridKeys()

    /// Main-actor mirror of the current immutable state. Published so Settings and resolver UI react.
    @Published private(set) var keys: [DebridService: String]

    private var state: DebridCredentialMutableState

    var owner: DebridOwnerScope { state.owner }
    var revision: UInt64 { state.revision }

    /// Global legacy adoption retains the shipped first-explicit-bind rule. Raw account-scope migration is
    /// separate and is retried independently for every canonical account.
    private var hasConsideredGlobalLegacy = false

    /// Initialization reads only the permanent device-local scope. It never adopts a global or account source.
    private init() {
        let initialOwner = DebridOwnerScope.signedOutDevice
        let initialKeys = Self.loadScope(owner: initialOwner)
        state = DebridCredentialMutableState(owner: initialOwner, keys: initialKeys)
        keys = state.keys
        precondition(DebridCredentialSnapshotStore.shared.publish(state.snapshot))
    }

    /// Bind a validated typed owner. Migration and full-scope load complete before one revision is published.
    func bind(owner newOwner: DebridOwnerScope) {
        migrateIfNeeded(for: newOwner)
        let loaded = Self.loadScope(owner: newOwner)
        guard let snapshot = state.replace(owner: newOwner, keys: loaded) else { return }
        publish(snapshot)
    }

    /// Raw canonical-account sources are considered on every account bind. The global source is considered
    /// only on the first explicit bind. A source survives every failed or conflicting migration.
    private func migrateIfNeeded(for owner: DebridOwnerScope) {
        let includeGlobal = !hasConsideredGlobalLegacy
        for service in DebridService.allCases {
            let target = service.keychainAccount(owner: owner)
            var sources: [String] = []
            if case .account(let uuid) = owner {
                sources.append(service.legacyRawAccountKeychainAccount(uuid))
            }
            if includeGlobal { sources.append(service.legacyGlobalKeychainAccount) }
            _ = DebridCredentialMigration.migrateFirstAvailable(
                target: target,
                sources: sources,
                read: Keychain.string,
                write: { value, account in Keychain.set(value, for: account) },
                delete: { account in Keychain.set(nil, for: account) }
            )
        }
        if includeGlobal { hasConsideredGlobalLegacy = true }
    }

    private static func loadScope(owner: DebridOwnerScope) -> [DebridService: String] {
        var next: [DebridService: String] = [:]
        for service in DebridService.allCases {
            if let k = Keychain.string(service.keychainAccount(owner: owner)), !k.isEmpty {
                next[service] = k
            }
        }
        return next
    }

    func key(for service: DebridService) -> String { keys[service] ?? "" }
    func isConfigured(_ service: DebridService) -> Bool { !key(for: service).isEmpty }

    var snapshot: DebridCredentialSnapshot { state.snapshot }

    /// Persist (or clear, on empty) a service's key in the Keychain and nudge the E2E sync.
    func setKey(_ value: String, for service: DebridService) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = Keychain.set(trimmed.isEmpty ? nil : trimmed, for: service.keychainAccount(owner: owner))
        guard let snapshot = state.setKey(trimmed, for: service) else { return }
        publish(snapshot)
        Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }
    }

    /// Apply a remote document atomically. This path intentionally never schedules sync, so a remote pull
    /// cannot echo itself even after the surrounding suppression window drains.
    func applyRemoteKeys(_ remote: [DebridService: String]) {
        var normalized: [DebridService: String] = [:]
        for (service, value) in remote {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized[service] = trimmed
            guard trimmed != key(for: service) else { continue }
            _ = Keychain.set(trimmed.isEmpty ? nil : trimmed, for: service.keychainAccount(owner: owner))
        }
        guard let snapshot = state.applyRemoteKeys(normalized) else { return }
        publish(snapshot)
    }

    private func publish(_ snapshot: DebridCredentialSnapshot) {
        keys = snapshot.keys
        precondition(DebridCredentialSnapshotStore.shared.publish(snapshot))
        Task { await DebridCoordinator.shared.reload(snapshot: snapshot) }
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
