import Foundation

// Source-only controlled boundaries for the ACTUAL WatchPartyClientSession.
// No networking, account singleton, Keychain, profile manager, native player or
// replacement auth/HTTP types. Nothing here prints requests or wire payloads.
enum AsyncHarnessError: Error {
    case assertion(String)
    case unexpectedHTTPRoute
    case wrongReplyKind
    case missingHandle
    case socketClosed
    case cleanup
}

@MainActor
func asyncRequire(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    if !condition() { throw AsyncHarnessError.assertion(label) }
}

@MainActor
func asyncEventually(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
    // Scheduling bound, not an elapsed-time sleep. The root harness additionally
    // owns a process timeout; a deadlock must never turn into a success result.
    for _ in 0..<4_096 {
        if predicate() { return }
        await Task.yield()
    }
    throw AsyncHarnessError.assertion("bounded scheduling wait: " + label)
}

@MainActor
func asyncDrain(_ count: Int = 64) async {
    for _ in 0..<count { await Task.yield() }
}

@MainActor
final class AsyncHarnessJob<Value> {
    private(set) var result: Result<Value, Error>?
    private var task: Task<Void, Never>?

    init(_ operation: @MainActor @escaping () async throws -> Value) {
        task = Task { @MainActor [weak self] in
            do {
                let value = try await operation()
                self?.result = .success(value)
            } catch {
                self?.result = .failure(error)
            }
        }
    }

    func cancel() { task?.cancel() }

    func value(_ label: String) async throws -> Value {
        try await asyncEventually(label) { self.result != nil }
        guard let result else { throw AsyncHarnessError.missingHandle }
        return try result.get()
    }
}

enum SyntheticParty {
    static let room = "room_aaaaaaaaaaaaaaaaaaaaaaa"
    static let member = "member_bbbbbbbbbbbbbbbbbbbbb"
    static let capability = "capability_cccccccccccccccccc"
    static let invite = "invite_ddddddddddddddddddddd"
    static let ticket = "ticket_eeeeeeeeeeeeeeeeeeeee"
    static let generation = "generation_fffffffffffffffff"
    static let reservation = "reservation_gggggggggggggggg"
    static let title = "synthetic_title_token"

    static func snapshot(_ sequence: Int64) -> WatchPartyClientSession.Snapshot {
        .init(roomGeneration: generation, leaderTerm: 1, serverSequence: sequence,
              memberCount: 2, leaseRemainingMs: 30_000, expiresAtMs: nil, nonce: nil)
    }
}

@MainActor
final class ControlledHTTP {
    enum Kind: Equatable { case create, join, ticket, renew }

    enum Reply {
        case created(Int64)
        case joined(Int64, role: String)
        case ticket
        case renewed(Int64)

        var kind: Kind {
            switch self {
            case .created: return .create
            case .joined: return .join
            case .ticket: return .ticket
            case .renewed: return .renew
            }
        }

        func response() throws -> AuthenticatedHTTPResponse {
            struct Created: Encodable {
                let roomId = SyntheticParty.room
                let leaderId = SyntheticParty.member
                let capability = SyntheticParty.capability
                let inviteCode = SyntheticParty.invite
                let snapshot: WatchPartyClientSession.Snapshot
            }
            struct Joined: Encodable {
                let roomId = SyntheticParty.room
                let id = SyntheticParty.member
                let capability = SyntheticParty.capability
                let role: String
                let incarnation = 1
                let snapshot: WatchPartyClientSession.Snapshot
            }
            struct Ticket: Encodable { let ticket = SyntheticParty.ticket }
            struct Renewed: Encodable {
                let expiresAtMs: Int64 = 999_999
                let snapshot: WatchPartyClientSession.Snapshot
            }
            let data: Data
            switch self {
            case .created(let sequence):
                data = try JSONEncoder().encode(Created(snapshot: SyntheticParty.snapshot(sequence)))
            case .joined(let sequence, let role):
                data = try JSONEncoder().encode(Joined(role: role, snapshot: SyntheticParty.snapshot(sequence)))
            case .ticket:
                data = try JSONEncoder().encode(Ticket())
            case .renewed(let sequence):
                data = try JSONEncoder().encode(Renewed(snapshot: SyntheticParty.snapshot(sequence)))
            }
            return AuthenticatedHTTPResponse(data: data, statusCode: 200)
        }
    }

    final class Request {
        let id: Int
        let kind: Kind
        var cancelled = false
        var returnedToCaller = false
        var retainAfterCancellation: Bool
        fileprivate var continuation: CheckedContinuation<AuthenticatedHTTPResponse, Error>?

        init(id: Int, kind: Kind, retain: Bool) {
            self.id = id; self.kind = kind; self.retainAfterCancellation = retain
        }
    }

    private(set) var requests: [Request] = []
    private var queued: [Reply] = []
    var retainNextRequestAfterCancellation = false
    private(set) var boundaryValid = true

    func enqueue(_ reply: Reply) { queued.append(reply) }

    func pending(_ kind: Kind) -> [Request] {
        requests.filter { $0.kind == kind && $0.continuation != nil }
    }

