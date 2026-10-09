// The runner compiles the actual engine activation/sync/update methods and actual cue renderer. No AV objects.
import Foundation

@MainActor final class SubtitleClockFixturePlayer {
    struct Time { let seconds: Double }
    var seconds = 10.0
    var paused = true
    func currentTime() -> Time { Time(seconds: seconds) }
}
@MainActor final class SubtitleClockFixtureOverlay {
    var text: String?
    var styleApplications = 0
    var updates = 0
    func setText(_ value: String?) { text = value; updates += 1 }
    func applyStyle() { styleApplications += 1 }
}
@MainActor final class SubtitleClockFixtureEngine {
    let player = SubtitleClockFixturePlayer()
    var remuxTimelineOrigin = 1000.0
    let subtitleRenderer = SubtitleCueRenderer()
    var subtitleOverlay: SubtitleClockFixtureOverlay? = SubtitleClockFixtureOverlay()
    var externalSubActive = false
    var nativeOverlayInvalidations = 0
    func invalidateNativeSubtitleOverlay() { nativeOverlayInvalidations += 1 }
}

@main @MainActor private enum AVPlayerSubtitleClockTests {
    static var failures = 0
    static func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        if !condition { failures += 1 }
    }
    static func main() {
        let engine = SubtitleClockFixtureEngine()
        engine.subtitleRenderer.load(cues: [
            .init(start: 1006, end: 1008, text: "earlier source cue"),
            .init(start: 1009, end: 1011, text: "current source cue"),
            .init(start: 1012, end: 1014, text: "later source cue"),
            .init(start: 2009, end: 2011, text: "wrong double-origin cue")
        ])
        engine.setExternalSubtitleActive(true)
        check("paused remux activation immediately displays the source-time cue",
              engine.subtitleOverlay?.text == "current source cue")
        check("activation retains external/native rendering handoff and style",
              engine.externalSubActive && engine.nativeOverlayInvalidations == 1
                && engine.subtitleOverlay?.styleApplications == 1)
        check("activation leaves actual paused player clock unchanged", engine.player.paused && engine.player.seconds == 10)

        // No periodic tick occurs between these calls: each production method must refresh the right cue itself.
        engine.setSubDelay(3)
        check("paused positive sync immediately displays earlier source cue",
              engine.subtitleOverlay?.text == "earlier source cue" && engine.subtitleRenderer.offset == 3)
        engine.setSubDelay(-3)
        check("paused negative sync immediately displays later source cue",
              engine.subtitleOverlay?.text == "later source cue" && engine.subtitleRenderer.offset == -3)
        engine.setSubDelay(0)
        engine.setSubDelay(0)
        check("repeated sync reset neither double-adds origin nor rewinds to player zero",
              engine.subtitleOverlay?.text == "current source cue")
        check("sync never seeks or resumes the paused player", engine.player.paused && engine.player.seconds == 10)
        check("sync does not reapply style or change native ownership",
              engine.nativeOverlayInvalidations == 1 && engine.subtitleOverlay?.styleApplications == 1)

        engine.setExternalSubtitleActive(false)
        let updatesWhileOff = engine.subtitleOverlay?.updates
        engine.setSubDelay(7)
        check("native subtitle fallback is untouched while external captions are off",
              !engine.externalSubActive && engine.subtitleOverlay?.text == nil
                && engine.subtitleOverlay?.updates == updatesWhileOff && engine.nativeOverlayInvalidations == 1)

        engine.remuxTimelineOrigin = 2000
        engine.player.seconds = 5
        engine.subtitleRenderer.offset = 0
        engine.subtitleRenderer.load(cues: [.init(start: 2004, end: 2006, text: "replacement origin")])
        engine.setExternalSubtitleActive(true)
        check("replacement mount uses current achieved origin rather than retained resume request",
              engine.subtitleOverlay?.text == "replacement origin")

        engine.remuxTimelineOrigin = 0
        engine.player.seconds = 10
        engine.subtitleRenderer.load(cues: [
            .init(start: 6, end: 8, text: "direct earlier"), .init(start: 9, end: 11, text: "direct current")
        ])
        engine.setExternalSubtitleActive(true)
        check("direct native origin zero retains current-clock activation", engine.subtitleOverlay?.text == "direct current")
        engine.setSubDelay(3)
        check("direct native origin zero retains positive-delay semantics", engine.subtitleOverlay?.text == "direct earlier")

        engine.remuxTimelineOrigin = 1000
        engine.player.seconds = .nan
        engine.subtitleRenderer.offset = 0
        engine.subtitleRenderer.load(cues: [.init(start: 1000, end: 1001, text: "origin cue")])
        engine.setExternalSubtitleActive(true)
        check("nonfinite player clock follows existing presented-time policy", engine.subtitleOverlay?.text == "origin cue")
        engine.player.seconds = -1
        engine.setSubDelay(0)
        check("negative player clock cannot rewind before achieved origin", engine.subtitleOverlay?.text == "origin cue")
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
