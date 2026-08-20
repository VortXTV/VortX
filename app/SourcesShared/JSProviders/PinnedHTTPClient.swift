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
        if (300...399).contains(code) { throw Failure.redirect(code) }
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

    fileprivate static func isHTTPToken(_ value: String) -> Bool {
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
