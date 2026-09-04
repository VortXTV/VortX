import Foundation
import Libmpv

// This is a real-libmpv executable repro, not a production controller test. It
// deliberately keeps keep-open=no so an accidental END_FILE leaves an
// unseekable idle player, exactly as it does in the regression.

private final class Checks {
    private(set) var failures = 0
    func require(_ condition: Bool, _ name: String, _ detail: String) {
        if condition { print("PASS \(name): \(detail)") }
        else { failures += 1; print("FAIL \(name): \(detail)") }
    }
}

private struct Events {
    var eof = false
    var naturalEOF = false
    var seeks = 0
    var restarts = 0
    var minimumForwardBytes: Int64?
}

private func option(_ h: OpaquePointer, _ name: String, _ value: String) -> Bool {
    let result = mpv_set_option_string(h, name, value)
    if result < 0 { print("FAIL option \(name)=\(value): \(result)") }
    return result >= 0
}

@discardableResult private func command(_ h: OpaquePointer, _ values: [String], reportFailure: Bool = true) -> Int32 {
    let storage = values.map { strdup($0) }
    defer { storage.forEach { free($0) } }
    var argv: [UnsafePointer<CChar>?] = storage.map { UnsafePointer<CChar>($0) }
    argv.append(nil)
    let result = mpv_command(h, &argv)
    if result < 0 && reportFailure { print("FAIL command \(values.joined(separator: " ")): \(result)") }
    return result
}

@discardableResult private func commandString(_ h: OpaquePointer, _ text: String, reportFailure: Bool = true) -> Int32 {
    let result = text.withCString { mpv_command_string(h, $0) }
    if result < 0 && reportFailure { print("FAIL command-string \(text): \(result)") }
    return result
}

private func flag(_ h: OpaquePointer, _ name: String) -> Bool? {
    var value: Int32 = 0
    return mpv_get_property(h, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
}

private func number(_ h: OpaquePointer, _ name: String) -> Double? {
    var value = 0.0
    return mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
}

private func integer(_ h: OpaquePointer, _ name: String) -> Int64? {
    var value: Int64 = 0
    return mpv_get_property(h, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
}

private func string(_ h: OpaquePointer, _ name: String) -> String? {
    guard let value = mpv_get_property_string(h, name) else { return nil }
    defer { mpv_free(value) }
    return String(cString: value)
}

private func cacheValue(_ h: OpaquePointer, _ key: String) -> mpv_node? {
    var node = mpv_node()
    defer { mpv_free_node_contents(&node) }
    guard mpv_get_property(h, "demuxer-cache-state", MPV_FORMAT_NODE, &node) >= 0,
          node.format == MPV_FORMAT_NODE_MAP,
          let list = node.u.list,
          let keys = list.pointee.keys,
          let values = list.pointee.values else { return nil }
    for index in 0..<Int(list.pointee.num) where keys[index].map({ String(cString: $0) }) == key {
        return values[index]
    }
    return nil
}

private func cacheEOF(_ h: OpaquePointer) -> Bool? {
    guard let value = cacheValue(h, "eof") else { return nil }
    if value.format == MPV_FORMAT_FLAG { return value.u.flag != 0 }
    if value.format == MPV_FORMAT_INT64 { return value.u.int64 != 0 }
    return nil
}

private func cacheInteger(_ h: OpaquePointer, _ key: String) -> Int64? {
    guard let value = cacheValue(h, key) else { return nil }
    if value.format == MPV_FORMAT_INT64 { return value.u.int64 }
    if value.format == MPV_FORMAT_DOUBLE { return Int64(value.u.double_) }
    return nil
}

private func poll(_ h: OpaquePointer, _ seconds: TimeInterval, events: inout Events) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let forwardBytes = cacheInteger(h, "fw-bytes") {
            events.minimumForwardBytes = min(events.minimumForwardBytes ?? forwardBytes, forwardBytes)
        }
        guard let event = mpv_wait_event(h, 0.10) else { continue }
        if event.pointee.event_id == MPV_EVENT_END_FILE {
            events.eof = true
            if let data = event.pointee.data {
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                events.naturalEOF = end.reason == MPV_END_FILE_REASON_EOF && end.error == 0
                print("END_FILE reason=\(end.reason) error=\(end.error)")
            }
        } else if event.pointee.event_id == MPV_EVENT_SEEK {
            events.seeks += 1
        } else if event.pointee.event_id == MPV_EVENT_PLAYBACK_RESTART {
            events.restarts += 1
        }
    }
}

