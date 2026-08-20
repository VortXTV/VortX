import Foundation
import Network
import Security

/// A deliberately small HTTPS/HTTP1.1 transport for untrusted community add-on traffic. It resolves a host
/// exactly once, rejects a mixed or non-public answer set, then gives Network.framework a numeric peer while
/// retaining the original hostname for both TLS SNI and HTTP Host. No URLSession is involved, so it cannot
/// perform a second resolver lookup after this policy decision.
enum PinnedHTTPClient {
    struct Limits: Sendable, Equatable {
        var maximumHeaderBytes = 32 * 1024
        var maximumBodyBytes = 16 * 1024 * 1024
        var maximumWireBytes = 17 * 1024 * 1024
        /// Retained control-plane responses stay small; forwarded media has a separate hard ceiling so a
        /// malicious origin cannot hold a route forever while normal feature-length streams still work.
        var maximumStreamBytes = 8 * 1024 * 1024 * 1024
        var timeout: TimeInterval = 20
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

    /// The portion of a response that is safe to retain while a potentially very large body is forwarded.
    /// Streaming callers must never need to accumulate the media body just to inspect status or ranges.
    struct ResponseHead: Sendable, Equatable {
        let statusCode: Int
        let headers: [String: String]
    }

    enum Failure: Error, Equatable {
        case invalidURL
        case unsafeResolution
        case unsupportedMethod
        case unsafeHeader
        case requestTooLarge
        case malformedResponse
        case responseTooLarge
        case redirect(Int)
        case timedOut
        case cancelled
        case connectionFailed
    }

    typealias Resolver = @Sendable (_ host: String) throws -> [String]

    static func endpoint(for url: URL, answers: [String]) throws -> Endpoint {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              !answers.isEmpty, answers.allSatisfy(JSProviderURLPolicy.isPublicNumericAddress) else {
            throw Failure.unsafeResolution
        }
        let explicitPort = url.port
        guard explicitPort == nil || (1...65_535).contains(explicitPort!) else { throw Failure.invalidURL }
        let port = UInt16(explicitPort ?? 443)
        let hostHeader = explicitPort == nil || explicitPort == 443 ? host : "\(host):\(port)"
        return Endpoint(address: answers.sorted()[0], port: port, tlsServerName: host, hostHeader: hostHeader)
    }

    static let systemResolver: Resolver = { host in
        guard let addresses = JSProviderURLPolicy.vettedNumericAddresses(for: host) else { throw Failure.unsafeResolution }
        return addresses
    }

    /// Constructs the exact bytes written after a pinned TLS connection is ready. Percent-encoded path and
    /// query bytes retain their original ordering; neither URLComponents nor a dictionary reconstructs them.
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
        guard request.url.scheme?.lowercased() == "https", JSProviderURLPolicy.default.isAllowed(request.url), let host = request.url.host else {
            throw Failure.invalidURL
        }
        let endpoint = try endpoint(for: request.url, answers: resolver(host))
        let bytes = try requestBytes(for: request, endpoint: endpoint, limits: limits)
        return try await withTimeout(limits.timeout) {
            try await exchange(bytes: bytes, endpoint: endpoint, limits: limits)
        }
    }

