import SwiftUI

// CREDENTIAL_OWNER_IDENTITY_BEGIN
/// Validates the identity used to scope credentials and account-local sync state.
///
/// H7 (INS-260722-06R): remote account identity is ONE rule, shared with `DebridOwnerScope.canonicalAccount`:
/// an EXACT lowercase hyphenated UUID that round-trips through Foundation's parser. The server mints account
/// ids with `crypto.randomUUID()` (already exact lowercase), so every real account passes unchanged, while
/// uppercase, braced, compact, padded, or otherwise malformed remote identities FAIL CLOSED (never adopted,
/// never made into a Keychain/UserDefaults namespace). `deviceOwnerID` remains the explicit signed-out scope
/// and can never be aliased by a remote value (a UUID can never equal "local").
enum CredentialOwnerIdentity {
    static let deviceOwnerID = "local"

    /// An explicitly-bindable owner id: the reserved signed-out device scope, or a canonical remote account id.
    static func explicitOwnerID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw == deviceOwnerID { return raw }
        return remoteAccountID(raw)
    }

    /// The canonical remote account id, or nil (fail closed) for anything that is not an exact lowercase
    /// hyphenated UUID round-trip. Delegates to the single shared rule in `DebridOwnerScope.canonicalAccount`.
    static func remoteAccountID(_ raw: String?) -> String? {
        guard let raw, case .account(let uuid) = DebridOwnerScope.canonicalAccount(raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    static func accountNamespace(prefix: String, accountID: String?) -> String? {
        guard let owner = remoteAccountID(accountID) else { return nil }
        return prefix + owner
    }
}
// CREDENTIAL_OWNER_IDENTITY_END

/// The user's debrid API keys. Keychain-backed (they are credentials) and synced end-to-end to the
/// VortX account, so one key reaches every Apple device, no per-device re-paste. Mirrors `ApiKeys`.
/// This is the foundation of native in-app debrid: the resolver/cache-check layers read keys from here.
@MainActor
final class DebridKeys: ObservableObject {
    static let shared = DebridKeys()

    /// Main-actor mirror of the current immutable state. Published so Settings and resolver UI react.
    @Published private(set) var keys: [DebridService: String]

    /// A durable write failure is visible to the settings surface. Memory and sync remain on the last committed
    /// generation, so this never reports a value that will disappear or reactivate after relaunch.
    @Published private(set) var persistenceError: String?

    private var state: DebridCredentialMutableState

    var owner: DebridOwnerScope { state.owner }
    var revision: UInt64 { state.revision }

    private static var storageIO: DebridCredentialStorageIO {
        DebridCredentialStorageIO(
            read: Keychain.string,
            write: { value, account in Keychain.set(value, for: account) },
            delete: { account in Keychain.set(nil, for: account) }
        )
    }

    /// The snapshot store performs the synchronous signed-out bootstrap. Reusing its exact snapshot here avoids
    /// a second owner that could transiently publish an empty device scope.
    private init() {
        let initial = DebridCredentialSnapshotStore.shared.load()
        state = DebridCredentialMutableState(snapshot: initial)
        keys = state.keys
        persistenceError = nil
    }

    /// Bind a validated typed owner. Migration and full-scope load complete before one revision is published.
    func bind(owner newOwner: DebridOwnerScope) {
        migrateIfNeeded(for: newOwner)
        let loaded = Self.loadScope(owner: newOwner)
        guard let snapshot = state.replace(owner: newOwner, keys: loaded) else { return }
        publish(snapshot)
    }

    /// Raw canonical-account sources are considered on every account bind. Each global source has one permanent
    /// owner claim, so the first explicit bind remains authoritative across process death and delete failure.
    private func migrateIfNeeded(for owner: DebridOwnerScope) {
        let io = Self.storageIO
        func targetKeys() -> [DebridService: String] {
            DebridCredentialPersistence.committedKeys(owner: owner, read: io.read)
        }
        func commitTarget(_ keys: [DebridService: String]) -> Bool {
            DebridCredentialPersistence.commit(owner: owner, keys: keys, io: io).succeeded
        }

        for service in DebridService.allCases {
            if case .account(let uuid) = owner {
                // The exact prior artifact's v2 slot is checked first, then the shipped raw account slot.
                let sources = [
                    service.keychainAccount(owner: owner),
                    service.legacyRawAccountKeychainAccount(uuid),
                ]
                for source in sources {
                    _ = DebridCredentialMigration.migrate(
                        service: service,
                        owner: owner,
                        sourceAccount: source,
                        claimAccount: nil,
                        targetKeys: targetKeys,
                        commitTarget: commitTarget,
                        read: io.read,
                        write: io.write,
                        delete: io.delete
                    )
                }
            }

            _ = DebridCredentialMigration.migrate(
                service: service,
                owner: owner,
                sourceAccount: service.legacyGlobalKeychainAccount,
                claimAccount: DebridCredentialMigration.globalClaimAccount(for: service),
                targetKeys: targetKeys,
                commitTarget: commitTarget,
                read: io.read,
                write: io.write,
                delete: io.delete
            )
        }
    }

    private static func loadScope(owner: DebridOwnerScope) -> [DebridService: String] {
        DebridCredentialPersistence.loadKeys(owner: owner, read: Keychain.string)
    }

    func key(for service: DebridService) -> String { keys[service] ?? "" }
    func isConfigured(_ service: DebridService) -> Bool { !key(for: service).isEmpty }

    var snapshot: DebridCredentialSnapshot { state.snapshot }

    /// Persist one complete owner envelope first. Publish and sync only after the new generation's exact
    /// envelope and commit marker both read back byte-identically.
    @discardableResult
    func setKey(_ value: String, for service: DebridService) -> Bool {
        let io = Self.storageIO
        let currentOwner = owner
        let result = DebridCredentialDurableMutation.setKey(
            value,
            for: service,
            state: &state,
            persist: { keys in
                DebridCredentialPersistence.commit(owner: currentOwner, keys: keys, io: io).succeeded
            }
        )
        switch result {
        case .unchanged:
            persistenceError = nil
            return true
        case .persistenceFailed:
            persistenceError = "Could not save debrid credentials. Your previous saved keys are still active."
            return false
        case .committed(let snapshot):
            persistenceError = nil
            publish(snapshot)
            Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }
            return true
        }
    }

    /// Apply a remote document atomically. This path intentionally never schedules sync, so a remote pull
    /// cannot echo itself even after the surrounding suppression window drains.
    @discardableResult
    func applyRemoteKeys(_ remote: [DebridService: String]) -> Bool {
        let io = Self.storageIO
        let currentOwner = owner
        let result = DebridCredentialDurableMutation.applyRemoteKeys(
            remote,
            state: &state,
            persist: { keys in
                DebridCredentialPersistence.commit(owner: currentOwner, keys: keys, io: io).succeeded
            }
        )
        switch result {
        case .unchanged:
            persistenceError = nil
            return true
        case .persistenceFailed:
            persistenceError = "Could not apply synced debrid credentials. The previous generation remains active."
            return false
        case .committed(let snapshot):
            persistenceError = nil
            publish(snapshot)
            return true
        }
    }

    private func publish(_ snapshot: DebridCredentialSnapshot) {
        precondition(DebridCredentialSnapshotStore.shared.publish(snapshot))
        keys = snapshot.keys
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
                if let error = debrid.persistenceError {
                    Text(error)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.danger)
                }
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
