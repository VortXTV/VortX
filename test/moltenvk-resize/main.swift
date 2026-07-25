// =============================================================================
// moltenvk-resize harness
//
// Proves, against the REAL libmpv we ship, that resizing the CAMetalLayer alone
// makes mpv re-render at the new size, with NO video-chain teardown.
//
// This is the acceptance test for scripts/mpv-moltenvk-resize.patch. Before that
// patch the moltenvk render context answered VO_NOTIMPL to every request, so a
// layer resize was invisible to mpv and the app had to destroy and rebuild the
// whole decode plus VO chain (vid=no then vid=auto) on every rotation.
//
// It drives libmpv exactly the way MPVMetalViewController does (wid = the
// CAMetalLayer pointer, vo=gpu-next, gpu-api=vulkan, gpu-context=moltenvk), so a
// pass here is a statement about the shipped configuration, not a lab setup.
//
// Signals, all read from mpv itself:
//   osd-width / osd-height   mpv's own view of its window size (vo->dwidth/dheight
//                            reach it through vo_get_src_dst_rects). If this
//                            follows the layer, mpv genuinely re-laid-out.
//   "moltenvk: layer resized" the patch's own verbose line, so a pass cannot come
//                            from some unrelated path.
//   "VO: [" / "reconfig to"  mpv's markers for a VO (re)configure. Seeing either
//                            AFTER the baseline means the chain was rebuilt, which
//                            is the exact cost this work removes.
//
// Exit code = RED count, so it can gate.
// =============================================================================

import Foundation
import AppKit
import QuartzCore
import Metal
import Libmpv

// ---------------------------------------------------------------- result board

final class Board: @unchecked Sendable {
    private let lock = NSLock()
    private var reds = 0
    func green(_ what: String, _ detail: String) {
        lock.lock(); print("GREEN  \(what): \(detail)"); lock.unlock()
    }
    func red(_ what: String, _ detail: String) {
        lock.lock(); reds += 1; print("RED    \(what): \(detail)"); lock.unlock()
    }
    func check(_ ok: Bool, _ what: String, _ detail: String) {
        ok ? green(what, detail) : red(what, detail)
    }
    var redCount: Int { lock.lock(); defer { lock.unlock() }; return reds }
}

let board = Board()

// ---------------------------------------------------------------- log capture

final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    /// Lines added at or after `from`, matching `needle`.
    func matches(_ needle: String, from: Int = 0) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard from < lines.count else { return [] }
        return lines[from...].filter { $0.contains(needle) }
    }
}

let sink = LogSink()

// ---------------------------------------------------------------- fixture

let fixture = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/dd-mvkresize/fixtures/resize-fixture.mkv"

guard FileManager.default.fileExists(atPath: fixture) else {
    print("RED    fixture: not found at \(fixture)")
    exit(1)
}

// ---------------------------------------------------------------- surface

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let startSize = CGSize(width: 640, height: 360)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: startSize),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView?.wantsLayer = true

let layer = CAMetalLayer()
layer.device = MTLCreateSystemDefaultDevice()
layer.framebufferOnly = false
layer.presentsWithTransaction = false
layer.allowsNextDrawableTimeout = true
layer.contentsScale = 1
layer.frame = NSRect(origin: .zero, size: startSize)
layer.drawableSize = startSize
window.contentView?.layer?.addSublayer(layer)
window.orderFrontRegardless()

// ---------------------------------------------------------------- mpv

guard let mpv = mpv_create() else {
    print("RED    mpv_create: returned nil")
    exit(1)
}

func opt(_ name: String, _ value: String) {
    let rc = mpv_set_option_string(mpv, name, value)
    if rc < 0 { print("note: mpv_set_option_string(\(name)=\(value)) rc=\(rc)") }
}

mpv_request_log_messages(mpv, "v")

// Same handoff MPVMetalViewController performs: WinID carries the CAMetalLayer pointer,
// which context_moltenvk.m bridges straight back to a CAMetalLayer *.
var winID = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &winID)

opt("vo", "gpu-next")
opt("gpu-api", "vulkan")
opt("gpu-context", "moltenvk")
opt("hwdec", "no")          // determinism: keep VideoToolbox out of the picture
opt("audio", "no")          // no AO, so an audio route cannot colour the result
opt("loop-file", "inf")     // the file must never end under us
opt("keep-open", "yes")
opt("idle", "yes")

guard mpv_initialize(mpv) >= 0 else {
    print("RED    mpv_initialize: failed")
    exit(1)
}

