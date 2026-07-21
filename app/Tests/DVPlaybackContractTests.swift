// Source-contract harness for the two Dolby Vision playback fixes. Both live in files with heavy dependencies
// (Network, the remux stream, RemoteConfig, DiagnosticsLog), so compiling them standalone would need app-wide
// stubs for no added confidence. This reads the production sources as TEXT and asserts the properties the fixes
// exist to guarantee, which is the same approach used for the identity caller gate.
//
//   xcrun swiftc -o /tmp/dv-playback-contract-test \
//     app/Tests/DVPlaybackContractTests.swift && /tmp/dv-playback-contract-test
//
// The bar for this file is mutation survival, not a pass count: each assertion below has been verified to turn RED
// when its fix is reverted. An assertion that cannot fail is decoration, and two of the tests added earlier in this
// engagement passed for the wrong reason, so the check is: delete the fix, watch this go red, restore.

import Foundation

let repoRoot: String = {
    // Walk up from this file to the directory containing `app/`, so the suite runs from anywhere.
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("app").path) { return dir.path }
        dir = dir.deletingLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
}()

func source(_ relative: String) -> String {
    let path = repoRoot + "/" + relative
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("FAIL  could not read \(relative) (looked in \(repoRoot))")
        exit(1)
    }
    return text
}

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

// Comments are stripped before asserting. Every property below was previously "guaranteed" by a comment while the
// code did something else, so a doc line describing the fix must never be able to satisfy the test for it.
func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("//") ? "" : String(line)
        }
        .joined(separator: "\n")
}

// MARK: - DV start position

let hlsServer = codeOnly(source("app/Sources/Player/VortXRemuxHLSServer.swift"))

// The playlist carries no EXT-X-ENDLIST until the remux finishes, so a client choosing a start point applies the
// live-edge rule and begins about three target durations from the end. TARGETDURATION is 5, hence the ~15s start
// reported from the field. EXT-X-START states the start point explicitly instead.
check("DV start: the media playlist emits EXT-X-START",
      hlsServer.contains("#EXT-X-START:"))
check("DV start: the offset is zero, not a live-edge relative value",
      hlsServer.contains("TIME-OFFSET=0"))
check("DV start: PRECISE=YES, so the client does not round back to a preceding segment",
      hlsServer.range(of: #"#EXT-X-START:TIME-OFFSET=0,\s*PRECISE=YES"#, options: .regularExpression) != nil)
// A negative offset would reintroduce the defect while still emitting the tag, so the shape is pinned rather
// than merely the tag's presence.
check("DV start: no negative TIME-OFFSET anywhere (that is the live-edge behaviour we are removing)",
      !hlsServer.contains("TIME-OFFSET=-"))

// MARK: - Display switch idempotency

let hdr = codeOnly(source("app/Sources/Player/HDRDisplayMode.swift"))

// Assigning preferredDisplayCriteria makes tvOS renegotiate the HDMI link, and a renegotiation is a visible flick.
// Several paths can request the SAME mode during one start, so without a guard a single start renegotiates
// repeatedly for no change. Field reports described four to five flickers.
check("flicker: a last-requested mode is remembered",
      hdr.contains("lastRequested"))
check("flicker: an identical request is compared BEFORE the criteria assignment",
      {
          guard let guardIdx = hdr.range(of: "if let last = lastRequested")?.lowerBound,
                let assignIdx = hdr.range(of: "manager.preferredDisplayCriteria = criteria")?.lowerBound
          else { return false }
          return guardIdx < assignIdx
      }())
check("flicker: the comparison covers range, rate AND dimensions (not just range)",
      hdr.contains("last.range == range") && hdr.contains("last.rate == rate")
      && hdr.contains("last.width == width") && hdr.contains("last.height == height"))
check("flicker: reset forgets the remembered mode, so the next request re-asserts",
      hdr.contains("lastRequested = nil"))
check("flicker: the remembered mode is recorded after a real assignment",
      hdr.range(of: #"manager\.preferredDisplayCriteria = criteria\s*\n\s*lastRequested = \("#,
                options: .regularExpression) != nil)

// MARK: - Result

print("")
if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("\(failures) FAILED")
    exit(1)
}
