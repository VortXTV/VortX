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
///  - An account that ALREADY holds data shows the SAME three-way conflict SyncSettingsView presents
///    (SyncSettingsView.swift ~:43-45), but the primary/default button is "Keep this device"
///    (pushThisDevice()), because the user came here to SAVE this Apple TV's data.
///
/// The QR carries only a ~100-150 byte pairing URL (the short code plus this TV's ephemeral public key);
/// the ~1MB backup doc rides HTTPS through VortXSyncManager's sync doc, never through the QR.
struct BackupExportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var session: VortXSyncManager.QrJoinSession?
    @State private var qrImage: CGImage?
    @State private var status: Status = .starting
    @State private var poller: Task<Void, Never>?
    @State private var showConflict = false

    private enum Status: Equatable { case starting, waiting, saving, backedUp, failed }

    private static let qrSize: CGFloat = 320
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { start() }
        .onDisappear { poller?.cancel() }
        .alert("This account already has data", isPresented: $showConflict) {
            // The SAME three-way choice SyncSettingsView offers (mergeBoth / useAccountData / pushThisDevice),
            // but the BACKUP default is "Keep this device": the user came here to SAVE this Apple TV's data,
            // so pushThisDevice() is the primary button. None of the three can silently drop a profile
            // (syncDown unions the local roster back in even on "Use account's data").
            // keepThisDeviceOverridingAccount, not pushThisDevice: reached only after the account's doc was
            // positively READ, so this is the user's informed choice to overwrite it and the one push allowed
            // past the #145 restore gate.
            Button("Keep this device") { resolve { await $0.keepThisDeviceOverridingAccount() } }
            Button("Merge both (keep all profiles)") { resolve { await $0.mergeBoth() } }
            Button("Use account's data") { resolve { await $0.useAccountData() } }
        } message: {
            Text("This VortX account already holds synced data. Keep this device to save this Apple TV's data over it, merge both to keep every profile, or use the account's data instead.")
        }
    }

    private func start() {
        poller?.cancel()
        status = .starting
        poller = Task { @MainActor in
            guard let s = await VortXSyncManager.shared.qrStart() else { status = .failed; return }
            session = s
            // The QR opens vortx.tv/approve carrying the code plus this TV's ephemeral public key, so the
            // approving device can wrap the data key to us. Both values are URL-safe (base64url / A-Z2-9).
            qrImage = QRCodeImage.make("\(Self.approveBase)?c=\(s.code)&k=\(s.devicePublicKey)")
            status = .waiting
            await pollLoop(s)
        }
    }

    private func pollLoop(_ s: VortXSyncManager.QrJoinSession) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if Task.isCancelled { return }
            switch await VortXSyncManager.shared.qrPoll(s) {
            case .pending:
                continue
            case .expired:
                start(); return                      // the code aged out; mint a fresh one
            case .failed:
                status = .failed; return
            case .signedIn:
                // BACKUP completion, NOT the joiner's blind useAccountData(): an empty account is already
                // seeded from this device by reconcileAfterSignIn (.seededFromDevice), so we just confirm; a
                // non-empty account asks which side to keep, defaulting to keeping THIS device.
                if await VortXSyncManager.shared.reconcileAfterSignIn() == .hasAccountData {
                    showConflict = true
                } else {
                    status = .backedUp
                }
                return
            }
        }
    }

    /// Run one of the three conflict resolutions, then confirm the backup landed. Each op is @discardableResult
    /// (or Void), so the closure body discards any Bool and returns Void.
    private func resolve(_ op: @escaping (VortXSyncManager) async -> Void) {
        status = .saving
        Task { @MainActor in
            await op(VortXSyncManager.shared)
            status = .backedUp
        }
    }
}
