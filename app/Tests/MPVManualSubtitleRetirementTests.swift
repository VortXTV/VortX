import Foundation
import Dispatch
import Darwin
import os

// Filled by the maintained runner from the selected actual source, never a guard model.
// @source:models
// @source:properties

private final class NativePort: Sendable {
    struct Snapshot: Sendable {
        var properties: [String: String] = [:]
        var writes: [String] = []
        var commands: [[String]] = []
        var commandStatus: Int32 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    var snapshot: Snapshot { state.withLock { $0 } }
    func set(_ name: String, _ value: String) {
        state.withLock { $0.properties[name] = value; $0.writes.append(name + "=" + value) }
    }
    func command(_ arguments: [String]) -> Int32 {
        state.withLock {
            $0.commands.append(arguments)
            if $0.commandStatus >= 0 { $0.properties[MPVProperty.sid] = "external:" + (arguments.dropFirst().first ?? "") }
            return $0.commandStatus
        }
    }
    func rejectCommands() { state.withLock { $0.commandStatus = -1 } }
}

// No raw pointer is stored or marked Sendable: each synchronous borrow constructs an inert
// identifier locally. The fake C entrypoint resolves it to owned, checked recorder state.
private enum NativeRegistry {
    private struct State: Sendable { var next: UInt = 1; var ports: [UInt: NativePort] = [:] }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static func register(_ port: NativePort) -> UInt {
        state.withLock { let id = $0.next; $0.next += 1; $0.ports[id] = port; return id }
    }
    static func port(_ handle: OpaquePointer) -> NativePort {
        let identifier = UInt(bitPattern: handle)
        return state.withLock { $0.ports[identifier]! }
    }
}

private final class MPVNativeHandle: Sendable {
    private let id: UInt
    private let queue: DispatchQueue
    private let retirement = OSAllocatedUnfairLock(initialState: false)
    init(port: NativePort, queue: DispatchQueue) { id = NativeRegistry.register(port); self.queue = queue }
    var isRetired: Bool { retirement.withLock { $0 } }
    func retire() { retirement.withLock { $0 = true } }
    func withBorrow<Result: Sendable>(_ body: (OpaquePointer) -> Result) -> Result? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isRetired else { return nil }
        return body(OpaquePointer(bitPattern: id)!)
    }
}

private func mpv_command(_ handle: OpaquePointer, _ arguments: inout [UnsafePointer<CChar>?]) -> Int32 {
    var owned: [String] = []
    for argument in arguments { guard let argument else { break }; owned.append(String(cString: argument)) }
    precondition(owned.first == "sub-add" && owned.count == 5)
    return NativeRegistry.port(handle).command(owned)
}

// These nullable collaborators admit the actual current scalar take/cleanup methods.
// This fixture never mounts a renderer or starts an alignment extraction: invoking
// either boundary would exceed its manual-selection/final-apply scope and must fail.
private enum SubtitleEmbeddedExtractor {
    struct TimingWindowCancellation: Sendable {
        func cancel() { preconditionFailure("Alignment extraction is outside this fixture") }
    }
}
private final class MPVRemoteReferenceCancellation: Sendable {
    func cancel() { preconditionFailure("Remote reading is outside this nil-collaborator manual fixture") }
}
private enum CredentialPublicationOutbox {
    struct SubtitleRendererRegistration: Sendable {}
    static func unregisterSubtitleRenderer(_ registration: SubtitleRendererRegistration) {
        preconditionFailure("Mounted renderer cleanup is outside this fixture")
    }
}
private struct MPVAlignedSubtitleRecord: Sendable {}

// @source:native

