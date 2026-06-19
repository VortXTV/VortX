import SwiftUI

/// Touch sign-in for a Stremio account, on the StremioX design system (see Theme.swift).
/// QR/link login is the default so passwords are entered on Stremio's own web flow; a password
/// form remains available as a fallback. Either path seeds the engine (add-ons + library) the
/// moment the account reports signed-in, so Home's rails populate without a cold relaunch.
struct iOSSignInView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .link
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    // The sign-in handoff below MUST run exactly once. `@Published` re-publishes on every assignment
    // (true→true included), so without this latch the handler's own work re-fired `$isSignedIn` and
    // re-entered itself in an unbounded main-thread loop — the iOS/iPad "stuck on Signing in, dead
    // buttons, phone lags, then crashes" hang. (macOS has no main-thread watchdog so it rode it out.)
    @State private var didHandleSignIn = false

    private enum Mode { case link, password }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    // LazyVStack: greedy on width so the QR card / password field can't push the
                    // column past the viewport and clip (systemic fix S1).
                    LazyVStack(spacing: Theme.Space.lg) {
                        wordmark
                        intro
                        if mode == .link {
                            LinkLoginView(account: account)
                        } else {
                            passwordCard
                        }
                        modeToggle
                        footnote
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Space.lg)
                }
            }
            .navigationTitle("")          // the wordmark IS the title
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        // One place handles success for BOTH paths (password + QR/link): seed the engine with the
        // freshly written authKey, then dismiss. CoreBridge booted signed-out at launch, so without
        // signedInWithLegacyAuthKey() the Home rails (boardRows / continueWatching) stay empty until
        // the next cold launch. Mirrors the proven tvOS LoginView handoff exactly.
        //
        // Runs ONCE per presentation (didHandleSignIn latch): the handler must not write anything that
        // re-publishes `$isSignedIn`, or it re-enters itself forever. Both sign-in entry points
        // (signIn / signInWithAuthKey) already load add-ons + set the email, so reloadForActiveProfile()
        // is redundant here — and it was the second `isSignedIn = true` write that armed the loop.
        .onReceive(account.$isSignedIn) { signedIn in
            guard signedIn, !didHandleSignIn else { return }
            didHandleSignIn = true
            core.signedInWithLegacyAuthKey()
            dismiss()
        }
    }

    // MARK: Brand

    private var wordmark: some View {
        VortXWordmark(fontSize: 40)
            .padding(.top, Theme.Space.sm)
    }

    private var intro: some View {
        Text(mode == .link
             ? "Scan the QR code, or enter the code at link.stremio.com on another device to sign in."
             : "Sign in to your Stremio account to pull in your add-ons and library.")
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Password fallback

    private var passwordCard: some View {
        VStack(spacing: Theme.Space.md) {
            field {
                TextField("Email or username", text: $email)
                    .textContentType(.username)
                    .emailFieldStyle()
                    .autocorrectionDisabled()
            }
            field {
                SecureField("Password", text: $password).textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { if !busy && !email.isEmpty && !password.isEmpty { Task { await signIn() } } }
            }

            if let err = account.signInError {
                Text(err)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    if busy { ProgressView().tint(Theme.Palette.onAccent) }
                    Text(busy ? "Signing in…" : "Sign In")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(busy || email.isEmpty || password.isEmpty)
        }
        .frame(maxWidth: 460)
    }

    /// A warm surface card wrapping a single text/secure field, matching the tvOS login fields.
    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Palette.surface1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    // MARK: Mode toggle + footnote

    private var modeToggle: some View {
        Button {
            account.signInError = nil
            mode = (mode == .link) ? .password : .link
        } label: {
            Text(mode == .link ? "Use password instead" : "Use QR code instead")
        }
        .buttonStyle(ChipButtonStyle())
    }

    private var footnote: some View {
        Text("Signing in pulls your add-ons and library into the app. Your account stays on this device.")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Space.xs)
    }

    private func signIn() async {
        busy = true
        await account.signIn(email: email, password: password)
        busy = false
        // Success (isSignedIn flips true) is handled centrally in .onReceive above, which runs the
        // signedInWithLegacyAuthKey() -> dismiss() sequence exactly once. On failure
        // account.signInError carries the message and the form stays put.
    }
}
