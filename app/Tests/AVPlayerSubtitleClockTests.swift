// The runner compiles the actual engine activation/sync/update/retirement methods and cue renderer.
// This fixture exercises manual/raw subtitle timing. It cannot mint an automatic request or publication.
import Foundation

#if VORTX_AVKIT_ALIGNMENT_REQUEST
enum AVSubtitleRequestRetirementCause: Equatable {
    case successor, ownerRevoked, uncertainNativeCommit, cancelledNativeCommit, engineTeardown
}
// Nil-only tripwires satisfy the current method dependencies without substituting a successful
// AVKit request, credential owner, publication receipt or corrected-overlay renderer. Private
// trapping initializers prevent this fixture from manufacturing either capability.
@MainActor final class SubtitleClockUnexpectedAutomaticRequest {
    enum Kind { case automaticSelection, explicitKeepCurrent }
    private init() { preconditionFailure("Automatic request is outside the manual clock fixture") }
    var kind: Kind { preconditionFailure("Automatic request access is outside the manual clock fixture") }
    var publication: SubtitleClockUnexpectedPublication? {
        get { preconditionFailure("Publication access is outside the manual clock fixture") }
        set { preconditionFailure("Publication mutation is outside the manual clock fixture") }
    }
    var rawSettled: Bool {
        get { preconditionFailure("Automatic request access is outside the manual clock fixture") }
        set { preconditionFailure("Automatic request mutation is outside the manual clock fixture") }
    }
    var nativeCommitStarted: Bool {
        get { preconditionFailure("Native subtitle commit is outside the manual clock fixture") }
        set { preconditionFailure("Native subtitle commit is outside the manual clock fixture") }
    }
    var retirementCause: AVSubtitleRequestRetirementCause? {
        get { preconditionFailure("Request retirement is outside the manual clock fixture") }
        set { preconditionFailure("Request retirement is outside the manual clock fixture") }
    }
}
@MainActor final class SubtitleClockUnexpectedPublication {
    private init() { preconditionFailure("Publication is outside the manual clock fixture") }
    var isRevoked: Bool { preconditionFailure("Publication access is outside the manual clock fixture") }
    func claimOwnerRevocationForDefaultRetirement() -> Bool {
        preconditionFailure("Owner revocation is outside the manual clock fixture")
    }
    func close() { preconditionFailure("Publication cleanup is outside the manual clock fixture") }
}
#endif

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
#if VORTX_AVKIT_ALIGNMENT_REQUEST
    func setPreparedPresentation(_ value: SubtitleReferencePresentation.Presentation?) {
        preconditionFailure("Corrected-overlay publication is outside the manual clock fixture")
    }
#endif
}
@MainActor final class SubtitleClockFixtureEngine {
    let player = SubtitleClockFixturePlayer()
    var remuxTimelineOrigin = 1000.0
    let subtitleRenderer = SubtitleCueRenderer()
    var subtitleOverlay: SubtitleClockFixtureOverlay? = SubtitleClockFixtureOverlay()
    var externalSubActive = false
#if VORTX_CURRENT_ALIGNMENT
    var subtitleAlignmentGeneration: UInt64 = 0
#endif
#if VORTX_AVKIT_ALIGNMENT_REQUEST
    var automaticSubtitleRequest: SubtitleClockUnexpectedAutomaticRequest?
    var automaticSubtitleTask: Task<Void, Never>?
    var alignedSubtitlePublication: SubtitleClockUnexpectedPublication?
    var alignedSubtitlePresentation: SubtitleReferencePresentation.Prepared?
    var alignedSubtitleClock = SubtitleReferencePresentation.Clock()
    var alignedSubtitleSelection: Never?
    var externalSubtitleSettlement = AVPlayerRecoverySettlementPolicy.ExternalSubtitleSettlement()
    var externalSubtitleRequestRevision: UInt64 = 41
    var subtitleSelectionRevision: UInt64 = 73
    func automaticSubtitleRequestIsCurrent(_ generation: UInt64) -> Bool {
        preconditionFailure("Automatic admission is outside the manual clock fixture")
    }
#endif
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
#if VORTX_CURRENT_ALIGNMENT
        guard let originalRevision = engine.subtitleAlignmentRevision else { preconditionFailure("Concrete AV lost its capability") }
#endif
        engine.subtitleRenderer.load(cues: [
            .init(start: 1006, end: 1008, text: "earlier source cue"),
            .init(start: 1009, end: 1011, text: "current source cue"),
            .init(start: 1012, end: 1014, text: "later source cue"),
            .init(start: 2009, end: 2011, text: "wrong double-origin cue")
        ])
        engine.setExternalSubtitleActive(true)
#if VORTX_CURRENT_ALIGNMENT
        check("external activation retires original alignment", engine.subtitleAlignmentRevision != originalRevision)
        let beforeSync = engine.subtitleAlignmentRevision
#endif
        check("paused remux activation immediately displays the source-time cue",
              engine.subtitleOverlay?.text == "current source cue")
        check("activation retains external/native rendering handoff and style",
              engine.externalSubActive && engine.nativeOverlayInvalidations == 1
                && engine.subtitleOverlay?.styleApplications == 1)
        check("activation leaves actual paused player clock unchanged", engine.player.paused && engine.player.seconds == 10)

