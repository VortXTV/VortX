import Foundation
import Network
import Security

/// A small HTTPS/HTTP1.1 transport for untrusted community add-on traffic. Resolution happens once,
/// then each vetted numeric peer is attempted without allowing Network.framework to resolve the hostname again.
enum PinnedHTTPClient {
    struct Limits: Sendable, Equatable {
        var maximumHeaderBytes = 32 * 1024
        var maximumBodyBytes = 16 * 1024 * 1024
        var maximumWireBytes = 17 * 1024 * 1024
        var timeout: TimeInterval = 20
        var idleTimeout: TimeInterval = 10
    }

    struct Endpoint: Equatable, Sendable {
        let address: String
        let port: UInt16
        let tlsServerName: String
        let hostHeader: String
    }

    struct Request: Sendable, Equatable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data?

        init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
            self.url = url
            self.method = method.uppercased()
            self.headers = headers
            self.body = body
        }
    }

    struct Response: Sendable, Equatable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    struct ResponseHead: Sendable, Equatable {
        let statusCode: Int
        let headers: [String: String]
    }

    enum Failure: Error, Equatable {
        case invalidURL, unsafeResolution, unsupportedMethod, unsafeHeader, requestTooLarge
        case malformedResponse, responseTooLarge, redirect(Int), timedOut, cancelled, connectionFailed
    }

    typealias Resolver = @Sendable (_ host: String) throws -> [String]

    static func endpoints(for url: URL, answers: [String]) throws -> [Endpoint] {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              !answers.isEmpty, answers.allSatisfy(JSProviderURLPolicy.isPublicNumericAddress) else {
            throw Failure.unsafeResolution
        }
        let explicitPort = url.port
        guard explicitPort == nil || (1...65_535).contains(explicitPort!) else { throw Failure.invalidURL }
        let port = UInt16(explicitPort ?? 443)
        let hostHeader = explicitPort == nil || explicitPort == 443 ? host : "\(host):\(port)"
        return Array(Set(answers)).sorted().map {
            Endpoint(address: $0, port: port, tlsServerName: host, hostHeader: hostHeader)
        }
    }

    /// Kept for focused callers that need a stable representative endpoint. Network operations use `endpoints`.
    static func endpoint(for url: URL, answers: [String]) throws -> Endpoint {
        guard let endpoint = try endpoints(for: url, answers: answers).first else { throw Failure.unsafeResolution }
        return endpoint
    }

    static let systemResolver: Resolver = { host in
        guard let addresses = JSProviderURLPolicy.vettedNumericAddresses(for: host) else { throw Failure.unsafeResolution }
        return addresses
    }

    static func requestBytes(for request: Request, endpoint: Endpoint, limits: Limits = .init()) throws -> Data {
        guard request.method == "GET" || request.method == "HEAD" else { throw Failure.unsupportedMethod }
        let forbidden = Set(["host", "content-length", "transfer-encoding", "connection", "upgrade", "proxy-connection"])
        guard request.headers.allSatisfy({ name, value in
            isHTTPToken(name) && !forbidden.contains(name.lowercased()) && !value.contains("\r") && !value.contains("\n")
        }) else { throw Failure.unsafeHeader }
        guard request.body == nil else { throw Failure.unsupportedMethod }
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { throw Failure.invalidURL }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        var fields = ["\(request.method) \(target) HTTP/1.1", "Host: \(endpoint.hostHeader)", "Connection: close"]
        fields += request.headers.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
        let wire = fields.joined(separator: "\r\n") + "\r\n\r\n"
        guard wire.utf8.count <= limits.maximumHeaderBytes else { throw Failure.requestTooLarge }
        return Data(wire.utf8)
    }

    static func execute(_ request: Request, limits: Limits = .init(), resolver: @escaping Resolver = PinnedHTTPClient.systemResolver) async throws -> Response {
        try Task.checkCancellation()
        let (peers, bytes) = try prepare(request, limits: limits, resolver: resolver)
        return try await withTimeout(limits.timeout) {
            try await firstSuccessful(peers) { endpoint in
                try await exchange(bytes: bytes, endpoint: endpoint, limits: limits, method: request.method)
            }
        }
    }

    /// Peers are retried only before a response head reaches the consumer: retrying after a head would create
    /// two downstream HTTP responses for one client request.
    static func stream(_ request: Request, limits: Limits = .init(), resolver: @escaping Resolver = PinnedHTTPClient.systemResolver,
                       onHead: @escaping @Sendable (ResponseHead) async throws -> Void,
                       onBody: @escaping @Sendable (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        let (peers, bytes) = try prepare(request, limits: limits, resolver: resolver)
        try await withTimeout(limits.timeout) {
            var lastFailure: Error = Failure.connectionFailed
            for endpoint in peers {
                try Task.checkCancellation()
                let operation = StreamingConnection(connection: makeConnection(endpoint), request: bytes, method: request.method,
                                                   limits: limits, onHead: onHead, onBody: onBody)
                do { try await operation.run(); return }
                catch {
                    if operation.didDeliverHead { throw error }
                    lastFailure = error
                }
            }
            throw lastFailure
        }
    }

    static func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard timeout > 0, timeout.isFinite else { throw Failure.timedOut }
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    try Task.checkCancellation()
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw Failure.connectionFailed }
                return first
            }
        } catch is CancellationError {
            throw Failure.cancelled
        }
    }

    static func firstSuccessful<T: Sendable>(_ endpoints: [Endpoint], attempt: @escaping @Sendable (Endpoint) async throws -> T) async throws -> T {
        var lastFailure: Error = Failure.connectionFailed
        for endpoint in endpoints {
            try Task.checkCancellation()
            do { return try await attempt(endpoint) }
            catch is CancellationError { throw Failure.cancelled }
            catch { lastFailure = error }
        }
        throw lastFailure
    }

    static func decodeResponse(_ wire: Data, limits: Limits, method: String = "GET", isComplete: Bool = false) throws -> Response? {
        guard wire.count <= limits.maximumWireBytes else { throw Failure.responseTooLarge }
        guard let parsed = try decodeHead(wire, limits: limits) else { return nil }
        switch try bodyFraming(method: method, head: parsed.head) {
        case .none:
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: Data())
        case .chunked:
            guard let decoded = try decodeChunked(parsed.body, limit: limits.maximumBodyBytes) else { return nil }
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: decoded)
        case let .contentLength(expected):
            guard expected <= limits.maximumBodyBytes else { throw Failure.responseTooLarge }
            guard parsed.body.count >= expected else { return nil }
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: Data(parsed.body.prefix(expected)))
        case .closeDelimited:
            guard isComplete else { return nil }
            guard parsed.body.count <= limits.maximumBodyBytes else { throw Failure.responseTooLarge }
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: parsed.body)
        }
    }

    static func decodeHead(_ wire: Data, limits: Limits) throws -> (head: ResponseHead, body: Data)? {
        guard wire.count <= limits.maximumWireBytes else { throw Failure.responseTooLarge }
        guard let separator = wire.range(of: Data("\r\n\r\n".utf8)) else {
            if wire.count > limits.maximumHeaderBytes { throw Failure.responseTooLarge }
            return nil
        }
        guard separator.lowerBound <= limits.maximumHeaderBytes,
              let headerText = String(data: wire[..<separator.lowerBound], encoding: .utf8) else { throw Failure.malformedResponse }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " "), status.count >= 2,
              let code = Int(status[1]), (100...599).contains(code) else { throw Failure.malformedResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformedResponse }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isHTTPToken(key), !value.contains("\r"), !value.contains("\n"), headers[key] == nil else {
                throw Failure.malformedResponse
            }
            headers[key] = value
        }
        return (ResponseHead(statusCode: code, headers: headers), Data(wire[separator.upperBound...]))
    }

    static func bodyFraming(method: String, head: ResponseHead) throws -> BodyFraming {
        if method.uppercased() == "HEAD" || (100...199).contains(head.statusCode) || head.statusCode == 204 || head.statusCode == 304 { return .none }
        let transferEncoding = try parseTransferEncoding(head.headers["transfer-encoding"])
        if transferEncoding != nil, head.headers["content-length"] != nil { throw Failure.malformedResponse }
        if transferEncoding != nil { return .chunked }
        if let value = head.headers["content-length"] {
            guard !value.isEmpty, value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }), let length = Int(value) else {
                throw Failure.malformedResponse
            }
            return .contentLength(length)
        }
        return .closeDelimited
    }

    static func parseTransferEncoding(_ value: String?) throws -> Bool? {
        guard let value else { return nil }
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.isEmpty, tokens.allSatisfy({ isHTTPToken($0) }) else { throw Failure.malformedResponse }
        guard tokens.count == 1, tokens[0].caseInsensitiveCompare("chunked") == .orderedSame else { throw Failure.malformedResponse }
        return true
    }

    static func isHTTPToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 33 || (35...39).contains(scalar.value) || (42...43).contains(scalar.value) ||
                (45...46).contains(scalar.value) || (48...57).contains(scalar.value) ||
                (65...90).contains(scalar.value) || (94...122).contains(scalar.value) || scalar.value == 124 || scalar.value == 126
        }
    }

    private static func prepare(_ request: Request, limits: Limits, resolver: Resolver) throws -> ([Endpoint], Data) {
        guard request.url.scheme?.lowercased() == "https", JSProviderURLPolicy.default.isAllowed(request.url), let host = request.url.host else {
            throw Failure.invalidURL
        }
        let peers = try endpoints(for: request.url, answers: resolver(host))
        return (peers, try requestBytes(for: request, endpoint: peers[0], limits: limits))
    }

    private static func exchange(bytes: Data, endpoint: Endpoint, limits: Limits, method: String) async throws -> Response {
        try await ConnectionOperation(connection: makeConnection(endpoint), request: bytes, method: method, limits: limits).run()
    }

    private static func makeConnection(_ endpoint: Endpoint) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.tlsServerName)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.prohibitExpensivePaths = false
        return NWConnection(host: NWEndpoint.Host(endpoint.address), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: parameters)
    }

    private static func decodeChunked(_ body: Data, limit: Int) throws -> Data? {
        var chunkLimits = Limits()
        chunkLimits.maximumBodyBytes = limit
        var framer = StreamFramer(method: "GET", limits: chunkLimits)
        var output = Data()
        for event in try framer.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + body, endOfStream: false) {
            if case let .body(bytes) = event {
                guard output.count <= limit - bytes.count else { throw Failure.responseTooLarge }
                output.append(bytes)
            }
        }
        return framer.isComplete ? output : nil
    }

    enum BodyFraming: Sendable, Equatable { case none, contentLength(Int), chunked, closeDelimited }
}

