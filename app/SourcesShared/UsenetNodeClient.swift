import Foundation

/// Local `/nzb/create` transport, injectable without launching a server or touching a provider account.
enum UsenetNodeClient {
    enum ClientError: Error, Equatable {
        case createFailed(Int), badResponse, unsafeEndpoint, nativeUnavailable, unsupportedArchive, invalidSelector
        case selectionUnmatched, nativeRejected
        /// A native refusal whose body carried one of the engine's fixed reason codes (never free text).
        case nativeFailed(Int, String)

        /// No file could be chosen for the requested episode: names tagged with another episode, or names
        /// with no episode tag at all and no pattern to follow.
        var isEpisodeSelectionMiss: Bool {
            self == .selectionUnmatched || self == .nativeFailed(422, "selection_unsupported")
        }
    }

    /// The native engine's fixed failure vocabulary. Only these exact codes are ever surfaced; any other
    /// body text is dropped, because a provider response could echo an NZB URL or credentials.
    static let nativeReasonCodes: Set<String> = [
        "invalid_request", "unsupported_archive_or_encoding", "article_integrity_failed", "provider_timeout",
        "session_closed", "resource_limit", "provider_unavailable", "selection_unmatched", "selection_ambiguous",
        "selection_unsupported", "invalid_selector", "operation_cancelled", "operation_reused",
        // The NZB link answered with an indexer refusal (limits, key) or with something that is not an NZB.
        "nzb_indexer_error", "nzb_unreadable",
    ]

    /// Only fixed reason labels/numeric codes may reach diagnostics. Error descriptions and provider
    /// response bodies can contain an NZB URL or NNTP credentials.
    static func failureReason(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? ClientError {
            switch failure {
            case .createFailed(let status): return "http_\(status)"
            case .badResponse: return "invalid_response"
            case .unsafeEndpoint: return "unsafe_endpoint"
            case .nativeUnavailable: return "native_capabilities_unavailable"
            case .unsupportedArchive: return "unsupported_archive"
            case .invalidSelector: return "invalid_selector"
            case .selectionUnmatched: return "selection_unmatched"
            case .nativeRejected: return "native_rejected"
            case .nativeFailed(let status, let reason): return "http_\(status)_\(reason)"
            }
        }
        if let failure = error as? URLError { return "network_\(failure.code.rawValue)" }
        return "resolver_error"
    }

    struct Endpoint: Sendable, Equatable {
        let base: String
    }

    struct Selection: Sendable {
        struct Episode: Sendable { let season: Int; let episode: Int }
        var fileIdx: Int? = nil
        var fileMustInclude: String? = nil
        var episode: Episode? = nil
        /// The requested episode's absolute number across the series (season 1 onwards, specials excluded).
        var absoluteEpisode: Int? = nil

        /// Anime is often released by absolute number ("Show - 061", "Show.S01E61") while the catalogue counts
        /// per season (S02E05). This last attempt asks for that number: as S01E<n> for names carrying a tag, and
        /// as an exact-number pattern for names without one (the engine applies the pattern only when a name
        /// has no tag, and still rejects a pattern that matches more than one file). The regex avoids
        /// look-around, which the engine's regex engine does not support.
        var absoluteNumberRetry: Selection? {
            guard let absolute = absoluteEpisode, let episode, episode.season != 1 || episode.episode != absolute else { return nil }
            return Selection(fileIdx: nil, fileMustInclude: "(?:^|[^0-9])0*\(absolute)(?:[^0-9]|$)",
                             episode: Episode(season: 1, episode: absolute))
        }

        /// The resident title's episode numbers for the absolute-number retry. CoreBridge installs the provider
        /// at start; anywhere it is not installed the list is empty and the retry never runs.
        @MainActor static var residentEpisodeNumbers: () -> [(season: Int?, episode: Int?)] = { [] }

