import Foundation
import CryptoKit

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
        guard let episode else { return videos.max(by: { $0.size < $1.size }) }
        let scored = videos.compactMap { f -> (DebridFile, Int)? in
            let s = episodeMatchScore(filename: f.shortName.isEmpty ? f.name : f.shortName,
                                      season: episode.season, episode: episode.episode)
            return s > 0 ? (f, s) : nil
        }
        if let best = scored.max(by: { $0.1 < $1.1 })?.0 { return best }
        return videos.max(by: { $0.size < $1.size })   // pack fallback: biggest video
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
            guard let url = URL(string: "\(Self.base)/checkcached?hash=\(joined)&format=list&list_files=true") else { continue }
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
        guard let id = torrentId else { throw DebridError.notReady }
        guard let pick = DebridResolve.pickFile(files, episode: episode, fileIdx: fileIdx) else {
            throw DebridError.noMatchingFile
        }

        // 3. Request the direct stream URL.
        let url = try await requestDL(torrentId: id, fileId: pick.id)
        return (url, id, pick.id)
    }

    /// Regenerate a fresh link from the stored ids. When `torrentId`+`fileId` are present, this is a single
    /// `requestdl` (no add step) — the fast path a debrid resume wants. If TorBox 404s the file (evicted),
    /// fall back to a full re-add via the default resolve. Nil ids also fall back.
    func reresolveLink(infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?) async throws -> URL {
        if let tid = torrentId, let fid = fileId {
            // Any provider-side failure on this fast path (evicted file -> .notCached, non-2xx -> .providerError,
            // a transient 401/403 during a key refresh -> .invalidKey, or a not-yet-ready blip -> .notReady) is
            // recoverable by the full re-add below, so fall through on all of them rather than aborting.
            do { return try await requestDL(torrentId: tid, fileId: fid) }
            catch DebridError.notCached { /* fall through to re-add */ }
            catch DebridError.providerError { /* file/torrent likely evicted: re-add below */ }
            catch DebridError.invalidKey { /* transient auth blip: re-add below */ }
            catch DebridError.notReady { /* not ready yet on the fast path: re-add below */ }
        }
        let magnet = DebridResolve.magnet(forHash: infoHash)
        return try await resolve(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: nil)
    }

    /// The `requestdl` leg: mint a direct stream URL for a known torrent_id+file_id. A missing file surfaces
    /// as `.notCached` (a 404/"not found" from TorBox) so the caller can re-add.
    private func requestDL(torrentId: Int, fileId: Int) async throws -> URL {
        guard let url = URL(string: "\(Self.base)/requestdl?token=\(apiKey)&torrent_id=\(torrentId)&file_id=\(fileId)&redirect=false") else {
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

    /// Poll the library by infohash until the torrent is ready (cached should be ~1 poll). Streaming
    /// timeout ~30s; uncached downloads surface as `.notReady` for the caller to fall back to the engine.
    private func pollByHash(_ hash: String, into torrentId: inout Int?) async throws -> [DebridFile] {
        for attempt in 0..<10 {
            try Task.checkCancellation()   // a losing leg of the parallel cached-race (or the 15s bound) cancels the group: stop polling promptly, don't keep hitting the provider
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }   // 3s between polls
            guard let url = URL(string: "\(Self.base)/mylist?bypass_cache=true") else { break }
            let env: Envelope<[Item]> = try await get(url)
            // Match the torrent for THIS hash (newly added or promoted from the queue); ready when cached/
            // completed with files present.
            if let mine = (env.data ?? []).first(where: { $0.hash?.lowercased() == hash && $0.ready && !($0.files ?? []).isEmpty }) {
                torrentId = mine.id
                return (mine.files ?? []).map(file(from:))
            }
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
            guard let url = URL(string: "\(Self.base)/checkcached?hash=\(joined)&format=list&list_files=true") else { continue }
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
        guard let url = URL(string: "\(Self.base)/requestdl?token=\(apiKey)&usenet_id=\(usenetId)&file_id=\(fileId)&redirect=false") else {
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
                throw DebridError.notReady
            }
        }
        guard let link else { throw DebridError.notReady }
        let un: Unrestrict = try await form("\(Self.base)/unrestrict/link", ["link": link])
        guard let u = URL(string: un.download) else { throw DebridError.providerError("no download url") }
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

    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] { [:] }

    private struct Env<T: Decodable>: Decodable { let status: String; let data: T? }
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

    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] { [:] }

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
@MainActor
final class DebridCoordinator {
    static let shared = DebridCoordinator()

