import Foundation
import Network

/// Loopback-only media gateway for streams produced by community JavaScript add-ons. Players receive an
/// opaque local URL rather than a provider URL, so every initial request, range retry, subtitle request, and
/// playlist child request crosses `PinnedHTTPClient` instead of letting a media framework resolve a hostname.
final class CommunityStreamGateway: @unchecked Sendable {
    typealias StreamOperation = @Sendable (
        PinnedHTTPClient.Request,
        @escaping @Sendable (PinnedHTTPClient.ResponseHead) async throws -> Void,
        @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Void

    static let shared = CommunityStreamGateway()

    enum Failure: Error, Equatable {
        case unavailable
        case invalidStream
        case expired
        case malformedRequest
    }

    struct Route: Sendable, Equatable {
        let upstream: URL
        let headers: [String: String]
        let expiresAt: Date
        let hardExpiresAt: Date
        let providerID: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "CommunityStreamGateway.listener")
    private var listener: NWListener?
    private var port: UInt16?
    private var routes: [String: Route] = [:]
    private var starting = false
    private let routeLifetime: TimeInterval = 60 * 30
    private let maximumRouteLifetime: TimeInterval = 60 * 60 * 6
    private let maximumRoutes = 256
    private let maximumPlaylistBytes = 2 * 1024 * 1024
    private let maximumClientHeaderBytes = 32 * 1024
    private let streamOperation: StreamOperation

    private convenience init() {
        self.init(streamOperation: { request, onHead, onBody in
            try await PinnedHTTPClient.stream(request, onHead: onHead, onBody: onBody)
        })
    }

    init(streamOperation: @escaping StreamOperation) { self.streamOperation = streamOperation }

    /// Starts a listener bound to 127.0.0.1 only. It is intentionally never exposed on LAN interfaces.
    func start() async throws {
        switch beginStart() {
        case .alreadyReady: return
        case .waiting: return try await waitForStart()
        case .start: break
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = GatewayStartCompletion(continuation)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    guard let self, let listener, let port = listener.port?.rawValue else {
                        completion.fail(Failure.unavailable); return
                    }
                    self.lock.lock()
                    self.listener = listener
                    self.port = port
                    self.starting = false
                    self.lock.unlock()
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    completion.succeed()
                case .failed(let error):
                    self?.lock.lock(); self?.starting = false; self?.lock.unlock()
                    completion.fail(error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private enum StartDecision { case alreadyReady, waiting, start }

    private func beginStart() -> StartDecision {
        lock.lock(); defer { lock.unlock() }
        if listener != nil { return .alreadyReady }
        if starting { return .waiting }
        starting = true
        return .start
    }

    /// Launch paths call this early; route registration remains synchronous for existing player APIs.
    func startIfNeededAsync() {
        Task.detached(priority: .utility) { [weak self] in
            do { try await self?.start() }
            catch { DiagnosticsLog.log("community-gateway", "loopback listener unavailable") }
        }
    }

    private func waitForStart() async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if isStarted() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.unavailable
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        self.port = nil
        self.starting = false
        self.routes.removeAll()
        lock.unlock()
        listener?.cancel()
    }

    /// Registers a provider URL and returns the only URL media clients may receive. No remote URL or request
    /// header is encoded into the local address. Every token is random, scoped to this process, and expires.
    func register(upstream: URL, headers: [String: String] = [:], providerID: String? = nil, now: Date = Date()) throws -> URL {
        guard upstream.scheme?.lowercased() == "https", JSProviderURLPolicy.default.isAllowed(upstream) else {
            throw Failure.invalidStream
        }
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        guard let port else { throw Failure.unavailable }
        if let token = routes.first(where: {
            $0.value.upstream == upstream && $0.value.headers == safeHeaders(headers) && $0.value.providerID == providerID
        })?.key {
            return URL(string: "http://127.0.0.1:\(port)/community/\(token)")!
        }
        if routes.count >= maximumRoutes, let oldest = routes.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            routes[oldest] = nil
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        routes[token] = Route(upstream: upstream, headers: safeHeaders(headers), expiresAt: now.addingTimeInterval(routeLifetime),
                              hardExpiresAt: now.addingTimeInterval(maximumRouteLifetime), providerID: providerID)
        return URL(string: "http://127.0.0.1:\(port)/community/\(token)")!
    }

    /// Adapts only streams carrying the community-provider provenance marker. This is the integration seam for
    /// iOS, macOS, tvOS, download, subtitle, and warm callers without altering other provider behavior.
    func localURL(for stream: CoreStream, upstream: URL, now: Date = Date()) throws -> URL? {
        guard stream.isCommunityJavaScriptProvider else { return nil }
        return try register(upstream: upstream, headers: stream.requestHeaders ?? [:], providerID: stream.vortxProvider, now: now)
    }

    /// Compatibility bridge for the existing synchronous `CoreStream.playableURL` contract. Launch starts
    /// the listener ahead of source resolution; if the process has not reached ready state yet, returning nil
    /// is deliberately fail-closed (and a bounded async start is requested) rather than exposing the remote URL.
    func localURLIfReady(for stream: CoreStream, upstream: URL) -> URL? {
        do { return try localURL(for: stream, upstream: upstream) }
        catch Failure.unavailable { startIfNeededAsync(); return nil }
        catch { return nil }
    }

    func invalidate(providerID: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let providerID { routes = routes.filter { $0.value.providerID != providerID } }
        else { routes.removeAll() }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopbackPeer(connection.endpoint) else { connection.cancel(); return }
        let lifetime = GatewayClientLifetime()
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: lifetime.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data(), lifetime: lifetime)
    }

    private static func isLoopbackPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == IPv4Address("127.0.0.1")
        case .ipv6(let address): return address == IPv6Address("::1")
        case .name(let name, _): return name.lowercased() == "localhost"
        @unknown default: return false
        }
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data, lifetime: GatewayClientLifetime) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] content, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let content { buffer.append(content) }
            if buffer.count > self.maximumClientHeaderBytes { self.reply(connection, status: "431 Request Header Fields Too Large"); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { self.reply(connection, status: "400 Bad Request") } else { self.receiveRequest(connection, buffer: buffer, lifetime: lifetime) }
                return
            }
            guard let header = String(data: buffer[..<end.lowerBound], encoding: .utf8), let parsed = self.parseRequest(header) else {
                self.reply(connection, status: "400 Bad Request"); return
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.serve(connection, request: parsed)
            }
            lifetime.install(task)
            if GatewayDownstreamReceivePolicy.shouldMonitor(initialRead: true, complete: complete, hasError: error != nil, lifetime: lifetime) {
                self.monitorDownstream(connection, lifetime: lifetime)
            }
        }
    }

    private func monitorDownstream(_ connection: NWConnection, lifetime: GatewayClientLifetime) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            guard let self else { return }
            if GatewayDownstreamReceivePolicy.shouldMonitor(initialRead: false, complete: complete, hasError: error != nil, lifetime: lifetime) {
                self.monitorDownstream(connection, lifetime: lifetime)
            }
        }
    }

    private struct ClientRequest { let method: String; let token: String; let range: String? }

    private func parseRequest(_ header: String) -> ClientRequest? {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first?.split(separator: " "), first.count == 3,
              first[0] == "GET" || first[0] == "HEAD", first[2] == "HTTP/1.1" else { return nil }
        let path = String(first[1])
        guard path.hasPrefix("/community/"), path.dropFirst("/community/".count).count == 32,
              path.dropFirst("/community/".count).allSatisfy({ $0.isHexDigit }) else { return nil }
        var range: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "range" {
                guard range == nil, validRange(value) else { return nil }
                range = value
            }
        }
        return ClientRequest(method: String(first[0]), token: String(path.dropFirst("/community/".count)), range: range)
    }

    private func serve(_ connection: NWConnection, request: ClientRequest) async {
        guard let route = route(for: request.token) else { reply(connection, status: "404 Not Found"); return }
        var headers = route.headers
        if let range = request.range { headers["Range"] = range }
        do {
            try await forwardFollowingRedirects(connection, request: request, upstream: route.upstream, headers: headers)
        } catch PinnedHTTPClient.Failure.unsafeResolution {
            reply(connection, status: "403 Forbidden")
        } catch PinnedHTTPClient.Failure.timedOut {
            reply(connection, status: "504 Gateway Timeout")
        } catch PinnedHTTPClient.Failure.cancelled {
            connection.cancel()
        } catch GatewayForwardFailure.downstreamStarted {
            connection.cancel()
        } catch {
            reply(connection, status: "502 Bad Gateway")
        }
    }

    private struct RedirectReceived: Error { let head: PinnedHTTPClient.ResponseHead }
    private enum GatewayForwardFailure: Error { case downstreamStarted }

    /// Follows redirects and streams the first non-redirect response from the request that discovered it.
    /// The old probe-then-forward shape fetched the final origin twice, which doubled signed-CDN hits and could
    /// consume a one-use URL before the player received any bytes.
    private func forwardFollowingRedirects(_ connection: NWConnection, request: ClientRequest,
                                            upstream: URL, headers: [String: String]) async throws {
        var currentURL = upstream
        var currentHeaders = headers
        for hop in 0...3 {
            let state = ForwardState(method: request.method, upstream: currentURL, headers: currentHeaders,
                                     maximumPlaylistBytes: maximumPlaylistBytes)
            do {
                try await streamOperation(
                    .init(url: currentURL, method: request.method, headers: currentHeaders),
                    { head in
                        if (300...399).contains(head.statusCode) { throw RedirectReceived(head: head) }
                        try await state.accept(head: head, send: { [weak self] status, responseHeaders in
                            guard let self else { throw Failure.unavailable }
                            try await self.sendHead(connection, status: status, headers: responseHeaders)
                        })
                    },
                    { [weak self] bytes in
                        guard let self else { throw Failure.unavailable }
                        try await state.accept(bytes: bytes, send: { body in
                            try await self.sendBody(connection, body: body)
                        })
                    }
                )
                if let body = try state.finish(rewrite: { body, base, routeHeaders, responseHeaders in
                    try self.rewritePlaylistIfNeeded(body, upstream: base, routeHeaders: routeHeaders,
                                                     responseHeaders: responseHeaders)
                }) {
                    let sent = request.method == "HEAD" ? Data() : body
                    try await sendHead(connection, status: state.status,
                                       headers: filteredHeaders(state.responseHeaders, bodyLength: body.count,
                                                                preserveLength: false))
                    if !sent.isEmpty { try await sendBody(connection, body: sent) }
                }
                connection.cancel()
                return
            } catch let redirect as RedirectReceived {
                guard hop < 3,
                      let value = redirect.head.headers["location"],
                      let next = URL(string: value, relativeTo: currentURL)?.absoluteURL,
                      next.scheme?.lowercased() == "https",
                      JSProviderURLPolicy.default.isAllowed(next) else {
                    throw PinnedHTTPClient.Failure.redirect(redirect.head.statusCode)
                }
                currentHeaders = CommunityGatewayTransportPolicy.childHeaders(currentHeaders, parent: currentURL, child: next)
                currentURL = next
            } catch {
                if state.hasSentHead { throw GatewayForwardFailure.downstreamStarted }
                throw error
            }
        }
        throw PinnedHTTPClient.Failure.redirect(310)
    }

    private func route(for token: String, now: Date = Date()) -> Route? {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now)
        guard var route = routes[token], route.hardExpiresAt > now else { routes[token] = nil; return nil }
        // Renew only an active route, never beyond its immutable hard lifetime. This lets a long HLS session
        // survive normal token rotation while a forgotten token still disappears deterministically.
        route = Route(upstream: route.upstream, headers: route.headers,
                      expiresAt: min(route.hardExpiresAt, now.addingTimeInterval(routeLifetime)),
                      hardExpiresAt: route.hardExpiresAt, providerID: route.providerID)
        routes[token] = route
        return route
    }

    private func pruneLocked(now: Date) { routes = routes.filter { $0.value.hardExpiresAt > now && $0.value.expiresAt > now } }

    private func isStarted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    private func rewritePlaylistIfNeeded(_ body: Data, upstream: URL, routeHeaders: [String: String], responseHeaders: [String: String]) throws -> Data {
        let contentType = responseHeaders["content-type"]?.lowercased() ?? ""
        guard contentType.contains("mpegurl") || upstream.path.lowercased().hasSuffix(".m3u8"),
              let playlist = String(data: body, encoding: .utf8) else { return body }
        let rewritten = playlist.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            let text = String(line)
            if text.hasPrefix("#") { return rewriteURIAttributes(in: text, upstream: upstream, headers: routeHeaders) }
            return rewriteChild(text, upstream: upstream, headers: routeHeaders)
        }.joined(separator: "\n")
        return Data(rewritten.utf8)
    }

    private func rewriteURIAttributes(in line: String, upstream: URL, headers: [String: String]) -> String {
        // RFC 8216 URI attributes occur on KEY, MAP, MEDIA, I-FRAME-STREAM-INF, RENDITION-REPORT,
        // PRELOAD-HINT and SESSION-KEY variants. Match the attribute grammar rather than a small tag list.
        let expression = try? NSRegularExpression(pattern: "(?i)URI=(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^,\\s]*))")
        guard let expression else { return line }
        let range = NSRange(line.startIndex..., in: line)
        let matches = expression.matches(in: line, range: range).reversed()
        var output = line
        for match in matches {
            let captured = [1, 2, 3].compactMap { index -> Range<String.Index>? in
                let r = match.range(at: index); return r.location == NSNotFound ? nil : Range(r, in: output)
            }.first
            guard let captured else { continue }
            output.replaceSubrange(captured, with: rewriteChild(String(output[captured]), upstream: upstream, headers: headers))
        }
        return output
    }

    private func rewriteChild(_ value: String, upstream: URL, headers: [String: String]) -> String {
        guard !value.isEmpty, let child = URL(string: value, relativeTo: upstream)?.absoluteURL,
              let local = try? register(upstream: child, headers: CommunityGatewayTransportPolicy.childHeaders(headers, parent: upstream, child: child)) else { return value }
        return local.absoluteString
    }

    private func filteredHeaders(_ input: [String: String], bodyLength: Int, preserveLength: Bool) -> [String: String] {
        let allowed = Set(["content-type", "content-range", "content-length", "accept-ranges", "cache-control", "etag", "last-modified"])
        var result = input.reduce(into: [String: String]()) { partial, entry in
            if allowed.contains(entry.key.lowercased()), !entry.value.contains("\r"), !entry.value.contains("\n") { partial[entry.key.lowercased()] = entry.value }
        }
        if !preserveLength || result["content-length"] == nil { result["content-length"] = String(bodyLength) }
        result["connection"] = "close"
        return result
    }

    private func safeHeaders(_ input: [String: String]) -> [String: String] {
        StreamRequestHeaderPolicy.sanitized(input)
    }

    private func sendHead(_ connection: NWConnection, status: String, headers: [String: String]) async throws {
        var fields = ["HTTP/1.1 \(status)"]
        fields += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        try await send(connection, data: Data((fields.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }

    private func sendBody(_ connection: NWConnection, body: Data) async throws { try await send(connection, data: body) }

    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { continuation.resume() } else { continuation.resume(throwing: PinnedHTTPClient.Failure.connectionFailed) }
            })
        }
    }

    private func reply(_ connection: NWConnection, status: String, headers: [String: String] = [:], body: Data = Data()) {
        var fields = ["HTTP/1.1 \(status)"]
        fields += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        let head = Data((fields.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: head + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func validRange(_ value: String) -> Bool {
        let bytes = value.utf8
        return value.hasPrefix("bytes=") && bytes.count <= 128 && bytes.allSatisfy { $0 == 45 || $0 == 44 || $0 == 61 || (48...57).contains($0) || $0 == 98 || $0 == 121 || $0 == 116 || $0 == 101 || $0 == 115 }
    }

    private func statusText(_ code: Int) -> String {
        switch code { case 200: return "OK"; case 206: return "Partial Content"; case 404: return "Not Found"; default: return "OK" }
    }
}

private final class GatewayStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func succeed() { finish(.success(())) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}

final class GatewayClientLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancelled { lock.unlock(); task.cancel(); return }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

enum GatewayDownstreamReceivePolicy {
    /// Bytes plus EOF in the initial receive are a legal TCP half-close: the player finished its GET and may
    /// still read the response. Once the request was parsed without EOF, a later receive EOF or transport error
    /// is a disconnect and cancels upstream. NWConnection failed/cancelled state is the remaining close signal.
    static func shouldMonitor(initialRead: Bool, complete: Bool, hasError: Bool, lifetime: GatewayClientLifetime) -> Bool {
        if hasError || (complete && !initialRead) { lifetime.cancel(); return false }
        return !complete
    }
}

enum CommunityGatewayTransportPolicy {
    static func childHeaders(_ headers: [String: String], parent: URL, child: URL) -> [String: String] {
        guard !sameOrigin(parent, child) else { return headers }
        let sensitive = Set(["authorization", "cookie", "origin", "referer"])
        return headers.filter { !sensitive.contains($0.key.lowercased()) }
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && effectivePort(first) == effectivePort(second)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}

/// Mutable per-client forwarding state. Access is serialized by `PinnedHTTPClient.stream`: a new upstream
/// receive is scheduled only after the previous callback returns, so this object cannot observe concurrent
/// body mutation and does not need an actor or an unbounded queue.
private final class ForwardState: @unchecked Sendable {
    let method: String
    let upstream: URL
    let routeHeaders: [String: String]
    let maximumPlaylistBytes: Int
    private(set) var responseHeaders: [String: String] = [:]
    private(set) var status = "502 Bad Gateway"
    private var playlist = false
    private var playlistBody = Data()
    private var headSent = false

    var hasSentHead: Bool { headSent }

    init(method: String, upstream: URL, headers: [String: String], maximumPlaylistBytes: Int) {
        self.method = method; self.upstream = upstream; self.routeHeaders = headers; self.maximumPlaylistBytes = maximumPlaylistBytes
    }

    func accept(head: PinnedHTTPClient.ResponseHead, send: @escaping @Sendable (String, [String: String]) async throws -> Void) async throws {
        responseHeaders = head.headers
        status = "\(head.statusCode) \(Self.statusText(head.statusCode))"
        let type = head.headers["content-type"]?.lowercased() ?? ""
        playlist = type.contains("mpegurl") || upstream.path.lowercased().hasSuffix(".m3u8")
        if !playlist {
            let length = Int(head.headers["content-length"] ?? "") ?? 0
            try await send(status, Self.filtered(head.headers, length: method == "HEAD" ? length : length, preserveLength: true))
            headSent = true
        }
    }

    func accept(bytes: Data, send: @escaping @Sendable (Data) async throws -> Void) async throws {
        if playlist {
            guard playlistBody.count <= maximumPlaylistBytes - bytes.count else { throw PinnedHTTPClient.Failure.responseTooLarge }
            playlistBody.append(bytes)
        } else if method != "HEAD" {
            try await send(bytes)
        }
    }

    func finish(rewrite: (Data, URL, [String: String], [String: String]) throws -> Data) throws -> Data? {
        guard playlist else { return nil }
        return try rewrite(playlistBody, upstream, routeHeaders, responseHeaders)
    }

    private static func filtered(_ headers: [String: String], length: Int, preserveLength: Bool) -> [String: String] {
        let allowed = Set(["content-type", "content-range", "content-length", "accept-ranges", "cache-control", "etag", "last-modified"])
        var out = headers.filter { allowed.contains($0.key.lowercased()) && !$0.value.contains("\r") && !$0.value.contains("\n") }
        if !preserveLength { out["content-length"] = String(length) }
        out["connection"] = "close"
        return out
    }

    private static func statusText(_ code: Int) -> String {
        switch code { case 200: return "OK"; case 206: return "Partial Content"; case 204: return "No Content"; case 404: return "Not Found"; case 416: return "Range Not Satisfiable"; default: return "OK" }
    }
}
