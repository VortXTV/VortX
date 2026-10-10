import AppKit
import SwiftUI

// Inert palette glue for exact production Theme tokens and GlassStyle. Values match the VortX gold
// ThemeManager ladder, but no real preferences, profile store or singleton is constructed by this test.
struct ThemeManager: Sendable {
    static let shared = ThemeManager()
    let textScale = 1.0
    var accent: Color { Color(.sRGB, red: 0.851, green: 0.467, blue: 0.024) }
    var accentBright: Color { Color(.sRGB, red: 0.961, green: 0.620, blue: 0.043) }
    var onAccent: Color { Color(.sRGB, red: 0.059, green: 0.051, blue: 0.039) }
    // VortX gold HSB, saturation halved and capped as in ThemeManager.tintedDark.
    private func warm(_ brightness: Double) -> Color { Color(hue: 0.08927, saturation: 0.34, brightness: brightness) }
    #if WARM_GLASS_FIXTURE
    var canvas: Color { warm(0.085) }
    var surface1: Color { warm(0.130) }
    var surface2: Color { warm(0.175) }
    var surface3: Color { warm(0.225) }
    var hairline: Color { warm(0.260) }
    var glassVeil: Color { warm(0.265) }
    #else
    var canvas: Color { .black }
    var surface1: Color { Color(.sRGB, red: 0.055, green: 0.055, blue: 0.057) }
    var surface2: Color { Color(.sRGB, red: 0.094, green: 0.094, blue: 0.098) }
    var surface3: Color { Color(.sRGB, red: 0.141, green: 0.141, blue: 0.149) }
    var hairline: Color { Color(.sRGB, red: 0.196, green: 0.196, blue: 0.204) }
    var glassVeil: Color { Color(.sRGB, red: 0.188, green: 0.188, blue: 0.196) }
    #endif
}

