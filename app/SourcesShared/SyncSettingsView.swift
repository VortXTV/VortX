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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("VortX account").screenTitleStyle()
                if sync.isSignedIn, let account = sync.account {
                    signedIn(account)
                } else {
                    signedOut
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
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

        Text("Your profiles, settings, library, and history sync to this account, end-to-end encrypted.")
            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)

        Button("Sign out") { sync.signOut(); reset() }
            .buttonStyle(ChipButtonStyle(selected: false))
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
                field("Email", text: $email, content: .emailAddress)
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
        case .totpRequired:
            needsTotp = true; message = "Enter your authenticator code."; failed = false
        case .failed(let msg):
            message = msg; failed = true
        }
    }

    private func reset() {
        email = ""; username = ""; password = ""; totp = ""; recoveryCodeInput = ""
        needsTotp = false; message = nil; failed = false; newRecoveryCode = nil; mode = .signIn
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