/// Incremental framing emits every available chunk prefix immediately; it never buffers a declared chunk body.
struct StreamFramer: Sendable {
    enum Event: Sendable, Equatable { case head(PinnedHTTPClient.ResponseHead), body(Data), complete }

    private let method: String
    private let limits: PinnedHTTPClient.Limits
    private var head: PinnedHTTPClient.ResponseHead?
    private var framing: PinnedHTTPClient.BodyFraming?
    private var pending = Data()
    private var contentRemaining: Int?
    private var chunkRemaining: Int?
    private var awaitingChunkTerminator = false
    private var readingTrailers = false
    private(set) var isComplete = false

    init(method: String, limits: PinnedHTTPClient.Limits) { self.method = method; self.limits = limits }
    var bufferedByteCount: Int { pending.count }

    mutating func consume(_ bytes: Data, endOfStream: Bool) throws -> [Event] {
        guard !isComplete else { return [] }
        pending.append(bytes)
        var events: [Event] = []
        if head == nil {
            guard let parsed = try PinnedHTTPClient.decodeHead(pending, limits: limits) else {
                if endOfStream { throw PinnedHTTPClient.Failure.malformedResponse }
                return events
            }
            head = parsed.head; pending = parsed.body
            framing = try PinnedHTTPClient.bodyFraming(method: method, head: parsed.head)
            events.append(.head(parsed.head))
            if framing == PinnedHTTPClient.BodyFraming.none { return complete(events) }
        }
        guard let framing else { return events }
        switch framing {
        case let .contentLength(length):
            if contentRemaining == nil { contentRemaining = length }
            if let remaining = contentRemaining, !pending.isEmpty {
                let count = min(remaining, pending.count)
                if count > 0 { events.append(.body(Data(pending.prefix(count)))); pending.removeFirst(count); contentRemaining = remaining - count }
            }
            if contentRemaining == 0 { return complete(events) }
        case .chunked:
            try consumeChunked(into: &events)
            if isComplete { return events }
        case .closeDelimited:
            if !pending.isEmpty { events.append(.body(pending)); pending.removeAll(keepingCapacity: false) }
            if endOfStream { return complete(events) }
        case .none:
            return complete(events)
        }
        if endOfStream { throw PinnedHTTPClient.Failure.malformedResponse }
        return events
    }

