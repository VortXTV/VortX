// Standalone contract for the DV remux source-read retry backoff.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/remux-read-retry \
//     app/Sources/Player/VortXRemuxReadRetryPolicy.swift \
//     app/Tests/RemuxReadRetryPolicyTests.swift && /tmp/remux-read-retry

import Foundation

@main
struct RemuxReadRetryPolicyTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { print("FAIL  \(message)"); exit(1) }
            passed += 1
            print("PASS  \(message)")
        }

        let steps = (1...VortXRemuxReadRetryPolicy.maximumReadRetries)
            .map(VortXRemuxReadRetryPolicy.backoffSeconds)
        check(steps == [0.5, 1.0, 1.5, 2.0], "retry steps are the bounded monotonic schedule")
        check(VortXRemuxReadRetryPolicy.totalBackoffSeconds == 5.0, "all retry waits total five seconds")
        check(
            VortXRemuxReadRetryPolicy.backoffSeconds(readRetries: 0) == 0.5
                && VortXRemuxReadRetryPolicy.backoffSeconds(readRetries: 99) == 2.0,
            "stale or out-of-range retry indices are safely clamped"
        )

        let cancelledAtStart = ProcessInfo.processInfo.systemUptime
        let completed = VortXRemuxReadRetryPolicy.sleepAbortableSlices(seconds: 1, isCancelled: { true })
        check(!completed, "already-cancelled retry never waits")
        check(ProcessInfo.processInfo.systemUptime - cancelledAtStart < 0.25, "already-cancelled retry returns promptly")

        var polls = 0
        let cancellationDuringWaitBegan = ProcessInfo.processInfo.systemUptime
        let interrupted = VortXRemuxReadRetryPolicy.sleepAbortableSlices(seconds: 1, isCancelled: {
            polls += 1
            return polls >= 2
        })
        let cancellationDuringWaitElapsed = ProcessInfo.processInfo.systemUptime - cancellationDuringWaitBegan
        check(!interrupted && polls == 2, "mid-wait cancellation stops at the next slice")
        check(
            cancellationDuringWaitElapsed < 0.30,
            "mid-wait cancellation is responsive (\(String(format: "%.3f", cancellationDuringWaitElapsed))s)"
        )

        // The retry sleep belongs only after sourceError classification. EOF, cancellation and AVERROR_EXIT
        // remain separate terminal dispositions in the existing classifier.
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Player/VortXMKVRemuxStream.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        check(source.contains("case .sourceError:") && source.contains("VortXRemuxReadRetryPolicy.sleepAbortableSlices"), "only source errors enter retry backoff")
        check(source.contains("case .unexpectedInterrupt:") && source.contains("source read interrupted unexpectedly"), "unexpected AVERROR_EXIT remains terminal")
        check(source.contains("return VortXRemuxInputProbeIsCancelled(probe) ? 1 : 0"), "AVIO interrupt remains hard-cancel-only")
        check(source.contains("\"reconnect_max_retries\", \"1\"")
                && source.contains("\"reconnect_delay_total_max\", \"5\""),
              "the bundled HTTP transport bounds retries and aggregate reconnect delay in the live AVIO context")

        print("ALL TESTS PASSED (\(passed) checks)")
    }
}