private func waitUntil(_ h: OpaquePointer, _ timeout: TimeInterval, events: inout Events, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        poll(h, 0.10, events: &events)
    }
    return predicate()
}

private func newPlayer(disableSeekableCacheBeforeLoad: Bool = false) -> OpaquePointer? {
    guard let h = mpv_create() else { return nil }
    let options = [("config", "no"), ("load-scripts", "no"), ("resume-playback", "no"),
                   ("idle", "yes"), ("keep-open", "no"), ("cache", "yes"),
                   ("cache-secs", "3600"), ("demuxer-max-bytes", "256MiB"),
                   ("demuxer-max-back-bytes", "256MiB"), ("vo", "null"), ("ao", "null"), ("hwdec", "no")]
    guard options.allSatisfy({ option(h, $0.0, $0.1) }),
          (!disableSeekableCacheBeforeLoad || option(h, "demuxer-seekable-cache", "no")),
          mpv_initialize(h) >= 0 else { mpv_terminate_destroy(h); return nil }
    return h
}

private func loadAndBuffer(_ h: OpaquePointer, _ fixture: String, events: inout Events) -> Bool {
    guard command(h, ["loadfile", fixture, "replace"]) >= 0 else { return false }
    return waitUntil(h, 45, events: &events) { cacheEOF(h) == true && number(h, "duration") != nil }
}

private func parked(_ h: OpaquePointer, _ at: Double, events: inout Events) -> Bool {
    guard command(h, ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), at), "absolute+exact"]) >= 0,
          command(h, ["set", "pause", "yes"]) >= 0 else { return false }
    return waitUntil(h, 12, events: &events) { abs((number(h, "time-pos") ?? -999) - at) < 1.0 && flag(h, "pause") == true }
}

private struct ReanchorReceipt {
    let appliedNo: String?
    let restored: String?
    let forwardBytes: Int64?
    let settledForwardBytes: Int64?
    let lowLevelBefore: Int64?
    let lowLevelAfter: Int64?
}

private func atomicDropAndReanchor(_ h: OpaquePointer, at position: Double, events: inout Events) -> ReanchorReceipt? {
    guard position.isFinite, let wasPaused = flag(h, "pause") else { return nil }
    let target = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), position)
    let lowLevelBefore = cacheInteger(h, "debug-low-level-seeks")
    let seekCount = events.seeks
    let restartCount = events.restarts
    events.minimumForwardBytes = nil
    // `target` is a finite numeric string constructed here, not fixture/user input.
    guard commandString(h, "no-osd drop-buffers; no-osd seek \(target) absolute+exact") >= 0 else { return nil }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline && (events.seeks == seekCount || events.restarts == restartCount) && !events.eof {
        poll(h, 0.10, events: &events)
    }
    guard events.seeks > seekCount, events.restarts > restartCount, !events.eof,
          abs((number(h, "time-pos") ?? -999) - position) < 1.0,
          flag(h, "pause") == wasPaused else { return nil }
    poll(h, 0.5, events: &events)
    return .init(appliedNo: nil, restored: nil, forwardBytes: events.minimumForwardBytes,
                 settledForwardBytes: cacheInteger(h, "fw-bytes"),
                 lowLevelBefore: lowLevelBefore, lowLevelAfter: cacheInteger(h, "debug-low-level-seeks"))
}

private func reanchor(_ h: OpaquePointer, at position: Double, events: inout Events) -> ReanchorReceipt? {
    // Production's safe replacement for drop-buffers: force normal demux seeks to
    // refill from source, then restore the previous option only after settling.
    guard let wasPaused = flag(h, "pause"),
          command(h, ["set", "demuxer-seekable-cache", "no"]) >= 0 else { return nil }
    // The option setter is asynchronous relative to demux. Give it a bounded
    // event turn before sending the seek, then retain its readback in receipt.
    poll(h, 0.5, events: &events)
    let appliedNo = string(h, "options/demuxer-seekable-cache")
    let lowLevelBefore = cacheInteger(h, "debug-low-level-seeks")
    guard appliedNo == "no",
          command(h, ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), position), "absolute+exact"]) >= 0 else { return nil }
    events.minimumForwardBytes = nil
    let seekCount = events.seeks
    let restartCount = events.restarts
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline && (events.seeks == seekCount || events.restarts == restartCount) && !events.eof {
        poll(h, 0.10, events: &events)
    }
    guard events.seeks > seekCount, events.restarts > restartCount, !events.eof,
          abs((number(h, "time-pos") ?? -999) - position) < 1.0 else { return nil }
    let forwardBytes = events.minimumForwardBytes
    let lowLevelAfter = cacheInteger(h, "debug-low-level-seeks")
    guard command(h, ["set", "demuxer-seekable-cache", "auto"]) >= 0 else { return nil }
    poll(h, 0.1, events: &events)
    guard flag(h, "pause") == wasPaused else { return nil }
    return .init(appliedNo: appliedNo, restored: string(h, "options/demuxer-seekable-cache"), forwardBytes: forwardBytes, settledForwardBytes: cacheInteger(h, "fw-bytes"), lowLevelBefore: lowLevelBefore, lowLevelAfter: lowLevelAfter)
}

