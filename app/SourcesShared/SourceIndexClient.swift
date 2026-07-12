import Foundation

/// Client for VortX's community SOURCE INDEX at `sources.vortx.tv` ("Singularity"): the pooled record of which
/// SOURCES (torrent / usenet / direct) exist for a title, corroborated across users.
///
/// TWO halves, both 100% fail-soft (any miss / error / offline is a silent no-op; nothing ever blocks or slows
/// playback or a screen):
///
///   1. HOARD (default ON, anonymous): whenever the app assembles a title's stream results from its add-ons /
///      debrid / usenet / torrent sources, it reports the source DESCRIPTORS -- NOT the media, NOT any account
///      token or user id. A descriptor is only { kind, id, quality, sizeBytes, sourceTag, seeders? } where `id`
///      is the source's real, re-resolvable identity: a torrent infohash, a usenet nzb link, or the direct
///      http link (owner directive 2026-07-05: share every source type so each user can resolve it with THEIR
///      OWN debrid / TorBox key). The worker STRIPS credential query params before storing, so a contributor's
///      indexer / debrid apikey never lands in the shared pool. Fire-and-forget, batched, deduped by id.
///
///   2. SERVE (opt-in): when the user turns the Singularity toggle ON AND is signed in, the detail / stream
///      screen reads the corroborated pooled sources for the title and MERGES them into the stream list as
///      community sources, ALL kinds now -- torrent (infohash), usenet (nzb link), and direct (http link) --
///      each resolved by the user's own debrid / TorBox pipeline. A legacy hash-only row (older fleet stored
///      sha256 for usenet/http) is not replayable and is dropped. Empty on any miss; signed-out disables the
///      read entirely (hard login gate, matching the worker).
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
        let id: String            // infohash (torrent) | real nzb link (usenet) | real http link (direct)
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
    /// is never sent (the public infohash is used instead). A torrent is keyed by its infohash, a usenet source
    /// by its real nzb link, and a plain direct source by its real http link (owner directive 2026-07-05), with
    /// the worker stripping credential query params before storing. No account token, user id, or filename is
    /// included.
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

        // USENET: keyed by the REAL nzb link so any user can re-resolve it with their own TorBox usenet plan
        // (owner directive 2026-07-05: share every source type, resolve per-user). The worker STRIPS credential
        // query params before storing, so a private-indexer apikey embedded in the link never lands in the pool
        // (a link that genuinely needed that key just won't resolve for another user). Kind = usenet.
        if stream.isUsenet, let nzb = stream.nzbUrl, !nzb.isEmpty {
            return Descriptor(kind: Kind.usenet.rawValue, id: nzb, quality: quality,
                              sizeBytes: sizeBytes, sourceTag: tag, seeders: nil)
        }
        // TORRENT (raw OR debrid-resolved): keyed by the infohash, which is public and identity-stable. We use
        // the infohash whenever present, even if the add-on already handed us a personal resolved `url` -- the
        // url is never sent (any personal resolved link stays out of the pool; the infohash re-resolves per-user).
        if let hash = stream.infoHash?.lowercased(), !hash.isEmpty {
            let seeders = StreamRanking.seedersForSort(stream)
            return Descriptor(kind: Kind.torrent.rawValue, id: hash, quality: quality,
                              sizeBytes: sizeBytes, sourceTag: tag, seeders: seeders >= 0 ? seeders : nil)
        }
        // DIRECT: a plain http(s) link with no infohash. Now keyed by the REAL link so another user can play it
        // (or unrestrict it through their own debrid), credential params stripped worker-side. Kind = direct.
        if let url = stream.url, !url.isEmpty {
            return Descriptor(kind: Kind.direct.rawValue, id: url, quality: quality,
                              sizeBytes: sizeBytes, sourceTag: tag, seeders: nil)
        }
        return nil
    }

    // MARK: - HOARD: POST /sources/contribute (signed, fire-and-forget)

    /// Report the assembled source descriptors for a title. Gated on consent + the fleet feature flag. Popular
    /// titles routinely resolve far more than one POST can carry (the worker truncates each POST at
    /// `MAX_SOURCES_PER_CONTRIBUTE` = 100), so a single ONE-POST upload silently dropped every descriptor past
    /// the first 100 and a real title never fully seeded. Instead we chunk the whole deduped set into
    /// `batchSize`-descriptor POSTs and send them SEQUENTIALLY, spaced by `interBatchDelayMs` so the run stays
    /// under the worker's per-IP rate limit. Each POST is independently fire-and-forget: its result is ignored,
    /// and a 429 or any error silently drops just that one batch (never blocks or crashes playback). No-op on an
    /// empty set. `descriptors` is expected already-deduped by `descriptors(from:)`.
    static func contribute(contentID: String, descriptors: [Descriptor]) async {
        guard isEnabled, !descriptors.isEmpty else { return }
        // Bound the whole title: a pathological title still never sends an unbounded number of batches.
        let all = Array(descriptors.prefix(maxDescriptorsPerTitle))
        // batchSize MUST stay <= the worker's MAX_SOURCES_PER_CONTRIBUTE or the tail of every batch is dropped
        // worker-side. Slice into <= batchSize chunks.
        let batches = stride(from: 0, to: all.count, by: batchSize).map {
            Array(all[$0 ..< min($0 + batchSize, all.count)])
        }

        struct Body: Encodable { let content_id: String; let sources: [Descriptor] }
        for (i, chunk) in batches.enumerated() {
            guard let data = try? JSONEncoder().encode(Body(content_id: contentID, sources: chunk)) else { continue }

            var req = URLRequest(url: baseURL.appendingPathComponent("sources").appendingPathComponent("contribute"),
                                 timeoutInterval: 8)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = data
            VortXEdgeAuth.sign(&req)   // gated host: stamp X-VX-Ts / X-VX-Sig / X-VX-Kid
            VXProbe.log("sing", "contribute POST content=\(contentID) batch=\(i + 1)/\(batches.count) descriptors=\(chunk.count)")
            _ = try? await URLSession.shared.data(for: req)   // fire-and-forget; a 429 / error just drops this batch

            // Space the batches so the whole run stays under the worker per-IP limit. Skip the sleep after the
            // last batch. try? swallows cancellation, which is fine: this whole call is a detached, fail-soft
            // pool write and is never tied to playback.
            if i < batches.count - 1 {
                try? await Task.sleep(nanoseconds: interBatchDelayMs * 1_000_000)
            }
        }
    }

    /// Convenience: extract descriptors from `groups` and contribute them for `contentID`. The HOARD entry the
    /// detail screens call.
    static func hoard(contentID: String, groups: [CoreStreamSourceGroup]) async {
        guard isEnabled else { return }
        let descriptors = descriptors(from: groups)
        await contribute(contentID: contentID, descriptors: descriptors)
    }

    /// HOARD the SINGLE source a Continue-Watching / card resume actually plays. The resume path re-resolves one
    /// stored source and plays it WITHOUT assembling the title's full stream groups, so the detail-view `hoard`
    /// never runs for a card resume and those (very common) playbacks never seeded the pool at all. This seeds
    /// exactly that one source from the resume's already-stored fields: no new stream-resolve, no network fan-out,
    /// no hot-path work. Gated identically (contribute re-checks `isEnabled` = consent + fleet flag). Deduped per
    /// content id per process, so re-resuming the same title does not re-POST. Fire-and-forget + fail-soft.
    ///
    /// Only TORRENT sources carry a shareable, corroboratable public id (the infohash). A non-torrent resume
    /// (plain direct link) has no poolable id here and is a clean no-op, matching the detail-view descriptor
    /// rules which never send the raw resolved url.
    static func hoardResumedSource(contentID: String, infoHash: String?, quality: String?,
                                   sizeBytes: Int64, sourceTag: String, seeders: Int?) async {
        guard isEnabled else { return }
        guard let hash = infoHash?.lowercased(), !hash.isEmpty,
              hash.range(of: #"^[0-9a-fA-F]{20,64}$"#, options: .regularExpression) != nil else { return }
        // Per-process dedup: a resumed title only needs to seed its one source once per launch.
        guard await ResumeSeedGuard.shared.shouldSeed(contentID: contentID, id: hash) else { return }
        let d = Descriptor(kind: Kind.torrent.rawValue, id: hash,
                           quality: (quality?.isEmpty == false) ? quality! : "Other",
                           sizeBytes: max(0, sizeBytes), sourceTag: sanitizeTag(sourceTag),
                           seeders: (seeders ?? -1) >= 0 ? seeders : nil)
        await contribute(contentID: contentID, descriptors: [d])
    }

    /// HOARD the FULL assembled source groups a Continue-Watching / card resume produces, once the resume path's
    /// background `loadMeta` has populated them. A card resume plays one stored source WITHOUT opening the detail
    /// view, so the detail-view `hoard` never fires for it; the older `hoardResumedSource` only seeded a torrent
    /// resume's single source and no-op'd for a debrid/direct resume (which is exactly the common case), so those
    /// playbacks seeded nothing. This bridges the gap: the resume already kicks `loadMeta` (for the auto-hop
    /// safety net), which asynchronously fills `streamGroups(forStreamId:)`; we poll for that becoming non-empty
    /// under a short bounded cap, then fire the SAME full-group `hoard` the detail view uses, so debrid/direct
    /// resumes seed too.
    ///
    /// 100% fail-soft + off the hot path: bounded poll (`maxWaitMs`), a hung/empty meta simply times out to a
    /// no-op, and the eventual `hoard` is itself consent + fleet-flag gated. Deduped per content per process via
    /// `ResumeSeedGuard` so re-resuming the same title in one launch does not re-POST. `resolveGroups` is called
    /// on the main actor (it reads `CoreBridge`'s published state); nothing here blocks the resume/playback.
    static func hoardResumedGroups(contentID: String,
                                   maxWaitMs: Int = 5000,
                                   pollIntervalMs: Int = 250,
                                   resolveGroups: @MainActor @escaping () -> [CoreStreamSourceGroup]) async {
        guard isEnabled else { return }
        let deadline = max(1, maxWaitMs / max(1, pollIntervalMs))
        for _ in 0..<deadline {
            let groups = await resolveGroups()
            if !groups.isEmpty {
                // Per-process dedup, consumed only once we actually have groups to seed (so a timed-out poll does
                // not burn the slot for a later resume of the same title). A synthetic id keeps this from
                // colliding with the single-source `hoardResumedSource` dedup entries.
                guard await ResumeSeedGuard.shared.shouldSeed(contentID: contentID, id: "resume-groups") else { return }
                await hoard(contentID: contentID, groups: groups)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
        }
        // Timed out with no assembled groups (the resume's stored link played but no meta/streams arrived): a
        // clean no-op, exactly today's behavior for a resume that never assembles the title.
    }

    // MARK: - SERVE: GET /sources?content_id=… (signed, opt-in + login-gated)

    /// Read the corroborated pooled sources for `contentID`. Returns `[]` unless the Singularity SERVE toggle is
    /// on AND the user is signed in AND consent is granted AND the fleet flag is on. Fail-soft to `[]` on any
    /// error, on the worker's `login_required` empty read, or when disabled.
    static func fetchPooled(contentID: String, isSignedIn: Bool) async -> [PooledSource] {
        // SERVE opt-in gate: toggle on/off + signed-in state + master enable, with the decision logged. Sign-in
        // IS required (owner decision 2026-07-04: keep Singularity results a VortX-user-only benefit; the worker
        // enforces the same login gate and serves an empty list to a tokenless caller). Contribute stays open.
        VXProbe.log("sing", "fetchPooled GATE contentID=\(contentID) isEnabled=\(isEnabled ? "on" : "off") serveEnabled=\(serveEnabled ? "on" : "off") isSignedIn=\(isSignedIn ? "yes" : "no")")
        guard isEnabled, serveEnabled, isSignedIn else {
            VXProbe.log("sing", "fetchPooled GATE CLOSED contentID=\(contentID) -> [] (gate off / not signed in)")
            return []
        }
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("sources"),
                                        resolvingAgainstBaseURL: false) else {
            VXProbe.log("sing", "fetchPooled URLComponents FAILED contentID=\(contentID) -> []")
            return []
        }
        // Ask for ALL kinds (no &kind filter): torrent, usenet, AND direct are now cross-user playable (the
        // worker stores real, credential-stripped links; each user resolves per-account). streams(from:) rebuilds
        // each kind and drops any legacy hash-only row it cannot replay.
        comps.queryItems = [
            URLQueryItem(name: "content_id", value: contentID),
        ]
        guard let url = comps.url else {
            VXProbe.log("sing", "fetchPooled url build FAILED contentID=\(contentID) -> []")
            return []
        }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)
        let signed = req.value(forHTTPHeaderField: "X-VX-Sig") != nil
        // Moat token: the SERVE gate is login-only AND moat-token-gated (the worker's verifyMoatToken returns
        // an empty list with no token). Stamp X-VX-Moat after the edge signature. Fail-soft: no token -> no
        // header -> the worker returns empty, which is the correct signed-out / cold-start SERVE result.
        let moat = await MoatToken.shared.current(isSignedIn: isSignedIn)
        if let moat {
            req.setValue(moat, forHTTPHeaderField: MoatToken.header)
        }
        VXProbe.log("sing", "fetchPooled GET \(url.absoluteString) contentID=\(contentID) edgeSigned=\(signed ? "yes" : "no") moatToken=\(moat != nil ? "present" : "absent")")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                VXProbe.log("sing", "fetchPooled HTTP non-2xx contentID=\(contentID) status=\(status) -> []")
                return []
            }
            let decoded = try? JSONDecoder().decode(SourcesResponse.self, from: data)
            let sources = decoded?.sources ?? []
            VXProbe.log("sing", "fetchPooled HTTP OK contentID=\(contentID) status=\(http.statusCode) corroboratedSources=\(sources.count) reason=\(decoded?.reason ?? "-")")
            return sources
        } catch {
            VXProbe.log("sing", "fetchPooled HTTP ERROR contentID=\(contentID) error=\(error.localizedDescription) -> []")
            return []
        }
    }

    /// Turn the corroborated pooled sources into playable `CoreStream`s to merge into the source list. ALL three
    /// kinds are now reconstructable: a torrent (infohash id), a usenet source (real nzb link id), and a direct
    /// source (real http link id). The user's existing debrid / TorBox pipeline then resolves each one with
    /// THEIR OWN keys (infohash -> debrid, nzb -> TorBox usenet, http -> play-or-unrestrict). A LEGACY row whose
    /// id is a bare hash (old fleet stored sha256 for usenet/http) is not replayable and is dropped. Fail-soft.
    static func streams(from pooled: [PooledSource]) -> [CoreStream] {
        let built: [CoreStream] = pooled.compactMap { src -> CoreStream? in
            guard let kind = src.kind, let id = src.id, !id.isEmpty else { return nil }
            let quality = (src.quality?.isEmpty == false) ? src.quality! : "Source"
            let sizeSuffix = (src.sizeBytes ?? 0) > 0 ? " · \(byteSize(src.sizeBytes!))" : ""
            let seedSuffix = src.seeders.map { " · 👤 \($0)" } ?? ""
            // Name/desc both say "Singularity" so the source ROW is visibly a Singularity source (the group
            // label is discarded by the quality re-grouping, but this per-stream text survives and renders).
            let name = "\(quality) · Singularity"
            let isLink = id.lowercased().hasPrefix("http://") || id.lowercased().hasPrefix("https://")
            switch kind {
            case Kind.torrent.rawValue:
                guard id.range(of: #"^[0-9a-fA-F]{20,64}$"#, options: .regularExpression) != nil else { return nil }
                return make(name: name, description: "Singularity source\(sizeSuffix)\(seedSuffix)", infoHash: id.lowercased())
            case Kind.usenet.rawValue:
                guard isLink else { return nil }   // legacy hashed nzb ids are unreplayable
                return make(name: name, description: "Singularity usenet\(sizeSuffix)", nzbUrl: id)
            case "http", Kind.direct.rawValue:
                guard isLink else { return nil }   // legacy sha256(url) rows are unreplayable
                return make(name: name, description: "Singularity source\(sizeSuffix)", url: id)
            default:
                return nil
            }
        }
        VXProbe.log("sing", "streams(from:) reconstruct pooled=\(pooled.count) -> playable=\(built.count) (torrent+usenet+direct; legacy-hash rows dropped)")
        return built
    }

    // MARK: - Feature gates

    /// The master gate for the whole client: consent (give-to-get) AND the fleet feature flag. When off, HOARD
    /// and SERVE are both hard no-ops that never touch the network.
    static var isEnabled: Bool {
        MoatConsent.contributeAndConsume
            && RemoteConfig.snapshot.isFeatureOn("sourceIndex", default: RemoteConfigDefaults.featureSourceIndex)
    }

    /// The per-user SERVE opt-in (the "Singularity" Settings toggle). Default ON, absent key reads as true
    /// (give-to-get; still sign-in gated in fetchPooled), mirroring MoatConsent.contributeAndConsume.
    static let serveKey = "vortx.singularity.serve"
    static var serveEnabled: Bool {
        if UserDefaults.standard.object(forKey: serveKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: serveKey)
    }

    // MARK: - Singularity source-group identity (shared by the iOS + tvOS source lists)

    /// The stable group id `merged(into:)` stamps on Singularity's merged source group, so the source lists
    /// can find it without a magic string.
    static let groupID = "vortx.singularity.sources"
    /// The user-facing label on Singularity's source group + rows. Kept as one constant so the row labels
    /// and the merge all read identically.
    ///
    /// NOTE (owner decision): Singularity renders INLINE ONLY, as this one merged group flowing through
    /// the ranked list like any add-on, sortable with the user's sort. The old pinned top-of-list section
    /// (`pinnedStreams` / `pinnedSectionMax`) duplicated the same sources unsortably above the list and
    /// was removed on both platforms.
    static let groupAddon = "Singularity"

    // MARK: - Helpers

    /// The overall per-title cap on descriptors uploaded. Far above real fan-out (a title with more unique
    /// sources than this drops the tail, which is acceptable). At `batchSize` per POST this is at most 20 POSTs.
    private static let maxDescriptorsPerTitle = 2000
    /// Descriptors per POST. MUST stay <= the worker's MAX_SOURCES_PER_CONTRIBUTE (currently 100) or each batch
    /// tail is truncated worker-side and silently lost.
    private static let batchSize = 100
    /// Delay between sequential batch POSTs. Just over one second so 20 batches spread over ~21s stay under the
    /// worker's per-IP limit (60 contributes per 60s). Fire-and-forget: any dropped batch is silently lost.
    private static let interBatchDelayMs: UInt64 = 1100

    /// The source-index base URL from RemoteConfig, or the baked default.
    private static var baseURL: URL {
        RemoteConfig.snapshot.endpoint("sources") ?? URL(string: RemoteConfigDefaults.endpointSources)!
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
        decodeStream(["name": name, "description": description, "infoHash": infoHash])
    }
    /// A direct source: the `url` field marks it a plain http(s) stream (the existing player plays it, or the
    /// user's debrid unrestricts it).
    private static func make(name: String, description: String, url: String) -> CoreStream? {
        decodeStream(["name": name, "description": description, "url": url])
    }
    /// A usenet source: a non-nil `nzbUrl` makes CoreStream report `isUsenet`, so the existing TorBox usenet
    /// path resolves it with the user's own TorBox account (when their plan supports usenet).
    private static func make(name: String, description: String, nzbUrl: String) -> CoreStream? {
        decodeStream(["name": name, "description": description, "nzbUrl": nzbUrl])
    }
    private static func decodeStream(_ json: [String: Any]) -> CoreStream? {
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
    @Published private(set) var streams: [CoreStream] = [] { didSet { epoch &+= 1 } }
    /// Monotonic epoch bumped whenever `streams` is REPLACED. `SourceListModel` folds this into its
    /// O(1) rebuild signature (a single Int compare instead of hashing the array).
    private(set) var epoch = 0

    private var lastContentID: String?
    private var task: Task<Void, Never>?

    // MARK: Process-lifetime result bank (publish-lost fix)

    /// Last successfully BUILT pool result per content id, process-lifetime. The fetch result used to live
    /// ONLY on this per-view @StateObject: the detail screens derive their page from the GLOBAL
    /// `core.metaDetails` slot, so the owning CoreStreamList is routinely destroyed (meta nil-swap when the
    /// next title's load clears the slot, the player covering the page, a navigation pop) BEFORE the ~0.5s
    /// network round trip returns, and the built streams were dropped at the `let self` guard ("publish
    /// SKIPPED ... self gone"): the owner-reported "Singularity sources never appear". Banking the built
    /// result by content id lets the NEXT instance for the same title publish instantly instead of
    /// re-losing the race. Keyed strictly by the pool content id (always the tt[:S:E] form from
    /// `SourceIndexClient.contentID`), so a banked answer for title A can never paint into a view showing
    /// title B. Statics of this @MainActor class are MainActor-isolated, so every read/write below is
    /// synchronous on the main actor (refresh() and the Task body both run there). Bounded defensively,
    /// mirroring ResumeSeedGuard: on overflow it resets (worst case one re-fetch, still correct).
    private static var resultBank: [String: [CoreStream]] = [:]
    private static func bank(_ contentID: String, _ built: [CoreStream]) {
        if resultBank.count >= 64, resultBank[contentID] == nil { resultBank.removeAll(keepingCapacity: true) }
        resultBank[contentID] = built
    }

    /// Fetch pooled sources for `contentID` when SERVE is enabled + the user is signed in (owner decision
    /// 2026-07-04: Singularity results are a VortX-user-only benefit). Fail-soft + deduped by content id. Safe
    /// to call on every meta change / `.task` / `.onAppear`.
    func refresh(contentID: String?, isSignedIn: Bool) {
        guard SourceIndexClient.serveEnabled, SourceIndexClient.isEnabled, isSignedIn,
              let contentID, contentID != lastContentID else {
            // Clear any previously-merged community sources whenever the SERVE gate is CLOSED (toggle off, signed
            // out, or consent/fleet-flag withdrawn), so stale Singularity rows do not linger after the gate
            // closes. A skip for an unchanged / nil content id with the gate still open leaves them in place.
            if (!SourceIndexClient.serveEnabled || !SourceIndexClient.isEnabled || !isSignedIn), !streams.isEmpty {
                streams = []
            }
            return
        }
        lastContentID = contentID
        // WARM PAINT: a fetch for this exact content id already landed this process (often on a predecessor
        // @StateObject SwiftUI destroyed before the round trip returned). Publish it synchronously so the
        // recreated view merges the pool immediately; the network fetch below still runs and replaces it
        // with the fresh answer.
        if let banked = Self.resultBank[contentID], !banked.isEmpty {
            VXProbe.log("sing", "refresh seeded from bank contentID=\(contentID) streams=\(banked.count)")
            streams = banked
        }
        task?.cancel()
        task = Task { [weak self] in
            let pooled = await SourceIndexClient.fetchPooled(contentID: contentID, isSignedIn: isSignedIn)
            let built = SourceIndexClient.streams(from: pooled)
            // Bank BEFORE the liveness guard: the result is correct for this content id whether or not the
            // requesting view survived. A dead view just means the NEXT view for this title publishes it
            // instantly. Empty results are never banked (a young pool may fill; keep re-asking).
            if !built.isEmpty { Self.bank(contentID, built) }
            guard !Task.isCancelled, let self else {
                VXProbe.log("sing", "refresh publish SKIPPED contentID=\(contentID) (cancelled or self gone) built=\(built.count) banked=\(built.isEmpty ? "no" : "yes")")
                return
            }
            VXProbe.log("sing", "refresh publish contentID=\(contentID) streams=\(built.count) (now merge-ready)")
            self.streams = built
        }
    }

    /// Empty the PUBLISHED community streams, cancelling any in-flight fetch first - its completion
    /// publishes `streams` UNCONDITIONALLY (no content-id guard), so an uncancelled late answer for a
    /// previous title would repopulate the pool after this clear. The cancel loses nothing durable: the
    /// fetch banks its result BEFORE the liveness guard, so the process-lifetime result bank (which this
    /// method never touches) still warms the next refresh for that title. `lastContentID` resets so a
    /// later refresh for the SAME title re-publishes (bank-seeded) instead of being deduped into keeping
    /// the emptied state. For an owner that reuses ONE instance across titles (the batch-download
    /// coordinator #119, unlike the per-view @StateObjects that die with their screen): the result pool
    /// is PER-TITLE, and a title that cannot query the pool (no imdb id -> nil content id) must see it
    /// EMPTY, never a predecessor title's results - `refresh` skips a nil content id with the gate open
    /// without clearing, so the owner clears explicitly.
    func clearResults() {
        task?.cancel()
        lastContentID = nil
        if !streams.isEmpty { streams = [] }
    }

    /// Merge the community sources into `groups` as its OWN named source group, exactly like any other add-on.
    /// Singularity's corroborated sources appear under the "Singularity" label whenever the pool has any for this
    /// title, EVEN when one of your own add-ons also returns the same release: add-ons are never deduped against
    /// one another, so Singularity is not either (that is what made it invisible on titles your add-ons already
    /// cover). We drop only internal duplicates within Singularity's own list, by infoHash. Empty pool (SERVE off
    /// / not signed in / fleet-off / nothing corroborated) is a pure pass-through, so the list is unchanged.
    func merged(into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        Self.merge(streams, into: groups)
    }

    /// The pure merge. `nonisolated static` so `SourceListModel`'s off-main assembly can run it over a
    /// snapshotted `streams` array without hopping to the main actor; the instance `merged(into:)`
    /// wraps it for the existing main-actor call sites.
    ///
    /// DELIBERATELY SILENT: the old per-call `[sing] merged` probe fired on every SwiftUI body eval
    /// (thousands of lines, ~150 ms apart, on a loading title) and was the log-flood symptom of the
    /// main-thread source-list storm. The `[sing] merged` health log now lives in
    /// `SourceListModel.rebuild`, once per coalesced rebuild, where its frequency is the metric.
    nonisolated static func merge(_ extra: [CoreStream], into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard !extra.isEmpty else { return groups }
        var seen: Set<String> = []
        var own: [CoreStream] = []
        for s in extra {
            // Key each pooled source by its REPLAYABLE identity so all three kinds survive de-dup, not just
            // torrents (the old infohash-only key silently dropped every usenet + direct pooled row): a torrent
            // by infohash, a usenet source by its nzb link, a direct source by its url. A stream with none of
            // those is unplayable and skipped. The kind prefix keeps the three key spaces from colliding.
            let key: String?
            if let h = s.infoHash?.lowercased(), !h.isEmpty { key = "t:" + h }
            else if let nzb = s.nzbUrl, !nzb.isEmpty { key = "u:" + nzb }
            else if let u = s.url, !u.isEmpty { key = "d:" + u }
            else { key = nil }
            guard let key else { continue }
            if seen.insert(key).inserted { own.append(s) }
        }
        // NOTE: `own` is deduped ONLY within Singularity's own list (by replayable identity: torrent infohash,
        // usenet nzb link, or direct url); it is deliberately NOT deduped against the user's add-on groups, so a
        // release your add-ons already return still appears under the Singularity label.
        guard !own.isEmpty else { return groups }
        return groups + [CoreStreamSourceGroup(id: SourceIndexClient.groupID, addon: SourceIndexClient.groupAddon, streams: own)]
    }
}

// MARK: - Resume-seed dedup

/// Remembers which (content, source) pairs a resume already seeded this process, so re-resuming the same title
/// does not re-POST the same one source. Process-lifetime only (never persisted): a fresh launch may re-seed
/// once, which is harmless (the pool upserts by UNIQUE(content_id, kind, id)).
actor ResumeSeedGuard {
    static let shared = ResumeSeedGuard()
    private var seen: Set<String> = []

    /// True the FIRST time a given (contentID, id) is offered this process; false thereafter. Bounded so a long
    /// session cannot grow the set without limit; on overflow it resets (worst case a re-seed, still harmless).
    func shouldSeed(contentID: String, id: String) -> Bool {
        if seen.count > 4000 { seen.removeAll(keepingCapacity: true) }
        return seen.insert(contentID + "|" + id).inserted
    }
}
