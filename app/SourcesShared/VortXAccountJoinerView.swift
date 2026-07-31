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
    // Honesty state so the screen is never a silent forever-"waiting": the reducer folds each poll result
    // into an action, `reachTrouble` surfaces recurring relay/transport failure under the QR, and
    // `codeMintedAt` lets a stale code re-mint even if the relay never reports it expired (see #153).
    @State private var reducer = QrJoinerReducer()
    @State private var reachTrouble = false
    @State private var codeMintedAt = Date()

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
    // The approver is vortx.tv/approve: a REAL PAGE on the account site (vortx-site, src/pages/approve.astro),
    // which reads `c` and `k` from location.search. That is also where the VortX account itself lives (login,
    // dashboard), and it is the address this screen's own caption tells the user to type. It is NOT the
    // hash-routed web player at web.vortx.tv, which is a separate origin with a separate signed-in session.
    //
    // beta.7 through beta.9 pointed this at "https://vortx.tv/#/approve", which put the params behind a hash
    // on the marketing site's home route: the browser landed on the home page and the approve page never ran.
    // That was a regression, not the original #153 defect (the original was the approve page's dead-end
    // sign-in link, which dropped `c` and `k` on the way to /login). Both are fixed; the site also folds a
    // stray "#/approve?..." hash back onto /approve so beta.7-9 codes already in the field still resolve.
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
                if reachTrouble {
                    // Recurring relay/transport failure: keep polling, but stop implying we are simply
                    // waiting for the user to approve. Never a silent stall (#153).
                    Text("Trouble reaching VortX. Still trying…")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                        .multilineTextAlignment(.center).frame(maxWidth: Self.captionMaxWidth)
                }

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
        reachTrouble = false
        reducer = QrJoinerReducer()          // fresh code, fresh error/age accounting
        poller = Task { @MainActor in
            guard let s = await VortXSyncManager.shared.qrStart() else { status = .failed; return }
            session = s
            codeMintedAt = Date()
            // The QR opens vortx.tv/approve carrying the code plus this device's ephemeral public key, so the
            // approving device can wrap the data key to us. Both values are URL-safe (base64url / A-Z2-9), so
            // they need no escaping in the query string (see the approveBase note above, #153).
            qrImage = QRCodeImage.make("\(Self.approveBase)?c=\(s.code)&k=\(s.devicePublicKey)")
            status = .waiting
            await pollLoop(s)
        }
    }

    private func pollLoop(_ s: VortXSyncManager.QrJoinSession) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if Task.isCancelled { return }
            let result = await VortXSyncManager.shared.qrPoll(s)
            if Task.isCancelled { return }
            switch reducer.onResult(result, codeAge: Date().timeIntervalSince(codeMintedAt)) {
            case .keepWaiting(let trouble):
                if reachTrouble != trouble { reachTrouble = trouble }
                continue
            case .remint:
                start(); return                      // code aged out (or a shown code went stale); mint a fresh one
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

/// Pure decision layer for the joiner poll loop, split out of the SwiftUI view so it can be unit-tested
/// off device (VortX's Apple app has no XCTest bundle; see app/Tests/QRJoinerFlowTests.swift). It folds a
/// stream of `VortXSyncManager.QrJoinResult` into a UI action and GUARANTEES the screen is never a silent
/// forever-"waiting": expiry always re-mints, recurring relay/transport trouble is surfaced, and a code
/// that has been shown too long is re-minted even if the relay never reports it expired.
struct QrJoinerReducer {
    /// Consecutive retriable (transport/relay) errors seen since we last reached the relay.
    private(set) var consecutiveErrors = 0
    /// Surface "trouble reaching VortX" once retriable errors recur this many times in a row
    /// (~ threshold × pollInterval seconds of failure before the notice appears).
    let errorNoticeThreshold: Int
    /// Re-mint a code that has been shown at least this long without approval, as a backstop against a
    /// relay that keeps a pairing alive indefinitely, so the shown code can never silently rot.
    let codeMaxAge: TimeInterval

    init(errorNoticeThreshold: Int = 4, codeMaxAge: TimeInterval = 240) {
        self.errorNoticeThreshold = errorNoticeThreshold
        self.codeMaxAge = codeMaxAge
    }

    enum Action: Equatable {
        case keepWaiting(reachTrouble: Bool)
        case remint
        case signedIn(email: String)
        case failed
    }

    mutating func onResult(_ result: VortXSyncManager.QrJoinResult, codeAge: TimeInterval) -> Action {
        switch result {
        case .signedIn(let email):
            return .signedIn(email: email)
        case .failed:
            return .failed
        case .expired:
            consecutiveErrors = 0
            return .remint
        case .transportError:
            consecutiveErrors += 1
            return .keepWaiting(reachTrouble: consecutiveErrors >= errorNoticeThreshold)
        case .pending:
            // We reached the relay, so clear any trouble state. Re-mint a stale code as a backstop.
            consecutiveErrors = 0
            if codeAge >= codeMaxAge { return .remint }
            return .keepWaiting(reachTrouble: false)
        }
    }
}
