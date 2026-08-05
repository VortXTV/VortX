// Focused standalone regression harness for the trickplay black-frame size floor (task 3). It compiles the REAL
// `TrickplayFrameByteFloor` out of ScrubThumbnails.swift under the TRICKPLAY_BYTEFLOOR_TESTING seam, which drops
// the engine/RemoteConfig/Combine-dependent store and leaves the pure floor rule compilable in isolation:
//
// xcrun swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
//   -D TRICKPLAY_BYTEFLOOR_TESTING -parse-as-library \
//   app/SourcesShared/ScrubThumbnails.swift app/Tests/TrickplayFrameByteFloorTests.swift \
//   -o /tmp/trickplay-byte-floor-tests && /tmp/trickplay-byte-floor-tests
//
// Proves the fix on the non-AppKit (tvOS/iOS) path: a captured frame below the floor is dropped (kept=false) and
// a frame at or above the floor is kept, with no pixel sampler. Also pins the macOS keep rule (a large frame is
// kept even when the crude sampler reports black) and the exact floor constant so it cannot silently drift.

import Foundation

@main
private enum TrickplayFrameByteFloorTests {
    nonisolated(unsafe) private static var passed = 0

    static func main() {
        testFloorConstantIsExactlyEightThousand()
        testNonSamplerPathDropsBelowFloor()
        testNonSamplerPathKeepsAtOrAboveFloor()
        testNonSamplerPathDropsTypicalBlackTile()
        testMacOSKeepsLargeFrameEvenWhenSamplerReportsBlack()
        testMacOSDropsOnlyWhenBothSmallAndSamplerBlack()
        print("TrickplayFrameByteFloorTests: \(passed)/\(passed) passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(file):\(line): \(message)")
        }
        passed += 1
    }

    /// The floor is the single lever separating a real detailed frame (tens of KB) from a black or unrendered
    /// tile (~2-4 KB). Pin it so a future edit that changes the number has to change this test too.
    private static func testFloorConstantIsExactlyEightThousand() {
        expect(
            TrickplayFrameByteFloor.nonBlackByteFloor == 8000,
            "floor drifted from 8000 to \(TrickplayFrameByteFloor.nonBlackByteFloor)"
        )
    }

    /// The load-bearing tvOS/iOS fix: a sub-floor encoded frame is a black/unrendered tile and must be dropped.
    private static func testNonSamplerPathDropsBelowFloor() {
        let floor = TrickplayFrameByteFloor.nonBlackByteFloor
        expect(!TrickplayFrameByteFloor.keepBySize(byteCount: floor - 1),
               "a frame one byte under the floor must be dropped (kept=false)")
        expect(!TrickplayFrameByteFloor.keepBySize(byteCount: 0),
               "a zero-byte frame must be dropped")
        expect(!TrickplayFrameByteFloor.keepBySize(byteCount: 1),
               "a 1-byte frame must be dropped")
    }

    /// The complementary half: a real detailed frame at or above the floor is kept, no sampler needed.
    private static func testNonSamplerPathKeepsAtOrAboveFloor() {
        let floor = TrickplayFrameByteFloor.nonBlackByteFloor
        expect(TrickplayFrameByteFloor.keepBySize(byteCount: floor),
               "a frame exactly at the floor must be kept (kept=true)")
        expect(TrickplayFrameByteFloor.keepBySize(byteCount: floor + 1),
               "a frame one byte over the floor must be kept")
        expect(TrickplayFrameByteFloor.keepBySize(byteCount: 42_000),
               "a real tens-of-KB frame must be kept")
    }

    /// A representative 2.8 KB black tile, the exact size the fix description cites as slipping into the pool
    /// before this change, is dropped on the non-sampler path.
    private static func testNonSamplerPathDropsTypicalBlackTile() {
        expect(!TrickplayFrameByteFloor.keepBySize(byteCount: 2_800),
               "a typical ~2.8 KB black tile must be dropped on tvOS/iOS")
    }

    /// macOS rule: the size floor overrides a misfiring sampler, so a large frame the crude sampler wrongly
    /// calls black is still kept. This is the `bigEnoughToBeReal || !samplerBlack` semantics.
    private static func testMacOSKeepsLargeFrameEvenWhenSamplerReportsBlack() {
        let floor = TrickplayFrameByteFloor.nonBlackByteFloor
        expect(TrickplayFrameByteFloor.keep(byteCount: floor, samplerBlack: true),
               "a large frame the sampler flags black must still be kept")
        expect(TrickplayFrameByteFloor.keep(byteCount: 42_000, samplerBlack: true),
               "a real tens-of-KB frame is kept regardless of the sampler")
    }

    /// macOS rule: the only frame that drops is one both under the floor AND the sampler calls black; a small
    /// frame the sampler does not call black is kept.
    private static func testMacOSDropsOnlyWhenBothSmallAndSamplerBlack() {
        expect(!TrickplayFrameByteFloor.keep(byteCount: 2_800, samplerBlack: true),
               "a small frame the sampler calls black must be dropped")
        expect(TrickplayFrameByteFloor.keep(byteCount: 2_800, samplerBlack: false),
               "a small frame the sampler does not call black must be kept")
    }
}
