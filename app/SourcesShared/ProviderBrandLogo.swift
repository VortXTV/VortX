import SwiftUI

#if canImport(UIKit)
import UIKit
/// The decoded platform image the plate compositor operates on (UIImage on iOS / iPadOS / tvOS).
typealias VXImage = UIImage
#elseif canImport(AppKit)
import AppKit
/// The decoded platform image the plate compositor operates on (NSImage on macOS).
typealias VXImage = NSImage
#endif

/// Bundled, first-party brand marks for the "Streaming Services" tiles, shared by every native Apple target
/// (iOS/Mac via SourcesiOS, tvOS via SourcesTV). The owner rejected the TMDB-logo path: for the majors it
/// resolved to a square TMDB icon that fill-cropped badly (or, on a miss, collapsed to a single-letter
/// placeholder: "wtf are these logos"). This file ships REAL transparent-background brand PNGs under
/// `Resources/streaming-logos/` (bundled as a folder reference on all four targets) so a mapped major ALWAYS
/// renders its own logo instantly, with NO network and NO letters.
///
/// Two pieces live here so both UI layers (SourcesiOS `iOSServiceTile`, SourcesTV `TVServiceTile`) share one
/// source of truth:
///   - `bundledLogoName(for:)`: TMDB/JustWatch provider id -> logo slug (the PNG filename without extension),
///     or nil when we don't bundle a mark for that provider (the tile then falls back to the TMDB logoURL,
///     then to the letter placeholder as a last resort).
///   - `BundledLogo.image(named:)`: loads a bundled PNG from the `streaming-logos` subdirectory and returns a
///     SwiftUI `Image?` (NSImage on macOS, UIImage on iOS/tvOS), so the caller can aspect-fit it centered.
enum ProviderBrandLogo {

    /// TMDB/JustWatch provider id -> bundled logo slug. Alias ids (Prime 9/119, Max 1899/384, Apple 2/350,
    /// Discovery+ 520/524, Disney/Hotstar) all resolve to the same mark so a not-yet-deduped list still shows
    /// the right logo. Only the ids we actually ship a PNG for appear here; everything else returns nil.
    private static let idToSlug: [Int: String] = [
        8:    "netflix",        // Netflix
        9:    "primevideo",     // Amazon Prime Video
        119:  "primevideo",     // Amazon Prime Video (alias)
        337:  "disneyplus",     // Disney+
        122:  "hotstar",        // Disney+ Hotstar
        1899: "max",            // Max
        384:  "max",            // HBO Max (alias)
        350:  "appletv",        // Apple TV+
        2:    "appletv",        // Apple TV (store, aliased to +)
        531:  "paramountplus",  // Paramount+
        15:   "hulu",           // Hulu
        386:  "peacock",        // Peacock
        283:  "crunchyroll",    // Crunchyroll
        520:  "discoveryplus",  // Discovery+
        524:  "discoveryplus",  // Discovery+ (alias)
        43:   "starz",          // Starz
        37:   "showtime",       // Showtime
        526:  "amcplus",        // AMC+
        73:   "tubi",           // Tubi
        300:  "plutotv",        // Pluto TV
        38:   "bbciplayer",     // BBC iPlayer
        11:   "mubi",           // MUBI
        344:  "viki",           // Rakuten Viki
    ]

    /// The bundled logo slug for a provider, or nil when we don't ship a mark (fall back to TMDB logoURL).
    static func bundledLogoName(for providerID: Int) -> String? {
        idToSlug[providerID]
    }

    /// Whether we bundle a first-party logo for this provider (drives the "logo-first" branch in the tiles).
    static func hasBundledLogo(for providerID: Int) -> Bool { idToSlug[providerID] != nil }

    /// Per-provider full-bleed brand fill for the "Streaming Services" tiles (the Apple TV look the owner
    /// asked for): the brand's own color fills the WHOLE rounded pill edge to edge, with the bundled logo
    /// centered on top. This replaces the old uniform near-white plate (white for every brand, aspect-fit so
    /// it never filled the pill). `top`/`bottom` describe a top->bottom LinearGradient (set them equal for a
    /// flat solid); `tintWhite` says whether the logo should be re-rendered white (dark or saturated brand
    /// backgrounds) or kept its natural color (light backgrounds like Netflix's white pill, and the few marks
    /// that read on their own on a dark tile). Returns nil for providers with no curated brand style, so the
    /// tiles keep their existing logo/full-name fallback path.
    static func brandStyle(for providerID: Int) -> BrandTileStyle? {
        brandStyles[providerID]
    }

