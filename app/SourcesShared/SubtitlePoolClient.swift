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

    // MARK: - Public model

    /// One subtitle offered by the pool. `url` is a fully-qualified downloadable link to the sub TEXT.
    struct PooledSubtitle: Identifiable, Equatable, Sendable {
        let id: Int
        let lang: String
        let format: String   // "srt" | "vtt" | "ass"
        let origin: String   // e.g. "embedded" | "addon" | free-form worker tag
        let score: Int
        let url: URL
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
    /// `false` keeps every existing caller compiling and fail-soft (no token -> the worker's cold-start
    /// empty), until the call sites thread the real account flag.
    static func fetchPooled(contentKey: String,
                            lang: String? = nil,
                            fingerprint: String? = nil,
                            isSignedIn: Bool = false) async -> (subs: [PooledSubtitle], offsetMs: Int?) {
        guard featureCommunitySubtitles else { return ([], nil) }
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("subs"), resolvingAgainstBaseURL: false) else {
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
        if let moat = await MoatToken.shared.current(isSignedIn: isSignedIn) {   // SERVE moat gate (no-op signed out)
            req.setValue(moat, forHTTPHeaderField: MoatToken.header)
        }

        guard let data = await performData(req) else { return ([], nil) }
        guard let decoded = try? JSONDecoder().decode(SubsResponse.self, from: data) else { return ([], nil) }

        let subs: [PooledSubtitle] = (decoded.subs ?? []).compactMap { raw in
            guard let urlStr = raw.url, let subURL = URL(string: urlStr),
                  let id = raw.id, let lang = raw.lang, let format = raw.format else { return nil }
            return PooledSubtitle(id: id, lang: lang, format: format,
                                  origin: raw.origin ?? "", score: raw.score ?? 0, url: subURL)
        }
        return (subs, decoded.offset?.offsetMs)
    }

    // MARK: - Download the sub text: GET <pooled.url>

    /// Download `pooled`'s sub text to a deterministic temp file (reused across the session, like the player's
    /// subtitle-download fix) and return the local file URL, or nil on any failure. The download REQUEST is
    /// signed too when its host is a gated VortX host, so pool-hosted sub text stays VortX-only. Timeout comes
    /// from the RemoteConfig `subtitle.downloadTimeoutMs` tunable (baked 12 s).
    static func download(_ pooled: PooledSubtitle, isSignedIn: Bool = false) async -> URL? {
        guard featureCommunitySubtitles else { return nil }
        // Session-scoped reuse: if we already fetched this URL to a still-present file, hand it back.
        if let cached = cachedFile(for: pooled.url) { return cached }

        var req = URLRequest(url: pooled.url, timeoutInterval: RemoteConfig.snapshot.subtitleDownloadTimeout)
        req.httpMethod = "GET"
        VortXEdgeAuth.sign(&req)   // host-gated inside sign(): no-op unless the URL host is a gated VortX host
        // The pool-hosted sub TEXT is served from a moat-gated VortX host too, so stamp the moat token; a
        // no-op signed out (the URL is only reachable via the moat-gated list anyway).
        if let moat = await MoatToken.shared.current(isSignedIn: isSignedIn) {
            req.setValue(moat, forHTTPHeaderField: MoatToken.header)
        }

        guard let data = await performData(req), !data.isEmpty else { return nil }

        // Deterministic filename from the URL hash + declared format so one on-disk file is reused all session.
        let ext = ["srt", "vtt", "ass"].contains(pooled.format) ? pooled.format : "srt"
        let name = "vortx-poolsub-\(stableHash(pooled.url.absoluteString)).\(ext)"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return nil }
        cacheStore(pooled.url, tmp)
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
        guard featureCommunitySubtitles, featureSubtitleUpload else { return }
        let maxBytes = RemoteConfig.snapshot.subtitleUploadMaxBytes
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

        await postJSON(path: "subs", body: body)
    }

    // MARK: - Post a learned offset: POST /offset (signed)

    /// Best-effort submit of a learned sync offset (ms) for `contentKey` + `fingerprint`. Signed POST. Gated on
    /// `features.subtitleSync`. The worker buckets `offset_ms` to 250 ms server-side; we send the raw value.
    /// Result ignored.
    static func postOffset(contentKey: String,
                           lang: String,
                           fingerprint: String?,
                           offsetMs: Int) async {
        guard featureSubtitleSync else { return }
        var body: [String: Any] = [
            "content_key": contentKey,
            "lang": lang,
            "offset_ms": offsetMs,
        ]
        if let fingerprint, !fingerprint.isEmpty { body["fingerprint"] = fingerprint }

        await postJSON(path: "offset", body: body)
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

    /// GET-style fetch that returns the body on a 2xx, else nil. Never throws.
    private static func performData(_ req: URLRequest) async -> Data? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Signed JSON POST to `path`. Best-effort: serializes, signs, sends, ignores the response. Never throws.
    private static func postJSON(path: String, body: [String: Any]) async {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        VortXEdgeAuth.sign(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Session-scoped download cache (deterministic temp files, like the player's subtitle fix)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var fileCache: [URL: URL] = [:]
    /// Insertion order for `fileCache`, so a long multi-title session evicts the oldest entry past the cap
    /// instead of growing the map unbounded for the whole process lifetime.
    nonisolated(unsafe) private static var cacheOrder: [URL] = []
    private static let cacheCap = 256

    private static func cachedFile(for remote: URL) -> URL? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let file = fileCache[remote] else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        fileCache[remote] = nil   // purged (temp cleanup): force a re-download
        cacheOrder.removeAll { $0 == remote }
        return nil
    }

    private static func cacheStore(_ remote: URL, _ local: URL) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if fileCache[remote] == nil {
            cacheOrder.append(remote)
            while cacheOrder.count > cacheCap {
                let oldest = cacheOrder.removeFirst()
                fileCache[oldest] = nil
            }
        }
        fileCache[remote] = local
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
