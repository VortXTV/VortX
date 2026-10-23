import SwiftUI

/// "Stremio" card for the Integrations screen: connect a Stremio account as an OPTIONAL source that
/// brings your Stremio add-ons and library into VortX. It is NOT a login to VortX; VortX owns its own
/// account (see SyncSettingsView). This card matches the Trakt/SIMKL card styling and REUSES the shared
/// `LinkLoginView` (QR + code) for the actual sign-in, so it never duplicates the sign-in UI that WS2
/// owns in LoginView / iOSSignInView.
///
/// Cross-platform (iPhone / iPad / Mac / Apple TV): mounted inside `IntegrationsSettingsView`, which both
/// the iOS and tvOS settings screens push to, so both surfaces get it by construction (settings parity).
struct StremioConnectCard: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge

    /// Reveals the shared QR/code panel inline while a connect is in flight.
    @State private var connecting = false
    /// Run the post-sign-in engine seed + owned-addon snapshot exactly once (parity with LoginView's
    /// latch): `@Published isSignedIn` re-publishes on every assignment, so an unlatched sink could
    /// re-enter on a later republish.
    @State private var didHandleSignIn = false

    var body: some View {
        StremioProviderCard {
            Text("Stremio").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            if connecting {
                // Keep retry UI mounted even if a partial import saved the credential already.
                LinkLoginView(account: account)
                Button("Cancel") { connecting = false }
                    .buttonStyle(ChipButtonStyle(selected: false))
            } else if account.isSignedIn {
                Text(account.signInError == nil ? "Connected" : "Connection needs attention")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                if let warning = account.signInError {
                    Text(warning).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                    Button("Retry connection") { connecting = true }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
                if let email = account.email, !email.isEmpty {
                    Text(email).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                }
                Text("\(account.addons.count) add-ons · \(account.streamAddonBases.count) stream sources")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                Button("Disconnect") { disconnect() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            } else {
                Text("Bring your Stremio add-ons and library into VortX. This is optional and separate from your VortX account.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                Button("Connect Stremio") { connecting = true }
                    .buttonStyle(PrimaryActionStyle())
            }
        }
        // The link auth path finishes through StremioAccount.isSignedIn (LinkLoginView calls
        // signInWithAuthKey). Mirror LoginView's post-sign-in handoff so connecting Stremio HERE actually
        // seeds the engine and snapshots the imported add-ons into the VortX account doc, instead of just
        // flipping a flag. Never-zero guarded inside the manager if the pull is still empty.
        .onReceive(account.$isSignedIn) { signedIn in
            handleStremioSignIn(signedIn: signedIn)
        }
        .onChange(of: account.credentialBoundaryGeneration) { _ in
            handleStremioSignIn(signedIn: account.isSignedIn)
        }
        .onChange(of: account.isSignedIn) { signedIn in
            // Re-arm the one-shot latch after a disconnect so a later reconnect runs the handoff again.
            if !signedIn { didHandleSignIn = false }
        }
    }

    private func handleStremioSignIn(signedIn: Bool) {
        guard signedIn, account.signInError == nil, !didHandleSignIn else { return }
        didHandleSignIn = true
        connecting = false
        core.signedInWithLegacyAuthKey()
        Task { @MainActor in
            await core.awaitAddonsHydrated()
            await VortXSyncManager.shared.snapshotOwnedFromEngine()
        }
    }

    private func disconnect() {
        account.signOut()
        core.logOut()
        connecting = false
    }
}

/// Card surface matching the Trakt/SIMKL provider cards (surface1, rounded). Kept local to this file so
/// it stays in sync with the account-card styling without reaching into ExternalServicesSettingsView's
/// private helper.
private struct StremioProviderCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) { content }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard()
    }
}