    /// sRGB brand color from 0-255 components.
    private static func srgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
    }

    /// Curated full-bleed brand fills keyed by TMDB/JustWatch provider id. Alias ids (Prime 9/119, Disney
    /// 337/122, Max 1899/384, Apple 350/2, Discovery+ 520/524) share a style so a not-yet-deduped list still
    /// looks uniform. Each brand uses its official primary color; a light second stop deepens toward the base
    /// so the flat tone reads as a real card. `tintWhite` is true for every dark/saturated fill (the logo is
    /// re-rendered white for a clean single-color mark); it is false only where the mark must keep its natural
    /// color: Netflix (red wordmark on its white pill), ESPN/light fills, and Hulu (green mark on black).
    /// Note: a few marks whose art is predominantly BLACK (Peacock, Pluto TV) tint white despite reading as
    /// "multicolor" brands, because a black wordmark would vanish on their dark tile; a visible logo wins.
    private static let brandStyles: [Int: BrandTileStyle] = [
        8:    BrandTileStyle(top: srgb(255, 255, 255), bottom: srgb(255, 255, 255), tintWhite: false), // Netflix
        9:    BrandTileStyle(top: srgb(19, 153, 255),  bottom: srgb(15, 121, 198),  tintWhite: true),  // Prime Video
        119:  BrandTileStyle(top: srgb(19, 153, 255),  bottom: srgb(15, 121, 198),  tintWhite: true),  // Prime Video (alias)
        337:  BrandTileStyle(top: srgb(12, 22, 103),   bottom: srgb(27, 44, 138),   tintWhite: true),  // Disney+
        122:  BrandTileStyle(top: srgb(12, 22, 103),   bottom: srgb(27, 44, 138),   tintWhite: true),  // Disney+ Hotstar
        1899: BrandTileStyle(top: srgb(10, 30, 220),   bottom: srgb(59, 10, 160),   tintWhite: true),  // Max
        384:  BrandTileStyle(top: srgb(10, 30, 220),   bottom: srgb(59, 10, 160),   tintWhite: true),  // HBO Max (alias)
        350:  BrandTileStyle(top: srgb(10, 10, 10),    bottom: srgb(0, 0, 0),       tintWhite: true),  // Apple TV+
        2:    BrandTileStyle(top: srgb(10, 10, 10),    bottom: srgb(0, 0, 0),       tintWhite: true),  // Apple TV (aliased to +)
        531:  BrandTileStyle(top: srgb(0, 100, 255),   bottom: srgb(0, 71, 179),    tintWhite: true),  // Paramount+
        15:   BrandTileStyle(top: srgb(11, 12, 15),    bottom: srgb(11, 12, 15),    tintWhite: false), // Hulu (green mark on black)
        386:  BrandTileStyle(top: srgb(10, 10, 10),    bottom: srgb(0, 0, 0),       tintWhite: true),  // Peacock (black wordmark, tint to show)
        283:  BrandTileStyle(top: srgb(244, 117, 33),  bottom: srgb(224, 100, 15),  tintWhite: true),  // Crunchyroll
        520:  BrandTileStyle(top: srgb(11, 92, 214),   bottom: srgb(10, 70, 168),   tintWhite: true),  // Discovery+
        524:  BrandTileStyle(top: srgb(11, 92, 214),   bottom: srgb(10, 70, 168),   tintWhite: true),  // Discovery+ (alias)
        43:   BrandTileStyle(top: srgb(10, 10, 10),    bottom: srgb(0, 0, 0),       tintWhite: true),  // Starz
        37:   BrandTileStyle(top: srgb(200, 16, 46),   bottom: srgb(142, 11, 32),   tintWhite: true),  // Showtime
        526:  BrandTileStyle(top: srgb(10, 10, 10),    bottom: srgb(0, 0, 0),       tintWhite: true),  // AMC+
        73:   BrandTileStyle(top: srgb(122, 8, 250),   bottom: srgb(90, 6, 189),    tintWhite: true),  // Tubi
        300:  BrandTileStyle(top: srgb(10, 10, 10),    bottom: srgb(0, 0, 0),       tintWhite: true),  // Pluto TV (black wordmark, tint to show)
        38:   BrandTileStyle(top: srgb(255, 78, 152),  bottom: srgb(214, 60, 124),  tintWhite: true),  // BBC iPlayer
        11:   BrandTileStyle(top: srgb(10, 10, 10),    bottom: srgb(0, 0, 0),       tintWhite: true),  // MUBI
        344:  BrandTileStyle(top: srgb(18, 179, 227),  bottom: srgb(14, 144, 182),  tintWhite: true),  // Rakuten Viki
    ]
}