@main @MainActor
enum PremiumInlineGlassTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }
    static func render<V: View>(_ view: V, name: String, directory: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else { preconditionFailure("actual inline component render unavailable") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("PNG render unavailable") }
        try png.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        return bitmap
    }
    static func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }
    static func row(_ wide: Bool, tint: Color, reduced: Bool = false, contrast: Bool = false) -> some View {
        VortXSettingsRowSurface(wide: wide, tint: tint, reduceTransparency: reduced, highContrast: contrast)
            .frame(width: wide ? 700 : 320, height: 44 + 2 * VortXInlineGlassPolicy.rowInsets(wide: wide).top)
            .background(Theme.Palette.canvas)
    }
    static func main() throws {
        let root = CommandLine.arguments[1], directory = CommandLine.arguments[2], mode = CommandLine.arguments[3]
        for wide in [false, true] {
            let insets = VortXInlineGlassPolicy.rowInsets(wide: wide)
            let gutter = VortXInlineGlassPolicy.rowGutter(wide: wide)
            expect(insets.top - gutter == 14 && insets.bottom - gutter == 14,
                   "row layout reserves its gutter without consuming inner control padding")
            expect(insets.leading == (wide ? 20 : 18) && insets.trailing == insets.leading,
                   "phone and wide layouts retain their readable horizontal insets")
            expect(gutter * 2 == (wide ? 16 : 12), "paired rows own an explicit 12/16pt painted gutter")
            expect(VortXInlineGlassPolicy.rowRadius(wide: wide) == (wide ? 24 : 18),
                   "phone remains compact while iPad/Mac keeps its softer wide radius")
        }
        expect(VortXInlineGlassPolicy.tintAlpha(reduceTransparency: false, highContrast: false) == 0.06,
               "inline surfaces use a six-percent profile wash, not a selected-control plate")
        expect(VortXInlineGlassPolicy.tintAlpha(reduceTransparency: true, highContrast: false) == 0.02,
               "Reduce Transparency uses an opaque base with only two-percent tint")
        expect(VortXInlineGlassPolicy.tintAlpha(reduceTransparency: false, highContrast: true) == 0
            && VortXInlineGlassPolicy.tintAlpha(reduceTransparency: true, highContrast: true) == 0,
               "increased contrast removes decorative surface tint in both modes")
        expect(VortXInlineGlassPolicy.canvasAlpha(reduceTransparency: false, highContrast: false) == 0.04
            && VortXInlineGlassPolicy.canvasAlpha(reduceTransparency: true, highContrast: false) == 0.015
            && VortXInlineGlassPolicy.canvasAlpha(reduceTransparency: true, highContrast: true) == 0,
               "cached-profile atmosphere remains static and accessibility-bounded")

        let red = try render(row(false, tint: .red), name: "\(mode)-settings-row-red", directory: directory)
        let blue = try render(row(false, tint: .blue), name: "\(mode)-settings-row-blue", directory: directory)
        let reduced = try render(row(false, tint: .red, reduced: true), name: "\(mode)-settings-row-reduced", directory: directory)
        let contrastRed = try render(row(false, tint: .red, contrast: true), name: "\(mode)-settings-row-contrast", directory: directory)
        let contrastBlue = try render(row(false, tint: .blue, contrast: true), name: "\(mode)-settings-row-contrast-blue", directory: directory)
        let wide = try render(row(true, tint: .red), name: "\(mode)-settings-row-wide", directory: directory)
        expect(red.pixelsWide == 320 && red.pixelsHigh == 84 && wide.pixelsWide == 700 && wide.pixelsHigh == 88,
               "actual row background sizes follow the production inset policy at compact and wide widths")
        let r = rgb(red, 160, 42), b = rgb(blue, 160, 42), rt = rgb(reduced, 160, 42)
        expect(r.redComponent > b.redComponent && b.blueComponent > r.blueComponent,
               "actual material pixels distinguish red and blue profile hues")
        expect(r.redComponent > rt.redComponent, "actual reduced-transparency pixels keep a quieter profile wash")
        expect(rgb(contrastRed, 160, 42) == rgb(contrastBlue, 160, 42),
               "actual increased-contrast opaque row pixels do not inherit any profile hue")
        expect(rgb(red, 160, 0) == rgb(red, 160, 5) && rgb(red, 160, 5) != rgb(red, 160, 12),
               "actual contained row paint leaves its entire six-point top gutter clear")
        expect(rgb(wide, 350, 0) == rgb(wide, 350, 7) && rgb(wide, 350, 7) != rgb(wide, 350, 16),
               "actual wide row paint leaves its entire eight-point top gutter clear")
        for isWide in [false, true] {
            let rowHeight = 44 + 2 * VortXInlineGlassPolicy.rowInsets(wide: isWide).top
            // Inert content arranged with actual production insets/backgrounds. This is NOT a Form
            // screenshot: it makes the surface gutter and its reserved layout space inspectable.
            let stack = try render(VStack(spacing: 0) {
                ForEach(["Appearance", "Playback", "Languages"], id: \.self) { title in
                    HStack {
                        Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .frame(height: 44)
                    .padding(VortXInlineGlassPolicy.rowInsets(wide: isWide))
                    .background(VortXSettingsRowSurface(wide: isWide, tint: Theme.Palette.accent,
                                                        reduceTransparency: false, highContrast: false))
                }
            }.frame(width: isWide ? 700 : 320).background(Theme.Palette.canvas),
                name: "\(mode)-settings-inert-stack-\(isWide ? "wide" : "compact")", directory: directory)
            expect(stack.pixelsHigh == Int(rowHeight * 3), "actual background/inset component stack preserves reserved layout height")
            let x = stack.pixelsWide / 2, boundary = Int(rowHeight), halfGap = Int(VortXInlineGlassPolicy.rowGutter(wide: isWide))
            expect((boundary - halfGap..<boundary + halfGap).allSatisfy { rgb(stack, x, $0) == rgb(stack, x, 0) },
                   "actual paired background pixels preserve all 12/16 points of clear inter-card gutter")
        }

        let canvas = try render(VortXProfileGlassCanvasSurface(tint: .red, reduceTransparency: false, highContrast: false)
            .frame(width: 390, height: 844),
                                name: "\(mode)-profile-canvas", directory: directory)
        let plainCanvas = try render(VortXProfileGlassCanvasSurface(tint: .red, reduceTransparency: false, highContrast: true)
            .frame(width: 390, height: 844), name: "\(mode)-profile-canvas-contrast", directory: directory)
        expect(rgb(canvas, 10, 10).redComponent > rgb(plainCanvas, 10, 10).redComponent,
               "actual cached-profile canvas adds only a faint upper atmosphere")
        expect(rgb(canvas, 10, 800) == rgb(plainCanvas, 10, 800),
               "actual canvas atmosphere is bounded above lower content")
        #if !WARM_GLASS_FIXTURE
        expect(rgb(plainCanvas, 10, 10).redComponent == 0 && rgb(plainCanvas, 10, 10).blueComponent == 0,
               "increased-contrast OLED canvas stays pure black")
        #endif

        let cards = [("Downloads", "Saved episodes available offline appear here.", "arrow.down.circle.fill"),
                     ("Watchlist", "Titles bookmarked to watch later", "bookmark.fill"),
                     ("Previously Watched", "Titles marked watched in this profile", "checkmark.circle.fill")]
        for width in [320, 390, 700] {
            for (index, item) in cards.enumerated() {
                let bitmap = try render(iOSLibraryHubCard(title: item.0, subtitle: item.1, systemImage: item.2,
                                                         badge: index == 0 ? "12" : nil)
                    .frame(width: CGFloat(width)).background(Theme.Palette.canvas),
                    name: "\(mode)-library-\(index)-\(width)", directory: directory)
                expect(bitmap.pixelsWide == width && bitmap.pixelsHigh >= 92 && bitmap.pixelsHigh <= 160,
                       "actual doorway card stays within narrow-phone/phone/wide bounds without fixed-height clipping")
            }
        }
        let accessible = try render(iOSLibraryHubCardSurface(title: "Previously Watched", subtitle: cards[2].1,
                                                      systemImage: cards[2].2, badge: nil,
                                                      reduceTransparency: true, highContrast: true)
            .frame(width: 320).background(Theme.Palette.canvas),
            name: "\(mode)-library-accessible-320", directory: directory)
        expect(accessible.pixelsWide == 320 && accessible.pixelsHigh <= 160,
               "actual doorway increased-contrast/reduced-transparency fallback remains compact")
        _ = try render(VStack(spacing: Theme.Space.sm) {
            ForEach(0..<cards.count, id: \.self) { index in
                iOSLibraryHubCard(title: cards[index].0, subtitle: cards[index].1, systemImage: cards[index].2,
                                  badge: index == 0 ? "12" : nil)
            }
        }.padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.md)
            .frame(width: 390).background(VortXProfileGlassCanvas(tint: Theme.Palette.accent)),
            name: "\(mode)-library-inert-stack", directory: directory)

        let glass = try String(contentsOfFile: root + "/app/SourcesShared/GlassStyle.swift", encoding: .utf8)
        let settings = try String(contentsOfFile: root + "/app/SourcesiOS/iOSSettingsView.swift", encoding: .utf8)
        let rootSource = try String(contentsOfFile: root + "/app/SourcesiOS/iOSRootView.swift", encoding: .utf8)
        let card = rootSource.components(separatedBy: "private struct iOSLibraryHubCardSurface: View {")[1]
            .components(separatedBy: "\n#endif")[0]
        expect(card.components(separatedBy: ".vortxGlassTintedSurface(").count == 2,
               "Library doorway has one material/lift owner, not a nested icon glass plate")
        expect(card.contains("contained: true") && card.contains("forceOpaque: reduceTransparency || highContrast"),
               "Library explicitly opts into contained material and opaque contrast fallback")
        expect(glass.contains("contained: Bool = false") && glass.contains("forceOpaque: Bool = false"),
               "all other glass consumers retain their original defaults")
        expect(settings.contains(".listRowBackground(VortXSettingsRowBackground(")
            && settings.contains(".listRowInsets(settingsRowInsets)") && settings.contains(".listRowSpacing(0)"),
               "actual Section metadata retains native controls with one gutter owner")
        expect(!settings.contains(".listRowInsets(EdgeInsets(")
            && settings.components(separatedBy: ".listRowInsets(settingsRowInsets)").count == 6,
               "Profiles and source-filter rows no longer override their reserved surface gutters")
        expect(rootSource.contains("NavigationLink(value: LibraryRoute.downloads)")
            && rootSource.contains("NavigationLink(value: LibraryRoute.watchlist)")
            && rootSource.contains("segment = .all\n                        activeFilters = [.watched]"),
               "all three Library doorway actions retain their existing route/filter wiring")
        let atmosphere = glass.components(separatedBy: "struct VortXProfileGlassCanvas: View {")[1]
            .components(separatedBy: "/// Form row background only")[0]
        expect(!atmosphere.contains(".task") && !atmosphere.contains("blur(") && !atmosphere.contains("@ObservedObject")
            && !atmosphere.contains("@State") && !atmosphere.contains("Timer"),
               "the profile atmosphere has no image task, blur, timer or observable pipeline")
        print("PremiumInlineGlassTests: \(checks) checks passed (\(mode)); actual production components/pixels, not a native Form/device interaction receipt")
    }
}
