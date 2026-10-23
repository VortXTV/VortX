// Source-extracted offscreen harness for the exact production player surface.
// The companion Node preparation script extracts PlayerControlSurfaceModifier from
// PlayerScreen.swift and injects this test with a RAM-only palette fixture. It is an
// offscreen macOS SwiftUI render contract, not an iPhone/tvOS/device or OS-26 hardware receipt.

import SwiftUI
import AppKit

private struct AccentProbe: View {
    let reduceTransparency: Bool
    let disabled: Bool
    var active = false
    var prominent = false
    var contrast: ColorSchemeContrast = .standard
    var glyph = false
    var backdrop: Color = .black

    var body: some View {
        ZStack {
            backdrop
            ZStack {
                if glyph {
                    Image(systemName: "plus").font(.system(size: 24, weight: .bold))
                }
            }
            .frame(width: prominent ? 56 : 120, height: 56)
            .playerControlSurface(in: RoundedRectangle(cornerRadius: prominent ? 28 : 12,
                                                        style: .continuous),
                                  prominent: prominent, active: active)
            .disabled(disabled)
            .environment(\.playerControlReduceTransparencyOverride, reduceTransparency)
            .environment(\.playerControlContrastOverride, contrast)
        }
        .frame(width: 180, height: 110)
    }
}

private struct RGBA: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
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
private func pixel(_ bitmap: NSBitmapImageRep, x: Int = 90, y: Int = 55) -> RGBA {
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
        fatalError("failed to read offscreen pixel")
    }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return RGBA(red: red, green: green, blue: blue, alpha: alpha)
}

private func distance(_ lhs: RGBA, _ rhs: RGBA) -> CGFloat {
    abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) + abs(lhs.blue - rhs.blue)
}

private func near(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.08) -> Bool {
    abs(actual - expected) <= tolerance
}

