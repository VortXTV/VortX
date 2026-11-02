import Foundation
import Network
import Security
import CoreImage
import Darwin

// Network collaborators are deliberately small. Production drivers use ONE serial callback queue.
// Every callback MUST be asynchronous on that queue, never inline in start/receive/send/cancel.
// Production wrappers normalize completions onto it; the inert fixture enforces the same contract.
// The fixture supplies inert drivers; it compiles this actual file and executes these actual methods.
protocol ProfilePickerToolsLANConnection: AnyObject, Sendable {
    func start(queue: DispatchQueue, state: @escaping @Sendable (ProfilePickerToolsLANConnectionState) -> Void)
    func receive(maximum: Int, completion: @escaping @Sendable (Data?, Bool, Bool) -> Void)
    func send(_ bytes: Data, final: Bool, completion: @escaping @Sendable (Bool) -> Void)
    func cancel()
}
enum ProfilePickerToolsLANConnectionState: Sendable { case ready, failed, cancelled }
protocol ProfilePickerToolsLANListener: AnyObject, Sendable {
    func start(queue: DispatchQueue,
               state: @escaping @Sendable (ProfilePickerToolsLANListenerState) -> Void,
               connection: @escaping @Sendable (any ProfilePickerToolsLANConnection) -> Void)
    func cancel()
}
enum ProfilePickerToolsLANListenerState: Sendable { case ready(UInt16), failed, cancelled }
protocol ProfilePickerToolsLANTimer: AnyObject, Sendable { func cancel() }

/// One original Tools/action owner. No account, keychain, native ABI, file URL or cloud API exists here.
/// A grant must be a synchronous, bounded MainActor admission read. It must not perform account work.
@MainActor
final class ProfilePickerToolsLANTransfer {
    typealias P = ProfilePickerToolsTransferPolicy
    typealias Page = ProfilePickerToolsTransferPhonePage
    typealias Grant = @MainActor @Sendable (P.Owner) -> Bool
    typealias InputReceiver = @MainActor @Sendable (P.ImmutableInput) async -> Void
    enum InputHandling { case notAccepted, receive(InputReceiver) }
    enum Failure: Error, Equatable { case entropy, noLAN, listener, configuration, retired, busy, stale, clock }
    struct Publication {
        let owner: P.Owner
        let endpoint: P.Endpoint
        /// Sensitive short-lived transfer capability. Display as QR only; never log/persist/interpolate HTML.
        let qrURL: String
        let qrImage: CGImage
    }
    struct Dependencies {
        let clock: @MainActor @Sendable () -> Double
        let capability: @MainActor @Sendable () throws -> P.Capability
        let ipv4: @MainActor @Sendable () -> String?
        let qr: @MainActor @Sendable (String) -> CGImage?
        let listener: @MainActor @Sendable () throws -> any ProfilePickerToolsLANListener
        let timer: @MainActor @Sendable (DispatchQueue, @escaping @Sendable () -> Void,
                                      @escaping @Sendable () -> Void) -> any ProfilePickerToolsLANTimer
        static var production: Self {
            .init(clock: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
                  capability: { try ProfilePickerToolsLANSupport.capability() },
                  ipv4: { ProfilePickerToolsLANSupport.ipv4() }, qr: { ProfilePickerToolsLANSupport.qr($0) },
                  listener: { try ProfilePickerToolsLANNetworkListener() },
                  timer: { queue, tick, cancelled in
                      ProfilePickerToolsLANDispatchTimer(queue: queue, tick: tick, cancelled: cancelled)
                  })
        }
    }
    let owner: P.Owner
    let mode: P.Mode
    private(set) var publication: Publication?
    private(set) var failure: Failure?
    var stage: P.Stage { policy.stage }
    var localSendOutcome: P.LocalSendOutcome? { policy.localSendOutcome }
    var outputInfo: P.OutputInfo? { policy.outputInfo }
    var hasOwnedWork: Bool { work != nil }
    var attemptsAreDrained: Bool {
        work == nil && !policy.hasUndrainedAttempts && !connections.values.contains(where: { $0.claim != nil })
    }
    /// Network-only drain permits the controller to start a separately owned TV Restore after input.
    /// It excludes the still-live operation deadline timer and never asserts account/native completion.
    var networkIsDrained: Bool {
        networkClosed && listenerTerminal && connections.isEmpty && mailbox.networkIsIdle
    }
    /// Full adapter drain includes its timer, queued callbacks and actual owned async-work return.
    /// Controller must additionally retain any work it starts outside performTVWork/inputReceiver.
    var isDrained: Bool {
        retired && networkIsDrained && timerTerminal && work == nil && mailbox.isIdle
            && !policy.hasUndrainedAttempts
    }
    private let dependencies: Dependencies
    private let liveGrant: Grant
    private let inputHandling: InputHandling
    private let onChange: @MainActor @Sendable (P.Owner) -> Void
    private let policy: P.Session
    nonisolated private let mailbox: Mailbox
    private var capability: P.Capability
    private var endpoint: P.Endpoint?
    private var listener: (any ProfilePickerToolsLANListener)?
    private var listenerTerminal = true
    private var started = false
    private var startedAt: Double?
    private var timer: (any ProfilePickerToolsLANTimer)?
    private var timerTerminal = false
    private var networkClosed = false
    private var retired = false
    private var drainedPublished = false
    private var notifying = false
    private var reconciling = false
    private var lastStateResponse: Double?
    private var connections: [UUID: Connection] = [:]
    private var work: Work?
    // Deliberately retained until acknowledged drain, including a noncooperative injected/account worker.
    private var lifetime: ProfilePickerToolsLANTransfer?

