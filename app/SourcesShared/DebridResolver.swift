import Foundation
import CryptoKit

/// Verbose source-resolve diagnostic probe: every resolve decision logs `[src-probe]` so the debrid
/// resolve, cache-gate, and fail path are traceable end to end. Gated on `VXProbe.enabled`, the same
/// "Diagnostic logging" toggle the rest of VXProbe honors, so a release build with diagnostics off stays
/// silent on the playback hot path (these lines carry infoHash prefixes) and pays nothing.
enum DebridProbe {
    static func log(_ category: String, _ message: String) {
        guard VXProbe.enabled else { return }
        NSLog("[src-probe] %@: %@", category, message)
    }
    static func h8(_ s: String) -> String { String(s.prefix(8)) }
    static func since(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
    static func ms(_ d: Duration) -> Int { Int(d.components.seconds) * 1000 }
}

/// Native in-client debrid resolution: turn a torrent (infohash / magnet) into a DIRECT, streamable
/// HTTPS URL through the user's own debrid account, so cached torrents play instantly without a debrid
/// add-on. The keys live in `DebridKeys.shared`; this is the resolver layer that finally USES them
/// (task #12). Provider-agnostic via `DebridResolving`; TorBox is implemented first (most popular, the
/// only one of the four that also does usenet, and — unlike Real-Debrid — it kept its instant cache-check).
///
/// This file is the resolver ENGINE only: it takes hashes/magnets and returns files/URLs. Wiring it into
/// the source list (badge + rank cached results to the top) and the play path (cached -> instant direct
/// link, fail soft to the torrent engine) is a separate step. Full API specs: Brain
/// `wiki/projects/stremiox/vortx-debrid-implementation.md`.

// MARK: - Query encoding

/// Percent-encoding for query-string VALUES. `CharacterSet.urlQueryAllowed` is the wrong set for a value: it
/// leaves the sub-delimiters `&`, `=`, `+` and `,` intact, so an unescaped value can inject extra params.
/// `valueAllowed` strips those so a joined hash list stays inside its `hash=` parameter.
enum DebridQuery {
    static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+,")
        return set
    }()
}

// MARK: - Value types

/// One file inside a debrid torrent. `id` is the provider's file id used to request the stream link.
struct DebridFile: Sendable, Equatable {
    let id: Int
    let name: String       // full path within the torrent
    let shortName: String   // filename only (cleaner to parse for SxEy)
    let size: Int64
    let mimetype: String?

    var isVideo: Bool {
        if let m = mimetype?.lowercased(), m.hasPrefix("video/") { return true }
        let candidate = shortName.isEmpty ? name : shortName
        let ext = (candidate as NSString).pathExtension.lowercased()
        return ["mkv", "mp4", "avi", "mov", "ts", "m2ts", "webm", "wmv", "flv", "m4v"].contains(ext)
    }
}

/// A series episode target, for picking the right file in a season pack. Nil for movies.
struct DebridEpisode: Sendable, Equatable {
    let season: Int
    let episode: Int
}

enum DebridError: Error, Equatable {
    case noKey
    case invalidKey
    case notCached
    case noMatchingFile
    case notReady          // added but still downloading past the streaming timeout
    case providerError(String)
}

/// The provenance of a natively-resolved debrid link: enough to regenerate a FRESH stream link straight
/// from the provider (skip the add step) when the minted URL has expired. Carried from the resolve site to
/// the play-record so a Continue-Watching resume can `DebridCoordinator.reresolve(...)`. All fields but the
/// URL are the reresolve inputs; `torrentId`/`fileId` are the provider ids that avoid a re-add, `infoHash`/
/// `fileIdx` let a provider re-add from scratch if the id is gone. Value type, `Sendable`.
struct DebridPlaybackRef: Sendable, Equatable {
    let url: URL
    let service: DebridService
    let infoHash: String
    let torrentId: Int?
    let fileId: Int?
    let fileIdx: Int?
}

/// One item ALREADY in the user's debrid cloud (a finished torrent / stored file), surfaced by the
/// browsable-library feature so it can be listed and played straight from the account (no add-on, no
/// re-download). `Sendable` value type: it crosses from the resolver actor to the browse UI and back to
/// the same provider's resolver for the on-demand direct-link resolve. The resolution fields are opaque
/// to the UI and interpreted ONLY by the owning provider's resolver (`resolveLibraryItem`): each provider
/// stores what its own resolve leg needs (a torrent+file id, a link to unlock, or an already-direct link).
struct DebridLibraryItem: Sendable, Identifiable, Equatable {
    /// Stable, provider-scoped id for SwiftUI: "<service.rawValue>:<providerId>".
    let id: String
    let service: DebridService
    let name: String
    /// Total bytes, or 0 when the provider omitted a size.
    let size: Int64
    /// When it was added to the cloud, or nil when the provider omitted / an unparseable timestamp.
    let added: Date?
    /// The provider's own item id (torrent / magnet / file id) in string form, for the resolve leg.
    let providerId: String
    /// A chosen file id inside the item, when the list step already picked one (TorBox).
    let fileId: Int?
    /// A restricted link the provider must unlock/unrestrict to a direct URL (AllDebrid).
    let restrictedLink: String?
    /// An already-direct, immediately playable link (Premiumize stream link).
    let directLink: String?
}

// MARK: - Protocol

/// A single debrid provider's resolver. Actor-isolated: each owns its own URLSession and serial work.
protocol DebridResolving: Actor {
    // `service` is a constant identity (every conformer declares it `nonisolated let`), so the requirement is
    // nonisolated too - lets the coordinator read `resolver.service` synchronously (e.g. resolveWithIds).
    nonisolated var service: DebridService { get }

    /// Batch cache-availability. Returns hash -> files for the hashes that are cached (absent / empty = not).
    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]]

    /// Resolve a torrent to a direct streamable URL: add the magnet (idempotent), wait until ready
    /// (near-instant for cached), pick the episode/movie file, and return its stream URL.
    func resolve(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL

    /// Resolve, but also surface the provider ids needed to LATER regenerate a fresh link without re-adding
    /// (see `reresolveLink`). Default impl calls `resolve` and returns nil ids (so a later reresolve re-adds
    /// from scratch); a provider with stable ids (TorBox) overrides to carry them. `torrentId`/`fileId` are
    /// the reresolve inputs.
    func resolveWithIds(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?)
        async throws -> (url: URL, torrentId: Int?, fileId: Int?)

    /// Regenerate a FRESH direct link for an already-resolved file, skipping the add step where possible.
    /// `torrentId`+`fileId` (when present) take the fast provider-native path; otherwise fall back to a full
    /// re-add via `resolve` using the carried `infoHash`/`fileIdx`. Throws `.notCached` when the file is gone.
    func reresolveLink(infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?) async throws -> URL

    /// List what is ALREADY in this provider's cloud (finished torrents / stored files), each carrying
    /// enough to resolve to a direct URL on demand. Powers the browsable debrid library. Default: none.
    func listCloudLibrary() async throws -> [DebridLibraryItem]

    /// Resolve one previously-listed `DebridLibraryItem` to a direct, streamable URL through this provider.
    /// Default: unsupported (throws), so a provider that has not implemented browsing stays inert.
    func resolveLibraryItem(_ item: DebridLibraryItem) async throws -> URL
}

extension DebridResolving {
    func resolveWithIds(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?)
        async throws -> (url: URL, torrentId: Int?, fileId: Int?) {
        let url = try await resolve(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: episode)
        return (url, nil, nil)
    }

    /// Default reresolve: no stable ids, so re-add from the infohash (the provider dedups an already-present
    /// torrent, so this is still far cheaper than the full add-on re-resolve). RD/AD/PM use this path.
    func reresolveLink(infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?) async throws -> URL {
        let magnet = DebridResolve.magnet(forHash: infoHash)
        return try await resolve(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: nil)
    }

    /// Default: a provider that has not implemented cloud browsing surfaces nothing (never throws, so the
    /// coordinator's fail-soft aggregate simply skips it).
    func listCloudLibrary() async throws -> [DebridLibraryItem] { [] }

    /// Default: browsing not supported for this provider.
    func resolveLibraryItem(_ item: DebridLibraryItem) async throws -> URL { throw DebridError.noMatchingFile }
}

/// Cross-provider timestamp parsing for the browsable library: RD/TorBox emit ISO-8601 strings (with or
/// without fractional seconds), AllDebrid/Premiumize emit Unix seconds (handled at their call sites). Any
/// unparseable value yields nil so the row simply omits the "added" line rather than showing a wrong date.
enum DebridDate {
    static func parse(iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}

// MARK: - Shared helpers

enum DebridResolve {
    /// Build a minimal magnet from an infohash (+ optional name / trackers). The `xt=urn:btih:` alone is
    /// enough for every provider's add/cache-check.
    static func magnet(forHash hash: String, name: String? = nil, trackers: [String] = []) -> String {
        var s = "magnet:?xt=urn:btih:\(hash)"
        if let name, let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            s += "&dn=\(enc)"
        }
        for tr in trackers {
            if let enc = tr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { s += "&tr=\(enc)" }
        }
        return s
    }

    /// Pick the file to stream: explicit fileIdx -> SxEy filename match -> largest video file.
    static func pickFile(_ files: [DebridFile], episode: DebridEpisode?, fileIdx: Int?) -> DebridFile? {
        if let idx = fileIdx, files.indices.contains(idx) { return files[idx] }
        let videos = files.filter(\.isVideo)
        // Provider omitted filenames (isVideo false for every entry, e.g. AllDebrid on a cached single-file
        // torrent): fall back to the whole file list so size selection still resolves instead of noMatchingFile.
        let pool = videos.isEmpty ? files : videos
        guard let episode else { return pool.max(by: { $0.size < $1.size }) }
        let scored = pool.compactMap { f -> (DebridFile, Int)? in
            let s = episodeMatchScore(filename: f.shortName.isEmpty ? f.name : f.shortName,
                                      season: episode.season, episode: episode.episode)
            return s > 0 ? (f, s) : nil
        }
        if let best = scored.max(by: { $0.1 < $1.1 })?.0 { return best }
        return pool.max(by: { $0.size < $1.size })   // pack fallback: biggest video
    }

    /// Score a filename against a SxEy target (SnnEnn, n x nn, "season n ... episode n"). 0 = no match.
    static func episodeMatchScore(filename: String, season: Int, episode: Int) -> Int {
        let lower = filename.lowercased()
        if lower.contains(String(format: "s%02de%02d", season, episode)) { return 3 }
        if lower.contains("\(season)x\(String(format: "%02d", episode))") { return 2 }
        if lower.contains("season \(season)") && lower.contains("episode \(episode)") { return 1 }
        return 0
    }
}

// MARK: - TorBox resolver (torrents)

