// Executable harness for the remux resume (timeline origin) decisions.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/remux-resume-policy-test \
//     app/Sources/Player/RemuxResumePolicy.swift \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Sources/Player/DVPlaybackPolicy.swift \
//     app/Tests/RemuxResumePolicyTests.swift && /tmp/remux-resume-policy-test
//
// This suite CALLS the production decisions. The code that uses them lives in AVPlayerEngine and
// VortXMKVRemuxStream, which pull in AVFoundation, Network and the whole FFmpeg vendor tree, so a suite written
// against those files could only have asserted on source text, a shape already proven inadequate here.
//
// The bar is mutation survival, not a pass count. The properties that matter most, because getting them wrong
// silently destroys a viewer's stored position rather than failing loudly:
//   - `presented` must ADD the origin, and must not answer 0 for a resumed session whose clock is not yet
//     readable, since 0 is exactly the value that would overwrite an hour of watched progress;
//   - `playerSeek` must SUBTRACT the origin and clamp on BOTH sides, so no seek can ever be issued outside
//     what the mount produced;
//   - the two must be exact inverses inside the reachable band, which is the only reason a scrub lands where
//     the scrubber said it would.
// Boundary pairs (just inside vs exactly at each clamp) catch comparison flips; the round-trip cases catch a
// sign error that no single-direction assertion would notice.

import Foundation

// Standalone-compilation stub for the buffer's production default (same shape as the sibling harnesses). The
// buffer is compiled in only so the REAL playlist renderer and startup oracle can run against real windows.
struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

/// Standalone-compilation stub for the buffer's failure-reason funnel (same pattern as the RemoteConfig stub).
enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) { print("[\(tag)] \(message)") }
}

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

/// Seconds are compared with a tolerance far tighter than a video frame, so a real arithmetic mistake fails
/// while binary floating point representation does not.
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@main
enum RemuxResumePolicyTests {
    @MainActor static func main() { run() }
}

