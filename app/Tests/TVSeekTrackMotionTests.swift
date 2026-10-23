import Foundation

// Compile with TVSeekTrackProductionExtract.swift from the preparation script. It contains
// the actual TV track constructor, progress expressions, style isAnimated member and shared
// Timeline paused expression, not a copied animation formula. UI/Theme/current-style selection
// are deterministic probes: this proves source-unit behavior, not SwiftUI scheduling/rendering.
@main
enum TVSeekTrackMotionTests {
    @MainActor static func main() {
        var failures = 0
        var cases = 0
        func check(_ value: Bool, _ message: String) {
            if !value {
                failures += 1
                if failures <= 12 { print("FAIL: \(message)") }
            }
        }
        // Independent finite oracle: only mask 1 (visible controls, all suppressors off)
        // permits motion. Every one-flag denial and all combinations are included.
        for mask in 0..<64 {
            var fixture = TVSeekTrackProductionFixture()
            fixture.showInfo = mask & 1 != 0
            fixture.showOptions = mask & 2 != 0
            fixture.loadFailed = mask & 4 != 0
            fixture.isPaused = mask & 8 != 0
            fixture.scrubbing = mask & 16 != 0
            fixture.accessibilityReduceMotion = mask & 32 != 0
            for style in SeekBarStyle.allCases {
                SeekBarStyle.current = style // fixture actor-local state, never real preferences
                let track = fixture.makeTrack()
                let permitted = mask == 1
                let staticStyle = style.rawValue == "classic" || style.rawValue == "minimal"
                check(track.animated == permitted, "actual TV animated argument: state \(mask), style \(style.rawValue)")
                check(track.sourceTimelinePaused() == (!permitted || staticStyle),
                      "actual shared paused expression: state \(mask), style \(style.rawValue)")
                check(track.style == style, "caller preserves fixture-selected style")
                check(track.progress == (fixture.scrubbing ? 0.75 : 0.25), "caller preserves played/scrub fraction")
                check(track.buffered == 0.5, "caller preserves buffered fraction")
                check(track.accent == Theme.Palette.accent && track.track == Theme.Palette.textPrimary.opacity(0.22),
                      "caller preserves colour arguments")
                cases += 1
            }
        }
        for duration in [0.0, -1.0, 100.0] {
            for position in [-10.0, 25.0, 150.0] {
                var fixture = TVSeekTrackProductionFixture()
                fixture.duration = duration
                fixture.currentTime = position
                fixture.bufferedTime = position
                let track = fixture.makeTrack()
                let expected: Double
                if duration <= 0 { expected = 0 }
                else if position < 0 { expected = 0 }
                else if position > duration { expected = 1 }
                else { expected = 0.25 }
                check(track.progress == expected && track.buffered == expected, "unchanged finite clamping inputs")
                cases += 1
            }
        }
        if failures != 0 {
            print("TV seek motion source-unit failed: \(failures) assertions across \(cases) cases")
            exit(1)
        }
        print("TV seek motion source-unit passed: \(cases) cases; no UI/Timeline scheduling or device-performance claim")
    }
}
