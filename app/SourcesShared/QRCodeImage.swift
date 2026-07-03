import CoreImage

/// Shared QR-code rendering, the same CIFilter("CIQRCodeGenerator") approach `LinkLoginView` and the
/// per-add-on Configure sheet use. Returns a cross-platform `CGImage` (iOS / tvOS / macOS): `CIContext`
/// yields a `CGImage` directly, so callers render it with `Image(decorative:scale:)` on every platform
/// without a UIImage / NSImage split.
///
/// Kept as a free function in `SourcesShared` so the Install-by-QR pairing view can reuse the exact
/// generator without duplicating it or reaching into another view's private helper.
enum QRCodeImage {
    /// `string` → a QR `CGImage`, or nil if the string can't be encoded. Medium error correction, scaled
    /// up 12× so it stays crisp when SwiftUI resizes it with `.interpolation(.none)`.
    static func make(_ string: String) -> CGImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
