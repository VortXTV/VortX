import Foundation
import CoreGraphics

// Inert transport/timer/image/clock collaborators. The actual Network-importing production adapter,
// actual policy and actual fixed page are direct compiler inputs, without body copying/rewrites.
// No production listener factory, OS timer, CSPRNG, account client, native ABI or live file is executed.
private final class FakeTimer: ProfilePickerToolsLANTimer, @unchecked Sendable {
    private let queue: DispatchQueue
    private let tick: @Sendable () -> Void
    private let cancelled: @Sendable () -> Void
    private let lock = NSLock()
    private var requested = 0
    init(queue: DispatchQueue, tick: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void) {
        self.queue = queue; self.tick = tick; self.cancelled = cancelled
    }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return requested }
    func cancel() { lock.lock(); requested += 1; lock.unlock() }
    func fire() { queue.async(execute: tick) }
    func acknowledgeCancellation() { queue.async(execute: cancelled) }
}
private final class FakeListener: ProfilePickerToolsLANListener, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var callback: (@Sendable (ProfilePickerToolsLANListenerState) -> Void)?
    private var incoming: (@Sendable (any ProfilePickerToolsLANConnection) -> Void)?
    private var requested = 0
    private var startsValue = 0
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return requested }
    var starts: Int { lock.lock(); defer { lock.unlock() }; return startsValue }
    func start(queue: DispatchQueue, state: @escaping @Sendable (ProfilePickerToolsLANListenerState) -> Void,
               connection: @escaping @Sendable (any ProfilePickerToolsLANConnection) -> Void) {
        lock.lock(); self.queue = queue; callback = state; incoming = connection; startsValue += 1; lock.unlock()
    }
    func cancel() { lock.lock(); requested += 1; lock.unlock() }
    func emit(_ state: ProfilePickerToolsLANListenerState) {
        lock.lock(); let queue = queue, callback = callback; lock.unlock()
        if let queue, let callback { queue.async { callback(state) } }
    }
    func accept(_ driver: FakeConnection) {
        lock.lock(); let queue = queue, incoming = incoming; lock.unlock()
        if let queue, let incoming { queue.async { incoming(driver) } }
    }
}
private final class FakeConnection: ProfilePickerToolsLANConnection, @unchecked Sendable {
    struct Sent { let bytes: Data; let final: Bool }
    private struct Read { let maximum: Int; let callback: @Sendable (Data?, Bool, Bool) -> Void; var returned = false }
    private struct Write { let callback: @Sendable (Bool) -> Void; var returned = false }
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var state: (@Sendable (ProfilePickerToolsLANConnectionState) -> Void)?
    private var reads: [Read] = []
    private var writes: [Write] = []
    private var sentValue: [Sent] = []
    private var requested = 0
    private var started = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads.count }
    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return writes.count }
    var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return sentValue }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return requested }
    var starts: Int { lock.lock(); defer { lock.unlock() }; return started }
    func start(queue: DispatchQueue, state: @escaping @Sendable (ProfilePickerToolsLANConnectionState) -> Void) {
        lock.lock(); self.queue = queue; self.state = state; started += 1; lock.unlock()
    }
    func receive(maximum: Int, completion: @escaping @Sendable (Data?, Bool, Bool) -> Void) {
        precondition(maximum > 0 && maximum <= 65_536)
        lock.lock(); reads.append(Read(maximum: maximum, callback: completion)); lock.unlock()
    }
    func send(_ bytes: Data, final: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); sentValue.append(Sent(bytes: bytes, final: final)); writes.append(Write(callback: completion)); lock.unlock()
    }
    func cancel() { lock.lock(); requested += 1; lock.unlock() }
    func reply(_ index: Int, _ bytes: Data?, eof: Bool = false, failed: Bool = false, duplicate: Bool = false) {
        lock.lock()
        guard reads.indices.contains(index), let queue else { lock.unlock(); preconditionFailure("missing read") }
        precondition(duplicate || !reads[index].returned)
        let callback = reads[index].callback
        if !duplicate { reads[index].returned = true }
        lock.unlock()
        // Always asynchronous, matching the actual wrapper's callback contract.
        queue.async { callback(bytes, eof, failed) }
    }
    func processed(_ index: Int, failed: Bool = false, duplicate: Bool = false) {
        lock.lock()
        guard writes.indices.contains(index), let queue else { lock.unlock(); preconditionFailure("missing send") }
        precondition(duplicate || !writes[index].returned)
        let callback = writes[index].callback
        if !duplicate { writes[index].returned = true }
        lock.unlock()
        queue.async { callback(failed) }
    }
    func acknowledgeCancelled() {
        lock.lock(); let queue = queue, state = state; lock.unlock()
        if let queue, let state { queue.async { state(.cancelled) } }
    }
    func returnAllPending() {
        lock.lock()
        let pendingReads = reads.indices.filter { !reads[$0].returned }
        let pendingWrites = writes.indices.filter { !writes[$0].returned }
        lock.unlock()
        for index in pendingReads { reply(index, nil, eof: true, failed: true) }
        for index in pendingWrites { processed(index, failed: true) }
    }
}
@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func finish() { continuation?.resume(); continuation = nil }
}
@MainActor private final class Harness {
    typealias A = ProfilePickerToolsLANTransfer
    typealias P = ProfilePickerToolsTransferPolicy
    let owner = P.Owner(sessionID: UUID(), routeID: UUID(), operationID: UUID(), credentialGeneration: UUID())
    let listener = FakeListener()
    var timer: FakeTimer!
    var adapter: A!
    var clock = 100.0
    var permitted = true
    var capabilityIndex = 0
    var token = ""
    var input: [P.ImmutableInput] = []
    var inputGate: Gate?
    var changes = 0
    var grants = 0
    var insideGrant: (() -> Void)?
    var peers: [FakeConnection] = []
    // These count ONLY external fixture callbacks, not actual account/cloud calls.
    var fixtureDownloads = 0, fixtureTakes = 0, fixtureRestores = 0
    init(_ mode: P.Mode, entropyFails: Bool = false, imageFails: Bool = false) throws {
        let dependencies = A.Dependencies(clock: { self.clock }, capability: {
            if entropyFails { throw A.Failure.entropy }
            self.capabilityIndex += 1
            self.token = String(repeating: "0", count: 62) + String(format: "%02x", self.capabilityIndex)
            return try P.Capability(hex: self.token)
        }, ipv4: { "192.168.1.7" }, qr: { _ in imageFails ? nil : Self.pixel() }, listener: { self.listener },
        timer: { queue, tick, cancelled in
            let timer = FakeTimer(queue: queue, tick: tick, cancelled: cancelled); self.timer = timer; return timer
        })
        let inputHandling: A.InputHandling = mode == .download ? .notAccepted : .receive { value in
            self.input.append(value)
            if let inputGate = self.inputGate { await inputGate.wait() }
        }
        adapter = try A(owner: owner, mode: mode, liveGrant: { owner in
            self.grants += 1; self.insideGrant?()
            return self.permitted && owner == self.owner
        }, input: inputHandling, onChange: { owner in precondition(owner == self.owner); self.changes += 1 }, dependencies: dependencies)
    }
    static func pixel() -> CGImage? {
        let data = Data([0, 0, 0, 255]) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    func startReady() async throws {
        try adapter.start(); listener.emit(.ready(40_000))
        await Runner.until { self.adapter.publication != nil }
    }
    func peer() async -> FakeConnection {
        let connection = FakeConnection(); peers.append(connection); listener.accept(connection)
        await Runner.until { connection.readCount == 1 }; return connection
    }
    func head(_ path: String, token: String? = nil, length: Int? = nil) -> Data {
        let auth = path == "/" ? "" : "Authorization: Bearer \(token ?? self.token)\r\n"
        let body = length.map { "Origin: http://192.168.1.7:40000\r\nContent-Type: application/octet-stream\r\nContent-Length: \($0)\r\n" } ?? ""
        return Data("\(length == nil ? "GET" : "POST") \(path) HTTP/1.1\r\nHost: 192.168.1.7:40000\r\n\(auth)\(body)\r\n".utf8)
    }
    func retireAndReturnNetwork() {
        adapter.retire()
        if listener.starts > 0 { listener.emit(.cancelled) }
        timer.acknowledgeCancellation()
        for peer in peers where peer.starts > 0 { peer.returnAllPending(); peer.acknowledgeCancelled() }
    }
    func finish() async {
        retireAndReturnNetwork()
        await Runner.until { self.adapter.isDrained }
    }
}
@main @MainActor private enum Runner {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) {
        precondition(value, label); checks += 1; print("PASS \(label)")
    }
    static func until(_ predicate: @MainActor () -> Bool) async {
        let limit = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < limit { await Task.yield() }
        precondition(predicate(), "fixture boundary did not settle")
    }
    static func main() async throws {
        do {
            do { _ = try Harness(.download, entropyFails: true); preconditionFailure("entropy accepted") }
            catch { check(true, "injected entropy-provider failure stops before listener/timer/publication") }
        }
        do {
            let h = try Harness(.download)
            try h.adapter.start(); h.adapter.retire(); h.listener.emit(.ready(40_000))
            await until { h.listener.cancels > 0 }
            check(h.adapter.publication == nil && !h.adapter.isDrained, "queued ready cannot publish after cancellation or fake drain")
            h.retireAndReturnNetwork(); await until { h.adapter.isDrained }
            check(h.adapter.publication == nil, "real listener/timer callbacks complete cold-start cancellation")
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            let page = await h.peer(); page.reply(0, h.head("/"))
            await until { page.sendCount == 1 }
            check(String(decoding: page.sent[0].bytes, as: UTF8.self).contains("Content-Security-Policy:"),
                  "public bootstrap needs no Authorization and uses actual fixed CSP page response")
            page.processed(0); await until { page.readCount == 2 }
            h.adapter.retire(); page.acknowledgeCancelled(); h.listener.emit(.cancelled); h.timer.acknowledgeCancellation()
            await Task.yield()
            check(!h.adapter.isDrained, "terminal cancel alone cannot hide an outstanding receive")
            page.reply(1, nil, eof: true, failed: true); await until { h.adapter.isDrained }
        }
        do {
            let h = try Harness(.restore); try await h.startReady()
            let peer = await h.peer(); h.permitted = false
            var bytes = h.head("/input", length: 3); bytes.append(Data([1, 2, 3])); peer.reply(0, bytes)
            await until { peer.cancels > 0 }
            check(h.input.isEmpty && peer.sendCount == 0, "revoked original grant forbids coalesced input append/commit/response")
            await h.finish()
        }
        do {
            let h = try Harness(.repair); try await h.startReady()
            let peer = await h.peer(); var body = h.head("/input", length: 1); body.append(Data([1, 2])); peer.reply(0, body)
            await until { peer.cancels > 0 }
            check(h.input.isEmpty && !h.adapter.hasOwnedWork && peer.sendCount == 0,
                  "coalesced extra body byte is rejected before any immutable-input delivery or service work")
            await h.finish()
        }
        do {
            let h = try Harness(.repair); try await h.startReady()
            let peer = await h.peer()
            var first = h.head("/input", length: 4); first.append(Data([1, 2])); peer.reply(0, first)
            await until { peer.readCount == 2 }; h.permitted = false; peer.reply(1, Data([3, 4]))
            await until { peer.cancels > 0 }
            check(h.input.isEmpty, "mid-upload revocation forbids the later append and completed input callback")
            await h.finish()
        }
        do {
            let h = try Harness(.repair); try await h.startReady()
            let candidates = [FakeConnection(), FakeConnection(), FakeConnection(), FakeConnection(), FakeConnection()]
            h.peers = candidates
            for connection in candidates { h.listener.accept(connection) }
            await until { candidates.filter { $0.readCount == 1 }.count == 4 && candidates.filter { $0.cancels > 0 }.count == 1 }
            let accepted = candidates.filter { $0.readCount == 1 }
            for connection in accepted { connection.reply(0, h.head("/input", length: 4)) }
            await until { accepted.filter { $0.readCount == 2 }.count == 1 && accepted.filter { $0.cancels > 0 }.count == 3 }
            let winner = accepted.first { $0.readCount == 2 }!
            check(accepted.filter { $0.readCount == 2 }.count == 1 && h.input.isEmpty,
                  "four contenders allocate one input attempt before body; fifth connection is rejected unstarted")
            winner.reply(1, Data([9, 8, 7, 6]))
            await until { h.input.count == 1 }
            check(h.input[0].bytes == Data([9, 8, 7, 6]) && h.input[0].owner == h.owner,
                  "only exact original immutable bytes are delivered once to original callback")
            winner.reply(1, Data([0, 0, 0, 0]), duplicate: true)
            for _ in 0..<30 { await Task.yield() }
            check(h.input.count == 1, "duplicate stale receive cannot deliver input again")
            await h.finish()
        }
        do {
            let h = try Harness(.repair); try await h.startReady()
            let first = await h.peer(); var bytes = h.head("/input", length: 4); bytes.append(Data([1, 2]))
            first.reply(0, bytes); await until { first.readCount == 2 }
            first.reply(1, nil, eof: true); await until { first.cancels > 0 }
            do { try h.adapter.retryInput(owner: h.owner); preconditionFailure("partial retry before drain") }
            catch { check(true, "failed partial upload cannot release its claim just by calling cancel") }
            first.acknowledgeCancelled()
            var retried = false
            let limit = ContinuousClock.now + .seconds(5)
            while !retried, ContinuousClock.now < limit {
                do { try h.adapter.retryInput(owner: h.owner); retried = true }
                catch { await Task.yield() }
            }
            check(retried, "exact partial-input callback/cancel drain enables explicit TV retry")
            let second = await h.peer(); second.reply(0, h.head("/input", length: 3)); await until { second.readCount == 2 }
            first.reply(1, nil, eof: true, duplicate: true)
            for _ in 0..<30 { await Task.yield() }
            second.reply(1, Data([7, 8, 9])); await until { h.input.count == 1 }
            check(h.input[0].bytes == Data([7, 8, 9]), "stale failed-input release cannot cancel or replace successor upload")
            await h.finish()
        }
        do {
            let h = try Harness(.repair); let gate = Gate(); h.inputGate = gate; try await h.startReady()
            let peer = await h.peer(); var bytes = h.head("/input", length: 1); bytes.append(0x61); peer.reply(0, bytes)
            await until { gate.entered }
            h.retireAndReturnNetwork()
            await until { !h.adapter.networkIsDrained || h.adapter.hasOwnedWork }
            check(h.adapter.hasOwnedWork && !h.adapter.isDrained, "cancel retains noncooperative input/account callback until actual return")
            gate.finish(); await until { h.adapter.isDrained }
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            let payload = Data(repeating: 0x6a, count: 65_543), snapshot = UUID()
            _ = try await h.adapter.performTVWork(owner: h.owner) { h.fixtureDownloads += 1; return 1 }
            _ = try h.adapter.installOutput(payload, snapshotID: snapshot, owner: h.owner)
            await until { !h.adapter.hasOwnedWork }
            let peer = await h.peer(); peer.reply(0, h.head("/file")); await until { peer.sendCount == 1 }
            h.permitted = false; peer.processed(0)
            await until { peer.cancels > 0 }
            check(peer.sendCount == 1, "revocation after output header forbids first deferred body chunk")
            await h.finish()
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            _ = try h.adapter.installOutput(Data(repeating: 0x61, count: 65_543), snapshotID: UUID(), owner: h.owner)
            let peer = await h.peer(); peer.reply(0, h.head("/file")); await until { peer.sendCount == 1 }
            peer.processed(0); await until { peer.sendCount == 2 }
            h.permitted = false; peer.processed(1); await until { peer.cancels > 0 }
            check(peer.sendCount == 2 && peer.sent[1].bytes.count == 65_536,
                  "one processed body chunk cannot authorize the next after live-policy revocation")
            await h.finish()
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            let payload = Data([0x61, 0x62, 0x63]), snapshot = UUID()
            _ = try await h.adapter.performTVWork(owner: h.owner) { h.fixtureDownloads += 1; return 1 }
            _ = try h.adapter.installOutput(payload, snapshotID: snapshot, owner: h.owner)
            await until { !h.adapter.hasOwnedWork }
            let originalToken = h.token, first = await h.peer()
            first.reply(0, h.head("/file")); await until { first.sendCount == 1 }
            first.processed(0); await until { first.sendCount == 2 }; first.processed(1)
            await until { h.adapter.localSendOutcome == .tvFinishedSendingCheckPhone && first.readCount == 2 }
            check(!h.adapter.isDrained, "local contentProcessed is neither browser ACK nor connection/operation drain")
            do { _ = try h.adapter.retrySameOutput(owner: h.owner); preconditionFailure("retry before drain") }
            catch { check(true, "TV retry cannot overlap outstanding peer-close receive") }
            first.reply(1, nil, eof: true); await until { first.cancels > 0 }; first.acknowledgeCancelled()
            // Retry may succeed only after actual event tickets, sends and cancellation drain.
            var retried = false
            let limit = ContinuousClock.now + .seconds(5)
            while !retried, ContinuousClock.now < limit {
                do { let info = try h.adapter.retrySameOutput(owner: h.owner); precondition(info.snapshotID == snapshot); retried = true }
                catch { await Task.yield() }
            }
            check(retried && h.token != originalToken && h.fixtureDownloads == 1 && h.fixtureTakes == 0,
                  "explicit retry remints capability for same snapshot without repeating external fixture download/take")
            let second = await h.peer(); second.reply(0, h.head("/file")); await until { second.sendCount == 1 }
            first.processed(1, duplicate: true)
            for _ in 0..<30 { await Task.yield() }
            check(second.sendCount == 1, "old output callback cannot advance or finish successor attempt")
            second.processed(0); await until { second.sendCount == 2 }
            check(second.sent[1].bytes == payload, "retry sends byte-identical original immutable snapshot")
            await h.finish()
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            let payload = Data([4, 5, 6]), snapshot = UUID()
            _ = try h.adapter.installOutput(payload, snapshotID: snapshot, owner: h.owner)
            let first = await h.peer(); first.reply(0, h.head("/file")); await until { first.sendCount == 1 }
            first.processed(0, failed: true); await until { first.cancels > 0 }
            check(h.adapter.localSendOutcome == .failedCheckPhone && h.adapter.publication == nil,
                  "actual send failure reports only local failure and hides retired attempt QR")
            first.acknowledgeCancelled()
            var retried = false
            let limit = ContinuousClock.now + .seconds(5)
            while !retried, ContinuousClock.now < limit {
                do { let info = try h.adapter.retrySameOutput(owner: h.owner); precondition(info.snapshotID == snapshot); retried = true }
                catch { await Task.yield() }
            }
            check(retried, "actual failed-send drain permits explicit retry of original installed snapshot")
            await h.finish()
        }
        do {
            let h = try Harness(.repair); try await h.startReady()
            let peer = await h.peer(); peer.reply(0, h.head("/input", length: 2)); await until { peer.readCount == 2 }
            h.clock += 16; h.timer.fire(); await until { peer.cancels > 0 }
            check(h.adapter.publication == nil && h.input.isEmpty && !h.adapter.isDrained,
                  "idle body deadline fires without incoming bytes and cannot certify pending receive drain")
            await h.finish()
        }
        do {
            let h = try Harness(.repair); try await h.startReady()
            let upload = await h.peer(); var body = h.head("/input", length: 1); body.append(0x71); upload.reply(0, body)
            await until { h.input.count == 1 && upload.sendCount == 1 }
            upload.processed(0); await until { upload.readCount == 2 }
            upload.reply(1, nil, eof: true); await until { upload.cancels > 0 }; upload.acknowledgeCancelled()
            await until { h.adapter.attemptsAreDrained }
            try h.adapter.showReview(owner: h.owner)
            let payload = try await h.adapter.performTVWork(owner: h.owner) { h.fixtureTakes += 1; return Data([1, 4, 9]) }
            let snapshot = UUID(); _ = try h.adapter.installOutput(payload, snapshotID: snapshot, owner: h.owner)
            await until { !h.adapter.hasOwnedWork }
            let output = await h.peer(); output.reply(0, h.head("/file")); await until { output.sendCount == 1 }
            output.processed(0, failed: true); await until { output.cancels > 0 }; output.acknowledgeCancelled()
            await until { h.adapter.attemptsAreDrained }
            let info = try h.adapter.retrySameOutput(owner: h.owner)
            check(info.snapshotID == snapshot && h.fixtureTakes == 1 && h.fixtureDownloads == 0,
                  "Repair retry retains one externally supplied fixture take and immutable snapshot after exact drain")
            await h.finish()
        }
        do {
            let h = try Harness(.restore); try await h.startReady()
            let upload = await h.peer(); var body = h.head("/input", length: 1); body.append(0x61); upload.reply(0, body)
            await until { h.input.count == 1 && !h.adapter.hasOwnedWork }
            try h.adapter.showReview(owner: h.owner)
            try h.adapter.closeNetworkForRestore(owner: h.owner)
            check(h.fixtureRestores == 0 && !h.adapter.networkIsDrained,
                  "received Restore bytes and requested cancel cannot initiate or prove readiness for a cloud action")
            h.listener.emit(.cancelled); upload.returnAllPending(); upload.acknowledgeCancelled()
            await until { h.adapter.networkIsDrained }
            _ = try await h.adapter.performTVWork(owner: h.owner) { h.fixtureRestores += 1; return 1 }
            check(h.fixtureRestores == 1 && !h.adapter.isDrained,
                  "only original TV-owned callback runs after actual network drain; deadline/work lifecycle remains owned")
            await h.finish()
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            let gate = Gate()
            let task = Task { try await h.adapter.performTVWork(owner: h.owner) { await gate.wait(); return 1 } }
            await until { gate.entered }; h.retireAndReturnNetwork()
            check(h.adapter.hasOwnedWork && !h.adapter.isDrained, "generic TV work lease survives cancellation until original provider returns")
            gate.finish(); _ = try? await task.value; await until { h.adapter.isDrained }
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await h.adapter.performTVWork(owner: h.owner) { h.fixtureDownloads += 1; return 1 }
            }
            _ = try? await task.value
            check(h.fixtureDownloads == 0 && !h.adapter.hasOwnedWork,
                  "already-cancelled TV caller cannot enter original account work")
            await h.finish()
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            h.insideGrant = { h.adapter.revokeNow() }
            do { _ = try h.adapter.installOutput(Data([1]), snapshotID: UUID(), owner: h.owner); preconditionFailure("reentrant revoke") }
            catch { check(true, "original grant can revoke synchronously without lock reentrancy or an open default") }
            h.insideGrant = nil; await h.finish()
        }
        do {
            let h = try Harness(.download); try await h.startReady()
            h.clock += 301; h.timer.fire(); await until { h.adapter.publication == nil }
            check(!h.adapter.isDrained, "expiry hides QR/revokes immediately but waits for actual timer/listener acknowledgments")
            await h.finish()
        }
        print("LAN_ADAPTER_ASSERTIONS=\(checks)")
        print("LAN_ADAPTER_CALLBACKS_PASS")
    }
}
