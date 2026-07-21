// Executable harness for the remux resume (timeline origin) decisions.
//
//   xcrun swiftc -o /tmp/remux-resume-policy-test \
//     app/Sources/Player/RemuxResumePolicy.swift \
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

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

/// Seconds are compared with a tolerance far tighter than a video frame, so a real arithmetic mistake fails
/// while binary floating point representation does not.
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@main
enum RemuxResumePolicyTests {
    static func main() { run() }
}

func run() {

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

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
