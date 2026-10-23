"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const root = path.resolve(__dirname, "..");
const read = file => fs.readFileSync(path.join(root, file), "utf8");
const glass = read("app/SourcesShared/GlassStyle.swift");
const manager = read("app/SourcesShared/ThemeManager.swift");
const player = read("app/Sources/PlayerScreen.swift");
const tv = read("app/SourcesTV/TVPlayerView.swift");
function section(source, from, to) {
    const start = source.indexOf(from);
    const end = source.indexOf(to, start + from.length);
    assert(start >= 0 && end > start, `missing source section: ${from}`);
    return source.slice(start, end);
}

test("large bottom scrims are one policy with existing accessibility and reduced-effects fallbacks", () => {
    const policy = section(glass, "enum VortXPlayerChromePolicy", "/// The actual large video backplate");
    for (const value of [
        "case .touch: return requiresContrast ? 0.75 : 0.38",
        "case .desktop: return requiresContrast ? 0.38 : 0.24",
        "case .television: return requiresContrast ? 0.90 : 0.58",
        "reduceTransparency || highContrast || !glassEnabled"
    ]) assert(policy.includes(value), `central scrim contract: ${value}`);
    assert(player.includes("VortXPlayerBackdrop(platform: .touch)"));
    assert(player.includes("VortXPlayerBackdrop(platform: .desktop)"));
    assert(tv.includes(".background(VortXPlayerBackdrop(platform: .television))"));
    const backdrop = section(glass, "struct VortXPlayerBackdrop:", "/// Desktop's additional rounded bottom container");
    for (const value of ["@Environment(\\.accessibilityReduceTransparency)",
        "@Environment(\\.colorSchemeContrast)", "VisualEffects.reducedForAuto",
        ".allowsHitTesting(false)", ".accessibilityHidden(true)"])
        assert(backdrop.includes(value), `backdrop contract: ${value}`);
    assert(!backdrop.includes("glassEffect") && !backdrop.includes("Material"),
        "thinner TV gradient must not add backdrop material work");
});

test("time-label protection hugs actual text before fixed widths, leaving the timeline uncovered", () => {
    const timeline = section(player, "private struct PlayerBottomTimeline:", "/// Delayed, local erasure");
    assert.equal((timeline.match(/vortxPlayerTimeLabelProtection/g) || []).length, 4,
        "touch and desktop branches protect duration and Ends-at labels");
    const clockLabel = section(player, "private struct PlayerTimeLabel:", "private struct PlayerClockSlider:");
    assert(clockLabel.includes('.vortxPlayerTimeLabelProtection()\n            .opacity(!showWhenPositive'),
        "LIVE zero-time opacity must hide the text and its protection together");
    const tvTimeline = section(tv, "private var trickplayControls:", "private func trickplayStatusBubble(");
    assert.equal((tvTimeline.match(/vortxPlayerTimeLabelProtection/g) || []).length, 3);
    assert(tvTimeline.includes('.vortxPlayerTimeLabelProtection()\n                        .frame(width: sideWidth, alignment: .leading)'),
        "TV elapsed-time capsule must hug text before its fixed layout width");
    assert(!tvTimeline.includes('.vortxPlayerTimeLabelProtection()\n                .frame(maxHeight: .infinity'),
        "do not paint the entire timeline or expanding preview row");
    const protection = section(glass, "private struct VortXPlayerTimeLabelProtectionModifier:", '/// VortX "liquid glass"');
    assert(protection.includes("content.background {"));
    assert(protection.includes(".padding(.horizontal, -6).padding(.vertical, -2)"));
    assert(protection.includes(".allowsHitTesting(false)"));
    assert(glass.includes("requiresContrast ? 1 : 0.62"));
    // Full-white labels on the local capsule: source-token SDR-white bound only, no render claim.
    const linear = c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    assert(1.05 / (linear(1 - 0.62) + 0.05) >= 4.5);
});

