// Standalone SwiftUI rendering contract for the player-only control surface.
// The runner extracts PlayerControlSurfaceModifier from PlayerScreen.swift and supplies only
// the palette symbols that modifier needs. This keeps the regression focused on actual SwiftUI
// compositing behavior without launching VortX or touching a media/player session.

import SwiftUI
import AppKit

private struct AccentProbe: View {
    let reduceTransparency: Bool
    let disabled: Bool

    var body: some View {
        Color.clear
            .frame(width: 120, height: 56)
            .playerControlSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(disabled)
            .environment(\.playerControlReduceTransparencyOverride, reduceTransparency)
    }
}

private struct ProbeCanvas: View {
    let reduceTransparency: Bool
    let disabled: Bool

    var body: some View {
        ZStack {
            Color.black
            AccentProbe(reduceTransparency: reduceTransparency, disabled: disabled)
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

@main @MainActor
private enum PlayerAccentControlsReduceTransparencyTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let accent = pixel(render(ProbeCanvas(reduceTransparency: true, disabled: false)))
        let normal = pixel(render(ProbeCanvas(reduceTransparency: false, disabled: false)))
        let disabled = pixel(render(ProbeCanvas(reduceTransparency: true, disabled: true)))

        // These are the exact opaque RGB values in the runner's minimal Theme.Palette stub.
        precondition(near(accent.red, 0.22) && near(accent.green, 0.58) && near(accent.blue, 0.91),
                     "Reduce Transparency secondary fill must be opaque accent")
        precondition(accent.alpha >= 0.98, "Reduce Transparency secondary fill must have full alpha")
        precondition(normal.blue < accent.blue - 0.20,
                     "normal secondary fill should remain translucent over the black canvas")
        precondition(near(disabled.red, 0.07) && near(disabled.green, 0.08) && near(disabled.blue, 0.10),
                     "disabled controls must retain an opaque neutral surface")
        precondition(disabled.blue < accent.blue - 0.50,
                     "disabled surface must remain visually distinct from enabled accent")

        print("PASS compiled PlayerControlSurfaceModifier offscreen Reduce Transparency/disabled render contract")
    }
}
