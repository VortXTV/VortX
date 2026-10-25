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

    private enum Status: Equatable { case starting, waiting, saving, backedUp, pending, failed }

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

            case .backedUp:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(Theme.Palette.accent)
                Text("Backed up to your VortX account")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                Button("Done") { dismiss() }.buttonStyle(PrimaryActionStyle())

            case .failed:
                Text("That backup did not complete. Try again.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.danger)
                Button("Try again") { start() }.buttonStyle(ChipButtonStyle())

            case .pending:
                Text("Your changes are still waiting to sync. Try again shortly.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                Button("Try again") { start() }.buttonStyle(ChipButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { start() }
        .onDisappear { stop() }
        .alert("This account already has data", isPresented: $showConflict) {
            Button("Merge both (keep all profiles)") { resolve { await $0.mergeBoth() ? .completed : .failed } }
            Button("Use account's data") { resolve { await $0.useAccountData() } }
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
    }

    private func pollLoop(_ s: VortXSyncManager.QrJoinSession, generation: UUID) async {
        while !Task.isCancelled, pollGeneration == generation {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if Task.isCancelled || pollGeneration != generation { return }
            let result = await VortXSyncManager.shared.qrPoll(s)
            if Task.isCancelled || pollGeneration != generation { return }
            switch result {
            case .pending, .transportError:
                continue                             // reachable-but-idle, or a retriable relay blip; keep polling
            case .expired:
                start(); return                      // the code aged out; mint a fresh one
            case .failed:
                status = .failed; return
            case .signedIn:
                guard !Task.isCancelled else { return }
                // BACKUP completion, NOT the joiner's blind useAccountData(): an empty account is already
                // seeded from this device by reconcileAfterSignIn (.seededFromDevice), so we just confirm; a
                // non-empty account asks which side to keep, defaulting to keeping THIS device.
                let result = await VortXSyncManager.shared.reconcileAfterSignIn()
                guard !Task.isCancelled else { return }
                switch result {
                case .hasAccountData: showConflict = true
                case .seededFromDevice: status = .backedUp
                case .unreachable: status = .failed
                }
                return
            }
        }
    }

    /// Publish the actual conflict result; a failed or queued operation is not a completed backup.
    private func resolve(_ op: @escaping (VortXSyncManager) async -> VortXSyncManager.ConflictResolutionOutcome) {
        poller?.cancel()
        status = .saving
        poller = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let outcome = await op(VortXSyncManager.shared)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .completed: status = .backedUp
            case .pending: status = .pending
            case .failed: status = .failed
            }
        }
    }
}
