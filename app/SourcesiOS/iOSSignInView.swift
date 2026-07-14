import SwiftUI

/// Touch sign-in on the VortX design system (see Theme.swift). VortX-account sign-in is the PRIMARY path
/// (QR pairing, or a typed email/password form) so you sign into the account that OWNS your add-ons, library,
/// and cross-device sync. Connecting a Stremio account (its QR/link flow, or a password) stays available as a
/// secondary "bring your Stremio library" step. Mirrors tvOS LoginView, adapted for touch. Either Stremio
/// path seeds the engine the moment the account reports signed-in; the VortX paths hydrate via adopt() and
/// only need the sheet to close on success.
struct iOSSignInView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    // The shared VortX account manager (the same singleton the app root injects). Observed here so the sheet
    // can dismiss itself the moment a typed VortX sign-in flips isSignedIn; the QR joiner dismisses itself.
    @ObservedObject private var vortxSync = VortXSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .vortx
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    // Pushes the typed VortX account form (the shared SyncSettingsView). A flag, not a Mode case, so the form
    // is a real pushed screen (its own ScrollView, a back button) instead of nesting inside this ScrollView.
    @State private var showVortXEmail = false
    // The sign-in handoff below MUST run exactly once. `@Published` re-publishes on every assignment
    // (true→true included), so without this latch the handler's own work re-fired `$isSignedIn` and
    // re-entered itself in an unbounded main-thread loop — the iOS/iPad "stuck on Signing in, dead
    // buttons, phone lags, then crashes" hang. (macOS has no main-thread watchdog so it rode it out.)
    @State private var didHandleSignIn = false

    // .vortx leads (QR joiner + a typed-form push); the Stremio link/password paths are the fallback.
    private enum Mode { case vortx, stremioLink, stremioPassword }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    // LazyVStack: greedy on width so the QR card / password field can't push the
                    // column past the viewport and clip (systemic fix S1).
                    LazyVStack(spacing: Theme.Space.lg) {
                        // macOS has no toolbar cancellation item (the shared-window NSToolbar bridge is the
                        // Beta 7 crash, so the toolbar below is iOS-only). Carry an in-content Cancel so the
                        // sign-in sheet stays dismissable on Mac.
                        #if os(macOS)
                        HStack {
                            Button("Cancel") { dismiss() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Spacer()
                        }
                        #endif
                        wordmark
                        intro
                        surface
                        secondaryActions
                        footnote
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Space.lg)
                }
            }
            // navigationTitle + the cancellation ToolbarItem both bridge into the single shared window
            // NSToolbar on macOS and crash in _insertNewItemWithItemIdentifier (the Beta 7 Mac crash).
            // iOS-only here; macOS gets the in-content Cancel above.
            #if os(iOS)
            .navigationTitle("")          // the wordmark IS the title
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            #endif
            // Typed VortX account path: the shared SyncSettingsView (sign in / create / recover), reused
            // AS-IS and pushed as its own screen so its ScrollView never nests inside this one. On success it
            // flips VortXSyncManager.isSignedIn and the .onChange below closes the sheet. SyncSettingsView
            // reads VortXSyncManager from the environment, which this sheet already inherits (same as the
            // account / core objects it already uses).
            .navigationDestination(isPresented: $showVortXEmail) { SyncSettingsView() }
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
            // Account-owns-everything snapshot-on-import: once the engine has finished pulling this
            // Stremio account's add-ons, snapshot the full descriptor set into the VortX account doc so
            // the account OWNS them (and they hydrate later even with no live Stremio session). We AWAIT the
            // engine's PullAddonsFromAPI settling (awaitAddonsHydrated) instead of a fixed delay: a fixed
            // delay snapshotted a slow host mid-pull, capturing only SOME add-ons (the partial-import bug).
            // No-op (never-zero guarded) if the engine is still empty or the VortX account is unreachable.
            Task { @MainActor in
                await core.awaitAddonsHydrated()
                await VortXSyncManager.shared.snapshotOwnedFromEngine()
            }
            dismiss()
        }
        // VortX typed-path success: SyncSettingsView signs the VortX account in and adopt() has already
        // hydrated add-ons + library (the app-root onChange re-runs the degraded-engine check), so here we
        // only close the sheet. Scoped to showVortXEmail so the QR joiner's own checkmark-then-dismiss is
        // never preempted. .onChange fires only on a real transition, so an already-signed-in open (someone
        // who opened this sheet just to add Stremio) never spuriously dismisses.
        .onChange(of: vortxSync.isSignedIn) { signedIn in
            if signedIn && showVortXEmail { dismiss() }
        }
    }

    // MARK: Brand

    private var wordmark: some View {
        VortXWordmark(fontSize: 40)
            .padding(.top, Theme.Space.sm)
    }

    private var intro: some View {
        Text(introText)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var introText: String {
        switch mode {
        case .vortx:
            return "Sign in to your VortX account to sync your add-ons, library, and settings across devices."
        case .stremioLink:
            return "Scan the QR code, or enter the code at link.stremio.com on another device to sign in."
        case .stremioPassword:
            return "Sign in to your Stremio account to pull in your add-ons and library."
        }
    }

    // MARK: Sign-in surface (VortX primary, Stremio fallback)

    /// The active credential surface. VortX (QR pairing) leads, mirroring tvOS LoginView; the typed VortX
    /// form is reached via `secondaryActions` (pushed SyncSettingsView). Stremio link/password are secondary.
    @ViewBuilder private var surface: some View {
        switch mode {
        case .vortx:
            // The joiner runs VortXSyncManager.qrStart/qrPoll and dismisses this sheet itself on success
            // (its own checkmark-then-dismiss), exactly as on tvOS.
            VortXAccountJoinerView(onSignedIn: { dismiss() })
                .frame(maxWidth: 460)
        case .stremioLink:
            LinkLoginView(account: account)
        case .stremioPassword:
            passwordCard
        }
    }

    /// Path switches under the active surface, mirroring tvOS LoginView.secondaryActions. Clearing
    /// account.signInError on each switch keeps a stale Stremio error from bleeding across paths.
    @ViewBuilder private var secondaryActions: some View {
        switch mode {
        case .vortx:
            VStack(spacing: Theme.Space.sm) {
                Button { showVortXEmail = true } label: { Text("Use email and password") }
                    .buttonStyle(ChipButtonStyle())
                Button { account.signInError = nil; mode = .stremioLink } label: {
                    Text("Connect a Stremio account instead")
                }
                .buttonStyle(ChipButtonStyle())
            }
        case .stremioLink:
            VStack(spacing: Theme.Space.sm) {
                Button { account.signInError = nil; mode = .stremioPassword } label: { Text("Use password instead") }
                    .buttonStyle(ChipButtonStyle())
                Button { account.signInError = nil; mode = .vortx } label: { Text("Sign in to VortX instead") }
                    .buttonStyle(ChipButtonStyle())
            }
        case .stremioPassword:
            VStack(spacing: Theme.Space.sm) {
                Button { account.signInError = nil; mode = .stremioLink } label: { Text("Use QR code instead") }
                    .buttonStyle(ChipButtonStyle())
                Button { account.signInError = nil; mode = .vortx } label: { Text("Sign in to VortX instead") }
                    .buttonStyle(ChipButtonStyle())
            }
        }
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

    // MARK: Footnote

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