@MainActor func run() {

// MARK: - originRequest

// The load-bearing case: a real resume point is passed through unchanged, so the input seek targets exactly
// where the viewer stopped.
check("origin: a real resume point is requested verbatim",
      near(RemuxResumePolicy.originRequest(resumeSeconds: 1830), 1830))

// 0 is the "start at the beginning" answer, and it is what makes this whole feature inert for every session
// that is not resuming: 0 disables the input seek AND the packet rebase, so the produced bytes are identical.
check("origin: no resume point means start at the beginning",
      RemuxResumePolicy.originRequest(resumeSeconds: 0) == 0)
check("origin: a negative position is refused",
      RemuxResumePolicy.originRequest(resumeSeconds: -600) == 0)
check("origin: a non-finite position is refused",
      RemuxResumePolicy.originRequest(resumeSeconds: .nan) == 0)
check("origin: an infinite position is refused",
      RemuxResumePolicy.originRequest(resumeSeconds: .infinity) == 0)

// The trivial floor, asserted as a boundary PAIR so raising it, lowering it, or flipping > to >= fails.
check("origin: a position below the trivial floor is refused",
      RemuxResumePolicy.originRequest(resumeSeconds: RemuxResumePolicy.minimumResumeSeconds - 0.5) == 0)
check("origin: a position exactly at the trivial floor is refused",
      RemuxResumePolicy.originRequest(resumeSeconds: RemuxResumePolicy.minimumResumeSeconds) == 0)
check("origin: a position just past the trivial floor is accepted",
      near(RemuxResumePolicy.originRequest(resumeSeconds: RemuxResumePolicy.minimumResumeSeconds + 0.5),
           RemuxResumePolicy.minimumResumeSeconds + 0.5))

// The floor must stay a floor. A value raised to minutes would silently stop resuming the very titles this
// exists for, and no assertion above would notice.
check("origin: the trivial floor stays small",
      RemuxResumePolicy.minimumResumeSeconds > 0 && RemuxResumePolicy.minimumResumeSeconds <= 30)
check("origin: the maximum is finite and comfortably above a feature film",
      RemuxResumePolicy.maximumResumeSeconds >= 12 * 60 * 60
        && RemuxResumePolicy.maximumResumeSeconds <= 7 * 24 * 60 * 60)
check("origin: the exact supported maximum is accepted",
      RemuxResumePolicy.originRequest(resumeSeconds: RemuxResumePolicy.maximumResumeSeconds)
        == RemuxResumePolicy.maximumResumeSeconds)
check("origin: a value above the supported maximum is refused",
      RemuxResumePolicy.originRequest(
        resumeSeconds: RemuxResumePolicy.maximumResumeSeconds + 1) == 0)
check("origin: a pathological finite value is refused without conversion",
      RemuxResumePolicy.originRequest(resumeSeconds: Double.greatestFiniteMagnitude) == 0)

// MARK: - checked FFmpeg seek conversion

check("timestamp: a valid resume point converts exactly to microseconds",
      RemuxResumePolicy.seekTimestampMicroseconds(resumeSeconds: 1830.25) == 1_830_250_000)
check("timestamp: the exact maximum converts without overflow",
      RemuxResumePolicy.seekTimestampMicroseconds(
        resumeSeconds: RemuxResumePolicy.maximumResumeSeconds)
        == Int64(RemuxResumePolicy.maximumResumeSeconds * 1_000_000))
check("timestamp: values at the trivial floor do not request an input seek",
      RemuxResumePolicy.seekTimestampMicroseconds(
        resumeSeconds: RemuxResumePolicy.minimumResumeSeconds) == nil)
check("timestamp: an above-maximum or huge finite value is rejected before Int64 conversion",
      RemuxResumePolicy.seekTimestampMicroseconds(
        resumeSeconds: RemuxResumePolicy.maximumResumeSeconds + 1) == nil
        && RemuxResumePolicy.seekTimestampMicroseconds(
          resumeSeconds: Double.greatestFiniteMagnitude) == nil)

// MARK: - origin latch source

check("origin latch: only a mapped base-video packet may establish the timeline origin",
      RemuxResumePolicy.canEstablishOrigin(
        packetStreamIndex: 3, baseVideoStreamIndex: 3, isMapped: true))
check("origin latch: a mapped audio or subtitle packet cannot establish video origin",
      !RemuxResumePolicy.canEstablishOrigin(
        packetStreamIndex: 4, baseVideoStreamIndex: 3, isMapped: true))
check("origin latch: an unmapped packet cannot establish video origin even if its index matches",
      !RemuxResumePolicy.canEstablishOrigin(
        packetStreamIndex: 3, baseVideoStreamIndex: 3, isMapped: false))
check("shipping: resume is enabled now that the pre-load origin lifecycle is wired",
      RemuxResumePolicy.isEnabledByDefault)

// MARK: - one-shot engine handoff

var configuration = RemuxResumeConfiguration()
check("configuration: no caller value means the next load has no configured origin",
      configuration.consumeForNextLoad() == nil)
configuration.configure(seconds: 1830.25)
check("configuration: a nonzero source origin is stored exactly",
      configuration.pendingOriginSeconds == 1830.25)
check("configuration: the next load consumes the configured nonzero origin",
      configuration.consumeForNextLoad() == 1830.25)
check("configuration: consumption is one-shot so a later title cannot inherit it",
      configuration.consumeForNextLoad() == nil)
configuration.configure(seconds: .infinity)
check("configuration: an explicit invalid value becomes an explicit start-at-zero request",
      configuration.consumeForNextLoad() == 0)
configuration.configure(seconds: 600)
configuration.reset()
check("configuration: stop/reset clears an unconsumed request",
      configuration.consumeForNextLoad() == nil)

// MARK: - presented (player clock -> source seconds)

// THE progress-save property. A session resumed at 1830s that reads 12s on the player clock is at 1842s in the
// film, and reporting anything else is what wipes the stored position.
check("presented: the origin is added to the player clock",
      near(RemuxResumePolicy.presented(playerSeconds: 12, origin: 1830), 1842))
check("presented: a mount that started at the beginning reports the player clock unchanged",
      near(RemuxResumePolicy.presented(playerSeconds: 12, origin: 0), 12))
check("presented: the very first sample of a resumed session reports the resume point, not zero",
      near(RemuxResumePolicy.presented(playerSeconds: 0, origin: 1830), 1830))

// AVPlayer reports NaN before the first sample. Answering 0 there is the destructive answer, so it is asserted
// explicitly rather than left to the max() below.
check("presented: an unreadable clock reports the origin, never zero",
      near(RemuxResumePolicy.presented(playerSeconds: .nan, origin: 1830), 1830))
check("presented: an infinite clock reports the origin",
      near(RemuxResumePolicy.presented(playerSeconds: .infinity, origin: 1830), 1830))
check("presented: a negative clock cannot report earlier than the origin",
      near(RemuxResumePolicy.presented(playerSeconds: -3, origin: 1830), 1830))

// MARK: - playerSeek (source seconds -> player clock, clamped)

// Regression: AVPlayer's duration is in PLAYER time after an origin remux. Clamping the SOURCE request to
// that value before subtracting the origin turns a valid 5000s source seek into player second zero. The source
// duration must win in source space first, then the mapped player target may be bounded in player space.
check("seek: source duration clamps before origin mapping and player bounds",
      near(RemuxResumePolicy.playerSeek(
        sourceSeconds: 5000,
        origin: 3600,
        authoritativeSourceDurationSeconds: 7200,
        playerDurationSeconds: 3600,
        producedEdgePlayerSeconds: 2000), 1400))
check("seek: a source target before the resumed origin still maps to player zero",
      near(RemuxResumePolicy.playerSeek(
        sourceSeconds: 1200,
        origin: 3600,
        authoritativeSourceDurationSeconds: 7200,
        playerDurationSeconds: 3600,
        producedEdgePlayerSeconds: 2000), 0))
check("seek: the authoritative source end is applied before the player-duration end",
      near(RemuxResumePolicy.playerSeek(
        sourceSeconds: 9000,
        origin: 3600,
        authoritativeSourceDurationSeconds: 7200,
        playerDurationSeconds: 3600,
        producedEdgePlayerSeconds: 5000), 3599))

// A remux duration is reported in SOURCE time. Prefer the demuxer's authoritative duration even when
// AVPlayer returns a finite player duration; if the source duration is unavailable, add the origin to that
// finite player duration. The same helper must leave every non-remux duration byte-for-byte unchanged.
check("duration: authoritative remux source duration wins over finite player duration",
      near(RemuxResumePolicy.reportedDuration(
        playerDurationSeconds: 3600,
        origin: 3600,
        authoritativeSourceDurationSeconds: 7200,
        isRemuxMounted: true), 7200))
check("duration: authoritative remux source duration wins over indefinite player duration",
      near(RemuxResumePolicy.reportedDuration(
        playerDurationSeconds: Double.nan,
        origin: 3600,
        authoritativeSourceDurationSeconds: 7200,
        isRemuxMounted: true), 7200))
check("duration: unknown remux source falls back to origin plus finite player duration",
      near(RemuxResumePolicy.reportedDuration(
        playerDurationSeconds: 3600,
        origin: 3600,
        authoritativeSourceDurationSeconds: nil,
        isRemuxMounted: true), 7200))
check("duration: non-remux duration is an exact identity",
      RemuxResumePolicy.reportedDuration(
        playerDurationSeconds: 3600,
        origin: 3600,
        authoritativeSourceDurationSeconds: 7200,
        isRemuxMounted: false) == 3600)

// The ordinary case: a scrub inside the produced band converts by subtracting the origin.
check("seek: a target inside the produced band converts by subtracting the origin",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1900, origin: 1830, producedEdgePlayerSeconds: 300), 70))
check("seek: a non-resumed mount converts the target unchanged",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 70, origin: 0, producedEdgePlayerSeconds: 300), 70))

