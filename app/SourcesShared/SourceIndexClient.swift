import Foundation
import CryptoKit

/// Client for VortX's community SOURCE INDEX at `sources.vortx.tv` ("Singularity"): the pooled record of which
/// SOURCES (torrent / usenet / direct) exist for a title, corroborated across users.
///
/// TWO halves, both 100% fail-soft (any miss / error / offline is a silent no-op; nothing ever blocks or slows
/// playback or a screen):
///
///   1. HOARD (default ON, anonymous): whenever the app assembles a title's stream results from its add-ons /
///      debrid / usenet / torrent sources, it reports the source DESCRIPTORS -- NOT the media, NOT the user's
///      personal debrid-unlocked link, NOT any account token or user id. A descriptor is only
///      { kind, id, quality, sizeBytes, sourceTag, seeders? } where `id` is a stable public identity of the
///      source (a torrent infohash, a usenet nzb id, or sha256(url) for a direct link -- never the raw url).
///      Fire-and-forget, batched into one POST, deduped by descriptor id.
///
///   2. SERVE (opt-in): when the user turns the Singularity toggle ON AND is signed in, the detail / stream
///      screen reads the corroborated pooled sources for the title and MERGES the actionable ones (torrent
///      infohash + usenet nzb) into the stream list, labeled as community sources. Direct-link entries are
///      keyed by sha256(url) with no recoverable url, so they cannot be reconstructed and are dropped. Empty
///      on any miss; signed-out disables the read entirely (hard login gate, matching the worker).
///
/// GIVE-TO-GET: every method is additionally gated on `MoatConsent.contributeAndConsume`. If the user has
/// opted out of the anonymized-data pool, this client neither contributes nor consumes.
///
/// GATING (VortX-only): `sources.vortx.tv` is in `VortXEdgeAuth.gatedHosts`, so BOTH the POST and the GET are
/// HMAC-signed. Signing is a safe no-op without a provisioned secret (the worker's observe mode allows it).
enum SourceIndexClient {

    // MARK: - Public models

    /// A source kind as the pool records it. Mirrors the app's own torrent / usenet / direct classification.
    enum Kind: String { case torrent, usenet, direct }

    /// One anonymized source descriptor for the HOARD upload. Carries ONLY public, non-personal fields.
    struct Descriptor: Encodable {
        let kind: String
        let id: String            // infohash (torrent) | nzb id (usenet) | sha256(url) (direct)
        let quality: String       // e.g. "4K", "1080p", "Other" (from StreamRanking.qualityLabel)
        let sizeBytes: Int64      // 0 when the add-on advertised no size
        let sourceTag: String     // the add-on / provider label the source came from (no user data)
        let seeders: Int?         // torrents only, when advertised
    }

    /// One corroborated source the pool returns for SERVE. `id` matches the descriptor id space.
    struct PooledSource: Decodable {
        let kind: String?
        let id: String?
        let quality: String?
        let sizeBytes: Int64?
        let sourceTag: String?
        let seeders: Int?
        let corroboration: Int?   // number of distinct witnesses; the worker only returns >= its quarantine floor
    }

    // MARK: - Content id (colon form: imdb[:season:episode])

