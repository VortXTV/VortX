import Foundation
import Network
import Security
import Darwin

/// A small HTTPS/HTTP1.1 transport for untrusted community add-on traffic. Resolution happens once,
/// then each vetted numeric peer is attempted without allowing Network.framework to resolve the hostname again.
enum PinnedHTTPClient {
    struct Limits: Sendable, Equatable {
        var maximumHeaderBytes = 32 * 1024
        var maximumBodyBytes = 16 * 1024 * 1024
        var maximumWireBytes = 17 * 1024 * 1024
        var timeout: TimeInterval = 20
        var idleTimeout: TimeInterval = 10
        var maximumStreamDuration: TimeInterval?
        /// A separate stream policy cap. `Int.max` removes the former arbitrary 8 GiB rejection while
        /// retaining overflow-safe accounting and allowing a route to impose a smaller hard limit.
        var maximumStreamBytes = Int.max
        var maximumPeers = 8
        var maximumPeersPerFamily = 4
        var minimumPeerAttempt: TimeInterval = 0.25
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

    typealias Resolver = @Sendable (_ host: String) async throws -> [NumericAddress]

    static func endpoints(for url: URL, answers: [String]) throws -> [Endpoint] {
        try endpoints(for: url, answers: answers, limits: .init())
    }

    static func endpoints(for url: URL, answers: [String], limits: Limits) throws -> [Endpoint] {
        let addresses = try answers.map { answer -> NumericAddress in
            guard let address = NumericAddress.parse(answer), address.isPublic else { throw Failure.unsafeResolution }
            return address
        }
        return try endpoints(for: url, addresses: addresses, limits: limits)
    }

    private static func endpoints(for url: URL, addresses: [NumericAddress], limits: Limits) throws -> [Endpoint] {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              !addresses.isEmpty else {
            throw Failure.unsafeResolution
        }
        let explicitPort = url.port
        guard explicitPort == nil || (1...65_535).contains(explicitPort!) else { throw Failure.invalidURL }
        let port = UInt16(explicitPort ?? 443)
        let hostForHeader = host.contains(":") ? "[\(host)]" : host
        let hostHeader = explicitPort == nil || explicitPort == 443 ? hostForHeader : "\(hostForHeader):\(port)"
        var familyCount: [Int32: Int] = [:]
        guard limits.maximumPeers > 0, limits.maximumPeersPerFamily > 0 else { throw Failure.unsafeResolution }
        let distinct = Set(addresses).sorted()
        let selected = distinct.compactMap { address -> NumericAddress? in
            guard familyCount[address.family, default: 0] < limits.maximumPeersPerFamily else { return nil }
            familyCount[address.family, default: 0] += 1
            return address
        }
        guard !selected.isEmpty else { throw Failure.unsafeResolution }
        return selected.prefix(limits.maximumPeers).map {
            Endpoint(address: $0.presentation, port: port, tlsServerName: host, hostHeader: hostHeader)
        }
    }

    /// Kept for focused callers that need a stable representative endpoint. Network operations use `endpoints`.
    static func endpoint(for url: URL, answers: [String]) throws -> Endpoint {
        guard let endpoint = try endpoints(for: url, answers: answers).first else { throw Failure.unsafeResolution }
        return endpoint
    }

    static let systemResolver: Resolver = { host in
        try await ResolverOperation.resolve(host)
    }