private final class QueueGate: Sendable {
    private struct State: Sendable { var entered = false; var continuation: CheckedContinuation<Void, Never>? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let release = DispatchSemaphore(value: 0)
    func enterAndWait() {
        let continuation = state.withLock { value -> CheckedContinuation<Void, Never>? in
            value.entered = true; defer { value.continuation = nil }; return value.continuation
        }
        continuation?.resume()
        precondition(release.wait(timeout: .now() + 5) == .success, "Synthetic queue release timed out")
    }
    func awaitEntry() async {
        await withCheckedContinuation { continuation in
            let entered = state.withLock {
                if $0.entered { return true }
                precondition($0.continuation == nil); $0.continuation = continuation; return false
            }
            if entered { continuation.resume() }
        }
    }
    func open() { release.signal() }
}

private struct PendingSubtitle: Sendable {
    let file: URL
    let title: String
    let language: String
    let context: MPVNativeHandle
    let token: PlayerLoadToken
    let generation: UInt64
}

@MainActor private final class MPVMetalViewController {
    private nonisolated let native = MPVNativeState()
    private nonisolated let queue = DispatchQueue(label: "vortx.synthetic.subtitle-final-apply", qos: .utility)
    private nonisolated let port = NativePort()
    private(set) var secondarySubtitleID = -1
// @source:accessors
// @source:alignmentAccessor
// @source:alignmentTake
// @source:alignmentRetire
// @source:primary
// @source:secondary
// @source:apply
// @source:arguments
// @source:delay
// @source:enqueueManualSubtitleProperty
// @source:mountLocalExternalSubtitle

    init() { replaceLoad() }
    private func setString(_ name: String, _ value: String) { port.set(name, value) }
    // The maintained source now queues scalar writes and the extracted source calls this
    // handle overload. Keep the fake recorder synchronous and queue-owned; it must not bypass
    // the actual source's load/context guard or invent a new selection generation.
    private nonisolated func setString(_ name: String, _ value: String, handle: OpaquePointer) {
        NativeRegistry.port(handle).set(name, value)
    }
    private nonisolated func checkError(_ status: Int32) { _ = status }
    var snapshot: NativePort.Snapshot { port.snapshot }
    func replaceLoad() {
        let token = PlayerLoadToken()
        native.update {
            $0.loadProvenance.invalidate()
            $0.loadProvenance.registerRequest(entryID: 1, token: token)
            $0.loadProvenance.bindStart(entryID: 1)
            $0.loadProvenance.markFileLoaded()
        }
        if nativeContext == nil { replaceContext() }
    }
    func replaceContext() {
        let context = MPVNativeHandle(port: port, queue: queue)
        native.update { $0.context = context }
    }
    func retireContext() { nativeContext?.retire() }
    func clearContext() { native.update { $0.context = nil } }
    func rejectCommands() { port.rejectCommands() }
    func settleQueue() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    var requestGeneration: UInt64 { native.read { $0.externalSubtitleRequestGeneration } }
#if VORTX_CURRENT_ALIGNMENT
    var alignmentGeneration: UInt64 {
        guard let revision = subtitleAlignmentRevision else { preconditionFailure("Concrete MPV lost its capability") }
        return revision
    }
#endif
    func capturePending(_ name: String) -> PendingSubtitle {
        guard let token = loadProvenance.activeToken, let context = nativeContext else { preconditionFailure("Missing synthetic native owner") }
        // Request metadata/networking are synthetic; reservation, selection, timing and final admission
        // are selected actual source, including both independent request/alignment fields.
        // @source:requestIntent
        return PendingSubtitle(file: URL(fileURLWithPath: "/synthetic/" + name + ".srt"), title: name,
                               language: "eng", context: context, token: token, generation: requestGeneration)
    }
    nonisolated func complete(_ pending: PendingSubtitle, gate: QueueGate? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                gate?.enterAndWait() // outside the native transaction; MainActor remains runnable.
                continuation.resume(returning: applyExternalSubtitle(pending.file, title: pending.title,
                    lang: pending.language, context: pending.context, loadToken: pending.token,
                    requestGeneration: pending.generation))
            }
        }
    }
}

