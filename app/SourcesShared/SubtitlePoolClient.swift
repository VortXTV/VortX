import Foundation

/// Client for VortX's community-subtitle pool at `subtitles.vortx.tv`.
///
/// The pool lets any VortX user READ subtitles other users have contributed for the same title/episode, and
/// (best-effort, in the background) UPLOAD embedded/add-on subtitle text so the next user benefits, plus learn
/// and share a per-rip SYNC OFFSET. This is the FOUNDATION client: pure, self-contained, callable. The
/// integration pass wires it into the player's subtitle list and the offset slider.
///
/// FAIL-SOFT CONTRACT (every method): any network / decode / signing / size error returns the empty / nil /
/// no-op result. Nothing throws to a caller. A disabled feature (`features.communitySubtitles` off, etc.) is a
/// hard no-op that never touches the network.
///
/// GATING (VortX-only pool): the owner gates this pool to real VortX builds, like trickplay and trailers, so
/// EVERY request to `subtitles.vortx.tv` is HMAC-signed with `VortXEdgeAuth.sign` -- the GET reads and the
/// sub-text download as well as the POSTs. Reads carry no ACCOUNT key (still "keyless" that way) but do carry
/// the `X-VX-Ts` / `X-VX-Sig` headers so that when the worker flips to enforce mode only VortX clients read the
/// pool. With no secret provisioned, signing is a safe no-op the worker's observe mode allows, so today it all
/// degrades gracefully.
enum SubtitlePoolClient {

    private static let bakedReadBaseURL = URL(string: "https://subtitles.vortx.tv")!
    private static let bakedReadHost = "subtitles.vortx.tv"
    private static let subtitleFormats = Set(["srt", "vtt", "ass"])
    // Current Worker proof: GET /subs returns at most 50 rows. Conservatively allowing 426 bytes per row,
    // 49 separators, the outer object, and the largest offset object totals 21,420 bytes. Keep the fixed
    // 64 KiB ceiling well above that mechanically derived maximum and independent of RemoteConfig.
    static let indexResponseMaxBytes = 64 * 1024
    // Mirrors the Worker's fixed MAX_TEXT_BYTES. This is intentionally not remotely raisable.
    static let subtitleBodyMaxBytes = 1024 * 1024

    struct TransportResponse: Sendable {
        let data: Data
        let statusCode: Int
    }

    typealias Transport = @Sendable (URLRequest) async -> TransportResponse?
    typealias MoatProvider = @Sendable (Bool) async -> String?

    private struct ReadAuthorization: Sendable {
        let sessionGeneration: UInt64
        let consentGeneration: UInt64
        let moat: String
    }

    // MARK: - Public model

    /// One subtitle offered by the pool. `url` is a fully-qualified downloadable link to the sub TEXT.
    struct PooledSubtitle: Identifiable, Equatable, Sendable {
        let id: Int
        let contentKey: String
        let lang: String
        let format: String   // "srt" | "vtt" | "ass"
        let origin: String   // e.g. "embedded" | "addon" | free-form worker tag
        let score: Int
        let url: URL
    }

    /// Caller-side fence for the gap between a successful client return and a UI/player publication.
    struct PublicationFence: Sendable {
        private let contentKey: String
        private let sessionGeneration: UInt64
        private let consentGeneration: UInt64

        init(contentKey: String) {
            let lifecycle = SourceIndexLifecycleClock.snapshot()
            self.contentKey = contentKey
            self.sessionGeneration = lifecycle.sessionGeneration
            self.consentGeneration = lifecycle.consentGeneration
        }

        func permits(currentContentKey: String?, isSignedIn: Bool) -> Bool {
            let lifecycle = SourceIndexLifecycleClock.snapshot()
            return currentContentKey == contentKey
                && isSignedIn
                && MoatConsent.contributeAndConsume
                && lifecycle.sessionGeneration == sessionGeneration
                && lifecycle.consentGeneration == consentGeneration
        }
    }

    /// Shared caller-side request ownership used by both player surfaces. The UUID is the authority: a late
    /// completion may release or publish state only while it still owns the matching stage. Fetch de-duplication
    /// also includes the account-session and consent generations so reopening either boundary can retry the same
    /// content/fingerprint immediately.
    struct RequestOwnership: Sendable {
        private struct FetchScope: Equatable, Sendable {
            let key: String
            let sessionGeneration: UInt64
            let consentGeneration: UInt64
        }

