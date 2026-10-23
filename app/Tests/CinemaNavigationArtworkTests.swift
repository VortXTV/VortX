import AppKit
import SwiftUI
import QuartzCore

// Inert palette for the actual source components; no ThemeManager/shared preferences.
enum Theme {
    enum Palette {
        static let canvas = Color.black
        static let accent = Color.orange
    }
}
enum HomeAtmospherePolicy {
    static func alpha(reduceTransparency: Bool, highContrast: Bool) -> Double {
        highContrast ? 0 : (reduceTransparency ? 0.02 : 0.05)
    }
}

@main @MainActor
enum CinemaNavigationArtworkTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8,
                                bytesPerRow: 6400, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1),
                      CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 1000), options: [])
        return context.makeImage()!
    }

    static func renderLayer(_ image: CGImage, width: CGFloat, height: CGFloat, name: String, directory: String,
                            restingPan: Bool = false, acceptedFallback: Bool = false) throws -> NSBitmapImageRep {
        // Actual production hero backing view.
        let view = KenBurnsBackingView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.artLayer.contentsGravity = .resizeAspectFill
        view.artLayer.contents = image
        if acceptedFallback { view.fallbackLayer.contents = image }
        if restingPan { KenBurnsPan.configure(view.artLayer, reduceMotion: true) }
        view.layout()
        let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        view.layer!.render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        return bitmap
    }

    static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    static func main() throws {
        let root = CommandLine.arguments[1], directory = CommandLine.arguments[2]
        let image = fixture()
        expect(EnvironmentValues().cinemaNavigationArtworkInset == 0,
               "standalone/TV consumers do not acquire a navigation reservation")

        for (name, width, height) in [("phone-card", 390.0, 520.0), ("ipad-card", 1024.0, 450.0),
                                      ("mac-card", 1440.0, 620.0), ("short-mac-card", 900.0, 280.0)] {
            let inner = CinemaHeroCardGeometry.innerWidth(viewport: width)
            expect(inner == width - 32, "hero inner width is the viewport minus two fixed gutters")
            let card = VStack(spacing: 0) {
                Color.red
                Button {} label: { Color.green.frame(height: 44) }
                    .buttonStyle(.plain)
            }
            .frame(width: inner, height: height)
            .cinemaHeroCard()
            .padding(.horizontal, CinemaHeroCardGeometry.inset)
            .frame(width: width, height: height)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            expect(bitmap.pixelsWide == Int(width) && bitmap.pixelsHigh == Int(height),
                   "actual rounded card cannot make its parent viewport oversized")
            expect(pixel(bitmap, x: Int(width / 2), y: 50).redComponent > 0.9,
                   "confined artwork keeps its visible center on every device width")
            expect(pixel(bitmap, x: 0, y: 0).redComponent < 0.5,
                   "no sharp artwork corner escapes the outside gutter")
            expect(pixel(bitmap, x: 17, y: 1).redComponent < 0.5,
                   "actual upper media-card corner is rounded")
            expect(pixel(bitmap, x: Int(width / 2), y: Int(height) - 43).greenComponent > 0.7
                && pixel(bitmap, x: Int(width / 2), y: Int(height) - 2).greenComponent > 0.7,
                   "actual center 44-point control stays inside the rounded card")
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        }

        let pan = try renderLayer(image, width: 1024, height: 530, name: "pan-hero", directory: directory,
                                  restingPan: true, acceptedFallback: true)
        for y in [0, 265, 529] {
            let edge = pixel(pan, x: 1023, y: y)
            expect(edge.redComponent + edge.blueComponent > 0.2,
                   "actual accepted-image underlay covers the pan's exposed rightmost edge")
        }

        for navigation in [80, 104] {
            let shell = CinemaNavigationShell {
                Color.red.frame(height: CGFloat(navigation))
            } content: {
                VStack(spacing: 0) {
                    Button {} label: { Color.green.frame(height: 44) }
                        .buttonStyle(.plain)
                    Color.blue
                }
            }
            .frame(width: 390, height: 844)
            let renderer = ImageRenderer(content: shell)
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            expect(pixel(bitmap, x: 195, y: navigation - 1).redComponent > 0.9,
                   "actual production shell keeps the full navigation bar above the first control")
            expect(pixel(bitmap, x: 195, y: navigation).greenComponent > 0.8
                && pixel(bitmap, x: 195, y: navigation + 43).greenComponent > 0.8,
                   "actual 44-point first control begins beneath navigation, without a clipped hit frame")
            expect(pixel(bitmap, x: 195, y: 843).blueComponent > 0.9,
                   "actual content viewport reaches the bottom after the navigation reservation")
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: directory + "/navigation-shell-\(navigation).png"))
        }

        let epoch = CACurrentMediaTime() - 4
        let hero = CALayer()
        KenBurnsPan.configure(hero, reduceMotion: false, epoch: epoch)
        expect(hero.animation(forKey: KenBurnsPan.animationKey)?.beginTime == epoch,
               "the hero pan runs on its view's compositor epoch")
        expect(hero.animation(forKey: KenBurnsPan.animationKey)?.duration == 18,
               "existing compositor motion keeps its original duration")
        KenBurnsPan.reconcile(hero, reduceMotion: true, epoch: epoch)
        expect(hero.animationKeys()?.isEmpty ?? true, "Reduce Motion leaves no hero animation")

        let dissolve = ImageRenderer(content: Color.red.mask(CinemaHeroDissolve()).frame(width: 100, height: 400))
        dissolve.scale = 1
        let mask = NSBitmapImageRep(cgImage: dissolve.cgImage!)
        expect(pixel(mask, x: 50, y: 10).alphaComponent > 0.99, "hero top artwork stays crisp")
        expect(pixel(mask, x: 50, y: 345).alphaComponent > 0.5,
               "actual SwiftUI hero dissolve retains a gradual transition")
        expect(pixel(mask, x: 50, y: 399).alphaComponent < 0.03,
               "actual final hero pixels expose the parent artwork/profile wash")
        try mask.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: directory + "/hero-dissolve.png"))

        let rootSource = try String(contentsOfFile: root + "/app/SourcesiOS/iOSRootView.swift", encoding: .utf8)
        let detail = try String(contentsOfFile: root + "/app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        let featured = try String(contentsOfFile: root + "/app/SourcesiOS/FeaturedHeroView.swift", encoding: .utf8)
        let helper = try String(contentsOfFile: root + "/app/SourcesiOS/CinemaNavigationArtwork.swift", encoding: .utf8)
        expect(rootSource.components(separatedBy: "CinemaNavigationShell {").count == 3,
               "actual Mac and wide-iPad shells both use the rendered floating-navigation layout")
        expect(rootSource.contains("if topNavigation {")
            && rootSource.contains("CinemaCompactNavigationShell {\n                        measuredTabContent\n                    } navigation: {\n                        bottomTabBarRow"),
               "phone/narrow iPad retain their existing bottom-navigation control viewport")
        for source in [rootSource, detail, featured, helper] {
            expect(!source.contains("CinemaNavigationArtworkKey") && !source.contains("cinemaNavigationArtworkOwner")
                && !source.contains("CinemaNavigationArtworkLayerHost") && !source.contains("cinemaHeroScrollOffsetTracking"),
                   "no hero publishes an artwork copy for the floating bar")
        }
        expect(!detail.contains("expandedHeight") && !detail.contains("offset(y: -navigationArtworkInset)"),
               "detail backdrop shows its whole image rather than hiding a bar-height crop")
        expect(featured.contains("usesAcceptedImageFallback: navigationArtworkInset > 0")
            && featured.components(separatedBy: "if usesAcceptedImageFallback { view.fallbackLayer.contents = image }").count == 3,
               "both native wide-hero hosts use the accepted bitmap beneath compositor pan edges")
        expect(featured.contains("onArtwork?(image)")
            && featured.contains("self.requestID == requestID"),
               "the pan-edge fill uses the loader's own accepted paint")
        expect(!helper.contains("PosterImageLoader") && !helper.contains("URLSession")
            && !helper.contains(".task") && !helper.contains("onPreferenceChange"),
               "shell decoration has no image work, timer or scroll observer")
        let macDetail = detail.components(separatedBy: "private func macDetailBody")[1]
            .components(separatedBy: "private func heroBanner")[0]
        expect(!macDetail.contains(".background(Theme.Palette.canvas"),
               "Mac detail ScrollView leaves the parent artwork wash visible")
        expect(detail.contains("tint.opacity(alpha)") && !detail.contains("dominantTint.opacity(0.28)"),
               "detail uses the existing restrained accessibility-aware atmosphere policy")
        expect(featured.contains(".mask(CinemaHeroDissolve())") && detail.contains(".mask(CinemaHeroDissolve())"),
               "both actual hero implementations dissolve their complete image/scrim into the parent canvas")
        expect(featured.contains(".cinemaHeroCard()")
            && featured.contains(".padding(.horizontal, CinemaHeroCardGeometry.inset)")
            && detail.components(separatedBy: ".cinemaHeroCard()").count == 4,
               "shared rounded treatment covers browse, detail and both episode device layouts")
        print("CinemaNavigationArtworkTests: \(checks) checks passed; native crop/timing and actual SwiftUI dissolve; no app/device smoothness claim")
    }
}
