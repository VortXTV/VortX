import AppKit
import CoreFoundation
import SwiftUI

struct CoreVideo {
    var season: Int? = 1
    var episodeNumber = 2
    var episodeTitle = "The Glass Bridge"
    var released: String? = "2026-10-10"
    var overview: String? = "A compact render fixture for the real Cinema episode card."
}

@main @MainActor
enum UIScreenshotSeamsRenderTests {
    static func render<V: View>(_ view: V, directory: String, name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else { preconditionFailure("production SwiftUI render unavailable") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("PNG render unavailable")
        }
        try png.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        return bitmap
    }

    static func materiallyDiffers(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Bool {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return false }
        for y in stride(from: 4, to: lhs.pixelsHigh - 4, by: 4) {
            for x in stride(from: 4, to: lhs.pixelsWide - 4, by: 4) {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(a.redComponent - b.redComponent) > 0.002
                    || abs(a.greenComponent - b.greenComponent) > 0.002
                    || abs(a.blueComponent - b.blueComponent) > 0.002 { return true }
            }
        }
        return false
    }

    static func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    static func close(_ actual: CGFloat, to expected: CGFloat, tolerance: CGFloat = 0.025) -> Bool {
        abs(actual - expected) <= tolerance
    }

    static func neutralEpisodeSurface(width: CGFloat, height: CGFloat) -> some View {
        Color.clear.frame(width: width, height: height)
            .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                        fillAlpha: VortXGlass.cardFillAlpha, shadow: .card)
            .background(Theme.Palette.canvas)
    }

    /// Exercise the real glass modifier with explicit production policy inputs. The fixture does not
    /// override SwiftUI's read-only accessibility environment or claim to render the full card under it.
    static func policyGlassSurface(reduceTransparency: Bool, highContrast: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return Color.clear.frame(width: 180, height: 72)
            .vortxGlassTintedSurface(
                in: shape,
                fillAlpha: VortXGlass.cardFillAlpha,
                tint: Theme.Palette.accent,
                tintAlpha: VortXInlineGlassPolicy.tintAlpha(
                    reduceTransparency: reduceTransparency, highContrast: highContrast),
                shadow: .flat,
                contained: true,
                forceOpaque: reduceTransparency || highContrast)
            .background(Theme.Palette.canvas)
    }

    static func main() throws {
        let directory = CommandLine.arguments[1]
        let card = CinemaEpisodeRailCard(video: CoreVideo(), isWatched: false, progress: 0.2,
                                         cardWidth: 320, artwork: AnyView(Color.clear.frame(height: 160)),
                                         trailingStatus: AnyView(EmptyView()))
            .background(Theme.Palette.canvas)
        let episodeTinted = try render(card, directory: directory, name: "episode-card-profile-tint")
        let episodeNeutral = try render(neutralEpisodeSurface(width: 320, height: CGFloat(episodeTinted.pixelsHigh)),
                                        directory: directory, name: "episode-card-neutral-glass-baseline")
        let artworkSampleYs = [40, episodeTinted.pixelsHigh - 40]
        let hasTintedArtworkPixel = artworkSampleYs.contains { y in
            let tinted = color(episodeTinted, x: episodeTinted.pixelsWide / 2, y: y)
            let neutral = color(episodeNeutral, x: episodeNeutral.pixelsWide / 2, y: y)
            return abs(tinted.redComponent - neutral.redComponent) > 0.002
                || abs(tinted.greenComponent - neutral.greenComponent) > 0.002
                || abs(tinted.blueComponent - neutral.blueComponent) > 0.002
        }
        precondition(hasTintedArtworkPixel,
                     "the real episode card's blank artwork region renders differently from neutral glass")

        let ordinaryTintAlpha = VortXInlineGlassPolicy.tintAlpha(reduceTransparency: false, highContrast: false)
        let reducedTintAlpha = VortXInlineGlassPolicy.tintAlpha(reduceTransparency: true, highContrast: false)
        let contrastTintAlpha = VortXInlineGlassPolicy.tintAlpha(reduceTransparency: false, highContrast: true)
        precondition(ordinaryTintAlpha == 0.06 && reducedTintAlpha == 0.02 && contrastTintAlpha == 0,
                     "the production policy keeps a faint normal tint and reduces or removes decoration for accessibility")
        let ordinaryPolicyGlass = try render(policyGlassSurface(reduceTransparency: false, highContrast: false),
                                             directory: directory, name: "glass-policy-normal")
        let reduceTransparencyGlass = try render(policyGlassSurface(reduceTransparency: true, highContrast: false),
                                                  directory: directory, name: "glass-policy-reduced-transparency")
        let highContrastGlass = try render(policyGlassSurface(reduceTransparency: false, highContrast: true),
                                           directory: directory, name: "glass-policy-high-contrast")
        precondition(materiallyDiffers(ordinaryPolicyGlass, reduceTransparencyGlass)
                     && materiallyDiffers(ordinaryPolicyGlass, highContrastGlass),
                     "the production glass modifier honors explicit opaque/reduced accessibility fallbacks")

        let sourceStyle = iOSSourceRowFocusStyle(reduceTransparency: false, highContrast: false)
        let source = Button {} label: {
            HStack {
                Text("1080P · EXAMPLE SOURCE").font(Theme.Typography.label)
                Spacer()
                Image(systemName: "play.circle.fill")
            }
            .padding(Theme.Space.md)
            .frame(width: 320, height: 76)
        }
        .buttonStyle(sourceStyle)
        .background(Theme.Palette.canvas)
        let sourceTinted = try render(source, directory: directory, name: "source-row-profile-tint")
        let sourceAccessible = try render(Button {} label: {
            HStack {
                Text("1080P · EXAMPLE SOURCE").font(Theme.Typography.label)
                Spacer()
                Image(systemName: "play.circle.fill")
            }
            .padding(Theme.Space.md)
            .frame(width: 320, height: 76)
        }
        .buttonStyle(iOSSourceRowFocusStyle(reduceTransparency: true, highContrast: true))
        .background(Theme.Palette.canvas),
            directory: directory, name: "source-row-accessible")
        precondition(materiallyDiffers(sourceTinted, sourceAccessible),
                     "the real source-row ButtonStyle paints profile tint and honors its opaque accessibility fallback")
        print("UIScreenshotSeamsRenderTests: tinted episode card, glass fallbacks and source-row ButtonStyle rendered")
    }
}
