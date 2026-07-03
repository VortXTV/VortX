import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
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
        return Image(uiImage: platedLogo(uiImage))
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: platedLogo(nsImage))
        #else
        return nil
        #endif
    }

    // MARK: Brand plate

    /// The plate is a fixed-aspect rounded rectangle (a touch wider than tall) so a wide wordmark and a
    /// near-square icon both land whole and centered. Sized in points; rendered at 3x for crisp edges. The
    /// logo is inset generously so no mark touches the plate edge, matching the "sane medium mark" treatment.
    private enum Plate {
        static let width: CGFloat = 300
        static let height: CGFloat = 190
        static let corner: CGFloat = 34
        static let inset: CGFloat = 34          // padding between the mark and the plate edge
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
