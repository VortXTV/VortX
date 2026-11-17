import SwiftUI

/// Keep both poster layers laid out against the card, even when the blurred fill is much taller.
struct LandscapePosterFallback: View {
    let image: Image
    let background: Color
    var blurRadius: CGFloat? = 18
    var posterInset: CGFloat = 0

    var body: some View {
        background
            .overlay {
                if let blurRadius {
                    image.resizable().scaledToFill()
                        .blur(radius: blurRadius).opacity(0.55)
                }
            }
            .overlay(Color.black.opacity(0.35))
            .overlay {
                image.resizable().scaledToFit().padding(posterInset)
            }
            .clipped()
    }
}