    private final class Work {
        let id: UUID
        let inputConnection: UUID?
        var cancel: (() -> Void)?
        init(id: UUID, inputConnection: UUID?) { self.id = id; self.inputConnection = inputConnection }
    }
    private enum Phase: Equatable { case headers, input, metadata, outputHeader, outputBody, peerClose, closing }
    private enum SendKind { case metadata, outputHeader, outputBody(Range<Int>) }
    private struct PendingSend { let id: UUID; let kind: SendKind }
    private final class Connection {
        let id: UUID
        let driver: any ProfilePickerToolsLANConnection
        let headerStarted: Double
        var parser: P.HeaderParser
        var head: P.RequestHead?
        var phase: Phase = .headers
        var receive: UUID?
        var send: PendingSend?
        var terminal = false
        var cancelRequested = false
        var claim: P.Claim?
        var expectedInput = 0
        var receivedInput = 0
        var inputWork: UUID?
        var peerCloseAt: Double?
        init(id: UUID, driver: any ProfilePickerToolsLANConnection, endpoint: P.Endpoint, now: Double) throws {
            self.id = id; self.driver = driver; headerStarted = now
            parser = try P.HeaderParser(endpoint: endpoint, now: now)
        }
    }

    init(owner: P.Owner, mode: P.Mode, liveGrant: @escaping Grant, input: InputHandling,
         onChange: @escaping @MainActor @Sendable (P.Owner) -> Void,
         dependencies: Dependencies = .production) throws {
        switch (mode, input) {
        case (.download, .notAccepted), (.repair, .receive), (.restore, .receive): break
        default: throw Failure.configuration
        }
        self.owner = owner; self.mode = mode; self.liveGrant = liveGrant
        inputHandling = input; self.onChange = onChange; self.dependencies = dependencies
        let fresh = try dependencies.capability()
        capability = fresh
        policy = try P.Session(owner: owner, mode: mode, capability: fresh, now: dependencies.clock())
        mailbox = Mailbox()
        mailbox.attach(event: { [weak self] event in self?.handle(event) },
                       acknowledged: { [weak self] in self?.reconcile() })
        lifetime = self
        let box = mailbox
        timer = dependencies.timer(box.queue, { box.postTick() }, { box.post(.timerCancelled) })
    }

    /// Returns immediately. Readiness/cancellation are actual driver callbacks, never a semaphore wait.
    func start() throws {
        guard !started, !networkClosed, !retired else { throw Failure.retired }
        try requireLocalLive()
        guard let address = dependencies.ipv4() else { failure = .noLAN; retire(); throw Failure.noLAN }
        // Validate the exact advertised numeric address before creating any listener.
        do { _ = try P.Endpoint(ipv4: address, port: 1) }
        catch { failure = .noLAN; retire(); throw Failure.noLAN }
        let created: any ProfilePickerToolsLANListener
        do { created = try dependencies.listener() }
        catch { failure = .listener; retire(); throw Failure.listener }
        let box = mailbox
        do {
            try withAuthority { grant, now in
                try policy.enforceDeadlines(now: now, liveGrant: grant)
                guard !networkClosed else { throw Failure.retired }
                started = true; startedAt = now; listener = created; listenerTerminal = false
                created.start(queue: box.queue, state: { box.post(.listener($0, address)) },
                              connection: { box.accept($0) })
            }
        } catch {
            created.cancel(); retire(); throw error
        }
    }

