import SwiftUI

/// tvOS sign-in for a Stremio account. Link login is the default so passwords are entered on
/// Stremio's own web flow; password login remains available as a fallback.
struct LoginView: View {
    @ObservedObject var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .link
    @State private var email = ""
    @State private var password = ""
    @State private var passwordBusy = false
    // Run the sign-in handoff exactly once. `@Published` re-publishes on every assignment, so a
    // future unconditional `isSignedIn = true` could otherwise re-enter this sink in a loop (the bug
    // that froze the iOS sign-in). Parity with iOSSignInView's latch — defensive, costs nothing.
    @State private var didHandleSignIn = false

    private enum Mode { case link, password }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                VortXWordmark(fontSize: 54)

                Text(mode == .link
                     ? "Scan the QR code or enter the code on another device to sign in."
                     : "Sign in to your Stremio account to load your addons and streams.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)

                if mode == .link { LinkLoginView(account: account) }
                else { passwordLogin }

                Button {
                    switchMode()
                } label: {
                    Text(mode == .link ? "Use password instead" : "Use QR code instead")
                        .frame(width: 320)
                }
                .buttonStyle(ChipButtonStyle())
            }
            .padding(Theme.Space.screenEdge)
        }
        .onReceive(account.$isSignedIn) { signedIn in
            guard signedIn, !didHandleSignIn else { return }
            didHandleSignIn = true
            core.signedInWithLegacyAuthKey()   // seed the engine now, not on next launch
            dismiss()
        }
    }

    private var passwordLogin: some View {
        VStack(spacing: Theme.Space.md) {
            field { TextField("Email or username", text: $email)
                .textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled() }
            field { SecureField("Password", text: $password).textContentType(.password) }

            if let err = account.signInError {
                Text(err).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
            }

            Button {
                passwordBusy = true
                Task {
                    await account.signIn(email: email, password: password)
                    await MainActor.run { passwordBusy = false }
                }
            } label: {
                Text(passwordBusy ? "Signing in…" : "Sign In").frame(width: 280)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(passwordBusy || email.isEmpty || password.isEmpty)
        }
        .frame(width: 700)
    }

    private func switchMode() {
        if mode == .link {
            mode = .password
        } else {
            mode = .link
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