    private mutating func consumeChunked(into events: inout [Event]) throws {
        while true {
            if readingTrailers {
                guard let trailerEnd = trailerEnd() else {
                    guard pending.count <= limits.maximumHeaderBytes else { throw PinnedHTTPClient.Failure.responseTooLarge }
                    return
                }
                try validateTrailers(Data(pending.prefix(trailerEnd)))
                pending.removeFirst(trailerEnd)
                isComplete = true
                pending.removeAll(keepingCapacity: false)
                events.append(.complete)
                return
            }
            if awaitingChunkTerminator {
                guard pending.count >= 2 else { return }
                let start = pending.startIndex
                guard pending[start] == 13, pending[pending.index(after: start)] == 10 else {
                    throw PinnedHTTPClient.Failure.malformedResponse
                }
                pending.removeFirst(2); awaitingChunkTerminator = false; chunkRemaining = nil
                continue
            }
            if chunkRemaining == nil {
                guard let end = pending.range(of: Data("\r\n".utf8)) else {
                    guard pending.count <= 1024 else { throw PinnedHTTPClient.Failure.malformedResponse }
                    return
                }
                let line = Data(pending[pending.startIndex..<end.lowerBound])
                pending.removeFirst(pending.distance(from: pending.startIndex, to: end.upperBound))
                let size = try chunkSize(line)
                if size == 0 { readingTrailers = true; continue }
                chunkRemaining = size
            }
            guard let remaining = chunkRemaining, !pending.isEmpty else { return }
            let count = min(remaining, pending.count)
            events.append(.body(Data(pending.prefix(count))))
            pending.removeFirst(count); chunkRemaining = remaining - count
            if chunkRemaining == 0 { awaitingChunkTerminator = true }
        }
    }