// ---------------------------------------------------------------- event pump

let pump = Thread {
    while true {
        guard let ev = mpv_wait_event(mpv, 1.0) else { continue }
        switch ev.pointee.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            let m = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(ev.pointee.data))!
            let prefix = String(cString: m.pointee.prefix)
            let text = String(cString: m.pointee.text).trimmingCharacters(in: .newlines)
            sink.append("[\(prefix)] \(text)")
        case MPV_EVENT_SHUTDOWN:
            return
        default:
            break
        }
    }
}
pump.stackSize = 1 << 20
pump.start()

// ---------------------------------------------------------------- helpers

func intProp(_ name: String) -> Int64 {
    var v: Int64 = 0
    guard mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v) >= 0 else { return -1 }
    return v
}

func doubleProp(_ name: String) -> Double {
    var v: Double = 0
    guard mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v) >= 0 else { return -1 }
    return v
}

func setLayerSize(_ size: CGSize) {
    DispatchQueue.main.async {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = NSRect(origin: .zero, size: size)
        layer.drawableSize = size
        CATransaction.commit()
    }
}

/// The candidate follow-ups a host app can perform after it resizes the layer. mpv's vo thread
/// parks for a very long time when it has nothing to render (video/out/vo.c), so while PAUSED a
/// poll-based resize may not be picked up until something wakes that thread. Which of these
/// actually wakes it is measured, not assumed.
enum Nudge: String, CaseIterable {
    /// Nothing at all: a bare layer resize.
    case none
    /// MPVMetalViewController.applyVideoSize, default (Original) branch. Note that mpv only
    /// notifies option listeners when a value actually CHANGES (options/m_config_core.c), and
    /// these values do not change on a rotation, so this is expected to be inert.
    case size
    /// An async read of a property whose getter goes through vo_control(), which dispatches onto
    /// the vo thread and therefore wakes it. The value is irrelevant and this lane answers
    /// VO_NOTIMPL; the dispatch is the entire point. Async so no caller ever blocks on the vo thread.
    case wake

    func apply(_ mpv: OpaquePointer) {
        switch self {
        case .none:
            return
        case .size:
            mpv_set_property_string(mpv, "keepaspect", "yes")
            mpv_set_property_string(mpv, "panscan", "0.0")
        case .wake:
            mpv_get_property_async(mpv, 0, "display-names", MPV_FORMAT_STRING)
        }
    }
}

/// Poll until `predicate` holds or `seconds` elapse. Returns whether it held.
@discardableResult
func waitUntil(_ seconds: Double, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return predicate()
}

// ---------------------------------------------------------------- the run

