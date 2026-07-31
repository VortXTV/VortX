// Source contract for behavior-neutral deep-resume telemetry.
//
// This guard deliberately does not link FFmpeg. It checks the production source so later edits cannot turn the
// diagnostic snapshots into another transport operation, expose the source URL, or silently add a third seek.
//
// RUN: swift app/Tests/RemuxResumeTelemetryContractTests.swift

import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func occurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var cursor = text.startIndex
    while let range = text[cursor...].range(of: needle) {
        count += 1
        cursor = range.upperBound
    }
    return count
}

private func section(_ source: String, from start: String, to end: String) -> String? {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func ordered(_ needles: [String], in source: String) -> Bool {
    var cursor = source.startIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: cursor..<source.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

private func collapsingWhitespace(_ source: String) -> String {
    source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let streamURL = testsDirectory.deletingLastPathComponent()
    .appendingPathComponent("Sources/Player/VortXMKVRemuxStream.swift")
guard let source = try? String(contentsOf: streamURL, encoding: .utf8) else {
    print("FAIL: cannot read \(streamURL.path)")
    exit(1)
}

let snapshot = section(
    source,
    from: "private static func resumeSeekSnapshot(",
    to: "/// Remux-thread-only resume state.")
let resume = section(
    source,
    from: "// RESUME ORIGIN: seek the INPUT once",
    to: "// Profile 5 / 8.x are single-layer")

check(snapshot != nil, "production snapshot helper remains present")
check(resume != nil, "production resume seek block remains present")

if let snapshot {
    check(snapshot.contains("avformat_index_get_entries_count("),
          "snapshot reads the already-loaded index count")
    check(snapshot.contains("avformat_index_get_entry("),
          "snapshot reads first and last loaded index entries")
    check(snapshot.contains("avformat_index_get_entry_from_timestamp("),
          "snapshot reads nearest backward and forward keyframe entries")
    check(snapshot.contains(".pointee.seekable") && snapshot.contains(".pointee.pos"),
          "snapshot records AVIO seekability and current position")
    check(snapshot.contains("formatContextFlags") && snapshot.contains(".pointee.ctx_flags"),
          "snapshot distinguishes AVFormatContext flags from state flags")
    check(snapshot.contains(".pointee.time_base") && snapshot.contains("targetTicks"),
          "snapshot records the base-video time base and target in stream ticks")
    check(!snapshot.contains("avio_size(") && !snapshot.contains("avio_seek(")
            && !snapshot.contains("av_read_frame("),
          "snapshot performs no size query, seek, or read")
    check(!snapshot.contains("input") && !snapshot.contains("headers")
            && !snapshot.localizedCaseInsensitiveContains("url"),
          "snapshot cannot log the source URL or request headers")
}

if let resume {
    let normalizedResume = collapsingWhitespace(resume)
    let exactSnapshotCall = "Self.resumeSeekSnapshot( context: inCtx, "
        + "baseVideoStreamIndex: baseVideoIn, targetUsec: target)"
    check(resume.contains("let resumeTelemetryEnabled = VXProbe.enabled"),
          "resume freezes the probe gate before collecting telemetry")
    check(occurrences(of: "Self.resumeSeekSnapshot(", in: resume) == 4
            && occurrences(of: "? Self.resumeSeekSnapshot(", in: resume) == 4,
          "all four snapshots are conditional on the frozen VXProbe gate")
    check(occurrences(of: exactSnapshotCall, in: normalizedResume) == 4,
          "every snapshot receives the live input context, base-video stream, and exact seek target")
    check(occurrences(of: "avformat_seek_file(", in: resume) == 1,
          "resume still has exactly one primary range seek")
    check(occurrences(of: "av_seek_frame(", in: resume) == 1,
          "resume still has exactly one keyframe fallback seek")
    check(ordered([
        "phase=range-before",
        "avformat_seek_file(",
        "phase=range-after",
        "avformat_flush(inCtx)",
        "phase=keyframe-before",
        "av_seek_frame(",
        "phase=keyframe-after",
        "RemuxResumePolicy.inputSeekOutcome(",
    ], in: resume), "telemetry brackets both existing seeks without changing outcome arbitration")
    check(resume.contains("indexDelta=") && resume.contains("coverageChanged="),
          "post-seek telemetry reports index coverage changes")
    let forbiddenRawLogFields = [
        "\\(input)", "\\(self.input)", "\\(headers)", "\\(self.headers)",
        "sourceURL", ".absoluteString", "url=", "headers=", "header=",
        "token=", "authorization=", "bearer ",
    ]
    check(!forbiddenRawLogFields.contains {
        resume.localizedCaseInsensitiveContains($0)
    }, "the full resume block cannot log raw input, URL, header, authorization, or token data")
}

if failures > 0 {
    print("\n\(failures) remux resume telemetry contract test(s) failed")
    exit(1)
}
print("\nAll remux resume telemetry source contracts passed")
