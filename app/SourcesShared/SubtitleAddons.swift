import Foundation

extension CoreStreamBehaviorHints {
    var subtitleMetadata: SubtitleRequestMetadata {
        SubtitleRequestMetadata(filename: filename, videoHash: videoHash, videoSize: videoSize)
    }
}

/// One external subtitle offered by a subtitles add-on (e.g. an OpenSubtitles add-on).
struct AddonSubtitle: Identifiable, Equatable, Sendable {
    let id: String
    let url: String
    let lang: String
    let addonName: String
    /// Original installed source endpoint; never inferred from the returned subtitle URL or redirect URL.
    let installedBaseURL: URL
    var releaseName: String? = nil

    var displayTitle: String {
        guard let releaseName, !releaseName.isEmpty else { return addonName }
        return "\(addonName) · \(releaseName)"
    }
}

/// A minimal installed subtitle add-on: the base URL to query and a display name. Decouples the fetch from
/// any one descriptor type so it can UNION the engine's installed add-ons (`CoreDescriptor`, the source of
/// truth since VortX went account-primary) with the legacy Stremio-collection add-ons (`AddonDescriptor`),
/// which are empty on a VortX-primary device with no live Stremio session (ozdek #148).
struct SubtitleAddonSource: Equatable, Sendable {
    let baseUrl: String
    let name: String
}

/// Fetches external subtitles from every installed add-on that declares the `subtitles`
/// resource, the way the official clients do. The player lists these next to the file's
/// embedded tracks; picking one hands the URL to mpv (`sub-add`).
enum SubtitleAddonService {
    private struct SubtitlesResponse: Decodable { let subtitles: [Sub]? }
    private struct Sub: Decodable {
        let id: String?
        let url: String?
        let lang: String?
        let subtitleFileName: String?

