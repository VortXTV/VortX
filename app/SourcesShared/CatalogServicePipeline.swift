import Foundation

/// Failure classes that must survive transport, pipeline, and UI boundaries. Keeping these distinct prevents
/// an authentication or rate-limit response from being presented as an ordinary empty catalog.
enum CatalogFailureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case transport
    case authentication
    case rateLimited
    case decoding
    case unavailable

    var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited, .unavailable: return true
        case .authentication, .decoding: return false
        }
    }
}

struct CatalogFailure: Hashable, Sendable {
    let kind: CatalogFailureKind
    let statusCode: Int?

    init(_ kind: CatalogFailureKind, statusCode: Int? = nil) {
        self.kind = kind
        self.statusCode = statusCode
    }
}

enum CatalogTransportOutcome<Value> {
    case success(Value)
    case failure(CatalogFailure)
}

/// An external-id lookup never collapses a retryable failure into a confirmed absence.
enum CatalogExternalIDOutcome: Hashable, Sendable {
    case resolved(String)
    case absent
    case failure(CatalogFailure)
}

/// A raw TMDB row before publication. `providerFamily` records the complete canonical family used by the
/// query, while `providerID` is the canonical service identity used by routing and saved order.
struct CatalogCandidate: Hashable, Sendable {
    let tmdbID: Int
    let media: String
    let name: String
    let poster: String?
    let providerID: Int?
    let providerFamily: [Int]

    var candidateKey: String { "\(media):\(tmdbID)" }
    var catalogID: String { "tmdb:\(tmdbID)" }
    var stremioType: String { media == "tv" ? "series" : "movie" }
}

struct CatalogProvenance: Hashable, Sendable {
    let region: String
    let page: Int
    let providerID: Int?
    let providerFamily: [Int]
}

/// One successfully decoded upstream region page. `failures` can be non-empty when, for example, the movie
/// family succeeded while the TV family failed. The page remains usable and is surfaced as partial.
struct CatalogRegionPage: Hashable, Sendable {
    let region: String
    let page: Int
    let totalPages: Int
    let candidates: [CatalogCandidate]
    let failures: [CatalogFailure]
}

enum CatalogRegionPageOutcome: Hashable, Sendable {
    case success(CatalogRegionPage)
    case failure(region: String, failure: CatalogFailure)
}

struct CatalogPublishedItem: Hashable, @unchecked Sendable {
    let preview: MetaPreview
    let provenance: [CatalogProvenance]
}

/// The state shown by both production browse grids.
enum CatalogPageState: Hashable, Sendable {
    case content
    case partial([CatalogFailureKind])
    case unavailable(CatalogFailureKind)
    case postFilter
    case regionEmpty

    var localizedMessage: String? {
        switch self {
        case .content:
            return nil
        case .partial:
            return String(localized: "Some regions could not be loaded. Showing available titles.")
        case .postFilter:
            return String(localized: "No playable IMDb titles were found.")
        case .regionEmpty:
            return String(localized: "No titles were found in the selected regions.")
        case .unavailable(let kind):
            switch kind {
            case .transport:
                return String(localized: "Check your connection and try again.")
            case .authentication:
                return String(localized: "Catalog authentication failed.")
            case .rateLimited:
                return String(localized: "Too many catalog requests. Try again shortly.")
            case .decoding:
                return String(localized: "Catalog response could not be read.")
            case .unavailable:
                return String(localized: "Catalog service is unavailable.")
            }
        }
    }
}

struct CatalogPageResult: Hashable, @unchecked Sendable {
    let items: [CatalogPublishedItem]
    let state: CatalogPageState
    /// Derived only from upstream `total_pages`, never from the number of publishable cards.
    let hasMore: Bool
    let successfulRegions: [String]
    let failedRegions: [String]

    var previews: [MetaPreview] { items.map(\.preview) }
}

/// Ordered region identity shared by fetch, cache, and stale-generation gates.
enum CatalogCacheIdentity {
    static func key(namespace: String, regions: [String]) -> String {
        let ordered = CatalogServicePipeline.normalizedRegions(regions)
        return namespace + "." + ordered.joined(separator: ">")
    }
}

struct CatalogRequestStamp: Hashable, Sendable {
    let generation: Int
    let cacheIdentity: String

    func isCurrent(generation: Int, cacheIdentity: String) -> Bool {
        self.generation == generation && self.cacheIdentity == cacheIdentity
    }
}

