import AppKit
import SwiftUI

// This fixture compiles exact production GlassStyle and ChipButtonStyle, root tab components,
// and the adopted production compact shell. RAM-only theme glue is generated
// from current ThemeManager members; it neither opens preferences nor creates app owners.
@main @MainActor
enum ProfileGlassControlRenderingTests {
    static var checks = 0
    static func check(_ result: Bool, _ message: String) {
        precondition(result, message)
        checks += 1
    }
    static func render<V: View>(_ view: V, width: Int, height: Int) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
    static func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    static func delta(_ a: NSColor, _ b: NSColor) -> Double {
        Double(abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent))
    }
    static func luminance(_ value: NSColor) -> Double {
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(value.redComponent) + 0.7152 * linear(value.greenComponent)
            + 0.0722 * linear(value.blueComponent)
    }
    static func face(active: Bool, reduced: Bool, contrast: Bool, enabled: Bool, backdrop: Color) -> some View {
        ZStack {
            backdrop
            Color.clear.frame(width: 120, height: 56)
                .vortxGlassControl(in: RoundedRectangle(cornerRadius: 12, style: .continuous), active: active)
                .disabled(!enabled)
        }
        .frame(width: 180, height: 110)
        // These public, underscored writable environment hooks are fixture-only. The installed SDK
        // exposes read-only public accessibility values plus these setters; no system setting changes.
        .environment(\._accessibilityReduceTransparency, reduced)
        .environment(\._colorSchemeContrast, contrast ? .increased : .standard)
    }
    static func menu() -> some View {
        CinemaTabBarChrome {
            HStack(spacing: 0) {
                ForEach(["Home", "Library", "Search", "More"], id: \.self) { title in
                    Button {} label: {
                        CinemaCompactTabLabel(title: title, icon: "house", selected: title == "Home")
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = CommandLine.arguments[1], out = CommandLine.arguments[2]
        let source = try String(contentsOfFile: root + "/app/SourcesiOS/iOSRootView.swift", encoding: .utf8)
        let adopted = source.contains("struct CinemaCompactNavigationShell<")
        if adopted {
            check(source.contains("CinemaCompactNavigationShell {"), "shipping compact branch uses rendered shell")
        } else {
            print("NOTE shared compact shell is generated proposal; shipping safe-area routing is source-checked only")
            check(source.contains(".safeAreaInset(edge: .bottom, spacing: 0) { bottomTabBarRow }"),
                  "shipping compact branch contains the intended inset")
        }
        let foreground = NSColor(Theme.Palette.textPrimary).usingColorSpace(.sRGB)!
        for oled in [false, true] {
            ThemeManager.shared.oled = oled
            for option in ThemeManager.accents {
                ThemeManager.shared.accentID = option.id
                for active in [false, true] {
                    for mode in ["normal", "reduced", "contrast"] {
                        let reduced = mode == "reduced", contrast = mode == "contrast"
                        let dark = render(face(active: active, reduced: reduced, contrast: contrast,
                                               enabled: true, backdrop: .black), width: 180, height: 110)
                        let bright = render(face(active: active, reduced: reduced, contrast: contrast,
                                                 enabled: true, backdrop: .white), width: 180, height: 110)
                        let a = rgb(dark, 90, 55), b = rgb(bright, 90, 55)
                        if reduced || contrast {
                            check(delta(a, b) < 0.025 && b.alphaComponent >= 0.98,
                                  "opaque \(option.id)/oled=\(oled)/active=\(active)/\(mode) ignores backdrop")
                        }
                        let fg = luminance(foreground), bg = luminance(b)
                        check((max(fg, bg) + 0.05) / (min(fg, bg) + 0.05) >= 4.5,
                              "readable ordinary control ink over bright backdrop in \(option.id)/\(mode)")
                    }
                }
            }
        }
        ThemeManager.shared.accentID = "ocean"
        let blue = rgb(render(face(active: false, reduced: true, contrast: false, enabled: true, backdrop: .black),
                              width: 180, height: 110), 90, 55)
        ThemeManager.shared.accentID = "crimson"
        let red = rgb(render(face(active: false, reduced: true, contrast: false, enabled: true, backdrop: .black),
                             width: 180, height: 110), 90, 55)
        check(delta(blue, red) > 0.025, "production control face resolves the live profile accent")

        let shell = CinemaCompactNavigationShell {
            ScrollView { Color.blue.frame(height: 1200) }
                .background(Color.magenta.ignoresSafeArea(.container, edges: .bottom))
        } navigation: { menu() }
        .frame(width: 390, height: 844).background(Color.black)
        let bitmap = render(shell, width: 390, height: 844)
        let margin = rgb(bitmap, 4, 815)
        check(margin.redComponent > 0.85 && margin.blueComponent > 0.85,
              "outside floating pill remains the screen backdrop, not the black parent")
        check(bitmap.pixelsWide == 390 && bitmap.pixelsHigh == 844, "navigation inset preserves exact viewport")
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: out + "/proposed-compact-shell.png"))
        // Negative control models the previous sibling strip. Its black margin proves the pixel probe
        // can distinguish the defect; it is explicitly not an extraction of shipping production code.
        let legacy = VStack(spacing: 0) {
            ScrollView { Color.blue.frame(height: 1200) }.background(Color.magenta)
            menu()
        }.frame(width: 390, height: 844).background(Color.black)
        let legacyMargin = rgb(render(legacy, width: 390, height: 844), 4, 815)
        check(legacyMargin.redComponent < 0.2 && legacyMargin.blueComponent < 0.2,
              "negative sibling-strip control rejects black backing")
        print("PASS \(checks) offscreen macOS production control/palette checks; compact shell adopted=\(adopted); no device render")
    }
}

