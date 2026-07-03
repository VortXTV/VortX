import SwiftUI

/// Enter optional TMDB, MDBList, and fanart.tv keys (stored in the Keychain via ApiKeys). All are optional and
/// only enrich recommendations, ratings, and artwork; VortX works fully without them. The SkipDB key + the
/// custom skip provider live on their own `SkipKeysView`, reached from the Skip settings. Cross-platform.
struct MetadataKeysView: View {
    @ObservedObject private var keys = ApiKeys.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Metadata services").screenTitleStyle()
                Text("Optional. Add your own TMDB, MDBList, and fanart.tv keys to enrich recommendations, ratings, and artwork. Nothing here is required, and your keys stay on this device (and sync, encrypted, to your VortX account).")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                metaKeyField("TMDB", text: $keys.tmdb, hint: "Free at themoviedb.org, Settings then API.")
                metaKeyField("MDBList", text: $keys.mdblist, hint: "Free at mdblist.com, Preferences then API.")
                metaKeyField("fanart.tv", text: $keys.fanart, hint: "Free at fanart.tv, your profile then API.")
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

/// The SkipDB key + an optional custom SkipDB-compatible provider, reached from the Skip settings right next to
/// the "Skip timestamps source" setting (moved out of the Metadata screen). Skip editing works with no key here;
/// these only share your edits back and unlock more reads.
struct SkipKeysView: View {
    @ObservedObject private var keys = ApiKeys.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Skip database").screenTitleStyle()
                Text("Optional. A SkipDB key shares your skip-segment edits back to the community database and unlocks its reads. Skip editing works without it, and your key stays on this device (and syncs, encrypted, to your VortX account).")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                metaKeyField("SkipDB", text: $keys.skipdb, hint: "Optional. Create an account at skipdb.tv, then generate an API key in Account settings to also share edits there.")

                Text("Custom skip provider").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.top, Theme.Space.md)
                Text("Optional. A SkipDB-compatible endpoint (e.g. a self-hosted mirror) to also read from and contribute to. Submissions go to VortX, skipdb.tv (if keyed), and this, all at once.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                metaURLField("Provider URL", text: $keys.customSkipURL, hint: "Base URL only, e.g. https://my-mirror.example")
                metaKeyField("Provider API key", text: $keys.customSkipKey, hint: "Optional. Leave blank if the provider is keyless.")
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

// MARK: - Shared field builders (fileprivate free functions so both screens reuse them)

/// A masked credential field (keys are credentials, Bug 3).
@ViewBuilder fileprivate func metaKeyField(_ title: String, text: Binding<String>, hint: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.sm) {
        HStack {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            if !text.wrappedValue.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.accent)
            }
        }
        SecureField("Paste your key", text: text)
            .font(.system(size: 15, design: .monospaced))
            #if os(iOS)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            #endif
        Text(hint).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
    }
    .padding(Theme.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
}

/// A plain (non-masked) field: a base URL is configuration, not a credential.
@ViewBuilder fileprivate func metaURLField(_ title: String, text: Binding<String>, hint: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.sm) {
        HStack {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            if !text.wrappedValue.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.accent)
            }
        }
        TextField("https://", text: text)
            .font(.system(size: 15, design: .monospaced))
            #if os(iOS)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            #endif
        Text(hint).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
    }
    .padding(Theme.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
}
