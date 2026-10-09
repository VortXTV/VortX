import Foundation
import Libmpv

@main
private enum MPVCacheSnapshotTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ name: String, _ condition: Bool) throws {
        guard condition else { print("FAIL \(name)"); throw Failure.assertion(name) }
        print("PASS \(name)")
    }

    static func integer(_ value: Int64) -> mpv_node {
        var node = mpv_node(); node.format = MPV_FORMAT_INT64; node.u.int64 = value; return node
    }
    static func flag(_ value: Int32) -> mpv_node {
        var node = mpv_node(); node.format = MPV_FORMAT_FLAG; node.u.flag = value; return node
    }
    static func double(_ value: Double) -> mpv_node {
        var node = mpv_node(); node.format = MPV_FORMAT_DOUBLE; node.u.double_ = value; return node
    }
    static func snapshot(_ fields: [(String, mpv_node)]) -> MPVDemuxerCacheSnapshot {
        var keys = fields.map { strdup($0.0) }
        defer { keys.forEach { free($0) } }
        var values = fields.map(\.1)
        return keys.withUnsafeMutableBufferPointer { keyBuffer in
            values.withUnsafeMutableBufferPointer { valueBuffer in
                var list = mpv_node_list(num: Int32(fields.count), values: valueBuffer.baseAddress, keys: keyBuffer.baseAddress)
                return withUnsafeMutablePointer(to: &list) {
                    var node = mpv_node(); node.format = MPV_FORMAT_NODE_MAP; node.u.list = $0
                    return MPVDemuxerCacheSnapshot(node: node)
                }
            }
        }
    }

    static func pure() throws {
        typealias P = MPVCacheReanchorPolicy
        let valid = snapshot([("fw-bytes", integer(0)), ("debug-low-level-seeks", integer(0)),
                              ("underrun", flag(0)), ("idle", flag(1)), ("debug-seeking", double(104.125))])
        try check("NODE map preserves real zero counters and false flags", valid.status == .available
            && valid.integer("fw-bytes") == 0 && valid.integer("debug-low-level-seeks") == 0
            && valid.flag("underrun") == false && valid.flag("idle") == true && valid.double("debug-seeking") == 104.125)
        let invalid = snapshot([("fw-bytes", integer(-1)), ("debug-low-level-seeks", double(0)),
                                ("underrun", flag(2)), ("debug-seeking", double(.nan))])
        try check("wrong types, negatives and nonfinite fields stay unknown", invalid.integer("fw-bytes") == nil
            && invalid.integer("debug-low-level-seeks") == nil && invalid.flag("underrun") == nil
            && invalid.double("debug-seeking") == nil && invalid.flag("idle") == nil)
        let duplicate = snapshot([("debug-low-level-seeks", integer(1)), ("debug-low-level-seeks", integer(2))])
        try check("duplicate counters cannot certify a seek", duplicate.integer("debug-low-level-seeks") == nil)
        try check("malformed is not zero or available", MPVDemuxerCacheSnapshot(node: integer(0)).status == .malformed)
        let unavailable = MPVDemuxerCacheSnapshot(status: .readError(-11))
        try check("native read failure retains its error and unknown fields", unavailable.status == .readError(-11)
            && unavailable.integer("debug-low-level-seeks") == nil)
        let sample = P.Sample(position: 104.125, seeking: false, eof: false, paused: true, lowLevelSeeks: 0)
        try check("known zero admits maintenance on settled native paused transport", P.admit(sample, seekable: true, transportSettled: true)?.paused == true)
        for suspect in [
            P.Sample(position: 104.125, seeking: false, eof: false, paused: true, lowLevelSeeks: nil),
            P.Sample(position: 104.125, seeking: true, eof: false, paused: true, lowLevelSeeks: 0),
            P.Sample(position: 104.125, seeking: false, eof: true, paused: true, lowLevelSeeks: 0),
            P.Sample(position: 104.125, seeking: nil, eof: false, paused: true, lowLevelSeeks: 0),
            P.Sample(position: 104.125, seeking: false, eof: nil, paused: true, lowLevelSeeks: 0),
            P.Sample(position: 104.125, seeking: false, eof: false, paused: nil, lowLevelSeeks: 0),
            P.Sample(position: .nan, seeking: false, eof: false, paused: true, lowLevelSeeks: 0),
            P.Sample(position: 0, seeking: false, eof: false, paused: true, lowLevelSeeks: 0)
        ] { try check("incomplete or unsafe native evidence refuses admission", P.admit(suspect, seekable: true, transportSettled: true) == nil) }
        try check("unattributed or unknown seekability refuses admission", P.admit(sample, seekable: true, transportSettled: false) == nil
            && P.admit(sample, seekable: nil, transportSettled: true) == nil)
        try check("changed pause intent or unsettled event cannot complete or retry", !P.canSettle(sample, target: 104.125, pausedIntent: false, transportSettled: true)
            && !P.canSettle(sample, target: 104.125, pausedIntent: true, transportSettled: false))
        try check("remote and nonfinite target cannot complete", !P.canSettle(sample, target: 107, pausedIntent: true, transportSettled: true)
            && !P.canSettle(sample, target: .infinity, pausedIntent: true, transportSettled: true))

        // The actual production command policy retires a queued cache witness across three
        // accepted viewer seeks, replacement, same-owner reset and stop.
        var transport = MPVSeekSettlementPolicy<Int>(); transport.reset(owner: 7)
        let cacheCommand = transport.beginIssue(owner: 7, seeking: false)!
        transport.completeIssue(cacheCommand, accepted: true)
        transport.observeSeek(owner: 7); transport.observeRestart(owner: 7, seeking: false, eofReached: false)
        let queued = transport.evidence(owner: 7, seeking: false, eofReached: false)
        for _ in 0..<3 {
            let newer = transport.beginIssue(owner: 7, seeking: false)!
            transport.completeIssue(newer, accepted: true)
        }
        try check("three accepted seeks retire queued cache event", !transport.accepts(queued, owner: 7))
        for owner: Int? in [7, 8, nil] {
            transport.reset(owner: owner)
            try check("reset replacement or stop retires queued event", !transport.accepts(queued, owner: 7))
        }
        var flight = CacheFlushSingleFlight<Int>()
        let timeout = DispatchWorkItem {}
        let initial = flight.install(owner: 7, reason: .memoryWarning, target: 104.125, targetArgument: "104.125",
            startUptime: 10, timeoutWorkItem: timeout, originalSeekableCache: "yes", lowLevelSeeksAtIssue: 0, wasPaused: true)
        _ = flight.markSeekCommandAccepted(id: initial.id, owner: 7); _ = flight.markSeekEventObserved(owner: 7)
        try check("unknown counter never completes or reissues", flight.completeOnPlaybackRestart(owner: 7, position: 104.125, lowLevelSeeks: nil) == nil
            && flight.reissueAfterCachedRestart(owner: 7, lowLevelSeeks: nil) == nil)
        let retry = flight.reissueAfterCachedRestart(owner: 7, lowLevelSeeks: 0)!
        try check("one cached restart retains deadline and option rollback snapshot", retry.reissues == 1 && retry.startUptime == 10
            && retry.timeoutWorkItem === timeout && retry.originalSeekableCache == "yes"
            && !flight.acceptsEvent(id: initial.id, owner: 7, attempt: 0))
        _ = flight.markSeekCommandAccepted(id: retry.id, owner: 7); _ = flight.markSeekEventObserved(owner: 7)
        try check("second cached restart cannot create reset loop", flight.reissueAfterCachedRestart(owner: 7, lowLevelSeeks: 0) == nil)
        let ended = flight.settle(id: retry.id, owner: 7)
        try check("timeout fails and preserves restoration option", ended?.result == .timedOut && ended?.originalSeekableCache == "yes"
            && timeout.isCancelled && flight.current == nil)
        for terminal in ["error", "cancel", "timeout"] {
            let installed = flight.install(owner: 7, reason: .memoryWarning, target: 104.125, targetArgument: "104.125",
                startUptime: 10, timeoutWorkItem: DispatchWorkItem {}, originalSeekableCache: "auto", lowLevelSeeksAtIssue: 0, wasPaused: true)
            flight.updateTransportIntent(owner: 8, paused: false)
            try check("foreign pause intent cannot mutate flight", flight.current?.wasPaused == true)
            flight.updateTransportIntent(owner: 7, paused: false)
            try check("accepted pause change requires matching native state", !P.canSettle(sample, target: installed.target,
                pausedIntent: flight.current!.wasPaused, transportSettled: true))
            let finished: CacheFlushFlight<Int>?
            switch terminal {
            case "error": finished = flight.seekCommandError(id: installed.id, owner: 7)
            case "cancel": finished = flight.reset(owner: 7)
            default:
                _ = flight.markSeekCommandAccepted(id: installed.id, owner: 7)
                finished = flight.settle(id: installed.id, owner: 7)
            }
            try check("\(terminal) retains exact original option and retires event", finished?.originalSeekableCache == "auto"
                && flight.current == nil && !flight.acceptsEvent(id: installed.id, owner: 7, attempt: 0))
        }
        print("MPVCacheSnapshotTests pure ALL PASS")
    }

    static func number(_ handle: OpaquePointer, _ key: String) -> Double? {
        var value = Double(); return mpv_get_property(handle, key, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }
    static func boolean(_ handle: OpaquePointer, _ key: String) -> Bool? {
        var value = Int32(); return mpv_get_property(handle, key, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }
    static func string(_ handle: OpaquePointer, _ key: String) -> String? {
        guard let value = mpv_get_property_string(handle, key) else { return nil }
        defer { mpv_free(value) }; return String(cString: value)
    }
    static func nativeSample(_ handle: OpaquePointer) -> MPVCacheReanchorPolicy.Sample {
        .init(position: number(handle, "time-pos"), seeking: boolean(handle, "seeking"), eof: boolean(handle, "eof-reached"),
              paused: boolean(handle, "pause"), lowLevelSeeks: MPVDemuxerCacheSnapshot.read(from: handle).integer("debug-low-level-seeks"))
    }
    static func native() throws {
        let args = CommandLine.arguments
        guard args.count >= 4, args[1].hasPrefix("http://127.0.0.1:"), let handle = mpv_create() else { throw Failure.assertion("local fixture arguments") }
        defer { mpv_terminate_destroy(handle) }
        for (key, value) in [("vo", "null"), ("ao", "null"), ("terminal", "no"), ("config", "no"),
                              ("stream-lavf-o", args[2]), ("demuxer-readahead-secs", "300"), ("demuxer-max-bytes", "256MiB")] {
            try check("headless option \(key)", mpv_set_option_string(handle, key, value) >= 0)
        }
        try check("initialize fresh libmpv", mpv_initialize(handle) >= 0)
        print("artifact mpv=\(string(handle, "mpv-version") ?? "unknown") ffmpeg=\(string(handle, "ffmpeg-version") ?? "unknown")")
        let unloaded = MPVDemuxerCacheSnapshot.read(from: handle)
        try check("unloaded native map remains unavailable", unloaded.status == .unavailable && unloaded.integer("debug-low-level-seeks") == nil)
        try check("load synthetic localhost media", mpv_command_string(handle, "loadfile \(args[1]) replace") >= 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var warmupIssued = false, warmupSeek = false, ready = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let event = mpv_wait_event(handle, 0.05)!.pointee.event_id
            if !warmupIssued, let position = number(handle, "time-pos"), position >= 0.4, boolean(handle, "seeking") == false {
                try check("accept pause", mpv_set_property_string(handle, "pause", "yes") >= 0)
                try check("accept cold nonzero seek", mpv_command_string(handle, "seek 104.146 absolute+exact") >= 0)
                warmupIssued = true; continue
            }
            if warmupIssued && event == MPV_EVENT_SEEK { warmupSeek = true }
            if warmupSeek && event == MPV_EVENT_PLAYBACK_RESTART,
               MPVCacheReanchorPolicy.canSettle(nativeSample(handle), target: 104.146, pausedIntent: true, transportSettled: true) { ready = true; break }
        }
        try check("cold nonzero seek settled paused", ready)
        while mpv_wait_event(handle, 0)!.pointee.event_id != MPV_EVENT_NONE {}
        let cache = MPVDemuxerCacheSnapshot.read(from: handle)
        var oldCounter: Int64 = -1
        let oldStatus = mpv_get_property(handle, "demuxer-cache-state/debug-low-level-seeks", MPV_FORMAT_INT64, &oldCounter)
        var oldFlag: Int32 = -1
        let oldFlagStatus = mpv_get_property(handle, "demuxer-cache-state/idle", MPV_FORMAT_FLAG, &oldFlag)
        print("cache-read legacyCounterStatus=\(oldStatus) legacyIdleStatus=\(oldFlagStatus) mapCounter=\(cache.integer("debug-low-level-seeks") ?? -1) mapForwardBytes=\(cache.integer("fw-bytes") ?? -1) mapIdle=\(String(describing: cache.flag("idle")))")
        try check("baseline slash properties fail while typed map is available", oldStatus < 0 && oldFlagStatus < 0
            && cache.integer("debug-low-level-seeks") != nil && cache.integer("fw-bytes") != nil && cache.flag("idle") != nil)
        let native = nativeSample(handle)
        let legacy = ProcessInfo.processInfo.environment["VORTX_TEST_LEGACY_CACHE_READ"] == "1"
        let sample = MPVCacheReanchorPolicy.Sample(position: native.position, seeking: native.seeking, eof: native.eof, paused: native.paused,
            lowLevelSeeks: legacy ? (oldStatus >= 0 ? Int(oldCounter) : nil) : native.lowLevelSeeks)
        let admission = MPVCacheReanchorPolicy.admit(sample, seekable: boolean(handle, "seekable"), transportSettled: true)
        try check("production reanchor admission has real counter", admission != nil)
        let admitted = admission!
        guard let original = string(handle, "demuxer-seekable-cache") else { throw Failure.assertion("original cache option unavailable") }
        defer { _ = mpv_set_property_string(handle, "demuxer-seekable-cache", original) }
        var flight = CacheFlushSingleFlight<Int>()
        var transport = MPVSeekSettlementPolicy<Int>(); transport.reset(owner: 7)
        let operation = flight.install(owner: 7, reason: .memoryWarning, target: admitted.target,
            targetArgument: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), admitted.target),
            startUptime: ProcessInfo.processInfo.systemUptime, timeoutWorkItem: DispatchWorkItem {},
            originalSeekableCache: original, lowLevelSeeksAtIssue: admitted.lowLevelSeeks, wasPaused: admitted.paused)
        func issue() throws {
            let lease = transport.beginIssue(owner: 7, seeking: boolean(handle, "seeking"))!
            try check("disable in-cache seek", mpv_set_property_string(handle, "demuxer-seekable-cache", "no") >= 0)
            let status = mpv_command_string(handle, "no-osd seek \(operation.targetArgument) absolute+exact")
            transport.completeIssue(lease, accepted: status >= 0)
            try check("accept bounded cache reanchor", status >= 0)
            _ = flight.markSeekCommandAccepted(id: operation.id, owner: 7)
        }
        try issue()
        var completed: CacheFlushFlight<Int>?
        while ProcessInfo.processInfo.systemUptime - operation.startUptime < 15 {
            let event = mpv_wait_event(handle, 0.05)!.pointee.event_id
            let observed = nativeSample(handle)
            if event == MPV_EVENT_SEEK {
                transport.observeSeek(owner: 7); _ = flight.markSeekEventObserved(owner: 7)
            }
            if event != MPV_EVENT_PLAYBACK_RESTART { continue }
            transport.observeRestart(owner: 7, seeking: observed.seeking, eofReached: observed.eof)
            let evidence = transport.evidence(owner: 7, seeking: observed.seeking, eofReached: observed.eof)
            print("reanchor restart position=\(observed.position ?? -1) counter=\(observed.lowLevelSeeks ?? -1) baseline=\(admitted.lowLevelSeeks) paused=\(String(describing: observed.paused)) reissues=\(flight.current?.reissues ?? -1)")
            guard MPVCacheReanchorPolicy.canSettle(observed, target: operation.target, pausedIntent: true,
                transportSettled: evidence.settled && evidence.attributed) else { continue }
            completed = flight.completeOnPlaybackRestart(owner: 7, position: observed.position, lowLevelSeeks: observed.lowLevelSeeks)
            if completed != nil { break }
            if flight.reissueAfterCachedRestart(owner: 7, lowLevelSeeks: observed.lowLevelSeeks) != nil { try issue() }
        }
        try check("native low-level reanchor completes without pause loss", completed?.result == .commandAccepted && boolean(handle, "pause") == true)
        try check("restore original seekable-cache option", mpv_set_property_string(handle, "demuxer-seekable-cache", original) >= 0
            && string(handle, "demuxer-seekable-cache") == original)
        try check("single reissue ceiling retained", (completed?.reissues ?? 9) <= 1)
        // Exercise native option rollback on each production value-policy exit, without
        // launching an app or waiting 15s for a modeled deadline.
        for terminal in ["error", "cancel", "timeout"] {
            let installed = flight.install(owner: 7, reason: .memoryWarning, target: admitted.target,
                targetArgument: operation.targetArgument, startUptime: ProcessInfo.processInfo.systemUptime,
                timeoutWorkItem: DispatchWorkItem {}, originalSeekableCache: original,
                lowLevelSeeksAtIssue: nativeSample(handle).lowLevelSeeks!, wasPaused: true)
            try check("set temporary native option for \(terminal)", mpv_set_property_string(handle, "demuxer-seekable-cache", "no") >= 0)
            let finished: CacheFlushFlight<Int>?
            switch terminal {
            case "error":
                try check("native invalid seek command is rejected", mpv_command_string(handle, "seek invalid absolute+exact") < 0)
                finished = flight.seekCommandError(id: installed.id, owner: 7)
            case "cancel": finished = flight.reset(owner: 7)
            default:
                _ = flight.markSeekCommandAccepted(id: installed.id, owner: 7)
                finished = flight.settle(id: installed.id, owner: 7)
            }
            try check("\(terminal) restores actual original cache option", finished != nil && flight.current == nil
                && mpv_set_property_string(handle, "demuxer-seekable-cache", finished!.originalSeekableCache) >= 0
                && string(handle, "demuxer-seekable-cache") == original && boolean(handle, "pause") == true)
        }
        print("MPVCacheSnapshotTests native ALL PASS")
    }

    static func main() {
        do { if CommandLine.arguments.count == 1 { try pure() } else { try native() } }
        catch { print("MPVCacheSnapshotTests FAILED: \(error)"); exit(1) }
    }
}