/// Bounded, stable multi-region catalog union. Region results and external-id lookups may finish in any order,
/// but publication always follows configured region order, then upstream row order.
struct CatalogServicePipeline: Sendable {
    static let maximumRegions = 8
    static let maximumConcurrentRegionFetches = 3
    static let maximumConcurrentExternalIDResolutions = 6

    typealias RegionFetcher = @Sendable (_ region: String, _ page: Int) async -> CatalogRegionPageOutcome
    typealias ExternalIDResolver = @Sendable (_ candidate: CatalogCandidate) async -> CatalogExternalIDOutcome

    let maximumLookupAttempts: Int

    init(maximumLookupAttempts: Int = 2) {
        self.maximumLookupAttempts = max(1, maximumLookupAttempts)
    }

    static func normalizedRegions(_ regions: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in regions {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard code.count == 2,
                  code.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }),
                  seen.insert(code).inserted else { continue }
            ordered.append(code)
            if ordered.count == maximumRegions { break }
        }
        return ordered
    }

    static func isCanonicalIMDbID(_ value: String) -> Bool {
        guard value.hasPrefix("tt") else { return false }
        let digits = value.dropFirst(2)
        guard (7...10).contains(digits.count) else { return false }
        return digits.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    static func routeID(for value: String) -> String? {
        isCanonicalIMDbID(value) ? value : nil
    }

    func loadPage(
        regions requestedRegions: [String],
        page: Int,
        excludingIMDbIDs: Set<String> = [],
        fetch: @escaping RegionFetcher,
        resolveExternalID: @escaping ExternalIDResolver
    ) async -> CatalogPageResult {
        let regions = Array(Self.normalizedRegions(requestedRegions).prefix(Self.maximumRegions))
        guard !regions.isEmpty else {
            return CatalogPageResult(items: [], state: .unavailable(.unavailable), hasMore: false,
                                     successfulRegions: [], failedRegions: [])
        }

        var indexedOutcomes: [(Int, CatalogRegionPageOutcome)] = []
        for start in stride(from: 0, to: regions.count, by: Self.maximumConcurrentRegionFetches) {
            let batch = Array(regions[start..<min(start + Self.maximumConcurrentRegionFetches, regions.count)])
            let part: [(Int, CatalogRegionPageOutcome)] = await withTaskGroup(
                of: (Int, CatalogRegionPageOutcome).self,
                returning: [(Int, CatalogRegionPageOutcome)].self
            ) { group in
                for (offset, region) in batch.enumerated() {
                    let index = start + offset
                    group.addTask { (index, await fetch(region, page)) }
                }
                var values: [(Int, CatalogRegionPageOutcome)] = []
                for await value in group { values.append(value) }
                return values
            }
            indexedOutcomes.append(contentsOf: part)
        }

        let outcomes = indexedOutcomes.sorted { $0.0 < $1.0 }.map(\.1)
        var successfulPages: [CatalogRegionPage] = []
        var failedRegions: [String] = []
        var failures: [CatalogFailure] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let regionPage):
                successfulPages.append(regionPage)
                failures.append(contentsOf: regionPage.failures)
            case .failure(let region, let failure):
                failedRegions.append(region)
                failures.append(failure)
            }
        }

        guard !successfulPages.isEmpty else {
            let kind = Self.preferredFailureKind(failures.map(\.kind))
            return CatalogPageResult(items: [], state: .unavailable(kind), hasMore: false,
                                     successfulRegions: [], failedRegions: failedRegions)
        }

        struct CandidateBundle {
            let candidate: CatalogCandidate
            var provenance: [CatalogProvenance]
        }

        var bundles: [CandidateBundle] = []
        var bundleIndex: [String: Int] = [:]
        var upstreamCandidateCount = 0
        for regionPage in successfulPages {
            upstreamCandidateCount += regionPage.candidates.count
            for candidate in regionPage.candidates {
                let provenance = CatalogProvenance(region: regionPage.region, page: regionPage.page,
                                                   providerID: candidate.providerID,
                                                   providerFamily: candidate.providerFamily)
                if let index = bundleIndex[candidate.candidateKey] {
                    if !bundles[index].provenance.contains(provenance) {
                        bundles[index].provenance.append(provenance)
                    }
                } else {
                    bundleIndex[candidate.candidateKey] = bundles.count
                    bundles.append(CandidateBundle(candidate: candidate, provenance: [provenance]))
                }
            }
        }

        // A missing poster is a post-filter outcome, not an external-id transport request.
        let eligible = bundles.enumerated().filter { $0.element.candidate.poster?.isEmpty == false }
        var indexedResolutions: [(Int, CatalogExternalIDOutcome)] = []
        for start in stride(from: 0, to: eligible.count, by: Self.maximumConcurrentExternalIDResolutions) {
            let batch = Array(eligible[start..<min(start + Self.maximumConcurrentExternalIDResolutions, eligible.count)])
            let part: [(Int, CatalogExternalIDOutcome)] = await withTaskGroup(
                of: (Int, CatalogExternalIDOutcome).self,
                returning: [(Int, CatalogExternalIDOutcome)].self
            ) { group in
                for pair in batch {
                    group.addTask {
                        let outcome = await resolveWithRetry(pair.element.candidate, resolver: resolveExternalID)
                        return (pair.offset, outcome)
                    }
                }
                var values: [(Int, CatalogExternalIDOutcome)] = []
                for await value in group { values.append(value) }
                return values
            }
            indexedResolutions.append(contentsOf: part)
        }

        var published: [CatalogPublishedItem] = []
        var publishedIndex: [String: Int] = [:]
        var externalFailures: [CatalogFailure] = []
        for (index, outcome) in indexedResolutions.sorted(by: { $0.0 < $1.0 }) {
            let bundle = bundles[index]
            switch outcome {
            case .failure(let failure): externalFailures.append(failure)
            case .resolved, .absent: break
            }
            guard let imdbID = publicationID(for: outcome, candidate: bundle.candidate),
                  !excludingIMDbIDs.contains(imdbID) else { continue }
            if let existing = publishedIndex[imdbID] {
                var provenance = published[existing].provenance
                for value in bundle.provenance where !provenance.contains(value) { provenance.append(value) }
                published[existing] = CatalogPublishedItem(preview: published[existing].preview, provenance: provenance)
                continue
            }
            let preview = MetaPreview(id: imdbID, type: bundle.candidate.stremioType,
                                      name: bundle.candidate.name, poster: bundle.candidate.poster,
                                      posterShape: nil, popularity: nil)
            publishedIndex[imdbID] = published.count
            published.append(CatalogPublishedItem(preview: preview, provenance: bundle.provenance))
        }

        let regionalFailures = failures
        failures.append(contentsOf: externalFailures)
        let hasMore = successfulPages.contains { page < $0.totalPages }
        let successfulRegions = successfulPages.map(\.region)
        let state: CatalogPageState
        if !published.isEmpty, !failures.isEmpty {
            state = .partial(Self.distinctKinds(failures.map(\.kind)))
        } else if !published.isEmpty {
            state = .content
        } else if !externalFailures.isEmpty {
            state = .unavailable(Self.preferredFailureKind(externalFailures.map(\.kind)))
        } else if !regionalFailures.isEmpty {
            state = .partial(Self.distinctKinds(regionalFailures.map(\.kind)))
        } else if upstreamCandidateCount > 0 {
            state = .postFilter
        } else {
            state = .regionEmpty
        }

        return CatalogPageResult(items: published, state: state, hasMore: hasMore,
                                 successfulRegions: successfulRegions, failedRegions: failedRegions)
    }

    private func resolveWithRetry(
        _ candidate: CatalogCandidate,
        resolver: @escaping ExternalIDResolver
    ) async -> CatalogExternalIDOutcome {
        var attempt = 1
        while true {
            let outcome = await resolver(candidate)
            switch outcome {
            case .resolved(let imdbID):
                return Self.isCanonicalIMDbID(imdbID) ? .resolved(imdbID) : .failure(CatalogFailure(.decoding))
            case .absent:
                return .absent
            case .failure(let failure):
                if failure.kind.isRetryable, attempt < maximumLookupAttempts {
                    attempt += 1
                    continue
                }
                return .failure(failure)
            }
        }
    }

    private func publicationID(for outcome: CatalogExternalIDOutcome, candidate: CatalogCandidate) -> String? {
        switch outcome {
        case .resolved(let imdbID):
            guard Self.isCanonicalIMDbID(imdbID) else { return nil }
            return imdbID
        case .absent, .failure:
            return nil
        }
    }

    private static func distinctKinds(_ values: [CatalogFailureKind]) -> [CatalogFailureKind] {
        var seen = Set<CatalogFailureKind>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func preferredFailureKind(_ kinds: [CatalogFailureKind]) -> CatalogFailureKind {
        let priority: [CatalogFailureKind] = [.authentication, .rateLimited, .transport, .decoding, .unavailable]
        return priority.first(where: { kinds.contains($0) }) ?? .unavailable
    }
}
