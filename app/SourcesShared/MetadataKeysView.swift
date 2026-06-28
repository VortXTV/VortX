import SwiftUI

/// Enter optional TMDB and MDBList keys (stored in the Keychain via ApiKeys). Both are optional and
/// only enrich recommendations and ratings; VortX works fully without them. Cross-platform.
struct MetadataKeysView: View {
    @ObservedObject private var keys = ApiKeys.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Metadata services").screenTitleStyle()
                Text("Optional. Add your own TMDB and MDBList keys to enrich recommendations and ratings. Add a SkipDB key to submit and correct skip segments from the player. Keys stay on this device (and sync, encrypted, to your VortX account).")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                keyField("TMDB", text: $keys.tmdb, hint: "Free at themoviedb.org, Settings then API.")
                keyField("MDBList", text: $keys.mdblist, hint: "Free at mdblist.com, Preferences then API.")
                keyField("SkipDB", text: $keys.skipdb, hint: "Create an account at skipdb.tv, then generate an API key in Account settings.")
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    @ViewBuilder private func keyField(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if !text.wrappedValue.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.accent)
                }
            }
            // Masked like a password (Bug 3): keys are credentials.
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
}