/// The full-bleed brand fill for one streaming-service tile: a top->bottom gradient (top == bottom for a
/// solid) that fills the WHOLE rounded pill, plus whether the bundled logo should be re-rendered white on top
/// of it. Owned by `ProviderBrandLogo.brandStyle(for:)` and consumed by both tile layers (SourcesiOS
/// `iOSServiceTile`, SourcesTV `TVServiceTile`) so iOS/Mac and tvOS render one identical treatment.
struct BrandTileStyle {
    /// Top gradient stop (the brand's primary color).
    let top: Color
    /// Bottom gradient stop (a deeper base; equal to `top` for a flat solid).
    let bottom: Color
    /// Re-render the logo white (dark/saturated fills) vs. keep its natural color (light fills).
    let tintWhite: Bool
}

/// Cross-platform loader for a bundled PNG in the `streaming-logos` subdirectory of the app bundle. Returns a
/// SwiftUI `Image?` so the tiles can aspect-fit it centered. NSImage on macOS, UIImage on iOS/tvOS.
///
/// Legibility (the "logo lost on its own tile" fix): the bundled marks are transparent single-color art, and
/// most of them are DARK or a saturated brand hue (Apple TV+ near-black, Paramount+ / Max blue, Peacock /
/// Starz / Tubi / MUBI black, Disney+ / Prime navy-blue). Painted straight onto their equally dark or equally
/// blue brand tile they had almost no contrast and read as invisible. So every mark is composited onto a
/// consistent soft near-white "brand plate" here, once, in the shared component. Because BOTH tile layers
/// (SourcesiOS `iOSServiceTile`, SourcesTV `TVServiceTile`) call `image(named:)` and then `.resizable()
/// .aspectRatio(.fit)` the returned Image, plating it at the source guarantees identical, legible tiles on
/// iOS / iPad / Mac AND tvOS with no per-surface change. The plate is warm-neutral (not clinical pure white)
/// so it sits with the app's warm chrome, and carries a hairline edge so even the few light marks (Hulu green,
/// AMC+ teal, Crunchyroll orange) keep a visible boundary; the light plate on the dark tile is its own lift.
enum BundledLogo {
    /// Load `streaming-logos/<name>.png`, composite it onto the shared brand plate, and return it as a SwiftUI
    /// Image (or nil if the PNG isn't present). The result is a single opaque, rounded, plated raster; the
    /// caller aspect-fits the whole plate centered on the tile.
    static func image(named name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "streaming-logos")
        else { return nil }
        #if canImport(UIKit)
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return plated(uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return plated(nsImage)
        #else
        return nil
        #endif
    }