test("desktop changes the actual rounded bottom backplate without moving its content", () => {
    const layout = section(player, "private struct PlayerBottomBarLayout:", "/// Pinch is a mode change");
    assert(layout.includes(".vortxPlayerBottomBackplate()"));
    for (const geometry of ["VStack(spacing: 10)", "VStack(spacing: 14)",
        ".padding(.horizontal, 16).padding(.bottom, 12)",
        ".padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)",
        ".padding(.horizontal, 16).padding(.bottom, 16)"])
        assert(layout.includes(geometry), `retained bottom geometry: ${geometry}`);
    const plate = section(glass, "private struct VortXPlayerBottomBackplateModifier:", "extension View {");
    for (const value of ["RoundedRectangle(cornerRadius: 22, style: .continuous)",
        "highlightTop: 0.14, shadow: .bar", "forceOpaque: requiresContrast", "tone: .scrim"])
        assert(plate.includes(value), `backplate contract: ${value}`);
});

test("Crimson gets a player-only tint and non-Crimson profile selections pass through", () => {
    assert(manager.includes('accentID = UserDefaults.standard.string(forKey: Self.accentKey) ?? "vortx"'));
    assert(manager.includes('var playerGlassUsesCrimson: Bool { accentID == "crimson" }'));
    assert(manager.includes("playerGlassUsesCrimson ? themeRGB(0.706, 0.075, 0.208) : accent"));
    assert(manager.includes('AccentOption(id: "vortx",   label: "VortX",   base: themeRGB(0.851, 0.467, 0.024)'));
    assert(manager.includes('AccentOption(id: "crimson", label: "Crimson", base: themeRGB(0.886, 0.310, 0.357)'));
    assert(read("app/SourcesShared/Theme.swift").includes("static let danger = rgb(0.871, 0.282, 0.337)"));
    const surface = section(player, "private struct PlayerControlSurfaceModifier", "private struct PlayerControlButton:");
    // Keep the opaque fallback's existing profile tint and white enabled glyph; only normal glass changes.
    assert(surface.includes("if isEnabled { shape.fill(Theme.Palette.accent.opacity(active ? 0.22 : 0.12)) }"));
    assert(surface.includes("isEnabled ? .white : .white.opacity"));
    assert(surface.includes("|| contrast == .increased || !isEnabled"));
    assert(surface.includes("VortXPlayerChromePolicy.controlTintAlpha("));
    assert(surface.includes("VortXPlayerChromePolicy.controlVeilAlpha("));
    assert(tv.includes("Theme.Palette.playerGlassUsesCrimson ? Color.white : Theme.Palette.canvas"));
});

test("normal Crimson face has less total paint and retains a conservative white-face contrast bound", () => {
    // Analytic source-token contract only: the actual material, refraction, font and device still need renders.
    const policy = section(glass, "enum VortXPlayerChromePolicy", "/// The actual large video backplate");
    assert(policy.includes("crimson ? (active ? 0.68 : 0.52) : (active ? 0.62 : 0.46)"));
    assert(policy.includes("crimson ? 0.48 : 0.58"));
    const linear = c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    for (const [oldTint, newTint] of [[0.46, 0.52], [0.62, 0.68]]) {
        const oldPaint = 1 - (1 - oldTint) * (1 - 0.58);
        const newPaint = 1 - (1 - newTint) * (1 - 0.48);
        assert(newPaint < oldPaint, "richer Crimson must not be obtained with a more opaque face");
        const face = [0.706, 0.075, 0.208].map(c =>
            (c * newTint + (1 - newTint)) * (1 - 0.48) + 0.08 * 0.48);
        const luminance = face.map(linear).reduce((sum, c, i) => sum + c * [0.2126, 0.7152, 0.0722][i], 0);
        assert(1.05 / (luminance + 0.05) >= 4.5, "white control faces retain 4.5:1 over an SDR-white material bound");
    }
});
