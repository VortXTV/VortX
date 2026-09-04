// Standalone contract for true-DV mid-stream read recovery.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/vortx-remux-read-failure-policy \
//     app/Sources/Player/VortXRemuxReadFailurePolicy.swift \
//     app/Tests/VortXRemuxReadFailurePolicyTests.swift && /tmp/vortx-remux-read-failure-policy

import Foundation

@main
struct VortXRemuxReadFailurePolicyTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                print("FAIL  \(message)")
                exit(1)
            }
            passed += 1
            print("PASS  \(message)")
        }

        check(
            VortXRemuxReadFailurePolicy.classify(
                readResult: -1414092869,
                isCancelled: true
            ) == .cancelled,
            "hard cancellation owns AVERROR_EXIT"
        )
        check(
            VortXRemuxReadFailurePolicy.classify(
                readResult: -1414092869,
                isCancelled: false
            ) == .unexpectedInterrupt,
            "AVERROR_EXIT without cancellation is terminal, never a source retry"
        )
        check(
            VortXRemuxReadFailurePolicy.classify(
                readResult: -60,
                isCancelled: false
            ) == .sourceError,
            "rw_timeout remains a source error after FFmpeg's internal reconnect handling"
        )
        check(
            VortXRemuxReadFailurePolicy.classify(
                readResult: -5,
                isCancelled: false
            ) == .sourceError,
            "ordinary I/O failure remains eligible for the bounded source-error path"
        )
        check(
            VortXRemuxReadFailurePolicy.classify(
                readResult: -541478725,
                isCancelled: false
            ) == .endOfFile,
            "genuine EOF stays distinct from cancellation and source failure"
        )

        // Production wiring contract. This catches the rejected sleep-only mutant and any later attempt to
        // make a liveness watchdog return AVERROR_EXIT again. FFmpeg must own timeout/reconnect; VortX's
        // interrupt callback is reserved exclusively for hard cancellation.
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Player/VortXMKVRemuxStream.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        check(
            source.contains("return VortXRemuxInputProbeIsCancelled(probe) ? 1 : 0"),
            "production interrupt callback is hard-cancel-only through the atomic probe"
        )
        check(
            !source.contains("softInterrupt") && !source.contains("VortXRemuxInputLivenessWatchdog"),
            "production has no soft AVIO interrupt path"
        )
        check(
            source.contains("VortXRemuxReadFailurePolicy.classify"),
            "production read loop uses the tested failure classifier"
        )
        check(
            source.contains("case .unexpectedInterrupt:")
                && source.contains("source read interrupted unexpectedly"),
            "unexpected AVERROR_EXIT fails once instead of hot-looping or sleeping"
        )
        check(
            source.contains("av_dict_set(&openOpts, \"rw_timeout\", \"10000000\", 0)")
                && source.contains("av_dict_set(&opts, \"reconnect\", \"1\", 0)")
                && source.contains("av_dict_set(&opts, \"reconnect_streamed\", \"1\", 0)")
                && source.contains("av_dict_set(&opts, \"reconnect_max_retries\", \"1\", 0)")
                && source.contains("av_dict_set(&opts, \"reconnect_delay_total_max\", \"5\", 0)"),
            "production keeps bounded FFmpeg timeout and aggregate HTTP reconnect wiring"
        )

        print("ALL TESTS PASSED (\(passed) checks)")
    }
}
