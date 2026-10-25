"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { test } = require("node:test");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "../app/Sources/PlayerScreen.swift"), "utf8");

const glassSource = fs.readFileSync(path.join(__dirname, "../app/SourcesShared/GlassStyle.swift"), "utf8");

function section(from, to, input = source) {
    const start = input.indexOf(from);
    const end = input.indexOf(to, start);
    assert(start >= 0 && end > start, `missing source section: ${from}`);
    return input.slice(start, end);
}

function assertCurrentPlayerGlass(player, glass) {
    const surface = section("private struct PlayerControlSurfaceModifier", "private struct PlayerControlButton:", player);
    for (const contract of [
        "@Environment(\\.accessibilityReduceTransparency)", "@Environment(\\.colorSchemeContrast)",
        "@Environment(\\.isEnabled)", "reduceTransparencyOverride ?? systemReduceTransparency",
        "contrastOverride ?? systemContrast", ".background { surface }",
        ".overlay { shape.strokeBorder(border, lineWidth: 1) }", ".clipShape(shape)",
        ".contentShape(shape)", ".shadow(color: .black.opacity(shadowOpacity)",
        "if reduceTransparency", "|| !VisualEffects.glass(stored: glassChoice, reduced: VisualEffects.reducedForAuto)",
        "|| contrast == .increased || !isEnabled", "shape.fill(neutral)",
        "if isEnabled { shape.fill(Theme.Palette.accent.opacity(active ? 0.22 : 0.12)) }",
        "Color(.sRGB, white: 0.08, opacity: 1)", "isEnabled ? .white : .white.opacity",
        ".glassEffect(.clear.tint(Theme.Palette.playerGlassAccent.opacity(active ? 0.45 : 0.30)).interactive(), in: shape)",
        "shape.fill(.ultraThinMaterial)", "VortXPlayerChromePolicy.controlTintAlpha(",
        "active: active, crimson: Theme.Palette.playerGlassUsesCrimson",
        "VortXPlayerChromePolicy.controlVeilAlpha(", "crimson: Theme.Palette.playerGlassUsesCrimson",
        "contrast == .increased ? .white : Theme.Palette.playerGlassAccent"
    ]) assert(surface.includes(contract), "current player surface contract: " + contract);
    assert(!surface.includes("Theme.Palette.onAccent"), "playback glyphs remain white");
    assert(!surface.includes("return Theme.Palette.accent"), "transport cannot become a solid accent disc");
    assert(!surface.includes("shadow(color: Theme.Palette.accent"), "no accent-colored outer shadow");
    assert(surface.indexOf("VortXPlayerChromePolicy.controlTintAlpha(") <
        surface.indexOf("VortXPlayerChromePolicy.controlVeilAlpha("), "dark veil remains above profile tint");

    const policy = section("enum VortXPlayerChromePolicy", "/// The actual large video backplate", glass);
    assert(policy.includes("reduceTransparency || highContrast || !glassEnabled"));
    const plate = section("private struct VortXPlayerBottomBackplateModifier:", "extension View {", glass);
    for (const contract of [
        "reduceTransparency: reduceTransparency, highContrast: contrast == .increased",
        "glassEnabled: VisualEffects.glass(stored: glassChoice, reduced: VisualEffects.reducedForAuto)",
        "shape: RoundedRectangle(cornerRadius: 22, style: .continuous)",
        "highlightTop: 0.14, shadow: .bar", "forceOpaque: requiresContrast",
        "VortXPlayerChromePolicy.backplateFillAlpha(requiresContrast: requiresContrast)",
        "VortXPlayerChromePolicy.backplateMaterialOpacity(requiresContrast: requiresContrast)", "tone: .scrim"
    ]) assert(plate.includes(contract), "shared backplate contract: " + contract);
    const shared = section("private struct VortXGlassModifier", "// MARK: - The prominent", glass);
    assert(shared.includes("reduceTransparency: reduceTransparency || forceOpaque"));
    assert(shared.includes(".opacity(reduceTransparency || forceOpaque ? 1 : materialOpacity)"));
    assert(shared.includes("if !reduceTransparency && !forceOpaque"));

    const layout = section("private struct PlayerBottomBarLayout:", "/// Pinch is a mode change", player);
    for (const contract of ["VStack(spacing: 10)", "VStack(spacing: 14)",
        ".padding(.horizontal, 16).padding(.bottom, 12)",
        ".padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)",
        ".vortxPlayerBottomBackplate()", ".padding(.horizontal, 16).padding(.bottom, 16)"])
        assert(layout.includes(contract), "retained bottom geometry: " + contract);
    assert(player.includes("VortXPlayerBackdrop(platform: .touch)"));
    assert(player.includes("VortXPlayerBackdrop(platform: .desktop)"));
    assert(player.includes(".onPreferenceChange(PlayerBottomBarHeightKey.self) { bottomChromeHeight = $0 }"));
    assert(player.includes("chromeHeight: Double(bottomChromeHeight)"));
}

