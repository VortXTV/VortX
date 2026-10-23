#!/usr/bin/env node
'use strict';

// Generate a standalone source-extracted macOS player-glass fixture.
// This reads the current source and ThemeManager accent declarations, but never reads
// UserDefaults, profile files, account state, player state, network state, or devices.

const fs = require('node:fs');
const path = require('node:path');

const repoRoot = process.env.VORTX_ROOT
  ? path.resolve(process.env.VORTX_ROOT)
  : path.resolve(__dirname, '..');
const outputDirectory = process.argv[2];
if (require.main === module && !outputDirectory) {
  throw new Error('usage: node prepare-player-accent-controls.js <generated-output-directory>');
}

const read = relative => fs.readFileSync(path.join(repoRoot, relative), 'utf8');
const production = read('app/Sources/PlayerScreen.swift');
const themeManager = read('app/SourcesShared/ThemeManager.swift');
const theme = read('app/SourcesShared/Theme.swift');
const eligibilityStart = theme.indexOf('@propertyWrapper\nstruct GlassEligibility:');
const eligibilityEnd = theme.indexOf("/// Apple's Liquid Glass belongs", eligibilityStart);
if (eligibilityStart < 0 || eligibilityEnd <= eligibilityStart) throw new Error('Missing source glass eligibility');
const glassEligibility = theme.slice(eligibilityStart, eligibilityEnd);
const glass = read('app/SourcesShared/GlassStyle.swift');
const policyStart = glass.indexOf('enum VortXPlayerChromePolicy {');
const policyEnd = glass.indexOf('/// The actual large video backplate', policyStart);
if (policyStart < 0 || policyEnd <= policyStart) throw new Error('Missing production player chrome policy');
// Compile all shared glass definitions, including the actual bottom backplate and timing protection.
const playerGlass = glass;
const playerThemeStart = themeManager.indexOf('    var playerGlassUsesCrimson:');
const playerThemeEnd = themeManager.indexOf('    /// Ink that sits ON the accent fill', playerThemeStart);
if (playerThemeStart < 0 || playerThemeEnd <= playerThemeStart) throw new Error('Missing player theme projection');
const playerThemeProjection = themeManager.slice(playerThemeStart, playerThemeEnd)
  .replace(/\bvar playerGlass/g, 'static var playerGlass');
const themeRGBStart = themeManager.indexOf('private func themeRGB(');
const themeRGBEnd = themeManager.indexOf('/// A selectable accent.', themeRGBStart);
if (themeRGBStart < 0 || themeRGBEnd <= themeRGBStart) throw new Error('Missing source color helper');
const themeRGBHelper = themeManager.slice(themeRGBStart, themeRGBEnd);
// The player glass reads the shared Effects glass choice; VisualEffects is Foundation-only, so compile it as is.
const visualEffects = read('app/SourcesShared/VisualEffects.swift').replace(/^import Foundation\n/m, '');
const harness = fs.readFileSync(path.join(repoRoot, 'app/Tests/PlayerAccentControlsReduceTransparencyTests.swift'), 'utf8');

const start = production.indexOf('private enum PlayerControlReduceTransparencyOverrideKey');
const end = production.indexOf('private struct PlayerControlButton:', start);
if (start < 0 || end <= start) {
  throw new Error('Missing production player-control presentation slice');
}
const modifier = production.slice(start, end);
if (!modifier.includes('private struct PlayerControlSurfaceModifier')
    || !modifier.includes('playerControlSurface')) {
  throw new Error('Production player-control surface was not extracted');
}

const accentsDeclaration = themeManager.match(
  /static let accents:\s*\[AccentOption\]\s*=\s*\[(.*?)(?:\n\s*)?\]/s,
);
if (!accentsDeclaration) {
  throw new Error('Could not locate ThemeManager.accents');
}

const accents = [];
const accentPattern = /AccentOption\(\s*id:\s*"([^"]+)"\s*,\s*label:\s*"([^"]+)"\s*,\s*base:\s*themeRGB\(([^)]+)\)\s*,\s*bright:\s*themeRGB\(([^)]+)\)\s*\)/g;
let match;
while ((match = accentPattern.exec(accentsDeclaration[1])) !== null) {
  const values = match.slice(3).map(value => value.split(',').map(part => part.trim()));
  if (values.some(parts => parts.length !== 3 || parts.some(part => !/^\d+(?:\.\d+)?$/.test(part)))) {
    throw new Error(`Non-literal accent fixture for ${match[1]}`);
  }
  accents.push({ id: match[1], label: match[2], base: values[0], bright: values[1] });
}

const expectedIDs = ['vortx', 'ember', 'ocean', 'forest', 'royal', 'crimson', 'gold', 'rose', 'mono'];
if (accents.length !== expectedIDs.length || accents.some((accent, index) => accent.id !== expectedIDs[index])) {
  throw new Error(`Expected the current nine-accent ThemeManager order, got: ${accents.map(accent => accent.id).join(', ')}`);
}

const swiftAccentRows = accents.map(accent => `
        AccentSpec(id: "${accent.id}", base: (${accent.base.join(', ')}), bright: (${accent.bright.join(', ')})),`).join('');