        private struct FetchRequest: Sendable {
            let id: UUID
            let scope: FetchScope
        }

        private var activeFetch: FetchRequest?
        private var completedFetchScope: FetchScope?
        private var downloadOwner: UUID?
        private var externalOwner: UUID?

        mutating func beginFetch(dedupeKey: String) -> UUID? {
            let lifecycle = SourceIndexLifecycleClock.snapshot()
            let scope = FetchScope(
                key: dedupeKey,
                sessionGeneration: lifecycle.sessionGeneration,
                consentGeneration: lifecycle.consentGeneration
            )
            guard activeFetch?.scope != scope, completedFetchScope != scope else { return nil }
            let id = UUID()
            activeFetch = FetchRequest(id: id, scope: scope)
            return id
        }

        func ownsFetch(_ id: UUID) -> Bool {
            activeFetch?.id == id
        }

        /// Returns true only when `id` released the active request. A rejected fence leaves no completed
        /// de-duplication latch, allowing a fresh authorized attempt with the same key.
        @discardableResult
        mutating func finishFetch(_ id: UUID, published: Bool) -> Bool {
            guard let request = activeFetch, request.id == id else { return false }
            activeFetch = nil
            if published { completedFetchScope = request.scope }
            return true
        }

        mutating func beginDownload() -> UUID {
            let id = UUID()
            downloadOwner = id
            externalOwner = nil
            return id
        }

        func ownsDownload(_ id: UUID) -> Bool {
            downloadOwner == id
        }

        @discardableResult
        mutating func finishDownload(_ id: UUID) -> Bool {
            guard downloadOwner == id else { return false }
            downloadOwner = nil
            return true
        }

        /// Transfers ownership from a completed download to a separately identified player-add operation.
        mutating func beginExternal(after downloadID: UUID) -> UUID? {
            guard downloadOwner == downloadID else { return nil }
            downloadOwner = nil
            let id = UUID()
            externalOwner = id
            return id
        }

        func ownsExternal(_ id: UUID) -> Bool {
            externalOwner == id
        }

        @discardableResult
        mutating func finishExternal(_ id: UUID) -> Bool {
            guard externalOwner == id else { return false }
            externalOwner = nil
            return true
        }

        mutating func invalidate() {
            activeFetch = nil
            completedFetchScope = nil
            downloadOwner = nil
            externalOwner = nil
        }
    }

    // MARK: - Read: GET /subs

    /// Fetch pooled subtitles + the learned offset for `contentKey`. Signed GET, 8 s timeout. Returns
    /// `([], nil)` on any error, or when `features.communitySubtitles` is off.
    ///
    /// - Parameters:
    ///   - contentKey:  the `imdb:tt…[:s:e]` key from `SubtitleReleaseFingerprint.contentKey`.
    ///   - lang:        optional ISO language filter; nil = all languages.
    ///   - fingerprint: optional release fingerprint so the returned `offset` matches the playing rip.
    /// `isSignedIn` gates the SERVE-side moat token: the pooled-subtitle READ is moat-gated on the worker
    /// (verifyMoatToken => empty list with no token), so a signed-in device stamps `X-VX-Moat`. Default
    /// `false` keeps every existing caller compiling and fails soft to a zero-transport empty result until the
    /// call sites thread the real account flag.
    static func fetchPooled(contentKey: String,
                            lang: String? = nil,
                            fingerprint: String? = nil,
                            isSignedIn: Bool = false) async -> (subs: [PooledSubtitle], offsetMs: Int?) {
        await fetchPooledUsing(
            contentKey: contentKey,
            lang: lang,
            fingerprint: fingerprint,
            isSignedIn: isSignedIn,
            moatProvider: { signedIn in await MoatToken.shared.current(isSignedIn: signedIn) },
            transport: { request in
                await liveTransport(request, maxBytes: indexResponseMaxBytes)
            }
        )
    }

