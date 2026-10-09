import Foundation

/// Local `/nzb/create` transport, injectable without launching a server or touching a provider account.
enum UsenetNodeClient {
    enum ClientError: Error, Equatable {
        case createFailed(Int), badResponse, unsafeEndpoint, nativeUnavailable, unsupportedArchive, invalidSelector
    }

    struct Endpoint: Sendable, Equatable {
        let base: String
        let requiresNativeCapabilities: Bool
    }

    struct Selection: Sendable {
        struct Episode: Sendable { let season: Int; let episode: Int }
        var fileIdx: Int? = nil
        var fileMustInclude: String? = nil
        var episode: Episode? = nil

        fileprivate var isValid: Bool {
            (fileIdx.map { (0..<131_072).contains($0) } ?? true)
                && (fileMustInclude.map { $0.utf8.count <= 512 } ?? true)
                && (episode.map { (0...9999).contains($0.season) && (1...9999).contains($0.episode) } ?? true)
        }
    }

    struct CreatedStream: Sendable {
        let url: URL
        let lease: OperationLease?
    }

    /// One native create, not one server. Copies of a playback reference share this lease; explicit
    /// retirement wins even when a launch request or prepared-episode snapshot still retains a copy.
    final class OperationLease: @unchecked Sendable, Equatable {
        let id = UUID().uuidString.lowercased()
        private let lock = NSLock()
        private var closed = false
        private var monitor: Task<Void, Never>?
        private var closeObservers: [@Sendable () -> Void] = []
        private let origin: URL
        private let cleanupSession: URLSession
        private let ownerIsCurrent: @Sendable () async -> Bool

        fileprivate init(origin: URL, session: URLSession,
                         ownerIsCurrent: @escaping @Sendable () async -> Bool) {
            self.origin = origin
            // The resolver closes its request session on return. Cleanup must outlive that session
            // and must not inherit the cancelled create task's cancellation state.
            let configuration = session.configuration
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 3
            cleanupSession = URLSession(configuration: configuration)
            self.ownerIsCurrent = ownerIsCurrent
        }

        static func == (lhs: OperationLease, rhs: OperationLease) -> Bool { lhs === rhs }
        var isClosed: Bool { lock.withLock { closed } }

        /// A consumer can retire its queued/paused work when authority closes. Never capture this
        /// lease in the observer; capture the consumer weakly. Callbacks run outside the lock and
        /// may arrive on any executor. Registration after retirement is notified immediately.
        func onClose(_ observer: @escaping @Sendable () -> Void) {
            let notifyNow = lock.withLock {
                guard !closed else { return true }
                closeObservers.append(observer)
                return false
            }
            if notifyNow { observer() }
        }

        fileprivate func startMonitoring() {
            let check = ownerIsCurrent
            lock.withLock {
                guard !closed else { return }
                monitor = Task.detached { [weak self] in
                    while !Task.isCancelled {
                        guard await check() else { self?.close(); return }
                        // Never hold the lease across a suspension: otherwise the monitor itself
                        // would prevent the final prepared/ref release from retiring the operation.
                        guard self != nil else { return }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
            }
        }

        /// Revalidate captured authority immediately before a consumer adopts the operation.
        /// `isClosed` alone is a state check, not a substitute for this admission check.
        func validateOwner() async throws {
            guard !Task.isCancelled, !isClosed, await ownerIsCurrent(), !isClosed, !Task.isCancelled else {
                close()
                throw CancellationError()
            }
        }

        /// A closed transport may still authorize a fresh same-owner Retry. This checks only
        /// captured authority, never whether this old operation can be reused (it cannot).
        func authorityIsCurrent() async -> Bool {
            guard !Task.isCancelled else { return false }
            return await ownerIsCurrent()
        }

        func close() {
            let observers = lock.withLock { () -> [@Sendable () -> Void]? in
                guard !closed else { return nil }
                closed = true
                monitor?.cancel()
                monitor = nil
                let observers = closeObservers
                closeObservers.removeAll()
                return observers
            }
            guard let observers else { return }
            for observer in observers { observer() }
            let session = cleanupSession
            let cancelURL = origin.appendingPathComponent("nzb/operations/\(id)/cancel")
            Task.detached(priority: .utility) {
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: cancelURL)
                request.httpMethod = "POST"
                request.timeoutInterval = 3
                request.cachePolicy = .reloadIgnoringLocalCacheData
                // Idempotent UUID cancellation also tombstones an unknown key. Retry only the same
                // operation, boundedly, if a transient loopback failure loses the acknowledgement.
                for attempt in 0..<3 {
                    if let (_, response) = try? await session.data(for: request, delegate: NoRedirects()),
                       (response as? HTTPURLResponse)?.statusCode == 204 { return }
                    if attempt < 2 { try? await Task.sleep(for: .milliseconds(250)) }
                }
            }
        }

        deinit { close() }
    }

