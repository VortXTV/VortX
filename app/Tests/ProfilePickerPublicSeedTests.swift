import Foundation
import Combine
import Darwin

// This file is a template. run.sh inserts the actual bounded production declarations below.
// No helper algorithm is reimplemented here. Only image/network/cache-location boundaries are fake.
@MainActor private enum FixtureCacheBoundary {
    static var seedURL: URL?
}

private struct VXPosterImage: Equatable, Sendable {
    let marker: Int
}

@MainActor private enum PosterImageLoader {
    static var images: [String: VXPosterImage] = [:]
    static var loads: [String] = []

    static func cached(_ url: URL, maxPixel: CGFloat = 900) -> VXPosterImage? {
        images[HeroArtworkQualityPolicy.decodedCacheIdentity(url: url, maxPixel: Int(maxPixel))]
    }

    static func load(_ raw: String?, maxPixel: CGFloat = 900) async -> VXPosterImage? {
        guard !Task.isCancelled, let raw, let url = URL(string: raw) else { return nil }
        loads.append(raw)
        return cached(url, maxPixel: maxPixel)
    }
}

/* ACTUAL_META_PREVIEW */

@MainActor private final class HeldCatalog {
    private var response: CheckedContinuation<[MetaPreview], Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    private(set) var started = false
    private(set) var released = false

    func waitForResponse() async -> [MetaPreview] {
        calls += 1
        return await withCheckedContinuation { continuation in
            precondition(response == nil, "the public catalog request must be single-flight")
            response = continuation
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        released = true
        response?.resume(returning: [])
        response = nil
    }
}

@MainActor private enum FixtureCatalogBoundary {
    static var held: HeldCatalog?
    static var requestedOnlyPublicFamily = true
}

@MainActor private struct AddonClient {
    /* ACTUAL_CINEMETA_CONSTANT */

    func catalog(base: String, type: String, id: String, genre: String) async throws -> [MetaPreview] {
        FixtureCatalogBoundary.requestedOnlyPublicFamily =
            FixtureCatalogBoundary.requestedOnlyPublicFamily && base == Self.cinemeta &&
            type == "movie" && id == "top" && genre == "Family"
        guard let held = FixtureCatalogBoundary.held else { return [] }
        return await held.waitForResponse()
    }
}

/* ACTUAL_PUBLIC_MOVIE */

/* ACTUAL_ARTWORK_CLASS */

private struct FixtureMovie {
    let id: String
    let name: String
    let poster: String

    init(_ id: String = "tt12345", _ name: String = "Public Family Movie", _ poster: String? = nil) {
        self.id = id
        self.name = name
        self.poster = poster ?? "https://images.metahub.space/poster/medium/\(id)/img"
    }

    var candidate: ProfilePickerMovie {
        ProfilePickerMovie(id: id, name: name, poster: poster,
                           background: "https://images.metahub.space/background/big/\(id)/img")
    }
}

// Same-file extensions expose actual private members without modifying their implementation.
@MainActor private extension ProfilePickerArtwork {
    static var fixtureByteLimit: Int { publicSeedByteLimit }
    static var fixtureCandidateLimit: Int { candidateLimit }
    static var fixtureLifetime: TimeInterval { publicSeedLifetime }
    static func fixtureValidID(_ value: String) -> Bool { publicMovieID(value) }
    static func fixturePoster(_ value: String?, id: String = "tt12345") -> String { publicPoster(value, id: id) }
    static func fixtureRead() -> [ProfilePickerMovie] { readPublicSeed() }
    static func fixtureWrite(_ entries: [FixtureMovie], preferredID: String? = nil) {
        writePublicSeed(entries.map(\.candidate), preferredID: preferredID)
    }
    static func fixtureWriteRaw(_ entries: [FixtureMovie], version: Int = 1, savedAt: Date = Date()) throws {
        let seed = PublicSeed(version: version, savedAt: savedAt,
                              movies: entries.map { PublicMovie(id: $0.id, name: $0.name, poster: $0.poster) })
        guard let url = FixtureCacheBoundary.seedURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(seed).write(to: url, options: .atomic)
    }
    static func fixtureMake() -> ProfilePickerArtwork { ProfilePickerArtwork() }
    func fixtureDrainCatalog() async { _ = await catalogRequest?.value }
}

private struct FixtureFailure: Error {
    let message: String
}

@MainActor private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(message: message) }
}

