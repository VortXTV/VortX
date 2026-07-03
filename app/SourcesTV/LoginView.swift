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
    /// H22: an explicit first-responder identity for each credential field, so the tvOS system keyboard
    /// (and the iPhone Continuity Keyboard) binds to a concrete field the same way Search's field does.
    @FocusState private var focusedField: Field?

    private enum Mode { case link, password }
    private enum Field { case email, password }

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
            // Account-owns-everything snapshot-on-import: once the engine has pulled this Stremio
            // account's add-ons, snapshot the full descriptor set into the VortX account doc so the
            // account OWNS them (they hydrate later with no live Stremio session). Delayed so
            // PullAddonsFromAPI has landed; no-op (never-zero guarded) if still empty / signed out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Task { @MainActor in await VortXSyncManager.shared.snapshotOwnedFromEngine() }
            }
            dismiss()
        }
    }

    private var passwordLogin: some View {
        VStack(spacing: Theme.Space.md) {
            // H22 CONTINUITY KEYBOARD: the iPhone Continuity Keyboard detected the Apple TV but never
            // connected on these fields (it works in the Search tab, which uses the system .searchable
            // field). Continuity attaches to the standard tvOS credential-entry path, which the OS
            // recognizes when the identifier + secret are declared as a `.username`/`.password` CREDENTIAL
            // PAIR (not a bare `.emailAddress`), and each field carries an explicit `keyboardType` +
            // `submitLabel` so the system keyboard (and thus Continuity) presents its full entry sheet.
            // The `focused($focusedField)` binding gives each field a real first-responder identity so the
            // Continuity session binds to a concrete field the way the search controller does. This makes
            // the fields use the same standard tvOS text-entry path Search uses.
            field { TextField("Email or username", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .submitLabel(.next)
                .focused($focusedField, equals: .email)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { focusedField = .password } }
            field { SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit { if !email.isEmpty && !password.isEmpty { submitSignIn() } } }

            if let err = account.signInError {
                Text(err).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
            }

            Button { submitSignIn() } label: {
                Text(passwordBusy ? "Signing in…" : "Sign In").frame(width: 280)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(passwordBusy || email.isEmpty || password.isEmpty)
        }
        .frame(width: 700)
    }

    /// Kick off the password sign-in (shared by the Sign In button and the password field's Return key).
    private func submitSignIn() {
        guard !passwordBusy, !email.isEmpty, !password.isEmpty else { return }
        passwordBusy = true
        Task {
            await account.signIn(email: email, password: password)
            await MainActor.run { passwordBusy = false }
        }
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