    /// Callable off-actor: closes the bounded synchronous-release fence NOW, then requests actor cleanup.
    /// A release already inside the fence may finish before this returns; its handed-off bytes are not recalled.
    nonisolated func revokeNow() { mailbox.revoke(); mailbox.post(.revoke) }

    func retire() {
        guard !retired else { reconcile(); return }
        mailbox.revoke(); retired = true; networkClosed = true; publication = nil
        policy.retire()
        work?.cancel?()
        timer?.cancel()
        listener?.cancel()
        for connection in connections.values { close(connection) }
        changed(); reconcile()
    }

    /// TV/controller-only. Browser routes can never call this or supply work/key/account witnesses.
    /// This tracked child is retained/cancelled until the actual closure returns, even if uncooperative.
    func performTVWork<Value: Sendable>(owner supplied: P.Owner,
        _ operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        guard supplied == owner else { throw Failure.stale }
        guard !Task.isCancelled else { retire(); throw CancellationError() }
        try requireLocalLive()
        guard work == nil else { throw Failure.busy }
        let record = Work(id: UUID(), inputConnection: nil)
        work = record
        let task = Task { @MainActor [self] in
            defer { mailbox.post(.workReturned(record.id)) }
            try Task.checkCancellation()
            try requireLocalLive()
            let result = try await operation()
            try Task.checkCancellation()
            try requireLocalLive()
            return result
        }
        record.cancel = { task.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel(); self.revokeNow()
        }
    }

    /// Call only after controller inspection/prepare; this is not export or Restore approval.
    func showReview(owner supplied: P.Owner) throws {
        guard supplied == owner else { throw Failure.stale }
        try withAuthority { grant, now in
            try policy.showReview(now: now, liveGrant: grant)
        }
        changed()
    }
    /// Validated immutable bytes from the original controller's explicit TV approval/take/download.
    @discardableResult func installOutput(_ bytes: Data, snapshotID: UUID, owner supplied: P.Owner) throws -> P.OutputInfo {
        guard supplied == owner else { throw Failure.stale }
        let result = try withAuthority { grant, now in
            try policy.installOutput(bytes, snapshotID: snapshotID, now: now, liveGrant: grant)
        }
        changed(); return result
    }
    /// The only retry entry is a TV action. It never downloads/takes/rewrites a snapshot or extends time.
    @discardableResult func retrySameOutput(owner supplied: P.Owner) throws -> P.OutputInfo {
        guard supplied == owner, !networkClosed else { throw Failure.stale }
        guard work == nil, !policy.hasUndrainedAttempts,
              !connections.values.contains(where: { $0.claim != nil }) else { throw Failure.busy }
        let fresh = try dependencies.capability()
        let info = try withAuthority { grant, now in
            try policy.retryOutput(with: fresh, now: now, liveGrant: grant)
        }
        capability = fresh
        cancelMetadataConnections()
        try publish(); changed(); return info
    }
    func retryInput(owner supplied: P.Owner) throws {
        guard supplied == owner, !networkClosed else { throw Failure.stale }
        guard work == nil, !policy.hasUndrainedAttempts,
              !connections.values.contains(where: { $0.claim != nil }) else { throw Failure.busy }
        let fresh = try dependencies.capability()
        try withAuthority { grant, now in try policy.retryInput(with: fresh, now: now, liveGrant: grant) }
        capability = fresh
        cancelMetadataConnections()
        try publish(); changed()
    }
    /// Stop all input networking BEFORE the controller's explicit Restore confirmation can perform a PUT.
    /// Wait for networkIsDrained; performTVWork still tracks original local TV/account work and deadline.
    func closeNetworkForRestore(owner supplied: P.Owner) throws {
        guard supplied == owner, mode == .restore, policy.inputConsumed, stage == .reviewOnTV else { throw Failure.stale }
        try requireLocalLive()
        networkClosed = true; publication = nil; mailbox.closeAdmission()
        listener?.cancel()
        for connection in connections.values { close(connection) }
        changed(); reconcile()
    }