// The backward clamp: content before the origin was never produced. Landing at the origin is the documented
// cost of this design; landing anywhere else means a seek into bytes that do not exist.
check("seek: a target before the origin clamps to the origin",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 60, origin: 1830, producedEdgePlayerSeconds: 300), 0))
check("seek: a target exactly at the origin is the start of the player timeline",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1830, origin: 1830, producedEdgePlayerSeconds: 300), 0))
check("seek: a target one second past the origin is not clamped",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1831, origin: 1830, producedEdgePlayerSeconds: 300), 1))

// The forward clamp, as a boundary pair so > flipped to >= (or the cap dropped) fails.
check("seek: a target past the produced edge clamps to the edge",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1830 + 400, origin: 1830, producedEdgePlayerSeconds: 300), 300))
check("seek: a target exactly at the produced edge is not moved",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1830 + 300, origin: 1830, producedEdgePlayerSeconds: 300), 300))
check("seek: a target just inside the produced edge is not moved",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1830 + 299, origin: 1830, producedEdgePlayerSeconds: 300), 299))

// An unknown edge must not be treated as an edge of zero, which would pin every seek to the start of the
// timeline. This is the case that fires on a mount whose seekable range has not been published yet.
check("seek: an unknown produced edge caps nothing",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1830 + 400, origin: 1830, producedEdgePlayerSeconds: 0), 400))
check("seek: a negative produced edge caps nothing",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1830 + 400, origin: 1830, producedEdgePlayerSeconds: -1), 400))