private func luminance(_ value: RGBA) -> CGFloat {
    func linear(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
}

private func whiteContrast(_ value: RGBA) -> CGFloat {
    1.05 / (luminance(value) + 0.05)
}

private func assertOpaqueInvariant(_ dark: RGBA, _ bright: RGBA, label: String) {
    precondition(distance(dark, bright) <= 0.03, "\(label) must cover dark and white backdrops")
    precondition(dark.alpha >= 0.98 && bright.alpha >= 0.98,
                 "\(label) must remain fully opaque")
}

private func assertWhiteGlyph(_ value: RGBA, label: String) {
    precondition(value.red > 0.90 && value.green > 0.90 && value.blue > 0.90,
                 "\(label) must retain a readable white glyph")
}

@main @MainActor
private enum PlayerAccentControlsReduceTransparencyTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var accentChecks = 0
        for accent in PlayerThemeFixture.accents {
            PlayerThemeFixture.select(accent.id)
            // Warm uses the exact ThemeManager tintedDark canvas recipe; OLED uses its true-black canvas.
            // Player controls still render over arbitrary video, so the white backdrop remains explicit.
            let darkBackdrop = PlayerThemeFixture.canvas

            let normalOffDark = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                         backdrop: darkBackdrop)))
            let normalOffBright = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                           backdrop: .white)))
            let normalActiveDark = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                            active: true, backdrop: darkBackdrop)))
            let normalActiveBright = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                              active: true, backdrop: .white)))
            let normalProminentBright = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                                 prominent: true, backdrop: .white)))
            let normalActiveProminentBright = pixel(render(AccentProbe(reduceTransparency: false,
                                                                       disabled: false, active: true,
                                                                       prominent: true, backdrop: .white)))

            // The normal path must preserve white-glyph readability over a bright video frame in all
            // off/selected/prominent combinations. This intentionally remains a 4.5:1 assertion.
            for value in [normalOffBright, normalActiveBright,
                          normalProminentBright, normalActiveProminentBright] {
                if whiteContrast(value) < 4.5 {
                    print("DIAG bright face \(accent.id): \(value) contrast=\(whiteContrast(value))")
                    fflush(stdout)
                }
                precondition(whiteContrast(value) >= 4.5,
                             "white player controls must keep 4.5:1 contrast over bright video (\(accent.id))")
            }

            // Selection is profile-tinted in both normal and accessibility fallbacks. Compare the same
            // accent/state/backdrop rather than relying on a blue-channel predicate that only works for Ocean.
            precondition(distance(normalOffDark, normalActiveDark) > 0.008,
                         "normal off/selected controls must retain an accent cue (\(accent.id))")

            let reducedOffDark = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                          backdrop: darkBackdrop)))
            let reducedOffBright = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                            backdrop: .white)))
            let reducedActiveDark = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                              active: true, backdrop: darkBackdrop)))
            let reducedActiveBright = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                               active: true, backdrop: .white)))
            let increasedOffDark = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                            contrast: .increased, backdrop: darkBackdrop)))
            let increasedOffBright = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                              contrast: .increased, backdrop: .white)))
            let increasedActiveDark = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                               active: true, contrast: .increased,
                                                               backdrop: darkBackdrop)))
            let increasedActiveBright = pixel(render(AccentProbe(reduceTransparency: false, disabled: false,
                                                                 active: true, contrast: .increased,
                                                                 backdrop: .white)))

            assertOpaqueInvariant(reducedOffDark, reducedOffBright,
                                  label: "Reduce Transparency off face (\(accent.id))")
            assertOpaqueInvariant(reducedActiveDark, reducedActiveBright,
                                  label: "Reduce Transparency selected face (\(accent.id))")
            assertOpaqueInvariant(increasedOffDark, increasedOffBright,
                                  label: "increased-contrast off face (\(accent.id))")
            assertOpaqueInvariant(increasedActiveDark, increasedActiveBright,
                                  label: "increased-contrast selected face (\(accent.id))")
            precondition(distance(reducedOffDark, reducedActiveDark) > 0.008,
                         "Reduce Transparency must preserve the selected accent cue (\(accent.id))")
            precondition(distance(increasedOffDark, increasedActiveDark) > 0.008,
                         "increased contrast must preserve the selected accent cue (\(accent.id))")

            // Disabled controls intentionally drop the active tint and keep their readable white glyph dimming.
            let disabledOff = pixel(render(AccentProbe(reduceTransparency: true, disabled: true,
                                                        backdrop: darkBackdrop)))
            let disabledActive = pixel(render(AccentProbe(reduceTransparency: true, disabled: true,
                                                          active: true, backdrop: darkBackdrop)))
            precondition(distance(disabledOff, disabledActive) <= 0.03,
                         "disabled controls must not paint the selected accent (\(accent.id))")

            let glyph = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                 glyph: true, backdrop: darkBackdrop)))
            let prominentGlyph = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                          prominent: true, glyph: true,
                                                          backdrop: darkBackdrop)))
            let disabledGlyph = pixel(render(AccentProbe(reduceTransparency: true, disabled: true,
                                                        active: true, glyph: true,
                                                        backdrop: darkBackdrop)))
            assertWhiteGlyph(glyph, label: "enabled player glyph (\(accent.id))")
            assertWhiteGlyph(prominentGlyph, label: "enabled prominent player glyph (\(accent.id))")
            precondition(disabledGlyph.red < glyph.red - 0.20,
                         "disabled controls must dim their white glyph (\(accent.id))")

            // The source-derived fixture must exercise both warm and OLED canvas modes for every accent.
            // No device claim is made: this only proves the opaque fallback is stable against either fixture.
            for oled in [false, true] {
                PlayerThemeFixture.oled = oled
                let fixtureDark = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                           backdrop: PlayerThemeFixture.canvas)))
                let fixtureBright = pixel(render(AccentProbe(reduceTransparency: true, disabled: false,
                                                             backdrop: .white)))
                assertOpaqueInvariant(fixtureDark, fixtureBright,
                                      label: "accessibility fallback in \(oled ? "OLED" : "warm") mode (\(accent.id))")
            }
            PlayerThemeFixture.oled = false
            accentChecks += 1
        }

        precondition(PlayerThemeFixture.accents.count == 9,
                     "the player audit must cover exactly the nine current ThemeManager accents")
        print("PASS offscreen macOS player glass audit: \(accentChecks) accents × warm/OLED fixture × off/selected/disabled/accessibility states; no device-render claim")
    }
}
