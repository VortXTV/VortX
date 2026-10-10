// Standalone macOS render contract for the exact production player seek surface and toolbar button.
// The runner supplies only Theme.Palette and external callback fixtures; the actual seek style,
// track renderer, interaction policy, glass helper, and control bodies are extracted from source.

import SwiftUI
import AppKit

private struct SkipSegment: Identifiable {
    enum Kind { case intro, recap, credits, preview }
    let kind: Kind
    let start: Double
    let end: Double
    var id: String { "\(kind)-\(start)" }
}

private final class TimelineMeasurements {
    var size: CGSize = .zero
}

private struct BottomTimelineProbe: View {
    @State private var scrubbing = false
    @State private var scrubTarget = 0.0
    let clock: TimePosClock
    let measurements: TimelineMeasurements

    init(measurements: TimelineMeasurements) {
        let clock = TimePosClock()
        clock.position = 480
        self.clock = clock
        self.measurements = measurements
    }

    var body: some View {
        PlayerBottomTimeline(clock: clock, durationText: "20:00", endsAtText: "Ends at 21:00",
                             hasThumbnail: false) { size in
            measurements.size = size
            return PlayerSeekTimelineTrack(
                clock: clock,
                scrubbing: $scrubbing,
                scrubTarget: $scrubTarget,
                duration: 1_200,
                bufferedTime: 744,
                size: size,
                chapterFractions: [0.25, 0.75],
                accent: Color(red: 0.12, green: 0.82, blue: 0.38),
                animated: false,
                skipSegments: [SkipSegment(kind: .intro, start: 80, end: 130),
                               SkipSegment(kind: .credits, start: 1_080, end: 1_180)],
                showSkipEditor: true,
                skipEditStart: 200,
                skipEditEnd: 255,
                hoverPreviewTime: nil,
                onScrubChanged: { _ in },
                onEditingChanged: { _ in },
                onHoverPreviewChanged: { _ in },
                preview: { _, _ in AnyView(EmptyView()) }
            )
        }
        .frame(width: 1_300, height: 64)
    }
}

private struct ToolbarButtonProbe: View {
    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.11)
            PlayerControlButton(icon: "captions.bubble", title: "Subtitles", action: {})
        }
        .frame(width: 240, height: 76)
    }
}

private final class InteractionRecorder {
    var seekTargets: [Double] = []
    var editingStates: [Bool] = []
}

@MainActor
private func render<V: View>(_ view: V, width: Int, height: Int) -> NSBitmapImageRep {
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: CGFloat(width), height: CGFloat(height))
    renderer.scale = 1
    guard let image = renderer.cgImage else { fatalError("failed to render player-control component") }
    return NSBitmapImageRep(cgImage: image)
}

private func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (red, green, blue)
}

private func savePNG(_ bitmap: NSBitmapImageRep, name: String, directory: String) -> URL? {
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    do {
        try data.write(to: url)
        return url
    } catch {
        return nil
    }
}

private func changedPixelCount(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep,
                               xRange: Range<Int>, yRange: Range<Int>) -> Int {
    var changed = 0
    for y in yRange {
        for x in xRange {
            guard let left = rgb(lhs, x: x, y: y), let right = rgb(rhs, x: x, y: y) else { continue }
            let delta = abs(left.red - right.red) + abs(left.green - right.green) + abs(left.blue - right.blue)
            if delta > 0.06 { changed += 1 }
        }
    }
    return changed
}