    private struct NativeCapabilities: Decodable {
        let version: Int
        let raw: Bool
        let multipartYenc: Bool
        let checksumsRequired: Bool
        let archives: [String]
        let operationCancellation: Bool?
        let operationIdFormat: String?
        let selection: NativeSelection?
        struct NativeSelection: Decodable {
            let fileIdx: Bool
            let fileMustInclude: Bool
            let episode: Bool
            let fileIdxOrder: String
            let regexSyntax: String
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func acceptsNativeCapabilities(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 200, let capabilities = try? JSONDecoder().decode(NativeCapabilities.self, from: body),
              capabilities.version == 1, capabilities.raw, capabilities.multipartYenc, capabilities.checksumsRequired,
              capabilities.operationCancellation == true, capabilities.operationIdFormat == "uuid",
              let selection = capabilities.selection, selection.fileIdx, selection.fileMustInclude, selection.episode,
              selection.fileIdxOrder == "nzb-media-or-archive-entry-order", selection.regexSyntax == "bare-or-js-ims",
              Set(["rar4-store", "rar5-store", "7z-copy"]).isSubset(of: Set(capabilities.archives)) else { return false }
        return true
    }

    static func createStream(endpoint: Endpoint, nzbURLs: [String], servers: [String], session: URLSession,
                             timeout: TimeInterval, selection: Selection = Selection(),
                             ownerIsCurrent: @escaping @Sendable () async -> Bool) async throws -> CreatedStream {
        try await createStream(base: endpoint.base, nzbURLs: nzbURLs, servers: servers, session: session,
                               timeout: timeout, requiresNativeCapabilities: endpoint.requiresNativeCapabilities,
                               selection: selection, ownerIsCurrent: ownerIsCurrent)
    }

    static func createStream(base: String, nzbURLs: [String], servers: [String], session: URLSession,
                             timeout: TimeInterval, requiresNativeCapabilities: Bool = false,
                             selection: Selection = Selection(),
                             ownerIsCurrent: @escaping @Sendable () async -> Bool) async throws -> CreatedStream {
        guard let origin = NativeTransportPolicy.localControlBase(base) else { throw ClientError.unsafeEndpoint }
        try Task.checkCancellation()
        guard await ownerIsCurrent() else { throw CancellationError() }
        if requiresNativeCapabilities, !selection.isValid { throw ClientError.invalidSelector }
        let noRedirects = NoRedirects()
        if requiresNativeCapabilities {
            var probe = URLRequest(url: origin.appendingPathComponent("nzb/capabilities"))
            probe.timeoutInterval = min(timeout, 4)
            probe.cachePolicy = .reloadIgnoringLocalCacheData
            let (capabilities, response) = try await session.data(for: probe, delegate: noRedirects)
            guard acceptsNativeCapabilities(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                            body: capabilities) else { throw ClientError.nativeUnavailable }
            try Task.checkCancellation()
        }
        let lease = requiresNativeCapabilities
            ? OperationLease(origin: origin, session: session, ownerIsCurrent: ownerIsCurrent) : nil
        lease?.startMonitoring()
        do {
            return try await withTaskCancellationHandler {
                try await lease?.validateOwner()
                try Task.checkCancellation()
                return try await postCreate(origin: origin, nzbURLs: nzbURLs, servers: servers,
                    session: session, timeout: timeout, selection: selection, lease: lease)
            } onCancel: { lease?.close() }
        } catch {
            lease?.close()
            throw error
        }
    }

    private static func postCreate(origin: URL, nzbURLs: [String], servers: [String], session: URLSession,
                                   timeout: TimeInterval, selection: Selection,
                                   lease: OperationLease?) async throws -> CreatedStream {
        let createURL = origin.appendingPathComponent("nzb/create")
        var body: [String: Any] = ["servers": servers, "nzbUrls": nzbURLs]
        if let lease {
            body["operationId"] = lease.id
            if let index = selection.fileIdx { body["fileIdx"] = index }
            if let pattern = selection.fileMustInclude { body["fileMustInclude"] = pattern }
            if let episode = selection.episode {
                body["episode"] = ["season": episode.season, "episode": episode.episode]
            }
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw ClientError.badResponse }
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        try Task.checkCancellation()
        try await lease?.validateOwner()
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if lease != nil, code == 422 { throw ClientError.unsupportedArchive }
        guard (200...299).contains(code) else { throw ClientError.createFailed(code) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty else { throw ClientError.badResponse }
        // A Node key is one opaque value, never additional query parameters or a fragment.
        let keyCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: keyCharacters) else {
            throw ClientError.badResponse
        }
        guard let streamURL = URL(string: "\(origin.appendingPathComponent("nzb/stream").absoluteString)?key=\(encodedKey)") else {
            throw ClientError.badResponse
        }
        return CreatedStream(url: streamURL, lease: lease)
    }
}