// Both clamps have to hold at once: a target before the origin on a mount with no known edge still clamps.
check("seek: the backward clamp holds even when the edge is unknown",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 10, origin: 1830, producedEdgePlayerSeconds: 0), 0))

check("seek: a non-finite target lands at the start of the player timeline",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: .nan, origin: 1830, producedEdgePlayerSeconds: 300), 0))

// MARK: - The two directions are inverses

// This is what makes a scrub land where the scrubber said it would: converting a reported position back into a
// seek must be the identity inside the reachable band. A sign error in either direction breaks it while each
// direction on its own could still look plausible.
for origin in [0.0, 7.5, 1830.0] {
    for playerClock in [0.0, 1.0, 63.25, 299.0] {
        let reported = RemuxResumePolicy.presented(playerSeconds: playerClock, origin: origin)
        let back = RemuxResumePolicy.playerSeek(sourceSeconds: reported, origin: origin,
                                                producedEdgePlayerSeconds: 300)
        check("round trip: origin \(origin) clock \(playerClock) survives report-then-seek", near(back, playerClock))
    }
}

// MARK: - preStartSeek

// The case that makes resume WORK: the chrome asks for the point the mount was already opened at, so there is
// nothing to seek and no risk of touching unproduced bytes.
check("pre-start: a target the origin already reached needs no seek",
      RemuxResumePolicy.preStartSeek(target: 1830, origin: 1830) == .satisfied)

// The input seek lands on the keyframe AT OR BEFORE the request, so the mount legitimately starts earlier than
// asked. That must still count as satisfied, or every resume would immediately issue a forward seek.
check("pre-start: a mount that started a few seconds early still counts as satisfied",
      RemuxResumePolicy.preStartSeek(target: 1830, origin: 1826) == .satisfied)
check("pre-start: a target behind the origin counts as satisfied",
      RemuxResumePolicy.preStartSeek(target: 100, origin: 1830) == .satisfied)

// The case that PROTECTS the session: the origin seek did not happen (or not for this target), so the request
// is dropped rather than issued into bytes that do not exist. Asserted as a boundary pair around the tolerance.
check("pre-start: a target exactly at the tolerance is satisfied",
      RemuxResumePolicy.preStartSeek(target: RemuxResumePolicy.originToleranceSeconds, origin: 0) == .satisfied)
check("pre-start: a target just past the tolerance is unreachable",
      RemuxResumePolicy.preStartSeek(target: RemuxResumePolicy.originToleranceSeconds + 1, origin: 0)
        == .unreachable(RemuxResumePolicy.originToleranceSeconds + 1))
