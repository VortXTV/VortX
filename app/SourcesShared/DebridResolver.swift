import Foundation

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

// MARK: - Protocol

/// A single debrid provider's resolver. Actor-isolated: each owns its own URLSession and serial work.
protocol DebridResolving: Actor {
    var service: DebridService { get }

    /// Batch cache-availability. Returns hash -> files for the hashes that are cached (absent / empty = not).
    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]]

    /// Resolve a torrent to a direct streamable URL: add the magnet (idempotent), wait until ready
    /// (near-instant for cached), pick the episode/movie file, and return its stream URL.
    func resolve(infoHash: String, magnet: String, fileIdx: Int?, episode: DebridEpisode?) async throws -> URL
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
        guard let url = URL(string: "\(Self.base)/requestdl?token=\(apiKey)&torrent_id=\(id)&file_id=\(pick.id)&redirect=false") else {
            throw DebridError.providerError("bad requestdl url")
        }
        let link: Envelope<String> = try await get(url)
        guard let s = link.data, let u = URL(string: s) else { throw DebridError.providerError("no stream url") }
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
        // Poll until downloaded, selecting all files the FIRST time RD asks (it won't cache until selection).
        var info: Info?
        var didSelect = false
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            let i: Info = try await get("\(Self.base)/torrents/info/\(id)")
            if i.status == "downloaded" { info = i; break }
            if ["magnet_error", "error", "virus", "dead"].contains(i.status) {
                throw DebridError.providerError("status \(i.status)")
            }
            if i.status == "waiting_files_selection", !didSelect {
                didSelect = true
                // Select once and PROPAGATE failure: a 401 here surfaces as invalidKey, not a misleading
                // notReady after the full timeout, and it never re-fires every poll.
                try await formVoid("\(Self.base)/torrents/selectFiles/\(id)", ["files": "all"])
            }
        }
        guard let info, let links = info.links, !links.isEmpty else { throw DebridError.notReady }
        // RD's `links` are parallel to the SELECTED files in order, so DebridFile.id is the selected index
        // and `links[pick.id]` is the matching restricted link to unrestrict.
        let selected = (info.files ?? []).filter { $0.selected == 1 }
        let dfiles = selected.enumerated().map { idx, f -> DebridFile in
            DebridFile(id: idx, name: f.path, shortName: (f.path as NSString).lastPathComponent, size: f.bytes, mimetype: nil)
        }
        // The stream's `fileIdx` is a TORRENT-WIDE index, but `dfiles`/`links` here are RD's selected-file
        // list, so a torrent-wide index would mis-map to the wrong file. Pick by the episode/size heuristic on
        // RD's own filenames instead (reliable), which keeps `links[pick.id]` aligned (pick.id = selected index).
        guard let pick = DebridResolve.pickFile(dfiles, episode: episode, fileIdx: nil),
              links.indices.contains(pick.id) else { throw DebridError.noMatchingFile }
        let un: Unrestrict = try await form("\(Self.base)/unrestrict/link", ["link": links[pick.id]])
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

    /// (Re)build resolvers from the current keys. Call after a key changes.
    func reload(from keys: DebridKeys = .shared) {
        resolvers.removeAll()
        if keys.isConfigured(.torBox) { resolvers[.torBox] = TorBoxResolver(apiKey: keys.key(for: .torBox)) }
        if keys.isConfigured(.realDebrid) { resolvers[.realDebrid] = RealDebridResolver(apiKey: keys.key(for: .realDebrid)) }
        if keys.isConfigured(.allDebrid) { resolvers[.allDebrid] = AllDebridResolver(apiKey: keys.key(for: .allDebrid)) }
        if keys.isConfigured(.premiumize) { resolvers[.premiumize] = PremiumizeResolver(apiKey: keys.key(for: .premiumize)) }
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
        let resolver: (any DebridResolving)?
        if let service { resolver = resolvers[service] } else { resolver = resolvers.values.first }
        guard let resolver else { throw DebridError.noKey }
        return try await resolver.resolve(infoHash: infoHash, magnet: magnet, fileIdx: fileIdx, episode: episode)
    }
}
