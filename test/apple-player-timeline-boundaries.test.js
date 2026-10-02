"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { test } = require("node:test");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "../app/Sources/PlayerScreen.swift"), "utf8");

test("bottom-bar geometry returns a concrete rendering boundary", () => {
    const bottom = source.slice(source.indexOf("private var bottomBar: some View"),
        source.indexOf("// MARK: - Skip segment edit bar"));
    const geometry = bottom.slice(bottom.indexOf("GeometryReader { geo in"), bottom.indexOf(".frame(height: 24)"));
    assert(geometry.includes("PlayerSeekTimelineTrack("));
    assert(!geometry.includes("PlayerClockSlider("));
    assert(!geometry.includes(".overlay"), "do not reintroduce the deeply nested metadata tree in GeometryReader");
    for (const binding of ["clock: timePosClock", "scrubbing: $scrubbing", "scrubTarget: $scrubTarget",
        "chapterFractions: chapterFractions", "skipSegments: skipSegments", "hoverPreviewTime: hoverPreviewTime"]) {
        assert(geometry.includes(binding), `retained timeline input: ${binding}`);
    }
    for (const operation of ["issueSeek(to: target, reason: \"scrub\")", "reportSeek(target)",
        "scrubThumbnails.clear()", "scheduleHide()", "trickplayBubbleOffset(sliderWidth: width)"]) {
        assert(geometry.includes(operation), `retained transport/preview operation: ${operation}`);
    }
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
