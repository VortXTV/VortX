import SwiftUI

/// tvOS sign-in. VortX-account sign-in (QR pairing) is the PRIMARY path, so you sign into the account that
/// owns your add-ons, library, and cross-device sync. Connecting a Stremio account (its own QR link, or a
/// password) stays available as a secondary "bring your Stremio library" step.
struct LoginView: View {
    @ObservedObject var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .vortx
    @State private var email = ""
    @State private var password = ""
    @State private var passwordBusy = false
    // Run the Stremio sign-in handoff exactly once. `@Published` re-publishes on every assignment, so a
    // future unconditional `isSignedIn = true` could otherwise re-enter this sink in a loop (the bug that
    // froze the iOS sign-in). Parity with iOSSignInView's latch, defensive, costs nothing.
    @State private var didHandleSignIn = false
    /// H22: an explicit first-responder identity for each credential field, so the tvOS system keyboard
    /// (and the iPhone Continuity Keyboard) binds to a concrete field the same way Search's field does.
    @FocusState private var focusedField: Field?

    private enum Mode { case vortx, stremioLink, stremioPassword }
    private enum Field { case email, password }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                VortXWordmark(fontSize: 54)

                Text(headline)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)

                switch mode {
                case .vortx:           VortXAccountJoinerView(onSignedIn: { dismiss() })
                case .stremioLink:     LinkLoginView(account: account)
                case .stremioPassword: passwordLogin
                }

                secondaryActions
            }
            .padding(Theme.Space.screenEdge)
        }
        // The Stremio paths finish through StremioAccount.isSignedIn; the VortX path dismisses itself via
        // the joiner's onSignedIn. This sink covers only the Stremio link/password sign-in handoff.
        .onReceive(account.$isSignedIn) { signedIn in
            guard signedIn, !didHandleSignIn else { return }
            didHandleSignIn = true
            core.signedInWithLegacyAuthKey()   // seed the engine now, not on next launch
            // Account-owns-everything snapshot-on-import: once the engine has pulled this Stremio account's
            // add-ons, snapshot the full descriptor set into the VortX account doc so the account OWNS them
            // (they hydrate later with no live Stremio session). We AWAIT the engine's PullAddonsFromAPI
            // settling (awaitAddonsHydrated) rather than a fixed delay: a fixed delay snapshotted a slow
            // host mid-pull, capturing only SOME add-ons (the partial-import bug). No-op (never-zero guarded)
            // if still empty / signed out.
            Task { @MainActor in
                await core.awaitAddonsHydrated()
                await VortXSyncManager.shared.snapshotOwnedFromEngine()
            }
            dismiss()
        }
    }

    private var headline: String {
        switch mode {
        case .vortx:           return "Scan the code or enter it on a device signed in to VortX."
        case .stremioLink:     return "Scan the QR code or enter the code on another device to connect Stremio."
        case .stremioPassword: return "Sign in to your Stremio account to load your add-ons and streams."
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        switch mode {
        case .vortx:
            Button { mode = .stremioLink } label: {
                Text("Connect a Stremio account instead").frame(width: 380)
            }
            .buttonStyle(ChipButtonStyle())
        case .stremioLink:
            HStack(spacing: Theme.Space.sm) {
                Button { mode = .stremioPassword } label: { Text("Use password").frame(width: 200) }
                    .buttonStyle(ChipButtonStyle())
                Button { mode = .vortx } label: { Text("Sign in to VortX").frame(width: 240) }
                    .buttonStyle(ChipButtonStyle())
            }
        case .stremioPassword:
            HStack(spacing: Theme.Space.sm) {
                Button { mode = .stremioLink } label: { Text("Use QR code").frame(width: 200) }
                    .buttonStyle(ChipButtonStyle())
                Button { mode = .vortx } label: { Text("Sign in to VortX").frame(width: 240) }
                    .buttonStyle(ChipButtonStyle())
            }
        }
    }

    private var passwordLogin: some View {
        VStack(spacing: Theme.Space.md) {
            // H22 CONTINUITY KEYBOARD: the earlier fix declared these as a `.username`/`.password` CREDENTIAL
            // PAIR (textContentType), but the iPhone Continuity Keyboard detects the Apple TV yet never
            // CONNECTS on login, while it works fine in Search. Search uses `.searchable` (plain text, NO
            // textContentType), so it never enters the tvOS AutoFill-Passwords / iCloud Keychain CREDENTIAL
            // negotiation that a `.password` / `.username` field triggers. That autofill negotiation stalling
            // over Continuity is the likely cause. So drop textContentType (and the tvOS-irrelevant
            // keyboardType) and use plain text entry like Search; the SecureField still masks the password.
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

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
