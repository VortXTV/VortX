"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { test } = require("node:test");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "../app/Sources/PlayerScreen.swift"), "utf8");

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
        "app/SourcesShared/GlassStyle.swift", "app/SourcesShared/Theme.swift", "app/SourcesShared/ThemeManager.swift"]) {
        assert(runner.includes(productionInput), `runtime probe must compile ${productionInput}`);
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
    assert(surface.includes("#if os(iOS)\n        PlayerStyledSeekSlider("));
    assert(surface.includes("#else\n        PlayerClockSlider("), "retain native desktop seek behavior");
});

test("pinch changes the live engine mode and is exclusive with video taps", () => {
    const interaction = source.slice(source.indexOf("private struct PlayerVideoInteractionSurface:"),
        source.indexOf("private struct PlayerSizeModeFeedback:"));
    assert(interaction.includes(".exclusively(before: TapGesture())"));
    assert(interaction.includes("if pinchEnabled && !locked { onPinch(scale) }"));
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