    static func requestBytes(for request: Request, endpoint: Endpoint, limits: Limits = .init()) throws -> Data {
        guard request.method == "GET" || request.method == "HEAD" else { throw Failure.unsupportedMethod }
        let forbidden = Set(["host", "content-length", "transfer-encoding", "connection", "upgrade", "proxy-connection"])
        guard request.headers.allSatisfy({ name, value in
            isHTTPToken(name) && !forbidden.contains(name.lowercased()) && isValidFieldValue(value)
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
        let deadline = ProcessInfo.processInfo.systemUptime + limits.timeout
        return try await withTimeout(limits.timeout) {
            let (peers, bytes) = try await prepare(request, limits: limits, resolver: resolver)
            return try await attemptPeers(peers, deadline: deadline, limits: limits) { endpoint, timeout in
                try await withTimeout(timeout) {
                try await exchange(bytes: bytes, endpoint: endpoint, limits: limits, method: request.method)
                }
            }
        }
    }

    /// Peers are retried only before a response head reaches the consumer: retrying after a head would create
    /// two downstream HTTP responses for one client request.
    static func stream(_ request: Request, limits: Limits = .init(), resolver: @escaping Resolver = PinnedHTTPClient.systemResolver,
                       onHead: @escaping @Sendable (ResponseHead) async throws -> Void,
                       onBody: @escaping @Sendable (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + limits.timeout
        let (peers, bytes) = try await withTimeout(limits.timeout) {
            try await prepare(request, limits: limits, resolver: resolver)
        }
        var lastFailure: Error = Failure.connectionFailed
        for (index, endpoint) in peers.enumerated() {
            try Task.checkCancellation()
            let timeout = try peerAttemptTimeout(for: index, peers: peers, deadline: deadline, limits: limits)
            let operation = StreamingConnection(connection: makeConnection(endpoint), request: bytes, method: request.method,
                                               limits: limits, onHead: onHead, onBody: onBody)
            do { try await operation.run(responseHeadTimeout: timeout); return }
            catch {
                if operation.didDeliverHead { throw error }
                lastFailure = error
            }
        }
        throw lastFailure
    }

    static func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let nanoseconds = timeoutNanoseconds(timeout) else { throw Failure.timedOut }
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: nanoseconds)
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

    static func isCleanEOF(_ complete: Bool, hasError: Bool) -> Bool {
        complete && !hasError
    }

    static func decodeResponse(_ wire: Data, limits: Limits, method: String = "GET", isComplete: Bool = false) throws -> Response? {
        guard wire.count <= limits.maximumWireBytes else { throw Failure.responseTooLarge }
        guard let parsed = try decodeHead(wire, limits: limits) else { return nil }
        switch try bodyFraming(method: method, head: parsed.head) {
        case .none:
            guard parsed.body.isEmpty else { throw Failure.malformedResponse }
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: Data())
        case .chunked:
            guard let decoded = try decodeChunked(parsed.body, limit: limits.maximumBodyBytes) else { return nil }
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: decoded)
        case let .contentLength(expected):
            guard expected <= limits.maximumBodyBytes else { throw Failure.responseTooLarge }
            guard parsed.body.count >= expected else { return nil }
            guard parsed.body.count == expected else { throw Failure.malformedResponse }
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: parsed.body)
        case .closeDelimited:
            guard isComplete else { return nil }
            guard parsed.body.count <= limits.maximumBodyBytes else { throw Failure.responseTooLarge }
            return Response(statusCode: parsed.head.statusCode, headers: parsed.head.headers, body: parsed.body)
        }
    }

    static func decodeHead(_ wire: Data, limits: Limits) throws -> (head: ResponseHead, body: Data)? {
        var pending = wire
        var informationalCount = 0
        while true {
            guard let parsed = try decodeSingleHead(pending, limits: limits) else { return nil }
            if (100...199).contains(parsed.head.statusCode) {
                guard parsed.head.statusCode != 101,
                      parsed.head.headers["content-length"] == nil,
                      parsed.head.headers["transfer-encoding"] == nil else { throw Failure.malformedResponse }
                informationalCount += 1
                guard informationalCount <= 8 else { throw Failure.malformedResponse }
                pending = parsed.body
                continue
            }
            return parsed
        }
    }