    func send(_ request: URLRequest, hosts: Set<String>, limit: Int) async throws -> AuthenticatedHTTPResponse {
        // Inspect only; do not retain/log a bearer-bearing request or URL.
        boundaryValid = boundaryValid && request.url?.scheme == "https" &&
            request.url?.host == "api.vortx.tv" && request.url?.query == nil &&
            request.url?.fragment == nil && request.httpMethod == "POST" &&
            hosts == Set(["api.vortx.tv"]) && limit == AuthenticatedHTTPTransport.controlResponseLimit
        let path = request.url?.path ?? ""
        let kind: Kind
        if path == "/v1/watch-parties" { kind = .create }
        else if path == "/v1/watch-parties/\(SyntheticParty.room)/join" { kind = .join }
        else if path == "/v1/watch-parties/\(SyntheticParty.room)/ticket" { kind = .ticket }
        else if path == "/v1/watch-parties/\(SyntheticParty.room)/renew" { kind = .renew }
        else { throw AsyncHarnessError.unexpectedHTTPRoute }
        let entry = Request(id: requests.count + 1, kind: kind,
                            retain: retainNextRequestAfterCancellation)
        retainNextRequestAfterCancellation = false
        requests.append(entry)
        defer { entry.returnedToCaller = true }
        let cancellationID = entry.id
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                entry.continuation = continuation
                if Task.isCancelled { self.cancel(entry.id) }
                if entry.continuation != nil, let index = queued.firstIndex(where: { $0.kind == kind }) {
                    let reply = queued.remove(at: index)
                    do { try self.complete(entry.id, reply) }
                    catch { self.fail(entry.id, error) }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(cancellationID) }
        })
    }

    func complete(_ id: Int, _ reply: Reply) throws {
        guard let entry = requests.first(where: { $0.id == id }),
              let continuation = entry.continuation else { throw AsyncHarnessError.missingHandle }
        guard entry.kind == reply.kind else { throw AsyncHarnessError.wrongReplyKind }
        let response = try reply.response()
        entry.continuation = nil
        continuation.resume(returning: response)
    }

    private func cancel(_ id: Int) {
        guard let entry = requests.first(where: { $0.id == id }) else { return }
        entry.cancelled = true
        if !entry.retainAfterCancellation { fail(id, CancellationError()) }
    }

    private func fail(_ id: Int, _ error: Error) {
        guard let entry = requests.first(where: { $0.id == id }),
              let continuation = entry.continuation else { return }
        entry.continuation = nil
        continuation.resume(throwing: error)
    }

    func cleanup() {
        queued.removeAll()
        for entry in requests { fail(entry.id, AsyncHarnessError.cleanup) }
    }
}

@MainActor
final class ControlledScheduler {
    final class Sleep {
        let id: Int
        let nanoseconds: UInt64
        let started: Double
        var cancelled = false
        var retainAfterCancellation = false
        fileprivate var continuation: CheckedContinuation<Void, Error>?

        init(id: Int, nanoseconds: UInt64, started: Double) {
            self.id = id; self.nanoseconds = nanoseconds; self.started = started
        }
    }

    var now: Double = 1_000
    private(set) var sleeps: [Sleep] = []
    var pending: [Sleep] { sleeps.filter { $0.continuation != nil } }

    func sleep(_ nanoseconds: UInt64) async throws {
        let entry = Sleep(id: sleeps.count + 1, nanoseconds: nanoseconds, started: now)
        sleeps.append(entry)
        let cancellationID = entry.id
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                entry.continuation = continuation
                if Task.isCancelled { self.cancel(entry.id) }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(cancellationID) }
        })
    }

    // An intentionally retained canceled operation returns normally, exercising
    // the caller's post-await generation/socket/cancellation fences.
    func complete(_ id: Int) throws {
        guard let entry = sleeps.first(where: { $0.id == id }),
              let continuation = entry.continuation else { throw AsyncHarnessError.missingHandle }
        entry.continuation = nil
        continuation.resume()
    }

    private func cancel(_ id: Int) {
        guard let entry = sleeps.first(where: { $0.id == id }) else { return }
        entry.cancelled = true
        if !entry.retainAfterCancellation { fail(entry, CancellationError()) }
    }

    private func fail(_ entry: Sleep, _ error: Error) {
        guard let continuation = entry.continuation else { return }
        entry.continuation = nil
        continuation.resume(throwing: error)
    }

    func cleanup() { for entry in sleeps { fail(entry, AsyncHarnessError.cleanup) } }
}

struct SyntheticServerFrame: Encodable {
    let kind: String
    var type: String? = nil
    var nonce: String? = nil
    var roomGeneration: String? = SyntheticParty.generation
    var leaderTerm: Int64? = 1
    var serverSequence: Int64? = nil
    var leaseRemainingMs: Int64? = nil
    var reservationId: String? = nil
    var ciphertext: String? = nil

