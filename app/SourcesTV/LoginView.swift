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
            // account OWNS them (they hydrate later with no live Stremio session). We AWAIT the engine's
            // PullAddonsFromAPI settling (awaitAddonsHydrated) rather than a fixed delay: a fixed delay
            // snapshotted a slow host mid-pull, capturing only SOME add-ons (the partial-import bug).
            // No-op (never-zero guarded) if still empty / signed out.
            Task { @MainActor in
                await core.awaitAddonsHydrated()
                await VortXSyncManager.shared.snapshotOwnedFromEngine()
            }
            dismiss()
        }
    }

    private var passwordLogin: some View {
        VStack(spacing: Theme.Space.md) {
            // H22 CONTINUITY KEYBOARD (attempt 2, NEEDS device verification on a real Apple TV + iPhone):
            // the earlier fix declared these as a `.username`/`.password` CREDENTIAL PAIR (textContentType),
            // but users still report the iPhone Continuity Keyboard DETECTS the Apple TV yet never CONNECTS on
            // login, while it works fine in the Search tab. The Search tab uses `.searchable`, which is PLAIN
            // text entry with NO textContentType, so it never enters the tvOS AutoFill-Passwords / iCloud
            // Keychain CREDENTIAL negotiation that a `.password` / `.username` field triggers. That autofill
            // negotiation stalling over Continuity is the most likely cause of "detected but won't connect".
            // So drop textContentType (and the tvOS-irrelevant keyboardType) and use plain text entry like
            // Search; the SecureField still masks the password. Trade-off: no saved-password autofill, but the
            // priority is that Continuity can type at all. focused()/submitLabel/onSubmit are kept.
            field { TextField("Email or username", text: $email)
                .submitLabel(.next)
                .focused($focusedField, equals: .email)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { focusedField = .password } }
            field { SecureField("Password", text: $password)
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