    /// Evaluate the ORIGINAL live callback outside the lock. MainActor admission cannot change
    /// before the following synchronous effect. The lock then linearizes nonactor retirement against
    /// only bounded policy mutation/append/send; no arbitrary grant/observer callback is held inside.
    /// The private nonescaping projection binds that just-checked admission to this exact Owner/fence.
    private func withAuthority<Value>(_ body: (@MainActor (P.Owner) -> Bool, Double) throws -> Value) throws -> Value {
        guard !Task.isCancelled, originalGrant(owner) else { retire(); throw P.Refusal.denied }
        let now = dependencies.clock() // Injected clock is also outside the effect lock.
        do {
            return try mailbox.withOpen {
                guard !retired else { throw Failure.retired }
                return try body({ [self] candidate in candidate == owner && !retired && !mailbox.isRevoked }, now)
            }
        } catch {
            if mailbox.isRevoked { retire() }
            throw error
        }
    }
    private func originalGrant(_ candidate: P.Owner) -> Bool {
        guard candidate == owner, !retired, !mailbox.isRevoked else { return false }
        let admitted = liveGrant(candidate)
        return admitted && !retired && !mailbox.isRevoked
    }
    private func requireLocalLive() throws {
        guard !retired else { throw Failure.retired }
        do { try withAuthority { grant, now in try policy.enforceDeadlines(now: now, liveGrant: grant) } }
        catch { if policy.retired || !originalGrant(owner) { retire() }; throw error }
    }
    private func publish() throws {
        try requireLocalLive()
        guard !networkClosed, let endpoint else { throw Failure.retired }
        let url = endpoint.origin + "/#" + capability.qrFragment
        guard let image = dependencies.qr(url) else { failure = .configuration; retire(); throw Failure.configuration }
        try withAuthority { grant, now in
            try policy.enforceDeadlines(now: now, liveGrant: grant)
            guard !networkClosed else { throw Failure.retired }
            publication = Publication(owner: owner, endpoint: endpoint, qrURL: url, qrImage: image)
        }
        changed()
    }
    private func changed() {
        guard !notifying else { return }
        notifying = true; defer { notifying = false }; onChange(owner)
    }

