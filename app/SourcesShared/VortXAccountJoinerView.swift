import SwiftUI

/// VortX-account sign-in by QR pairing (the JOINER side of VortXSyncManager.qrStart/qrPoll). Cross-platform:
/// used on Apple TV (LoginView, BackupImportView) and on iPhone/iPad/Mac (iOSSignInView). It lives in
/// SourcesShared so every Apple target compiles it; the QR/code/caption sizing branches by platform so the
/// Apple TV keeps its 10-foot layout while phone/tablet/Mac render a compact card that fits a sheet.
///
/// A device signs into the VortX account by showing a QR + short code. The user approves on a device already
/// signed into VortX (a phone, or vortx.tv/approve in a browser), which hands over the sync data key
/// ECDH-wrapped to this device's ephemeral key. The relay never sees the key. This signs into the VortX
/// account (the one that owns your add-ons, library, and sync), NOT a Stremio account.
struct VortXAccountJoinerView: View {
    /// Called on the main actor once this device is signed into VortX and its account data has been pulled.
    var onSignedIn: () -> Void

    @State private var session: VortXSyncManager.QrJoinSession?
    @State private var qrImage: CGImage?
    @State private var status: Status = .starting
    @State private var poller: Task<Void, Never>?

    private enum Status: Equatable { case starting, waiting, signedIn(String), failed }

    // Sizing branches by platform (H: #if os(tvOS) per WS2): the Apple TV renders at 10-foot scale (a large
    // QR + code read across the room), while phone/tablet/Mac get a compact card sized for a sign-in sheet.
    // tvOS values are unchanged from the TV-only original so the shipping Apple TV layout is byte-identical.
    #if os(tvOS)
    private static let qrSize: CGFloat = 320
    private static let codeFontSize: CGFloat = 42
    private static let checkFontSize: CGFloat = 54
    private static let captionMaxWidth: CGFloat = 660
    #else
    private static let qrSize: CGFloat = 232
    private static let codeFontSize: CGFloat = 34
    private static let checkFontSize: CGFloat = 46
    private static let captionMaxWidth: CGFloat = 420
    #endif
    private static let approveBase = "https://vortx.tv/approve"
    private static let pollInterval: UInt64 = 2_000_000_000   // 2s

    var body: some View {
        VStack(spacing: Theme.Space.md) {
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
                        .font(.system(size: Self.codeFontSize, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Text("Scan the code, or go to vortx.tv/approve and enter it, on a phone or browser signed in to VortX.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: Self.captionMaxWidth)

            case .signedIn(let email):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Self.checkFontSize)).foregroundStyle(Theme.Palette.accent)
                Text(email.isEmpty ? "Signed in to VortX" : "Signed in as \(email)")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)

            case .failed:
                Text("That sign-in did not complete. Try again.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.danger)
                Button("Try again") { start() }.buttonStyle(ChipButtonStyle())
            }
        }
        .onAppear { start() }
        .onDisappear { poller?.cancel() }
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
            case .signedIn(let email):
                status = .signedIn(email)
                // Pull the account's add-ons/library/settings onto this fresh TV, then hydrate the engine.
                if await VortXSyncManager.shared.reconcileAfterSignIn() == .hasAccountData {
                    await VortXSyncManager.shared.useAccountData()
                }
                await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                try? await Task.sleep(nanoseconds: 900_000_000)   // let the check mark land
                onSignedIn()
                return
            }
        }
    }
}