    static func proof(_ nonce: String, sequence: Int64, lease: Int64 = 30_000) -> Self {
        Self(kind: "lease.proof", nonce: nonce, serverSequence: sequence, leaseRemainingMs: lease)
    }

    static func event(_ type: String, sequence: Int64) -> Self {
        Self(kind: "event", type: type, serverSequence: sequence)
    }

    static func reservation(sequence: Int64) -> Self {
        Self(kind: "reservation", serverSequence: sequence, reservationId: SyntheticParty.reservation)
    }
}

@MainActor
final class ControlledSocket: WatchPartySessionSocket {
    struct SentFrame: Decodable {
        let kind: String
        let nonce: String?
        let reservationId: String?
        let serverSequence: Int64?
        let ciphertext: String?
    }

    final class Receive {
        let id: Int
        var cancelled = false
        var retainAfterCancellation = false
        fileprivate var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        init(id: Int) { self.id = id }
    }

    private(set) var resumed = false
    private(set) var closeCount = 0
    private(set) var receiveCalls = 0
    private(set) var sent: [SentFrame] = []
    private(set) var receives: [Receive] = []
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var closed = false
    var selectedProtocol: String? = "vortx-party-v1"
    var pending: [Receive] { receives.filter { $0.continuation != nil } }
    var challenges: [SentFrame] { sent.filter { $0.kind == "lease.challenge" } }
    var publishes: [SentFrame] { sent.filter { $0.kind == "publish" } }

    func resume() { resumed = true }
    func waitForProtocol(timeoutNanoseconds: UInt64) async -> String? { selectedProtocol }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard !closed else { throw AsyncHarnessError.socketClosed }
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw AsyncHarnessError.socketClosed
        }
        sent.append(try JSONDecoder().decode(SentFrame.self, from: data))
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        receiveCalls += 1
        guard !closed else { throw AsyncHarnessError.socketClosed }
        let entry = Receive(id: receives.count + 1)
        receives.append(entry)
        let cancellationID = entry.id
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                entry.continuation = continuation
                if Task.isCancelled { self.cancel(entry.id) }
                if entry.continuation != nil, !queued.isEmpty {
                    self.complete(entry, queued.removeFirst())
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(cancellationID) }
        })
    }

    func deliver(_ frame: SyntheticServerFrame, to id: Int? = nil) throws {
        let message = URLSessionWebSocketTask.Message.data(try JSONEncoder().encode(frame))
        try deliverMessage(message, to: id)
    }

    // Backend-shaped error fixtures bypass SyntheticServerFrame and its encoder.
    func deliverRawJSON(_ json: String, to id: Int? = nil) throws {
        try deliverMessage(.string(json), to: id)
    }

    private func deliverMessage(_ message: URLSessionWebSocketTask.Message, to id: Int?) throws {
        if let id {
            guard let entry = receives.first(where: { $0.id == id }),
                  entry.continuation != nil else { throw AsyncHarnessError.missingHandle }
            complete(entry, message)
        } else if let entry = pending.first {
            complete(entry, message)
        } else {
            guard !closed else { throw AsyncHarnessError.socketClosed }
            queued.append(message)
        }
    }

    private func complete(_ entry: Receive, _ message: URLSessionWebSocketTask.Message) {
        let continuation = entry.continuation
        entry.continuation = nil
        continuation?.resume(returning: message)
    }

    private func cancel(_ id: Int) {
        guard let entry = receives.first(where: { $0.id == id }) else { return }
        entry.cancelled = true
        if !entry.retainAfterCancellation { fail(entry, CancellationError()) }
    }

    private func fail(_ entry: Receive, _ error: Error) {
        let continuation = entry.continuation
        entry.continuation = nil
        continuation?.resume(throwing: error)
    }

    func close() {
        closeCount += 1
        closed = true
        queued.removeAll()
        for entry in pending { cancel(entry.id) }
    }

    func cleanup() {
        queued.removeAll()
        for entry in receives { fail(entry, AsyncHarnessError.cleanup) }
    }
}

@MainActor
final class ControlledTransport {
    let http = ControlledHTTP()
    let scheduler = ControlledScheduler()
    private(set) var sockets: [ControlledSocket] = []
    private(set) var socketBoundaryValid = true

    var dependencies: WatchPartyClientSession.Dependencies {
        .init(http: { [self] in try await http.send($0, hosts: $1, limit: $2) },
              makeSocket: { [self] url, protocols in
                  socketBoundaryValid = socketBoundaryValid && url.scheme == "wss" &&
                      url.host == "api.vortx.tv" && url.query == nil && url.fragment == nil &&
                      url.path == "/v1/watch-parties/\(SyntheticParty.room)/connect" &&
                      protocols.count == 2 && protocols.first == "vortx-party-v1" &&
                      protocols.last == "vortx-ticket.\(SyntheticParty.ticket)"
                  let socket = ControlledSocket()
                  sockets.append(socket)
                  return socket
              },
              sleep: { [self] in try await scheduler.sleep($0) })
    }

    func cleanup() {
        http.cleanup()
        scheduler.cleanup()
        for socket in sockets { socket.cleanup() }
    }
}