// The test harness only needs palette values consumed by the extracted player modifier. The extra
// chrome tokens are dynamic and source-derived so the same fixture remains usable if the player slice
// opts into the shared palette-backed glass helper. OLED values are the exact ThemeManager ladder;
// warm values reproduce ThemeManager.tintedDark(brightness) without constructing the real singleton.
const palette = `
// Only satisfies unrelated shared-glass invalidation; palette values below come from source.
// This RAM-only shell does not construct the persistent application ThemeManager.
@MainActor private final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
}

private struct AccentSpec {
    let id: String
    let base: (Double, Double, Double)
    let bright: (Double, Double, Double)

    var baseColor: Color { Color(.sRGB, red: base.0, green: base.1, blue: base.2, opacity: 1) }
    var brightColor: Color { Color(.sRGB, red: bright.0, green: bright.1, blue: bright.2, opacity: 1) }
}

private enum PlayerThemeFixture {
    static let accents: [AccentSpec] = [${swiftAccentRows}
    ]
    static var accentID = accents[0].id
    static var oled = false

    static var current: AccentSpec {
        accents.first { $0.id == accentID } ?? accents[0]
    }

    static func select(_ id: String) {
        precondition(accents.contains { $0.id == id }, "unknown ThemeManager accent: \\(id)")
        accentID = id
        oled = false
    }

    static var accent: Color { current.baseColor }
    static var accentBright: Color { current.brightColor }

${playerThemeProjection}

    // Matches ThemeManager.onAccent's current source logic (ThemeManager.swift:118-141).
    static var onAccent: Color {
        switch current.id {
        case "vortx": return Color(.sRGB, red: 0.059, green: 0.051, blue: 0.039, opacity: 1)
        case "ember": return Color(.sRGB, red: 0.106, green: 0.067, blue: 0.043, opacity: 1)
        case "crimson": return Color(.sRGB, red: 0.97, green: 0.97, blue: 0.96, opacity: 1)
        default: return Color(.sRGB, red: 0.10, green: 0.10, blue: 0.11, opacity: 1)
        }
    }

    private static func tintedDark(_ brightness: Double) -> Color {
        guard let rgb = NSColor(accent).usingColorSpace(.sRGB) else {
            return Color(.sRGB, red: brightness, green: brightness, blue: brightness, opacity: 1)
        }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var value: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        return Color(hue: Double(hue), saturation: min(Double(saturation) * 0.5, 0.34), brightness: brightness)
    }

    static var canvas: Color {
        oled ? Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1) : tintedDark(0.085)
    }
    static var surface1: Color {
        oled ? Color(.sRGB, red: 0.055, green: 0.055, blue: 0.057, opacity: 1) : tintedDark(0.130)
    }
    static var surface2: Color {
        oled ? Color(.sRGB, red: 0.094, green: 0.094, blue: 0.098, opacity: 1) : tintedDark(0.175)
    }
    static var surface3: Color {
        oled ? Color(.sRGB, red: 0.141, green: 0.141, blue: 0.149, opacity: 1) : tintedDark(0.225)
    }
    static var hairline: Color {
        oled ? Color(.sRGB, red: 0.196, green: 0.196, blue: 0.204, opacity: 1) : tintedDark(0.260)
    }
    static var glassVeil: Color {
        oled ? Color(.sRGB, red: 0.188, green: 0.188, blue: 0.196, opacity: 1) : tintedDark(0.265)
    }
}

enum Theme {
    enum Radius { static let card: CGFloat = 16 }
    enum Space { static let md: CGFloat = 20 }
    enum Palette {
        static var accent: Color { PlayerThemeFixture.accent }
        static var accentBright: Color { PlayerThemeFixture.accentBright }
        static var playerGlassUsesCrimson: Bool { PlayerThemeFixture.playerGlassUsesCrimson }
        static var playerGlassAccent: Color { PlayerThemeFixture.playerGlassAccent }
        static var onAccent: Color { PlayerThemeFixture.onAccent }
        static var canvas: Color { PlayerThemeFixture.canvas }
        static var surface1: Color { PlayerThemeFixture.surface1 }
        static var surface2: Color { PlayerThemeFixture.surface2 }
        static var surface3: Color { PlayerThemeFixture.surface3 }
        static var glassVeil: Color { PlayerThemeFixture.glassVeil }
        static var hairline: Color { PlayerThemeFixture.hairline }
        static let textTertiary = Color(.sRGB, red: 0.620, green: 0.580, blue: 0.520, opacity: 1)
    }
}
`;

const playerGlassFixture = [
  'import SwiftUI',
  'import AppKit',
  themeRGBHelper,
  palette,
  visualEffects,
  glassEligibility,
  playerGlass,
].join('\n');
module.exports = { playerGlassFixture };

if (require.main === module) {
fs.mkdirSync(outputDirectory, { recursive: true });
const generated = [
  playerGlassFixture,
  modifier,
  harness,
].join('\n');
const outputPath = path.join(outputDirectory, 'accent.swift');
fs.writeFileSync(outputPath, generated);
console.log(`prepared source-extracted player accent fixture: ${outputPath}`);
console.log(`palette source: ThemeManager.accents (${accents.length} accents), RAM-only; no preferences or app state`);
}

