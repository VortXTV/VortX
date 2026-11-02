import SwiftUI

/// Account recovery remains reachable before opening a profile. The manager owns
/// credential persistence, cancellation, retries and the eventual signed-out state.
struct ProfilePickerAccountControls: View {
    @ObservedObject private var sync = VortXSyncManager.shared
    let onSignIn: () -> Void
    let beforeConfirmedSignOut: () -> Void
    @State private var confirmingSignOut = false
    @State private var signOutAccountID: String?
    @State private var signOutCredential: CredentialScopeRegistry.Capture?

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            if sync.isSignedIn, let account = sync.account {
                Text("@\(account.username)")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            HStack(spacing: Theme.Space.md) {
                if sync.accountReconnectRequired {
                    Button("Sign in again", action: onSignIn)
                        .buttonStyle(ChipButtonStyle())
                }
                Button(sync.isSignedIn ? "Sign out" : "Sign in") {
                    if sync.isSignedIn, let account = sync.account {
                        signOutAccountID = account.id
                        signOutCredential = CredentialScopeRegistry.shared.capture()
                        confirmingSignOut = true
                    } else { onSignIn() }
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityIdentifier("profile-picker-login-logout")
            }
        }
        .confirmationDialog("Sign out of your VortX account?", isPresented: $confirmingSignOut,
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                guard let capture = signOutCredential,
                      CredentialScopeRegistry.shared.isCurrent(capture),
                      sync.isSignedIn, sync.account?.id == signOutAccountID else { return }
                beforeConfirmedSignOut()
                // Retiring picker presentation is not permission to affect a new session.
                guard CredentialScopeRegistry.shared.isCurrent(capture),
                      sync.isSignedIn, sync.account?.id == signOutAccountID else { return }
                sync.signOut()
                signOutAccountID = nil
                signOutCredential = nil
            }
            Button("Cancel", role: .cancel) {
                signOutAccountID = nil
                signOutCredential = nil
            }
        } message: {
            Text("This signs out this device. It does not delete your VortX account.")
        }
        .onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in
            confirmingSignOut = false
            signOutAccountID = nil
            signOutCredential = nil
        }
    }
}
