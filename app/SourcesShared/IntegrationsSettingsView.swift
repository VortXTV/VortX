import SwiftUI

/// "Integrations" screen: OPTIONAL imports and services that enrich VortX. VortX owns its own account,
/// add-ons, and library (see SyncSettingsView); nothing here is required, and connecting any of these
/// never turns VortX into a client of that service. Order, top to bottom:
///   1. Stremio: bring your Stremio add-ons and library in (StremioConnectCard, reuses LinkLoginView).
///   2. Trakt: scrobble + watchlist (existing card, via ExternalServicesSettingsView).
///   3. SIMKL: mark-watched + plan-to-watch (existing card, via ExternalServicesSettingsView).
///   4. Nuvio: placeholder for the upcoming import (WS6 fills it; graceful stub, no dead button).
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

                // 4. Nuvio placeholder: clearly marked, informative, and inert (WS6 wires the real import).
                NuvioPlaceholderCard()
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

/// Graceful stub for the upcoming Nuvio import. No action yet: it states what is coming instead of
/// offering a button that does nothing, so it never reads as a broken control.
private struct NuvioPlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("Nuvio").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text("Coming soon")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 4)
                    .background(Theme.Palette.surface2, in: Capsule())
            }
            Text("Import your Nuvio catalogs and sources into VortX. This is on the way; there is nothing to set up yet.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