    /// Opens one exact-peer HTTPS connection and forwards body bytes only after the consumer has accepted
    /// the response head. The next upstream receive is not scheduled until `onBody` returns, providing
    /// natural backpressure all the way to the loopback client.
    static func stream(
        _ request: Request,
        limits: Limits = .init(),
        resolver: @escaping Resolver = PinnedHTTPClient.systemResolver,
        onHead: @escaping @Sendable (ResponseHead) async throws -> Void,
        onBody: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard request.url.scheme?.lowercased() == "https", JSProviderURLPolicy.default.isAllowed(request.url), let host = request.url.host else {
            throw Failure.invalidURL
        }
        let endpoint = try endpoint(for: request.url, answers: resolver(host))
        let bytes = try requestBytes(for: request, endpoint: endpoint, limits: limits)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.tlsServerName)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.prohibitExpensivePaths = false
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.address), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: parameters)
        try await StreamingConnection(connection: connection, request: bytes, limits: limits, onHead: onHead, onBody: onBody).run()
    }

    static func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
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

    private static func exchange(bytes: Data, endpoint: Endpoint, limits: Limits) async throws -> Response {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.tlsServerName)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.prohibitExpensivePaths = false
        let port = NWEndpoint.Port(rawValue: endpoint.port)!
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.address), port: port, using: parameters)
        return try await ConnectionOperation(connection: connection, request: bytes, limits: limits).run()
    }

    static func decodeResponse(_ wire: Data, limits: Limits) throws -> Response? {
        guard wire.count <= limits.maximumWireBytes else { throw Failure.responseTooLarge }
        guard let separator = wire.range(of: Data("\r\n\r\n".utf8)) else {
            if wire.count > limits.maximumHeaderBytes { throw Failure.responseTooLarge }
            return nil
        }
        guard separator.lowerBound <= limits.maximumHeaderBytes,
              let headerText = String(data: wire[..<separator.lowerBound], encoding: .utf8) else { throw Failure.malformedResponse }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " "), status.count >= 2, let code = Int(status[1]), (100...599).contains(code) else {
            throw Failure.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformedResponse }
            let key = String(line[..<colon]).lowercased()
            guard isHTTPToken(key) else { throw Failure.malformedResponse }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let body = Data(wire[separator.upperBound...])
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            guard let decoded = try decodeChunked(body, limit: limits.maximumBodyBytes) else { return nil }
            return Response(statusCode: code, headers: headers, body: decoded)
        }
        if let value = headers["content-length"] {
            guard let expected = Int(value), expected >= 0 else { throw Failure.malformedResponse }
            if expected > limits.maximumBodyBytes { throw Failure.responseTooLarge }
            guard body.count >= expected else { return nil }
            return Response(statusCode: code, headers: headers, body: Data(body.prefix(expected)))
        }
        guard body.count <= limits.maximumBodyBytes else { throw Failure.responseTooLarge }
        return Response(statusCode: code, headers: headers, body: body)
    }

    fileprivate static func decodeHead(_ wire: Data, limits: Limits) throws -> (head: ResponseHead, body: Data)? {
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
            guard isHTTPToken(key) else { throw Failure.malformedResponse }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw Failure.malformedResponse }
            if headers[key] != nil { throw Failure.malformedResponse }
            headers[key] = value
        }
        return (ResponseHead(statusCode: code, headers: headers), Data(wire[separator.upperBound...]))
    }

    private static func decodeChunked(_ body: Data, limit: Int) throws -> Data? {
        var cursor = body.startIndex
        var output = Data()
        while true {
            guard let lineEnd = body.range(of: Data("\r\n".utf8), options: [], in: cursor..<body.endIndex),
                  let text = String(data: body[cursor..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(text.split(separator: ";", maxSplits: 1)[0], radix: 16), size >= 0 else { return nil }
            cursor = lineEnd.upperBound
            guard body.distance(from: cursor, to: body.endIndex) >= size + 2 else { return nil }
            if size == 0 { return output }
            guard output.count + size <= limit else { throw Failure.responseTooLarge }
            output.append(body[cursor..<body.index(cursor, offsetBy: size)])
            cursor = body.index(cursor, offsetBy: size + 2)
        }
    }

    static func isHTTPToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 33 || (35...39).contains(scalar.value) || (42...43).contains(scalar.value) ||
                (45...46).contains(scalar.value) || (48...57).contains(scalar.value) ||
                (65...90).contains(scalar.value) || (94...122).contains(scalar.value) || scalar.value == 124 || scalar.value == 126
        }
    }
}