        // No periodic tick occurs between these calls: each production method must refresh the right cue itself.
#if VORTX_AVKIT_ALIGNMENT_REQUEST
        // This is pure presentation data, never a publication or an owner grant. Retirement must
        // discard it and reset the real Clock before the ordinary raw-file overlay refreshes.
        let retimed = SubtitleReferenceNativeQuery.RetimedFile(
            originalJob: UUID(), srt: Data("1\n00:16:49,000 --> 00:16:51,000\npure prepared cue\n\n".utf8),
            cues: [.init(startMs: 1009_000, endMs: 1011_000, text: "pure prepared cue")],
            offsetMs: 0, driftPpm: 0, confidence: 1000)
        let prepared: SubtitleReferencePresentation.Prepared
        do { prepared = try SubtitleReferencePresentation.prepare(retimed) }
        catch { preconditionFailure("Genuine pure presentation preparation failed: \(error)") }
        engine.alignedSubtitlePresentation = prepared
        check("actual pure clock first sample changes", engine.alignedSubtitleClock.sample(
            prepared, mediaSeconds: 1010, manualDelaySeconds: 0).changed)
        check("actual pure clock repeated sample is stable", !engine.alignedSubtitleClock.sample(
            prepared, mediaSeconds: 1010, manualDelaySeconds: 0).changed)
        engine.externalSubtitleSettlement.request(generation: 7, mountIdentity: 8, revision: 73)
        let settlementBeforeTiming = engine.externalSubtitleSettlement
        let task = Task<Void, Never> {}
        engine.automaticSubtitleTask = task
#endif
        engine.setSubDelay(3)
#if VORTX_AVKIT_ALIGNMENT_REQUEST
        check("manual timing cancels and releases the original worker task",
              task.isCancelled && engine.automaticSubtitleTask == nil)
        check("manual timing drops prepared state without manufacturing a request or publication",
              engine.alignedSubtitlePresentation == nil && engine.automaticSubtitleRequest == nil
                && engine.alignedSubtitlePublication == nil && engine.alignedSubtitleSelection == nil)
        check("manual retirement resets the actual pure clock", engine.alignedSubtitleClock.sample(
            prepared, mediaSeconds: 1010, manualDelaySeconds: 0).changed)
        check("manual timing preserves pending native settlement and file/selection intent revisions",
              engine.externalSubtitleSettlement == settlementBeforeTiming
                && engine.externalSubtitleRequestRevision == 41 && engine.subtitleSelectionRevision == 73)
#endif
#if VORTX_CURRENT_ALIGNMENT
        check("positive timing edit retires alignment", engine.subtitleAlignmentRevision != beforeSync)
        let afterPositiveSync = engine.subtitleAlignmentRevision
#endif
        check("paused positive sync immediately displays earlier source cue",
              engine.subtitleOverlay?.text == "earlier source cue" && engine.subtitleRenderer.offset == 3)
        engine.setSubDelay(-3)
#if VORTX_CURRENT_ALIGNMENT
        check("negative timing edit retires alignment", engine.subtitleAlignmentRevision != afterPositiveSync)
#endif
        check("paused negative sync immediately displays later source cue",
              engine.subtitleOverlay?.text == "later source cue" && engine.subtitleRenderer.offset == -3)
        engine.setSubDelay(0)
#if VORTX_CURRENT_ALIGNMENT
        let beforeRepeatedReset = engine.subtitleAlignmentRevision
#endif
        engine.setSubDelay(0)
#if VORTX_CURRENT_ALIGNMENT
        check("equal-value reset still retires pending preparation", engine.subtitleAlignmentRevision != beforeRepeatedReset)
#endif
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
#if VORTX_AVKIT_ALIGNMENT_REQUEST
        check("manual-only fixture never acquired automatic request or publication authority",
              engine.automaticSubtitleRequest == nil && engine.alignedSubtitlePublication == nil)
#endif
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