test("the entire bottom bar terminates metadata at concrete rendering boundaries", () => {
    const bottom = source.slice(source.indexOf("private var bottomBar: PlayerBottomBarLayout"),
        source.indexOf("private var bottomTimeline:"));
    assert(bottom.includes("PlayerBottomBarLayout("));
    assert(!bottom.includes("VStack("));
    const layout = source.slice(source.indexOf("private struct PlayerBottomBarLayout:"),
        source.indexOf("/// One provider refresh"));
    for (const leaf of ["PlayerLiveIndicator", "PlayerBottomTimeline", "PlayerSkipEditorLayout?", "PlayerTransportToolbar"]) {
        assert(layout.includes(leaf), `outer boundary: ${leaf}`);
    }
    assert(!layout.includes("-> some View"));
    const timeline = source.slice(source.indexOf("private struct PlayerBottomTimeline:"),
        source.indexOf("private struct PlayerSkipEditorSection:"));
    assert(timeline.includes("let track: (CGSize) -> PlayerSeekTimelineTrack"));
    assert(timeline.includes("GeometryReader { geo in track(geo.size) }"));
    const factory = source.slice(source.indexOf("private var bottomTimeline:"),
        source.indexOf("private var bottomSkipEditor:"));
    assert(factory.includes("PlayerSeekTimelineTrack("));
    assert(!factory.includes("PlayerClockSlider("));
    assert(!factory.includes(".overlay"));
    for (const binding of ["clock: timePosClock", "scrubbing: $scrubbing", "scrubTarget: $scrubTarget",
        "chapterFractions: chapterFractions", "skipSegments: skipSegments", "hoverPreviewTime: hoverPreviewTime"]) {
        assert(factory.includes(binding), `retained timeline input: ${binding}`);
    }
    for (const operation of ["issueSeek(to: target, reason: \"scrub\")", "reportSeek(target)",
        "scrubThumbnails.clear()", "scheduleHide()", "trickplayBubbleOffset(sliderWidth: width)"]) {
        assert(factory.includes(operation), `retained transport/preview operation: ${operation}`);
    }
});