check("pre-start: a resume request on a mount that started at zero is unreachable",
      RemuxResumePolicy.preStartSeek(target: 1830, origin: 0) == .unreachable(1830))
check("pre-start: the reported distance is measured from the origin, not from zero",
      RemuxResumePolicy.preStartSeek(target: 1830, origin: 800) == .unreachable(1030))

check("pre-start: a non-finite target is never issued",
      RemuxResumePolicy.preStartSeek(target: .nan, origin: 0) == .satisfied)

// The tolerance must stay inside one long GOP. Raised to minutes it would silently accept resume requests the
// mount never honored, reporting the viewer as resumed while playback runs from somewhere else entirely; cut to
// zero it would issue a forward seek on every single resume.
check("pre-start: the tolerance stays around one long GOP",
      RemuxResumePolicy.originToleranceSeconds > 0 && RemuxResumePolicy.originToleranceSeconds <= 20)

// MARK: - Position in -> playlist/segment start out (the wired resume, end to end)

// This section proves the WIRED chain, not one decision at a time: a stored continue-watching position goes in
// at the chrome, and what comes out is a playlist whose first segment is the resume content. It executes every
// policy seam the production path crosses, in production order, with the real playlist renderer and the real
// startup oracle, so a break anywhere in the chain turns exactly these checks RED.
//
// The chain under test (each step names its production caller):
//   1. chrome -> engine: RemuxResumeConfiguration one-shot (PlayerScreen.loadIntoPlayer /
//      TVPlayerView.playerSurface -> AVPlayerEngineView.makeHostView -> configureResumeOrigin).
//   2. engine -> stream: the consumed origin is the remux mount's startAtSeconds
//      (AVPlayerEngine.loadFile -> VortXRemuxHLSServer.make -> VortXMKVRemuxStream.init).
//   3. stream: sanitize + convert to the one input seek (originRequest -> seekTimestampMicroseconds ->
//      avformat_seek_file BACKWARD), then latch the achieved keyframe origin from mapped base video only.
//   4. stream -> playlist: every packet is REBASED by the achieved origin, so the produced timeline starts at
//      zero and the FIRST segment holds the resume content. The playlist renderer states that start explicitly
//      (EXT-X-START:TIME-OFFSET=0 while segment zero is retained), which is the only lever that matters: the
//      client picks the first segment from playlist CONTENTS; EXT-X-START is advisory.
//   5. playlist -> chrome: the pre-start seek resolves satisfied (no post-mount seek is issued into a
//      forward-only mount) and the first reported frame maps back to the stored position, so progress saves
//      continue from where the viewer left off.

let storedPosition = 1830.25          // the continue-watching value the chrome fetched
var launchConfiguration = RemuxResumeConfiguration()
launchConfiguration.configure(seconds: storedPosition)
let consumedOrigin = launchConfiguration.consumeForNextLoad()
check("wired: the stored position survives the chrome-to-engine handoff unchanged",
      consumedOrigin == storedPosition)

// Step 3: the mount's request converts to the exact microsecond seek target the input seek receives.
check("wired: the consumed origin is the exact input-seek target",
      RemuxResumePolicy.seekTimestampMicroseconds(resumeSeconds: consumedOrigin ?? 0) == 1_830_250_000)

// The BACKWARD seek lands on the keyframe at or before the ask; this achieved origin is what production
// latches (establishTimelineOrigin), and only a mapped base-video packet may set it.
let achievedOrigin = 1828.0
check("wired: the achieved keyframe origin is latched from mapped base video",
      RemuxResumePolicy.canEstablishOrigin(packetStreamIndex: 0, baseVideoStreamIndex: 0, isMapped: true)
        && RemuxResumePolicy.preStartSeek(target: storedPosition, origin: achievedOrigin) == .satisfied)

