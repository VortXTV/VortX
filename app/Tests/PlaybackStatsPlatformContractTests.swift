// Standalone executable source contract for the dropped-frame Playback info row.
//
// Run with:
//   xcrun swiftc -parse-as-library -swift-version 5 \
//     -strict-concurrency=complete -warnings-as-errors \
//     app/Tests/PlaybackStatsPlatformContractTests.swift \
//     -o /tmp/playback-stats-platform-contract \
//     && /tmp/playback-stats-platform-contract

import Foundation

@MainActor private var failures = 0

@MainActor
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func section(in source: String, from start: String, to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func compactSwift(_ source: String) -> String {
    source.components(separatedBy: "\n").compactMap { rawLine -> String? in
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return nil }
        return rawLine
    }
    .joined()
    .filter { !$0.isWhitespace }
}

private func hasPlatformSafeDroppedRow(_ source: String) -> Bool {
    guard let droppedRow = section(
        in: source,
        from: "let dropped = getInt(\"frame-drop-count\")",
        to: "// --- Audio"
    ) else {
        return false
    }
    let expected = #"""
        let dropped = getInt("frame-drop-count")
        #if os(tvOS)
        if let rate = lastReceiptFrameDropsPerMinute {
            rows.append(("Dropped", "\(dropped) total, \(String(format: "%.0f", rate))/min"))
        } else {
            rows.append(("Dropped", "\(dropped) total"))
        }
        #else
        rows.append(("Dropped", "\(dropped) total"))
        #endif
    """#
    return compactSwift(droppedRow) == compactSwift(expected)
}

@main
private enum PlaybackStatsPlatformContractTests {
    @MainActor
    static func main() {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerPath = appRoot
            .appendingPathComponent("Sources/Player/MPVMetalViewController.swift")
        guard let controller = try? String(contentsOf: controllerPath, encoding: .utf8) else {
            fputs("FAIL  MPVMetalViewController.swift is readable\n", stderr)
            exit(1)
        }

        check("tvOS-only dropped-frame rate is platform-guarded in playbackStats",
              hasPlatformSafeDroppedRow(controller))

        let playbackStatsStart = controller.range(of: "func playbackStats()")?.lowerBound
        let mutationRange = playbackStatsStart.map { $0..<controller.endIndex }
        let unguardedMutant = controller.replacingOccurrences(
            of: "        #if os(tvOS)\n        if let rate = lastReceiptFrameDropsPerMinute {",
            with: "        if let rate = lastReceiptFrameDropsPerMinute {",
            options: [],
            range: mutationRange
        )
        check("contract rejects an unguarded iOS reference",
              !hasPlatformSafeDroppedRow(unguardedMutant))

        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}