private final class ConnectionOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let limits: PinnedHTTPClient.Limits
    private let queue = DispatchQueue(label: "PinnedHTTPClient.connection")
    private var buffer = Data()
    private var continuation: CheckedContinuation<PinnedHTTPClient.Response, Error>?
    private var finished = false
    private let lock = NSLock()

    init(connection: NWConnection, request: Data, limits: PinnedHTTPClient.Limits) {
        self.connection = connection
        self.request = request
        self.limits = limits
    }

    func run() async throws -> PinnedHTTPClient.Response {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: PinnedHTTPClient.Failure.cancelled)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue)
            }
        }, onCancel: { self.finish(.failure(PinnedHTTPClient.Failure.cancelled)) })
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)); return }
                self.receiveNext()
            })
        case .failed, .waiting:
            finish(.failure(PinnedHTTPClient.Failure.connectionFailed))
        case .cancelled:
            finish(.failure(PinnedHTTPClient.Failure.cancelled))
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, complete, error in
            guard let self else { return }
            if let content { self.buffer.append(content) }
            do {
                if let response = try PinnedHTTPClient.decodeResponse(self.buffer, limits: self.limits) {
                    self.finish(.success(response)); return
                }
                if complete { self.finish(.failure(PinnedHTTPClient.Failure.malformedResponse)); return }
                if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)); return }
                self.receiveNext()
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<PinnedHTTPClient.Response, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Separate from `ConnectionOperation`: that type intentionally retains small control-plane responses,
/// while this one never retains a media body after it has been acknowledged by its consumer.
private final class StreamingConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let limits: PinnedHTTPClient.Limits
    private let onHead: @Sendable (PinnedHTTPClient.ResponseHead) async throws -> Void
    private let onBody: @Sendable (Data) async throws -> Void
    private let queue = DispatchQueue(label: "PinnedHTTPClient.stream")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var head: PinnedHTTPClient.ResponseHead?
    private var pending = Data()
    private var remaining: Int?
    private var chunkRemaining: Int?
    private var streamedBytes = 0

    init(
        connection: NWConnection,
        request: Data,
        limits: PinnedHTTPClient.Limits,
        onHead: @escaping @Sendable (PinnedHTTPClient.ResponseHead) async throws -> Void,
        onBody: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.connection = connection
        self.request = request
        self.limits = limits
        self.onHead = onHead
        self.onBody = onBody
    }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue)
            }
        }, onCancel: { self.finish(.failure(PinnedHTTPClient.Failure.cancelled)) })
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)) }
                else { self.receiveNext() }
            })
        case .failed, .waiting:
            finish(.failure(PinnedHTTPClient.Failure.connectionFailed))
        case .cancelled:
            finish(.failure(PinnedHTTPClient.Failure.cancelled))
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    if let content { self.pending.append(content) }
                    try await self.consume(complete: complete)
                    if self.isFinished { return }
                    if error != nil { self.finish(.failure(PinnedHTTPClient.Failure.connectionFailed)); return }
                    if complete {
                        if self.head != nil, self.remaining == nil, self.chunkRemaining == nil, self.pending.isEmpty {
                            self.finish(.success(()))
                        } else {
                            self.finish(.failure(PinnedHTTPClient.Failure.malformedResponse))
                        }
                        return
                    }
                    self.receiveNext()
                } catch is CancellationError {
                    self.finish(.failure(PinnedHTTPClient.Failure.cancelled))
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func consume(complete: Bool) async throws {
        if head == nil {
            guard let parsed = try PinnedHTTPClient.decodeHead(pending, limits: limits) else { return }
            head = parsed.head
            pending = parsed.body
            if let value = parsed.head.headers["content-length"] {
                guard let length = Int(value), length >= 0, length <= limits.maximumStreamBytes else { throw PinnedHTTPClient.Failure.responseTooLarge }
                remaining = length
            } else if parsed.head.headers["transfer-encoding"]?.lowercased() == "chunked" {
                remaining = nil
            } else if parsed.head.statusCode == 204 || parsed.head.statusCode == 304 {
                remaining = 0
            }
            try await onHead(parsed.head)
            if remaining == 0 { finish(.success(())); return }
        }

        guard let head else { return }
        if head.headers["transfer-encoding"]?.lowercased() == "chunked" {
            try await consumeChunked()
        } else if let remaining {
            guard pending.count <= remaining else { throw PinnedHTTPClient.Failure.malformedResponse }
            if !pending.isEmpty { try await forward(pending); self.remaining = remaining - pending.count; pending.removeAll(keepingCapacity: true) }
            if self.remaining == 0 { finish(.success(())) }
        } else if !pending.isEmpty {
            try await forward(pending)
            pending.removeAll(keepingCapacity: true)
        }
        _ = complete
    }

    private func consumeChunked() async throws {
        while true {
            if chunkRemaining == nil {
                guard let end = pending.range(of: Data("\r\n".utf8)) else {
                    guard pending.count <= 1024 else { throw PinnedHTTPClient.Failure.malformedResponse }
                    return
                }
                guard let line = String(data: pending[..<end.lowerBound], encoding: .ascii),
                      let size = Int(line.split(separator: ";", maxSplits: 1)[0], radix: 16), size >= 0,
                      size <= limits.maximumStreamBytes else { throw PinnedHTTPClient.Failure.malformedResponse }
                pending.removeSubrange(..<end.upperBound)
                if size == 0 {
                    // Trailer fields are irrelevant to a loopback media response. The terminating CRLF is
                    // sufficient; reject only an unbounded trailer rather than retaining it.
                    if let end = pending.range(of: Data("\r\n\r\n".utf8)) { pending.removeSubrange(..<end.upperBound) }
                    finish(.success(())); return
                }
                chunkRemaining = size
            }
            guard let size = chunkRemaining, pending.count >= size + 2 else { return }
            let payload = Data(pending.prefix(size))
            let suffix = pending.index(pending.startIndex, offsetBy: size)
            guard pending[suffix] == 13, pending[pending.index(after: suffix)] == 10 else { throw PinnedHTTPClient.Failure.malformedResponse }
            pending.removeSubrange(..<pending.index(suffix, offsetBy: 2))
            chunkRemaining = nil
            try await forward(payload)
        }
    }

    private func forward(_ bytes: Data) async throws {
        guard streamedBytes <= limits.maximumStreamBytes - bytes.count else { throw PinnedHTTPClient.Failure.responseTooLarge }
        streamedBytes += bytes.count
        if !bytes.isEmpty { try await onBody(bytes) }
    }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(with: result)
    }
}