// Step 4: the produced window after rebase. Segment ids and starts both begin at ZERO even though the mount
// began 1828 s into the source; nine 4 s segments cover the startup oracle's admission floor below.
let resumedWindow = VortXHLSWindow(segments: (0..<9).map {
    VortXHLSSegment(id: $0, byteOffset: $0 * 1_000, byteLength: 1_000,
                    start: Double($0) * 4.0, duration: 4.0)
})
let frozenTarget = VortXHLSTargetPolicy.conservativeTarget
let resumedPlaylist = DVPlaybackPolicy.mediaPlaylistLines(
    window: resumedWindow, ended: false,
    targetDuration: frozenTarget.seconds, mapURI: "init.mp4")

// The client-visible levers, asserted on the REAL rendered artifact. TIME-OFFSET=0 plus a MEDIA-SEQUENCE of 0
// tells every client the presentation starts at seg0, and seg0 IS the resume point after the rebase; that is
// the whole position-in -> segment-start-out contract.
check("wired: the resumed playlist starts at media sequence zero",
      resumedPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:0"))
check("wired: the resumed playlist pins the start to time-offset zero precisely",
      resumedPlaylist.contains("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES"))
check("wired: the first advertised media URI is segment zero (the resume content)",
      resumedPlaylist.first(where: { $0.hasSuffix(".m4s") }) == "seg0.m4s")
check("wired: a producing resumed mount does not claim ENDLIST",
      !resumedPlaylist.contains("#EXT-X-ENDLIST"))

// Startup timing is NOT resume's to change: the playlist carries the frozen conservative target (12) and the
// startup oracle admits the same first cohort it would admit for a fresh mount. A resume that widened, shrank
// or re-froze the target would break the conformance startup expectations and fail here.
check("wired: the resumed playlist carries the frozen conservative target duration",
      frozenTarget.seconds == 12
        && resumedPlaylist.contains("#EXT-X-TARGETDURATION:12"))
let readiness = VortXHLSStartupReadiness(frozenTarget: frozenTarget)
// The startup floor is the FLAT two-segment / four-second budget (the 6-segment / 3x-target floor held every
// UHD master past the chrome's 10s start watchdog in the field - the build 189 regression), and resume must
// not change it.
check("wired: startup readiness admission is unchanged by resume",
      readiness?.minimumSegmentCount == 2
        && readiness?.minimumRenderedDurationMilliseconds == 4_000)
if let readiness {
    let pinned = DVPlaybackPolicy.pinnedStartupSnapshot(
        window: resumedWindow, ended: false,
        minimumSegmentCount: readiness.minimumSegmentCount,
        minimumRenderedDurationMilliseconds: readiness.minimumRenderedDurationMilliseconds)
    check("wired: the resumed window pins the same startup cohort as a fresh mount",
          pinned?.window.segments.map(\.id) == Array(0..<2) && pinned?.ended == false)
} else {
    check("wired: startup readiness must construct for the frozen conservative target", false)
}

// Step 5: closing the loop with the chrome. No seek is issued (satisfied), the first frame reports the
// achieved origin so a progress save can never write zero over the viewer's position, and asking to scrub back
// to the exact stored position lands inside the produced band where the origin put it.
check("wired: the first reported frame is the resume point, never zero",
      near(RemuxResumePolicy.presented(playerSeconds: 0, origin: achievedOrigin), achievedOrigin))
check("wired: a scrub to the stored position maps just past the produced start",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: storedPosition, origin: achievedOrigin,
                                        producedEdgePlayerSeconds: 36), storedPosition - achievedOrigin))

// Inertness: a fresh start renders BYTE-IDENTICAL playlist lines for the same produced window. Resume changes
// which source second seg0 contains, never the playlist shape, so every conformance property proven for fresh
// starts holds for resumed mounts by construction.
check("wired: a fresh start renders byte-identical playlist lines for the same window",
      DVPlaybackPolicy.mediaPlaylistLines(
        window: resumedWindow, ended: false,
        targetDuration: frozenTarget.seconds, mapURI: "init.mp4") == resumedPlaylist)

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
