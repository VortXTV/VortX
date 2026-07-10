import SwiftUI

/// Touch sign-in on the VortX design system (see Theme.swift). VortX-account sign-in is the PRIMARY
/// path, so you sign into the account that owns your add-ons, library, and cross-device sync: pair by
/// QR from a device already signed in to VortX, or use email and password (create / sign in / recover
/// via SyncSettingsView). Connecting a Stremio account stays available as a secondary "bring your
/// Stremio library" step. This mirrors the tvOS LoginView, which already leads with VortX.
struct iOSSignInView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var sync: VortXSyncManager
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .vortx
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    // The Stremio sign-in handoff below MUST run exactly once. `@Published` re-publishes on every
    // assignment (true→true included), so without this latch the handler's own work re-fired
    // `$isSignedIn` and re-entered itself in an unbounded main-thread loop, the iOS/iPad "stuck on
    // Signing in, dead buttons, phone lags, then crashes" hang. (macOS has no main-thread watchdog so
    // it rode it out.)
    @State private var didHandleSignIn = false
    /// Push the full VortX account panel (SyncSettingsView: create / sign in / recover) onto this
    /// sheet's own navigation stack. Reusing SyncSettingsView verbatim, pushed rather than nested, keeps
    /// its own ScrollView out of this sheet's ScrollView.
    @State private var showVortXAccount = false
    /// Whether the VortX account was already signed in when the email/password panel opened, so a
    /// re-emitted `isSignedIn` (SyncSettingsView refreshes its account on appear) cannot auto-dismiss a
    /// user who was only viewing the panel. Only a fresh sign-in from that panel closes the sheet.
    @State private var vortxSignedInBeforeAccount = false
    @State private var didHandleVortXSignIn = false

    private enum Mode { case vortx, stremioLink, stremioPassword }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    // LazyVStack: greedy on width so the QR card / password field can't push the
                    // column past the viewport and clip (systemic fix S1).
                    LazyVStack(spacing: Theme.Space.lg) {
                        // macOS has no toolbar cancellation item (the shared-window NSToolbar bridge is
                        // the Beta 7 crash, so the toolbar below is iOS-only). Carry an in-content Cancel
                        // so the sign-in sheet stays dismissable on Mac.
                        #if os(macOS)
                        macCancelBar
                        #endif
                        wordmark
                        intro
                        primaryContent
                        secondaryActions
                        footnote
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Space.lg)
                }
            }
            // The VortX email/password flow reuses SyncSettingsView as-is, pushed here so it renders as
            // a full screen with its own scroll and title rather than nested inside the sheet's column.
            .navigationDestination(isPresented: $showVortXAccount) { SyncSettingsView() }
            // navigationTitle + the cancellation ToolbarItem both bridge into the single shared window
            // NSToolbar on macOS and crash in _insertNewItemWithItemIdentifier (the Beta 7 Mac crash).
            // iOS-only here; macOS gets the in-content Cancel above.
            #if os(iOS)
            .navigationTitle("")          // the wordmark IS the title
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            #endif
        }
        // Stremio success handler. One place seeds the engine with the freshly written authKey, then
        // dismisses. CoreBridge booted signed-out at launch, so without signedInWithLegacyAuthKey() the
        // Home rails (boardRows / continueWatching) stay empty until the next cold launch. Mirrors the
        // proven tvOS LoginView handoff exactly.
        //
        // Runs ONCE per presentation (didHandleSignIn latch): the handler must not write anything that
        // re-publishes `$isSignedIn`, or it re-enters itself forever. Both sign-in entry points
        // (signIn / signInWithAuthKey) already load add-ons + set the email, so reloadForActiveProfile()
        // is redundant here, and it was the second `isSignedIn = true` write that armed the loop.
        .onReceive(account.$isSignedIn) { signedIn in
            guard signedIn, !didHandleSignIn else { return }
            didHandleSignIn = true
            core.signedInWithLegacyAuthKey()
            // Account-owns-everything snapshot-on-import: once the engine has finished pulling this
            // Stremio account's add-ons, snapshot the full descriptor set into the VortX account doc so
            // the account OWNS them (and they hydrate later even with no live Stremio session). We AWAIT
            // the engine's PullAddonsFromAPI settling (awaitAddonsHydrated) instead of a fixed delay: a
            // fixed delay snapshotted a slow host mid-pull, capturing only SOME add-ons (the partial-import
            // bug). No-op (never-zero guarded) if the engine is still empty or the VortX account is
            // unreachable.
            Task { @MainActor in
                await core.awaitAddonsHydrated()
                await VortXSyncManager.shared.snapshotOwnedFromEngine()
            }
            dismiss()
        }
        // VortX email/password success handler. The QR path dismisses itself via the joiner's onSignedIn
        // after its check-mark, so it is deliberately NOT handled here. This closes the sheet only for a
        // fresh sign-in made from the pushed SyncSettingsView panel, and hydrates the engine from the
        // account's owned add-ons so Home populates without a cold relaunch (the QR path already does this
        // inside the joiner). Guarded so a user who opened the panel already signed in is not auto-closed.
        .onReceive(sync.$isSignedIn) { signedIn in
            guard showVortXAccount, signedIn, !vortxSignedInBeforeAccount, !didHandleVortXSignIn else { return }
            didHandleVortXSignIn = true
            Task { @MainActor in
                await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                dismiss()
            }
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
        case .vortx:           return "Sign in to VortX to sync your library, add-ons, and settings across your devices."
        case .stremioLink:     return "Scan the QR code, or enter the code at link.stremio.com on another device, to connect Stremio."
        case .stremioPassword: return "Sign in to your Stremio account to pull in your add-ons and library."
        }
    }

    // MARK: Primary content per mode

    @ViewBuilder private var primaryContent: some View {
        switch mode {
        case .vortx:           VortXAccountJoinerView(onSignedIn: { dismiss() })
        case .stremioLink:     LinkLoginView(account: account)
        case .stremioPassword: passwordCard
        }
    }

    // MARK: Stremio password fallback

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

    #if os(macOS)
    private var macCancelBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
        }
    }
    #endif

    // MARK: Secondary actions + footnote

    /// Mirrors the tvOS LoginView's secondary-action structure and copy: VortX leads, Stremio is the
    /// secondary "Connect a Stremio account instead", and each Stremio mode offers a way back to VortX.
    @ViewBuilder private var secondaryActions: some View {
        switch mode {
        case .vortx:
            VStack(spacing: Theme.Space.sm) {
                Button { openVortXAccount() } label: {
                    Text("Use email and password").frame(maxWidth: 460)
                }
                .buttonStyle(ChipButtonStyle())
                Button { switchMode(.stremioLink) } label: {
                    Text("Connect a Stremio account instead").frame(maxWidth: 460)
                }
                .buttonStyle(ChipButtonStyle())
            }
        case .stremioLink:
            HStack(spacing: Theme.Space.sm) {
                Button { switchMode(.stremioPassword) } label: { Text("Use password") }
                    .buttonStyle(ChipButtonStyle())
                Button { switchMode(.vortx) } label: { Text("Sign in to VortX") }
                    .buttonStyle(ChipButtonStyle())
            }
        case .stremioPassword:
            HStack(spacing: Theme.Space.sm) {
                Button { switchMode(.stremioLink) } label: { Text("Use QR code") }
                    .buttonStyle(ChipButtonStyle())
                Button { switchMode(.vortx) } label: { Text("Sign in to VortX") }
                    .buttonStyle(ChipButtonStyle())
            }
        }
    }

    private var footnote: some View {
        Text("Signing in pulls your add-ons and library into the app. Your account stays on this device.")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Space.xs)
    }

    // MARK: Actions

    private func switchMode(_ next: Mode) {
        account.signInError = nil
        mode = next
    }

    /// Open the VortX account email/password panel. Capture whether the account is already signed in so
    /// the success handler only auto-dismisses on a fresh sign-in, not on a user who is just viewing it.
    private func openVortXAccount() {
        vortxSignedInBeforeAccount = sync.isSignedIn
        showVortXAccount = true
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
