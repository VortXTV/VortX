import SwiftUI

/// A debrid service VortX can hold an API key for. A debrid key turns cached torrents into instant
/// direct links; the roadmap's "in-app debrid" means the user pastes the key ONCE here, with no separate
/// add-on configuration site.
enum DebridService: String, CaseIterable, Identifiable {
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
    func keychainAccount(owner: String) -> String { "vortx.debrid." + rawValue + "." + owner }

    /// The pre-scoping global entry. Read once so an existing user does not have to re-paste, then removed.
    /// Never written.
    var legacyGlobalKeychainAccount: String { "vortx.debrid." + rawValue }
}

/// The user's debrid API keys. Keychain-backed (they are credentials) and synced end-to-end to the
/// VortX account, so one key reaches every Apple device, no per-device re-paste. Mirrors `ApiKeys`.
/// This is the foundation of native in-app debrid: the resolver/cache-check layers read keys from here.
final class DebridKeys: ObservableObject {
    static let shared = DebridKeys()

    /// In-memory mirror of the Keychain, keyed by `DebridService.rawValue`. Published so Settings + any
    /// resolver UI react to changes.
    @Published private(set) var keys: [String: String] = [:]

    /// Owner scope for a device with nobody signed in. Its keys are real and usable (debrid does not require a
    /// VortX account), they simply belong to the signed-out device rather than to any account.
    static let signedOutOwner = "local"

    /// The account these in-memory keys belong to. Every Keychain read and write goes through it, so a stale
    /// value cannot leak one account's credentials to another.
    private(set) var owner: String = DebridKeys.signedOutOwner

    /// Legacy adoption happens exactly once, at the FIRST binding, and never again. Deliberately not at init:
    /// at init the signed-in account is not yet restored, so adopting then would file an existing user's keys
    /// under the signed-out scope and make them vanish the moment their session restored. The first binding is
    /// the earliest point at which the device's real owner is known.
    private var hasConsideredLegacy = false

    /// Loads the CURRENT scope only. It must never adopt legacy state, because the singleton is constructed
    /// before `VortXSyncManager.restore()` has bound the restored account, so at this moment `owner` is still
    /// `signedOutOwner`. An earlier version adopted here and did precisely the damage the comment above warns
    /// about: an upgrading signed-in user's key was filed under the signed-out scope, their account then saw
    /// nothing, and the credential stayed readable by anyone using the device signed out. Adoption is now the
    /// sole responsibility of `bind(owner:)`, which is the first point an explicit owner exists.
    private init() { loadScope() }

    /// Point the store at an account (or at `signedOutOwner`). Call on sign-in, sign-out and account switch.
    /// Republishes and rebuilds the resolvers, so a switched-in account never keeps the previous one's keys
    /// in memory either.
    func bind(owner newOwner: String) {
        let resolved = newOwner.isEmpty ? Self.signedOutOwner : newOwner
        guard resolved != owner || !hasConsideredLegacy else { return }
        owner = resolved
        adoptLegacyIfNeeded()
        loadScope()
        let snapshot = self.snapshot
        Task { await DebridCoordinator.shared.reload(keys: snapshot) }
    }

    /// Move the pre-scoping global entries into the CURRENT owner's scope, once per process, and only where
    /// that owner has no key of its own so an adoption can never overwrite one the account already had. The
    /// legacy entry is deleted as it is moved, so a second account cannot inherit the same credential.
    ///
    /// Called ONLY from `bind(owner:)`. That is the invariant: adoption requires an explicitly bound owner, so
    /// a credential can never be filed under a scope that merely happens to be the default at construction.
    private func adoptLegacyIfNeeded() {
        guard !hasConsideredLegacy else { return }
        hasConsideredLegacy = true
        for service in DebridService.allCases {
            let scoped = service.keychainAccount(owner: owner)
            guard Keychain.string(scoped)?.isEmpty != false,
                  let legacy = Keychain.string(service.legacyGlobalKeychainAccount), !legacy.isEmpty
            else { continue }
            Keychain.set(legacy, for: scoped)
            Keychain.set(nil, for: service.legacyGlobalKeychainAccount)
        }
    }

    /// Read the current owner's keys into memory. Pure load: it adopts nothing and writes nothing, so calling
    /// it before an owner is bound cannot consume state belonging to an account that has not restored yet.
    private func loadScope() {
        var next: [String: String] = [:]
        for service in DebridService.allCases {
            if let k = Keychain.string(service.keychainAccount(owner: owner)), !k.isEmpty {
                next[service.rawValue] = k
            }
        }
        keys = next
    }

    func key(for service: DebridService) -> String { keys[service.rawValue] ?? "" }
    func isConfigured(_ service: DebridService) -> Bool { !key(for: service).isEmpty }

    /// A Sendable, by-value snapshot of the current keys, keyed by `DebridService`. Hand THIS to
    /// `DebridCoordinator.reload(keys:)` instead of the `DebridKeys` reference: the coordinator is an actor
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

    /// Persist (or clear, on empty) a service's key in the Keychain and nudge the E2E sync.
    func setKey(_ value: String, for service: DebridService) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keys.removeValue(forKey: service.rawValue)
            Keychain.set(nil, for: service.keychainAccount(owner: owner))
        } else {
            keys[service.rawValue] = trimmed
            Keychain.set(trimmed, for: service.keychainAccount(owner: owner))
        }
        // Rebuild the debrid resolvers so a CHANGED key takes effect: the coordinator's lazy warm only
        // builds on first use, so it would otherwise keep using the OLD key (resolvers already non-empty).
        // Capture the fresh key snapshot HERE, synchronously on this writer's context (serialized with the
        // `keys` mutation just above), then hand the immutable value to the actor: the actor never reads the
        // `@Published` dictionary itself (that would race the main-actor writers).
        let snapshot = self.snapshot
        Task { await DebridCoordinator.shared.reload(keys: snapshot) }
        // Nudge the E2E sync SEPARATELY, not chained behind the actor hop. Keeping it a distinct main-actor
        // task preserves the old enqueue timing: on the sync-apply path the nudge lands while
        // `withRemoteApplySuppressed` is still active, so `requestSyncSoon`'s guard swallows the self-echo.
        // Ordering vs the debounced push is irrelevant (the push reads keys at send time).
        Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }
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
