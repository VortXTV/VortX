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

    static func renderLayer(_ image: CGImage, width: CGFloat, height: CGFloat,
                            artworkHeight: CGFloat, name: String, directory: String,
                            restingPan: Bool = false, acceptedFallback: Bool = false) throws -> NSBitmapImageRep {
        // Actual production backing view used by BOTH header and hero, using its AppKit top crop.
        let view = KenBurnsBackingView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.artworkHeight = artworkHeight
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
        for (name, width, band, navigation) in [("ipad", 1024.0, 450.0, 80.0),
                                               ("mac", 1440.0, 620.0, 80.0),
                                               ("mac-short", 900.0, 280.0, 104.0)] {
            let expanded = CinemaArtworkGeometry.expandedHeight(band: band, navigation: navigation)
            expect(expanded == band + navigation, "only artwork expands; existing hero band is preserved")
            let full = try renderLayer(image, width: width, height: expanded, artworkHeight: expanded,
                                       name: name + "-full", directory: directory)
            let header = try renderLayer(image, width: width, height: navigation, artworkHeight: expanded,
                                         name: name + "-header", directory: directory)
            for y in [0, Int(navigation / 2), Int(navigation) - 1] {
                for x in [0, Int(width / 2), Int(width) - 1] {
                    let a = pixel(full, x: x, y: y), b = pixel(header, x: x, y: y)
                    expect(abs(a.redComponent - b.redComponent) < 0.01
                        && abs(a.blueComponent - b.blueComponent) < 0.01,
                           "actual native header crop matches same expanded hero image coordinates")
                    expect(b.redComponent + b.blueComponent > 0.2,
                           "artwork reaches behind complete navigation width, including both outer edges")
                }
            }
        }
        expect(CinemaArtworkGeometry.expandedHeight(band: 523, navigation: 0) == 523,
               "phone/narrow iPad retain their existing hero height and image crop")
        expect(EnvironmentValues().cinemaNavigationArtworkInset == 0,
               "standalone/TV consumers do not acquire a navigation reservation")

        let panFull = try renderLayer(image, width: 1024, height: 530, artworkHeight: 530,
                                      name: "pan-full", directory: directory,
                                      restingPan: true, acceptedFallback: true)
        let panHeader = try renderLayer(image, width: 1024, height: 80, artworkHeight: 530,
                                        name: "pan-header", directory: directory,
                                        restingPan: true, acceptedFallback: true)
        for y in [0, 40, 79] {
            let a = pixel(panFull, x: 1023, y: y), b = pixel(panHeader, x: 1023, y: y)
            expect(b.redComponent + b.blueComponent > 0.2,
                   "actual accepted-image underlay covers the pan's exposed rightmost edge")
            expect(abs(a.redComponent - b.redComponent) < 0.01
                && abs(a.blueComponent - b.blueComponent) < 0.01,
                   "actual resting/reduced-motion edge joins the same hero underlay")
        }

        for navigation in [80, 104] {
            let shell = CinemaNavigationReservedShell {
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
                   "actual production shell retains the full reserved navigation row")
            expect(pixel(bitmap, x: 195, y: navigation).greenComponent > 0.8
                && pixel(bitmap, x: 195, y: navigation + 43).greenComponent > 0.8,
                   "actual 44-point first control begins beneath navigation, without a clipped hit frame")
            expect(pixel(bitmap, x: 195, y: 843).blueComponent > 0.9,
                   "actual content viewport reaches the bottom after the navigation reservation")
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: directory + "/reserved-shell-\(navigation).png"))
        }

        let epoch = CACurrentMediaTime() - 4
        let hero = CALayer(), header = CALayer()
        KenBurnsPan.configure(hero, reduceMotion: false, epoch: epoch)
        KenBurnsPan.configure(header, reduceMotion: false, epoch: epoch)
        expect(hero.animation(forKey: KenBurnsPan.animationKey)?.beginTime == epoch
            && header.animation(forKey: KenBurnsPan.animationKey)?.beginTime == epoch,
               "both art slices use one compositor epoch rather than restarting at the menu")
        expect(hero.animation(forKey: KenBurnsPan.animationKey)?.duration == 18,
               "existing compositor motion keeps its original duration")
        KenBurnsPan.reconcile(header, reduceMotion: true, epoch: epoch)
        expect(header.animationKeys()?.isEmpty ?? true, "Reduce Motion leaves no navigation animation")

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
        expect(rootSource.components(separatedBy: "CinemaNavigationReservedShell {").count == 3,
               "actual Mac and wide-iPad shells both use the rendered reserved-control layout")
        expect(rootSource.contains("if topNavigation {")
            && rootSource.contains("measuredTabContent.frame(maxWidth: .infinity, maxHeight: .infinity)\n                        bottomTabBarRow"),
               "phone/narrow iPad retain their existing bottom-navigation control viewport")
        expect(rootSource.contains("artwork?.owner == navigationArtworkOwner ? artwork : nil")
            && rootSource.components(separatedBy: "navigationArtwork = nil").count == 3,
               "shell independently rejects old route/owner artwork and clears tab/profile transitions")
        expect(featured.contains("navigationImage.key == heroTintKey")
            && featured.contains("requested == heroTintKey,")
            && featured.contains("requestedOwner == navigationArtworkOwner else { return }"),
               "hero rejects a late obsolete image before publishing either crop")
        expect(featured.contains(".onChange(of: heroTintKey) { _ in navigationImage = nil }")
            && featured.contains(".onChange(of: navigationArtworkOwner) { _ in navigationImage = nil }"),
               "retired title/owner bitmap storage is released as well as hidden immediately")
        expect(featured.contains("usesAcceptedImageFallback: navigationArtworkInset > 0")
            && featured.components(separatedBy: "if usesAcceptedImageFallback { view.fallbackLayer.contents = image }").count == 3,
               "both native wide-hero hosts use the accepted bitmap beneath compositor pan edges")
        expect(featured.contains("onArtwork?(image)")
            && featured.contains("self.requestID == requestID"),
               "navigation image comes from the actual accepted loader paint")
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
        expect(rootSource.contains(".clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))")
            && rootSource.contains(".padding(.horizontal, 16)"),
               "approved phone inset rounded hero remains in the real Home composition")
        print("CinemaNavigationArtworkTests: \(checks) checks passed; native crop/timing and actual SwiftUI dissolve; no app/device smoothness claim")
    }
}
