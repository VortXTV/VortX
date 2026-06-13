import SwiftUI
import CoreImage

/// QR/code sign-in panel for Stremio's link auth flow.
/// Owns polling while visible and stops automatically when removed from the view tree.
struct LinkLoginView: View {
    @ObservedObject var account: StremioAccount

    @State private var busy = false
    @State private var code: LinkAuthService.LinkCode?
    // Held as a CGImage rather than UIImage: CGImage is cross-platform (iOS / tvOS / macOS), so this
    // view compiles on the Mac target without a UIImage/NSImage split. CIContext yields a CGImage
    // directly, and SwiftUI's `Image(decorative:scale:)` renders it on every platform.
    @State private var qrImage: CGImage?
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(2)
    private static let timeout: TimeInterval = 5 * 60
    // ~10s of solid failures (5 polls at 2s) before surfacing the error, so a one-off blip is
    // ridden out but a real outage stops looking like an endless "Waiting for sign-in…".
    private static let maxConsecutiveFailures = 5

    // tvOS is viewed at ten feet, so its QR / code / panel are large. Phone and Mac are viewed at
    // arm's length, so size everything down (QR ~220pt, code ~40pt mono) and let the panel be fluid.
    #if os(tvOS)
    private static let panelWidth: CGFloat? = 760
    private static let cardSize: CGFloat = 330
    private static let qrSize: CGFloat = 286
    private static let codeFontSize: CGFloat = 58
    private static let linkFontSize: CGFloat = 20
    private static let controlWidth: CGFloat = 280
    #else
    private static let panelWidth: CGFloat? = nil
    private static let cardSize: CGFloat = 252
    private static let qrSize: CGFloat = 220
    private static let codeFontSize: CGFloat = 40
    private static let linkFontSize: CGFloat = 14
    private static let controlWidth: CGFloat = 240
    #endif

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            qrCard
            codeDetails
            statusText
            refreshButton
        }
        .frame(width: Self.panelWidth)
        .frame(maxWidth: .infinity)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
                .frame(width: Self.cardSize, height: Self.cardSize)
            if let qrImage {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.qrSize, height: Self.qrSize)
            } else if busy {
                // BigSpinner lives in SourcesTV (not compiled into iOS/macOS); inline its identical
                // body — ProgressView at 1.5x with the accent tint — for the non-tvOS targets.
                #if os(tvOS)
                BigSpinner()
                #else
                ProgressView().scaleEffect(1.5).tint(Theme.Palette.accent)
                #endif
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 110))
                    .foregroundStyle(.black.opacity(0.25))
            }
        }
    }

    @ViewBuilder private var codeDetails: some View {
        if let code {
            VStack(spacing: 8) {
                Text(code.code)
                    .font(.system(size: Self.codeFontSize, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Go to link.stremio.com and enter this code")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Text(code.link)
                    .font(.system(size: Self.linkFontSize, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        if !status.isEmpty {
            Text(status)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        if let errorMessage {
            Text(errorMessage)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.danger)
                .multilineTextAlignment(.center)
        }
    }

    private var refreshButton: some View {
        Button {
            start()
        } label: {
            Text(busy ? "Creating code…" : "Refresh code").frame(width: Self.controlWidth)
        }
        .buttonStyle(PrimaryActionStyle())
        .disabled(busy)
    }

    private func start() {
        stop()
        busy = true
        code = nil
        qrImage = nil
        errorMessage = nil
        status = "Creating a sign-in code…"

        pollTask = Task {
            do {
                let created = try await LinkAuthService.create()
                let image = Self.makeQRCodeImage(created.link)
                await MainActor.run {
                    code = created
                    qrImage = image
                    busy = false
                    status = "Waiting for sign-in…"
                }

                let deadline = Date().addingTimeInterval(Self.timeout)
                // A single network blip must not kill the flow, but a persistent failure (server
                // down, DNS gone, the link service erroring) must NOT spin silently forever — after
                // a short run of consecutive failures we surface the last error so the user can act.
                var consecutiveFailures = 0
                while !Task.isCancelled {
                    if Date() >= deadline {
                        await MainActor.run {
                            status = ""
                            errorMessage = "This code expired. Refresh it to try again."
                        }
                        return
                    }
                    do {
                        switch try await LinkAuthService.read(code: created.code) {
                        case .authKey(let token):
                            await MainActor.run {
                                status = "Signing in…"
                                errorMessage = nil
                            }
                            // `read` only proves the link service handed back a key — NOT that the
                            // main account API still honours it. A rejected/expired token is gated
                            // here: validate against api.strem.io first, and only commit to a
                            // signed-in state once the session is confirmed. On failure we surface
                            // the message and leave the panel open (no flip to signed-in, no
                            // dismiss), so a dead token can never look like a successful sign-in
                            // with an empty add-on list.
                            do {
                                try await LinkAuthService.validate(authKey: token)
                            } catch {
                                let message = error.localizedDescription
                                await MainActor.run {
                                    status = ""
                                    errorMessage = message
                                }
                                return
                            }
                            await account.signInWithAuthKey(token)
                            return
                        case .pending:
                            consecutiveFailures = 0
                            await MainActor.run {
                                if status.isEmpty { status = "Waiting for sign-in…" }
                                errorMessage = nil
                            }
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        // Tolerate a few transient failures, then make the problem visible instead
                        // of leaving the panel stuck on "Waiting for sign-in…".
                        consecutiveFailures += 1
                        if consecutiveFailures >= Self.maxConsecutiveFailures {
                            let message = error.localizedDescription
                            await MainActor.run {
                                status = ""
                                errorMessage = message
                            }
                            return
                        }
                    }
                    try await Task.sleep(for: Self.pollInterval)
                }
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    busy = false
                    status = ""
                    errorMessage = message
                }
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private static func makeQRCodeImage(_ string: String) -> CGImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        // CIContext yields a CGImage directly — cross-platform, no UIImage/NSImage wrap needed.
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
