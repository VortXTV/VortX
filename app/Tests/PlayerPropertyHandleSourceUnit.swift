// Saved source-unit fixture. The runner inserts unchanged production method text below.
// Fake native ABI and deterministic stored work do not emulate native threads or destruction.
import Foundation
import Dispatch
import Darwin

let MPV_FORMAT_DOUBLE: Int32 = 1
let MPV_FORMAT_FLAG: Int32 = 2
let MPV_FORMAT_INT64: Int32 = 3
let liveHandle = OpaquePointer(bitPattern: 0x1234)!

struct NativeCall {
    let handle: OpaquePointer?
    let name: String
    let format: Int32?
    let writtenFlag: Int32?
    let writtenString: String?
}
final class NativeState {
    var calls: [NativeCall] = []
    var status: Int32 = 0
    var writeReadValue = true
    var doubleValue = 2.5
    var intValue: Int64 = 7
    var flagValue: Int32 = 1
    var stringValue: String? = "value"
    var freeCalls = 0
    var nilFreeCalls = 0
    var allocated = 0
}
var native = NativeState()

@discardableResult
func mpv_get_property<T>(_ handle: OpaquePointer?, _ name: String,
                         _ format: Int32, _ value: UnsafeMutablePointer<T>) -> Int32 {
    native.calls.append(.init(handle: handle, name: name, format: format,
                              writtenFlag: nil, writtenString: nil))
    if native.writeReadValue {
        let raw = UnsafeMutableRawPointer(value)
        switch format {
        case MPV_FORMAT_DOUBLE: raw.storeBytes(of: native.doubleValue, as: Double.self)
        case MPV_FORMAT_FLAG: raw.storeBytes(of: native.flagValue, as: Int32.self)
        case MPV_FORMAT_INT64: raw.storeBytes(of: native.intValue, as: Int64.self)
        default: fatalError("Unexpected fake property format")
        }
    }
    return native.status
}

func mpv_get_property_string(_ handle: OpaquePointer?, _ name: String) -> UnsafeMutablePointer<CChar>? {
    native.calls.append(.init(handle: handle, name: name, format: nil,
                              writtenFlag: nil, writtenString: nil))
    guard let value = native.stringValue else { return nil }
    native.allocated += 1
    return strdup(value)
}

func mpv_free(_ value: UnsafeMutablePointer<CChar>?) {
    native.freeCalls += 1
    if value == nil { native.nilFreeCalls += 1 }
    free(value)
}

@discardableResult
func mpv_set_property(_ handle: OpaquePointer?, _ name: String,
                      _ format: Int32, _ value: UnsafeMutablePointer<Int32>) -> Int32 {
    native.calls.append(.init(handle: handle, name: name, format: format,
                              writtenFlag: value.pointee, writtenString: nil))
    return native.status
}

@discardableResult
func mpv_set_property_string(_ handle: OpaquePointer?, _ name: String, _ value: String) -> Int32 {
    native.calls.append(.init(handle: handle, name: name, format: nil,
                              writtenFlag: nil, writtenString: value))
    return native.status
}

// The ramp's selected property names never enter this dependency's branch.
struct MPVDemuxerCacheSnapshot {
    static func read(from handle: OpaquePointer) -> Self {
        fatalError("Unexpected cache-node dependency in property-handle fixture")
    }
    func double(_ name: String) -> Double? { nil }
    func integer(_ name: String) -> Int? { nil }
    func flag(_ name: String) -> Bool? { nil }
}
enum MPVProperty {
    static let frameDropCount = "frame-drop-count"
    static let pausedForCache = "paused-for-cache"
}
enum VXProbe { static func log(_ channel: String, _ message: String) {} }
enum LogPrivacy { case `public` }
struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    init(stringLiteral value: String) {}
    init(stringInterpolation: StringInterpolation) {}
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy) {}
    }
}
struct TestLogger { func log(_ message: LogMessage) {} }

// Deliberately stores work without starting a thread, sleeping or running a real queue.
final class DispatchWorkItem {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func perform() { body() }
}
final class RecordedQueue {
    var work: [DispatchWorkItem] = []
    func asyncAfter(deadline: DispatchTime, execute: DispatchWorkItem) { work.append(execute) }
    func runFirst() { work.removeFirst().perform() }
}

final class Controller {
    var storedHandle: OpaquePointer? = liveHandle
    var scriptedReads: [OpaquePointer?]?
    var mpvReads = 0
    var mpv: OpaquePointer! {
        get {
            let index = mpvReads
            mpvReads += 1
            if let scriptedReads {
                precondition(!scriptedReads.isEmpty)
                return scriptedReads[min(index, scriptedReads.count - 1)]
            }
            return storedHandle
        }
        set { storedHandle = newValue }
    }
    let queue = RecordedQueue()
    let mpvLog = TestLogger()
    var cacheReadaheadRampGeneration: UInt64 = 1
    var userSeekedSinceRampSample = false
    var cacheReadaheadRampLastFrameDrop = 7
    var cacheReadaheadRampStartSecs = 60
    var cacheReadaheadRampAppliedSecs = 60
    var cacheReadaheadRampWork: DispatchWorkItem?
    static let diskCacheReadaheadRampMaxReadaheadBytes: Int64 = 8 << 30
    static let diskCacheReadaheadRampBitrateFloorSecs = 300
    static let diskCacheReadaheadRampStepSecs = 60
    static let diskCacheReadaheadRampDropTolerance = 2
    static let diskCacheReadaheadRampBurstDropThreshold = 6
    static let diskCacheReadaheadRampIntervalSecs: TimeInterval = 15

__PRODUCTION_METHODS__