guard CommandLine.arguments.count == 2 else { print("usage: libmpv-cache-reanchor <fixture>"); exit(2) }
let fixture = CommandLine.arguments[1]
private let checks = Checks()

// 1. Guard the old control: only call drop-buffers after confirmed fully-buffered
// cache, then prove its unpause is terminal and future seeks fail.
if let h = newPlayer() {
    defer { mpv_terminate_destroy(h) }
    var events = Events()
    checks.require(loadAndBuffer(h, fixture, events: &events), "control fully buffers", "demuxer-cache-state.eof=\(String(describing: cacheEOF(h)))")
    checks.require(parked(h, 30, events: &events), "control parks paused", "time=\(String(describing: number(h, "time-pos")))")
    let dropped = command(h, ["drop-buffers"]) >= 0
    let unpaused = command(h, ["set", "pause", "no"]) >= 0
    poll(h, 5, events: &events)
    let lateSeek = command(h, ["seek", "10", "absolute+exact"], reportFailure: false)
    checks.require(dropped && unpaused && events.eof && events.naturalEOF && flag(h, "idle-active") == true && lateSeek < 0,
                   "old drop-buffers control becomes terminal", "eof=\(events.eof) natural=\(events.naturalEOF) idle=\(String(describing: flag(h, "idle-active"))) seek=\(lateSeek)")
} else { print("INFRA mpv initialization failed"); exit(2) }

// Positive control for the optional debug counter: disabling cache seeks before
// load must make an ordinary post-load exact seek traverse the demuxer.
if let h = newPlayer(disableSeekableCacheBeforeLoad: true) {
    defer { mpv_terminate_destroy(h) }
    var events = Events()
    guard loadAndBuffer(h, fixture, events: &events), parked(h, 30, events: &events) else { exit(2) }
    let before = cacheInteger(h, "debug-low-level-seeks")
    guard command(h, ["seek", "10", "absolute+exact"]) >= 0 else { exit(2) }
    poll(h, 1, events: &events)
    let after = cacheInteger(h, "debug-low-level-seeks")
    let positiveControl = before.map { beforeValue in after.map { $0 > beforeValue } ?? false } ?? true
    checks.require(positiveControl, "pre-load disabled-cache seek increments low-level counter", "before=\(String(describing: before)) after=\(String(describing: after))")
} else { exit(2) }

// 2. Paused exact re-anchor must preserve pause, discard forward payload under a
// 1 MiB cap, restore normal seekable-cache behavior, then tolerate paused seeks.
if let h = newPlayer() {
    defer { mpv_terminate_destroy(h) }
    var events = Events()
    guard loadAndBuffer(h, fixture, events: &events), parked(h, 30, events: &events) else { exit(2) }
    let before = cacheInteger(h, "fw-bytes") ?? -1
    let cap: Int64 = 1_048_576
    let capSet = command(h, ["set", "demuxer-max-bytes", "1MiB"]) >= 0
    let receipt = reanchor(h, at: 30, events: &events)
    let after = receipt?.forwardBytes ?? -1
    let lowLevelSeekAdvanced = receipt?.lowLevelBefore.map { beforeValue in receipt?.lowLevelAfter.map { $0 > beforeValue } ?? false } ?? false
    // The earlier immediate-set variant is refuted: it raced the demux option
    // update. This settled variant proves the race diagnosis independently of
    // the atomic drop-buffers candidate below.
    let dynamicSettled = capSet && receipt?.appliedNo == "no" && receipt?.restored == "auto" && !events.eof && flag(h, "pause") == true && after <= cap + 262_144 && after < before / 2 && lowLevelSeekAdvanced
    print("DIAGNOSTIC settled dynamic re-anchor \(dynamicSettled ? "passes" : "remains refuted"): before=\(before) minimumAfter=\(after) applied=\(String(describing: receipt?.appliedNo)) restored=\(String(describing: receipt?.restored)) lowLevel=\(String(describing: receipt?.lowLevelBefore))->\(String(describing: receipt?.lowLevelAfter)) eof=\(events.eof)")
    let pausedBack = command(h, ["seek", "10", "absolute+exact"]) >= 0 && waitUntil(h, 10, events: &events) { abs((number(h, "time-pos") ?? -999) - 10) < 1 }
    let pausedForward = command(h, ["seek", "30", "absolute+exact"]) >= 0 && waitUntil(h, 10, events: &events) { abs((number(h, "time-pos") ?? -999) - 30) < 1 }
    let start = number(h, "time-pos") ?? -1
    let played = command(h, ["set", "pause", "no"]) >= 0 && waitUntil(h, 8, events: &events) { (number(h, "time-pos") ?? start) > start + 0.5 }
    checks.require(pausedBack && pausedForward && played && !events.eof, "paused seeks and resume progress after re-anchor", "start=\(start) end=\(String(describing: number(h, "time-pos"))) eof=\(events.eof)")
} else { exit(2) }

