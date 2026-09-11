import SwiftUI

/// Downsampled artwork with a finite metadata fallback chain, not an unbounded image retry loop.
struct FallbackArtwork: View {
    let urls: [String?]
    var maxPixel: CGFloat = 1920
    var contentMode: ContentMode = .fill
    @State private var image: VXPosterImage?

    private struct Request: Hashable {
        let urls: [String]
        let maxPixel: CGFloat
    }

    var body: some View {
        let request = Request(urls: ArtworkFallbackPolicy.candidates(urls), maxPixel: maxPixel)
        Color.clear
            .overlay {
                if let image {
                    #if canImport(UIKit)
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    #else
                    Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                    #endif
                } else {
                    Theme.Palette.surface1
                }
            }
            .clipped()
            .task(id: request) {
                image = nil
                let loaded = await ArtworkFallbackPolicy.firstAvailable(request.urls) {
                    await PosterImageLoader.load($0, maxPixel: request.maxPixel)
                }
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}
