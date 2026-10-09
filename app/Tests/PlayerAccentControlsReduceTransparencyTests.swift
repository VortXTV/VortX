// Standalone SwiftUI rendering contract for the player-only control surface.
// The runner extracts PlayerControlSurfaceModifier from PlayerScreen.swift and supplies only
// the palette symbols that modifier needs. This keeps the regression focused on actual SwiftUI
// compositing behavior without launching VortX or touching a media/player session.

import SwiftUI
import AppKit

private struct AccentProbe: View {
    let reduceTransparency: Bool
    let disabled: Bool
    var active = false
    var prominent = false
    var contrast: ColorSchemeContrast = .standard
    var glyph = false

    var body: some View {
        ZStack {
            if glyph {
                Image(systemName: "plus").font(.system(size: 24, weight: .bold))
            }
        }
            .frame(width: prominent ? 56 : 120, height: 56)
            .playerControlSurface(in: RoundedRectangle(cornerRadius: prominent ? 28 : 12, style: .continuous),
                                  prominent: prominent, active: active)
            .disabled(disabled)
            .environment(\.playerControlReduceTransparencyOverride, reduceTransparency)
            .environment(\.playerControlContrastOverride, contrast)
    }
}

private struct ProbeCanvas: View {
    var reduceTransparency = false
    var disabled = false
    var active = false
    var prominent = false
    var contrast: ColorSchemeContrast = .standard
    var backdrop = Color.black
    var glyph = false

    var body: some View {
        ZStack {
            backdrop
            AccentProbe(reduceTransparency: reduceTransparency, disabled: disabled,
                        active: active, prominent: prominent, contrast: contrast, glyph: glyph)
        }
        .frame(width: 180, height: 110)
    }
}

@MainActor
private func render<V: View>(_ view: V) -> NSBitmapImageRep {
    let size = NSSize(width: 180, height: 110)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()

    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(size.width),
                                        pixelsHigh: Int(size.height),
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bitmapFormat: [],
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0) else {
        fatalError("failed to allocate offscreen bitmap")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
}

@MainActor
private func pixel(_ bitmap: NSBitmapImageRep, x: Int = 90, y: Int = 55) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
        fatalError("failed to read offscreen pixel")
    }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (red, green, blue, alpha)
}

private func near(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.08) -> Bool {
    abs(actual - expected) <= tolerance
}

private func neutral(_ value: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> Bool {
    abs(value.red - value.green) < 0.025 && abs(value.green - value.blue) < 0.025
}

private func luminance(_ value: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> CGFloat {
    func linear(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
}

@main @MainActor
private enum PlayerAccentControlsReduceTransparencyTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let reducedDark = pixel(render(ProbeCanvas(reduceTransparency: true)))
        let reducedBright = pixel(render(ProbeCanvas(reduceTransparency: true, backdrop: .white)))
        let increased = pixel(render(ProbeCanvas(contrast: .increased, backdrop: .white)))
        let normal = pixel(render(ProbeCanvas()))
        let bright = pixel(render(ProbeCanvas(backdrop: .white)))
        let prominent = pixel(render(ProbeCanvas(prominent: true, backdrop: .white)))
        let selected = pixel(render(ProbeCanvas(reduceTransparency: true, active: true)))
        let disabled = pixel(render(ProbeCanvas(reduceTransparency: true, disabled: true, active: true)))
        let glyph = pixel(render(ProbeCanvas(reduceTransparency: true, glyph: true)))
        let prominentGlyph = pixel(render(ProbeCanvas(reduceTransparency: true, prominent: true, glyph: true)))
        let disabledGlyph = pixel(render(ProbeCanvas(reduceTransparency: true, disabled: true, glyph: true)))

        for value in [reducedDark, reducedBright, increased, normal, bright, prominent, disabled] {
            precondition(neutral(value), "unselected player controls must remain neutral across accessibility modes")
        }
        precondition(near(reducedDark.red, 0.08, tolerance: 0.025), "Reduce Transparency must use the opaque neutral face")
        precondition(near(reducedDark.red, reducedBright.red, tolerance: 0.01),
                     "Reduce Transparency must fully cover both dark and bright video")
        precondition(near(increased.red, reducedDark.red, tolerance: 0.01),
                     "increased contrast must retain the solid high-contrast neutral face")
        precondition(reducedBright.alpha >= 0.98, "Reduce Transparency face must have full alpha")
        for value in [bright, prominent, reducedBright, increased] {
            precondition(1.05 / (luminance(value) + 0.05) >= 4.5,
                         "white controls must keep 4.5:1 contrast over the bright backdrop")
        }
        precondition(selected.blue > selected.red + 0.06, "selected settings must retain an accent cue")
        precondition(glyph.red > 0.90 && glyph.green > 0.90 && glyph.blue > 0.90,
                     "enabled player glyphs must render white")
        precondition(prominentGlyph.red > 0.90 && prominentGlyph.blue > 0.90,
                     "the main play glyph must render white rather than on-accent dark")
        precondition(disabledGlyph.red < glyph.red - 0.20, "disabled controls must dim their white glyph")

        print("PASS compiled player glass: neutral/selected/disabled/prominent surfaces, white glyphs, Reduce Transparency and increased contrast")
    }
}