// Candidate: enqueue drop-buffers and the exact recovery seek in one command
// string. libmpv executes the subcommands together before returning to its
// playloop, leaving no observable EOF window between them.
for attempt in 1...3 {
for paused in [true, false] {
    guard let h = newPlayer() else { exit(2) }
    var events = Events()
    guard loadAndBuffer(h, fixture, events: &events), parked(h, 30, events: &events) else { exit(2) }
    if !paused { guard command(h, ["set", "pause", "no"]) >= 0 else { exit(2) }; poll(h, 0.5, events: &events) }
    let target = number(h, "time-pos") ?? 30
    let before = cacheInteger(h, "fw-bytes") ?? -1
    guard command(h, ["set", "demuxer-max-bytes", "1MiB"]) >= 0 else { exit(2) }
    let receipt = atomicDropAndReanchor(h, at: target, events: &events)
    let after = receipt?.forwardBytes ?? -1
    let settled = receipt?.settledForwardBytes ?? -1
    let lowLevelAdvanced = receipt?.lowLevelBefore.map { beforeValue in receipt?.lowLevelAfter.map { $0 > beforeValue } ?? false } ?? false
    let label = paused ? "paused" : "playing"
    checks.require(receipt != nil && !events.eof && after <= 1_310_720 && settled <= 1_310_720 && after < before / 2 && lowLevelAdvanced && flag(h, "pause") == paused,
                   "atomic drop-buffers re-anchor sheds cache while \(label) attempt \(attempt)", "before=\(before) minimumAfter=\(after) settledAfter=\(settled) lowLevel=\(String(describing: receipt?.lowLevelBefore))->\(String(describing: receipt?.lowLevelAfter)) eof=\(events.eof)")
    if paused {
        let backward = command(h, ["seek", "10", "absolute+exact"]) >= 0 && waitUntil(h, 10, events: &events) { abs((number(h, "time-pos") ?? -999) - 10) < 1 }
        let forward = command(h, ["seek", "30", "absolute+exact"]) >= 0 && waitUntil(h, 10, events: &events) { abs((number(h, "time-pos") ?? -999) - 30) < 1 }
        let start = number(h, "time-pos") ?? -1
        let progresses = command(h, ["set", "pause", "no"]) >= 0 && waitUntil(h, 8, events: &events) { (number(h, "time-pos") ?? start) > start + 0.5 }
        checks.require(backward && forward && progresses && !events.eof, "atomic paused seek/replay remains usable", "eof=\(events.eof)")
    } else {
        let start = number(h, "time-pos") ?? target
        let progresses = waitUntil(h, 8, events: &events) { (number(h, "time-pos") ?? start) > start + 0.5 }
        checks.require(progresses && !events.eof, "atomic playing recovery progresses", "eof=\(events.eof)")
    }
    mpv_terminate_destroy(h)
}
}

// No suppression mechanism: a real end-of-file must still be delivered.
if let h = newPlayer() {
    defer { mpv_terminate_destroy(h) }
    var events = Events()
    guard command(h, ["loadfile", fixture, "replace"]) >= 0 else { exit(2) }
    _ = waitUntil(h, 12, events: &events) { number(h, "duration") != nil }
    let duration = number(h, "duration") ?? 0
    guard command(h, ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, duration - 0.25)), "absolute+exact"]) >= 0 else { exit(2) }
    poll(h, 2, events: &events)
    checks.require(events.eof && events.naturalEOF, "genuine end delivers EOF naturally", "duration=\(duration) natural=\(events.naturalEOF)")
} else { exit(2) }

print("SUMMARY \(checks.failures == 0 ? "PASS" : "FAIL") failures=\(checks.failures)")
exit(Int32(min(checks.failures, 125)))