    /// Load `streaming-logos/<name>.png` as a RAW, un-plated SwiftUI Image (or nil if absent). This is the
    /// full-bleed twin of `image(named:)`: the bundled marks are transparent single-color art, so a tile can
    /// paint its own brand fill and lay the raw logo centered on top (tinting it white via `.renderingMode`
    /// where the fill is dark), instead of the old warm near-white plate that was white for every brand. The
    /// plated path stays for any caller that still wants the boxed look.
    static func rawImage(named name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "streaming-logos")
        else { return nil }
        #if canImport(UIKit)
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }

    /// Composite an ALREADY-DECODED mark (a downloaded remote logo, e.g. a TMDB/JustWatch provider raster)
    /// onto the SAME warm near-white plate the bundled marks use, and return it as a SwiftUI Image. This is
    /// the runtime twin of `image(named:)`: it lets the long-tail providers we don't bundle share ONE plate
    /// look with the majors, so a dark or brand-hued regional mark is legible on its dark tile instead of
    /// reading as invisible (#95 "icons are very dark"). Pure image compositing, so it is safe to call off
    /// the main thread (e.g. from a background decode) as well as inline. Returns nil only on an unsupported
    /// platform.
    static func plated(_ logo: VXImage) -> Image? {
        #if canImport(UIKit)
        return Image(uiImage: platedLogo(logo))
        #elseif canImport(AppKit)
        return Image(nsImage: platedLogo(logo))
        #else
        return nil
        #endif
    }

    // MARK: Brand plate (shared surface tokens)

    /// The plate's warm off-white fill exposed as a SwiftUI Color, plus its corner radius, so the iOS/Mac
    /// tiles that plate a REMOTE mark with a SwiftUI backing surface (rather than a rasterized composite) can
    /// paint the exact same plate look and stay pixel-consistent with the rasterized bundled/remote marks.
    static var plateFill: Color {
        Color(.sRGB, red: Plate.fillR, green: Plate.fillG, blue: Plate.fillB, opacity: 1)
    }
    /// The plate corner radius as a fraction of the plate WIDTH, so a caller can scale it to any tile size
    /// (the raster plate is 300 wide with a 34pt corner). Keeps the SwiftUI backing plate's rounding in step
    /// with the rasterized plate regardless of the tile's on-screen size.
    static var plateCornerFraction: CGFloat { Plate.corner / Plate.width }
    /// The plate's content inset as a fraction of the plate WIDTH, so a SwiftUI backing plate pads the mark
    /// the same generous amount the raster plate does.
    static var plateInsetFraction: CGFloat { Plate.inset / Plate.width }

    // MARK: Brand plate

    /// The plate is a fixed-aspect rounded rectangle (a touch wider than tall) so a wide wordmark and a
    /// near-square icon both land whole and centered. Sized in points; rendered at 3x for crisp edges. The
    /// logo is inset generously so no mark touches the plate edge, matching the "sane medium mark" treatment.
    private enum Plate {
        static let width: CGFloat = 300
        static let height: CGFloat = 190
        static let corner: CGFloat = 34
        static let inset: CGFloat = 18          // padding between the mark and the plate edge (tight so the mark FILLS the plate)
        static let scale: CGFloat = 3           // supersample for crisp downscale on the tile
        // Warm off-white, not #FFF, so the plate reads as part of the warm-neutral chrome rather than a
        // clinical white sticker. Every dark or brand-hued mark clears a wide luminance gap against it.
        static let fillR: CGFloat = 0.965
        static let fillG: CGFloat = 0.957
        static let fillB: CGFloat = 0.945
        static let edgeAlpha: CGFloat = 0.10    // hairline so a light mark keeps a visible boundary
    }

    /// The mark's target rect inside the plate: the inset content box, so the caller's `.fit` sees a plate
    /// with the logo already correctly padded and centered.
    private static var contentRect: CGRect {
        CGRect(x: Plate.inset, y: Plate.inset,
               width: Plate.width - Plate.inset * 2, height: Plate.height - Plate.inset * 2)
    }

    /// Aspect-fit `size` into `box`, centered (matches SwiftUI `.aspectRatio(.fit)` so the plated mark keeps
    /// the exact proportions of the source art).
    private static func fitted(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    #if canImport(UIKit)
    /// Draw the mark centered on the warm rounded plate (iOS / iPadOS / tvOS).
    private static func platedLogo(_ logo: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = Plate.scale
        format.opaque = false
        let bounds = CGRect(x: 0, y: 0, width: Plate.width, height: Plate.height)
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let plate = UIBezierPath(roundedRect: bounds, cornerRadius: Plate.corner)
            UIColor(red: Plate.fillR, green: Plate.fillG, blue: Plate.fillB, alpha: 1).setFill()
            plate.fill()
            let logoRect = fitted(logo.size, in: contentRect)
            logo.draw(in: logoRect)
            // Hairline edge on top of the mark so even a near-white mark shows the plate boundary.
            cg.saveGState()
            UIColor(white: 0, alpha: Plate.edgeAlpha).setStroke()
            let edge = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: Plate.corner - 0.75)
            edge.lineWidth = 1.5
            edge.stroke()
            cg.restoreGState()
        }
    }
    #elseif canImport(AppKit)
    /// Draw the mark centered on the warm rounded plate (macOS via SourcesiOS reuse).
    private static func platedLogo(_ logo: NSImage) -> NSImage {
        let bounds = CGRect(x: 0, y: 0, width: Plate.width, height: Plate.height)
        let out = NSImage(size: bounds.size)
        out.lockFocus()
        defer { out.unlockFocus() }
        let plate = NSBezierPath(roundedRect: bounds, xRadius: Plate.corner, yRadius: Plate.corner)
        NSColor(srgbRed: Plate.fillR, green: Plate.fillG, blue: Plate.fillB, alpha: 1).setFill()
        plate.fill()
        let logoRect = fitted(logo.size, in: contentRect)
        logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: Plate.edgeAlpha).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: Plate.corner - 0.75, yRadius: Plate.corner - 0.75)
        edge.lineWidth = 1.5
        edge.stroke()
        return out
    }
    #endif
}
