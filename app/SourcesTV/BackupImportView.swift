import SwiftUI

/// tvOS "Restore": bring a VortX account's data (profiles, add-ons, library, watch history) onto this
/// Apple TV by scanning a QR with a phone or browser already signed in to VortX.
///
/// This is the RESTORE direction, and it reuses VortXAccountJoinerView AS-IS. That view's onSignedIn
/// already runs reconcileAfterSignIn -> useAccountData -> hydrateEngineFromOwnedAddons
/// (VortXAccountJoinerView.swift pollLoop, ~:95-98), i.e. it PULLS the account's data down onto a fresh
/// install, which is exactly what restore wants. The only thing added here is the framing/label.
///
/// The QR carries only a ~100-150 byte pairing URL (the short code plus this TV's ephemeral public key);
/// the actual data rides HTTPS through VortXSyncManager's sync doc, never through the QR.
struct BackupImportView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Text("Restore").screenTitleStyle()
            Text("Scan the code below on a phone or browser signed in to VortX to bring your profiles, add-ons, library, and watch history onto this Apple TV.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 660)
            VortXAccountJoinerView(onSignedIn: { dismiss() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}
