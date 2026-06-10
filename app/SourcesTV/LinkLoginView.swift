import SwiftUI
import CoreImage

/// QR/code sign-in panel for Stremio's link auth flow.
/// Owns polling while visible and stops automatically when removed from the view tree.
struct LinkLoginView: View {
    @ObservedObject var account: StremioAccount

    @State private var busy = false
    @State private var code: LinkAuthService.LinkCode?
    @State private var qrImage: UIImage?
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(2)
    private static let timeout: TimeInterval = 5 * 60

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            qrCard
            codeDetails
            statusText
            refreshButton
        }
        .frame(width: 760)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
                .frame(width: 330, height: 330)
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 286, height: 286)
            } else if busy {
                ProgressView().controlSize(.large).tint(Theme.Palette.accent)
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
                    .font(.system(size: 58, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Go to link.stremio.com and enter this code")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(code.link)
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
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
            Text(busy ? "Creating code…" : "Refresh code").frame(width: 280)
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
                while !Task.isCancelled {
                    if Date() >= deadline {
                        await MainActor.run {
                            status = ""
                            errorMessage = "This code expired. Refresh it to try again."
                        }
                        return
                    }
                    if let token = try await LinkAuthService.read(code: created.code) {
                        await MainActor.run {
                            status = "Signing in…"
                            errorMessage = nil
                        }
                        await account.signInWithAuthKey(token)
                        return
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

    private static func makeQRCodeImage(_ string: String) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