    static func fetchPooledUsing(
        contentKey: String,
        lang: String? = nil,
        fingerprint: String? = nil,
        isSignedIn: Bool,
        moatProvider: @escaping MoatProvider,
        transport: @escaping Transport
    ) async -> (subs: [PooledSubtitle], offsetMs: Int?) {
        guard isValidContentKey(contentKey),
              featureCommunitySubtitles, MoatConsent.contributeAndConsume,
              let authorization = await readAuthorization(
                isSignedIn: isSignedIn, moatProvider: moatProvider
              ) else { return ([], nil) }
        guard var comps = URLComponents(
            url: bakedReadBaseURL.appendingPathComponent("subs"),
            resolvingAgainstBaseURL: false
        ) else {
            return ([], nil)
        }
        var items = [URLQueryItem(name: "key", value: contentKey)]
        if let lang, !lang.isEmpty { items.append(URLQueryItem(name: "lang", value: lang)) }
        if let fingerprint, !fingerprint.isEmpty { items.append(URLQueryItem(name: "fp", value: fingerprint)) }
        comps.queryItems = items
        guard let url = comps.url else { return ([], nil) }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)   // VortX-only gate: sign reads too (no-op without a secret)
        req.setValue(authorization.moat, forHTTPHeaderField: MoatToken.header)

        guard let data = await performData(
            req, authorization: authorization, target: .index, transport: transport
        ) else { return ([], nil) }
        guard let decoded = try? JSONDecoder().decode(SubsResponse.self, from: data) else { return ([], nil) }

