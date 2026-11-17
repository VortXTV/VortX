import SwiftUI

/// tvOS "Back up": save THIS Apple TV's data (profiles, theme, player preferences, add-ons, library) up
/// to a VortX account, by scanning a QR with a phone or browser already signed in to VortX.
///
/// This is the BACKUP direction, and it deliberately does NOT reuse VortXAccountJoinerView's onSignedIn.
/// That path calls useAccountData() unconditionally on any non-empty account (VortXAccountJoinerView.swift
/// ~:95-98), which for the backup direction would OVERWRITE this device's data with the account's:
/// silent local-data loss. Instead this drives VortXSyncManager.qrStart/qrPoll with a custom completion:
///
///  - An EMPTY account is already seeded from this device by reconcileAfterSignIn (.seededFromDevice), so
///    the backup is done the moment sign-in lands; we just confirm success.
///  - An account that ALREADY holds data offers native merge/restore. Only legacy builds may
///    offer a whole-device override; native export deliberately rejects that operation.
///
/// The QR carries only a ~100-150 byte pairing URL (the short code plus this TV's ephemeral public key);
/// the ~1MB backup doc rides HTTPS through VortXSyncManager's sync doc, never through the QR.
struct BackupExportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var session: VortXSyncManager.QrJoinSession?
    @State private var qrImage: CGImage?
    @State private var status: Status = .starting
    @State private var poller: Task<Void, Never>?
    @State private var pollGeneration = UUID()
    @State private var showConflict = false
    @State private var decisionOwner: VortXAuthenticationReceipt?
    @State private var retryDecision: BackupDecision?

    private enum Status: Equatable { case starting, waiting, decision, saving, backedUp, pending, failed }
    private enum BackupDecision { case merge, useAccount }

    private static let qrSize: CGFloat = 320
    // A real page on the account site (vortx-site, src/pages/approve.astro), which reads `c` and `k` out of
    // location.search. Kept identical to the sign-in joiner's approveBase; see the long note there (#153).
    private static let approveBase = "https://vortx.tv/approve"
    private static let pollInterval: UInt64 = 2_000_000_000   // 2s

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Text("Back up").screenTitleStyle()

            switch status {
            case .starting:
                ProgressView().tint(Theme.Palette.accent)
                Text("Preparing your code…")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)

            case .waiting:
                if let qrImage {
                    Image(decorative: qrImage, scale: 1)
                        .interpolation(.none).resizable().scaledToFit()
                        .frame(width: Self.qrSize, height: Self.qrSize)
                        .padding(Theme.Space.sm)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                if let code = session?.code {
                    Text(code)
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Text("Scan the code, or go to vortx.tv/approve and enter it, on a phone or browser signed in to VortX. Your profiles, settings, add-ons, and library save to that account.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 660)

            case .saving:
                ProgressView().tint(Theme.Palette.accent)
                Text("Saving to your VortX account…")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)

            case .decision:
                Text("Choose how to combine or restore the profiles on this Apple TV.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                Button("Review backup choices") { showConflict = true }.buttonStyle(PrimaryActionStyle())

            case .backedUp:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(Theme.Palette.accent)
                Text("Backed up to your VortX account")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                Button("Done") { dismiss() }.buttonStyle(PrimaryActionStyle())

            case .failed:
                Text("That backup did not complete. Try again.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.danger)
                Button("Try again") { retry() }.buttonStyle(ChipButtonStyle())

            case .pending:
                Text("Your changes are still waiting to sync. Try again shortly.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                Button("Try again") { retry() }.buttonStyle(ChipButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { start() }
        .onDisappear { stop() }
        .alert("This account already has data", isPresented: $showConflict) {
            Button("Merge both (keep all profiles)") { resolve(.merge) }
            Button("Use account's data") { resolve(.useAccount) }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("This VortX account already holds synced data. Merge both to keep every profile, or restore the account's data. Native backups do not overwrite an account with a legacy device snapshot.")
        }
    }

    private func start() {
        stop()
        let generation = pollGeneration
        status = .starting
        poller = Task { @MainActor in
            let result = await VortXSyncManager.shared.qrStart()
            guard !Task.isCancelled, pollGeneration == generation else {
                if let result { VortXSyncManager.shared.qrCancel(result) }
                return
            }
            guard let s = result else { status = .failed; return }
            session = s
            // The QR opens vortx.tv/approve carrying the code plus this TV's ephemeral public key, so the
            // approving device can wrap the data key to us. Both values are URL-safe (base64url / A-Z2-9).
            qrImage = QRCodeImage.make("\(Self.approveBase)?c=\(s.code)&k=\(s.devicePublicKey)")
            status = .waiting
            await pollLoop(s, generation: generation)
        }
    }

    private func stop() {
        pollGeneration = UUID()
        poller?.cancel(); poller = nil
        if let session { VortXSyncManager.shared.qrCancel(session) }
        session = nil; qrImage = nil
        decisionOwner = nil; retryDecision = nil; showConflict = false
    }

    private func pollLoop(_ s: VortXSyncManager.QrJoinSession, generation: UUID) async {
        while !Task.isCancelled, pollGeneration == generation {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if Task.isCancelled || pollGeneration != generation { return }
            let result = await VortXSyncManager.shared.qrPoll(s, onAuthenticated: { receipt in
                if !Task.isCancelled, pollGeneration == generation { decisionOwner = receipt }
            })
            if Task.isCancelled || pollGeneration != generation { return }
            switch result {
            case .pending, .transportError:
                continue                             // reachable-but-idle, or a retriable relay blip; keep polling
            case .expired:
                start(); return                      // the code aged out; mint a fresh one
            case .failed:
                status = .failed; return
            case .signedIn:
                guard let owner = decisionOwner, isCurrent(owner) else { status = .failed; return }
                await finishPairing(owner, generation: generation)
                return
            }
        }
    }

    private func isCurrent(_ owner: VortXAuthenticationReceipt) -> Bool {
        decisionOwner == owner && CredentialScopeRegistry.shared.isCurrent(owner.credential)
            && VortXSyncManager.shared.isSignedIn && VortXSyncManager.shared.account?.id == owner.accountID
    }

    private func finishPairing(_ owner: VortXAuthenticationReceipt, generation: UUID) async {
        guard !Task.isCancelled, pollGeneration == generation, isCurrent(owner) else { return }
        status = .saving
        let result = await VortXSyncManager.shared.reconcileAfterSignIn(credentialCapture: owner.credential)
        guard !Task.isCancelled, pollGeneration == generation else { return }
        guard isCurrent(owner) else { status = .failed; return }
        switch result {
        case .hasAccountData: status = .decision; showConflict = true
        case .seededFromDevice: status = .backedUp
        case .unreachable: status = .failed
        }
    }

    private func retry() {
        guard let owner = decisionOwner, isCurrent(owner), !VortXSyncManager.shared.accountSignInAgainRequired else {
            start(); return
        }
        if let retryDecision { resolve(retryDecision); return }
        poller?.cancel()
        let generation = pollGeneration
        poller = Task { @MainActor in await finishPairing(owner, generation: generation) }
    }

    /// The decision and any retry belong to the exact account this QR adopted.
    private func resolve(_ decision: BackupDecision) {
        guard let owner = decisionOwner, isCurrent(owner) else { status = .failed; return }
        poller?.cancel()
        retryDecision = decision
        let generation = pollGeneration
        status = .saving
        poller = Task { @MainActor in
            guard !Task.isCancelled, pollGeneration == generation, isCurrent(owner) else { return }
            let manager = VortXSyncManager.shared
            let outcome: VortXSyncManager.ConflictResolutionOutcome
            switch decision {
            case .merge: outcome = await manager.mergeBoth(credentialCapture: owner.credential)
            case .useAccount: outcome = await manager.useAccountData(credentialCapture: owner.credential)
            }
            guard !Task.isCancelled, pollGeneration == generation else { return }
            guard isCurrent(owner) else { status = .failed; return }
            switch outcome {
            case .completed: retryDecision = nil; status = .backedUp
            case .pending: status = .pending
            case .failed: status = .failed
            }
        }
    }
}
