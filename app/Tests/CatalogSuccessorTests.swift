import Foundation
import XCTest

#if os(iOS)
@testable import VortXiOSNative
#elseif os(tvOS)
@testable import VortXTV
#endif

final class CatalogSuccessorTests: XCTestCase {
    private func candidate(
        _ id: Int,
        media: String = "movie",
        poster: String? = "/poster.jpg",
        providerID: Int? = 2336
    ) -> CatalogCandidate {
        CatalogCandidate(tmdbID: id, media: media, name: "Title \(id)", poster: poster,
                         providerID: providerID,
                         providerFamily: providerID.map(TMDBClient.providerFamilyMembers) ?? [])
    }

    private func page(
        region: String,
        page: Int = 1,
        totalPages: Int = 1,
        candidates: [CatalogCandidate],
        failures: [CatalogFailure] = []
    ) -> CatalogRegionPageOutcome {
        .success(CatalogRegionPage(region: region, page: page, totalPages: totalPages,
                                   candidates: candidates, failures: failures))
    }

    func testM1RegionsFirstOnlyIsKilledByOrderedUnion() async {
        let fetchProbe = RegionFetchProbe()
        let resolveProbe = ResolutionProbe()
        let pipeline = CatalogServicePipeline()
        let result = await pipeline.loadPage(
            regions: ["GB", "IN", "US", "CA"],
            page: 1,
            fetch: { region, page in
                await fetchProbe.fetch(region: region, page: page, candidates: [
                    "GB": [self.candidate(1), self.candidate(2)],
                    "IN": [self.candidate(1), self.candidate(3)],
                    "US": [self.candidate(3), self.candidate(4)],
                    "CA": [self.candidate(5)],
                ])
            },
            resolveExternalID: { candidate in await resolveProbe.resolve(candidate) }
        )

        XCTAssertEqual(result.previews.map(\.id),
                       ["tt0000001", "tt0000002", "tt0000003", "tt0000004", "tt0000005"])
        XCTAssertEqual(result.successfulRegions, ["GB", "IN", "US", "CA"])
        XCTAssertEqual(result.items.first(where: { $0.preview.id == "tt0000001" })?.provenance.map(\.region),
                       ["GB", "IN"])
        XCTAssertEqual(result.items.first(where: { $0.preview.id == "tt0000003" })?.provenance.map(\.region),
                       ["IN", "US"])
        let maximumRegionConcurrency = await fetchProbe.maximumConcurrent
        XCTAssertEqual(maximumRegionConcurrency, 3)
    }

    func testM2RegionFailureIsTotalIsKilledByPartialPublication() async {
        let result = await CatalogServicePipeline().loadPage(
            regions: ["GB", "IN"],
            page: 1,
            fetch: { region, _ in
                region == "GB"
                    ? self.page(region: region, candidates: [self.candidate(6)])
                    : .failure(region: region, failure: CatalogFailure(.authentication, statusCode: 401))
            },
            resolveExternalID: { _ in .resolved("tt0000006") }
        )

        XCTAssertEqual(result.previews.map(\.id), ["tt0000006"])
        XCTAssertEqual(result.state, .partial([.authentication]))
        XCTAssertEqual(result.successfulRegions, ["GB"])
        XCTAssertEqual(result.failedRegions, ["IN"])

        let total = await CatalogServicePipeline().loadPage(
            regions: ["GB", "IN"], page: 1,
            fetch: { region, _ in
                .failure(region: region,
                         failure: CatalogFailure(region == "GB" ? .transport : .authentication))
            },
            resolveExternalID: { _ in .absent }
        )
        XCTAssertEqual(total.state, .unavailable(.authentication))
        XCTAssertTrue(total.items.isEmpty)
    }

    func testM3RawTMDBPublishedIsKilledByStrictPublication() async {
        let result = await CatalogServicePipeline().loadPage(
            regions: ["IN"], page: 1,
            fetch: { region, _ in self.page(region: region, candidates: [self.candidate(73)]) },
            resolveExternalID: { _ in .absent }
        )

        XCTAssertTrue(result.previews.isEmpty)
        XCTAssertEqual(result.state, .postFilter)
        XCTAssertNil(CatalogServicePipeline.routeID(for: "tmdb:73"))
    }