    func readDouble() -> Double { getDouble("value") }
    func readString() -> String? { getString("value") }
    func readFlag() -> Bool { getFlag("value") }
    func readInt() -> Int { getInt("value") }
    func writeFlag(_ value: Bool) -> Bool { setFlag("value", value) }
    func writeString() { setString("value", "written") }
    func scheduleRamp(generation: UInt64 = 1) {
        scheduleDiskCacheReadaheadRampStep(generation: generation, ceiling: 120)
    }
__BORROW_WRAPPERS__
}

enum Value: Equatable {
    case double(Double), string(String?), flag(Bool), integer(Int), nothing
}
var failures: [String] = []
var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if !condition() { failures.append(name); print("FAIL \(name)") }
}
func fresh() -> Controller { native = NativeState(); return Controller() }
let operations: [(String, (Controller) -> Value, Value)] = [
    ("getDouble", { .double($0.readDouble()) }, .double(0)),
    ("getString", { .string($0.readString()) }, .string(nil)),
    ("getFlag", { .flag($0.readFlag()) }, .flag(false)),
    ("getInt", { .integer($0.readInt()) }, .integer(0)),
    ("setFlag", { .flag($0.writeFlag(true)) }, .flag(false)),
    ("setString", { $0.writeString(); return .nothing }, .nothing)
]
for (name, operation, _) in operations {
    let c = fresh(); c.scriptedReads = [liveHandle, nil]
    _ = operation(c)
    check("single-read.\(name)", c.mpvReads == 1 && native.calls.count == 1
          && native.calls.allSatisfy { $0.handle == liveHandle })
}
for (name, operation, stoppedValue) in operations {
    let c = fresh(); c.storedHandle = nil
    let result = operation(c)
    check("stopped.\(name)", result == stoppedValue && c.mpvReads == 1 && native.calls.isEmpty)
}

do {
    let c = fresh(); native.status = -7; native.writeReadValue = false
    check("semantics.zero-on-unwritten-error", c.readDouble() == 0 && c.readInt() == 0 && !c.readFlag())
}
do {
    let c = fresh(); native.status = -7
    check("semantics.raw-value-on-error", c.readDouble() == 2.5 && c.readInt() == 7 && c.readFlag())
}
do {
    let c = fresh(); native.flagValue = 2
    let positive = c.readFlag(); native.flagValue = -1
    check("semantics.positive-flag-only", positive && !c.readFlag())
}
do {
    let c = fresh(); let accepted = c.writeFlag(true); native.status = -7
    let refused = c.writeFlag(false)
    check("semantics.flag-write-status-width", accepted && !refused
          && native.calls.map { $0.writtenFlag } == [Int32(1), Int32(0)]
          && native.calls.allSatisfy { $0.format == MPV_FORMAT_FLAG })
}
do {
    let c = fresh(); native.stringValue = ""
    check("semantics.empty-string-free", c.readString() == "" && native.freeCalls == 1 && native.allocated == 1)
}
do {
    let c = fresh(); native.stringValue = nil
    check("semantics.nil-string-free", c.readString() == nil && native.freeCalls == 1 && native.nilFreeCalls == 1)
}
do {
    let c = fresh()
    check("semantics.string-copy-free", c.readString() == "value" && native.freeCalls == 1 && native.allocated == 1)
}
do {
    let c = fresh(); native.doubleValue = .nan
    check("semantics.nan-preserved", c.readDouble().isNaN)
}

let borrowed: [(String, (Controller) -> Void)] = [
    ("getString", { _ = $0.borrowedString(liveHandle) }),
    ("getInt", { _ = $0.borrowedInt(liveHandle) }),
    ("getFlag", { _ = $0.borrowedFlag(liveHandle) }),
    ("setString", { $0.borrowedSetString(liveHandle) }),
    ("probe", { $0.borrowedProbe(liveHandle) })
]
for (name, operation) in borrowed {
    let c = fresh(); c.storedHandle = nil
    native.intValue = 1; native.stringValue = "video"
    operation(c)
    check("borrowed.\(name)", c.mpvReads == 0 && !native.calls.isEmpty
          && native.calls.allSatisfy { $0.handle == liveHandle })
}

do {
    let c = fresh(); c.scheduleRamp(); let readsAtEnqueue = c.mpvReads
    c.storedHandle = nil; c.queue.runFirst()
    check("ramp.stop-before-work", readsAtEnqueue == 0 && c.mpvReads == 1 && native.calls.isEmpty)
}
do {
    let c = fresh(); c.scheduleRamp(generation: 0); c.queue.runFirst()
    check("ramp.stale-generation", native.calls.isEmpty && c.cacheReadaheadRampAppliedSecs == 60)
}
for backoff in [false, true] {
    let c = fresh(); c.scriptedReads = [liveHandle, nil]
    native.doubleValue = 0; native.flagValue = 0
    if backoff { c.cacheReadaheadRampAppliedSecs = 180; c.cacheReadaheadRampLastFrameDrop = 0; native.intValue = 10 }
    c.scheduleRamp(); let readsAtEnqueue = c.mpvReads; c.queue.runFirst()
    check("ramp.\(backoff ? "backoff" : "growth")-one-admission",
          readsAtEnqueue == 0 && c.mpvReads == 1 && native.calls.count == 5
          && native.calls.allSatisfy { $0.handle == liveHandle }
          && native.calls.last?.writtenString == "120"
          && c.cacheReadaheadRampAppliedSecs == 120 && c.queue.work.isEmpty)
}
print("CHECKS=\(checks) FAILURES=\(failures.count)")
exit(failures.isEmpty ? 0 : 1)