/// TorBox native resolver. Base `https://api.torbox.app/v1/api/torrents`, Bearer auth. Flow (cached):
/// checkcached -> createtorrent (idempotent) -> requestdl. Usenet is a separate backend (next step).
actor TorBoxResolver: DebridResolving {
    nonisolated let service: DebridService = .torBox
    private let apiKey: String
    private let session: URLSession
    private static let base = "https://api.torbox.app/v1/api/torrents"
    /// Percent-encode a query VALUE (drops the sub-delimiters `&`/`=`/`+`/`,` that `.urlQueryAllowed` leaves
    /// intact) so a joined hash list can never break out of the `hash=` parameter.
    fileprivate static let queryValueAllowed = DebridQuery.valueAllowed

    init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    // Generic envelope: { success, error, detail, data }
    private struct Envelope<T: Decodable>: Decodable { let success: Bool; let data: T? }
    private struct Cached: Decodable {
        let hash: String
        let files: [File]?
        struct File: Decodable {
            let id: Int; let name: String?; let size: Int64?; let mimetype: String?
            let shortName: String?
            enum CodingKeys: String, CodingKey { case id, name, size, mimetype; case shortName = "short_name" }
        }
    }
    private struct Created: Decodable {
        let torrentId: Int?
        enum CodingKeys: String, CodingKey { case torrentId = "torrent_id" }
    }
    private struct Item: Decodable {
        let id: Int; let hash: String?; let downloadFinished: Bool?; let downloadPresent: Bool?; let downloadState: String?
        let files: [Cached.File]?
        enum CodingKeys: String, CodingKey {
            case id, hash, files
            case downloadFinished = "download_finished", downloadPresent = "download_present"
            case downloadState = "download_state"
        }
        var ready: Bool {
            (downloadFinished == true && downloadPresent == true)
                || downloadState == "cached" || downloadState == "completed"
        }
    }

    private func file(from f: Cached.File) -> DebridFile {
        DebridFile(id: f.id, name: f.name ?? f.shortName ?? "", shortName: f.shortName ?? f.name ?? "",
                   size: f.size ?? 0, mimetype: f.mimetype)
    }

    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] {
        guard !hashes.isEmpty else { return [:] }
        var out: [String: [DebridFile]] = [:]
        // Up to 100 hashes per call.
        for chunk in hashes.chunked(into: 100) {
            let joined = chunk.joined(separator: ",")
            let encoded = joined.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? joined
            guard let url = URL(string: "\(Self.base)/checkcached?hash=\(encoded)&format=list&list_files=true") else { continue }
            let env: Envelope<[Cached]> = try await get(url)
            for c in env.data ?? [] {
                out[c.hash.lowercased()] = (c.files ?? []).map(file(from:))
            }
        }
        return out
    }

    func resolve(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {
        try await resolveWithIds(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: episode).url
    }

    /// TorBox carries stable `torrent_id`+`file_id`, so surface them: a later resume can hit `requestdl`
    /// directly (no re-add) to mint a fresh link (see `reresolveLink`).
    func resolveWithIds(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?)
        async throws -> (url: URL, torrentId: Int?, fileId: Int?) {
        let srcProbeStart = Date()
        DebridProbe.log("resolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) createtorrent + resolve begin")
        // 1. Add the magnet (idempotent; returns the existing torrent_id if already in the library).
        let created: Envelope<Created> = try await postMultipart("\(Self.base)/createtorrent", fields: ["magnet": magnet])
        var torrentId = created.data?.torrentId

        // 2. If it wasn't immediately cached, poll mylist by hash until a torrent_id appears + it's ready.
        var files: [DebridFile] = []
        if let id = torrentId, let item = try? await fetchItem(id: id), item.ready {
            files = (item.files ?? []).map(file(from:))
        } else {
            files = try await pollByHash(infoHash.lowercased(), into: &torrentId)
        }
        guard let id = torrentId else {
            DebridProbe.log("resolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) -> notReady (no torrentId after poll) elapsed=\(DebridProbe.since(srcProbeStart))ms")
            throw DebridError.notReady
        }
        guard let pick = DebridResolve.pickFile(files, episode: episode, fileIdx: fileIdx) else {
            DebridProbe.log("resolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) -> noMatchingFile (files=\(files.count)) elapsed=\(DebridProbe.since(srcProbeStart))ms")
            throw DebridError.noMatchingFile
        }

        // 3. Request the direct stream URL.
        let url = try await requestDL(torrentId: id, fileId: pick.id)
        DebridProbe.log("resolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) -> OK torrentId=\(id) fileId=\(pick.id) elapsed=\(DebridProbe.since(srcProbeStart))ms")
        return (url, id, pick.id)
    }

    /// Regenerate a fresh link from the stored ids. When `torrentId`+`fileId` are present, this is a single
    /// `requestdl` (no add step) — the fast path a debrid resume wants. If TorBox 404s the file (evicted),
    /// fall back to a full re-add via the default resolve. Nil ids also fall back.
    func reresolveLink(infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?) async throws -> URL {
        // [src-probe] CW-resume fast path: mint a fresh link from the stored torrentId+fileId (no re-add). A
        // fall-through here means the stored ids were stale/evicted and we drop to a full re-add.
        DebridProbe.log("reresolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) fast-path ids torrentId=\(torrentId.map(String.init) ?? "nil") fileId=\(fileId.map(String.init) ?? "nil")")
        if let tid = torrentId, let fid = fileId {
            // Any provider-side failure on this fast path (evicted file -> .notCached, non-2xx -> .providerError,
            // a transient 401/403 during a key refresh -> .invalidKey, or a not-yet-ready blip -> .notReady) is
            // recoverable by the full re-add below, so fall through on all of them rather than aborting.
            do {
                let u = try await requestDL(torrentId: tid, fileId: fid)
                DebridProbe.log("reresolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) fast-path requestdl OK")
                return u
            }
            catch DebridError.notCached { DebridProbe.log("reresolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) fast-path notCached (file evicted) -> re-add") }
            catch DebridError.providerError { DebridProbe.log("reresolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) fast-path providerError -> re-add") }
            catch DebridError.invalidKey { DebridProbe.log("reresolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) fast-path invalidKey (auth blip) -> re-add") }
            catch DebridError.notReady { DebridProbe.log("reresolve.torbox", "infoHash=\(DebridProbe.h8(infoHash)) fast-path notReady -> re-add") }
        }
        let magnet = DebridResolve.magnet(forHash: infoHash)
        return try await resolve(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: nil)
    }

    /// The `requestdl` leg: mint a direct stream URL for a known torrent_id+file_id. A missing file surfaces
    /// as `.notCached` (a 404/"not found" from TorBox) so the caller can re-add.
    private func requestDL(torrentId: Int, fileId: Int) async throws -> URL {
        // Auth rides the Authorization: Bearer header set by `get`; do NOT also put the key in the query string
        // (it would leak into URL logs/caches). token= is intentionally omitted.
        guard let url = URL(string: "\(Self.base)/requestdl?torrent_id=\(torrentId)&file_id=\(fileId)&redirect=false") else {
            throw DebridError.providerError("bad requestdl url")
        }
        let link: Envelope<String> = try await get(url)
        guard let s = link.data, let u = URL(string: s) else { throw DebridError.notCached }
        return u
    }

    /// Fetch one torrent by numeric id.
    private func fetchItem(id: Int) async throws -> Item? {
        guard let url = URL(string: "\(Self.base)/mylist?id=\(id)&bypass_cache=true") else { return nil }
        let env: Envelope<Item> = try await get(url)
        return env.data
    }

    /// Poll the library by infohash until the torrent is ready (a CONFIRMED-cached torrent should be ready on
    /// the first poll or two). Fast-fails an uncached add as `.notReady` for the caller to fall back to the
    /// engine, mirroring the RealDebrid active-download early-out: a genuinely-cached torrent reports ready
    /// almost immediately, so if THIS hash surfaces in the list but is NOT ready after one grace poll it is
    /// actively downloading (was not cached) and will never finish inside the play-time budget: bail now
    /// instead of looping ~30s. A hash that never surfaces still gets the full poll window (it may be settling
    /// into the list).
    private func pollByHash(_ hash: String, into torrentId: inout Int?) async throws -> [DebridFile] {
        for attempt in 0..<10 {
            try Task.checkCancellation()   // a losing leg of the parallel cached-race (or the resolve bound) cancels the group: stop polling promptly, don't keep hitting the provider
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }   // 3s between polls
            guard let url = URL(string: "\(Self.base)/mylist?bypass_cache=true") else { break }
            let env: Envelope<[Item]> = try await get(url)
            // Match the torrent for THIS hash (newly added or promoted from the queue); ready when cached/
            // completed with files present.
            let mineForHash = (env.data ?? []).first(where: { $0.hash?.lowercased() == hash })
            if let mine = mineForHash, mine.ready, !(mine.files ?? []).isEmpty {
                torrentId = mine.id
                return (mine.files ?? []).map(file(from:))
            }
            // NOT-CACHED FAST-FAIL: the hash is in the account but not ready after one grace poll = an active,
            // uncached download. Stop here so a false-cached tap reaches a truly-cached source in ~1s instead
            // of hanging the poll loop.
            if attempt >= 1, mineForHash != nil { throw DebridError.notReady }
        }
        throw DebridError.notReady
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private func postMultipart<T: Decodable>(_ urlString: String, fields: [String: String]) async throws -> T {
        guard let url = URL(string: urlString) else { throw DebridError.providerError("bad url") }
        let boundary = "vortx-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw DebridError.invalidKey }
        guard (200...299).contains(code) else { throw DebridError.providerError("HTTP \(code)") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DebridError.providerError("decode: \(error.localizedDescription)") }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - TorBox usenet resolver

/// TorBox USENET resolver. A DROP-IN TWIN of `TorBoxResolver`, pointed at TorBox's `/usenet/*` backend
/// (base `https://api.torbox.app/v1/api/usenet`, same Bearer auth). A usenet stream carries an `.nzb`
/// link (`CoreStream.nzbUrl`) instead of an infohash; the resolver adds the nzb, waits until TorBox has
/// it present, picks the video file, and mints a direct HTTPS URL the player opens as a plain direct
/// stream (NOT a torrent — no `/create`, no warm-up, no torrent teardown). The identifier is the md5 of
/// the nzb link (TorBox's usenet cache key). Fail-soft: any failure throws a `DebridError`, which the
/// coordinator's bounded resolve collapses to `nil`.
actor TorBoxUsenetResolver {
    private let apiKey: String
    private let session: URLSession
    private static let base = "https://api.torbox.app/v1/api/usenet"
    fileprivate static let queryValueAllowed = DebridQuery.valueAllowed

    init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    /// md5 of an nzb link, TorBox's usenet cache identifier (the usenet twin of the torrent infohash).
    static func identifier(forNzbURL nzbUrl: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(nzbUrl.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Reuse the torrent envelope + file shapes; the /usenet/* JSON is the same structure.
    private struct Envelope<T: Decodable>: Decodable { let success: Bool; let data: T? }
    private struct Cached: Decodable {
        let hash: String
        let files: [File]?
        struct File: Decodable {
            let id: Int; let name: String?; let size: Int64?; let mimetype: String?
            let shortName: String?
            enum CodingKeys: String, CodingKey { case id, name, size, mimetype; case shortName = "short_name" }
        }
    }
    private struct Created: Decodable {
        let usenetId: Int?
        enum CodingKeys: String, CodingKey { case usenetId = "usenetdownload_id" }
    }
    private struct Item: Decodable {
        let id: Int; let hash: String?; let downloadFinished: Bool?; let downloadPresent: Bool?; let downloadState: String?
        let files: [Cached.File]?
        enum CodingKeys: String, CodingKey {
            case id, hash, files
            case downloadFinished = "download_finished", downloadPresent = "download_present"
            case downloadState = "download_state"
        }
        var ready: Bool {
            (downloadFinished == true && downloadPresent == true)
                || downloadState == "cached" || downloadState == "completed"
        }
    }

    private func file(from f: Cached.File) -> DebridFile {
        DebridFile(id: f.id, name: f.name ?? f.shortName ?? "", shortName: f.shortName ?? f.name ?? "",
                   size: f.size ?? 0, mimetype: f.mimetype)
    }

    /// Which nzb md5s the user's usenet account has cached (drives the ⚡). Batched like the torrent side.
    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] {
        guard !hashes.isEmpty else { return [:] }
        var out: [String: [DebridFile]] = [:]
        for chunk in hashes.chunked(into: 100) {
            let joined = chunk.joined(separator: ",")
            let encoded = joined.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? joined
            guard let url = URL(string: "\(Self.base)/checkcached?hash=\(encoded)&format=list&list_files=true") else { continue }
            let env: Envelope<[Cached]> = try await get(url)
            for c in env.data ?? [] {
                out[c.hash.lowercased()] = (c.files ?? []).map(file(from:))
            }
        }
        return out
    }

    /// Resolve one usenet stream (nzb link) to a direct HTTPS URL. Mirrors the torrent resolve flow:
    /// createusenetdownload -> poll mylist until present -> pick the file -> requestdl. `fileMustInclude`
    /// (a regex) and `fileIdx` bias the pick when present; otherwise the shared `pickFile` heuristic runs.
    /// `knownHash` is the source's authoritative NZB md5 when the emitter had one (TorBox search results
    /// carry it); the md5-of-the-link fallback only matches when TorBox derived its key the same way.
    func resolve(nzbUrl: String, knownHash: String? = nil, fileMustInclude: String?, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {
        // 1. Add the nzb (JSON body; post_processing default -1). Idempotent: TorBox returns the existing
        //    download id if the same nzb is already in the user's usenet list.
        let created: Envelope<Created> = try await postJSON("\(Self.base)/createusenetdownload",
                                                            body: ["link": nzbUrl, "post_processing": -1])
        var usenetId = created.data?.usenetId

        // 2. Poll mylist until the download is finished + present (cached should be ~1 poll).
        var files: [DebridFile] = []
        if let id = usenetId, let item = try? await fetchItem(id: id), item.ready {
            files = (item.files ?? []).map(file(from:))
        } else {
            files = try await pollById(&usenetId, hash: knownHash?.lowercased() ?? Self.identifier(forNzbURL: nzbUrl))
        }
        guard let id = usenetId else { throw DebridError.notReady }

        // 3. Pick the file, honoring fileMustInclude / fileIdx, then the shared episode/size heuristic.
        guard let pick = pickUsenetFile(files, mustInclude: fileMustInclude, fileIdx: fileIdx, episode: episode) else {
            throw DebridError.noMatchingFile
        }

        // 4. Request the direct stream URL.
        return try await requestDL(usenetId: id, fileId: pick.id)
    }

    /// File pick with the usenet-specific `fileMustInclude` regex applied FIRST (when present + it matches
    /// a video), then the shared `DebridResolve.pickFile` (explicit idx -> SxEy -> largest video).
    private func pickUsenetFile(_ files: [DebridFile], mustInclude: String?, fileIdx: Int?, episode: DebridEpisode?) -> DebridFile? {
        if let pattern = mustInclude, !pattern.isEmpty,
           let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let matched = files.filter { f in
                guard f.isVideo else { return false }
                let name = f.shortName.isEmpty ? f.name : f.shortName
                return re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
            if let best = DebridResolve.pickFile(matched, episode: episode, fileIdx: nil) { return best }
        }
        return DebridResolve.pickFile(files, episode: episode, fileIdx: fileIdx)
    }

    /// The `requestdl` leg: mint a direct stream URL for a known usenet_id+file_id.
    private func requestDL(usenetId: Int, fileId: Int) async throws -> URL {
        // Auth rides the Authorization: Bearer header set by `get`; the key is not repeated in the query string.
        guard let url = URL(string: "\(Self.base)/requestdl?usenet_id=\(usenetId)&file_id=\(fileId)&redirect=false") else {
            throw DebridError.providerError("bad requestdl url")
        }
        let link: Envelope<String> = try await get(url)
        guard let s = link.data, let u = URL(string: s) else { throw DebridError.notCached }
        return u
    }

    private func fetchItem(id: Int) async throws -> Item? {
        guard let url = URL(string: "\(Self.base)/mylist?id=\(id)&bypass_cache=true") else { return nil }
        let env: Envelope<Item> = try await get(url)
        return env.data
    }

    /// Poll the usenet list until the download is ready. Match by id when we have one, else by the nzb md5
    /// (TorBox echoes the hash), promoting the resolved id out via `inout`. Streaming timeout ~30s; an
    /// uncached download surfaces as `.notReady` (the caller shows "caching…" and does not hang).
    private func pollById(_ usenetId: inout Int?, hash: String) async throws -> [DebridFile] {
        for attempt in 0..<10 {
            try Task.checkCancellation()   // bounded-resolve timeout cancels the group: stop polling promptly, don't orphan
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }   // 3s between polls
            if let id = usenetId {
                if let item = try? await fetchItem(id: id), item.ready, !(item.files ?? []).isEmpty {
                    return (item.files ?? []).map(file(from:))
                }
                continue
            }
            guard let url = URL(string: "\(Self.base)/mylist?bypass_cache=true") else { break }
            let env: Envelope<[Item]> = try await get(url)
            if let mine = (env.data ?? []).first(where: { $0.hash?.lowercased() == hash && $0.ready && !($0.files ?? []).isEmpty }) {
                usenetId = mine.id
                return (mine.files ?? []).map(file(from:))
            }
        }
        throw DebridError.notReady
    }

    // MARK: HTTP (Bearer auth, same contract as TorBoxResolver.send)

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private func postJSON<T: Decodable>(_ urlString: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: urlString) else { throw DebridError.providerError("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw DebridError.invalidKey }
        guard (200...299).contains(code) else { throw DebridError.providerError("HTTP \(code)") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DebridError.providerError("decode: \(error.localizedDescription)") }
    }
}

// MARK: - Real-Debrid resolver (torrents)

/// Real-Debrid native resolver. Base `https://api.real-debrid.com/rest/1.0`, Bearer auth. Real-Debrid REMOVED
/// its instant cache-check (the old `/torrents/instantAvailability` now returns empty), so `checkCache` is a
/// no-op and cached torrents resolve through the add-then-poll flow instead (near-instant when cached).
/// Flow: addMagnet -> selectFiles(all) -> poll info until `downloaded` -> pick the file -> unrestrict its link.
/// NOTE: the API flow follows the Brain spec (vortx-debrid-implementation.md); it is compile-verified but not
/// yet live-verified (needs a real key), and stays inert until the source-list/play-path wiring calls it.
actor RealDebridResolver: DebridResolving {
    nonisolated let service: DebridService = .realDebrid
    private let apiKey: String
    private let session: URLSession
    private static let base = "https://api.real-debrid.com/rest/1.0"

    init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] { [:] }   // removed upstream

    private struct AddResp: Decodable { let id: String }
    private struct Info: Decodable {
        let status: String
        let files: [F]?
        let links: [String]?
        struct F: Decodable { let id: Int; let path: String; let bytes: Int64; let selected: Int }
    }
    private struct Unrestrict: Decodable { let download: String }

    func resolve(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {
        let srcProbeStart = Date()
        DebridProbe.log("resolve.rd", "infoHash=\(DebridProbe.h8(infoHash)) addMagnet + resolve begin")
        let add: AddResp = try await form("\(Self.base)/torrents/addMagnet", ["magnet": magnet])
        let id = add.id
        // Wait for RD to parse the magnet into its file list (magnet_conversion -> waiting_files_selection).
        var fileList: [Info.F] = []
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            let i: Info = try await get("\(Self.base)/torrents/info/\(id)")
            if ["magnet_error", "error", "virus", "dead"].contains(i.status) { throw DebridError.providerError("status \(i.status)") }
            if let fs = i.files, !fs.isEmpty { fileList = fs; break }
        }
        guard !fileList.isEmpty else { throw DebridError.notReady }
        // Pick the ONE target file (DebridFile.id = RD's own file id) by the episode/size heuristic over the
        // full list, then select ONLY it. This is the verified-against-live-API path: RD packs a MULTI-file
        // selection into a single RAR link (unstreamable), and selectFiles is a no-op once the torrent has
        // downloaded — so selecting the wanted file alone, before download, is the only way to get one
        // streamable link. `links.first` is then that file's restricted link.
        let dfiles = fileList.map { f -> DebridFile in
            DebridFile(id: f.id, name: f.path, shortName: (f.path as NSString).lastPathComponent, size: f.bytes, mimetype: nil)
        }
        guard let pick = DebridResolve.pickFile(dfiles, episode: episode, fileIdx: nil) else { throw DebridError.noMatchingFile }
        try await formVoid("\(Self.base)/torrents/selectFiles/\(id)", ["files": String(pick.id)])
        var link: String?
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            let i: Info = try await get("\(Self.base)/torrents/info/\(id)")
            if ["magnet_error", "error", "virus", "dead"].contains(i.status) { throw DebridError.providerError("status \(i.status)") }
            if i.status == "downloaded", let first = i.links?.first { link = first; break }
            // NOT-CACHED FAST-FAIL. RD retired /torrents/instantAvailability, so the ⚡ "cached" badge on an
            // RD row is the ADD-ON's claim, not a check against THIS account. A genuinely cached torrent
            // reports "downloaded" within the first poll or two; an ACTIVE-download status means RD is
            // pulling it from peers now = it was NOT cached, and it will never finish inside the play-time
            // budget. Bail immediately (after one grace poll for the status to settle) so the user reaches a
            // truly-cached source in a couple of seconds instead of hanging out the 15s play-resolve timeout
            // on every false-cached tap (the "first 5 Cached sources timed out" report).
            if attempt >= 1, ["downloading", "queued", "compressing", "uploading"].contains(i.status) {
                DebridProbe.log("resolve.rd", "infoHash=\(DebridProbe.h8(infoHash)) NOT-CACHED fast-fail (status=\(i.status), active download) elapsed=\(DebridProbe.since(srcProbeStart))ms")
                throw DebridError.notReady
            }
        }
        guard let link else {
            DebridProbe.log("resolve.rd", "infoHash=\(DebridProbe.h8(infoHash)) -> notReady (never reached 'downloaded') elapsed=\(DebridProbe.since(srcProbeStart))ms")
            throw DebridError.notReady
        }
        let un: Unrestrict = try await form("\(Self.base)/unrestrict/link", ["link": link])
        guard let u = URL(string: un.download) else { throw DebridError.providerError("no download url") }
        DebridProbe.log("resolve.rd", "infoHash=\(DebridProbe.h8(infoHash)) -> OK unrestricted link elapsed=\(DebridProbe.since(srcProbeStart))ms")
        return u
    }

    private func get<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else { throw DebridError.providerError("bad url") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }
    private func form<T: Decodable>(_ urlString: String, _ fields: [String: String]) async throws -> T {
        try await send(formRequest(urlString, fields))
    }
    private func formVoid(_ urlString: String, _ fields: [String: String]) async throws {
        let (_, resp) = try await session.data(for: formRequest(urlString, fields))   // selectFiles is 204, no body
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw DebridError.invalidKey }
        guard (200...299).contains(code) else { throw DebridError.providerError("HTTP \(code)") }
    }
    private func formRequest(_ urlString: String, _ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: URL(string: urlString) ?? Self.fallbackURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = DebridForm.encode(fields)
        return req
    }
    private static let fallbackURL = URL(string: "https://api.real-debrid.com")!
    private func send<T: Decodable>(_ req: URLRequest) async throws -> T { try await DebridHTTP.decode(session, req) }
}

// MARK: - AllDebrid resolver (torrents)

/// AllDebrid native resolver. Base `https://api.alldebrid.com/v4`, auth via `agent` + `apikey` query params.
/// Flow: `/magnet/upload` -> poll `/magnet/status` until statusCode 4 (Ready) -> pick the file from the link
/// list -> `/link/unlock` for the direct URL. `checkCache` is deferred to the wiring tick (resolve is fast for
/// cached). Spec-derived, compile-verified, not yet live-verified; inert until wired.
actor AllDebridResolver: DebridResolving {
    nonisolated let service: DebridService = .allDebrid
    private let apiKey: String
    private let session: URLSession
    private static let base = "https://api.alldebrid.com/v4"

    init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    /// `GET /magnet/instant`, `magnets[]` = infohashes. AllDebrid still ships this in 2026 (only Real-Debrid
    /// removed its cache-check), but it is known to be flaky, so a failed/empty chunk simply yields no
    /// confirmations for those hashes and the resolve path still works. Batch ~40.
    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] {
        guard !hashes.isEmpty else { return [:] }
        var out: [String: [DebridFile]] = [:]
        for chunk in hashes.chunked(into: 40) {
            let items = chunk.map { URLQueryItem(name: "magnets[]", value: $0) }
            guard let env: Env<InstantData> = try? await get(authed("/magnet/instant", items)),
                  env.status == "success", let magnets = env.data?.magnets else { continue }
            for m in magnets where (m.instant ?? false) {
                let files = (m.files ?? []).compactMap { f -> DebridFile? in
                    guard let n = f.n else { return nil }
                    return DebridFile(id: 0, name: n, shortName: (n as NSString).lastPathComponent, size: f.s ?? 0, mimetype: nil)
                }
                // A cached hash MUST map to a non-empty file list to enter the confirmed-cached set; if the
                // instant tree was omitted, a placeholder keeps the hash confirmed (resolve picks the file).
                out[m.hash.lowercased()] = files.isEmpty ? [DebridFile(id: 0, name: m.hash, shortName: m.hash, size: 0, mimetype: nil)] : files
            }
        }
        return out
    }

    private struct Env<T: Decodable>: Decodable { let status: String; let data: T? }
    private struct InstantData: Decodable {
        let magnets: [InstantMagnet]?
        struct InstantMagnet: Decodable {
            let hash: String
            let instant: Bool?
            let files: [IFile]?
            struct IFile: Decodable { let n: String?; let s: Int64? }
        }
    }
    private struct UploadData: Decodable { let magnets: [UpMagnet]?; struct UpMagnet: Decodable { let id: Int? } }
    private struct StatusData: Decodable {
        let magnets: StatusMagnet?
        struct StatusMagnet: Decodable {
            let statusCode: Int?
            let links: [Link]?
            enum CodingKeys: String, CodingKey { case statusCode, links }
        }
        struct Link: Decodable { let link: String; let filename: String?; let size: Int64? }
    }
    private struct UnlockData: Decodable { let link: String? }

    func resolve(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {
        let upEnv: Env<UploadData> = try await get(authed("/magnet/upload", [URLQueryItem(name: "magnets[]", value: magnet)]))
        guard let id = upEnv.data?.magnets?.first?.id else { throw DebridError.providerError("upload") }
        var links: [StatusData.Link] = []
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            let st: Env<StatusData> = try await get(authed("/magnet/status", [URLQueryItem(name: "id", value: String(id))]))
            guard let m = st.data?.magnets else { continue }
            if m.statusCode == 4, let ls = m.links, !ls.isEmpty { links = ls; break }   // 4 = Ready
            if let sc = m.statusCode, sc >= 5 { throw DebridError.providerError("status \(sc)") }   // 5+ = error/expired
        }
        guard !links.isEmpty else { throw DebridError.notReady }
        let dfiles = links.enumerated().map { idx, l -> DebridFile in
            let name = l.filename ?? ""
            return DebridFile(id: idx, name: name, shortName: (name as NSString).lastPathComponent, size: l.size ?? 0, mimetype: nil)
        }
        // fileIdx is torrent-wide; AD's link list may differ in order/count, so pick by the filename/size
        // heuristic (which keeps `links[pick.id]` aligned), not by the raw torrent index.
        guard let pick = DebridResolve.pickFile(dfiles, episode: episode, fileIdx: nil),
              links.indices.contains(pick.id) else { throw DebridError.noMatchingFile }
        let un: Env<UnlockData> = try await get(authed("/link/unlock", [URLQueryItem(name: "link", value: links[pick.id].link)]))
        guard let s = un.data?.link, let u = URL(string: s) else { throw DebridError.providerError("unlock") }
        return u
    }

    private func authed(_ path: String, _ extra: [URLQueryItem]) -> URL {
        var c = URLComponents(string: Self.base + path)
        c?.queryItems = [URLQueryItem(name: "agent", value: "vortx"), URLQueryItem(name: "apikey", value: apiKey)] + extra
        return c?.url ?? URL(string: Self.base)!
    }
    private func get<T: Decodable>(_ url: URL) async throws -> T { try await DebridHTTP.decode(session, URLRequest(url: url)) }
}

// MARK: - Premiumize resolver (torrents)

/// Premiumize native resolver. Base `https://www.premiumize.me/api`, auth via `apikey` query param. One call
/// does it: `POST /transfer/directdl` with the magnet returns the file list WITH direct links (instant for
/// cached, so there is no separate unrestrict step). `checkCache` is deferred to the wiring tick. Spec-derived,
/// compile-verified, not yet live-verified; inert until wired.
actor PremiumizeResolver: DebridResolving {
    nonisolated let service: DebridService = .premiumize
    private let apiKey: String
    private let session: URLSession
    private static let base = "https://www.premiumize.me/api"

    init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    /// `POST /api/cache/check` with `items[]` = bare infohashes. The response arrays are positionally aligned
    /// with `items[]`; a `true` in `response` means `transfer/directdl` will succeed instantly for that hash.
    /// It does not consume fair-use quota. Premiumize still ships this in 2026 (only Real-Debrid removed its
    /// cache-check). Any failure yields no confirmations for that chunk (resolve still works); batch ~80.
    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] {
        guard !hashes.isEmpty else { return [:] }
        var out: [String: [DebridFile]] = [:]
        for chunk in hashes.chunked(into: 80) {
            guard let r: CacheCheck = try? await formItems("/cache/check", chunk.map { ("items[]", $0) }),
                  r.status == "success", let flags = r.response else { continue }
            for (i, hash) in chunk.enumerated() where i < flags.count && flags[i] {
                let name = (r.filename.flatMap { i < $0.count ? $0[i] : nil } ?? nil) ?? hash
                let size = r.filesize.flatMap { i < $0.count ? $0[i].value : nil } ?? 0
                out[hash.lowercased()] = [DebridFile(id: 0, name: name, shortName: (name as NSString).lastPathComponent, size: size, mimetype: nil)]
            }
        }
        return out
    }

    private struct CacheCheck: Decodable {
        let status: String
        let response: [Bool]?
        let filename: [String?]?
        let filesize: [PMSize]?
    }
    /// Premiumize returns `filesize` as a base-10 STRING on a hit and the integer `0` on a miss; decode both.
    private struct PMSize: Decodable {
        let value: Int64
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = Int64(s) ?? 0 }
            else { value = (try? c.decode(Int64.self)) ?? 0 }
        }
    }

    private struct DirectDL: Decodable {
        let status: String
        let content: [Item]?
        struct Item: Decodable {
            let path: String?; let size: Int64?; let link: String?; let streamLink: String?
            enum CodingKeys: String, CodingKey { case path, size, link; case streamLink = "stream_link" }
        }
    }

    func resolve(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {
        let dl: DirectDL = try await form("/transfer/directdl", ["src": magnet])
        guard dl.status == "success" else { throw DebridError.providerError("directdl \(dl.status)") }
        guard let content = dl.content, !content.isEmpty else { throw DebridError.notReady }
        let dfiles = content.enumerated().map { idx, c -> DebridFile in
            let name = c.path ?? ""
            return DebridFile(id: idx, name: name, shortName: (name as NSString).lastPathComponent, size: c.size ?? 0, mimetype: nil)
        }
        // fileIdx is torrent-wide; PM's directdl content order may differ, so pick by the filename/size
        // heuristic (which keeps `content[pick.id]` aligned), not by the raw torrent index.
        guard let pick = DebridResolve.pickFile(dfiles, episode: episode, fileIdx: nil),
              content.indices.contains(pick.id) else { throw DebridError.noMatchingFile }
        let item = content[pick.id]
        guard let s = item.streamLink ?? item.link, let u = URL(string: s) else { throw DebridError.providerError("no link") }
        return u
    }

    private func form<T: Decodable>(_ path: String, _ fields: [String: String]) async throws -> T {
        var c = URLComponents(string: Self.base + path)
        c?.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        var req = URLRequest(url: c?.url ?? URL(string: Self.base)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = DebridForm.encode(fields)
        return try await DebridHTTP.decode(session, req)
    }

    /// POST with REPEATED form keys (the `[String: String]` `form` above collapses duplicate keys, but
    /// `/cache/check` needs many `items[]=...`). `apikey` rides the query, matching `form`.
    private func formItems<T: Decodable>(_ path: String, _ pairs: [(String, String)]) async throws -> T {
        var c = URLComponents(string: Self.base + path)
        c?.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        var req = URLRequest(url: c?.url ?? URL(string: Self.base)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&").data(using: .utf8)
        return try await DebridHTTP.decode(session, req)
    }
}

// MARK: - Shared HTTP helpers (for the query/Bearer-auth resolvers above)

enum DebridForm {
    /// `application/x-www-form-urlencoded` body from string fields.
    static func encode(_ fields: [String: String]) -> Data {
        fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

enum DebridHTTP {
    /// Send a request and decode JSON, mapping 401/403 to `.invalidKey`, other non-2xx to `.providerError`,
    /// and decode failures to `.providerError` — the same contract `TorBoxResolver.send` uses.
    static func decode<T: Decodable>(_ session: URLSession, _ req: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw DebridError.invalidKey }
        guard (200...299).contains(code) else { throw DebridError.providerError("HTTP \(code)") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DebridError.providerError("decode: \(error.localizedDescription)") }
    }
}

// MARK: - Coordinator

/// Builds resolvers from the user's stored keys and drives cache-check + playback resolution. TorBox is
/// wired now; Real-Debrid (add-then-poll, no instant cache-check), AllDebrid, and Premiumize slot in as
/// further `DebridResolving` conformers. Owned by the stream/play layer; reads `DebridKeys.shared`.
///
/// ISOLATION: this is an `actor`, NOT `@MainActor`. Its only state (`resolvers`, `torboxUsenet`) is mutated
/// in `reload(keys:)` / `warmIfNeeded()` and read in the async resolve/cache-check methods, so the actor's own serial executor keeps
/// those accesses race-free WITHOUT pinning them to the main thread. This matters for `cacheCheck`: the
/// per-provider probes are already off-main (the resolvers are actors), but under the old `@MainActor` the
/// O(services x hashes) merge loop AND every `await` continuation resumed on the main actor, so a cacheCheck
/// over a large source list (thousands of hashes) hitched the UI thread. As an actor the merge and the
/// resumptions run on a background executor; nothing here is UI state, so nothing needs the main actor.
actor DebridCoordinator {
    static let shared = DebridCoordinator()

    private var resolvers: [DebridService: any DebridResolving] = [:]
    /// The TorBox usenet resolver, built only when a TorBox key is configured (usenet is a TorBox-only
    /// backend among the four services). Separate from `resolvers` because usenet resolves off an nzb link,
    /// not the infohash/magnet the `DebridResolving` protocol takes. nil = no TorBox key = usenet inert.
    private var torboxUsenet: TorBoxUsenetResolver?

    /// Whether the resolvers have been built at least once (from `reload(keys:)` or the lazy warm). A no-key
    /// user leaves `resolvers` empty, so `resolvers.isEmpty` alone cannot tell "never warmed" from "warmed,
    /// no keys" and would re-hop to the main actor on every resolve. This flag makes the lazy warm hop AT
    /// MOST ONCE until a key change explicitly reloads, preserving the cheap no-key fast path.
    private var didWarm = false

    /// (Re)build resolvers from a Sendable key SNAPSHOT. Call after a key changes.
    ///
    /// RACE-SAFETY: takes a `[DebridService: String]` value, NOT the `DebridKeys` reference. `DebridKeys.keys`
    /// is a plain `@Published` dictionary mutated on the MAIN actor (per-keystroke `setKey`, and the
    /// sync-apply path). Reading that dictionary from THIS actor's background executor while main mutates it
    /// is a concurrent Dictionary read/write == undefined behavior. So every caller captures a snapshot on
    /// the main actor and hands us the value; we only ever touch the immutable copy.
    func reload(keys: [DebridService: String]) {
        resolvers.removeAll()
        torboxUsenet = nil
        func keyFor(_ s: DebridService) -> String? {
            guard let k = keys[s], !k.isEmpty else { return nil }
            return k
        }
        if let k = keyFor(.torBox) {
            resolvers[.torBox] = TorBoxResolver(apiKey: k)
            torboxUsenet = TorBoxUsenetResolver(apiKey: k)
        }
        if let k = keyFor(.realDebrid) { resolvers[.realDebrid] = RealDebridResolver(apiKey: k) }
        if let k = keyFor(.allDebrid) { resolvers[.allDebrid] = AllDebridResolver(apiKey: k) }
        if let k = keyFor(.premiumize) { resolvers[.premiumize] = PremiumizeResolver(apiKey: k) }
        didWarm = true
    }

    /// Lazy first-use warm: build the resolvers from a fresh main-actor snapshot IF they have not been built
    /// yet. Replaces the old synchronous `if resolvers.isEmpty { reload() }` warm, which read `DebridKeys`
    /// off-main (the race). Hopping to the main actor for the snapshot keeps the read serialized with the
    /// key writers; the `reload` that follows only touches actor-isolated state on this executor.
    private func warmIfNeeded() async {
        guard !didWarm else { return }
        let snapshot = await MainActor.run { DebridKeys.shared.snapshot }
        // Re-check under the actor: a concurrent warm (or an explicit reload) may have run across the await.
        guard !didWarm else { return }
        reload(keys: snapshot)
    }

    /// True when a usenet resolve is possible (a TorBox key is configured). Gates both the usenet play
    /// path and the usenet cache-check; with no TorBox key everything usenet behaves exactly as before.
    var hasUsenetResolver: Bool {
        get async { await warmIfNeeded(); return torboxUsenet != nil }
    }

    var hasAnyResolver: Bool {
        get async { await warmIfNeeded(); return !resolvers.isEmpty }
    }

    /// Which provider has each hash cached (first configured provider that reports it), with the files.
    /// Queries every configured provider CONCURRENTLY (resolvers are actors, so the captures are Sendable),
    /// then merges in a deterministic `DebridService.allCases` priority order so the chosen provider for a
    /// hash is stable. Previously this looped providers sequentially AND in nondeterministic dict order.
    func cacheCheck(hashes: [String]) async -> [String: (service: DebridService, files: [DebridFile])] {
        await warmIfNeeded()
        guard !resolvers.isEmpty, !hashes.isEmpty else { return [:] }
        let maps: [DebridService: [String: [DebridFile]]] = await withTaskGroup(
            of: (DebridService, [String: [DebridFile]]).self
        ) { group in
            for (service, resolver) in resolvers {
                group.addTask { (service, (try? await resolver.checkCache(hashes: hashes)) ?? [:]) }
            }
            var collected: [DebridService: [String: [DebridFile]]] = [:]
            for await (service, map) in group { collected[service] = map }
            return collected
        }
        var out: [String: (service: DebridService, files: [DebridFile])] = [:]
        for service in DebridService.allCases {
            guard let map = maps[service] else { continue }
            for (hash, files) in map where !files.isEmpty && out[hash] == nil {
                out[hash] = (service, files)
            }
        }
        return out
    }

    /// Resolve a torrent to a direct stream URL via the given (or first available) provider.
    func resolve(service: DebridService? = nil, infoHash: String, magnet: String,
                 fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {
        await warmIfNeeded()
        let resolver = pick(service)
        guard let resolver else { throw DebridError.noKey }
        return try await resolver.resolve(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: episode)
    }

    /// Resolve, surfacing the provider + ids (for a later `reresolve`). Chooses the given service or the
    /// first configured resolver (the same choice `resolve` makes).
    func resolveWithIds(service: DebridService? = nil, infoHash: String, magnet: String,
                        fileIdx: Int?, episode: DebridEpisode?)
        async throws -> (result: (url: URL, torrentId: Int?, fileId: Int?), service: DebridService) {
        await warmIfNeeded()
        guard let resolver = pick(service) else { throw DebridError.noKey }
        let r = try await resolver.resolveWithIds(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: episode)
        return (r, resolver.service)
    }

    /// Regenerate a fresh direct link for a previously-resolved file through the SAME provider, skipping the
    /// add step where the provider supports it. Throws `.noKey` when that provider is no longer configured,
    /// `.notCached`/`.providerError` when the file is gone. Used by the Continue-Watching resume path to
    /// refresh an expired debrid link without the slow full add-on re-resolve.
    func reresolve(service: DebridService, infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?)
        async throws -> URL {
        await warmIfNeeded()
        guard let resolver = resolvers[service] else { throw DebridError.noKey }
        return try await resolver.reresolveLink(infoHash: infoHash, torrentId: torrentId, fileId: fileId, fileIdx: fileIdx)
    }

    private func pick(_ service: DebridService?) -> (any DebridResolving)? {
        if let service { return resolvers[service] }
        return resolvers.values.first
    }

    // MARK: Usenet (TorBox-only)

    /// Resolve a usenet stream (nzb link) to a direct HTTPS URL via the TorBox usenet backend. Throws
    /// `.noKey` when no TorBox key is configured, so the bounded resolve below collapses it to `nil`.
    /// `knownHash` = the stream's authoritative NZB md5 when its emitter carried one (nil otherwise).
    func resolveUsenet(nzbUrl: String, knownHash: String? = nil, fileMustInclude: String?, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {
        await warmIfNeeded()
        guard let usenet = torboxUsenet else { throw DebridError.noKey }
        return try await usenet.resolve(nzbUrl: nzbUrl, knownHash: knownHash, fileMustInclude: fileMustInclude, fileIdx: fileIdx, episode: episode)
    }

    /// Which nzb md5s the user's TorBox usenet account has cached (drives the ⚡ on usenet rows). Empty (a
    /// no-op) when no TorBox key is configured. Keys are the lowercased md5 identifiers, matching
    /// `TorBoxUsenetResolver.identifier(forNzbURL:)`.
    func usenetCacheCheck(nzbMD5s: [String]) async -> Set<String> {
        await warmIfNeeded()
        guard let usenet = torboxUsenet, !nzbMD5s.isEmpty else { return [] }
        let map = (try? await usenet.checkCache(hashes: nzbMD5s)) ?? [:]
        return Set(map.filter { !$0.value.isEmpty }.keys)
    }
}

// MARK: - Play-path bridge (cached debrid → direct link)

extension CoreStream {
    /// The authoritative NZB md5 a usenet stream's emitter attached via a `usenethash:` marker in
    /// `sources` (TorBox search results carry TorBox's own cache key there). nil when absent; the
    /// cache-check / resolve poll then falls back to md5-of-the-link.
    var usenetKnownHash: String? {
        sources?.first(where: { $0.hasPrefix("usenethash:") })
            .map { String($0.dropFirst("usenethash:".count)).lowercased() }
    }
}

extension DebridCoordinator {
    /// Streaming-settle ceiling for an in-line resolve. A CONFIRMED-cached torrent resolves in ~1 round trip,
    /// so 5s comfortably covers it while bounding a stall (a flaky provider, a hung network) so the play action
    /// never hangs the UI. On timeout the resolve Task is cancelled and the caller falls soft to the local
    /// engine. Kept tight (was 15s) because the manual play path now only resolves CONFIRMED-cached picks (a
    /// not-confirmed pick returns nil with zero network and falls straight through), so nothing here should ever
    /// need an add-then-poll window; a resolve that has not produced a link in 5s is a stall, not a slow cache.
    private static let resolveTimeout: Duration = .seconds(5)

    /// The single bridge from a tapped/auto-picked RAW TORRENT to a debrid DIRECT link for playback.
    ///
    /// Returns a remote HTTPS URL the player can open as a plain direct stream (NOT a torrent — it does not
    /// match the `{server}:11470/{40-hex}/{idx}` shape the player keys torrent behaviour off, so it gets no
    /// `/create`, no warm-up, and no `closeTorrent` teardown), or `nil` when the caller should use today's
    /// path unchanged. It is FAIL-SOFT by construction: every non-success (no key, not a raw torrent, any
    /// `DebridError`, a throw, or the timeout) returns `nil`, so the user is never left unable to play.
    ///
    /// NO-KEY GUARANTEE: with no resolver configured (`hasAnyResolver == false`) this returns `nil`
    /// immediately with no network and no provider contact (only the at-most-once lazy warm hop), so the
    /// caller runs exactly the code it ran before this feature existed. The same immediate `nil` applies to
    /// any non-raw-torrent stream (direct URL, YouTube, externalUrl), so direct/trailer playback is also untouched.
    ///
    /// - Parameters:
    ///   - stream: the stream the user is about to play.
    ///   - episode: the SxEy target for a series, so a season-pack resolves the right file. `nil` for movies.
    ///   - confirmedCachedHashes: when non-nil, a raw torrent only resolves if its infoHash is in this set (an
    ///     account-confirmed `DebridCacheAwareness.cachedHashes`); a not-confirmed pick returns nil with ZERO
    ///     network so the caller falls through to the instant embedded path. Pass this on the MANUAL/single
    ///     play paths to keep a tap instant. nil (the default) keeps the pre-gate behaviour for callers that
    ///     already pre-filter to cached candidates (`resolveFirstPlayable`) or want an unconditional resolve.
    ///   - confirmedUsenetURLs: the usenet parallel of `confirmedCachedHashes` (account-confirmed nzb links).
    func resolvedPlaybackURL(for stream: CoreStream, episode: DebridEpisode? = nil,
                             confirmedCachedHashes: Set<String>? = nil,
                             confirmedUsenetURLs: Set<String>? = nil) async -> URL? {
        await resolvedPlaybackRef(for: stream, episode: episode,
                                  confirmedCachedHashes: confirmedCachedHashes,
                                  confirmedUsenetURLs: confirmedUsenetURLs)?.url
    }

    /// The same bounded, fail-soft resolve as `resolvedPlaybackURL`, but returning the full
    /// `DebridPlaybackRef` (URL + provider + reresolve ids) so the play-record can persist enough to
    /// later refresh an expired link. `resolvedPlaybackURL` is a thin `?.url` wrapper over this, so every
    /// guarantee (raw-torrent-only, no-key immediate nil (no network, only the at-most-once lazy warm hop),
    /// timeout → nil) is identical.
    func resolvedPlaybackRef(for stream: CoreStream, episode: DebridEpisode? = nil,
                             confirmedCachedHashes: Set<String>? = nil,
                             confirmedUsenetURLs: Set<String>? = nil) async -> DebridPlaybackRef? {
        // USENET first: a stream with an `.nzb` link (and no direct `url`) resolves through the TorBox
        // usenet backend, gated on a TorBox key. With no TorBox key `hasUsenetResolver` is false, so this
        // returns nil here with no network (only the at-most-once lazy warm hop), so a usenet row behaves
        // exactly as today (no playable link). NOT a torrent: the minted URL is a plain direct stream (no
        // infoHash carried).
        if stream.url == nil, let nzb = stream.nzbUrl, !nzb.isEmpty {
            guard await hasUsenetResolver else { return nil }
            // CACHE-GATE (instant first-play): when the caller passed a confirmed-cached set, a not-confirmed
            // usenet row returns nil here with ZERO network (no add-then-poll), so a tap falls straight through
            // to today's embedded path instead of burning the resolve budget. nil set = pre-gate behaviour.
            if let confirmed = confirmedUsenetURLs, !confirmed.contains(nzb) {
                DebridProbe.log("resolve", "usenet nzb=\(DebridProbe.h8(nzb)) gate=NOT-CONFIRMED (confirmedSet=\(confirmed.count)) -> nil ZERO-NETWORK, embedded path")
                return nil
            }
            DebridProbe.log("resolve", "usenet nzb=\(DebridProbe.h8(nzb)) gate=\(confirmedUsenetURLs == nil ? "OPEN(no set)" : "CONFIRMED-CACHED") -> running blocking usenet resolve")
            let mustInclude = stream.fileMustInclude
            let fileIdx = stream.fileIdx
            let knownHash = stream.usenetKnownHash
            return await withTaskGroup(of: DebridPlaybackRef?.self) { group in
                group.addTask {
                    guard let url = try? await DebridCoordinator.shared.resolveUsenet(
                        nzbUrl: nzb, knownHash: knownHash, fileMustInclude: mustInclude, fileIdx: fileIdx, episode: episode) else { return nil }
                    // Usenet is a plain direct link: no infoHash / torrentId to carry (no reresolve fast
                    // path), so the ref's torrent fields are nil. The `url` alone lets the player open it.
                    return DebridPlaybackRef(url: url, service: .torBox, infoHash: "",
                                             torrentId: nil, fileId: nil, fileIdx: fileIdx)
                }
                group.addTask {
                    try? await Task.sleep(for: DebridCoordinator.resolveTimeout)
                    return nil   // timeout sentinel
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        // Raw torrent only: a stream WITH a `url` is already a direct/debrid link; one with neither url nor
        // infoHash (YouTube / external) isn't ours to resolve. Branch out before any provider work.
        guard stream.url == nil, let hash = stream.infoHash?.lowercased(), !hash.isEmpty else { return nil }
        // No-key fast path: no network, zero behaviour change (only the at-most-once lazy warm hop). This is
        // the byte-identical guarantee.
        guard await hasAnyResolver else {
            DebridProbe.log("resolve", "infoHash=\(DebridProbe.h8(hash)) NO-KEY (no resolver configured) -> nil, embedded path")
            return nil
        }
        // CACHE-GATE (instant first-play, restores pre-511c973 snap): when the caller passed a confirmed-cached
        // set, only a pick whose infoHash is account-confirmed cached runs the blocking resolve (~1 round trip
        // to the instant direct link). A NOT-confirmed pick returns nil here with ZERO network, no createtorrent,
        // no pollByHash, no timeout burn, so the caller falls straight through to the pre-regression embedded
        // path (the row's own playableURL + prepareTorrent) and plays in a snap. nil set (the default) keeps the
        // pre-gate behaviour for `resolveFirstPlayable`'s already-cached-filtered legs and any unconditional caller.
        // [src-probe] CACHE-GATE decision: on CW resume this is the crux. A `gate=NOT-CONFIRMED` return means the
        // pick's infoHash was NOT in the account-confirmed cached set, so this returns nil with ZERO network and
        // the caller falls to the embedded/torrent path; if the confirmed set had not populated yet (cache-check
        // in flight), a genuinely-cached source is treated as uncached and skipped.
        if let confirmed = confirmedCachedHashes, !confirmed.contains(hash) {
            DebridProbe.log("resolve", "infoHash=\(DebridProbe.h8(hash)) gate=NOT-CONFIRMED (confirmedSet=\(confirmed.count) hashes) -> nil ZERO-NETWORK, caller uses embedded path")
            return nil
        }
        DebridProbe.log("resolve", "infoHash=\(DebridProbe.h8(hash)) gate=\(confirmedCachedHashes == nil ? "OPEN(no set)" : "CONFIRMED-CACHED") -> running blocking resolve (\(DebridProbe.ms(DebridCoordinator.resolveTimeout))ms budget)")

        // Build the magnet from the infohash (+ the add-on's `sources`, which carry trackers some providers
        // use to add the magnet); fileIdx biases the season-pack pick when present, the episode SxEy refines it.
        let trackers = (stream.sources ?? []).filter { $0.hasPrefix("tracker:") }.map { String($0.dropFirst("tracker:".count)) }
        let magnet = DebridResolve.magnet(forHash: hash, name: stream.behaviorHints?.filename, trackers: trackers)
        let fileIdx = stream.fileIdx   // hoist the value so the @Sendable task captures an Int?, not CoreStream

        // Bounded resolve: race the provider resolve against a timeout sleep; whichever finishes first wins and
        // the loser is cancelled. Any throw / timeout collapses to `nil` → the caller falls soft.
        let srcProbeStart = Date()
        let result = await withTaskGroup(of: DebridPlaybackRef?.self) { group in
            group.addTask {
                guard let (r, service) = try? await DebridCoordinator.shared.resolveWithIds(
                    infoHash: hash, magnet: magnet, fileIdx: fileIdx, episode: episode) else { return nil }
                return DebridPlaybackRef(url: r.url, service: service, infoHash: hash,
                                         torrentId: r.torrentId, fileId: r.fileId, fileIdx: fileIdx)
            }
            group.addTask {
                try? await Task.sleep(for: DebridCoordinator.resolveTimeout)
                return nil   // timeout sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // [src-probe] Blocking-resolve outcome. url=nil = the resolve threw (dead/evicted/uncached link) OR the
        // 5s timeout sentinel won the race (a stall). Either way the caller falls soft to the embedded path.
        DebridProbe.log("resolve", "infoHash=\(DebridProbe.h8(hash)) blocking-resolve RESULT -> \(result.map { "\($0.service) url ok" } ?? "nil (throw or 5s timeout)") elapsed=\(DebridProbe.since(srcProbeStart))ms")
        return result
    }

    /// PARALLEL cached-source race for the AUTO-PICK play path: resolve up to the top `max` CACHED
    /// candidates CONCURRENTLY and return the FIRST that produces a real link, cancelling the losers. This
    /// is what makes "Watch Now" reach a genuinely-cached source fast instead of the user tapping dead rows
    /// one by one: some candidates are truly cached (resolve in ~1 round trip) while others fail fast (the RD
    /// not-cached fast-fail, a missing file, an expired link), so a small group settles in ~2-4s on the
    /// winner rather than serially timing out the false-cached ones.
    ///
    /// Ordering IS the caller's ranking: `candidates` must arrive already StreamRanking-ordered (continuity /
    /// binge / pin preserved), and the first `max` that are resolvable-cached are raced. A candidate is
    /// resolvable-cached when it is a raw torrent whose lowercased infoHash is in `cachedHashes`, OR a usenet
    /// stream whose nzb link is in `cachedUsenetURLs` — i.e. the same account-confirmed sets the source list
    /// badges. A stream already carrying a direct `url` is skipped (nothing to resolve; the caller plays it
    /// directly). Anything not confirmed cached is left out so we never kick off an uncached add-then-download.
    ///
    /// Each leg reuses `resolvedPlaybackRef` verbatim, so every per-leg guarantee holds: the existing
    /// `DebridCoordinator.resolveTimeout` bound, the RealDebrid active-download fast-fail, the season-pack
    /// file pick, and the fail-soft nil. The whole group is therefore bounded by that same
    /// `resolveTimeout` per leg, and settles as soon as ONE leg wins.
    ///
    /// FAIL-SOFT: returns `nil` when nothing is confirmed-cached to race (e.g. no key, or no cached row) or
    /// when every raced leg fails — the caller then falls back to today's single-resolve / local-engine path,
    /// so behaviour with no debrid key is byte-identical (this returns `nil` before any `await`).
    ///
    /// - Parameters:
    ///   - candidates: streams in the caller's rank order (continuity/binge/pin already applied).
    ///   - episode: the SxEy target for a series season-pack pick. `nil` for movies.
    ///   - cachedHashes: lowercased infoHashes the user's debrid account confirmed cached (`DebridCacheAwareness`).
    ///   - cachedUsenetURLs: nzb links the user's TorBox usenet account confirmed cached (`DebridCacheAwareness`).
    ///   - max: concurrency cap (<= 4 enforced) so we never hammer the provider; the losers are cancelled.
    /// Returns the winning `ref` (URL + provider + reresolve ids, for the play-record) PAIRED with the source
    /// `stream` it resolved from, so the caller can wire the engine / headers / quality signature off the
    /// exact winning row (`DebridPlaybackRef` itself is a persisted value type and deliberately carries no
    /// `CoreStream`).
    /// - Parameter labeledBest: the exact stream the "Watch Now" label was composed from (`StreamRanking.best`),
    ///   so the race can keep its promise. When supplied AND the labeled best is itself confirmed-cached (so it
    ///   is guaranteed to resolve), the race REFUSES any winner of a lower resolution than the label: a faster
    ///   lower-quality leg can no longer silently override the promised quality (the device-verified "button
    ///   says 4K DV, plays 1080p" divergence). Such a race returns `nil`, so the caller single-resolves the
    ///   labeled best and the played quality matches the button. When the labeled best is NOT confirmed-cached
    ///   (a false add-on ⚡ this account does not hold, which would time out serially), the completion-order race
    ///   is kept as-is so the user still reaches a genuinely-cached source fast. `nil` (the default) preserves
    ///   the pre-cap completion-order behaviour for every non-Watch-Now caller.
    func resolveFirstPlayable(candidates: [CoreStream], episode: DebridEpisode? = nil,
                              cachedHashes: Set<String>, cachedUsenetURLs: Set<String> = [],
                              labeledBest: CoreStream? = nil,
                              max: Int = 4) async -> (ref: DebridPlaybackRef, stream: CoreStream)? {
        // No-key / nothing-to-race guarantee: with no resolver (or no confirmed-cached row) this returns nil
        // before any provider contact (only the at-most-once lazy warm hop), so the caller's fallback runs
        // its unchanged path. Evaluate both awaited flags first: `await` cannot live in `||`'s autoclosure,
        // and both are cheap (idempotent warm), so eager evaluation is fine.
        let hasTorrentResolver = await hasAnyResolver
        let hasUsenet = await hasUsenetResolver
        guard hasTorrentResolver || hasUsenet else { return nil }
        guard !cachedHashes.isEmpty || !cachedUsenetURLs.isEmpty else { return nil }

        // Keep only the confirmed-cached, resolvable candidates, in the caller's rank order. A raw torrent
        // (url == nil) qualifies when its infoHash is in cachedHashes; a usenet stream (url == nil, nzbUrl set)
        // qualifies when its nzb link is in cachedUsenetURLs. Everything else is dropped so we never start an
        // uncached add-then-download in the race.
        let cached = candidates.filter { s in
            guard s.url == nil else { return false }
            if let h = s.infoHash?.lowercased(), !h.isEmpty, cachedHashes.contains(h) { return true }
            if let nzb = s.nzbUrl, !nzb.isEmpty, cachedUsenetURLs.contains(nzb) { return true }
            return false
        }
        guard !cached.isEmpty else { return nil }

        // Bound concurrency to <= 4 (and >= 1) so a group never hammers the provider with more than a handful
        // of parallel resolves; the losers are cancelled the moment one wins.
        let cap = Swift.min(Swift.max(max, 1), 4)
        let racing = Array(cached.prefix(cap))

        // LABEL-AUTHORITATIVE GATE. The Watch-Now label is composed from `labeledBest`; the played source must
        // not be a LOWER resolution than that promise. We can only hold the promise when the labeled best is
        // itself guaranteed to resolve, i.e. it is confirmed-cached (a raw torrent whose hash is in
        // `cachedHashes`, a usenet nzb in `cachedUsenetURLs`, or a url-bearing direct/debrid row). In that case
        // we REFUSE any race winner whose resolution is below the label and let the caller single-resolve the
        // labeled best instead. When the labeled best is NOT confirmed-cached (a false add-on ⚡ that would time
        // out serially), we keep the completion-order race exactly as before so the user still reaches a real
        // cached source fast. With no `labeledBest` the gate is inert (accept anything).
        let bestRank = labeledBest.map(StreamRanking.resolutionRank)
        let bestConfirmedCached: Bool = {
            guard let best = labeledBest else { return false }
            if best.url != nil { return true }   // direct / debrid link resolves without an add-then-download
            if let h = best.infoHash?.lowercased(), !h.isEmpty, cachedHashes.contains(h) { return true }
            if let nzb = best.nzbUrl, !nzb.isEmpty, cachedUsenetURLs.contains(nzb) { return true }
            return false
        }()
        // A winner is acceptable unless the label is a confirmed-cached HIGHER resolution than it (which we can
        // and must deliver instead). Equal-or-higher-resolution winners always pass, so a same-tier faster leg
        // (e.g. two 4K sources) still wins the race.
        func acceptable(_ s: CoreStream) -> Bool {
            guard bestConfirmedCached, let br = bestRank else { return true }
            return StreamRanking.resolutionRank(s) >= br
        }

        // A single confirmed-cached candidate is just the existing single resolve (no group overhead). Still
        // honour the gate: a lone winner below a confirmed-cached label is refused so the caller resolves the
        // labeled best instead.
        if racing.count == 1 {
            guard acceptable(racing[0]) else { return nil }
            // Re-assert the confirmed-cached gate at resolve time: a candidate evicted between the cache check
            // and this call returns nil with ZERO network instead of starting an add-then-download.
            guard let ref = await resolvedPlaybackRef(for: racing[0], episode: episode,
                                                      confirmedCachedHashes: cachedHashes,
                                                      confirmedUsenetURLs: cachedUsenetURLs) else { return nil }
            return (ref, racing[0])
        }

        return await withTaskGroup(of: (ref: DebridPlaybackRef, stream: CoreStream)?.self) { group in
            for stream in racing {
                group.addTask {
                    // Each leg carries its own `DebridCoordinator.resolveTimeout` bound + RD fast-fail (it is a full resolvedPlaybackRef).
                    // Pass the confirmed-cached sets so a candidate evicted between the cache check and this
                    // leg returns nil with ZERO network rather than kicking off an add-then-download.
                    guard let ref = await DebridCoordinator.shared.resolvedPlaybackRef(for: stream, episode: episode,
                                                                                       confirmedCachedHashes: cachedHashes,
                                                                                       confirmedUsenetURLs: cachedUsenetURLs)
                    else { return nil }
                    return (ref, stream)
                }
            }
            // First leg to produce a real ref that PASSES the label-authoritative gate wins. A leg that
            // fails/fast-fails returns nil, and a leg that resolves but is a lower resolution than a
            // confirmed-cached label is skipped (not accepted as a silent lower-quality substitute); we keep
            // draining until an acceptable ref appears or every leg has reported. Then cancel the remaining
            // (in-flight) legs. When every resolved leg is below a confirmed-cached label the winner stays nil
            // and the caller single-resolves the labeled best, so the played quality matches the button.
            var winner: (ref: DebridPlaybackRef, stream: CoreStream)?
            for await result in group {
                if let result, acceptable(result.stream) { winner = result; break }
            }
            group.cancelAll()
            return winner
        }
    }
}

// MARK: - Detail-view cache awareness

/// Publishes the set of raw-torrent infoHashes a detail page's title has CACHED in the user's debrid
/// account, so the source list can badge + rank them up (`StreamRanking(debridCachedHashes:)`). It is a
/// per-view `@StateObject`: a detail view holds one, calls `refresh(from:)` once the title's stream
/// groups have loaded, and reads `cachedHashes` for the badge + ranking. With NO debrid key configured
/// `DebridCoordinator.cacheCheck` returns `[:]`, so `cachedHashes` stays empty and nothing changes.
///
/// Awareness only: this never resolves a direct link or touches the play path. It de-dups by the set of
/// hashes it last queried, so a re-render with the same torrents does not re-hit the provider.
@MainActor
final class DebridCacheAwareness: ObservableObject {
    /// Lowercased infoHashes confirmed cached. Empty until a check completes (and always, with no key).
    @Published private(set) var cachedHashes: Set<String> = []
    /// nzb links whose TorBox usenet download is confirmed cached, so a usenet row can show the ⚡. Keyed
    /// by the raw `nzbUrl` string (not its md5) so the row check is a plain set lookup. Empty until a
    /// usenet check completes and always with no TorBox key. Parallel to `cachedHashes` for torrents.
    @Published private(set) var cachedUsenetURLs: Set<String> = []

    /// The hash set most recently queried, so an identical set (same title, same torrents) is a no-op.
    private var lastQueried: Set<String> = []
    private var lastUsenetQueried: Set<String> = []
    private var task: Task<Void, Never>?
    private var usenetTask: Task<Void, Never>?

    /// Collect the RAW-torrent infoHashes in `groups` (a raw torrent is `url == nil`, `infoHash != nil`)
    /// and, if that set changed since the last query, ask the coordinator which are cached. Cheap and
    /// debounced: identical input returns immediately, and an empty input or no-key path clears nothing
    /// it didn't set. Safe to call on every `groups` change / `.task`. Also fires a parallel usenet check.
    func refresh(from groups: [CoreStreamSourceGroup]) {
        refreshUsenet(from: groups)
        var hashes: Set<String> = []
        for group in groups {
            for stream in group.streams where stream.url == nil {
                if let h = stream.infoHash?.lowercased(), !h.isEmpty { hashes.insert(h) }
            }
        }
        guard !hashes.isEmpty else { return }          // nothing to check; leave any prior result intact
        guard hashes != lastQueried else { return }    // same torrents already queried: no re-hit
        task?.cancel()
        task = Task { [weak self] in
            let result = await DebridCoordinator.shared.cacheCheck(hashes: Array(hashes))
            guard !Task.isCancelled, let self else { return }
            // Commit the queried set ONLY after a real result, so a failed/cancelled check leaves
            // lastQueried untouched and the next refresh re-hits the provider instead of being deduped away.
            self.lastQueried = hashes
            // result keys are already lowercased infoHashes (see TorBoxResolver.checkCache).
            self.cachedHashes = Set(result.keys)
        }
    }

    /// The usenet twin of the torrent cache check: collect the usenet nzb links in `groups`, key each by
    /// its NZB md5, and ask TorBox which are cached, mapping the cached md5s back to their nzb urls. The
    /// key is the stream's authoritative `usenethash:` marker when its emitter carried one (TorBox search
    /// results do); md5-of-the-link is the fallback for plain add-on usenet streams. No-op (leaves state
    /// intact) with no usenet stream present or no TorBox key. Debounced by the nzb-url set.
    private func refreshUsenet(from groups: [CoreStreamSourceGroup]) {
        var byMD5: [String: String] = [:]   // md5 -> nzbUrl, so a cached md5 maps back to the row's raw link
        for group in groups {
            for stream in group.streams where stream.isUsenet {
                guard let nzb = stream.nzbUrl, !nzb.isEmpty else { continue }
                byMD5[stream.usenetKnownHash ?? TorBoxUsenetResolver.identifier(forNzbURL: nzb)] = nzb
            }
        }
        guard !byMD5.isEmpty else { return }
        let urls = Set(byMD5.values)
        guard urls != lastUsenetQueried else { return }
        usenetTask?.cancel()
        usenetTask = Task { [weak self] in
            let cachedMD5s = await DebridCoordinator.shared.usenetCacheCheck(nzbMD5s: Array(byMD5.keys))
            guard !Task.isCancelled, let self else { return }
            self.lastUsenetQueried = urls
            self.cachedUsenetURLs = Set(cachedMD5s.compactMap { byMD5[$0] })
        }
    }
}

// MARK: - Browsable cloud library (list + resolve, per provider)
//
// Each provider lists what is ALREADY in the user's account and resolves a chosen item to a direct URL,
// reusing that provider's existing private HTTP + decode helpers (same-file extensions can touch them).
// A short throwaway `DebridFile` reuses `DebridResolve.pickFile` (largest-video heuristic) so the same
// file-pick logic that powers streaming also picks the playable file inside a browsed torrent.

extension TorBoxResolver {
    /// A `/torrents/mylist` row, richer than the resolve-path `Item` (adds name / size / created_at).
    private struct LibraryRow: Decodable {
        let id: Int
        let name: String?
        let size: Int64?
        let createdAt: String?
        let downloadFinished: Bool?
        let downloadPresent: Bool?
        let downloadState: String?
        let files: [Cached.File]?
        enum CodingKeys: String, CodingKey {
            case id, name, size, files
            case createdAt = "created_at"
            case downloadFinished = "download_finished", downloadPresent = "download_present"
            case downloadState = "download_state"
        }
        var ready: Bool {
            (downloadFinished == true && downloadPresent == true)
                || downloadState == "cached" || downloadState == "completed"
        }
    }

    func listCloudLibrary() async throws -> [DebridLibraryItem] {
        guard let url = URL(string: "\(Self.base)/mylist?bypass_cache=true") else { return [] }
        let env: Envelope<[LibraryRow]> = try await get(url)
        return (env.data ?? []).compactMap { row -> DebridLibraryItem? in
            guard row.ready else { return nil }
            let files = (row.files ?? []).map(file(from:))
            // Pick the file that would stream (largest video; no episode target for a bare library browse).
            guard let pick = DebridResolve.pickFile(files, episode: nil, fileIdx: nil) else { return nil }
            let name = (row.name?.isEmpty == false) ? row.name! : pick.shortName
            return DebridLibraryItem(
                id: "\(service.rawValue):\(row.id)",
                service: service,
                name: name.isEmpty ? "Untitled" : name,
                size: row.size ?? files.reduce(Int64(0)) { $0 + $1.size },
                added: DebridDate.parse(iso: row.createdAt),
                providerId: String(row.id),
                fileId: pick.id,
                restrictedLink: nil,
                directLink: nil)
        }
    }

    func resolveLibraryItem(_ item: DebridLibraryItem) async throws -> URL {
        guard let tid = Int(item.providerId) else { throw DebridError.providerError("bad torrent id") }
        if let fid = item.fileId {
            return try await requestDL(torrentId: tid, fileId: fid)
        }
        // No stored file id (defensive): fetch the item and pick the largest video before minting the link.
        guard let row = try await fetchItem(id: tid) else { throw DebridError.notCached }
        let files = (row.files ?? []).map(file(from:))
        guard let pick = DebridResolve.pickFile(files, episode: nil, fileIdx: nil) else { throw DebridError.noMatchingFile }
        return try await requestDL(torrentId: tid, fileId: pick.id)
    }
}

extension RealDebridResolver {
    /// A `/torrents` list row (the account's torrent cloud). `status == "downloaded"` == finished + playable.
    private struct TorrentRow: Decodable {
        let id: String
        let filename: String?
        let bytes: Int64?
        let status: String?
        let added: String?
    }

    func listCloudLibrary() async throws -> [DebridLibraryItem] {
        let rows: [TorrentRow] = try await get("\(Self.base)/torrents?limit=200")
        return rows.compactMap { r -> DebridLibraryItem? in
            guard (r.status ?? "") == "downloaded" else { return nil }
            return DebridLibraryItem(
                id: "\(service.rawValue):\(r.id)",
                service: service,
                name: (r.filename?.isEmpty == false) ? r.filename! : "Untitled",
                size: r.bytes ?? 0,
                added: DebridDate.parse(iso: r.added),
                providerId: r.id,
                fileId: nil,
                restrictedLink: nil,
                directLink: nil)
        }
    }

    func resolveLibraryItem(_ item: DebridLibraryItem) async throws -> URL {
        // `/torrents/info/{id}`: `links` align 1:1 with the SELECTED files, in file order, so pick the
        // largest video among the selected files and unrestrict its aligned link.
        let info: Info = try await get("\(Self.base)/torrents/info/\(item.providerId)")
        guard let links = info.links, !links.isEmpty else { throw DebridError.notReady }
        let selected = (info.files ?? []).filter { $0.selected == 1 }
        let dfiles = selected.enumerated().map { idx, f -> DebridFile in
            DebridFile(id: idx, name: f.path, shortName: (f.path as NSString).lastPathComponent, size: f.bytes, mimetype: nil)
        }
        guard let pick = DebridResolve.pickFile(dfiles, episode: nil, fileIdx: nil), links.indices.contains(pick.id) else {
            throw DebridError.noMatchingFile
        }
        let un: Unrestrict = try await form("\(Self.base)/unrestrict/link", ["link": links[pick.id]])
        guard let u = URL(string: un.download) else { throw DebridError.providerError("no download url") }
        return u
    }
}

extension AllDebridResolver {
    /// The list form of `/magnet/status`: `magnets` is an ARRAY (the id-specific call returns one object).
    private struct StatusListEnv: Decodable {
        let status: String
        let data: D?
        struct D: Decodable {
            let magnets: [Magnet]?
            struct Magnet: Decodable {
                let id: Int?
                let filename: String?
                let size: Int64?
                let statusCode: Int?
                let uploadDate: Int?
                let links: [L]?
                struct L: Decodable { let link: String; let filename: String?; let size: Int64? }
            }
        }
    }

    func listCloudLibrary() async throws -> [DebridLibraryItem] {
        let env: StatusListEnv = try await get(authed("/magnet/status", []))
        guard env.status == "success" else { return [] }
        return (env.data?.magnets ?? []).compactMap { m -> DebridLibraryItem? in
            guard m.statusCode == 4 else { return nil }   // 4 = Ready
            let links = m.links ?? []
            let dfiles = links.enumerated().map { idx, l -> DebridFile in
                let n = l.filename ?? ""
                return DebridFile(id: idx, name: n, shortName: (n as NSString).lastPathComponent, size: l.size ?? 0, mimetype: nil)
            }
            guard let pick = DebridResolve.pickFile(dfiles, episode: nil, fileIdx: nil), links.indices.contains(pick.id) else { return nil }
            let name = (m.filename?.isEmpty == false) ? m.filename!
                : (pick.shortName.isEmpty ? "Untitled" : pick.shortName)
            return DebridLibraryItem(
                id: "\(service.rawValue):\(m.id ?? 0)",
                service: service,
                name: name,
                size: m.size ?? links.reduce(Int64(0)) { $0 + ($1.size ?? 0) },
                added: m.uploadDate.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                providerId: String(m.id ?? 0),
                fileId: nil,
                restrictedLink: links[pick.id].link,
                directLink: nil)
        }
    }

    func resolveLibraryItem(_ item: DebridLibraryItem) async throws -> URL {
        guard let restricted = item.restrictedLink else { throw DebridError.noMatchingFile }
        let un: Env<UnlockData> = try await get(authed("/link/unlock", [URLQueryItem(name: "link", value: restricted)]))
        guard let s = un.data?.link, let u = URL(string: s) else { throw DebridError.providerError("unlock") }
        return u
    }
}

extension PremiumizeResolver {
    /// `/folder/list` (root): the cloud files, each already carrying a direct `stream_link` / `link`.
    private struct FolderList: Decodable {
        let status: String
        let content: [Entry]?
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let type: String?
            let size: Int64?
            let createdAt: Int?
            let link: String?
            let streamLink: String?
            enum CodingKeys: String, CodingKey {
                case id, name, type, size, link
                case createdAt = "created_at"
                case streamLink = "stream_link"
            }
        }
    }

    func listCloudLibrary() async throws -> [DebridLibraryItem] {
        let list: FolderList = try await getFolderList("/folder/list")
        guard list.status == "success" else { return [] }
        return (list.content ?? []).compactMap { e -> DebridLibraryItem? in
            guard (e.type ?? "") == "file" else { return nil }   // skip subfolders (root browse only)
            guard let direct = e.streamLink ?? e.link, !direct.isEmpty else { return nil }
            let name = (e.name?.isEmpty == false) ? e.name! : "Untitled"
            // Video files only: reuse DebridFile.isVideo (extension / mimetype heuristic).
            let looksVideo = DebridFile(id: 0, name: name, shortName: (name as NSString).lastPathComponent,
                                        size: 0, mimetype: nil).isVideo
            guard looksVideo || e.streamLink != nil else { return nil }
            return DebridLibraryItem(
                id: "\(service.rawValue):\(e.id ?? direct)",
                service: service,
                name: name,
                size: e.size ?? 0,
                added: e.createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                providerId: e.id ?? "",
                fileId: nil,
                restrictedLink: nil,
                directLink: direct)
        }
    }

    func resolveLibraryItem(_ item: DebridLibraryItem) async throws -> URL {
        guard let s = item.directLink, let u = URL(string: s) else { throw DebridError.providerError("no link") }
        return u   // Premiumize folder files are already direct: no extra unrestrict round trip.
    }

    /// GET with the apikey query (folder/list is a GET), reusing the shared decode contract.
    private func getFolderList<T: Decodable>(_ path: String) async throws -> T {
        var c = URLComponents(string: Self.base + path)
        c?.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        return try await DebridHTTP.decode(session, URLRequest(url: c?.url ?? URL(string: Self.base)!))
    }
}

// MARK: - Coordinator: cloud library aggregate

extension DebridCoordinator {
    /// Every configured provider's cloud library, keyed by service, queried CONCURRENTLY (the resolvers are
    /// actors). FAIL-SOFT: with no key the map is empty; a provider that errors or is empty simply does not
    /// appear (its `try?` collapses to no entry), so the browse UI hides that section rather than erroring.
    func cloudLibrary() async -> [DebridService: [DebridLibraryItem]] {
        await warmIfNeeded()
        guard !resolvers.isEmpty else { return [:] }
        return await withTaskGroup(of: (DebridService, [DebridLibraryItem]).self) { group in
            for (service, resolver) in resolvers {
                group.addTask { (service, (try? await resolver.listCloudLibrary()) ?? []) }
            }
            var out: [DebridService: [DebridLibraryItem]] = [:]
            for await (service, items) in group where !items.isEmpty { out[service] = items }
            return out
        }
    }

    /// Resolve a chosen library item to a direct, streamable URL through its own provider's resolver.
    /// Throws `.noKey` when that provider is no longer configured; other `DebridError`s when the file is gone.
    func resolveLibraryItem(_ item: DebridLibraryItem) async throws -> URL {
        await warmIfNeeded()
        guard let resolver = resolvers[item.service] else { throw DebridError.noKey }
        return try await resolver.resolveLibraryItem(item)
    }
}