    private func handle(_ event: Event) {
        switch event {
        case .revoke: retire()
        case .workReturned(let id): workReturned(id)
        case .timerCancelled: timerTerminal = true; timer = nil
        case .tick: tick()
        case .listener(let state, let address):
            switch state {
            case .ready(let port):
                guard !retired, !networkClosed, !listenerTerminal else { listener?.cancel(); return }
                do {
                    let actual = try P.Endpoint(ipv4: address, port: port)
                    if let endpoint {
                        guard endpoint == actual else { throw Failure.stale }
                        return // A repeated ready cannot republish an expired/failed attempt's old QR.
                    }
                    endpoint = actual; try publish()
                } catch { failure = .listener; retire() }
            case .failed: failure = .listener; retire() // cancel is not itself terminal evidence.
            case .cancelled:
                listenerTerminal = true; listener = nil
                if !networkClosed { failure = .listener; retire() }
            }
        case .accepted(let id, let driver): accepted(id, driver: driver)
        case .connection(let id, let state):
            guard let connection = connections[id] else { return }
            switch state {
            case .ready: break
            case .failed: close(connection)
            case .cancelled: connection.terminal = true; close(connection)
            }
        case .received(let id, let request, let bytes, let eof, let failed):
            received(id, request: request, bytes: bytes, eof: eof, failed: failed)
        case .sent(let id, let request, let failed): sent(id, request: request, failed: failed)
        }
    }
    private func accepted(_ id: UUID, driver: any ProfilePickerToolsLANConnection) {
        guard !networkClosed, !retired, let endpoint else {
            driver.cancel(); mailbox.discardUnstarted(id); return
        }
        do {
            try requireLocalLive()
            let connection = try Connection(id: id, driver: driver, endpoint: endpoint, now: dependencies.clock())
            connections[id] = connection
            let box = mailbox
            driver.start(queue: box.queue, state: { box.post(.connection(id, $0), connection: id) })
            receive(connection, maximum: P.chunkBytes)
        } catch { driver.cancel(); mailbox.discardUnstarted(id) }
    }
    private func receive(_ connection: Connection, maximum: Int) {
        guard connection.receive == nil, !connection.cancelRequested, !connection.terminal else { return }
        let request = UUID(); connection.receive = request
        let box = mailbox, id = connection.id
        connection.driver.receive(maximum: maximum) { bytes, eof, failed in
            box.post(.received(id, request, bytes, eof, failed), connection: id)
        }
    }
    private func received(_ id: UUID, request: UUID, bytes: Data?, eof: Bool, failed: Bool) {
        guard let connection = connections[id], connection.receive == request else { return }
        connection.receive = nil
        guard !connection.cancelRequested, connection.phase != .closing else { return }
        if failed { close(connection); return }
        let data = bytes ?? Data()
        guard data.count <= P.chunkBytes else { close(connection); return }
        if connection.phase == .peerClose {
            if eof { close(connection) } else { receive(connection, maximum: 1_024) }
            return
        }
        do {
            try requireLocalLive()
            guard !networkClosed else { throw Failure.retired }
            switch connection.phase {
            case .headers:
                let feed = try connection.parser.consume(data, now: dependencies.clock())
                if let head = feed.head {
                    connection.head = head
                    try route(head, receive: data, consumed: feed.consumed, connection: connection, eof: eof)
                } else {
                    if eof { try connection.parser.eof(now: dependencies.clock()); throw P.Refusal.earlyEOF }
                    receive(connection, maximum: P.chunkBytes)
                }
            case .input:
                try appendReceive(data, offset: 0, connection: connection, eof: eof)
            default: throw P.Refusal.stale
            }
        } catch { refuse(connection) }
    }
    private func route(_ head: P.RequestHead, receive data: Data, consumed: Int,
                       connection: Connection, eof: Bool) throws {
        try withAuthority { grant, now in try policy.authorize(head, now: now, liveGrant: grant) }
        switch head.route {
        case .bootstrap:
            try metadata(Page.bytes, kind: .bootstrap, head: head, connection: connection)
        case .state:
            let now = dependencies.clock()
            if let lastStateResponse, now - lastStateResponse < 1 { throw P.Refusal.busy }
            let body = try withAuthority { grant, now in try policy.stateBody(for: head, now: now, liveGrant: grant) }
            lastStateResponse = now
            try metadata(body, kind: .metadata, head: head, connection: connection)
        case .input:
            guard work == nil, case .receive = inputHandling else { throw P.Refusal.busy }
            // Reserve BEFORE a subdata/body tail or a per-attempt body allocation exists.
            let claim = try withAuthority { grant, now in try policy.reserveInput(head, now: now, liveGrant: grant) }
            connection.claim = claim; connection.expectedInput = head.contentLength; connection.phase = .input
            try appendReceive(data, offset: consumed, connection: connection, eof: eof)
        case .file:
            let claim = try withAuthority { grant, now in try policy.reserveOutput(head, now: now, liveGrant: grant) }
            connection.claim = claim
            guard let info = policy.outputInfo else { throw P.Refusal.notReady }
            let header = try Page.responseHead(status: .ok, kind: .file(info.filename), byteCount: info.byteCount)
            connection.phase = .outputHeader
            try send(header, final: false, kind: .outputHeader, head: head, connection: connection)
        }
    }
    /// The SINGLE path for a coalesced header tail and every later body receive.
    /// Each receive is <=64KiB; check its ENTIRE remaining tail before committing any exact-length input.
    private func appendReceive(_ data: Data, offset: Int, connection: Connection, eof: Bool) throws {
        guard let claim = connection.claim, offset >= 0, offset <= data.count,
              data.count <= P.chunkBytes else { throw P.Refusal.stale }
        let count = data.count - offset
        guard count <= connection.expectedInput - connection.receivedInput else { throw P.Refusal.extraBytes }
        if count != 0 {
            try withAuthority { grant, now in
                guard !networkClosed else { throw P.Refusal.denied }
                // Only after reserveInput and the original live grant; no eager tail initializer.
                let start = data.index(data.startIndex, offsetBy: offset)
                let body = data.subdata(in: start..<data.endIndex)
                try policy.appendInput(body, claim: claim, now: now, liveGrant: grant)
                connection.receivedInput += count
            }
        }
        if connection.receivedInput == connection.expectedInput {
            let accepted = try withAuthority { grant, now in try policy.commitInput(claim: claim, now: now, liveGrant: grant) }
            // The whole receive was checked above. No later slice from this callback can overflow it.
            try metadata(Data("{\"received\":true}".utf8), kind: .metadata, head: connection.head!, connection: connection)
            deliverInput(accepted, connection: connection)
        } else if eof {
            try withAuthority { grant, now in try policy.inputEOF(claim: claim, now: now, liveGrant: grant) }
            throw P.Refusal.earlyEOF
        } else { receive(connection, maximum: min(P.chunkBytes, connection.expectedInput - connection.receivedInput + 1)) }
    }
    private func deliverInput(_ input: P.ImmutableInput, connection: Connection) {
        guard case .receive(let receiver) = inputHandling, work == nil, input.owner == owner else { close(connection); return }
        let record = Work(id: UUID(), inputConnection: connection.id)
        work = record; connection.inputWork = record.id
        let task = Task { @MainActor [self] in
            defer { mailbox.post(.workReturned(record.id)) }
            do { try Task.checkCancellation(); try requireLocalLive(); guard !networkClosed else { return }; await receiver(input) }
            catch { retire() }
        }
        record.cancel = { task.cancel() }
        changed()
    }
    private func workReturned(_ id: UUID) {
        guard let current = work, current.id == id else { return }
        if let connectionID = current.inputConnection, connections[connectionID]?.inputWork == id {
            connections[connectionID]?.inputWork = nil
        }
        work = nil; changed(); reconcile()
    }
    private func metadata(_ body: Data, kind: Page.BodyKind, head: P.RequestHead, connection: Connection) throws {
        let header = try Page.responseHead(status: .ok, kind: kind, byteCount: body.count)
        let message = try withAuthority { grant, now in
            try policy.authorize(head, now: now, liveGrant: grant)
            var message = header; message.append(body)
            connection.phase = .metadata
            return message
        }
        try send(message, final: true, kind: .metadata, head: head, connection: connection)
    }
    private func send(_ bytes: Data, final: Bool, kind: SendKind, head: P.RequestHead, connection: Connection) throws {
        try withAuthority { grant, now in
            guard !networkClosed, !connection.cancelRequested, !connection.terminal,
                  connection.send == nil else { throw P.Refusal.stale }
            try policy.authorize(head, now: now, liveGrant: grant)
            let request = UUID(); connection.send = PendingSend(id: request, kind: kind)
            let box = mailbox, id = connection.id
            connection.driver.send(bytes, final: final) { failed in box.post(.sent(id, request, failed), connection: id) }
        }
    }
    private func sent(_ id: UUID, request: UUID, failed: Bool) {
        guard let connection = connections[id], let pending = connection.send, pending.id == request else { return }
        connection.send = nil
        guard !connection.cancelRequested, connection.phase != .closing else { return }
        if failed { close(connection); return }
        do {
            try requireLocalLive()
            switch pending.kind {
            case .metadata: waitForPeer(connection)
            case .outputHeader: try nextChunk(connection)
            case .outputBody(let range):
                guard let claim = connection.claim else { throw P.Refusal.stale }
                try withAuthority { grant, now in
                    try policy.localChunkProcessed(claim: claim, range: range, now: now, liveGrant: grant)
                }
                try nextChunk(connection)
            }
        } catch { refuse(connection) }
    }
    private func nextChunk(_ connection: Connection) throws {
        guard let claim = connection.claim, let head = connection.head else { throw P.Refusal.stale }
        let chunk = try withAuthority { grant, now in
            guard !networkClosed else { throw Failure.retired }
            return try policy.releaseOutputChunk(claim: claim, now: now, liveGrant: grant)
        }
        if let chunk {
            guard let info = policy.outputInfo else { throw P.Refusal.notReady }
            connection.phase = .outputBody
            try send(chunk.bytes, final: chunk.range.upperBound == info.byteCount,
                     kind: .outputBody(chunk.range), head: head, connection: connection)
        } else {
            try withAuthority { grant, now in
                try policy.finishOutput(claim: claim, success: true, now: now, liveGrant: grant)
            }
            publication = nil
            waitForPeer(connection); changed()
        }
    }
    private func waitForPeer(_ connection: Connection) {
        connection.phase = .peerClose; connection.peerCloseAt = dependencies.clock()
        // Locally processed finalMessage isn't peer receipt. Preserve TCP write-close until peer EOF
        // or a bounded cleanup timeout; calling cancel immediately can truncate queued bytes.
        receive(connection, maximum: 1_024)
    }
    private func refuse(_ connection: Connection) {
        close(connection)
        if policy.retired || !originalGrant(owner) { retire() }
    }
    private func close(_ connection: Connection) {
        guard !connection.cancelRequested else { return }
        connection.cancelRequested = true; connection.phase = .closing
        if let claim = connection.claim, let head = connection.head {
            if head.route == .input {
                if !policy.inputConsumed { publication = nil }
                policy.beginInputDrain(claim: claim)
            }
            else if head.route == .file {
                publication = nil
                do { try policy.finishOutput(claim: claim, success: false, now: dependencies.clock(), liveGrant: originalGrant) }
                catch { policy.beginOutputDrain(claim: claim) }
            }
        }
        connection.driver.cancel() // NOT a receive/send/connection-drain acknowledgment.
    }
    private func cancelMetadataConnections() {
        for connection in connections.values where connection.claim == nil { close(connection) }
    }
    private func tick() {
        guard !retired else { return }
        do { try requireLocalLive() }
        catch {
            if policy.retired || !originalGrant(owner) { retire(); return }
            for connection in connections.values where connection.claim != nil { close(connection) }
        }
        let now = dependencies.clock()
        if started, !networkClosed, endpoint == nil, let startedAt, now - startedAt >= P.headerSeconds {
            failure = .listener; retire(); return
        }
        for connection in connections.values {
            if connection.phase == .headers, now - connection.headerStarted >= P.headerSeconds { close(connection) }
            if let peerCloseAt = connection.peerCloseAt, now - peerCloseAt >= 30 { close(connection) }
        }
    }
    private func reconcile() {
        guard !reconciling else { return }
        reconciling = true; defer { reconciling = false }
        // Network operations must return, terminal cancellation must arrive, mailbox payload deliveries
        // must be acknowledged after their handlers return, AND input/account work must return.
        for connection in Array(connections.values) {
            guard connection.terminal, connection.receive == nil, connection.send == nil,
                  connection.inputWork == nil, mailbox.pending(for: connection.id) == 0 else { continue }
            if let claim = connection.claim, let head = connection.head {
                if head.route == .input { _ = policy.inputDrained(claim: claim) }
                else if head.route == .file { _ = policy.outputDrained(claim: claim) }
            }
            connections.removeValue(forKey: connection.id)
            mailbox.releaseConnection(connection.id)
        }
        if isDrained, !drainedPublished {
            do { try policy.releaseRetiredPayloadsAfterDrain() }
            catch { return }
            drainedPublished = true; changed(); lifetime = nil
        } else { changed() }
    }