    private mutating func complete(_ events: [Event]) -> [Event] {
        guard !isComplete else { return events }
        isComplete = true; pending.removeAll(keepingCapacity: false)
        return events + [.complete]
    }

    private func chunkSize(_ line: Data) throws -> Int {
        guard let text = String(data: line, encoding: .ascii) else { throw PinnedHTTPClient.Failure.malformedResponse }
        let sizeToken = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !sizeToken.isEmpty, sizeToken.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }), let size = Int(sizeToken, radix: 16), size >= 0 else { throw PinnedHTTPClient.Failure.malformedResponse }
        return size
    }

    private func trailerEnd() -> Int? {
        if pending.starts(with: Data("\r\n".utf8)) { return 2 }
        return pending.range(of: Data("\r\n\r\n".utf8)).map {
            pending.distance(from: pending.startIndex, to: $0.upperBound)
        }
    }

    private func validateTrailers(_ bytes: Data) throws {
        guard bytes != Data("\r\n".utf8), let text = String(data: bytes, encoding: .ascii) else { return }
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":"), PinnedHTTPClient.isHTTPToken(String(line[..<colon])) else {
                throw PinnedHTTPClient.Failure.malformedResponse
            }
        }
    }
}

private final class ConnectionOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let method: String
    private let limits: PinnedHTTPClient.Limits
    private let queue = DispatchQueue(label: "PinnedHTTPClient.connection")
    private var buffer = Data()
    private var continuation: CheckedContinuation<PinnedHTTPClient.Response, Error>?
    private var idleTimer: DispatchWorkItem?
    private var finished = false
    private let lock = NSLock()

    init(connection: NWConnection, request: Data, method: String, limits: PinnedHTTPClient.Limits) {
        self.connection = connection; self.request = request; self.method = method; self.limits = limits
    }

    func run() async throws -> PinnedHTTPClient.Response {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PinnedHTTPClient.Response, Error>) in
                lock.lock()
                guard !finished else { lock.unlock(); continuation.resume(throwing: PinnedHTTPClient.Failure.cancelled); return }
                self.continuation = continuation; lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue); armIdle()
            }
        }, onCancel: { self.finish(.failure(PinnedHTTPClient.Failure.cancelled)) })
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            armIdle()
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)); return }
                self.receiveNext()
            })
        case .failed, .waiting: finish(.failure(PinnedHTTPClient.Failure.connectionFailed))
        case .cancelled: finish(.failure(PinnedHTTPClient.Failure.cancelled))
        default: break
        }
    }

    private func receiveNext() {
        armIdle()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, complete, error in
            guard let self else { return }
            self.disarmIdle()
            if let content { self.buffer.append(content) }
            do {
                if let response = try PinnedHTTPClient.decodeResponse(self.buffer, limits: self.limits, method: self.method, isComplete: complete) {
                    self.finish(.success(response)); return
                }
                if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)); return }
                if complete { self.finish(.failure(PinnedHTTPClient.Failure.malformedResponse)); return }
                self.receiveNext()
            } catch { self.finish(.failure(error)) }
        }
    }

    private func armIdle() {
        guard limits.idleTimeout > 0, limits.idleTimeout.isFinite else { return }
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(PinnedHTTPClient.Failure.timedOut)) }
        lock.lock(); guard !finished else { lock.unlock(); return }
        idleTimer?.cancel(); idleTimer = timer; lock.unlock()
        queue.asyncAfter(deadline: .now() + limits.idleTimeout, execute: timer)
    }

    private func disarmIdle() { lock.lock(); idleTimer?.cancel(); idleTimer = nil; lock.unlock() }

    private func finish(_ result: Result<PinnedHTTPClient.Response, Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true; idleTimer?.cancel(); idleTimer = nil
        let continuation = self.continuation; self.continuation = nil; lock.unlock()
        connection.cancel(); continuation?.resume(with: result)
    }
}