let work = Thread {
    var cmd: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")),
                                        UnsafePointer(strdup(fixture)), nil]
    let loadRC = mpv_command(mpv, &cmd)
    board.check(loadRC >= 0, "loadfile", "rc=\(loadRC) \(fixture)")

    // 1. Real playback, at the size the surface started at.
    let started = waitUntil(30) { doubleProp("time-pos") > 0.5 && intProp("osd-width") > 0 }
    let w0 = intProp("osd-width"), h0 = intProp("osd-height")
    board.check(started && w0 == Int64(startSize.width) && h0 == Int64(startSize.height),
                "baseline", "playing at osd \(w0)x\(h0), expected \(Int(startSize.width))x\(Int(startSize.height))")
    guard started else {
        print("INFRA  playback never started; last 40 log lines:")
        sink.snapshot().suffix(40).forEach { print("       \($0)") }
        exit(Int32(max(board.redCount, 1)))
    }

    // Everything after this mark is what a rotation costs.
    let mark = sink.count
    let posBefore = doubleProp("time-pos")

    // 2. First resize, the shape of a portrait to landscape rotation.
    let sizeA = CGSize(width: 960, height: 540)
    setLayerSize(sizeA)
    let tookA = waitUntil(10) { intProp("osd-width") == Int64(sizeA.width) }
    board.check(tookA, "resize-1 followed",
                "osd is \(intProp("osd-width"))x\(intProp("osd-height")), expected 960x540")
    board.check(!sink.matches("moltenvk: layer resized to 960x540", from: mark).isEmpty,
                "resize-1 came from the render context",
                "the patch's own log line is \(sink.matches("moltenvk: layer resized to 960x540", from: mark).isEmpty ? "absent" : "present")")

    // 3. Second resize, to prove it is a live poll and not a one-shot.
    let sizeB = CGSize(width: 1280, height: 720)
    setLayerSize(sizeB)
    let tookB = waitUntil(10) { intProp("osd-width") == Int64(sizeB.width) }
    board.check(tookB, "resize-2 followed",
                "osd is \(intProp("osd-width"))x\(intProp("osd-height")), expected 1280x720")

    // 4. THE POINT: neither resize may have rebuilt the video chain.
    let voLines = sink.matches("VO: [", from: mark)
    board.check(voLines.isEmpty, "no VO rebuild",
                voLines.isEmpty ? "no new \"VO: [\" line across two resizes"
                                : "video output was reconfigured: \(voLines.joined(separator: " | "))")
    let reconfigLines = sink.matches("reconfig to", from: mark)
    board.check(reconfigLines.isEmpty, "no vo reconfig",
                reconfigLines.isEmpty ? "no new \"reconfig to\" line across two resizes"
                                      : "vo reconfigured: \(reconfigLines.joined(separator: " | "))")

    // 5. The poll must not fire on every iteration. Two size changes, so anything
    //    beyond a handful means the compare is wrong and the vo thread is spinning.
    let resizeLines = sink.matches("moltenvk: layer resized", from: mark)
    board.check(resizeLines.count <= 4, "poll does not spin",
                "\(resizeLines.count) resize lines for 2 size changes")

    // 6. Playback survived all of it.
    let posAfter = doubleProp("time-pos")
    board.check(posAfter > posBefore, "playback continued",
                String(format: "time-pos %.2f -> %.2f", posBefore, posAfter))

    // 6b. A resize that left playback crawling would be its own regression, so check that the clock
    //     recovers to real time afterwards rather than merely moving. libplacebo rebuilds pipelines
    //     for the new swapchain, which costs a moment; five seconds later it should be over.
    let settleFrom = doubleProp("time-pos")
    Thread.sleep(forTimeInterval: 5.0)
    let settleTo = doubleProp("time-pos")
    let advanced = settleTo - settleFrom
    board.check(advanced >= 4.0, "playback returns to real time after a resize",
                String(format: "advanced %.2fs of wall 5.00s", advanced))

    // 7. The awkward case: rotate while PAUSED, where the vo thread has nothing to render and
    //    parks. Probe each candidate follow-up in turn, each against its own target size, and
    //    print what actually happened. These are PROBE lines, not gate results: their job is to
    //    say which follow-up the app must perform, with measurement behind it.
    var yes: Int32 = 1
    mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &yes)
    Thread.sleep(forTimeInterval: 2.0)

    let pausedMark = sink.count
    var probeSizes: [Nudge: CGSize] = [.none: CGSize(width: 800, height: 450),
                                       .size: CGSize(width: 848, height: 477),
                                       .wake: CGSize(width: 896, height: 504)]
    var worked: [Nudge] = []
    for nudge in Nudge.allCases {
        let target = probeSizes[nudge]!
        setLayerSize(target)
        Thread.sleep(forTimeInterval: 0.3)   // let the layer write land before the follow-up
        nudge.apply(mpv)
        let seen = waitUntil(6) { intProp("osd-width") == Int64(target.width) }
        if seen { worked.append(nudge) }
        print("PROBE  paused rotation, follow-up \"\(nudge.rawValue)\": " +
              "\(seen ? "SEEN" : "NOT SEEN") (osd \(intProp("osd-width"))x\(intProp("osd-height")), " +
              "wanted \(Int(target.width))x\(Int(target.height)))")
    }
    print("PROBE  follow-ups that woke the vo thread while paused: " +
          "\(worked.isEmpty ? "none" : worked.map(\.rawValue).joined(separator: ", "))")

    // Whatever the mechanism, a paused rotation must end up at the right size, and must still
    // not have rebuilt the video chain.
    board.check(!worked.isEmpty, "paused rotation reaches the new size",
                worked.isEmpty ? "no follow-up made mpv notice a resize while paused"
                               : "via: \(worked.map(\.rawValue).joined(separator: ", "))")
    let pausedVO = sink.matches("VO: [", from: pausedMark) + sink.matches("reconfig to", from: pausedMark)
    board.check(pausedVO.isEmpty, "no VO rebuild while paused",
                pausedVO.isEmpty ? "no rebuild markers" : pausedVO.joined(separator: " | "))

    let reds = board.redCount
    print("---")
    print("moltenvk-resize: \(reds) RED")
    if reds > 0 {
        print("last 40 log lines:")
        sink.snapshot().suffix(40).forEach { print("       \($0)") }
    }
    exit(Int32(reds))
}
work.stackSize = 1 << 20
work.start()

app.run()
