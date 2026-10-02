import SwiftUI
import AppKit

/// This test constructs and lays out the production timeline views, not a parallel mock of
/// their rendering. The test runner exposes only their file-private declarations for this probe.
@main
struct PlayerSeekTimelineConstructionTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let clock = TimePosClock()
        for duration in [0.0, 2_700.0] {
            for scrubbing in [false, true] {
                for showEditor in [false, true] {
                    let timeline = PlayerSeekTimelineTrack(
                        clock: clock, scrubbing: .constant(scrubbing), scrubTarget: .constant(30),
                        duration: duration, bufferedTime: 60, size: CGSize(width: 720, height: 24),
                        chapterFractions: [0.1, 0.5, 0.9], accent: .orange,
                        skipSegments: [SkipSegment(kind: .intro, start: 0, end: 60),
                                       SkipSegment(kind: .credits, start: 2_600, end: 2_700)],
                        showSkipEditor: showEditor, skipEditStart: 10, skipEditEnd: 30,
                        hoverPreviewTime: scrubbing ? 30 : nil,
                        onScrubChanged: { _ in }, onEditingChanged: { _ in },
                        onHoverPreviewChanged: { _ in }, preview: { time, _ in AnyView(Text("\(time)")) }
                    )
                    // Creating the body exercises the same generic metadata instantiation that
                    // failed in the build-254 report, before mounting or loading any media engine.
                    let body = timeline.body
                    let type = String(reflecting: Swift.type(of: body))
                    precondition(type.contains("PlayerSeekSliderSurface"))
                    precondition(!type.contains("PlayerClockSlider"), "slider metadata leaked through the concrete boundary")
                    precondition(!type.contains("PlayerBufferedBand"), "buffer metadata leaked through the concrete boundary")
                    precondition(!type.contains("ForEach"), "marker metadata leaked through the concrete boundary")
                    let host = NSHostingView(rootView: timeline)
                    host.frame = CGRect(x: 0, y: 0, width: 720, height: 24)
                    host.layoutSubtreeIfNeeded()
                    clock.position = 25
                    host.layoutSubtreeIfNeeded()
                }
            }
        }
        print("PASS production seek timeline constructs/layouts with zero duration, markers, editor and preview")
        print("PASS concrete view boundaries exclude slider and marker generic trees from the enclosing timeline")
    }
}