@main @MainActor private enum MPVManualSubtitleRetirementTests {
    private static var checks = 0
    private static var failures = 0
    private static func check(_ condition: Bool, _ name: String) {
        checks += 1
        print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }
    private static func lateApplyAfterSelection(_ id: Int, name: String) async {
        let controller = MPVMetalViewController()
        let pending = controller.capturePending(name)
        let gate = QueueGate()
        let completion = Task { await controller.complete(pending, gate: gate) }
        await gate.awaitEntry()
        controller.setSubtitleTrack(id)
        gate.open()
        let accepted = await completion.value
        await controller.settleQueue()
        check(!accepted, name + ": queued external is retired by the actual manual setter")
        check(controller.snapshot.commands.isEmpty, name + ": stale result never issues sub-add")
        check(controller.snapshot.properties[MPVProperty.sid] == (id < 0 ? "no" : String(id)), name + ": manual property remains final")
    }
    static func main() async {
        await lateApplyAfterSelection(-1, name: "pending-then-Off")
        await lateApplyAfterSelection(8, name: "pending-then-embedded")
#if VORTX_CURRENT_ALIGNMENT
        do {
            let controller = MPVMetalViewController()
            let original = controller.alignmentGeneration
            let pending = controller.capturePending("timing-independent")
            let requested = controller.alignmentGeneration
            let request = controller.requestGeneration
            check(requested != original, "external intent retires the original alignment")
            controller.setSubDelay(1.25)
            await controller.settleQueue()
            let delayed = controller.alignmentGeneration
            check(delayed != requested, "manual delay retires prepared alignment")
            check(controller.requestGeneration == request, "manual delay preserves pending download authority")
            check(controller.snapshot.properties["sub-delay"] == "1.25", "delay retains existing native seconds and formatting")
            check(await controller.complete(pending), "pending subtitle still applies after a timing edit")
            check(controller.alignmentGeneration != delayed, "admitted file retires preparation captured during download")
        }
        do {
            let controller = MPVMetalViewController()
            let pending = controller.capturePending("secondary-independent")
            let original = controller.alignmentGeneration
            let request = controller.requestGeneration
            controller.setSecondarySubtitleTrack(7)
            check(controller.alignmentGeneration != original, "secondary selection retires prepared alignment")
            check(controller.requestGeneration == request, "secondary selection preserves download authority")
            check(await controller.complete(pending), "pending subtitle survives a secondary selection")
        }
        do {
            let controller = MPVMetalViewController()
            controller.setSubtitleTrack(3)
            let original = controller.alignmentGeneration
            controller.setSubtitleTrack(8)
            let middle = controller.alignmentGeneration
            controller.setSubtitleTrack(3)
            let final = controller.alignmentGeneration
            check(final != original && middle != original && final != middle,
                  "same-track ABA cannot revive original alignment")
            let beforeOff = controller.alignmentGeneration
            controller.setSubtitleTrack(-1)
            check(controller.alignmentGeneration != beforeOff, "Off retires alignment")
            let stale = controller.capturePending("denied-external")
            controller.setSubtitleTrack(4)
            let afterSelection = controller.alignmentGeneration
            check(!(await controller.complete(stale)), "manual selection still denies stale download")
            check(controller.alignmentGeneration == afterSelection, "denied completion cannot mutate alignment authority")
        }
#endif
        do {
            let controller = MPVMetalViewController()
            controller.setSubtitleTrack(3)
            let pending = controller.capturePending("ABA-original")
            controller.setSubtitleTrack(8)
            controller.setSubtitleTrack(3)
            let accepted = await controller.complete(pending)
            await controller.settleQueue()
            check(!accepted, "A-to-B-to-A manual selection retires the original generation")
            check(controller.snapshot.commands.isEmpty && controller.snapshot.properties[MPVProperty.sid] == "3", "ABA cannot be mistaken for an unchanged selection")
        }
        do {
            let controller = MPVMetalViewController()
            let first = controller.capturePending("external-A")
            let latest = controller.capturePending("external-B")
            check(!(await controller.complete(first)), "superseded external request is denied")
            check(await controller.complete(latest), "latest external request is accepted")
            check(controller.snapshot.commands.map { $0[1] } == [latest.file.path], "only the latest external file is issued")
        }
        do {
            let controller = MPVMetalViewController()
            let firstA = controller.capturePending("same-A")
            let middleB = controller.capturePending("middle-B")
            let lastA = controller.capturePending("same-A")
            let firstAccepted = await controller.complete(firstA)
            let middleAccepted = await controller.complete(middleB)
            check(!firstAccepted && !middleAccepted, "external A-to-B-to-A denies both older requests")
            check(await controller.complete(lastA), "external A-to-B-to-A accepts the newest A generation")
        }
        do {
            let controller = MPVMetalViewController()
            let pending = controller.capturePending("normal")
            check(await controller.complete(pending), "same-load request without intervening selection succeeds")
            check(controller.snapshot.commands == [["sub-add", pending.file.path, "select", "normal", "eng"]], "actual makeCArgs and strdup/free path preserve selection/title/language")
            controller.setSubtitleTrack(11)
            await controller.settleQueue()
            check(controller.snapshot.properties[MPVProperty.sid] == "11", "manual choice after an earlier admitted external remains final")
            let fresh = controller.capturePending("after-manual")
            check(await controller.complete(fresh), "a genuinely newer external request can supersede the manual choice")
        }
        do {
            let controller = MPVMetalViewController()
            let pending = controller.capturePending("old-load")
            controller.replaceLoad()
            check(!(await controller.complete(pending)), "old logical load is denied even with the same context and request generation")
            check(controller.snapshot.commands.isEmpty, "old load emits no native command")
        }
        do {
            let controller = MPVMetalViewController()
            let pending = controller.capturePending("old-context")
            controller.replaceContext()
            check(!(await controller.complete(pending)), "replaced native context cannot attach its pending file")
            check(controller.snapshot.commands.isEmpty, "replaced context emits no native command")
        }
        do {
            let controller = MPVMetalViewController()
            let pending = controller.capturePending("retired-context")
            controller.retireContext()
            check(!(await controller.complete(pending)) && controller.snapshot.commands.isEmpty, "retired native owner refuses the borrow")
        }
        do {
            let controller = MPVMetalViewController()
            let pending = controller.capturePending("cleared-context")
            controller.clearContext()
            check(!(await controller.complete(pending)) && controller.snapshot.commands.isEmpty, "cleared native context denies a late result")
        }
        do {
            let controller = MPVMetalViewController()
            controller.setSecondarySubtitleTrack(7)
            controller.setSubtitleTrack(7)
            await controller.settleQueue()
            check(controller.secondarySubtitleID == -1, "primary matching secondary clears the overlapping slot")
            check(controller.snapshot.writes == ["secondary-sid=7", "secondary-sub-pos=0", "secondary-sid=no", "sid=7"], "secondary clear occurs before the retained primary property write")
            controller.setSecondarySubtitleTrack(9)
            controller.setSubtitleTrack(4)
            await controller.settleQueue()
            check(controller.secondarySubtitleID == 9 && controller.snapshot.properties[MPVProperty.secondarySid] == "9", "nonoverlapping secondary selection is retained")
            controller.setSubtitleTrack(-1)
            await controller.settleQueue()
            check(controller.snapshot.properties[MPVProperty.sid] == "no", "Off still writes the literal no property")
        }
        do {
            let controller = MPVMetalViewController()
            let pending = controller.capturePending("native-rejection")
            controller.rejectCommands()
            check(!(await controller.complete(pending)), "native command failure remains a failed apply")
            check(controller.snapshot.commands.count == 1, "native failure is not confused with stale-admission rejection")
        }
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
