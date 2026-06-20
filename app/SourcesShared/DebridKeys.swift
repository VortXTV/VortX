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

    /// Keychain account this service's key is stored under (credentials, never UserDefaults).
    var keychainAccount: String { "vortx.debrid." + rawValue }
}

/// The user's debrid API keys. Keychain-backed (they are credentials) and synced end-to-end to the
/// VortX account, so one key reaches every Apple device, no per-device re-paste. Mirrors `ApiKeys`.
/// This is the foundation of native in-app debrid: the resolver/cache-check layers read keys from here.
final class DebridKeys: ObservableObject {
    static let shared = DebridKeys()

    /// In-memory mirror of the Keychain, keyed by `DebridService.rawValue`. Published so Settings + any
    /// resolver UI react to changes.
    @Published private(set) var keys: [String: String] = [:]

    private init() {
        for service in DebridService.allCases {
            if let k = Keychain.string(service.keychainAccount), !k.isEmpty {
                keys[service.rawValue] = k
            }
        }
    }

    func key(for service: DebridService) -> String { keys[service.rawValue] ?? "" }
    func isConfigured(_ service: DebridService) -> Bool { !key(for: service).isEmpty }

    /// Persist (or clear, on empty) a service's key in the Keychain and nudge the E2E sync.
    func setKey(_ value: String, for service: DebridService) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keys.removeValue(forKey: service.rawValue)
            Keychain.set(nil, for: service.keychainAccount)
        } else {
            keys[service.rawValue] = trimmed
            Keychain.set(trimmed, for: service.keychainAccount)
        }
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
                Text("Add your debrid API key once and VortX uses it everywhere, with no separate configuration site. Cached torrents resolve to instant direct links. Your keys stay on this device and sync, encrypted, to your VortX account.")
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
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