    private var resolvers: [DebridService: any DebridResolving] = [:]
    /// The TorBox usenet resolver, built only when a TorBox key is configured (usenet is a TorBox-only
    /// backend among the four services). Separate from `resolvers` because usenet resolves off an nzb link,
    /// not the infohash/magnet the `DebridResolving` protocol takes. nil = no TorBox key = usenet inert.
    private var torboxUsenet: TorBoxUsenetResolver?

    /// (Re)build resolvers from the current keys. Call after a key changes.
    func reload(from keys: DebridKeys = .shared) {
        resolvers.removeAll()
        torboxUsenet = nil
        if keys.isConfigured(.torBox) {
            resolvers[.torBox] = TorBoxResolver(apiKey: keys.key(for: .torBox))
            torboxUsenet = TorBoxUsenetResolver(apiKey: keys.key(for: .torBox))
        }
        if keys.isConfigured(.realDebrid) { resolvers[.realDebrid] = RealDebridResolver(apiKey: keys.key(for: .realDebrid)) }
        if keys.isConfigured(.allDebrid) { resolvers[.allDebrid] = AllDebridResolver(apiKey: keys.key(for: .allDebrid)) }
        if keys.isConfigured(.premiumize) { resolvers[.premiumize] = PremiumizeResolver(apiKey: keys.key(for: .premiumize)) }
    }

    /// True when a usenet resolve is possible (a TorBox key is configured). Gates both the usenet play
    /// path and the usenet cache-check; with no TorBox key everything usenet behaves exactly as before.
    var hasUsenetResolver: Bool {
        if resolvers.isEmpty { reload() }
        return torboxUsenet != nil
    }

    var hasAnyResolver: Bool {
        if resolvers.isEmpty { reload() }
        return !resolvers.isEmpty
    }

    /// Which provider has each hash cached (first configured provider that reports it), with the files.
    /// Queries every configured provider CONCURRENTLY (resolvers are actors, so the captures are Sendable),
    /// then merges in a deterministic `DebridService.allCases` priority order so the chosen provider for a
    /// hash is stable. Previously this looped providers sequentially AND in nondeterministic dict order.
    func cacheCheck(hashes: [String]) async -> [String: (service: DebridService, files: [DebridFile])] {
        if resolvers.isEmpty { reload() }
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
        if resolvers.isEmpty { reload() }
        let resolver = pick(service)
        guard let resolver else { throw DebridError.noKey }
        return try await resolver.resolve(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: episode)
    }

    /// Resolve, surfacing the provider + ids (for a later `reresolve`). Chooses the given service or the
    /// first configured resolver (the same choice `resolve` makes).
    func resolveWithIds(service: DebridService? = nil, infoHash: String, magnet: String,
                        fileIdx: Int?, episode: DebridEpisode?)
        async throws -> (result: (url: URL, torrentId: Int?, fileId: Int?), service: DebridService) {
        if resolvers.isEmpty { reload() }
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
        if resolvers.isEmpty { reload() }
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
        if resolvers.isEmpty { reload() }
        guard let usenet = torboxUsenet else { throw DebridError.noKey }
        return try await usenet.resolve(nzbUrl: nzbUrl, knownHash: knownHash, fileMustInclude: fileMustInclude, fileIdx: fileIdx, episode: episode)
    }