    private enum Event: Sendable {
        case revoke, tick, timerCancelled
        case workReturned(UUID)
        case listener(ProfilePickerToolsLANListenerState, String)
        case accepted(UUID, any ProfilePickerToolsLANConnection)
        case connection(UUID, ProfilePickerToolsLANConnectionState)
        case received(UUID, UUID, Data?, Bool, Bool)
        case sent(UUID, UUID, Bool)
    }
    /// One serial queue is ALSO the actual Network callback queue. The forward barrier therefore runs
    /// after the upstream callback returned. Its second barrier acknowledges only after MainActor handling
    /// returns. Pending tickets exist BEFORE either hop, so cancellation cannot erase enqueued payload work.
    private final class Mailbox: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.vortx.tools.lan-transfer")
        private let lock = NSRecursiveLock()
        private var revoked = false
        private var admissionClosed = false
        private var reservations = Set<UUID>()
        private struct Ticket { let connection: UUID?; let network: Bool }
        private var tickets: [UUID: Ticket] = [:]
        private var tickTicket: UUID?
        private var notificationScheduled = false
        private var handler: (@MainActor @Sendable (Event) -> Void)?
        private var acknowledged: (@MainActor @Sendable () -> Void)?
        func attach(event: @escaping @MainActor @Sendable (Event) -> Void,
                    acknowledged: @escaping @MainActor @Sendable () -> Void) {
            lock.lock(); defer { lock.unlock() }; handler = event; self.acknowledged = acknowledged
        }
        var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
        func revoke() { lock.lock(); revoked = true; admissionClosed = true; lock.unlock() }
        func closeAdmission() { lock.lock(); admissionClosed = true; lock.unlock() }
        // Recursive reads are internal projected-grant fence checks, never arbitrary grant callbacks.
        // No await, native work, observer callback or blocking Network wait occurs inside this fence.
        func withOpen<Value>(_ body: () throws -> Value) throws -> Value {
            lock.lock(); defer { lock.unlock() }
            guard !revoked else { throw Failure.retired }
            return try body()
        }
        func accept(_ driver: any ProfilePickerToolsLANConnection) {
            lock.lock()
            guard !revoked, !admissionClosed, reservations.count < 4 else { lock.unlock(); driver.cancel(); return }
            let id = UUID(); reservations.insert(id)
            lock.unlock()
            post(.accepted(id, driver), connection: id)
        }
        func discardUnstarted(_ id: UUID) { releaseConnection(id) }
        func releaseConnection(_ id: UUID) { lock.lock(); reservations.remove(id); lock.unlock() }
        func pending(for connection: UUID) -> Int {
            lock.lock(); defer { lock.unlock() }; return tickets.values.filter { $0.connection == connection }.count
        }
        var networkIsIdle: Bool {
            lock.lock(); defer { lock.unlock() }
            return reservations.isEmpty && !tickets.values.contains(where: { $0.network })
        }
        var isIdle: Bool {
            lock.lock(); defer { lock.unlock() }; return tickets.isEmpty && !notificationScheduled
        }
        func postTick() { post(.tick, tick: true) }
        func post(_ event: Event, connection: UUID? = nil, tick: Bool = false) {
            lock.lock()
            if tick && tickTicket != nil { lock.unlock(); return }
            let network: Bool
            switch event { case .tick, .timerCancelled, .workReturned: network = false; default: network = true }
            let ticket = UUID(); tickets[ticket] = Ticket(connection: connection, network: network)
            if tick { tickTicket = ticket }
            lock.unlock()
            queue.async { [self] in
                Task { @MainActor [self] in
                    eventCallback()?(event)
                    queue.async { [self] in acknowledge(ticket) }
                }
            }
        }
        private func eventCallback() -> (@MainActor @Sendable (Event) -> Void)? {
            lock.lock(); defer { lock.unlock() }; return handler
        }
        private func notificationCallback() -> (@MainActor @Sendable () -> Void)? {
            lock.lock(); defer { lock.unlock() }; notificationScheduled = false; return acknowledged
        }
        private func acknowledge(_ ticket: UUID) {
            lock.lock()
            tickets.removeValue(forKey: ticket)
            if tickTicket == ticket { tickTicket = nil }
            guard !notificationScheduled else { lock.unlock(); return }
            notificationScheduled = true
            lock.unlock()
            Task { @MainActor [self] in
                notificationCallback()?()
            }
        }
    }
}

