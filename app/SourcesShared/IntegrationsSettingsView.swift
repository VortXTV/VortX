import SwiftUI

/// "Integrations" screen: OPTIONAL imports and services that enrich VortX. VortX owns its own account,
/// add-ons, and library (see SyncSettingsView); nothing here is required, and connecting any of these
/// never turns VortX into a client of that service. Order, top to bottom:
///   1. Stremio: bring your Stremio add-ons and library in (StremioConnectCard, reuses LinkLoginView).
///   2. Trakt: scrobble + watchlist (existing card, via ExternalServicesSettingsView).
///   3. SIMKL: mark-watched + plan-to-watch (existing card, via ExternalServicesSettingsView).
///   4. Nuvio: bring the Stremio-compatible add-on(s) you use in Nuvio in (NuvioConnectCard, opens
///      NuvioImportView). Nuvio has no account/sync service of its own, so unlike Stremio there is
///      nothing to sign into; the card just opens the paste-URL importer.
///
/// Cross-platform (iPhone / iPad / Mac / Apple TV): hosted here in SourcesShared and pushed from both the
/// iOS and tvOS settings screens, so both surfaces get the same section by construction (settings parity).
struct IntegrationsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Integrations").screenTitleStyle()
                Text("Optional imports and services that enrich VortX. Connect what you already use; VortX keeps its own account, add-ons, and library either way.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                // 1. Stremio, up front as one optional source among the rest.
                StremioConnectCard()

                // 2 + 3. Trakt then SIMKL, reused as-is (each still dormant until its build creds exist).
                ExternalServicesSettingsView()

                // 4. Nuvio: opens the paste-URL importer (WS6).
                NuvioConnectCard()
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

/// "Nuvio" card for the Integrations screen: opens `NuvioImportView`, the paste-URL import for bringing a
/// Nuvio user's Stremio-compatible add-on(s) into VortX. Styled to match the Stremio/Trakt/SIMKL cards
/// (surface1, rounded, same title/body type). Unlike those three, Nuvio has no account or sign-in state to
/// reflect here (see NuvioImportView's header comment for why), so this is a plain NavigationLink card
/// rather than an inline connect/disconnect control, matching the AddonsView "Discover add-ons" link.
private struct NuvioConnectCard: View {
    var body: some View {
        NavigationLink { NuvioImportView() } label: {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Text("Nuvio").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
                }
                Text("Bring the Stremio-compatible add-on you use in Nuvio into VortX. This is optional and separate from your VortX account.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