    func testM4TransientExternalIDIsAbsentIsKilledByRetry() async {
        let attempts = RetryProbe()
        let result = await CatalogServicePipeline(maximumLookupAttempts: 2).loadPage(
            regions: ["IN"], page: 1,
            fetch: { region, _ in self.page(region: region, candidates: [self.candidate(74)]) },
            resolveExternalID: { _ in await attempts.resolveAfterTransientFailure() }
        )

        XCTAssertEqual(result.previews.map(\.id), ["tt0000074"])
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 2)
    }

    func testM5FilteredEmptyStopsPaginationIsKilledByUpstreamContinuation() async {
        let result = await CatalogServicePipeline().loadPage(
            regions: ["IN"], page: 1,
            fetch: { region, page in
                self.page(region: region, page: page, totalPages: 3,
                          candidates: [self.candidate(75, poster: nil)])
            },
            resolveExternalID: { _ in XCTFail("Poster-filtered rows must not resolve"); return .absent }
        )

        XCTAssertTrue(result.previews.isEmpty)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.state, .postFilter)
    }

    func testM6FailureKindCollapsedIsKilledByTypedTransportOutcomes() {
        XCTAssertEqual(TMDBClient.catalogFailure(statusCode: 401)?.kind, .authentication)
        XCTAssertEqual(TMDBClient.catalogFailure(statusCode: 403)?.kind, .authentication)
        XCTAssertEqual(TMDBClient.catalogFailure(statusCode: 429)?.kind, .rateLimited)
        XCTAssertEqual(TMDBClient.catalogFailure(statusCode: 503)?.kind, .unavailable)
        XCTAssertNil(TMDBClient.catalogFailure(statusCode: 204))

        switch TMDBClient.catalogDecodedJSON(data: Data("not-json".utf8), statusCode: 200) {
        case .failure(let failure): XCTAssertEqual(failure.kind, .decoding)
        case .success: XCTFail("Malformed JSON must remain a decode failure")
        }
        XCTAssertEqual(TMDBClient.catalogFailure(for: URLError(.timedOut)).kind, .transport)
    }

    func testM7CacheKeyIgnoresRegionOrderIsKilledByOrderedIdentity() {
        let gbFirst = CatalogCacheIdentity.key(namespace: "provider", regions: ["GB", "IN", "US"])
        let inFirst = CatalogCacheIdentity.key(namespace: "provider", regions: ["IN", "GB", "US"])
        XCTAssertNotEqual(gbFirst, inFirst)

        let stamp = CatalogRequestStamp(generation: 9, cacheIdentity: gbFirst)
        XCTAssertTrue(stamp.isCurrent(generation: 9, cacheIdentity: gbFirst))
        XCTAssertFalse(stamp.isCurrent(generation: 9, cacheIdentity: inFirst))
        XCTAssertFalse(stamp.isCurrent(generation: 10, cacheIdentity: gbFirst))
    }

    func testCanonicalIMDbGrammarAndRouteHelper() {
        for id in ["tt0000001", "tt12345678", "tt123456789", "tt1234567890"] {
            XCTAssertTrue(CatalogServicePipeline.isCanonicalIMDbID(id), id)
            XCTAssertEqual(CatalogServicePipeline.routeID(for: id), id)
        }
        for id in ["tmdb:1", "TT1234567", "tt123456", "tt12345678901", "tt12345a7", "tt١٢٣٤٥٦٧", "  tt1234567"] {
            XCTAssertFalse(CatalogServicePipeline.isCanonicalIMDbID(id), id)
            XCTAssertNil(CatalogServicePipeline.routeID(for: id))
        }
    }

    func testExternalIDResolutionConcurrencyIsBoundedAtSix() async {
        let probe = ResolutionProbe(delayNanoseconds: 30_000_000)
        let candidates = (100...111).map { candidate($0) }
        let result = await CatalogServicePipeline().loadPage(
            regions: ["GB"], page: 1,
            fetch: { region, _ in self.page(region: region, candidates: candidates) },
            resolveExternalID: { candidate in await probe.resolve(candidate) }
        )
        XCTAssertEqual(result.items.count, 12)
        let maximumResolutionConcurrency = await probe.maximumConcurrent
        XCTAssertEqual(maximumResolutionConcurrency, 6)
    }

    func testCrossPageDedupeExcludesAlreadyPublishedIMDbIDs() async {
        let result = await CatalogServicePipeline().loadPage(
            regions: ["GB"], page: 2, excludingIMDbIDs: ["tt0000200"],
            fetch: { region, page in
                self.page(region: region, page: page, totalPages: 2,
                          candidates: [self.candidate(200), self.candidate(201)])
            },
            resolveExternalID: { candidate in .resolved(String(format: "tt%07d", candidate.tmdbID)) }
        )
        XCTAssertEqual(result.previews.map(\.id), ["tt0000201"])
        XCTAssertFalse(result.hasMore)
    }

    func testSuccessfulEmptyRegionIsNotReportedAsAServiceFailure() async {
        let result = await CatalogServicePipeline().loadPage(
            regions: ["GB"], page: 1,
            fetch: { region, page in self.page(region: region, page: page, candidates: []) },
            resolveExternalID: { _ in XCTFail("An empty page has nothing to resolve"); return .absent }
        )
        XCTAssertEqual(result.state, .regionEmpty)
        XCTAssertFalse(result.hasMore)
    }

    @MainActor
    func testLegacyRegionMigrationBackupCloudAndProviderOrder() throws {
        XCTAssertEqual(CatalogPrefsStore.migratedCatalogRegions(storedRegions: nil,
                                                                legacyRegion: "GB", deviceRegion: "US"),
                       ["GB", "IN", "US"])
        XCTAssertEqual(CatalogPrefsStore.migratedCatalogRegions(storedRegions: nil,
                                                                legacyRegion: "CA", deviceRegion: "US"),
                       ["CA", "GB", "IN", "US"])
        XCTAssertEqual(CatalogPrefsStore.migratedCatalogRegions(
            storedRegions: ["ca", "IN", "ca", "US", "GB", "FR", "DE", "JP", "AU", "BR"],
            legacyRegion: "CA", deviceRegion: "US"),
            ["CA", "IN", "US", "GB", "FR", "DE", "JP", "AU"])

        let domain: [String: Any] = [
            CatalogPrefsStore.regionKey: "CA",
            CatalogPrefsStore.regionsV2Key: ["CA", "GB", "IN", "US"],
        ]
        XCTAssertTrue(SettingsBackup.isSyncable(CatalogPrefsStore.regionsV2Key))
        let backup = try SettingsBackup.encode(domain: domain, bundleID: "catalog.tests", app: "VortX",
                                               now: Date(timeIntervalSince1970: 1))
        let restored = try SettingsBackup.decodeDomain(from: backup)
        XCTAssertEqual(restored[CatalogPrefsStore.regionKey] as? String, "CA")
        XCTAssertEqual(restored[CatalogPrefsStore.regionsV2Key] as? [String], ["CA", "GB", "IN", "US"])

        let defaults = UserDefaults.standard
        let previousLegacy = defaults.object(forKey: CatalogPrefsStore.regionKey)
        let previousRegions = defaults.object(forKey: CatalogPrefsStore.regionsV2Key)
        defaults.removeObject(forKey: CatalogPrefsStore.regionKey)
        defaults.removeObject(forKey: CatalogPrefsStore.regionsV2Key)
        defer {
            if let previousLegacy { defaults.set(previousLegacy, forKey: CatalogPrefsStore.regionKey) }
            else { defaults.removeObject(forKey: CatalogPrefsStore.regionKey) }
            if let previousRegions { defaults.set(previousRegions, forKey: CatalogPrefsStore.regionsV2Key) }
            else { defaults.removeObject(forKey: CatalogPrefsStore.regionsV2Key) }
        }
        let cloud = SettingsBackup.mergedSyncBlob(onto: backup.base64EncodedString())
        XCTAssertNotNil(cloud)
        let cloudRestored = try SettingsBackup.decodeDomain(from: try XCTUnwrap(cloud))
        XCTAssertEqual(cloudRestored[CatalogPrefsStore.regionsV2Key] as? [String], ["CA", "GB", "IN", "US"])

        let tiles = [
            TMDBClient.ProviderTile(providerID: 8, name: "Netflix", logoPath: nil),
            TMDBClient.ProviderTile(providerID: 2336, name: "JioHotstar", logoPath: nil),
            TMDBClient.ProviderTile(providerID: 232, name: "ZEE5", logoPath: nil),
        ]
        XCTAssertEqual(CollectionsHubModel.applyOrder(tiles, order: [232, 8]).map(\.providerID),
                       [232, 8, 2336])
    }

    func testProviderRosterContainsJioHotstarAndZEE5() {
        let majorIDs = TMDBClient.majorStreamingServices.map(\.providerID)
        XCTAssertTrue(majorIDs.contains(2336))
        XCTAssertTrue(majorIDs.contains(232))
    }

    func testMountedHomeRoutesExposeJioHotstarAndZEE5() {
        let mounted = CollectionsHubMount.serviceRoutes(from: [
            TMDBClient.ProviderTile(providerID: 122, name: "Legacy Hotstar", logoPath: nil, regions: ["GB"]),
            TMDBClient.ProviderTile(providerID: 2336, name: "JioHotstar", logoPath: nil, regions: ["IN"]),
            TMDBClient.ProviderTile(providerID: 232, name: "ZEE5", logoPath: nil, regions: ["IN"]),
        ])
        XCTAssertEqual(mounted.map(\.id), [2336, 232])
        XCTAssertEqual(mounted.first?.provider.regions, ["GB", "IN"])
        guard case .service(let id, _) = mounted[1].target else {
            return XCTFail("Mounted route must target a service browse screen")
        }
        XCTAssertEqual(id, 232)
    }

    func testEverySuccessorUserVisibleLiteralIsInStringCatalog() throws {
        let appDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: appDirectory.appendingPathComponent("Resources/Localizable.xcstrings"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let keys = [
            "Catalog authentication failed.",
            "Catalog response could not be read.",
            "Catalog service is unavailable.",
            "Check your connection and try again.",
            "JioHotstar",
            "No playable IMDb titles were found.",
            "No titles were found in the selected regions.",
            "Some regions could not be loaded. Showing available titles.",
            "Too many catalog requests. Try again shortly.",
            "ZEE5",
        ]
        XCTAssertEqual(keys.filter { strings[$0] == nil }, [])
    }
}

private actor RegionFetchProbe {
    private(set) var concurrent = 0
    private(set) var maximumConcurrent = 0

    func fetch(
        region: String,
        page: Int,
        candidates: [String: [CatalogCandidate]]
    ) async -> CatalogRegionPageOutcome {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        try? await Task.sleep(nanoseconds: 30_000_000)
        concurrent -= 1
        return .success(CatalogRegionPage(region: region, page: page, totalPages: 1,
                                          candidates: candidates[region] ?? [], failures: []))
    }
}

private actor ResolutionProbe {
    private(set) var concurrent = 0
    private(set) var maximumConcurrent = 0
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func resolve(_ candidate: CatalogCandidate) async -> CatalogExternalIDOutcome {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        concurrent -= 1
        return .resolved(String(format: "tt%07d", candidate.tmdbID))
    }
}

private actor RetryProbe {
    private(set) var count = 0

    func resolveAfterTransientFailure() -> CatalogExternalIDOutcome {
        count += 1
        return count == 1 ? .failure(CatalogFailure(.rateLimited, statusCode: 429)) : .resolved("tt0000074")
    }
}
