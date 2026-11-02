import SwiftUI

/// Sign in to / create / recover a VortX account, and see sync status. Cross-platform (iPhone, iPad,
/// Mac, Apple TV) on top of VortXSyncManager + VortXSyncCrypto. The account is optional; VortX works
/// fully signed out, this only adds cross-device sync, backup, and recovery.
struct SyncSettingsView: View {
    @EnvironmentObject private var sync: VortXSyncManager
    /// Pre-profile callers retain their original device-wide diagnostics admission.
    /// An account form is not an unlocked profile.
    var allowsDiagnosticExport: Bool
    var diagnosticCredential: CredentialScopeRegistry.Capture?
    var diagnosticGrant: ProfilePickerToolsDiagnosticGrant?
    /// Embedded sheets close after authentication and one-time-code acknowledgement.
    /// Account restore remains manager-owned. Ordinary Account settings leave this nil.
    var onSignedIn: (() -> Void)?
    @StateObject private var authentication: AccountAuthenticationPresentation

    init(allowsDiagnosticExport: Bool = true,
         diagnosticCredential: CredentialScopeRegistry.Capture? = nil,
         diagnosticGrant: ProfilePickerToolsDiagnosticGrant? = nil,
         onSignedIn: (() -> Void)? = nil,
         authentication: AccountAuthenticationPresentation? = nil) {
        self.allowsDiagnosticExport = allowsDiagnosticExport
        self.diagnosticCredential = diagnosticCredential
        self.diagnosticGrant = diagnosticGrant
        self.onSignedIn = onSignedIn
        _authentication = StateObject(wrappedValue: authentication ?? AccountAuthenticationPresentation())
    }

    private var working: Bool { authentication.working }
    private var diagnosticExportIsAllowed: Bool {
        allowsDiagnosticExport && (diagnosticCredential.map { CredentialScopeRegistry.shared.isCurrent($0) } ?? true)
            && (exportGrant?.permitsExport ?? true)
    }
    private var exportGrant: ProfilePickerToolsDiagnosticGrant? {
        if let diagnosticGrant { return diagnosticGrant }
        guard let credential = diagnosticCredential else { return nil }
        let sync = sync, store = ProfileStore.shared
        return .init(allowed: allowsDiagnosticExport, credential: credential, admission: {
            if sync.accountReconnectRequired || sync.accountRestoreState == .failed { return true }
            return !store.profiles.contains { $0.pin != nil }
        })
    }

    enum Mode: String, CaseIterable { case signIn = "Sign in", create = "Create", recover = "Recover" }
    @State private var mode: Mode = .signIn
    private var effectiveMode: Mode { sync.accountReconnectRequired ? .signIn : mode }
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var totp = ""
    @State private var needsTotp = false
    @State private var recoveryCodeInput = ""
    @State private var message: String?
    @State private var failed = false
    @State private var showConflict = false       // account already has data: ask which side to keep
    @State private var syncing = false
    @State private var syncNote: String?          // signed-in status line: the tri-state retry surface
    private struct QRPresentation: Identifiable { let id: UUID }
    @State private var qrPresentation: QRPresentation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("VortX account").screenTitleStyle()
                if let code = authentication.recoveryCodeForCurrentOwner(accountID: sync.account?.id) {
                    recoveryCodeCard(code)
                } else if authentication.working || authentication.reconciling {
                    ProgressView("Finishing sign-in…")
                } else if sync.isSignedIn, !sync.accountReconnectRequired, let account = sync.account {
                    signedIn(account)
                } else {
                    signedOut
                }
                if diagnosticExportIsAllowed { DiagnosticLogExportButton(grant: exportGrant) }
                // This screen is now VortX-account-only. The external sync providers (Trakt, SIMKL) moved
                // to the Integrations screen (IntegrationsSettingsView), alongside the Stremio connect card,
                // since they enrich VortX rather than belonging to the VortX account itself.
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .interactiveDismissDisabled(authentication.blocksDismissal)
        .navigationBarBackButtonHidden(authentication.blocksDismissal)
        .sheet(item: $qrPresentation) { presentation in
            qrSignInSheet(attempt: presentation.id)
                .environmentObject(sync)
                .onDisappear { cancelQR(attempt: presentation.id) }
        }
        .alert("Sync conflict", isPresented: $showConflict) {
            // Native data uses the causal merge/restore path, never a legacy whole-document override.
            if let decision = authentication.pendingConflict {
                Button("Merge both (keep all profiles)") {
                    resolveConflict(decision) { await sync.mergeBoth() ? .completed : .failed }
                }
                Button("Use account's data") { resolveConflict(decision) { await sync.useAccountData() } }
                Button("Not now", role: .cancel) { cancelConflict(decision) }
            }
        } message: {
            Text("This account's profiles differ from this device. Merge both to keep every profile (recommended), or restore the account's data. Saved data is not overwritten by a legacy device backup.")
        }
        .task {
            if sync.accountReconnectRequired { mode = .signIn; email = sync.account?.email ?? "" }
            await sync.refreshAccount()
        }
        .onValueChange(of: sync.accountReconnectRequired) { required in
            if required { mode = .signIn; email = sync.account?.email ?? "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in
            // Async outcomes and one-time codes cannot repaint a replacement credential epoch.
            authentication.credentialDidChange()
            password = ""; totp = ""; recoveryCodeInput = ""
            syncNote = nil
            syncing = false
            showConflict = false
        }
        .onValueChange(of: sync.lastSyncAt) { stamp in
            // A new durable receipt can retire a previous manual-action failure;
            // an old successful stamp must not hide a newer failed attempt.
            if stamp != nil, sync.synchronizationIsComplete { syncNote = nil }
        }
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
        .vortxSettingsCard()

        Text("Your profiles, settings, and metadata keys sync to this account, end-to-end encrypted. They also sync automatically a moment after any change.")
            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)