        enum CodingKeys: String, CodingKey { case id, url, lang, subtitleFileName }
        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? fields?.decode(String.self, forKey: .id)
            url = try? fields?.decode(String.self, forKey: .url)
            lang = try? fields?.decode(String.self, forKey: .lang)
            subtitleFileName = try? fields?.decode(String.self, forKey: .subtitleFileName)
        }
    }

    /// The installed subtitle add-ons to query: the ENGINE store first (`core.addons`, authoritative since
    /// installs stopped propagating to the Stremio collection on a VortX-primary device), with the
    /// Stremio-collection store (`account.addons`) unioned in as a fallback so a still-Stremio-connected
    /// device is unchanged. Deduped by normalized base URL (engine wins on a tie). Both lists are filtered to
    /// add-ons that declare the `subtitles` resource. This is the #148 fix: the old fetch read only
    /// `account.addons`, which is empty when there is no live Stremio session.
    static func installedSources(engine: [CoreDescriptor], account: [AddonDescriptor]) -> [SubtitleAddonSource] {
        var seen = Set<String>()
        var out: [SubtitleAddonSource] = []
        func add(_ base: String, _ name: String) {
            let norm = AddonTombstones.normalize(base)
            guard !norm.isEmpty, seen.insert(norm).inserted else { return }
            out.append(SubtitleAddonSource(baseUrl: base, name: name))
        }
        for d in engine where d.providesSubtitles { add(d.baseUrl, d.manifest.name) }
        for d in account where d.manifest.resources.contains(where: { $0.name == "subtitles" }) {
            add(d.baseUrl, d.manifest.name)
        }
        return out
    }

    struct QueryIdentity: Equatable, Sendable {
        let type: String
        let libraryID: String
        let videoID: String
    }
    struct ResolutionState {
        struct Request: Equatable, Sendable {
            private let id = UUID()
            let query: QueryIdentity
            init(query: QueryIdentity) { self.query = query }
        }
        private(set) var pending: Request?
        mutating func reset() { pending = nil }
        mutating func begin(query: QueryIdentity) -> Request? {
            guard pending == nil else { return nil }
            let request = Request(query: query); pending = request
            return request
        }
        mutating func finish(_ request: Request, currentQuery: QueryIdentity) -> Bool {
            guard pending == request else { return false }
            pending = nil
            return request.query == currentQuery
        }
    }

    enum SourceStatus: Sendable {
        case success([AddonSubtitle]) // An empty success is authoritative for this source/key.
        case failed
    }
    struct SourceOutcome: Sendable {
        let source: SubtitleAddonSource
        let status: SourceStatus
    }
    struct FetchOutcome: Sendable {
        let sources: [SourceOutcome]
        var failedSourceCount: Int {
            sources.filter { if case .failed = $0.status { return true }; return false }.count
        }
        var subtitles: [AddonSubtitle] {
            var seen = Set<String>()
            return sources.flatMap { result -> [AddonSubtitle] in
                if case .success(let subtitles) = result.status { return subtitles }
                return []
            }.filter { seen.insert($0.url).inserted }
        }
    }

    /// Main-actor caller state, with opaque batch authority and per-installed-source receipts.
    /// It stores no diagnostic text and never grants transport permission.
    struct DiscoveryState {
        struct Request: Sendable {
            fileprivate let generation: UUID
            fileprivate let id: UUID
            let sources: [SubtitleAddonSource]
        }
        private enum Status {
            case pending, inFlight(UUID), complete(SourceStatus)
        }
        private struct Entry {
            let source: SubtitleAddonSource
            var status: Status
        }
        private var generation = UUID()
        private var key: String?
        private var currentSources: [SubtitleAddonSource] = []
        private var entries: [Entry] = []

        private func sameSource(_ lhs: SubtitleAddonSource, _ rhs: SubtitleAddonSource) -> Bool {
            lhs.baseUrl == rhs.baseUrl // A display-name edit is not new transport authority.
        }
        mutating func reset() { self = DiscoveryState() }
        mutating func updateSources(_ sources: [SubtitleAddonSource]) {
            currentSources = sources.reduce(into: []) { result, source in
                if !result.contains(where: { sameSource($0, source) }) { result.append(source) }
            }
            for source in currentSources where !entries.contains(where: { sameSource($0.source, source) }) {
                entries.append(Entry(source: source, status: .pending))
            }
            // Retain removed in-flight ownership until completion: remove/re-add cannot duplicate it.
            // Only currentSources contribute visible rows; owner/resource reset retires all receipts.
        }
        mutating func begin(key: String, sources: [SubtitleAddonSource], retryFailures: Bool) -> Request? {
            if self.key != key { reset(); self.key = key }
            updateSources(sources)
            let selected = entries.indices.filter { index in
                guard currentSources.contains(where: { sameSource($0, entries[index].source) }) else { return false }
                switch entries[index].status {
                case .pending: return true
                case .complete(.failed): return retryFailures
                case .inFlight(_), .complete(.success(_)): return false
                }
            }
            guard !selected.isEmpty else { return nil }
            let id = UUID()
            let sources = selected.map { entries[$0].source }
            for index in selected { entries[index].status = .inFlight(id) }
            return Request(generation: generation, id: id, sources: sources)
        }
        @discardableResult
        mutating func finish(_ request: Request, outcome: FetchOutcome) -> Bool {
            guard request.generation == generation else { return false }
            var owned = false
            for index in entries.indices {
                guard case .inFlight(let id) = entries[index].status, id == request.id,
                      request.sources.contains(where: { sameSource($0, entries[index].source) }) else { continue }
                owned = true
                let result = outcome.sources.first { sameSource($0.source, entries[index].source) }
                entries[index].status = .complete(result?.status ?? .failed)
            }
            return owned
        }
        var failedSourceCount: Int {
            currentSources.filter { source in
                entries.contains { entry in
                    guard sameSource(entry.source, source), case .complete(.failed) = entry.status else { return false }
                    return true
                }
            }.count
        }
        var subtitles: [AddonSubtitle] {
            FetchOutcome(sources: currentSources.compactMap { source in
                guard let entry = entries.first(where: { sameSource($0.source, source) }),
                      case .complete(let status) = entry.status else { return nil }
                return SourceOutcome(source: source, status: status)
            }).subtitles
        }
    }

    /// Compatibility API: existing callers retain the same fail-soft list contract.
    static func fetch(sources: [SubtitleAddonSource], type: String, videoId: String,
                      metadata: SubtitleRequestMetadata = .init(),
                      testURLProtocolClasses: AddonURLGuard.TestURLProtocolClasses? = nil) async -> [AddonSubtitle] {
        let outcome = await fetchOutcome(sources: sources, type: type, videoId: videoId, metadata: metadata,
                                         testURLProtocolClasses: testURLProtocolClasses)
        return outcome.subtitles
    }

    /// All subtitles for `type/videoId` across the given subtitle add-ons, in source order,
    /// deduplicated by URL. videoId is a movie id or `id:season:episode`.
    static func fetchOutcome(sources: [SubtitleAddonSource], type: String, videoId: String,
                      metadata: SubtitleRequestMetadata = .init(),
                      testURLProtocolClasses: AddonURLGuard.TestURLProtocolClasses? = nil) async -> FetchOutcome {
        guard !sources.isEmpty else { return FetchOutcome(sources: []) }
        let path = metadata.resourcePath(type: type, videoID: videoId)
        let legacyPath = SubtitleRequestMetadata().resourcePath(type: type, videoID: videoId)
        let paths = path == legacyPath ? [path] : [path, legacyPath]

        let collected: [SourceOutcome] = await withTaskGroup(of: (Int, SourceOutcome).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    func failed() -> (Int, SourceOutcome) {
                        (i, SourceOutcome(source: source, status: .failed))
                    }
                    guard let installedBaseURL = URL(string: source.baseUrl) else { return failed() }
                    let access = AddonURLGuard.AccessScope.addon(origin: installedBaseURL)
                    // One source gets one operation budget across both metadata and legacy paths.
                    let deadline = Date().addingTimeInterval(15)
                    for (attempt, resourcePath) in paths.enumerated() {
                        guard !Task.isCancelled,
                              let url = URL(string: "\(source.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(resourcePath)") else {
                            return failed()
                        }
                        let remaining = deadline.timeIntervalSinceNow
                        guard remaining > 0 else { return failed() }
                        let response: AddonURLGuard.Response
                        do {
                            response = try await AddonURLGuard.fetch(
                                url, context: .subtitleIndex, access: access, timeout: remaining,
                                testURLProtocolClasses: testURLProtocolClasses)
                        } catch let rejection as AddonURLGuard.SubtitleIndexRouteRejection {
                            // Older routers may only implement the ID-only route. Retry once for route
                            // rejection only, never for empty success, auth failure or provider outage.
                            if attempt == 0, paths.count > 1, [404, 405].contains(rejection.statusCode) { continue }
                            return failed()
                        } catch {
                            return failed()
                        }
                        guard let decoded = try? JSONDecoder().decode(SubtitlesResponse.self, from: response.data),
                              let subtitles = decoded.subtitles else {
                            return failed()
                        }
                        var subs: [AddonSubtitle] = []
                        // Relative links use the actual index location. Private-network permission
                        // still belongs ONLY to the original installed source, never this redirect.
                        // Bound expanded URL text too: a long base must not amplify a tiny JSON list.
                        var remainingURLBytes = AddonURLGuard.ResponseContext.subtitleIndex.maximumBytes
                        for sub in subtitles {
                            guard let raw = sub.url, !raw.isEmpty,
                                  let resolved = URL(string: raw, relativeTo: response.finalURL)?.absoluteURL,
                                  let scheme = resolved.scheme?.lowercased(), ["http", "https"].contains(scheme),
                                  let host = resolved.host, !host.isEmpty,
                                  resolved.user == nil, resolved.password == nil, resolved.fragment == nil else { continue }
                            let url = resolved.absoluteString
                            let bytes = url.utf8.count
                            guard bytes <= AddonURLGuard.ResponseContext.subtitleFile.maximumURLBytes else { continue }
                            guard bytes <= remainingURLBytes else { break }
                            remainingURLBytes -= bytes
                            subs.append(AddonSubtitle(id: sub.id ?? url, url: url,
                                lang: sub.lang ?? "und", addonName: source.name,
                                installedBaseURL: installedBaseURL, releaseName: sub.subtitleFileName))
                        }
                        return (i, SourceOutcome(source: source, status: .success(subs)))
                    }
                    return failed()
                }
            }
            var buckets = [SourceOutcome?](repeating: nil, count: sources.count)
            for await (i, chunk) in group { buckets[i] = chunk }
            return buckets.compactMap { $0 }
        }

        return FetchOutcome(sources: collected)
    }
}
