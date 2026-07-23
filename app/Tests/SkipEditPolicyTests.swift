// Executable harness for the skip-editor gate + submission-duration decisions, and the source-time mapping
// a captured skip time relies on.
//
//   xcrun swiftc -o /tmp/skip-edit-policy-test \
//     app/SourcesShared/SkipEditPolicy.swift \
//     app/Sources/Player/RemuxResumePolicy.swift \
//     app/Tests/SkipEditPolicyTests.swift && /tmp/skip-edit-policy-test
//
// This suite CALLS the production decisions. The visibility gate and the submission-duration fallback both
// live in `SkipEditPolicy` precisely so they can be exercised here rather than only inside PlayerScreen /
// TVPlayerView (which pull in SwiftUI + AVFoundation and could only be asserted on as source text).
//
// The property that matters: contribution is NEVER gated to one engine. The gate keys on CONTENT liveness,
// not on the player's reported duration/seekability, so a Dolby-Vision remux (which presents an
// indefinite/non-seekable HLS to AVPlayer) still shows the editor. The submission carries a runtime even in
// that INDEFINITE edge, mapped through the same origin `presented`/`playerSeek` use so captured times are
// source-relative.

import Foundation

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@main
enum SkipEditPolicyTests {
    @MainActor static func main() { run() }
}

@MainActor func run() {

// MARK: - canEdit: content liveness, never engine / player duration

// The load-bearing regression: a normal tt VOD shows the editor. The policy takes NO engine and NO duration
// argument, which is the whole point: the SAME true answer is returned for the libmpv lane and the
// AVPlayer/DV-remux lane, so contribution can never be gated to one engine.
check("canEdit: tt VOD is editable (engine-agnostic: mpv AND avplayer/DV lane)",
      SkipEditPolicy.canEdit(isLiveContent: false, contentId: "tt1234567") == true)
check("canEdit: 8-digit tt VOD is editable",
      SkipEditPolicy.canEdit(isLiveContent: false, contentId: "tt12345678") == true)

// A live-TV / IPTV feed has no fixed episode timeline to submit a skip against: hidden, even with a tt id.
check("canEdit: live content is NOT editable",
      SkipEditPolicy.canEdit(isLiveContent: true, contentId: "tt1234567") == false)

// Non-IMDb ids have nothing to key the worker on (imdb:S:E), so they are hidden regardless of liveness.
check("canEdit: kitsu id is not editable",
      SkipEditPolicy.canEdit(isLiveContent: false, contentId: "kitsu:44081:2") == false)
check("canEdit: tmdb id is not editable",
      SkipEditPolicy.canEdit(isLiveContent: false, contentId: "tmdb:1399") == false)
check("canEdit: empty id is not editable",
      SkipEditPolicy.canEdit(isLiveContent: false, contentId: "") == false)
check("canEdit: 6-digit tt is refused (below the 7-digit floor)",
      SkipEditPolicy.canEdit(isLiveContent: false, contentId: "tt123456") == false)

// MARK: - isSubmittableContentId shape

check("id: tt with 7 digits is submittable", SkipEditPolicy.isSubmittableContentId("tt1234567"))
check("id: tt with 8 digits is submittable", SkipEditPolicy.isSubmittableContentId("tt12345678"))
check("id: tt with 9 digits is refused", !SkipEditPolicy.isSubmittableContentId("tt123456789"))
check("id: tt with a suffix is refused", !SkipEditPolicy.isSubmittableContentId("tt1234567:1:2"))

// MARK: - submissionDurationMs: finite duration authoritative; synthesized runtime fills the INDEFINITE edge

// A finite chrome duration is used directly (source seconds -> ms), and it WINS over any fallback.
check("dur: a finite player duration is used as ms",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: 1440.5, fallbackRuntimeSeconds: nil) == 1440500)
check("dur: a finite player duration wins over the fallback runtime",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: 1000, fallbackRuntimeSeconds: 2000) == 1000000)

// INDEFINITE edge: the engine emitted no finite duration (0), so the SYNTHESIZED meta runtime carries the
// submission instead of a nil duration_ms. This is the DV-remux-no-source-duration case.
check("dur: an indefinite (0) duration falls back to the synthesized runtime",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: 0, fallbackRuntimeSeconds: 1320) == 1320000)
check("dur: a NaN player duration falls back to the synthesized runtime",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: .nan, fallbackRuntimeSeconds: 1320) == 1320000)
check("dur: an infinite player duration falls back to the synthesized runtime",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: .infinity, fallbackRuntimeSeconds: 1320) == 1320000)
check("dur: a negative player duration falls back to the synthesized runtime",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: -5, fallbackRuntimeSeconds: 1320) == 1320000)

// Neither known: nil, and the worker bounds the span itself.
check("dur: no duration and no fallback yields nil",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: 0, fallbackRuntimeSeconds: nil) == nil)
check("dur: no duration and a non-positive fallback yields nil",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: 0, fallbackRuntimeSeconds: 0) == nil)
check("dur: no duration and a non-finite fallback yields nil",
      SkipEditPolicy.submissionDurationMs(playerDurationSeconds: 0, fallbackRuntimeSeconds: .nan) == nil)

// MARK: - captured skip time is SOURCE-relative on a resumed remux mount

// A skip time captured on the AVPlayer/DV lane comes from the chrome's currentTime, which the engine reports
// as `presented(playerSeconds:origin:)`. So a mount resumed at source 1800s, sitting 42s into its produced
// stream, captures 1842s of SOURCE time, not 42s: exactly what the worker must store against imdb:S:E.
check("map: a captured time on a resumed mount is source-relative (origin + player)",
      near(RemuxResumePolicy.presented(playerSeconds: 42, origin: 1800), 1842))
// And a skip target expressed in SOURCE seconds seeks back to the right PLAYER second on that mount.
check("map: a source skip target maps back to player seconds (source - origin)",
      near(RemuxResumePolicy.playerSeek(sourceSeconds: 1842, origin: 1800, producedEdgePlayerSeconds: 0), 42))
// The two are exact inverses inside the reachable band, so a scrub-then-submit lands where the user saw it.
check("map: presented and playerSeek round-trip inside the produced band",
      near(RemuxResumePolicy.playerSeek(
            sourceSeconds: RemuxResumePolicy.presented(playerSeconds: 300, origin: 1800),
            origin: 1800, producedEdgePlayerSeconds: 0), 300))

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }

}
