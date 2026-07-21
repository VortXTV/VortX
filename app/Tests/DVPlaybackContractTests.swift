// Executable harness for the two Dolby Vision playback fixes.
//
//   xcrun swiftc -o /tmp/dv-playback-contract-test \
//     app/Sources/Player/DVPlaybackPolicy.swift \
//     app/Tests/DVPlaybackContractTests.swift && /tmp/dv-playback-contract-test
//
// This suite CALLS the production decisions. An earlier version asserted on source text instead, because the code
// using these decisions lives in files that pull in AVFoundation and UIKit. That version was proven inadequate: a
// mutant that preserved every asserted string and appended `false` to the guard condition passed the whole suite
// while the guard could never fire. Substring assertions prove a line exists, not that it runs. The decisions now
// live in a dependency-free file so the real functions can be executed here.
//
// The bar is mutation survival, not a pass count: every assertion below must turn RED when its property is broken,
// including SEMANTIC breaks that leave the source text intact.

import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

typealias Req = DVPlaybackPolicy.DisplayRequest

// Compiling several files together means only a `main.swift` may carry top-level expressions, so the run body is a
// function invoked from `@main`, matching the other standalone suites in this directory.
@main
enum DVPlaybackContractTests {
    static func main() { run() }
}

func run() {

// MARK: - DV start position (the ~14s start)

let header = DVPlaybackPolicy.mediaPlaylistHeader(targetDuration: 5, mapURI: "init.mp4")

check("start: the header states an explicit start point",
      header.contains { $0.hasPrefix("#EXT-X-START:") })
check("start: the offset is exactly zero",
      header.contains { $0.contains("TIME-OFFSET=0") && !$0.contains("TIME-OFFSET=0.") })
check("start: PRECISE=YES, so the client does not round back to a preceding segment",
      header.contains { $0.hasPrefix("#EXT-X-START:") && $0.contains("PRECISE=YES") })
// A negative offset is the live-edge behaviour being removed. It would still emit the tag, so the VALUE is pinned
// rather than the tag's presence.
check("start: no negative TIME-OFFSET (that is the live-edge behaviour we are removing)",
      !header.contains { $0.contains("TIME-OFFSET=-") })
// Asserted with a value DIFFERENT from the shipping 5. A mutation battery caught the earlier version: it passed 5
// and asserted 5, so replacing the interpolation with a hardcoded 5 was invisible. A fixture that happens to equal
// the value under test cannot detect that the value is ignored.
check("start: the target duration passed in is the one emitted",
      DVPlaybackPolicy.mediaPlaylistHeader(targetDuration: 7, mapURI: "i.mp4")
        .contains("#EXT-X-TARGETDURATION:7"))
check("start: a second, different target duration is also honoured",
      DVPlaybackPolicy.mediaPlaylistHeader(targetDuration: 11, mapURI: "i.mp4")
        .contains("#EXT-X-TARGETDURATION:11"))
check("start: the map URI is carried through",
      header.contains(#"#EXT-X-MAP:URI="init.mp4""#))
// The start tag must precede the segment list, which begins after the header. Emitting it after the segments would
// leave a client applying the live-edge rule before it ever reads the tag.
check("start: the start tag comes before the playlist type and map lines",
      {
          guard let s = header.firstIndex(where: { $0.hasPrefix("#EXT-X-START:") }),
                let m = header.firstIndex(where: { $0.hasPrefix("#EXT-X-MAP:") }) else { return false }
          return s < m
      }())

// MARK: - Display switch de-duplication (the flicker)

let dv60 = Req(range: "dolbyVision", rate: 60, width: 3840, height: 2160)

// The property that matters: an identical repeat is redundant, so the caller skips the assignment.
check("flicker: an identical repeat request is redundant",
      DVPlaybackPolicy.isRedundantDisplayRequest(last: dv60, next: dv60))
// The property that keeps it SAFE: nothing that differs may ever be skipped, or a needed switch is lost.
check("flicker: a different rate is NOT redundant",
      !DVPlaybackPolicy.isRedundantDisplayRequest(
        last: dv60, next: Req(range: "dolbyVision", rate: 23.976, width: 3840, height: 2160)))
check("flicker: a different range is NOT redundant",
      !DVPlaybackPolicy.isRedundantDisplayRequest(
        last: dv60, next: Req(range: "hdr10", rate: 60, width: 3840, height: 2160)))
check("flicker: a different width is NOT redundant",
      !DVPlaybackPolicy.isRedundantDisplayRequest(
        last: dv60, next: Req(range: "dolbyVision", rate: 60, width: 1920, height: 2160)))
check("flicker: a different height is NOT redundant",
      !DVPlaybackPolicy.isRedundantDisplayRequest(
        last: dv60, next: Req(range: "dolbyVision", rate: 60, width: 3840, height: 1080)))
// After a reset the caller clears its memory, and asking for nothing can never make the next ask redundant.
check("flicker: with no remembered request, nothing is redundant",
      !DVPlaybackPolicy.isRedundantDisplayRequest(last: nil, next: dv60))

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