private final class StreamingConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let method: String
    private let limits: PinnedHTTPClient.Limits
    private let onHead: @Sendable (PinnedHTTPClient.ResponseHead) async throws -> Void
    private let onBody: @Sendable (Data) async throws -> Void
    private let queue = DispatchQueue(label: "PinnedHTTPClient.stream")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var workerTask: Task<Void, Never>?
    private var idleTimer: DispatchWorkItem?
    private var framer: StreamFramer
    private var deliveredHead = false
    private var finished = false

    init(connection: NWConnection, request: Data, method: String, limits: PinnedHTTPClient.Limits,
         onHead: @escaping @Sendable (PinnedHTTPClient.ResponseHead) async throws -> Void,
         onBody: @escaping @Sendable (Data) async throws -> Void) {
        self.connection = connection; self.request = request; self.method = method; self.limits = limits
        self.onHead = onHead; self.onBody = onBody; self.framer = StreamFramer(method: method, limits: limits)
    }

    var didDeliverHead: Bool { lock.lock(); defer { lock.unlock() }; return deliveredHead }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock(); guard !finished else { lock.unlock(); continuation.resume(throwing: PinnedHTTPClient.Failure.cancelled); return }
                self.continuation = continuation; lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue); armIdle()
            }
        }, onCancel: { self.finish(.failure(PinnedHTTPClient.Failure.cancelled)) })
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            armIdle()
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)) } else { self.receiveNext() }
            })
        case .failed, .waiting: finish(.failure(PinnedHTTPClient.Failure.connectionFailed))
        case .cancelled: finish(.failure(PinnedHTTPClient.Failure.cancelled))
        default: break
        }
    }

    private func receiveNext() {
        armIdle()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
            guard let self else { return }
            self.disarmIdle()
            self.processCallback(content: content ?? Data(), complete: complete, error: error)
        }
    }

    /// The sole callback task is retained here and cancelled by `finish`; a new receive starts only after it ends.
    private func processCallback(content: Data, complete: Bool, error: NWError?) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let events = try self.framer.consume(content, endOfStream: complete)
                for event in events {
                    try Task.checkCancellation()
                    switch event {
                    case let .head(head): self.markHeadDelivered(); try await self.onHead(head)
                    case let .body(bytes): if !bytes.isEmpty { try await self.onBody(bytes) }
                    case .complete: self.finish(.success(())); return
                    }
                }
                if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)); return }
                if complete { self.finish(.failure(PinnedHTTPClient.Failure.malformedResponse)); return }
                if !self.isFinished { self.receiveNext() }
            } catch is CancellationError { self.finish(.failure(PinnedHTTPClient.Failure.cancelled)) }
            catch { self.finish(.failure(error)) }
        }
        workerTask = task; lock.unlock()
    }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func markHeadDelivered() {
        lock.lock(); deliveredHead = true; lock.unlock()
    }

    private func armIdle() {
        guard limits.idleTimeout > 0, limits.idleTimeout.isFinite else { return }
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(PinnedHTTPClient.Failure.timedOut)) }
        lock.lock(); guard !finished else { lock.unlock(); return }
        idleTimer?.cancel(); idleTimer = timer; lock.unlock()
        queue.asyncAfter(deadline: .now() + limits.idleTimeout, execute: timer)
    }

    private func disarmIdle() { lock.lock(); idleTimer?.cancel(); idleTimer = nil; lock.unlock() }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true; idleTimer?.cancel(); idleTimer = nil
        let task = workerTask; workerTask = nil
        let continuation = self.continuation; self.continuation = nil; lock.unlock()
        task?.cancel(); connection.cancel(); continuation?.resume(with: result)
    }
}