    private static func decodeSingleHead(_ wire: Data, limits: Limits) throws -> (head: ResponseHead, body: Data)? {
        guard wire.count <= limits.maximumWireBytes else { throw Failure.responseTooLarge }
        guard let separator = wire.range(of: Data("\r\n\r\n".utf8)) else {
            if wire.count > limits.maximumHeaderBytes { throw Failure.responseTooLarge }
            return nil
        }
        guard separator.lowerBound <= limits.maximumHeaderBytes,
              let headerText = String(data: wire[..<separator.lowerBound], encoding: .utf8) else { throw Failure.malformedResponse }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, let code = parseStatusCode(statusLine) else { throw Failure.malformedResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformedResponse }
            let key = String(line[..<colon]).lowercased()
            let value = trimOWS(String(line[line.index(after: colon)...]))
            guard isHTTPToken(key), isValidFieldValue(value), headers[key] == nil else {
                throw Failure.malformedResponse
            }
            headers[key] = value
        }
        if statusLine.hasPrefix("HTTP/1.0 "), headers["transfer-encoding"] != nil {
            throw Failure.malformedResponse
        }
        return (ResponseHead(statusCode: code, headers: headers), Data(wire[separator.upperBound...]))
    }

    static func bodyFraming(method: String, head: ResponseHead) throws -> BodyFraming {
        let transferEncoding = try parseTransferEncoding(head.headers["transfer-encoding"])
        if transferEncoding != nil, head.headers["content-length"] != nil { throw Failure.malformedResponse }
        if head.statusCode == 204, (transferEncoding != nil || head.headers["content-length"] != nil) { throw Failure.malformedResponse }
        if method.uppercased() == "HEAD" || head.statusCode == 304 { return .none }
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
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false).map { trimOWS(String($0)) }
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

    static func isValidFieldValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || (32...126).contains(scalar.value)
        }
    }

    private static func parseStatusCode(_ line: String) -> Int? {
        guard line.hasPrefix("HTTP/1.0 ") || line.hasPrefix("HTTP/1.1 ") else { return nil }
        let start = line.index(line.startIndex, offsetBy: 9)
        guard line.distance(from: start, to: line.endIndex) >= 3 else { return nil }
        let end = line.index(start, offsetBy: 3)
        let code = line[start..<end]
        guard code.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let result = Int(code), (100...599).contains(result) else { return nil }
        guard end == line.endIndex else {
            guard line[end] == " " else { return nil }
            let reasonStart = line.index(after: end)
            let reason = String(line[reasonStart...])
            guard !reason.isEmpty, isValidFieldValue(reason) else { return nil }
            return result
        }
        return result
    }

    static func trimOWS(_ value: String) -> String {
        var scalars = value.unicodeScalars
        while let first = scalars.first, first.value == 32 || first.value == 9 { scalars.removeFirst() }
        while let last = scalars.last, last.value == 32 || last.value == 9 { scalars.removeLast() }
        return String(scalars)
    }

    private static func prepare(_ request: Request, limits: Limits, resolver: Resolver) async throws -> ([Endpoint], Data) {
        guard request.url.scheme?.lowercased() == "https", request.url.user == nil, request.url.password == nil,
              JSProviderURLPolicy.default.isAllowed(request.url), let host = request.url.host else {
            throw Failure.invalidURL
        }
        let peers = try endpoints(for: request.url, addresses: try await resolver(host), limits: limits)
        return (peers, try requestBytes(for: request, endpoint: peers[0], limits: limits))
    }

    private static func attemptPeers<T: Sendable>(_ peers: [Endpoint], deadline: TimeInterval, limits: Limits,
                                                   attempt: @escaping @Sendable (Endpoint, TimeInterval) async throws -> T) async throws -> T {
        var lastFailure: Error = Failure.connectionFailed
        for (index, peer) in peers.enumerated() {
            try Task.checkCancellation()
            let attemptTimeout = try peerAttemptTimeout(for: index, peers: peers, deadline: deadline, limits: limits)
            do { return try await attempt(peer, attemptTimeout) }
            catch is CancellationError { throw Failure.cancelled }
            catch { lastFailure = error }
        }
        throw lastFailure
    }

    private static func peerAttemptTimeout(for index: Int, peers: [Endpoint], deadline: TimeInterval, limits: Limits) throws -> TimeInterval {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure.timedOut }
        return fairPeerAttemptTimeout(remaining: remaining, peersRemaining: peers.count - index, minimum: limits.minimumPeerAttempt)
    }

    static func fairPeerAttemptTimeout(remaining: TimeInterval, peersRemaining: Int, minimum: TimeInterval) -> TimeInterval {
        guard remaining > 0, remaining.isFinite, peersRemaining > 0 else { return 0 }
        let fairShare = remaining / Double(peersRemaining)
        let floor = minimum.isFinite && minimum > 0 ? minimum : 0
        return min(remaining, max(floor, fairShare))
    }

    static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64? {
        // Leave one second of headroom for Double rounding before the checked integer conversion.
        let maximum = Double(UInt64.max) / 1_000_000_000 - 1
        guard timeout > 0, timeout.isFinite, timeout <= maximum else { return nil }
        return UInt64(timeout * 1_000_000_000)
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
        chunkLimits.maximumStreamBytes = limit
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

/// A resolver answer is retained as address-family bytes. String input is accepted only at the test/public
/// seam, where it is parsed once with inet_pton; production resolution copies the sockaddr bytes directly.
private func numericAddressBytes<T>(_ value: T) -> Data {
    var copy = value
    return withUnsafeBytes(of: &copy) { Data($0) }
}

struct NumericAddress: Hashable, Comparable, Sendable {
    let family: Int32
    let bytes: Data
    let presentation: String

    static func < (lhs: NumericAddress, rhs: NumericAddress) -> Bool {
        if lhs.family != rhs.family { return lhs.family > rhs.family }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    static func == (lhs: NumericAddress, rhs: NumericAddress) -> Bool {
        lhs.family == rhs.family && lhs.bytes == rhs.bytes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(family)
        hasher.combine(bytes)
    }

    static func parse(_ value: String) -> NumericAddress? {
        guard !value.isEmpty, !value.contains("["), !value.contains("]"), !value.contains("%") else { return nil }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            return NumericAddress(family: AF_INET, bytes: numericAddressBytes(ipv4), presentation: value)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            return NumericAddress(family: AF_INET6, bytes: numericAddressBytes(ipv6), presentation: value)
        }
        return nil
    }

    var isPublic: Bool {
        let octets = [UInt8](bytes)
        switch family {
        case AF_INET:
            return Self.isPublicIPv4(octets)
        case AF_INET6:
            guard octets.count == 16 else { return false }
            // A mapped address is never an eligible peer, even if its embedded IPv4 is public.
            if octets.prefix(10).allSatisfy({ $0 == 0 }) && octets[10] == 0xFF && octets[11] == 0xFF { return false }
            // Globally routed IPv6 is 2000::/3. This also rejects unspecified, loopback, ULA, link-local,
            // multicast, site-local, and the well-known/local-use NAT64 prefixes outside that range.
            guard (octets[0] & 0xE0) == 0x20 else { return false }
            // 2001:db8::/32 documentation; Teredo, ORCHID, and 6to4 transition spaces are fail-closed.
            if octets[0] == 0x20 && octets[1] == 0x01 {
                if octets[2] == 0x0D && octets[3] == 0xB8 { return false }
                if octets[2] == 0x00 && (octets[3] == 0x00 || (0x10...0x1F).contains(octets[3])) { return false }
            }
            if octets[0] == 0x20 && octets[1] == 0x02 { return false }
            return true
        default:
            return false
        }
    }

    func usesPREF64Prefix(_ prefixes: Set<Data>) -> Bool {
        family == AF_INET6 && prefixes.contains(Data(bytes.prefix(12)))
    }

    private static func isPublicIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        let a = octets[0], b = octets[1], c = octets[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 0 || b == 88 || b == 168) { return false }
        if a == 192 && b == 31 && c == 196 { return false }
        if a == 192 && b == 52 && c == 193 { return false }
        if a == 192 && b == 175 && c == 48 { return false }
        if a == 192 && b == 0 && c == 2 { return false }
        if a == 198 && (18...19).contains(b) { return false }
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }
}

