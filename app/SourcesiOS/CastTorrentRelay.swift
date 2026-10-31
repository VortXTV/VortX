#if os(iOS) && !CINEMA_UI_SMOKE_RENDERER
import Foundation
import Network
import Darwin

/// Exposes one pinned progressive MP4 torrent file after an explicit Cast action. Never exposes the
/// native engine's settings/create/delete/proxy routes. No Bonjour advertisement and no background lease.
final class CastTorrentRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tv.vortx.cast-relay", qos: .utility)
    private let lock = NSLock()
    private var valid = false
    private var revoked = false
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var expiry: DispatchWorkItem?
    private let token: String
    private let source: URL
    private let nativeBase: URL
    private var startup: ((Result<URL, Error>) -> Void)?
    private var host = ""

    init(source: URL, nativeBase: URL) throws {
        guard CastTorrentRelayPolicy.sourceIsPinned(source, nativeBase: nativeBase) else { throw CastMediaProbe.Failure.unsafe }
        self.source = source; self.nativeBase = nativeBase
        var generator = SystemRandomNumberGenerator()
        token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
    private var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    private func setValid(_ value: Bool) { lock.lock(); valid = value && !revoked; lock.unlock() }
    private func revoke() { lock.lock(); valid = false; revoked = true; lock.unlock() }
    private var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !self.isRevoked, self.listener == nil, let address = Self.wifiIPv4() else {
                        continuation.resume(throwing: CastMediaProbe.Failure.unavailable); return
                    }
                    self.host = address
                    self.startup = { continuation.resume(with: $0) }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredInterfaceType = .wifi
                        parameters.includePeerToPeer = false
                        let listener = try NWListener(using: parameters, on: .any)
                        self.listener = listener; self.setValid(true)
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port,
                                      let url = URL(string: "http://\(self.host):\(port.rawValue)/cast/\(self.token)/media.mp4"),
                                      self.isValid else { self.close(); return }
                                self.finishStartup(.success(url))
                            case .failed(let error): self.finishStartup(.failure(error)); self.close()
                            case .cancelled: self.finishStartup(.failure(CastMediaProbe.Failure.unavailable))
                            default: break
                            }
                        }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard let self, self.startup != nil else { return }
                            self.finishStartup(.failure(CastMediaProbe.Failure.unavailable)); self.close()
                        }
                        let expiry = DispatchWorkItem { [weak self] in self?.close() }
                        self.expiry = expiry
                        self.queue.asyncAfter(deadline: .now() + 6 * 60 * 60, execute: expiry)
                    } catch { self.finishStartup(.failure(error)); self.close() }
                }
            }
        } onCancel: { self.stop() }
    }
    func stop() {
        // Revoke before returning to the source/account owner; queue cleanup can follow without allowing
        // another request through the capability gate.
        revoke()
        queue.async { self.close() }
    }
    private func finishStartup(_ result: Result<URL, Error>) { let callback = startup; startup = nil; callback?(result) }
    private func close() {
        revoke()
        finishStartup(.failure(CastMediaProbe.Failure.unavailable))
        expiry?.cancel(); expiry = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let active = Array(clients.values); clients.removeAll()
        active.forEach { $0.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        guard isValid, clients.count < 8,
              VortxNativeServer.publishedBaseURL.flatMap(URL.init(string:)) == nativeBase else { connection.cancel(); return }
        let id = UUID()
        let client = Client(connection: connection, queue: queue, token: token, source: source,
                            valid: { [weak self] in self?.isValid == true
                                && VortxNativeServer.publishedBaseURL.flatMap(URL.init(string:)) == self?.nativeBase },
                            finished: { [weak self] in self?.clients.removeValue(forKey: id) })
        clients[id] = client; client.start()
    }

    /// Restrict advertisement to the normal Wi-Fi IPv4 interface. VPN, cellular, AWDL, loopback and
    /// link-local addresses do not become receiver endpoints. No guess at the conventional engine port.
    private static func wifiIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard String(cString: item.ifa_name) == "en0", item.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if ReceiverURLPolicy.scope(host) == .lan { return host }
        }
        return nil
    }

    private final class Client: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        let token: String
        let source: URL
        let valid: () -> Bool
        let finished: () -> Void
        var header = Data()
        var session: URLSession?
        var task: URLSessionDataTask?
        var method = "GET"
        var headersSent = false
        var rejecting = false
        var closed = false
        var pendingSends = 0
        var upstreamFinished = false
        var headerDeadline: DispatchWorkItem?
        init(connection: NWConnection, queue: DispatchQueue, token: String, source: URL,
             valid: @escaping () -> Bool, finished: @escaping () -> Void) {
            self.connection = connection; self.queue = queue; self.token = token; self.source = source
            self.valid = valid; self.finished = finished
        }
        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.cancel() }
                if case .cancelled = state { self?.cancel() }
            }
            connection.start(queue: queue)
            let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
            headerDeadline = timeout; queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            receive()
        }
        func receive() {
            guard !closed, valid(), header.count < 8192 else { reject(); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(4096, 8192 - header.count)) { [weak self] data, _, done, error in
                guard let self, !self.closed else { return }
                if let data { self.header.append(data) }
                if let delimiter = self.header.range(of: Data("\r\n\r\n".utf8)) {
                    guard delimiter.upperBound == self.header.endIndex,
                          let text = String(data: self.header, encoding: .utf8),
                          let request = CastTorrentRelayPolicy.request(text, token: self.token), self.valid() else { self.reject(); return }
                    self.headerDeadline?.cancel(); self.headerDeadline = nil
                    self.open(request)
                } else if done || error != nil { self.cancel() } else { self.receive() }
            }
        }
        func open(_ request: CastTorrentRelayPolicy.Request) {
            method = request.method
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 6 * 60 * 60
            let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
            let session = URLSession(configuration: config, delegate: self, delegateQueue: operations)
            self.session = session
            var upstream = URLRequest(url: source); upstream.httpMethod = method
            upstream.cachePolicy = .reloadIgnoringLocalCacheData
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let range = request.range { upstream.setValue(range, forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: upstream); self.task = task; task.resume()
        }
        func reject() {
            guard !closed, !rejecting else { return }
            // Own the terminal response before upstream cancellation can complete synchronously.
            // Its completion/body callbacks must not send another 404 or close this write early.
            rejecting = true
            headerDeadline?.cancel(); headerDeadline = nil
            task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { [weak self] _ in self?.cancel() })
        }
        func cancel() {
            guard !closed else { return }; closed = true
            headerDeadline?.cancel(); headerDeadline = nil
            task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
            connection.stateUpdateHandler = nil; connection.cancel(); finished()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // A native media endpoint is final. Never let it redirect the LAN proxy to another endpoint.
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard valid(), !closed, !rejecting, let http = response as? HTTPURLResponse,
                  http.url == source, [200, 206, 416].contains(http.statusCode),
                  http.statusCode == 416 || http.mimeType?.lowercased() == "video/mp4",
                  let length = http.value(forHTTPHeaderField: "Content-Length") ?? (http.statusCode == 416 ? "0" : nil), UInt64(length) != nil else {
                reject(); completionHandler(.cancel); return
            }
            var headers = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n"
            for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
                if let value = http.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") { headers += "\(name): \(value)\r\n" }
            }
            if http.statusCode == 416, http.value(forHTTPHeaderField: "Content-Length") == nil { headers += "Content-Length: 0\r\n" }
            headers += "\r\n"; headersSent = true
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed, self.valid(), error == nil else { completionHandler(.cancel); self?.cancel(); return }
                completionHandler(self.method == "HEAD" ? .cancel : .allow)
                if self.method == "HEAD" { self.cancel() }
            })
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !closed, !rejecting, headersSent else { return }
            guard valid() else { cancel(); return }
            // Bound queued bytes by applying backpressure to URLSession until NWConnection consumes each
            // delegate chunk. No whole-movie Data, disk copy, range arithmetic, or unlimited buffered reader.
            dataTask.suspend(); pendingSends += 1
            connection.send(content: data, completion: .contentProcessed { [weak self, weak dataTask] error in
                guard let self, !self.closed else { return }
                self.pendingSends -= 1
                if error != nil || !self.valid() { self.cancel(); return }
                dataTask?.resume()
                if self.upstreamFinished && self.pendingSends == 0 { self.cancel() }
            })
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !closed, !rejecting else { return }
            upstreamFinished = true
            if !headersSent { reject() }
            else if error != nil || pendingSends == 0 { cancel() }
        }
    }
}
#endif