test("toolbar and editor do not expose repeated opaque button or editor-section types", () => {
    assert(source.includes("action: @escaping () -> Void) -> PlayerControlButton"));
    const toolbar = source.slice(source.indexOf("private struct PlayerTransportToolbar:"),
        source.indexOf("private struct PlayerLiveIndicator:"));
    assert.equal((toolbar.match(/: PlayerControlButton/g) || []).length, 10);
    const editor = source.slice(source.indexOf("private struct PlayerSkipEditorLayout:"),
        source.indexOf("private struct PlayerBottomBarLayout:"));
    assert.equal((editor.match(/let \w+: \(\) -> AnyView/g) || []).length, 3);
    assert.equal((editor.match(/PlayerSkipEditorSection\(content:/g) || []).length, 6,
        "both iOS scrolling and desktop editor rows retain three nominal sections");
    for (const name of ["skipDBEditTypeControls", "skipDBEditTimeControls", "skipDBEditActions", "skipDBTimeControl"]) {
        assert(new RegExp(`private func ${name}\\([^\\n]*\\) -> AnyView`).test(source), `${name} must bound its own subtree`);
    }
    assert(source.includes("guard showSkipDBEdit, let meta = curMeta else { return nil }"));
});

test("executable probe extracts production factories and editor bodies with actual glass styling", () => {
    const runner = fs.readFileSync(path.join(__dirname, "../scripts/test-apple-player-timeline.sh"), "utf8");
    for (const productionInput of ["private var skipEditorTimelineValues:", "private func skipDBEditBar(",
        "private var touchOptionsActions:", "app/SourcesShared/SeekBarStyle.swift", "app/SourcesShared/SkipEditPolicy.swift",
        "app/SourcesShared/GlassStyle.swift", "app/SourcesShared/Theme.swift", "app/SourcesShared/ThemeManager.swift",
        "app/SourcesShared/ValueChangeObservation.swift"]) {
        assert(runner.includes(productionInput), `runtime probe must compile ${productionInput}`);
    }
});

test("player-glass regression compiles actual prepared source and renders accessibility and selection states", () => {
    const runner = fs.readFileSync(path.join(__dirname, "../scripts/test-apple-player-accent-controls.sh"), "utf8");
    const prepare = fs.readFileSync(path.join(__dirname, "../scripts/prepare-player-accent-controls.cjs"), "utf8");
    const harness = fs.readFileSync(path.join(__dirname, "../app/Tests/PlayerAccentControlsReduceTransparencyTests.swift"), "utf8");
    assert(runner.includes('node scripts/prepare-player-accent-controls.cjs "$accent_test_dir"'));
    assert(runner.includes("xcrun swiftc -Onone -j 1 -num-threads 1"));
    for (const productionInput of ["PlayerControlReduceTransparencyOverrideKey",
        "app/Tests/PlayerAccentControlsReduceTransparencyTests.swift", "private struct PlayerControlSurfaceModifier",
        "private struct PlayerControlButton:", "app/SourcesShared/GlassStyle.swift", "const playerGlass = glass;",
        "const modifier = production.slice(start, end);", "playerGlassFixture,\n  modifier,\n  harness,"]) {
        assert(prepare.includes(productionInput), "accent preparation must compile " + productionInput);
    }
    for (const runtimeProbe of ["NSHostingView", "cacheDisplay(in: host.bounds, to: bitmap)",
        "dark.alpha >= 0.98 && bright.alpha >= 0.98", "white player controls must keep 4.5:1 contrast",
        "normal off/selected controls must retain an accent cue", "disabled controls must dim their white glyph",
        ".environment(\\.playerControlReduceTransparencyOverride, reduceTransparency)",
        ".environment(\\.playerControlContrastOverride, contrast)", "assertOpaqueInvariant(increasedOffDark",
        "assertOpaqueInvariant(reducedOffDark"]) {
        assert(harness.includes(runtimeProbe), "accent probe must render " + runtimeProbe);
    }
});

test("touch seek renders the stored style with a real adjustable 44pt interaction surface", () => {
    const styled = source.slice(source.indexOf("private struct PlayerStyledSeekSlider:"),
        source.indexOf("private struct PlayerBufferedBand:"));
    for (const behavior of ["@ObservedObject var clock", "@AppStorage(SeekBarStyle.storageKey)",
        "SeekBarTrack(style: selectedStyle", ".frame(height: 44)", "DragGesture(minimumDistance: 0)",
        ".accessibilityAdjustableAction", "onEditingChanged(true)", "onEditingChanged(false)",
        "PlayerSeekInteractionPolicy.animates(requested: animated, scrubbing: scrubbing, reduceMotion: reduceMotion)"]) {
        assert(styled.includes(behavior), `missing real seek behavior: ${behavior}`);
    }
    const surface = source.slice(source.indexOf("private struct PlayerSeekSliderSurface:"),
        source.indexOf("private struct PlayerChapterMarkers:"));
    assert(surface.includes("#if os(iOS) || os(macOS)\n        PlayerStyledSeekSlider("),
        "both touch and desktop use the actual stored-style seek surface");
    assert(surface.includes("#else\n        PlayerClockSlider("), "other platforms retain native seek behavior");
    for (const contract of [".onContinuousHover { phase in", "guard !scrubbing else { return }",
        "onHoverPreviewChanged(Double(ratio))", "onHoverPreviewChanged(nil)",
        "onScrubChanged: onScrubChanged, onEditingChanged: onEditingChanged"]) {
        assert(surface.includes(contract), "retained shared seek/desktop-hover behavior: " + contract);
    }
});

test("pinch owns its multi-touch cycle without also delivering a tap", () => {
    const interaction = source.slice(source.indexOf("private struct PlayerVideoInteractionSurface:"),
        source.indexOf("private struct PlayerSizeModeFeedback:"));
    for (const contract of ["UIViewRepresentable", "view.isMultipleTouchEnabled = true",
        "UITapGestureRecognizer", "tap.numberOfTouchesRequired = 1", "UIPinchGestureRecognizer",
        "coordinator.pinch?.isEnabled = pinchEnabled && !locked", "coordinator.ownership.invalidate()",
        "ownership.consumeTap(tapCycle)", "pinchCycle = ownership.claimPinch()",
        "guard attached, pinchEnabled, !locked, let pinchCycle,",
        "ownership.consumePinch(pinchCycle)", "onPinch(recognizer.scale)"]) {
        assert(interaction.includes(contract), "retained actual touch ownership: " + contract);
    }
    const ownership = section("private struct PlayerVideoTouchPolicy", "#if os(iOS)\n@MainActor private struct PlayerVideoInteractionSurface:");
    assert(ownership.includes("expectedCycle == cycle, !multiTouchOwned, !tapDelivered"));
    assert(ownership.includes("expectedCycle == cycle, multiTouchOwned, !pinchDelivered"));
    const enabled = source.slice(source.indexOf("private var touchPinchEnabled:"),
        source.indexOf("private func applyVideoSize("));
    for (const guard of ["!isLocked", "panel == nil", "!touchOptionsVisible", "!showExternalChooser", "!showShare", "!loadFailed", "!scrubbing"]) {
        assert(enabled.includes(guard));
    }
    const apply = source.slice(source.indexOf("private func applyVideoSize("),
        source.indexOf("private func restartFromBeginning("));
    assert(apply.includes("videoSize = mode"));
    assert(apply.includes("coordinator.player?.setVideoSize(mode)"));
    assert(!apply.includes("scaleEffect") && !apply.includes("load("));
});

test("decorative layers preserve order, identities and non-interactive hit testing", () => {
    const track = source.slice(source.indexOf("private struct PlayerSeekTimelineTrack:"),
        source.indexOf("/// One provider refresh"));
    assert(track.indexOf("PlayerSeekSliderSurface(") < track.indexOf("PlayerSkipTimelineBands("));
    assert(track.indexOf("PlayerSkipTimelineBands(") < track.indexOf("PlayerEditedSegmentMarkers("));
    assert(track.indexOf("PlayerEditedSegmentMarkers(") < track.indexOf(".overlay(alignment: .bottomLeading)"));
    assert(source.includes("ForEach(fractions, id: \\.self)"));
    assert(source.includes("ForEach(segments) { segment in"));
    assert(source.includes("private struct PlayerChapterMarkers: View"));
    assert(source.includes("private struct PlayerEditedSegmentMarkers: View"));
    for (const [name, next] of [
        ["PlayerChapterMarkers", "PlayerSkipTimelineBands"],
        ["PlayerSkipTimelineBands", "PlayerEditedSegmentMarkers"],
        ["PlayerEditedSegmentMarkers", "PlayerSeekTimelineTrack"]
    ]) {
        const layer = source.slice(source.indexOf(`private struct ${name}:`), source.indexOf(`private struct ${next}:`));
        assert(layer.includes(".allowsHitTesting(false)"), `${name} must not intercept slider input`);
    }
});

test("player controls retain clipped profile glass, white glyphs and shared opaque accessibility fallbacks", () => {
    assertCurrentPlayerGlass(source, glassSource);

    const controls = [
        ["toolbar control", section("private struct PlayerControlButton:", "private struct PlayerTransportToolbar:")],
        ["touch icon", section("private struct PlayerTouchIconButton:", "private struct PlayerTouchAspectButton:")],
        ["touch aspect", section("private struct PlayerTouchAspectButton:", "private struct PlayerTouchOptionAction:")],
        ["touch transport", section("private struct PlayerTouchTransport:", "/// One provider refresh")],
        ["legacy center", section("private var legacyCenterTransport:", "/// The seek-step setting")],
        ["legacy seek", section("private func seekButton(", "private var skipEditorTimelineValues:")],
        ["legacy top icon", section("private func iconButton(", "#if os(iOS) || os(macOS)")],
        ["PiP", section("private struct AVPlayerPictureInPictureButton:", "// MARK: - Skip intro / outro")]
    ];
    for (const [name, body] of controls) {
        assert(body.includes(".buttonStyle(.plain)"), `${name} must explicitly use plain button style`);
        assert(body.includes("playerControlSurface"), `${name} must use the player shape surface`);
    }
    const primaryFaces = [
        section("private struct PlayerTouchTransport:", "/// One provider refresh"),
        section("private var legacyCenterTransport:", "/// The seek-step setting")
    ];
    for (const body of primaryFaces) {
        assert(body.includes("playerControlSurface(in: Circle(), prominent: true)"),
            "play/pause must retain the player-owned prominent glass surface");
    }

    const panelClose = section("private func selectionSheet(_ p: Panel)", "@ViewBuilder private func panelRow");
    const panelRows = section("@ViewBuilder private func panelRow", "/// Rows for a panel");
    assert(panelClose.includes(".buttonStyle(.plain)"), "selection-panel close must not inherit AppKit chrome");
    assert(panelRows.includes(".buttonStyle(.plain)"), "selection-panel rows must not inherit AppKit chrome");
    assert(source.includes("struct AirPlayRoutePickerButton: View"), "native AirPlay wrapper remains present");
    assert(source.includes(".playerControlSurface(in: Circle())\n            .accessibilityLabel(\"AirPlay\")"),
        "AirPlay wrapper keeps the player glass surface without replacing AVRoutePickerView");
    assert(source.includes("private struct AVPlayerPictureInPictureButton: View"),
        "native PiP wrapper remains present");
});


test("current glass contracts reject missing accessibility, clipping, tint order and layout wiring", () => {
    const mutations = [
        ["Reduce Transparency", source.replace("if reduceTransparency\n", "if false\n"), glassSource],
        ["increased contrast", source.replace("|| contrast == .increased || !isEnabled", "|| !isEnabled"), glassSource],
        ["disabled controls", source.replace("|| contrast == .increased || !isEnabled", "|| contrast == .increased"), glassSource],
        ["shape clipping", source.replaceAll(".clipShape(shape)", ".unclippedFixture()"), glassSource],
        ["profile tint below veil", source.replace("VortXPlayerChromePolicy.controlTintAlpha(", "removedControlTint("), glassSource],
        ["opaque shared face", source, glassSource.replace("forceOpaque: requiresContrast", "forceOpaque: false")],
        ["opaque material opacity", source, glassSource.replace(".opacity(reduceTransparency || forceOpaque ? 1 : materialOpacity)",
            ".opacity(materialOpacity)")],
        ["scrim tone", source, glassSource.replace("tone: .scrim))", "tone: .lift))")],
        ["backplate real caller", source.replace(".vortxPlayerBottomBackplate()", ".removedBackplateFixture()"), glassSource],
        ["bottom geometry", source.replace(".padding(.horizontal, 16).padding(.bottom, 16)", ".padding(.bottom, 999)"), glassSource],
        ["skip/chrome measurement", source.replace(".onPreferenceChange(PlayerBottomBarHeightKey.self) { bottomChromeHeight = $0 }",
            ".onPreferenceChange(PlayerBottomBarHeightKey.self) { _ in }"), glassSource]
    ];
    for (const [name, mutatedPlayer, mutatedGlass] of mutations) {
        assert(mutatedPlayer !== source || mutatedGlass !== glassSource, "negative control must mutate " + name);
        assert.throws(() => assertCurrentPlayerGlass(mutatedPlayer, mutatedGlass), undefined,
            "current contracts must reject removal of " + name);
    }
});