@main @MainActor
private enum PlayerPremiumControlsRenderingTests {
    static func main() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        let suiteName = "VortX.PlayerPremiumControlsRenderingTests"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            fatalError("failed to create isolated player-control defaults suite")
        }
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        testDefaults.set(SeekBarStyle.wave.rawValue, forKey: SeekBarStyle.storageKey)
        let measurements = TimelineMeasurements()
        let timeline = BottomTimelineProbe(measurements: measurements).defaultAppStorage(testDefaults)
        let seekBitmap = render(timeline, width: 1_300, height: 64)
        var accentWavePixels = 0
        for y in 0..<64 {
            for x in 80..<300 {
                guard let pixel = rgb(seekBitmap, x: x, y: y) else { continue }
                if pixel.green > pixel.red * 1.35 && pixel.green > pixel.blue * 1.12 {
                    accentWavePixels += 1
                }
            }
        }
        testDefaults.set(SeekBarStyle.classic.rawValue, forKey: SeekBarStyle.storageKey)
        let classicMeasurements = TimelineMeasurements()
        let classicTimeline = BottomTimelineProbe(measurements: classicMeasurements).defaultAppStorage(testDefaults)
        let classicBitmap = render(classicTimeline, width: 1_300, height: 64)
        let waveShapeDifferencePixels = changedPixelCount(seekBitmap, classicBitmap,
                                                          xRange: 80..<650, yRange: 0..<64)
        let artifactDirectory = CommandLine.arguments[1]
        guard let timelinePNG = savePNG(seekBitmap, name: "premium-player-bottom-timeline.png", directory: artifactDirectory) else {
            fatalError("failed to save bottom-timeline diagnostic PNG")
        }
        guard let classicPNG = savePNG(classicBitmap, name: "premium-player-bottom-timeline-classic.png", directory: artifactDirectory) else {
            fatalError("failed to save classic timeline baseline PNG")
        }
        print("DIAG timeline waveStyle=wave classicBaseline=classic accentWavePixels=\(accentWavePixels) waveVsClassicChangedPixels=\(waveShapeDifferencePixels) assignedSize=\(measurements.size) classicAssignedSize=\(classicMeasurements.size) renderedFrame=1300x64 progress=0.4 buffered=0.62 animated=false reduceMotionPolicy=\(!PlayerSeekInteractionPolicy.animates(requested: true, scrubbing: false, reduceMotion: true)) png=\(timelinePNG.path) classicPng=\(classicPNG.path)")
        precondition(accentWavePixels > 12,
                     "the production macOS bottom timeline must show the selected wave in the profile accent")
        precondition(waveShapeDifferencePixels > 100,
                     "the production macOS bottom timeline must render Wave differently from Classic")
        precondition(measurements.size.height >= 44,
                     "the production Mac bottom timeline must allocate the full styled-seek interaction height")
        precondition(classicMeasurements.size.height >= 44)
        precondition(PlayerSeekInteractionPolicy.target(x: 300, width: 600, duration: 1_200) == 600,
                     "the production drag geometry must keep its 10pt endpoint inset")
        precondition(PlayerSeekInteractionPolicy.target(x: .nan, width: 600, duration: 1_200) == nil)
        precondition(!PlayerSeekInteractionPolicy.animates(requested: true, scrubbing: false, reduceMotion: true),
                     "Reduce Motion must pause production seek-track animation")
        let interactionClock = TimePosClock()
        interactionClock.position = 100
        let recorder = InteractionRecorder()
        let adjustableSeek = PlayerStyledSeekSlider(
            clock: interactionClock,
            scrubbing: .constant(false),
            scrubTarget: .constant(0),
            duration: 1_200,
            bufferedTime: 0,
            width: 600,
            accent: Color(red: 0.12, green: 0.82, blue: 0.38),
            animated: false,
            onScrubChanged: { recorder.seekTargets.append($0) },
            onEditingChanged: { recorder.editingStates.append($0) }
        )
        adjustableSeek.adjust(forward: true)
        precondition(recorder.seekTargets == [110] && recorder.editingStates == [true, false],
                     "the production adjustable seek action must retain its scrub callbacks")

        let button = PlayerControlButton(icon: "captions.bubble", title: "Subtitles", action: {})
        let buttonHost = NSHostingView(rootView: button)
        buttonHost.frame = NSRect(x: 0, y: 0, width: 240, height: 76)
        buttonHost.layoutSubtreeIfNeeded()
        let fittingHeight = buttonHost.fittingSize.height
        let buttonBitmap = render(ToolbarButtonProbe(), width: 240, height: 76)
        var accentEdgePixels = 0
        var brightGlyphPixels = 0
        for y in 12..<64 {
            for x in 12..<228 {
                guard let pixel = rgb(buttonBitmap, x: x, y: y) else { continue }
                if pixel.blue > pixel.red * 1.12 && pixel.blue > pixel.green * 0.92 {
                    accentEdgePixels += 1
                }
                if pixel.red > 0.78 && pixel.green > 0.78 && pixel.blue > 0.78 {
                    brightGlyphPixels += 1
                }
            }
        }
        guard let toolbarPNG = savePNG(buttonBitmap, name: "premium-player-toolbar-button.png", directory: artifactDirectory) else {
            fatalError("failed to save toolbar diagnostic PNG")
        }
        print("DIAG toolbar fittingHeight=\(fittingHeight) accentEdgePixels=\(accentEdgePixels) brightGlyphPixels=\(brightGlyphPixels) frame=240x76 png=\(toolbarPNG.path)")
        precondition(fittingHeight >= 44,
                     "the production Mac toolbar button must keep a usable 44pt target")
        precondition(accentEdgePixels > 8,
                     "the production toolbar glass must retain a restrained accent edge")
        precondition(brightGlyphPixels > 20,
                     "the production toolbar label and icon must remain readable white on glass")

        // Keep the interaction/accessibility contract tied to the extracted production declarations.
        print("PASS production macOS seek surface: Wave/accent render, paused Reduce Motion, drag geometry, and adjustable seek")
        print("PASS production Mac toolbar button: 44pt target, readable glyphs, restrained accent glass edge")
    }
}
