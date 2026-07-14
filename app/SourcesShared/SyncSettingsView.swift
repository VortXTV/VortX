import SwiftUI

/// Sign in to / create / recover a VortX account, and see sync status. Cross-platform (iPhone, iPad,
/// Mac, Apple TV) on top of VortXSyncManager + VortXSyncCrypto. The account is optional; VortX works
/// fully signed out, this only adds cross-device sync, backup, and recovery.
struct SyncSettingsView: View {
    @EnvironmentObject private var sync: VortXSyncManager

    enum Mode: String, CaseIterable { case signIn = "Sign in", create = "Create", recover = "Recover" }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var totp = ""
    @State private var needsTotp = false
    @State private var recoveryCodeInput = ""
    @State private var working = false
    @State private var message: String?
    @State private var failed = false
    @State private var newRecoveryCode: String?   // shown once, right after creating an account
    @State private var showConflict = false       // account already has data: ask which side to keep
    @State private var syncing = false
    @State private var syncNote: String?          // signed-in status line: the tri-state retry surface

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("VortX account").screenTitleStyle()
                if sync.isSignedIn, let account = sync.account {
                    signedIn(account)
                } else {
                    signedOut
                }
                // External sync providers (Trakt, SIMKL). Independent of the VortX account, so it is
                // mounted here for BOTH signed-in and signed-out states, and hosted from this shared view
                // so iOS and tvOS get it by construction (settings parity). Renders nothing until a
                // provider's build credentials are present (dormant with empty creds).
                ExternalServicesSettingsView()
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .alert("Sync conflict", isPresented: $showConflict) {
            // "Merge both" is the recommended/default: it unions the rosters so NO profile is lost.
            // The other two force one side, but even "Use account's data" still keeps local-only
            // profiles (syncDown unions them back), so neither choice can silently delete a profile.
            Button("Merge both (keep all profiles)") { resolveConflict { await sync.mergeBoth() } }
            Button("Use account's data") { resolveConflict { await sync.useAccountData() } }
            Button("Keep this device") { resolveConflict { await sync.pushThisDevice() } }
        } message: {
            Text("This account's profiles differ from this device. Merge both to keep every profile (recommended), or force one side.")
        }
        .task { await sync.refreshAccount() }
    }

    // MARK: Signed in

    @ViewBuilder private func signedIn(_ account: VortXSyncManager.Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("@\(account.username)").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text(account.email).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Text(account.twoFactorEnabled ? "Two-factor: on" : "Two-factor: off")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

        Text("Your profiles, settings, and metadata keys sync to this account, end-to-end encrypted. They also sync automatically a moment after any change.")
            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)

        HStack(spacing: Theme.Space.md) {
            Button(syncing ? "Syncing…" : "Sync now") { syncNow() }
                .buttonStyle(PrimaryActionStyle())
                .disabled(syncing)
            Button("Sign out") { sync.signOut(); reset() }
                .buttonStyle(ChipButtonStyle(selected: false))
        }

        // The tri-state retry surface: shown when the account doc could not be reached (a network
        // blip), so the failure is visible and retryable instead of silently swallowed.
        if let syncNote {
            Text(syncNote).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Signed out

    @ViewBuilder private var signedOut: some View {
        if let code = newRecoveryCode {
            recoveryCodeCard(code)
        } else {
            Text("Optional. A free, end-to-end-encrypted account keeps your profiles, settings, and library safe across devices.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)

            HStack(spacing: Theme.Space.sm) {
                ForEach(Mode.allCases, id: \.self) { m in
                    Button(m.rawValue) { mode = m; message = nil; needsTotp = false }
                        .buttonStyle(ChipButtonStyle(selected: mode == m))
                }
            }

            VStack(spacing: Theme.Space.md) {
                field(mode == .signIn ? "Email or username" : "Email", text: $email, content: .emailAddress)
                if mode == .create { field("Username", text: $username) }
                if mode == .recover { field("Recovery code (VX-…)", text: $recoveryCodeInput) }
                secureField(mode == .recover ? "New password" : "Password", text: $password)
                if needsTotp { field("Authenticator code", text: $totp, content: .oneTimeCode) }
            }

            if let message {
                Text(message).font(Theme.Typography.label)
                    .foregroundStyle(failed ? Theme.Palette.danger : Theme.Palette.textSecondary)
            }

            Button(working ? "Working…" : actionLabel) { submit() }
                .buttonStyle(PrimaryActionStyle())
                .disabled(working || !canSubmit)
        }
    }

    private var actionLabel: String {
        switch mode { case .signIn: return "Sign in"; case .create: return "Create account"; case .recover: return "Reset password" }
    }
    private var canSubmit: Bool {
        guard !email.isEmpty, !password.isEmpty else { return false }
        if mode == .create && username.isEmpty { return false }
        if mode == .recover && recoveryCodeInput.isEmpty { return false }
        if needsTotp && totp.isEmpty { return false }
        return true
    }

    @ViewBuilder private func recoveryCodeCard(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Save your recovery code").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text("This is shown only once. It is the only way back in if you forget your password and lose your devices. Store it somewhere safe.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Text(code)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Palette.accent)
                .selectableText()
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            Button("I saved it") { newRecoveryCode = nil }
                .buttonStyle(PrimaryActionStyle())
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: Actions

    /// Run ONE conflict resolution, then re-run the account hydrate as a belt-and-braces pass:
    /// whichever side won, the engine should hold the account's owned add-ons + owner library
    /// right away, without waiting for a background/foreground cycle to re-check. Idempotent and
    /// never-zero guarded inside the manager (a .failed/.empty pull does nothing; install-only union).
    private func resolveConflict(_ action: @escaping () async -> Void) {
        Task { @MainActor in
            syncing = true
            syncNote = nil
            await action()
            await sync.hydrateEngineFromOwnedAddons()
            syncing = false
        }
    }

    /// Explicit "Sync now": if the account's roster differs from this device, ASK which to keep
    /// (Merge both / Use account / Keep this device) instead of blind-pushing, so a deliberate push
    /// never silently drops the other side's profiles. When the rosters match there is nothing to ask,
    /// so it just pushes as before. An unreachable account doc is a DISTINCT retry state: it must not
    /// be misread as "no conflict" and silently pushed over a roster that was never compared.
    private func syncNow() {
        Task { @MainActor in
            syncing = true
            switch await sync.rosterConflictWithAccount() {
            case .conflict:
                syncing = false
                showConflict = true
            case .unreachable:
                syncNote = "Could not reach VortX sync. Check your connection and try again."
                syncing = false
            case .noConflict:
                await sync.pushThisDevice()
                syncNote = nil
                syncing = false
            }
        }
    }

    private func submit() {
        working = true; message = nil; failed = false
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        Task { @MainActor in
            switch mode {
            case .signIn:
                let r = await sync.signIn(login: mail, password: password, totp: needsTotp ? totp : nil)
                handle(r)
            case .create:
                let (r, code) = await sync.register(email: mail, username: username.trimmingCharacters(in: .whitespaces), password: password)
                if case .ok = r { newRecoveryCode = code }
                handle(r)
            case .recover:
                let r = await sync.recover(email: mail, recoveryCode: recoveryCodeInput, newPassword: password)
                handle(r)
            }
            working = false
        }
    }

    private func handle(_ result: VortXSyncManager.AuthResult) {
        switch result {
        case .ok:
            password = ""; totp = ""; needsTotp = false
            // Decide pull vs seed vs ask: a fresh account is seeded; one with data prompts which to
            // keep; an UNREACHABLE account doc is a distinct retry state (never misread as fresh and
            // seeded over, the old nil-collapse misroute).
            Task {
                switch await sync.reconcileAfterSignIn() {
                case .hasAccountData: showConflict = true
                case .seededFromDevice: break
                case .unreachable:
                    syncNote = "Signed in, but VortX sync could not be reached. It will retry; you can also use Sync now."
                }
                // Belt-and-braces on top of adopt()'s own hydrate: re-run the account hydrate after the
                // reconcile decision so ONE interactive sign-in restores add-ons + owner library even if
                // the adopt-time pass raced the doc pull or the engine boot. Idempotent + never-zero
                // guarded inside the manager (a .failed/.empty pull does nothing; install-only union).
                await sync.hydrateEngineFromOwnedAddons()
            }
        case .totpRequired:
            needsTotp = true; message = "Enter your authenticator code."; failed = false
        case .failed(let msg):
            message = msg; failed = true
        }
    }

    private func reset() {
        email = ""; username = ""; password = ""; totp = ""; recoveryCodeInput = ""
        needsTotp = false; message = nil; failed = false; newRecoveryCode = nil; mode = .signIn
        syncNote = nil
    }

    // MARK: Field helpers (cross-platform)

    @ViewBuilder private func field(_ placeholder: String, text: Binding<String>, content: UITextContentTypeShim = .none) -> some View {
        TextField(placeholder, text: text)
            .font(Theme.Typography.body)
            .disableAutocorrection(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .textContentType(content.value)
            .keyboardType(content == .emailAddress ? .emailAddress : (content == .oneTimeCode ? .numberPad : .default))
            #endif
    }

    @ViewBuilder private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .font(Theme.Typography.body)
            #if os(iOS)
            .textContentType(.password)
            #endif
    }
}

/// Tiny shim so the cross-platform `field(...)` signature compiles on tvOS/macOS where UITextContentType
/// behaves differently; only iOS actually applies the content type.
enum UITextContentTypeShim {
    case none, emailAddress, oneTimeCode
    #if os(iOS)
    var value: UITextContentType? {
        switch self { case .none: return nil; case .emailAddress: return .emailAddress; case .oneTimeCode: return .oneTimeCode }
    }
    #endif
}

private extension View {
    /// Text selection is iOS/macOS only; a no-op on tvOS so the recovery-code field still compiles.
    @ViewBuilder func selectableText() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}