    /// Which nzb md5s the user's TorBox usenet account has cached (drives the ⚡ on usenet rows). Empty (a
    /// no-op) when no TorBox key is configured. Keys are the lowercased md5 identifiers, matching
    /// `TorBoxUsenetResolver.identifier(forNzbURL:)`.
    func usenetCacheCheck(nzbMD5s: [String]) async -> Set<String> {
        if resolvers.isEmpty { reload() }
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
    /// Streaming-settle ceiling for an in-line resolve, matched to the source-list settle window: a CACHED
    /// torrent resolves in ~1 round trip, so 15s comfortably covers it while bounding a stall (an uncached
    /// add-then-poll, a flaky provider, a hung network) so the play action never hangs the UI. On timeout the
    /// resolve Task is cancelled and the caller falls soft to the local engine.
    private static let resolveTimeout: Duration = .seconds(15)

    /// The single bridge from a tapped/auto-picked RAW TORRENT to a debrid DIRECT link for playback.
    ///
    /// Returns a remote HTTPS URL the player can open as a plain direct stream (NOT a torrent — it does not
    /// match the `{server}:11470/{40-hex}/{idx}` shape the player keys torrent behaviour off, so it gets no
    /// `/create`, no warm-up, and no `closeTorrent` teardown), or `nil` when the caller should use today's
    /// path unchanged. It is FAIL-SOFT by construction: every non-success (no key, not a raw torrent, any
    /// `DebridError`, a throw, or the timeout) returns `nil`, so the user is never left unable to play.
    ///
    /// NO-KEY BYTE-IDENTICAL GUARANTEE: with no resolver configured (`hasAnyResolver == false`) this returns
    /// `nil` on the very first line with ZERO `await` and zero provider contact, so the caller runs exactly
    /// the code it ran before this feature existed. The same immediate `nil` applies to any non-raw-torrent
    /// stream (direct URL, YouTube, externalUrl), so direct/trailer playback is also untouched.
    ///
    /// - Parameters:
    ///   - stream: the stream the user is about to play.
    ///   - episode: the SxEy target for a series, so a season-pack resolves the right file. `nil` for movies.
    func resolvedPlaybackURL(for stream: CoreStream, episode: DebridEpisode? = nil) async -> URL? {
        await resolvedPlaybackRef(for: stream, episode: episode)?.url
    }

    /// The same bounded, fail-soft resolve as `resolvedPlaybackURL`, but returning the full
    /// `DebridPlaybackRef` (URL + provider + reresolve ids) so the play-record can persist enough to
    /// later refresh an expired link. `resolvedPlaybackURL` is a thin `?.url` wrapper over this, so every
    /// guarantee (raw-torrent-only, no-key zero-await nil, timeout → nil) is identical.
    func resolvedPlaybackRef(for stream: CoreStream, episode: DebridEpisode? = nil) async -> DebridPlaybackRef? {
        // USENET first: a stream with an `.nzb` link (and no direct `url`) resolves through the TorBox
        // usenet backend, gated on a TorBox key. With no TorBox key `hasUsenetResolver` is false, so this
        // returns nil on the first line (zero await) — a usenet row then behaves exactly as today (no
        // playable link). NOT a torrent: the minted URL is a plain direct stream (no infoHash carried).
        if stream.url == nil, let nzb = stream.nzbUrl, !nzb.isEmpty {
            guard hasUsenetResolver else { return nil }
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
        // No-key fast path: zero await, zero behaviour change. This is the byte-identical guarantee.
        guard hasAnyResolver else { return nil }

        // Build the magnet from the infohash (+ the add-on's `sources`, which carry trackers some providers
        // use to add the magnet); fileIdx biases the season-pack pick when present, the episode SxEy refines it.
        let trackers = (stream.sources ?? []).filter { $0.hasPrefix("tracker:") }.map { String($0.dropFirst("tracker:".count)) }
        let magnet = DebridResolve.magnet(forHash: hash, name: stream.behaviorHints?.filename, trackers: trackers)
        let fileIdx = stream.fileIdx   // hoist the value so the @Sendable task captures an Int?, not CoreStream

        // Bounded resolve: race the provider resolve against a timeout sleep; whichever finishes first wins and
        // the loser is cancelled. Any throw / timeout collapses to `nil` → the caller falls soft.
        return await withTaskGroup(of: DebridPlaybackRef?.self) { group in
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
    /// Each leg reuses `resolvedPlaybackRef` verbatim, so every per-leg guarantee holds: the existing 15s
    /// bound, the RealDebrid active-download fast-fail, the season-pack file pick, and the fail-soft nil. The
    /// whole group is therefore bounded by that same 15s per leg, and settles as soon as ONE leg wins.
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
    func resolveFirstPlayable(candidates: [CoreStream], episode: DebridEpisode? = nil,
                              cachedHashes: Set<String>, cachedUsenetURLs: Set<String> = [],
                              max: Int = 4) async -> (ref: DebridPlaybackRef, stream: CoreStream)? {
        // Zero-await no-key / nothing-to-race guarantee: with no resolver (or no confirmed-cached row) this
        // returns nil before any provider contact, so the caller's fallback runs its unchanged path.
        guard hasAnyResolver || hasUsenetResolver else { return nil }
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
        // A single confirmed-cached candidate is just the existing single resolve (no group overhead).
        if racing.count == 1 {
            guard let ref = await resolvedPlaybackRef(for: racing[0], episode: episode) else { return nil }
            return (ref, racing[0])
        }

        return await withTaskGroup(of: (ref: DebridPlaybackRef, stream: CoreStream)?.self) { group in
            for stream in racing {
                group.addTask {
                    // Each leg carries its own 15s bound + RD fast-fail (it is a full resolvedPlaybackRef).
                    guard let ref = await DebridCoordinator.shared.resolvedPlaybackRef(for: stream, episode: episode)
                    else { return nil }
                    return (ref, stream)
                }
            }
            // First leg to produce a real ref WINS. A leg that fails/fast-fails returns nil; keep draining
            // until a non-nil ref appears or every leg has reported. Then cancel the remaining (in-flight)
            // legs so we stop hitting the provider the instant we have a playable link.
            var winner: (ref: DebridPlaybackRef, stream: CoreStream)?
            for await result in group {
                if let result { winner = result; break }
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
