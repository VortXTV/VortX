import Foundation
import Libmpv

private final class Results {
    private(set) var failures = 0

    func check(_ condition: Bool, _ name: String, _ detail: String) {
        if condition {
            print("GREEN  \(name): \(detail)")
        } else {
            failures += 1
            print("RED    \(name): \(detail)")
        }
    }
}

private struct Observation {
    let rebaseEnabled: Bool
    let demuxerStart: Double
    let firstPosition: Double
    let resumePosition: Double
    let returnedPosition: Double
}

private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
    let result = mpv_set_option_string(handle, name, value)
    guard result >= 0 else {
        fatalError("mpv_set_option_string(\(name)=\(value)) failed: \(result)")
    }
}

private func doubleProperty(_ handle: OpaquePointer, _ name: String) -> Double? {
    var value = 0.0
    guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else {
        return nil
    }
    return value
}

private func flagProperty(_ handle: OpaquePointer, _ name: String) -> Bool? {
    var value: Int32 = 0
    guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else {
        return nil
    }
    return value != 0
}

private func command(_ handle: OpaquePointer, _ values: [String]) -> Int32 {
    let storage = values.map { strdup($0) }
    defer { storage.forEach { free($0) } }
    var arguments: [UnsafePointer<CChar>?] = storage.map { UnsafePointer<CChar>($0) }
    arguments.append(nil)
    return mpv_command(handle, &arguments)
}

private func waitForPosition(
    _ handle: OpaquePointer,
    timeout: TimeInterval,
    predicate: (Double) -> Bool
) -> Double? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let event = mpv_wait_event(handle, 0.25) else { continue }
        if event.pointee.event_id == MPV_EVENT_END_FILE {
            return nil
        }
        if let position = doubleProperty(handle, "time-pos"), predicate(position) {
            return position
        }
    }
    return doubleProperty(handle, "time-pos").flatMap { predicate($0) ? $0 : nil }
}

private func observe(
    fixture: String,
    rebaseOverride: Bool?
) -> Observation? {
    guard let handle = mpv_create() else {
        print("INFRA  mpv_create returned nil")
        return nil
    }
    defer { mpv_terminate_destroy(handle) }

    // Timeline-relevant production invariants from MPVMetalViewController.setupMpv.
    setOption(handle, "config", "no")
    setOption(handle, "load-scripts", "no")
    setOption(handle, "resume-playback", "no")
    setOption(handle, "idle", "yes")
    setOption(handle, "keep-open", "yes")
    setOption(handle, "vo", "null")
    setOption(handle, "ao", "null")
    setOption(handle, "hwdec", "no")
    if let rebaseOverride {
        setOption(handle, "rebase-start-time", rebaseOverride ? "yes" : "no")
    }

    guard mpv_initialize(handle) >= 0 else {
        print("INFRA  mpv_initialize failed")
        return nil
    }
    guard command(handle, ["loadfile", fixture, "replace"]) >= 0 else {
        print("INFRA  loadfile failed for \(fixture)")
        return nil
    }

    var loaded = false
    let loadDeadline = Date().addingTimeInterval(20)
    while Date() < loadDeadline, !loaded {
        guard let event = mpv_wait_event(handle, 0.5) else { continue }
        if event.pointee.event_id == MPV_EVENT_FILE_LOADED {
            loaded = true
        } else if event.pointee.event_id == MPV_EVENT_END_FILE {
            print("INFRA  fixture ended before FILE_LOADED")
            return nil
        }
    }
    guard loaded,
          let rebaseEnabled = flagProperty(handle, "options/rebase-start-time"),
          let demuxerStart = doubleProperty(handle, "demuxer-start-time"),
          let firstPosition = waitForPosition(
            handle,
            timeout: 5,
            predicate: { $0 > 0.01 && $0 < 8 }
          ) else {
        print("INFRA  libmpv did not expose the loaded timeline")
        return nil
    }

    guard command(handle, ["seek", "7.000", "absolute+exact"]) >= 0,
          let resumePosition = waitForPosition(
            handle,
            timeout: 8,
            predicate: { abs($0 - 7) < 0.75 }
          ) else {
        print("INFRA  absolute resume seek did not settle at 7 seconds")
        return nil
    }

    guard command(handle, ["seek", "0.000", "absolute+exact"]) >= 0,
          let returnedPosition = waitForPosition(
            handle,
            timeout: 8,
            predicate: { $0 >= 0 && $0 < 0.75 }
          ) else {
        print("INFRA  return-to-start seek did not settle near zero")
        return nil
    }

    return Observation(
        rebaseEnabled: rebaseEnabled,
        demuxerStart: demuxerStart,
        firstPosition: firstPosition,
        resumePosition: resumePosition,
        returnedPosition: returnedPosition
    )
}

guard CommandLine.arguments.count == 2 else {
    print("usage: libmpv-fresh-start <positive-start-fixture.mkv>")
    exit(2)
}

let fixture = CommandLine.arguments[1]
private let results = Results()

guard let brokenControl = observe(fixture: fixture, rebaseOverride: false) else {
    exit(2)
}
results.check(
    !brokenControl.rebaseEnabled
        && abs(brokenControl.demuxerStart - 5) < 0.1
        && brokenControl.firstPosition >= 4.5,
    "positive-origin control reproduces the field signature",
    String(
        format: "rebase=%@ demuxerStart=%.3fs firstPosition=%.3fs",
        brokenControl.rebaseEnabled ? "yes" : "no",
        brokenControl.demuxerStart,
        brokenControl.firstPosition
    )
)

guard let production = observe(fixture: fixture, rebaseOverride: nil) else {
    exit(2)
}
results.check(
    production.rebaseEnabled,
    "shipping libmpv default rebases container start time",
    "options/rebase-start-time=\(production.rebaseEnabled ? "yes" : "no")"
)
results.check(
    abs(production.demuxerStart - 5) < 0.1,
    "fixture reaches libmpv with the positive container origin intact",
    String(format: "demuxer-start-time=%.3fs", production.demuxerStart)
)
results.check(
    production.firstPosition >= 0 && production.firstPosition < 0.75,
    "fresh playback position is title-relative",
    String(format: "first time-pos=%.3fs", production.firstPosition)
)
results.check(
    abs(production.resumePosition - 7) < 0.75,
    "absolute resume remains title-relative",
    String(format: "seek 7 -> time-pos %.3fs", production.resumePosition)
)
results.check(
    production.returnedPosition >= 0 && production.returnedPosition < 0.75,
    "deep seek back to title start remains zero-based",
    String(format: "seek 0 -> time-pos %.3fs", production.returnedPosition)
)

print("SUMMARY \(results.failures == 0 ? "PASS" : "FAIL") failures=\(results.failures)")
exit(Int32(min(results.failures, 125)))