/// getaddrinfo is blocking and cannot be interrupted by Darwin. This bridge lets cancellation/timeouts
/// resume the awaiting task immediately and suppresses the eventual result; no detached Swift task outlives it.
private final class ResolverOperation: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "PinnedHTTPClient.resolver", qos: .utility, attributes: .concurrent)
    private static let maximumResolvedPeers = 8
    private static let maximumResolvedPeersPerFamily = 4
    private let host: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[NumericAddress], Error>?
    private var cancelled = false

    private init(host: String) { self.host = host }

    static func resolve(_ host: String) async throws -> [NumericAddress] {
        let operation = ResolverOperation(host: host)
        return try await operation.run()
    }

    private func run() async throws -> [NumericAddress] {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NumericAddress], Error>) in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: PinnedHTTPClient.Failure.cancelled); return }
                self.continuation = continuation
                lock.unlock()
                Self.queue.async { [weak self] in self?.resolveOnQueue() }
            }
        }, onCancel: { self.cancel() })
    }

    private func resolveOnQueue() {
        lock.lock()
        let shouldResolve = !cancelled
        lock.unlock()
        guard shouldResolve else { return }
        complete(Self.resolveBlocking(host))
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: PinnedHTTPClient.Failure.cancelled)
    }

    private func complete(_ result: Result<[NumericAddress], Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func resolveBlocking(_ host: String) -> Result<[NumericAddress], Error> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return .failure(PinnedHTTPClient.Failure.unsafeResolution)
        }
        defer { freeaddrinfo(result) }
        var answers = Set<NumericAddress>()
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            let info = current.pointee
            cursor = info.ai_next
            guard let socketAddress = info.ai_addr else { return .failure(PinnedHTTPClient.Failure.unsafeResolution) }
            switch info.ai_family {
            case AF_INET:
                let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addressCopy = address
                guard inet_ntop(AF_INET, &addressCopy, &text, socklen_t(text.count)) != nil else {
                    return .failure(PinnedHTTPClient.Failure.unsafeResolution)
                }
                let answer = NumericAddress(family: AF_INET, bytes: numericAddressBytes(address), presentation: String(cString: text))
                guard answer.isPublic else { return .failure(PinnedHTTPClient.Failure.unsafeResolution) }
                answers.insert(answer)
            case AF_INET6:
                let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var addressCopy = address
                guard inet_ntop(AF_INET6, &addressCopy, &text, socklen_t(text.count)) != nil else {
                    return .failure(PinnedHTTPClient.Failure.unsafeResolution)
                }
                let answer = NumericAddress(family: AF_INET6, bytes: numericAddressBytes(address), presentation: String(cString: text))
                guard answer.isPublic else { return .failure(PinnedHTTPClient.Failure.unsafeResolution) }
                answers.insert(answer)
            default:
                return .failure(PinnedHTTPClient.Failure.unsafeResolution)
            }
            let familyPeers = answers.filter { $0.family == info.ai_family }.count
            guard familyPeers <= maximumResolvedPeersPerFamily, answers.count <= maximumResolvedPeers else {
                return .failure(PinnedHTTPClient.Failure.unsafeResolution)
            }
        }
        let activePREF64Prefixes = pref64Prefixes()
        guard !answers.contains(where: { $0.usesPREF64Prefix(activePREF64Prefixes) }) else {
            return .failure(PinnedHTTPClient.Failure.unsafeResolution)
        }
        return answers.isEmpty ? .failure(PinnedHTTPClient.Failure.unsafeResolution) : .success(answers.sorted())
    }

    /// RFC 7050 discovery returns synthesized 192.0.0.170/171 answers. Prefixes found here are active on
    /// the current network, so target answers carrying one are refused rather than being used as a NAT64 tunnel.
    private static func pref64Prefixes() -> Set<Data> {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("ipv4only.arpa", nil, &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }
        var prefixes = Set<Data>()
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            let info = current.pointee
            cursor = info.ai_next
            guard info.ai_family == AF_INET6, let socketAddress = info.ai_addr else { continue }
            let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            let bytes = [UInt8](numericAddressBytes(address))
            guard bytes.count == 16, bytes[12] == 192, bytes[13] == 0, bytes[14] == 0,
                  bytes[15] == 170 || bytes[15] == 171 else { continue }
            prefixes.insert(Data(bytes.prefix(12)))
        }
        return prefixes
    }
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
    private var streamedBytes = 0
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
            if case let .contentLength(length)? = framing, length > limits.maximumStreamBytes {
                throw PinnedHTTPClient.Failure.responseTooLarge
            }
            events.append(.head(parsed.head))
            if framing == PinnedHTTPClient.BodyFraming.none {
                guard pending.isEmpty else { throw PinnedHTTPClient.Failure.malformedResponse }
                return complete(events)
            }
        }
        guard let framing else { return events }
        switch framing {
        case let .contentLength(length):
            if contentRemaining == nil { contentRemaining = length }
            if let remaining = contentRemaining, !pending.isEmpty {
                let count = min(remaining, pending.count)
                if count > 0 {
                    try appendBody(Data(pending.prefix(count)), into: &events)
                    pending.removeFirst(count)
                    contentRemaining = remaining - count
                }
            }
            if contentRemaining == 0 {
                guard pending.isEmpty else { throw PinnedHTTPClient.Failure.malformedResponse }
                return complete(events)
            }
        case .chunked:
            try consumeChunked(into: &events)
            if isComplete { return events }
        case .closeDelimited:
            if !pending.isEmpty {
                try appendBody(pending, into: &events)
                pending.removeAll(keepingCapacity: false)
            }
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
                guard trailerEnd <= limits.maximumHeaderBytes else { throw PinnedHTTPClient.Failure.responseTooLarge }
                try validateTrailers(Data(pending.prefix(trailerEnd)))
                pending.removeFirst(trailerEnd)
                guard pending.isEmpty else { throw PinnedHTTPClient.Failure.malformedResponse }
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
                guard line.count <= 1024 else { throw PinnedHTTPClient.Failure.malformedResponse }
                pending.removeFirst(pending.distance(from: pending.startIndex, to: end.upperBound))
                let size = try chunkSize(line)
                if size == 0 { readingTrailers = true; continue }
                chunkRemaining = size
            }
            guard let remaining = chunkRemaining, !pending.isEmpty else { return }
            let count = min(remaining, pending.count)
            try appendBody(Data(pending.prefix(count)), into: &events)
            pending.removeFirst(count); chunkRemaining = remaining - count
            if chunkRemaining == 0 { awaitingChunkTerminator = true }
        }
    }

    private mutating func complete(_ events: [Event]) -> [Event] {
        guard !isComplete else { return events }
        isComplete = true; pending.removeAll(keepingCapacity: false)
        return events + [.complete]
    }

    private mutating func appendBody(_ bytes: Data, into events: inout [Event]) throws {
        guard limits.maximumStreamBytes >= 0,
              streamedBytes <= limits.maximumStreamBytes,
              bytes.count <= limits.maximumStreamBytes - streamedBytes else {
            throw PinnedHTTPClient.Failure.responseTooLarge
        }
        streamedBytes += bytes.count
        events.append(.body(bytes))
    }

    private func chunkSize(_ line: Data) throws -> Int {
        guard let text = String(data: line, encoding: .ascii) else { throw PinnedHTTPClient.Failure.malformedResponse }
        guard !text.contains(";"), !text.isEmpty, text.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }), let size = Int(text, radix: 16), size >= 0 else { throw PinnedHTTPClient.Failure.malformedResponse }
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
        let prohibited = Set(["transfer-encoding", "content-length", "host", "connection", "trailer", "te", "upgrade", "proxy-connection", "keep-alive"])
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw PinnedHTTPClient.Failure.malformedResponse }
            let name = String(line[..<colon]).lowercased()
            let value = PinnedHTTPClient.trimOWS(String(line[line.index(after: colon)...]))
            guard PinnedHTTPClient.isHTTPToken(name), !prohibited.contains(name), PinnedHTTPClient.isValidFieldValue(value) else {
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
                if let response = try PinnedHTTPClient.decodeResponse(self.buffer, limits: self.limits, method: self.method,
                                                                       isComplete: PinnedHTTPClient.isCleanEOF(complete, hasError: error != nil)) {
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
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private var receiveContinuation: CheckedContinuation<(Data, Bool, NWError?), Error>?
    private var terminalError: Error?
    private var idleTimer: DispatchWorkItem?
    private var responseHeadTimer: DispatchWorkItem?
    private var hardLifetimeTimer: DispatchWorkItem?
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

    func run(responseHeadTimeout: TimeInterval) async throws {
        try Task.checkCancellation()
        guard responseHeadTimeout > 0, responseHeadTimeout.isFinite else { throw PinnedHTTPClient.Failure.timedOut }
        try await withTaskCancellationHandler(operation: {
            defer { finish() }
            armResponseHeadTimeout(responseHeadTimeout)
            try await start()
            try await sendRequest()
            while true {
                let received = try await receiveNext()
                disarmIdle()
                if received.error != nil { throw terminalOrConnectionFailure() }
                let events = try framer.consume(received.content, endOfStream: received.complete)
                for event in events {
                    try Task.checkCancellation()
                    switch event {
                    case let .head(head):
                        markHeadDelivered()
                        disarmResponseHeadTimeout()
                        armHardLifetime()
                        try await onHead(head)
                    case let .body(bytes):
                        if !bytes.isEmpty { try await onBody(bytes) }
                    case .complete:
                        finish()
                        return
                    }
                }
                if received.complete { throw PinnedHTTPClient.Failure.malformedResponse }
            }
        }, onCancel: { self.cancel(with: PinnedHTTPClient.Failure.cancelled) })
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready: resumeReady(.success(()))
        case .failed, .waiting: cancel(with: PinnedHTTPClient.Failure.connectionFailed)
        case .cancelled: cancel(with: PinnedHTTPClient.Failure.cancelled)
        default: break
        }
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard !finished else { lock.unlock(); continuation.resume(throwing: terminalOrConnectionFailure()); return }
            readyContinuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.start(queue: queue)
        }
    }

    private func sendRequest() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard !finished else { lock.unlock(); continuation.resume(throwing: terminalOrConnectionFailure()); return }
            sendContinuation = continuation
            lock.unlock()
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                let continuation = self.sendContinuation
                self.sendContinuation = nil
                self.lock.unlock()
                guard let continuation else { return }
                if error == nil { continuation.resume() } else { continuation.resume(throwing: self.terminalOrConnectionFailure()) }
            })
        }
    }

    private func receiveNext() async throws -> (content: Data, complete: Bool, error: NWError?) {
        armIdle()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Bool, NWError?), Error>) in
            lock.lock()
            guard !finished else { lock.unlock(); continuation.resume(throwing: terminalOrConnectionFailure()); return }
            receiveContinuation = continuation
            lock.unlock()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
                guard let self else { return }
                self.lock.lock()
                let continuation = self.receiveContinuation
                self.receiveContinuation = nil
                self.lock.unlock()
                guard let continuation else { return }
                if self.isFinished { continuation.resume(throwing: self.terminalOrConnectionFailure()); return }
                continuation.resume(returning: (content ?? Data(), complete, error))
            }
        }
    }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func markHeadDelivered() {
        lock.lock(); deliveredHead = true; lock.unlock()
    }

    private func resumeReady(_ result: Result<Void, Error>) {
        lock.lock(); let continuation = readyContinuation; readyContinuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }

    private func armIdle() {
        guard limits.idleTimeout > 0, limits.idleTimeout.isFinite else { return }
        let timer = DispatchWorkItem { [weak self] in self?.cancel(with: PinnedHTTPClient.Failure.timedOut) }
        lock.lock(); guard !finished else { lock.unlock(); return }
        idleTimer?.cancel(); idleTimer = timer; lock.unlock()
        queue.asyncAfter(deadline: .now() + limits.idleTimeout, execute: timer)
    }

    private func disarmIdle() { lock.lock(); idleTimer?.cancel(); idleTimer = nil; lock.unlock() }

    private func armResponseHeadTimeout(_ timeout: TimeInterval) {
        let timer = DispatchWorkItem { [weak self] in self?.cancel(with: PinnedHTTPClient.Failure.timedOut) }
        lock.lock(); guard !finished else { lock.unlock(); return }
        responseHeadTimer = timer; lock.unlock()
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    private func disarmResponseHeadTimeout() { lock.lock(); responseHeadTimer?.cancel(); responseHeadTimer = nil; lock.unlock() }

    private func armHardLifetime() {
        guard let duration = limits.maximumStreamDuration, duration > 0, duration.isFinite else { return }
        let timer = DispatchWorkItem { [weak self] in self?.cancel(with: PinnedHTTPClient.Failure.timedOut) }
        lock.lock(); guard !finished else { lock.unlock(); return }
        hardLifetimeTimer = timer; lock.unlock()
        queue.asyncAfter(deadline: .now() + duration, execute: timer)
    }

    private func terminalOrConnectionFailure() -> Error {
        lock.lock(); defer { lock.unlock() }
        return terminalError ?? PinnedHTTPClient.Failure.connectionFailed
    }

    private func cancel(with error: Error) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true; terminalError = error
        idleTimer?.cancel(); idleTimer = nil
        responseHeadTimer?.cancel(); responseHeadTimer = nil
        hardLifetimeTimer?.cancel(); hardLifetimeTimer = nil
        let readyContinuation = self.readyContinuation; self.readyContinuation = nil
        let sendContinuation = self.sendContinuation; self.sendContinuation = nil
        let receiveContinuation = self.receiveContinuation; self.receiveContinuation = nil
        lock.unlock()
        connection.cancel()
        readyContinuation?.resume(throwing: error)
        sendContinuation?.resume(throwing: error)
        receiveContinuation?.resume(throwing: error)
    }

    private func finish() {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true
        idleTimer?.cancel(); responseHeadTimer?.cancel(); hardLifetimeTimer?.cancel()
        idleTimer = nil; responseHeadTimer = nil; hardLifetimeTimer = nil
        let readyContinuation = self.readyContinuation; self.readyContinuation = nil
        let sendContinuation = self.sendContinuation; self.sendContinuation = nil
        let receiveContinuation = self.receiveContinuation; self.receiveContinuation = nil
        lock.unlock()
        connection.cancel()
        let error = PinnedHTTPClient.Failure.cancelled
        readyContinuation?.resume(throwing: error)
        sendContinuation?.resume(throwing: error)
        receiveContinuation?.resume(throwing: error)
    }
}