    /// The pool `content_id` for a title, in the worker's colon form (`tt0903747` for a movie, `tt…:S:E` for an
    /// episode). nil when the id is not a real imdb `tt…` id (ad-hoc paste-a-link plays have no shareable id).
    static func contentID(imdbId: String?, season: Int? = nil, episode: Int? = nil) -> String? {
        guard let imdbId, imdbId.range(of: #"^tt\d{6,}$"#, options: .regularExpression) != nil else { return nil }
        if let season, let episode { return "\(imdbId):\(season):\(episode)" }
        return imdbId
    }

    // MARK: - Descriptor extraction (pure; no user data)

    /// Build the anonymized descriptor set for a title's assembled source groups. Uses `StreamRanking` as the
    /// single source of truth for quality / size / seeders / classification, so the pool's view matches the
    /// app's. Skips YouTube trailers and any stream with no derivable public id. Deduped by descriptor id.
    ///
    /// PRIVACY: the debrid-resolved `url` of a torrent that a service already unlocked is a PERSONAL link, so it
    /// is never sent. A torrent/usenet source is keyed by its infohash / nzb id; a plain direct link is keyed by
    /// sha256(url) (one-way), never the url itself. No account token, user id, or filename is included.
    static func descriptors(from groups: [CoreStreamSourceGroup]) -> [Descriptor] {
        var seen = Set<String>()
        var out: [Descriptor] = []
        for group in groups {
            for stream in group.streams where !stream.isYouTubeTrailer {
                guard let d = descriptor(for: stream, sourceTag: group.addon) else { continue }
                guard seen.insert(d.kind + "|" + d.id).inserted else { continue }
                out.append(d)
            }
        }
        return out
    }

    /// One descriptor for one stream, or nil when it carries no public identity.
    private static func descriptor(for stream: CoreStream, sourceTag: String) -> Descriptor? {
        let sizeGB = StreamRanking.sizeForSort(stream)               // GB (0 when unknown)
        let sizeBytes = sizeGB > 0 ? Int64((sizeGB * 1024 * 1024 * 1024).rounded()) : 0
        let quality = StreamRanking.qualityLabel(stream)
        let tag = sanitizeTag(sourceTag)

        // USENET: keyed by a stable id derived from the nzb LINK (hashed, never the raw link, which may embed a
        // user-specific token). Kind = usenet.
        if stream.isUsenet, let nzb = stream.nzbUrl, !nzb.isEmpty {
            return Descriptor(kind: Kind.usenet.rawValue, id: sha256Hex(nzb), quality: quality,
                              sizeBytes: sizeBytes, sourceTag: tag, seeders: nil)
        }
        // TORRENT (raw OR debrid-resolved): keyed by the infohash, which is public and identity-stable. We use
        // the infohash whenever present, even if the add-on already handed us a personal resolved `url` -- the
        // url is never sent.
        if let hash = stream.infoHash?.lowercased(), !hash.isEmpty {
            let seeders = StreamRanking.seedersForSort(stream)
            return Descriptor(kind: Kind.torrent.rawValue, id: hash, quality: quality,
                              sizeBytes: sizeBytes, sourceTag: tag, seeders: seeders >= 0 ? seeders : nil)
        }
        // DIRECT: a plain http(s) link with no infohash. Keyed by sha256(url) so the pool can corroborate its
        // existence WITHOUT ever holding (or being able to reconstruct) the actual link. Kind = direct.
        if let url = stream.url, !url.isEmpty {
            return Descriptor(kind: Kind.direct.rawValue, id: sha256Hex(url), quality: quality,
                              sizeBytes: sizeBytes, sourceTag: tag, seeders: nil)
        }
        return nil
    }

    // MARK: - HOARD: POST /sources/contribute (signed, fire-and-forget)

    /// Report the assembled source descriptors for a title. Gated on consent + the fleet feature flag. Batches
    /// the whole set into ONE POST; result ignored; failures silent. No-op on an empty descriptor set.
    static func contribute(contentID: String, descriptors: [Descriptor]) async {
        guard isEnabled, !descriptors.isEmpty else { return }
        // Cap the batch so a pathological title (thousands of streams) can never send an unbounded body.
        let capped = Array(descriptors.prefix(maxDescriptorsPerContribute))

        struct Body: Encodable { let content_id: String; let sources: [Descriptor] }
        guard let data = try? JSONEncoder().encode(Body(content_id: contentID, sources: capped)) else { return }

        var req = URLRequest(url: baseURL.appendingPathComponent("sources").appendingPathComponent("contribute"),
                             timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        VortXEdgeAuth.sign(&req)   // gated host: stamp X-VX-Ts / X-VX-Sig / X-VX-Kid
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Convenience: extract descriptors from `groups` and contribute them for `contentID`. The HOARD entry the
    /// detail screens call.
    static func hoard(contentID: String, groups: [CoreStreamSourceGroup]) async {
        guard isEnabled else { return }
        let descriptors = descriptors(from: groups)
        await contribute(contentID: contentID, descriptors: descriptors)
    }

    // MARK: - SERVE: GET /sources?content_id=… (signed, opt-in + login-gated)

    /// Read the corroborated pooled sources for `contentID`. Returns `[]` unless the Singularity SERVE toggle is
    /// on AND the user is signed in AND consent is granted AND the fleet flag is on. Fail-soft to `[]` on any
    /// error, on the worker's `login_required` empty read, or when disabled.
    static func fetchPooled(contentID: String, isSignedIn: Bool) async -> [PooledSource] {
        guard isEnabled, serveEnabled, isSignedIn else { return [] }
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("sources"),
                                        resolvingAgainstBaseURL: false) else { return [] }
        comps.queryItems = [URLQueryItem(name: "content_id", value: contentID)]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)
        // Moat token: the SERVE gate is login-only AND moat-token-gated (the worker's verifyMoatToken returns
        // an empty list with no token). Stamp X-VX-Moat after the edge signature. Fail-soft: no token -> no
        // header -> the worker returns empty, which is the correct signed-out / cold-start SERVE result.
        if let moat = await MoatToken.shared.current(isSignedIn: isSignedIn) {
            req.setValue(moat, forHTTPHeaderField: MoatToken.header)
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            let decoded = try? JSONDecoder().decode(SourcesResponse.self, from: data)
            return decoded?.sources ?? []
        } catch {
            return []
        }
    }

    /// Turn the corroborated pooled sources into playable `CoreStream`s to merge into the source list. Only the
    /// ACTIONABLE kinds are reconstructable: a torrent (its infohash IS the id) and a usenet source keyed by an
    /// nzb id we can hand back only if the pool also returns a link -- since we deliberately never stored the raw
    /// nzb link, usenet + direct pooled entries are NOT reconstructable and are dropped. So SERVE surfaces
    /// community-corroborated TORRENTS the user's own add-ons did not return. Fail-soft: empty on nothing usable.
    static func streams(from pooled: [PooledSource]) -> [CoreStream] {
        pooled.compactMap { src -> CoreStream? in
            guard src.kind == Kind.torrent.rawValue, let hash = src.id, !hash.isEmpty,
                  hash.range(of: #"^[0-9a-fA-F]{20,64}$"#, options: .regularExpression) != nil else { return nil }
            let quality = (src.quality?.isEmpty == false) ? src.quality! : "Source"
            let sizeSuffix = (src.sizeBytes ?? 0) > 0 ? " · \(byteSize(src.sizeBytes!))" : ""
            let seedSuffix = src.seeders.map { " · 👤 \($0)" } ?? ""
            let name = "\(quality) · Community"
            let desc = "Community source\(sizeSuffix)\(seedSuffix)"
            return make(name: name, description: desc, infoHash: hash.lowercased())
        }
    }

    // MARK: - Feature gates

    /// The master gate for the whole client: consent (give-to-get) AND the fleet feature flag. When off, HOARD
    /// and SERVE are both hard no-ops that never touch the network.
    static var isEnabled: Bool {
        MoatConsent.contributeAndConsume
            && RemoteConfig.snapshot.isFeatureOn("sourceIndex", default: RemoteConfigDefaults.featureSourceIndex)
    }

    /// The per-user SERVE opt-in (the "Singularity" Settings toggle). Default OFF: an unset value reads false,
    /// which is exactly the intended default, so no object-presence dance is needed here.
    static let serveKey = "vortx.singularity.serve"
    static var serveEnabled: Bool { UserDefaults.standard.bool(forKey: serveKey) }

    // MARK: - Helpers

    private static let maxDescriptorsPerContribute = 400

    /// The source-index base URL from RemoteConfig, or the baked default.
    private static var baseURL: URL {
        RemoteConfig.snapshot.endpoint("sources") ?? URL(string: RemoteConfigDefaults.endpointSources)!
    }

    /// Lowercase hex SHA-256 of a string, for the one-way `id` of usenet / direct sources (never the raw link).
    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Trim + bound the source tag so it stays a short provider label with no accidental user data. Caps length.
    private static func sanitizeTag(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Add-on" : String(t.prefix(64))
    }

    private static func byteSize(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter(); fmt.countStyle = .binary
        return fmt.string(fromByteCount: bytes)
    }

    /// Build a `CoreStream` via JSON decode (the all-optional field set has no memberwise init), mirroring
    /// `TorBoxSearch.make`.
    private static func make(name: String, description: String, infoHash: String) -> CoreStream? {
        let json: [String: Any] = ["name": name, "description": description, "infoHash": infoHash]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(CoreStream.self, from: data)
    }

    // MARK: - Decodable wire shape

    private struct SourcesResponse: Decodable {
        let sources: [PooledSource]?
        let reason: String?
    }
}

// MARK: - Per-view SERVE contributor

/// A per-detail-view `@StateObject` that reads the community source index for the current title and publishes
/// the corroborated, actionable sources as one extra group to MERGE into the list -- the SERVE half. Mirrors
/// `TorBoxSearchSource`'s shape exactly. Gated inside `SourceIndexClient` (toggle OFF / signed-out / no consent
/// / fleet-off all yield an empty group), so the source list is unchanged unless the user opted in.
@MainActor
final class SourceIndexServeSource: ObservableObject {
    /// The corroborated community streams, ready to merge. Empty until a fetch completes (and always when the
    /// SERVE toggle is off / signed out / consent withdrawn).
    @Published private(set) var streams: [CoreStream] = []

    private var lastContentID: String?
    private var task: Task<Void, Never>?

    /// Fetch pooled sources for `contentID` when SERVE is enabled + the user is signed in. Fail-soft + deduped
    /// by content id. Safe to call on every meta change / `.task` / `.onAppear`.
    func refresh(contentID: String?, isSignedIn: Bool) {
        guard SourceIndexClient.serveEnabled, SourceIndexClient.isEnabled, isSignedIn,
              let contentID, contentID != lastContentID else {
            // When SERVE is off (or signed out / no consent), clear any previously-merged community sources.
            if !SourceIndexClient.serveEnabled && !streams.isEmpty { streams = [] }
            return
        }
        lastContentID = contentID
        task?.cancel()
        task = Task { [weak self] in
            let pooled = await SourceIndexClient.fetchPooled(contentID: contentID, isSignedIn: isSignedIn)
            let built = SourceIndexClient.streams(from: pooled)
            guard !Task.isCancelled, let self else { return }
            self.streams = built
        }
    }

    /// Merge the community sources into `groups` as one extra group, deduped against streams already present (by
    /// infoHash). Returns `groups` unchanged when there is nothing to add -- a pure pass-through when SERVE is
    /// off or the pool had nothing new.
    func merged(into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard !streams.isEmpty else { return groups }
        var seenHashes: Set<String> = []
        for group in groups {
            for s in group.streams { if let h = s.infoHash?.lowercased() { seenHashes.insert(h) } }
        }
        let fresh = streams.filter { s in
            guard let h = s.infoHash?.lowercased() else { return false }
            return !seenHashes.contains(h)
        }
        guard !fresh.isEmpty else { return groups }
        return groups + [CoreStreamSourceGroup(id: "vortx.singularity.sources", addon: "Community", streams: fresh)]
    }
}