@MainActor private final class Completion {
    var returned = false
}

@main private enum ProfilePickerPublicSeedTests {
    @MainActor static func main() async {
        // A hung/changed extraction must not occupy root's compiler slot indefinitely. This is
        // a bounded test watchdog, not an app timer or a performance threshold.
        let watchdog = Task.detached {
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            FileHandle.standardError.write(Data("FAIL fixture watchdog expired\n".utf8))
            exit(124)
        }
        defer { watchdog.cancel() }
        do {
            guard CommandLine.arguments.count == 2 else { throw FixtureFailure(message: "supply a disposable cache-file path") }
            let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            try check(url.path.contains("/profile-picker-public-seed.") && url.lastPathComponent == "public-seed.json",
                      "cache path must belong to this runner's retained receipt")
            FixtureCacheBoundary.seedURL = url
            try identityAndPosterCases()
            try cacheReadCases(url)
            try cacheWriteCases(url)
            try await warmLoadCase()
            print("PASS actual picker public ID/poster sanitization, bounded seed persistence, TTL/schema/corruption and held-catalog warm return")
        } catch let failure as FixtureFailure {
            FileHandle.standardError.write(Data("FAIL \(failure.message)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("FAIL fixture file operation: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func identityAndPosterCases() throws {
        try check(ProfilePickerArtwork.fixtureCandidateLimit == 12, "public candidate floor/cap changed")
        try check(ProfilePickerArtwork.fixtureByteLimit == 32_768, "public metadata byte cap changed")
        try check(ProfilePickerArtwork.fixtureLifetime == 30 * 24 * 60 * 60, "seed TTL changed")
        try check(Int(ProfilePickerArtwork.artworkMaxPixel) == HeroArtworkQualityPolicy.mobileLongEdge,
                  "macOS extraction must retain the existing non-TV decode cap")
        for valid in ["tt12345", "tt0111161", "tt123456789012"] {
            try check(ProfilePickerArtwork.fixtureValidID(valid), "valid public IMDb identifier rejected: \(valid)")
        }
        for invalid in ["", "tt", "tt1234", "tt1234567890123", "TT12345", "tt１２３４５", "tt1234x",
                        " tt12345", "tt12345 ", "tt12345:1:1", "tt12345/../secret", "tt12345?token=secret"] {
            try check(!ProfilePickerArtwork.fixtureValidID(invalid), "non-public identifier admitted: \(invalid)")
        }
        let fallback = "https://images.metahub.space/poster/medium/tt12345/img"
        for valid in [fallback, "https://live.metahub.space/poster/medium/tt12345/img",
                      "https://image.tmdb.org/t/p/w500/public.jpg",
                      "HTTPS://IMAGE.TMDB.ORG/t/p/w500/public.jpg",
                      "https://image.tmdb.org:443/t/p/w500/public.jpg"] {
            try check(ProfilePickerArtwork.fixturePoster(valid) == valid, "public poster URL changed unnecessarily")
        }
        let rejected: [String?] = [nil, "", "http://image.tmdb.org/t/p/w500/public.jpg",
            "https://unknown.invalid/poster.jpg", "https://images.metahub.space.evil.invalid/poster.jpg",
            "https://user@images.metahub.space/poster/medium/tt12345/img",
            "https://user:secret@images.metahub.space/poster/medium/tt12345/img",
            "https://image.tmdb.org/t/p/w500/public.jpg?token=secret",
            "https://image.tmdb.org/t/p/w500/public.jpg#secret",
            "https://image.tmdb.org:444/t/p/w500/public.jpg",
            "https://image.tmdb.org/" + String(repeating: "a", count: 2_049)]
        for raw in rejected {
            try check(ProfilePickerArtwork.fixturePoster(raw) == fallback,
                      "unknown/credential/query/fragment/non-HTTPS poster survived sanitization")
        }
        let movie = FixtureMovie().candidate
        try check(movie.artworkURLs.first == movie.background, "normal landscape-first rotation quality order changed")
        try check(movie.firstPaintArtworkURLs.first == movie.poster, "initial first-paint poster order is missing")
        print("PASS public IDs, public-only poster sanitization and first-paint/rotation quality split")
    }

    @MainActor private static func cacheReadCases(_ url: URL) throws {
        let one = FixtureMovie()
        try ProfilePickerArtwork.fixtureWriteRaw([one])
        try check(ProfilePickerArtwork.fixtureRead().map(\.id) == [one.id], "valid public seed did not round-trip")
        for version in [0, 2, -1] {
            try ProfilePickerArtwork.fixtureWriteRaw([one], version: version)
            try check(ProfilePickerArtwork.fixtureRead().isEmpty, "unsupported cache schema was accepted")
        }
        try ProfilePickerArtwork.fixtureWriteRaw([one], savedAt: Date().addingTimeInterval(120))
        try check(ProfilePickerArtwork.fixtureRead().isEmpty, "future cache timestamp was accepted")
        try ProfilePickerArtwork.fixtureWriteRaw([one], savedAt: Date().addingTimeInterval(30))
        try check(ProfilePickerArtwork.fixtureRead().count == 1, "bounded clock skew should not poison the public cache")
        try ProfilePickerArtwork.fixtureWriteRaw([one], savedAt: Date().addingTimeInterval(-ProfilePickerArtwork.fixtureLifetime - 60))
        try check(ProfilePickerArtwork.fixtureRead().isEmpty, "expired public catalog seed was accepted")
        try ProfilePickerArtwork.fixtureWriteRaw([one], savedAt: Date().addingTimeInterval(-ProfilePickerArtwork.fixtureLifetime + 60))
        try check(ProfilePickerArtwork.fixtureRead().count == 1, "unexpired public catalog seed was rejected")

        let thirteen = (0..<13).map { FixtureMovie("tt\(1_000_000 + $0)", "Public \($0)") }
        try ProfilePickerArtwork.fixtureWriteRaw(thirteen)
        try check(ProfilePickerArtwork.fixtureRead().isEmpty, "oversized candidate array must fail closed")
        let twelve = Array(thirteen.prefix(12))
        try ProfilePickerArtwork.fixtureWriteRaw(twelve)
        try check(ProfilePickerArtwork.fixtureRead().count == 12, "bounded public pool was rejected")
        let mixed = [FixtureMovie("tt12345", " First Public Name "), FixtureMovie("tt12345", "Duplicate"),
                     FixtureMovie("tt56789", "   \n"), FixtureMovie("not-an-imdb-id", "Private-shaped ID"),
                     FixtureMovie("tt23456", String(repeating: "x", count: 801)),
                     FixtureMovie("tt34567", "Other Public Name", "https://unknown.invalid/secret?token=secret")]
        try ProfilePickerArtwork.fixtureWriteRaw(mixed)
        let read = ProfilePickerArtwork.fixtureRead()
        try check(read.map(\.id) == ["tt12345", "tt34567"], "reader failed ID/name validation or duplicate suppression")
        try check(read.first?.name == "First Public Name", "reader must trim, preserving the first valid public name")
        try check(read.last?.poster == "https://images.metahub.space/poster/medium/tt34567/img",
                  "reader must sanitize even a locally altered cache")

        for corrupt in [Data(), Data("{}".utf8), Data("{not-json".utf8), Data([0xff, 0xfe, 0x00])] {
            try corrupt.write(to: url, options: .atomic)
            try check(ProfilePickerArtwork.fixtureRead().isEmpty, "corrupt/empty metadata must fail closed")
        }
        try ProfilePickerArtwork.fixtureWriteRaw([one])
        var oversized = try Data(contentsOf: url)
        oversized.append(Data(repeating: 0x20, count: ProfilePickerArtwork.fixtureByteLimit + 1))
        try oversized.write(to: url, options: .atomic)
        try check(ProfilePickerArtwork.fixtureRead().isEmpty, "oversized otherwise-valid JSON must fail before decode")
        let absent = url.deletingLastPathComponent().appendingPathComponent("never-created.json")
        FixtureCacheBoundary.seedURL = absent
        try check(ProfilePickerArtwork.fixtureRead().isEmpty, "missing cache should fall back to a public request")
        FixtureCacheBoundary.seedURL = nil
        try check(ProfilePickerArtwork.fixtureRead().isEmpty, "unavailable Caches directory should be cosmetic")
        ProfilePickerArtwork.fixtureWrite([one])
        FixtureCacheBoundary.seedURL = url
        print("PASS actual seed read: schema, TTL, bounded skew/count/bytes, duplicate/entry validation and corrupt/missing file")
    }

    @MainActor private static func cacheWriteCases(_ url: URL) throws {
        let twenty = (0..<20).map { FixtureMovie("tt\(2_000_000 + $0)", "Public \($0)") }
        ProfilePickerArtwork.fixtureWrite(twenty, preferredID: twenty.last?.id)
        let bounded = ProfilePickerArtwork.fixtureRead()
        try check(bounded.count == 12 && bounded.first?.id == twenty.last?.id,
                  "writer must prioritize the public seed then bound the persisted pool")
        let dirty = [FixtureMovie("tt12345", " Kept ", "https://user:secret@unknown.invalid/private?token=secret"),
                     FixtureMovie("tt12345", "Duplicate"), FixtureMovie("tt1234", "Invalid ID"),
                     FixtureMovie("tt23456", " \n"), FixtureMovie("tt34567", String(repeating: "x", count: 801))]
        ProfilePickerArtwork.fixtureWrite(dirty)
        let sanitized = ProfilePickerArtwork.fixtureRead()
        try check(sanitized.count == 1 && sanitized.first?.name == "Kept", "writer failed public metadata validation")
        let bytes = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        try check(Set(object?.keys.map { $0 } ?? []) == Set(["version", "savedAt", "movies"]),
                  "seed envelope acquired an owner/account preference field")
        let records = object?["movies"] as? [[String: Any]]
        try check(records?.count == 1 && Set(records?.first?.keys.map { $0 } ?? []) == Set(["id", "name", "poster"]),
                  "seed movie acquired background/private/profile metadata")
        let text = String(decoding: bytes, as: UTF8.self)
        try check(!text.contains("secret") && !text.contains("unknown.invalid"), "credential-bearing URL was persisted")

        let prefix = "https://image.tmdb.org/t/p/w500/"
        let longURL = prefix + String(repeating: "a", count: 2_048 - prefix.utf8.count)
        let huge = (0..<12).map { FixtureMovie("tt\(3_000_000 + $0)", String(repeating: "x", count: 800), longURL) }
        ProfilePickerArtwork.fixtureWrite(huge)
        let afterOversizedWrite = try Data(contentsOf: url)
        let storedSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try check(afterOversizedWrite == bytes, "byte-oversized write must preserve the previous valid cache")
        try check(storedSize <= ProfilePickerArtwork.fixtureByteLimit,
                  "writer exceeded the metadata byte cap")
        print("PASS actual seed write: preference order, 12-entry/32-KiB cap, public fields only and no credential/private URL persistence")
    }

    @MainActor private static func warmLoadCase() async throws {
        let seed = FixtureMovie("tt76543", "Warm Public Family Movie")
        ProfilePickerArtwork.fixtureWrite([seed])
        let artwork = ProfilePickerArtwork.fixtureMake()
        try check(artwork.movie?.id == seed.id, "public seed must be visible synchronously at construction")
        let held = HeldCatalog()
        FixtureCatalogBoundary.held = held
        let completion = Completion()
        let task = Task { @MainActor in
            await artwork.load()
            completion.returned = true
        }
        await held.waitForStart()
        // A bounded actor-turn budget, not a UI latency claim. The catalog continuation stays held.
        for _ in 0..<500 {
            if completion.returned { break }
            await Task.yield()
        }
        guard completion.returned else {
            held.release()
            await task.value
            throw FixtureFailure(message: "warm load waited for the held catalog")
        }
        try check(!held.released, "catalog was released before proving the early return")
        try check(artwork.movie?.id == seed.id && PosterImageLoader.loads.isEmpty,
                  "metadata-only warm load must not force an image preload or replace the public seed")
        await artwork.load()
        try check(held.calls == 1, "warm load started a second catalog task")
        try check(FixtureCatalogBoundary.requestedOnlyPublicFamily, "pre-profile request escaped the fixed public Family catalog")
        held.release()
        await task.value
        await artwork.fixtureDrainCatalog()
        try check(artwork.movie?.id == seed.id, "empty refresh must not clear already-visible public metadata")
        artwork.stopRotation()
        FixtureCatalogBoundary.held = nil
        print("PASS actual load: synchronous public seed and return before unresolved public catalog, single request, no forced image load")
    }
}