// Production driver wrappers contain no admission logic. All releases go through the owned adapter.
private final class ProfilePickerToolsLANNetworkConnection: ProfilePickerToolsLANConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; callbackQueue = queue }
    func start(queue: DispatchQueue, state: @escaping @Sendable (ProfilePickerToolsLANConnectionState) -> Void) {
        let callbackQueue = callbackQueue
        connection.stateUpdateHandler = { value in
            switch value {
            case .ready: callbackQueue.async { state(.ready) }
            case .failed: callbackQueue.async { state(.failed) }
            case .cancelled: callbackQueue.async { state(.cancelled) }
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func receive(maximum: Int, completion: @escaping @Sendable (Data?, Bool, Bool) -> Void) {
        let callbackQueue = callbackQueue
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { bytes, _, eof, error in
            let failed = error != nil
            callbackQueue.async { completion(bytes, eof, failed) }
        }
    }
    func send(_ bytes: Data, final: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        let callbackQueue = callbackQueue
        connection.send(content: bytes, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { error in
                            let failed = error != nil
                            callbackQueue.async { completion(failed) }
                        })
    }
    func cancel() { connection.cancel() }
}
private final class ProfilePickerToolsLANNetworkListener: ProfilePickerToolsLANListener, @unchecked Sendable {
    private let listener: NWListener
    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(queue: DispatchQueue, state: @escaping @Sendable (ProfilePickerToolsLANListenerState) -> Void,
               connection: @escaping @Sendable (any ProfilePickerToolsLANConnection) -> Void) {
        listener.stateUpdateHandler = { [weak self] value in
            guard let self else { return }
            switch value {
            case .ready: state(.ready(self.listener.port?.rawValue ?? 0))
            case .failed: state(.failed)
            case .cancelled: state(.cancelled)
            default: break
            }
        }
        listener.newConnectionHandler = { connection(ProfilePickerToolsLANNetworkConnection($0, queue: queue)) }
        listener.start(queue: queue)
    }
    func cancel() { listener.cancel() }
}
private final class ProfilePickerToolsLANDispatchTimer: ProfilePickerToolsLANTimer, @unchecked Sendable {
    private let source: DispatchSourceTimer
    init(queue: DispatchQueue, tick: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        source.setEventHandler(handler: tick)
        source.setCancelHandler(handler: cancelled)
        source.resume()
    }
    func cancel() { source.cancel() }
}
/// Narrow copies of the currently private diagnostic LAN/QR patterns; no diagnostic payload or parser.
private enum ProfilePickerToolsLANSupport {
    static func capability() throws -> ProfilePickerToolsTransferPolicy.Capability {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ProfilePickerToolsLANTransfer.Failure.entropy }
        return try .init(hex: bytes.map { String(format: "%02x", $0) }.joined())
    }
    static func ipv4() -> String? {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return nil }
        defer { freeifaddrs(address) }
        var preferred: String?, fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            defer { cursor = pointer.pointee.ifa_next }
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING), flags & IFF_LOOPBACK == 0,
                  let socket = pointer.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let end = host.firstIndex(of: 0) ?? host.endIndex
            let value = String(decoding: host[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !value.isEmpty, !value.hasPrefix("169.254") else { continue }
            if String(cString: pointer.pointee.ifa_name) == "en0" { preferred = value }
            else if fallback == nil { fallback = value }
        }
        return preferred ?? fallback
    }
    static func qr(_ value: String) -> CGImage? {
        guard let bytes = value.data(using: .utf8), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(bytes, forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