        if let decision = authentication.pendingConflict {
            // A system-dismissed alert does not silently discard its decision or trap Done.
            // Review reopens the same exact lease; Not now explicitly abandons it.
            Text("A sync decision is waiting. Review it or choose Not now to leave it unchanged.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Button("Review sync conflict") { reviewConflict(decision) }.buttonStyle(ChipButtonStyle())
            Button("Not now") { cancelConflict(decision) }.buttonStyle(ChipButtonStyle())
        }

        HStack(spacing: Theme.Space.md) {
            Button(syncing ? "Syncing…" : "Sync now") { syncNow() }
                .buttonStyle(PrimaryActionStyle())
                .disabled(syncing || authentication.blocksDismissal)
            Button("Sign out") { sync.signOut(); reset() }
                .buttonStyle(ChipButtonStyle(selected: false))
        }

        // Keep failures visible and retryable. A completed account round-trip may still have
        // a local change waiting, so do not show the backup claim until synchronization is complete.
        if let failure = sync.backupUploadFailure {
            // Observe the manager's live failure, not a copied string that survives an accepted retry.
            Text(failure.message).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        } else if let syncNote {
            Text(syncNote).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        } else {
            Text(MoveSeeding.backedUpLine(
                synchronizationIsComplete: sync.synchronizationIsComplete,
                pendingSettingsMessage: sync.pendingSettingsMessage
            ))
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
        Text(MoveSeeding.lastSyncLine(sync.lastSyncAt))
            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
    }

    // MARK: Signed out

    @ViewBuilder private var signedOut: some View {
        Group {
            if sync.accountReconnectRequired {
                Text("Reconnect your VortX account")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text("The server did not accept this device's session. Sign in again to reconnect. Your profiles and pending changes are still saved on this device.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            } else {
                Text("Optional. A free, end-to-end-encrypted account keeps your profiles, settings, and library safe across devices.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }

            Button("Sign in with QR code") { openQR() }
                .buttonStyle(ChipButtonStyle())
                .disabled(working)

            if !sync.accountReconnectRequired {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Button(m.rawValue) { mode = m; message = nil; needsTotp = false }
                            .buttonStyle(ChipButtonStyle(selected: mode == m))
                    }
                }
            }

            VStack(spacing: Theme.Space.md) {
                field(effectiveMode == .signIn ? "Email or username" : "Email", text: $email, content: .emailAddress)
                if effectiveMode == .create { field("Username", text: $username) }
                if effectiveMode == .recover { field("Recovery code (VX-…)", text: $recoveryCodeInput) }
                secureField(effectiveMode == .recover ? "New password" : "Password", text: $password)
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

    // Present the shared joiner directly: iOSSignInView pushes this screen for its email path,
    // so routing back through that view would create a recursive sign-in navigation flow.
    private func qrSignInSheet(attempt: UUID) -> some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                HStack {
                    Text("Sign in to VortX").font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    // In-content dismissal also works on Mac without touching the window toolbar.
                    Button("Cancel") { cancelQR(attempt: attempt) }
                        .buttonStyle(ChipButtonStyle())
                }
                VortXAccountJoinerView(onSignedIn: {
                    completeQR(attempt: attempt)
                })
                    .frame(maxWidth: .infinity)
                if diagnosticExportIsAllowed { DiagnosticLogExportButton(grant: exportGrant) }
            }
            .padding(Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private func openQR() {
        guard let attempt = authentication.beginQR() else { return }
        qrPresentation = QRPresentation(id: attempt)
    }

    private func cancelQR(attempt: UUID) {
        guard authentication.endQR(attempt: attempt) else { return }
        if qrPresentation?.id == attempt { qrPresentation = nil }
    }

    private func completeQR(attempt: UUID) {
        guard authentication.endQR(attempt: attempt) else { return }
        if qrPresentation?.id == attempt { qrPresentation = nil }
        onSignedIn?() // The joiner's unchanged protocol owns authenticated success.
    }

    private var actionLabel: String {
        switch effectiveMode { case .signIn: return "Sign in"; case .create: return "Create account"; case .recover: return "Reset password" }
    }
    private var canSubmit: Bool {
        guard !email.isEmpty, !password.isEmpty else { return false }
        if effectiveMode == .create && username.isEmpty { return false }
        if effectiveMode == .recover && recoveryCodeInput.isEmpty { return false }
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
            Button("I saved it") { completeAuthentication(acknowledgingCode: true) }
                .buttonStyle(PrimaryActionStyle())
                .disabled(working || authentication.reconciling)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    // MARK: Actions

    /// Run ONE conflict resolution, then re-run the account hydrate as a belt-and-braces pass:
    /// whichever side won, the engine should hold the account's owned add-ons + owner library
    /// right away, without waiting for a background/foreground cycle to re-check. Idempotent and
    /// never-zero guarded inside the manager (a .failed/.empty pull does nothing; install-only union).
    private func reviewConflict(_ decision: AccountActionLease) {
        guard authentication.pendingConflictIsCurrent(decision, accountID: sync.account?.id) else { return }
        showConflict = true
    }

    private func cancelConflict(_ decision: AccountActionLease) {
        guard authentication.cancelConflict(decision, accountID: sync.account?.id) else { return }
        showConflict = false
    }

    private func resolveConflict(_ decision: AccountActionLease,
                                 _ action: @escaping @MainActor () async -> VortXSyncManager.ConflictResolutionOutcome) {
        guard authentication.claimConflict(decision, accountID: sync.account?.id) else { return }
        showConflict = false
        syncing = true
        syncNote = nil
        Task { @MainActor in
            guard authentication.conflictActionIsCurrent(decision, accountID: sync.account?.id) else { return }
            let outcome = await action()
            guard authentication.conflictActionIsCurrent(decision, accountID: sync.account?.id) else { return }
            if outcome == .completed {
                await sync.hydrateEngineFromOwnedAddons(credentialCapture: decision.credential)
                guard authentication.conflictActionIsCurrent(decision, accountID: sync.account?.id) else { return }
            }
            switch outcome {
            case .completed: syncNote = nil
            case .pending: syncNote = "Your changes are still waiting to sync. Try again shortly."
            case .failed: syncNote = "Couldn't finish syncing. Your changes are still saved on this device. Try again."
            }
            syncing = false
            authentication.finishConflict(decision, accountID: sync.account?.id)
        }
    }

    /// Retain one exact signed-in owner through restore/probe/push and any resulting
    /// conflict decision. UI intent must never become an action for a replacement account.
    private func syncNow() {
        guard sync.isSignedIn, !syncing,
              let lease = authentication.beginManualSync(accountID: sync.account?.id) else { return }
        syncing = true
        syncNote = nil
        Task { @MainActor in
            guard authentication.manualSyncIsCurrent(lease, accountID: sync.account?.id) else { return }
            let restored = await sync.retryAccountRestore()
            guard authentication.manualSyncIsCurrent(lease, accountID: sync.account?.id) else { return }
            guard restored else {
                syncNote = "Couldn't load your account data yet. Your saved data has not been replaced. Try again."
                syncing = false
                authentication.finishManualSync(lease, accountID: sync.account?.id)
                return
            }
            let conflict = await sync.rosterConflictWithAccount()
            guard authentication.manualSyncIsCurrent(lease, accountID: sync.account?.id) else { return }
            switch conflict {
            case .conflict:
                guard authentication.holdManualConflict(lease, accountID: sync.account?.id) else { return }
                syncing = false
                showConflict = true
            case .unreachable:
                syncNote = "Could not reach VortX sync. Check your connection and try again."
                syncing = false
                authentication.finishManualSync(lease, accountID: sync.account?.id)
            case .noConflict:
                let pushed = await sync.pushThisDevice()
                guard authentication.manualSyncIsCurrent(lease, accountID: sync.account?.id) else { return }
                syncNote = pushed || sync.backupUploadFailure != nil
                    ? nil
                    : "Couldn't sync your latest changes. They are still saved on this device. Try again."
                syncing = false
                authentication.finishManualSync(lease, accountID: sync.account?.id)
            }
        }
    }

    private func submit() {
        guard let attempt = authentication.begin() else { return }
        message = nil; failed = false
        let submittedMode = effectiveMode
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        let name = username.trimmingCharacters(in: .whitespaces)
        let submittedPassword = password
        let submittedTotp = needsTotp ? totp : nil
        let submittedRecoveryCode = recoveryCodeInput
        let reconnect = sync.accountReconnectRequired
        Task { @MainActor in
            guard authentication.mayStartRequest(attempt: attempt) else { return }
            let result: VortXSyncManager.AuthResult
            switch submittedMode {
            case .signIn:
                result = await sync.signIn(login: mail, password: submittedPassword, totp: submittedTotp,
                                          requireCurrentAccount: reconnect, onAuthenticated: { receipt in
                    self.authentication.recordAuthenticated(receipt, attempt: attempt, accountID: self.sync.account?.id)
                })
            case .create:
                let (outcome, _) = await sync.register(email: mail, username: name, password: submittedPassword,
                                                     onAuthenticated: { receipt, code in
                    self.authentication.recordAuthenticated(receipt, recoveryCode: code, attempt: attempt,
                                                       accountID: self.sync.account?.id)
                })
                result = outcome
            case .recover:
                result = await sync.recover(email: mail, recoveryCode: submittedRecoveryCode, newPassword: submittedPassword,
                                            onAuthenticated: { receipt in
                    self.authentication.recordAuthenticated(receipt, attempt: attempt, accountID: self.sync.account?.id)
                })
            }
            handle(result, attempt: attempt)
        }
    }

    private func handle(_ result: VortXSyncManager.AuthResult, attempt: UUID) {
        guard authentication.finishAuthentication(attempt: attempt, succeeded: result == .ok,
                                                  accountID: sync.account?.id) else { return }
        switch result {
        case .ok:
            password = ""; totp = ""; recoveryCodeInput = ""; needsTotp = false
            // Registration has already recorded its code with the exact adopted owner.
            // Neither dismissal nor reconcile may consume that code before acknowledgement.
            if authentication.recoveryCode != nil { return }
            completeAuthentication()
        case .totpRequired:
            needsTotp = true; message = "Enter your authenticator code."; failed = false
        case .failed(let msg):
            message = msg; failed = true
        }
    }

    private func completeAuthentication(acknowledgingCode: Bool = false) {
        guard let owner = authentication.beginCompletion(acknowledgingCode: acknowledgingCode,
                                                         accountID: sync.account?.id) else { return }
        if let onSignedIn {
            guard authentication.finishCompletion(owner, accountID: sync.account?.id),
                  owner.isCurrent(accountID: sync.account?.id) else { return }
            onSignedIn() // adopt() owns network restore after this sheet disappears.
            return
        }
        Task { @MainActor in
            guard authentication.completionIsCurrent(owner, accountID: sync.account?.id) else { return }
            let outcome = await sync.reconcileAfterSignIn()
            guard authentication.completionIsCurrent(owner, accountID: sync.account?.id) else { return }
            let decision: AccountActionLease?
            switch outcome {
            case .hasAccountData:
                guard let held = authentication.holdConflict(from: owner, accountID: sync.account?.id) else { return }
                decision = held
            case .seededFromDevice: decision = nil
            case .unreachable:
                decision = nil
                syncNote = "Signed in, but VortX sync could not be reached. It will retry; you can also use Sync now."
            }
            await sync.hydrateEngineFromOwnedAddons(credentialCapture: owner.credential)
            guard authentication.completionIsCurrent(owner, accountID: sync.account?.id) else { return }
            authentication.finishCompletion(owner, accountID: sync.account?.id)
            if let decision, authentication.pendingConflictIsCurrent(decision, accountID: sync.account?.id) {
                showConflict = true
            }
        }
    }

    private func reset() {
        email = ""; username = ""; password = ""; totp = ""; recoveryCodeInput = ""
        needsTotp = false; message = nil; failed = false; mode = .signIn
        authentication.invalidate()
        syncNote = nil
        qrPresentation = nil
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
