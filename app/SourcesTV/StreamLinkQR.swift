import SwiftUI
import CoreImage.CIFilterBuiltins

/// The TV answer to "copy the stream link": a QR code you scan with your phone,
/// since tvOS has no pasteboard the viewer can reach. Direct and debrid streams
/// share their URL; torrents share a magnet rebuilt from the info hash, because
/// a 127.0.0.1 server URL means nothing to another device.
struct StreamLinkQRView: View {
    let title: String
    let link: String

    var body: some View {
        ZStack {
            Theme.Palette.canvas.opacity(0.94).ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Text(title)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let image = Self.qrImage(for: link) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 420, height: 420)
                        .padding(Theme.Space.md)
                        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                } else {
                    Text("Could not build a code for this link.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                }
                Text(link)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 900)
                Text("Scan with your phone to open this stream there  ·  Press Back to dismiss")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Space.screenEdge)
        }
        .transition(.opacity)
    }

    static func qrImage(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
