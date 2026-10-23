import Foundation
import CoreGraphics
import ImageIO

/// Static artwork supplied by a collection or catalog uses the same guarded transport as catalogs.
/// Callers fence their current view/source generation after awaiting `load`, before publishing art.
enum XperienceArtworkClient {
    static let maximumSourceDimension = 8_192
    static let maximumSourcePixels = 16_777_216
    static let maximumThumbnailDimension = 2_048
    static let maximumDecodedPixels = 4_194_304
    /// Post-decode acceptance bound for returned rows, not a peak decoder-memory guarantee.
    static let maximumDecodedBytes = 32 * 1_024 * 1_024

    enum Failure: Error, Equatable, LocalizedError {
        case unavailable
        case unsupportedImage

        var errorDescription: String? {
            switch self {
            case .unavailable: return "This artwork could not be loaded."
            case .unsupportedImage: return "This artwork is not a supported static image."
            }
        }
    }

    static func load(_ suppliedURL: String) async throws -> Data {
        try Task.checkCancellation()
        guard let url = URL(string: suppliedURL) else { throw Failure.unavailable }
        do {
            let response = try await AddonURLGuard.fetch(url, context: .xperienceArtwork)
            try Task.checkCancellation()
            return response.data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw Failure.unavailable
        }
    }

    /// Inspect dimensions before decoding, then use ImageIO's bounded thumbnail path. There is no
    /// platform decoder fallback and no SVG, video, animated-image or remote-media request path.
    static func decode(_ data: Data, thumbnailDimension: Int = maximumThumbnailDimension) throws -> CGImage {
        try Task.checkCancellation()
        // Small collection tiles request a small decode; existing callers keep the previous limit.
        // The caller can lower the bound, but can never raise the guarded decoder's maximum.
        let targetDimension = min(maximumThumbnailDimension, max(64, thumbnailDimension))
        guard !data.isEmpty, data.count <= AddonURLGuard.ResponseContext.xperienceArtwork.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              supportedTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0,
                  [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceDimensionsAreAllowed(width: width, height: height) else {
            throw Failure.unsupportedImage
        }
        try Task.checkCancellation()
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetDimension,
        ] as [CFString: Any] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              decodedDimensionsAreAllowed(width: image.width, height: image.height,
                                          bytesPerRow: image.bytesPerRow) else {
            throw Failure.unsupportedImage
        }
        try Task.checkCancellation()
        return image
    }

    static func sourceDimensionsAreAllowed(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumSourceDimension && height <= maximumSourceDimension
            && width <= maximumSourcePixels / height
    }

    static func decodedDimensionsAreAllowed(width: Int, height: Int, bytesPerRow: Int) -> Bool {
        width > 0 && height > 0 && bytesPerRow > 0
            && width <= maximumThumbnailDimension && height <= maximumThumbnailDimension
            && width <= maximumDecodedPixels / height
            && bytesPerRow <= maximumDecodedBytes / height
    }

    private static let supportedTypes: Set<String> = [
        "public.jpeg", "public.png", "org.webmproject.webp", "public.heic", "public.heif",
    ]
}