        /// The absolute number of `season`x`episode` in this episode list, or nil when it is not in it.
        static func absoluteEpisode(season: Int, episode: Int, in videos: [(season: Int?, episode: Int?)]) -> Int? {
            struct Number: Hashable, Comparable {
                let season: Int, episode: Int
                static func < (a: Number, b: Number) -> Bool { (a.season, a.episode) < (b.season, b.episode) }
            }
            let numbers = Set(videos.compactMap { video -> Number? in
                guard let s = video.season, let e = video.episode, s >= 1, e >= 1 else { return nil }
                return Number(season: s, episode: e)
            }).sorted()
            return numbers.firstIndex(of: Number(season: season, episode: episode)).map { $0 + 1 }
        }

        /// The second, add-on-trusting attempt after a strict selection matched nothing: only the add-on's
        /// own `fileMustInclude`, without VortX's season/episode numbers or a `fileIdx` whose order may be the
        /// add-on's rather than the engine's. nil when the add-on gave no pattern (there is nothing to trust).
        /// The engine still refuses a pattern that matches more than one file, so this cannot pick a random one.
        var addonPatternOnly: Selection? {
            guard let pattern = fileMustInclude,
                  !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  episode != nil || fileIdx != nil else { return nil }
            return Selection(fileIdx: nil, fileMustInclude: pattern, episode: nil)
        }

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
        /// The engine can download a release ahead of playback to disk (see `UsenetDiskAllowance`).
        let diskPreload: Bool?
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
                               timeout: timeout, selection: selection, ownerIsCurrent: ownerIsCurrent)
    }

    static func createStream(base: String, nzbURLs: [String], servers: [String], session: URLSession,
                             timeout: TimeInterval, selection: Selection = Selection(),
                             ownerIsCurrent: @escaping @Sendable () async -> Bool) async throws -> CreatedStream {
        guard let origin = NativeTransportPolicy.localControlBase(base) else { throw ClientError.unsafeEndpoint }
        try Task.checkCancellation()
        guard await ownerIsCurrent() else { throw CancellationError() }
        guard selection.isValid else { throw ClientError.invalidSelector }
        let noRedirects = NoRedirects()
        var probe = URLRequest(url: origin.appendingPathComponent("nzb/capabilities"))
        probe.timeoutInterval = min(timeout, 4)
        probe.cachePolicy = .reloadIgnoringLocalCacheData
        let (capabilities, response) = try await session.data(for: probe, delegate: noRedirects)
        guard acceptsNativeCapabilities(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                        body: capabilities) else { throw ClientError.nativeUnavailable }
        try Task.checkCancellation()
        if (try? JSONDecoder().decode(NativeCapabilities.self, from: capabilities))?.diskPreload == true,
           let allowance = UsenetDiskAllowance.current() {
            await postDiskAllowance(origin: origin, bytes: allowance, session: session)
            try Task.checkCancellation()
        }
        let lease = OperationLease(origin: origin, session: session, ownerIsCurrent: ownerIsCurrent)
        lease.startMonitoring()
        do {
            return try await withTaskCancellationHandler {
                try await lease.validateOwner()
                try Task.checkCancellation()
                return try await postCreate(origin: origin, nzbURLs: nzbURLs, servers: servers,
                    session: session, timeout: timeout, selection: selection, lease: lease)
            } onCancel: { lease.close() }
        } catch {
            lease.close()
            throw error
        }
    }

    /// Tell the engine how much of a release it may download ahead to disk. Best-effort: a failure only
    /// leaves the engine on its previous (or default) allowance.
    private static func postDiskAllowance(origin: URL, bytes: Int64, session: URLSession) async {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["nzbDiskCacheBytes": bytes]) else { return }
        var request = URLRequest(url: origin.appendingPathComponent("settings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 2
        _ = try? await session.data(for: request, delegate: NoRedirects())
    }

    private static func postCreate(origin: URL, nzbURLs: [String], servers: [String], session: URLSession,
                                   timeout: TimeInterval, selection: Selection,
                                   lease: OperationLease) async throws -> CreatedStream {
        let createURL = origin.appendingPathComponent("nzb/create")
        var body: [String: Any] = ["servers": servers, "nzbUrls": nzbURLs, "operationId": lease.id]
        if let index = selection.fileIdx { body["fileIdx"] = index }
        if let pattern = selection.fileMustInclude { body["fileMustInclude"] = pattern }
        if let episode = selection.episode {
            body["episode"] = ["season": episode.season, "episode": episode.episode]
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
        try await lease.validateOwner()
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 422 {
            // A 422 also covers a selector with no matching file. Do not turn every native refusal
            // into an archive diagnosis, and never log the untrusted response text.
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch object?["error"] as? String {
            case "selection_unmatched": throw ClientError.selectionUnmatched
            case "unsupported_archive", "unsupported_archive_or_encoding": throw ClientError.unsupportedArchive
            case let reason? where nativeReasonCodes.contains(reason): throw ClientError.nativeFailed(code, reason)
            default: throw ClientError.nativeRejected
            }
        }
        guard (200...299).contains(code) else {
            // Keep the engine's fixed reason (e.g. provider_unavailable vs provider_timeout) so a failed
            // play is diagnosable; the status alone hid whether the NZB download or the provider failed.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reason = object["error"] as? String, nativeReasonCodes.contains(reason) {
                throw ClientError.nativeFailed(code, reason)
            }
            throw ClientError.createFailed(code)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty else { throw ClientError.badResponse }
        // A stream key is one opaque value, never additional query parameters or a fragment.
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

/// What to tell the user when an NZB could not be played through their own providers, chosen only from
/// the engine's fixed reason codes (never provider text). nil keeps the generic message.
enum UsenetFailureMessage {
    static func forLocalReason(_ reason: String) -> String? {
        if reason.contains("provider_timeout") || reason.hasPrefix("http_504") || reason == "network_-1001" {
            return "Your usenet providers didn't finish opening this release in time. Try again, or pick a release split into fewer parts."
        }
        if reason.contains("selection_") {
            return "This NZB doesn't contain this episode in a way VortX can identify. Try a single-episode release."
        }
        if reason.contains("unsupported_archive") {
            return "This release is packed in a way on-device playback can't read (compressed or encrypted). Try another release."
        }
        if reason.contains("provider_unavailable") || reason.contains("article_integrity") || reason.hasPrefix("http_502") {
            return "Your usenet providers couldn't fetch this release. It may have been removed or be incomplete. Try another release."
        }
        if reason.contains("resource_limit") || reason.hasPrefix("http_503") {
            return "This release is too large to open on this device right now. Try another release."
        }
        return nil
    }
}

/// How much of a usenet release the engine may download ahead of playback to disk, from the Streaming
/// cache setting (the player's own key, with its never-more-than-half-of-free-space safety). nil when the
/// setting was never touched, so the engine keeps its own 2 GB default; 0 when the viewer chose Off;
/// Unlimited is half of the free space, enough for a whole film on most devices.
enum UsenetDiskAllowance {
    static let settingKey = "stremiox.diskCacheBytes"
    static let unlimitedSentinel: Int64 = -1
    private static let unknownFreeSpaceCeiling: Int64 = 2 * 1024 * 1024 * 1024

    static func bytes(stored: Int64?, freeDisk: Int64?) -> Int64? {
        guard let stored else { return nil }
        if stored == 0 { return 0 }
        let ceiling = freeDisk.map { max(0, $0 / 2) } ?? unknownFreeSpaceCeiling
        return stored == unlimitedSentinel ? ceiling : min(max(stored, 0), ceiling)
    }

    static func current() -> Int64? {
        let stored = (UserDefaults.standard.object(forKey: settingKey) as? NSNumber)?.int64Value
        return bytes(stored: stored, freeDisk: freeDiskBytes())
    }

    private static func freeDiskBytes() -> Int64? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        #if !os(tvOS)
        if let values = try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        #endif
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: caches.path),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }
}