        let subs: [PooledSubtitle] = (decoded.subs ?? []).compactMap { raw in
            guard let urlStr = raw.url, let subURL = URL(string: urlStr),
                  let id = raw.id, let lang = raw.lang, let format = raw.format,
                  isValidDownloadURL(subURL, contentKey: contentKey, format: format) else { return nil }
            return PooledSubtitle(id: id, contentKey: contentKey, lang: lang, format: format,
                                  origin: raw.origin ?? "", score: raw.score ?? 0, url: subURL)
        }
        guard readAuthorizationIsCurrent(authorization) else { return ([], nil) }
        VXProbe.log("sing", "sub fetchPooled key=\(contentKey) subs=\(subs.count) offsetMs=\(decoded.offset?.offsetMs.map(String.init) ?? "-")")
        return (subs, decoded.offset?.offsetMs)
    }

    // MARK: - Download the sub text: GET <pooled.url>

    /// Download `pooled`'s sub text to a deterministic temp file (reused across the session, like the player's
    /// subtitle-download fix) and return the local file URL, or nil on any failure. The download REQUEST is
    /// signed too when its host is a gated VortX host, so pool-hosted sub text stays VortX-only. Timeout comes
    /// from the RemoteConfig `subtitle.downloadTimeoutMs` tunable (baked 12 s).
    static func download(_ pooled: PooledSubtitle, isSignedIn: Bool = false) async -> URL? {
        await downloadUsing(
            pooled,
            isSignedIn: isSignedIn,
            moatProvider: { signedIn in await MoatToken.shared.current(isSignedIn: signedIn) },
            transport: { request in
                await liveTransport(request, maxBytes: subtitleBodyMaxBytes)
            }
        )
    }

    static func downloadUsing(
        _ pooled: PooledSubtitle,
        isSignedIn: Bool,
        moatProvider: @escaping MoatProvider,
        transport: @escaping Transport
    ) async -> URL? {
        guard isValidDownloadURL(
            pooled.url, contentKey: pooled.contentKey, format: pooled.format
        ), featureCommunitySubtitles, MoatConsent.contributeAndConsume,
              let authorization = await readAuthorization(
                isSignedIn: isSignedIn, moatProvider: moatProvider
              ) else { return nil }
        // Session-scoped reuse: if we already fetched this URL to a still-present file, hand it back.
        if let cached = cachedFile(for: pooled.url, authorization: authorization) {
            return readAuthorizationIsCurrent(authorization) ? cached : nil
        }

        var req = URLRequest(url: pooled.url, timeoutInterval: RemoteConfig.snapshot.subtitleDownloadTimeout)
        req.httpMethod = "GET"
        VortXEdgeAuth.sign(&req)   // host-gated inside sign(): no-op unless the URL host is a gated VortX host
        req.setValue(authorization.moat, forHTTPHeaderField: MoatToken.header)

        guard let data = await performData(
            req,
            authorization: authorization,
            target: .download(contentKey: pooled.contentKey, format: pooled.format),
            transport: transport
        ), !data.isEmpty else { return nil }

        // Deterministic filename from the URL hash + declared format so one on-disk file is reused all session.
        let name = "vortx-poolsub-\(stableHash(pooled.url.absoluteString))-s\(authorization.sessionGeneration)-c\(authorization.consentGeneration).\(pooled.format)"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard readAuthorizationIsCurrent(authorization) else { return nil }
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return nil }
        guard readAuthorizationIsCurrent(authorization),
              cacheStore(pooled.url, tmp, authorization: authorization) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        guard readAuthorizationIsCurrent(authorization) else {
            cacheRemove(pooled.url, authorization: authorization)
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return tmp
    }

    // MARK: - Upload sub text: POST /subs (signed)

    /// Best-effort upload of subtitle text to the pool so other users benefit. Signed POST. Gated on
    /// `features.communitySubtitles` AND the `.upload` sub-flag. Size-guarded: text larger than the
    /// `subtitle.uploadMaxBytes` tunable (baked 1 MiB) is skipped (the worker caps at 1 MiB anyway). The result
    /// is ignored; failures are silent.
    ///
    /// - Parameters:
    ///   - origin: "embedded" (extracted from the file's own tracks) or "addon" (fetched from a subtitles add-on).
    ///   - format: "srt" | "vtt" | "ass".
    static func upload(contentKey: String,
                       lang: String,
                       fingerprint: String?,
                       origin: String,
                       format: String,
                       text: String) async {
        await uploadUsing(
            contentKey: contentKey,
            lang: lang,
            fingerprint: fingerprint,
            origin: origin,
            format: format,
            text: text,
            transport: { request in
                await discardLiveTransport(request)
                return nil
            }
        )
    }

    static func uploadUsing(
        contentKey: String,
        lang: String,
        fingerprint: String?,
        origin: String,
        format: String,
        text: String,
        transport: @escaping Transport
    ) async {
        guard featureCommunitySubtitles, featureSubtitleUpload,
              MoatConsent.contributeAndConsume else { return }
        let maxBytes = min(RemoteConfig.snapshot.subtitleUploadMaxBytes, subtitleBodyMaxBytes)
        let bytes = text.utf8.count
        guard bytes > 0, bytes <= maxBytes else { return }   // skip empty or oversized text

        var body: [String: Any] = [
            "content_key": contentKey,
            "lang": lang,
            "origin": origin,
            "format": format,
            "text": text,
        ]
        if let fingerprint, !fingerprint.isEmpty { body["fingerprint"] = fingerprint }

        VXProbe.log("sing", "sub upload key=\(contentKey) lang=\(lang) origin=\(origin) fmt=\(format) bytes=\(bytes)")
        await postJSON(path: "subs", body: body, transport: transport)
    }

    // MARK: - Post a learned offset: POST /offset (signed)

    /// Best-effort submit of a learned sync offset (ms) for `contentKey` + `fingerprint`. Signed POST. Gated on
    /// `features.subtitleSync`. The worker buckets `offset_ms` to 250 ms server-side; we send the raw value.
    /// Result ignored.
    static func postOffset(contentKey: String,
                           lang: String,
                           fingerprint: String?,
                           offsetMs: Int) async {
        await postOffsetUsing(
            contentKey: contentKey,
            lang: lang,
            fingerprint: fingerprint,
            offsetMs: offsetMs,
            transport: { request in
                await discardLiveTransport(request)
                return nil
            }
        )
    }

    static func postOffsetUsing(
        contentKey: String,
        lang: String,
        fingerprint: String?,
        offsetMs: Int,
        transport: @escaping Transport
    ) async {
        guard featureSubtitleSync, MoatConsent.contributeAndConsume else { return }
        var body: [String: Any] = [
            "content_key": contentKey,
            "lang": lang,
            "offset_ms": offsetMs,
        ]
        if let fingerprint, !fingerprint.isEmpty { body["fingerprint"] = fingerprint }

        VXProbe.log("sing", "sub postOffset key=\(contentKey) lang=\(lang) offsetMs=\(offsetMs)")
        await postJSON(path: "offset", body: body, transport: transport)
    }

    // MARK: - Feature gates

    private static var featureCommunitySubtitles: Bool {
        RemoteConfig.snapshot.isFeatureOn("communitySubtitles", default: RemoteConfigDefaults.featureCommunitySubtitles)
    }
    private static var featureSubtitleSync: Bool {
        RemoteConfig.snapshot.isFeatureOn("subtitleSync", default: RemoteConfigDefaults.featureSubtitleSync)
    }
    /// Upload sub-flag: an extra opt-in layer under the master `communitySubtitles` gate. Defaults ON but can be
    /// killed remotely (e.g. to pause pool writes) without disabling reads. Stored under a distinct feature key.
    private static var featureSubtitleUpload: Bool {
        RemoteConfig.snapshot.isFeatureOn("subtitleUpload", default: true)
    }

    // MARK: - Networking primitives (all fail-soft)

    /// The pool base URL from RemoteConfig, or the baked default.
    private static var baseURL: URL {
        RemoteConfig.snapshot.endpoint("subtitles") ?? URL(string: RemoteConfigDefaults.endpointSubtitles)!
    }

    private static func readAuthorization(
        isSignedIn: Bool,
        moatProvider: @escaping MoatProvider
    ) async -> ReadAuthorization? {
        guard isSignedIn, MoatConsent.contributeAndConsume else { return nil }
        let lifecycle = SourceIndexLifecycleClock.snapshot()
        guard let moat = await moatProvider(isSignedIn), !moat.isEmpty else { return nil }
        let authorization = ReadAuthorization(
            sessionGeneration: lifecycle.sessionGeneration,
            consentGeneration: lifecycle.consentGeneration,
            moat: moat
        )
        return readAuthorizationIsCurrent(authorization) ? authorization : nil
    }

    private static func readAuthorizationIsCurrent(_ authorization: ReadAuthorization) -> Bool {
        let lifecycle = SourceIndexLifecycleClock.snapshot()
        return MoatConsent.contributeAndConsume
            && lifecycle.sessionGeneration == authorization.sessionGeneration
            && lifecycle.consentGeneration == authorization.consentGeneration
    }

    private enum ReadTarget {
        case index
        case download(contentKey: String, format: String)

        var responseByteLimit: Int {
            switch self {
            case .index:
                return SubtitlePoolClient.indexResponseMaxBytes
            case .download:
                return SubtitlePoolClient.subtitleBodyMaxBytes
            }
        }

        func permits(_ request: URLRequest) -> Bool {
            guard request.httpMethod == "GET", let url = request.url else { return false }
            switch self {
            case .index:
                return SubtitlePoolClient.isValidIndexURL(url)
            case let .download(contentKey, format):
                return SubtitlePoolClient.isValidDownloadURL(
                    url, contentKey: contentKey, format: format
                )
            }
        }
    }

    private static func exactOriginComponents(for url: URL) -> URLComponents? {
        guard url.baseURL == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == bakedReadHost,
              components.percentEncodedHost?.lowercased() == bakedReadHost,
              components.percentEncodedUser == nil,
              components.percentEncodedPassword == nil,
              components.port == nil,
              components.percentEncodedFragment == nil else { return nil }
        return components
    }

    private static func isValidIndexURL(_ url: URL) -> Bool {
        guard let components = exactOriginComponents(for: url) else { return false }
        return components.percentEncodedPath == "/subs" && components.percentEncodedQuery != nil
    }

    private static func isValidContentKey(_ contentKey: String) -> Bool {
        guard (1...200).contains(contentKey.utf8.count) else { return false }
        return contentKey.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 58 || byte == 46 || byte == 95 || byte == 45
        }
    }

    /// Accept only the worker's canonical public-object grammar under the baked pool origin.
    static func isValidDownloadURL(_ url: URL, contentKey: String, format: String) -> Bool {
        guard isValidContentKey(contentKey), subtitleFormats.contains(format),
              let components = exactOriginComponents(for: url),
              components.percentEncodedQuery == nil else { return false }

        let prefix = "/r2/subs/\(contentKey)/"
        let suffix = ".\(format)"
        let path = components.percentEncodedPath
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return false }
        let hashStart = path.index(path.startIndex, offsetBy: prefix.count)
        let hashEnd = path.index(path.endIndex, offsetBy: -suffix.count)
        guard hashStart <= hashEnd else { return false }
        let hash = path[hashStart..<hashEnd]
        return hash.utf8.count == 64 && hash.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    /// GET-style fetch that returns the body on a 2xx, else nil. Authorization is checked immediately before
    /// transport and again before any response can escape. Never throws.
    private static func performData(
        _ req: URLRequest,
        authorization: ReadAuthorization,
        target: ReadTarget,
        transport: @escaping Transport
    ) async -> Data? {
        guard target.permits(req), readAuthorizationIsCurrent(authorization),
              let response = await transport(req),
              (200..<300).contains(response.statusCode),
              response.data.count <= target.responseByteLimit,
              readAuthorizationIsCurrent(authorization) else { return nil }
        return response.data
    }

    /// Signed JSON POST to `path`. Best-effort: serializes, signs, sends, ignores the response. Never throws.
    private static func postJSON(
        path: String,
        body: [String: Any],
        transport: @escaping Transport
    ) async {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        VortXEdgeAuth.sign(&req)
        guard MoatConsent.contributeAndConsume else { return }
        _ = await transport(req)
    }

    struct LiveTransportOutcome: Sendable {
        let response: TransportResponse?
        let didCancelTask: Bool
        let bufferedByteCount: Int
        let receivedByteCount: Int
    }

    /// Streaming byte accumulator shared by the live delegate and the deterministic harness. A missing,
    /// malformed, or understated Content-Length never bypasses the incremental byte check.
    struct BoundedBodyAccumulator: Sendable {
        let maxBytes: Int
        private(set) var data = Data()
        private(set) var receivedByteCount = 0

        func acceptsDeclaredContentLength(_ raw: String?) -> Bool {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let length = Int(raw), length >= 0 else { return true }
            return length <= maxBytes
        }

        mutating func append(_ chunk: Data) -> Bool {
            receivedByteCount += chunk.count
            guard chunk.count <= maxBytes - data.count else {
                discard()
                return false
            }
            data.append(chunk)
            return true
        }

        mutating func discard() {
            data.removeAll(keepingCapacity: false)
        }
    }

    private enum LiveBodyPolicy: Sendable {
        case collect(maxBytes: Int)
        case discard
    }

    /// One delegate and one ephemeral session per request. The async operation retains this object, this object
    /// retains the session and task, and terminal completion invalidates the session after taking the continuation
    /// exactly once. The lock covers cancellation racing response, data, and completion callbacks.
    private final class BoundedLiveRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let policy: LiveBodyPolicy
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LiveTransportOutcome, Never>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var httpResponse: HTTPURLResponse?
        private var accumulator: BoundedBodyAccumulator?
        private var cancellationRequested = false
        private var completed = false

        init(policy: LiveBodyPolicy) {
            self.policy = policy
            if case let .collect(maxBytes) = policy {
                self.accumulator = BoundedBodyAccumulator(maxBytes: maxBytes)
            }
        }

        func run(_ request: URLRequest) async -> LiveTransportOutcome {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    start(request, continuation: continuation)
                }
            } onCancel: {
                self.cancel()
            }
        }

        private func start(
            _ request: URLRequest,
            continuation: CheckedContinuation<LiveTransportOutcome, Never>
        ) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCredentialStorage = nil
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
            let task = session.dataTask(with: request)

            lock.lock()
            if cancellationRequested {
                completed = true
                lock.unlock()
                task.cancel()
                session.invalidateAndCancel()
                continuation.resume(returning: LiveTransportOutcome(
                    response: nil,
                    didCancelTask: true,
                    bufferedByteCount: 0,
                    receivedByteCount: 0
                ))
                return
            }
            self.continuation = continuation
            self.session = session
            self.task = task
            task.resume()
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancellationRequested = true
            let hasContinuation = continuation != nil
            lock.unlock()
            if hasContinuation {
                finish(response: nil, cancelTask: true, discardBody: true)
            }
        }

        private func finish(
            response: TransportResponse?,
            cancelTask: Bool,
            discardBody: Bool
        ) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            if discardBody { accumulator?.discard() }
            let bufferedByteCount = accumulator?.data.count ?? 0
            let totalReceivedByteCount = accumulator?.receivedByteCount ?? 0
            let continuation = continuation
            let session = session
            let task = task
            self.continuation = nil
            self.session = nil
            self.task = nil
            lock.unlock()

            if cancelTask {
                task?.cancel()
                session?.invalidateAndCancel()
            } else {
                session?.finishTasksAndInvalidate()
            }
            continuation?.resume(returning: LiveTransportOutcome(
                response: response,
                didCancelTask: cancelTask,
                bufferedByteCount: bufferedByteCount,
                receivedByteCount: totalReceivedByteCount
            ))
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                finish(response: nil, cancelTask: true, discardBody: true)
                return
            }

            switch policy {
            case .discard:
                completionHandler(.cancel)
                finish(response: nil, cancelTask: true, discardBody: true)
            case .collect:
                let declaredLength = http.value(forHTTPHeaderField: "Content-Length")
                lock.lock()
                let acceptsLength = accumulator?.acceptsDeclaredContentLength(declaredLength) == true
                lock.unlock()
                if !acceptsLength {
                    completionHandler(.cancel)
                    finish(response: nil, cancelTask: true, discardBody: true)
                    return
                }
                lock.lock()
                if !completed { httpResponse = http }
                let isCompleted = completed
                lock.unlock()
                completionHandler(isCompleted ? .cancel : .allow)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            switch policy {
            case .discard:
                lock.unlock()
                finish(response: nil, cancelTask: true, discardBody: true)
            case .collect:
                let accepted = accumulator?.append(data) == true
                lock.unlock()
                if !accepted {
                    finish(response: nil, cancelTask: true, discardBody: true)
                }
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            let httpResponse = httpResponse
            let data = accumulator?.data ?? Data()
            lock.unlock()

            guard error == nil, let httpResponse else {
                finish(response: nil, cancelTask: false, discardBody: true)
                return
            }
            finish(
                response: TransportResponse(data: data, statusCode: httpResponse.statusCode),
                cancelTask: false,
                discardBody: false
            )
        }

    }

    static func liveTransportOutcome(
        _ req: URLRequest,
        maxBytes: Int
    ) async -> LiveTransportOutcome {
        guard maxBytes >= 0 else {
            return LiveTransportOutcome(
                response: nil,
                didCancelTask: false,
                bufferedByteCount: 0,
                receivedByteCount: 0
            )
        }
        return await BoundedLiveRequest(policy: .collect(maxBytes: maxBytes)).run(req)
    }

    static func liveTransport(
        _ req: URLRequest,
        maxBytes: Int = indexResponseMaxBytes
    ) async -> TransportResponse? {
        await liveTransportOutcome(req, maxBytes: maxBytes).response
    }

    static func liveDiscardTransportOutcome(_ req: URLRequest) async -> LiveTransportOutcome {
        await BoundedLiveRequest(policy: .discard).run(req)
    }

    private static func discardLiveTransport(_ req: URLRequest) async {
        _ = await liveDiscardTransportOutcome(req)
    }

    // MARK: - Session-scoped download cache (deterministic temp files, like the player's subtitle fix)

    /// Serializes the metadata-mutate, unlocked-file-delete transaction. `cacheLock` is never held across file
    /// I/O, while this outer lock prevents a collected path from becoming a surviving replacement mid-delete.
    private static let cacheMutationLock = NSLock()
    private static let cacheLock = NSLock()
    private struct CachedFile {
        let localURL: URL
        let sessionGeneration: UInt64
        let consentGeneration: UInt64
    }

    nonisolated(unsafe) private static var fileCache: [URL: CachedFile] = [:]
    /// Insertion order for `fileCache`, so a long multi-title session evicts the oldest entry past the cap
    /// instead of growing the map unbounded for the whole process lifetime.
    nonisolated(unsafe) private static var cacheOrder: [URL] = []
    private static let cacheCap = 256

    private static func cachedFile(
        for remote: URL,
        authorization: ReadAuthorization
    ) -> URL? {
        cacheMutationLock.lock(); defer { cacheMutationLock.unlock() }
        cacheLock.lock()
        guard let cached = fileCache[remote] else {
            cacheLock.unlock()
            return nil
        }
        if cached.sessionGeneration == authorization.sessionGeneration,
           cached.consentGeneration == authorization.consentGeneration,
           FileManager.default.fileExists(atPath: cached.localURL.path) {
            cacheLock.unlock()
            return cached.localURL
        }

        let previousCache = fileCache
        let previousOrder = cacheOrder
        fileCache[remote] = nil
        cacheOrder.removeAll { $0 == remote }
        let survivingPaths = Set(fileCache.values.map(\.localURL))
        let filesToDelete: Set<URL> = survivingPaths.contains(cached.localURL) ? [] : [cached.localURL]
        cacheLock.unlock()

        guard deleteCacheFiles(filesToDelete) else {
            cacheLock.lock()
            fileCache = previousCache
            cacheOrder = previousOrder
            cacheLock.unlock()
            return nil
        }
        return nil
    }

    private static func cacheStore(
        _ remote: URL,
        _ local: URL,
        authorization: ReadAuthorization
    ) -> Bool {
        cacheMutationLock.lock(); defer { cacheMutationLock.unlock() }
        cacheLock.lock()
        guard readAuthorizationIsCurrent(authorization) else {
            cacheLock.unlock()
            return false
        }
        let previousCache = fileCache
        let previousOrder = cacheOrder
        var filesToDelete = Set<URL>()
        if let replaced = fileCache[remote], replaced.localURL != local {
            filesToDelete.insert(replaced.localURL)
        }
        cacheOrder.removeAll { $0 == remote }
        cacheOrder.append(remote)
        fileCache[remote] = CachedFile(
            localURL: local,
            sessionGeneration: authorization.sessionGeneration,
            consentGeneration: authorization.consentGeneration
        )
        while cacheOrder.count > cacheCap {
            let oldest = cacheOrder.removeFirst()
            if let evicted = fileCache.removeValue(forKey: oldest) {
                filesToDelete.insert(evicted.localURL)
            }
        }
        let survivingPaths = Set(fileCache.values.map(\.localURL))
        filesToDelete.subtract(survivingPaths)
        cacheLock.unlock()

        guard deleteCacheFiles(filesToDelete) else {
            cacheLock.lock()
            fileCache = previousCache
            cacheOrder = previousOrder
            let restoredPaths = Set(fileCache.values.map(\.localURL))
            cacheLock.unlock()
            if !restoredPaths.contains(local) {
                _ = deleteCacheFiles([local])
            }
            return false
        }
        return true
    }

    private static func cacheRemove(_ remote: URL, authorization: ReadAuthorization) {
        cacheMutationLock.lock(); defer { cacheMutationLock.unlock() }
        cacheLock.lock()
        guard let cached = fileCache[remote],
              cached.sessionGeneration == authorization.sessionGeneration,
              cached.consentGeneration == authorization.consentGeneration else {
            cacheLock.unlock()
            return
        }
        let previousCache = fileCache
        let previousOrder = cacheOrder
        fileCache[remote] = nil
        cacheOrder.removeAll { $0 == remote }
        let survivingPaths = Set(fileCache.values.map(\.localURL))
        let filesToDelete: Set<URL> = survivingPaths.contains(cached.localURL) ? [] : [cached.localURL]
        cacheLock.unlock()

        guard deleteCacheFiles(filesToDelete) else {
            cacheLock.lock()
            fileCache = previousCache
            cacheOrder = previousOrder
            cacheLock.unlock()
            return
        }
    }

    /// Deletes only paths collected while metadata was locked. A missing file is already a successful cleanup.
    private static func deleteCacheFiles(_ files: Set<URL>) -> Bool {
        var allRemoved = true
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                allRemoved = false
            }
        }
        return allRemoved
    }

    /// Stable, per-string hash for a deterministic temp filename (NOT the per-process-seeded `hashValue`).
    private static func stableHash(_ input: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in input.utf8 { hash ^= UInt64(byte); hash = hash &* prime }
        return String(format: "%016llx", hash)
    }

    // MARK: - Decodable wire shapes

    private struct SubsResponse: Decodable {
        let subs: [RawSub]?
        let offset: RawOffset?
    }
    private struct RawSub: Decodable {
        let id: Int?
        let lang: String?
        let format: String?
        let origin: String?
        let score: Int?
        let url: String?
    }
    private struct RawOffset: Decodable {
        let offsetMs: Int?
        let votes: Int?
    }
}
