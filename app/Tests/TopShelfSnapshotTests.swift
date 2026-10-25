// TopShelfSnapshotTests: a standalone, runnable verification of the Apple TV Top Shelf hand-off
// contract, `SourcesShared/TopShelfSnapshot.swift`: the deep-link parser (an OPEN door that any app on
// the device can push URLs through), the link builder, and the payload's Codable round-trip.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per the repository guide), so,
// exactly like app/Tests/StreamRankingChipsTests.swift and app/Tests/HouseholdCryptoTests.swift, this is
// a self-contained Swift executable that runs directly with the system toolchain.
//
// UNLIKE those two, this one does NOT re-implement the surface under test: it compiles the REAL
// TopShelfSnapshot.swift alongside it, so there is no second copy to drift out of lockstep. That is
// possible precisely because that file is deliberately Foundation-only and free of every VortX type
// (which is also what keeps the extension's compile surface at one file). Run it with:
//
//     mkdir -p app/build/top-shelf-tests
//     swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
//         -target arm64-apple-macosx14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//         app/SourcesShared/TopShelfSnapshot.swift app/Tests/TopShelfSnapshotTests.swift \
//         -o app/build/top-shelf-tests/top-shelf
//     (cd app/build/top-shelf-tests && ./top-shelf)
//
// These fixtures never resolve or touch a real App Group/container or local preferences. Explicit
// disposable file/directory URLs exercise the real bounded reader/writer and pure artwork paths.
// The harness runs with a private working directory; use that explicit base instead of Foundation's
// temporaryDirectory, which can resolve to the user's system temporary folder despite TMPDIR.
// URL-scheme fallback is exercised outside an app bundle. Platform rendering is a separate gate.

import Foundation

// `@main` rather than the top-level script style the other two test files use: those are ONE file run
// with `swift <file>`, where top-level code is legal. This one compiles the real TopShelfSnapshot.swift
// beside it, and in a multi-file build top-level code has no home, so the entry point is explicit.
@main
@MainActor
enum TopShelfSnapshotTests {

    static var failures = 0
    static var checks = 0

    static func check(_ condition: Bool, _ what: String) {
        checks += 1
        if condition {
            print("  ok    \(what)")
        } else {
            failures += 1
            print("  FAIL  \(what)")
        }
    }

    static func section(_ title: String) { print("\n\(title)") }

    static func main() {

// MARK: Link builder

section("openURL builds a link the parser accepts")

let built = TopShelfSnapshot.openURL(type: "movie", id: "tt0111161")
check(built != nil, "openURL returns a URL")
check(built?.scheme == "vortx", "openURL uses the bundle scheme (fallback 'vortx' outside a bundle)")
check(TopShelfSnapshot.parse(built!) == .open(type: "movie", id: "tt0111161"),
      "a built link round-trips back through parse")

// MARK: Parser, happy paths

section("parse accepts what the shelf emits")

check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie&id=tt0111161")!) == .open(type: "movie", id: "tt0111161"),
      "movie link parses")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=series&id=tt0903747")!) == .open(type: "series", id: "tt0903747"),
      "series link parses")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?id=tt0111161&type=movie")!) == .open(type: "movie", id: "tt0111161"),
      "query order does not matter")
check(TopShelfSnapshot.parse(URL(string: "VORTX://open?type=MOVIE&id=tt0111161")!) == .open(type: "movie", id: "tt0111161"),
      "scheme and type match case-insensitively, and type normalizes to lowercase")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie&id=tmdb:1396")!) == .open(type: "movie", id: "tmdb:1396"),
      "a non-imdb id scheme survives intact")

// MARK: Parser, rejection

section("parse rejects everything else")

check(TopShelfSnapshot.parse(URL(string: "https://vortx.tv/open?type=movie&id=tt1")!) == nil,
      "a foreign scheme is ignored")
check(TopShelfSnapshot.parse(URL(string: "vortx-lite://open?type=movie&id=tt1")!) == nil,
      "the Lite scheme is not accepted by the Full app (side-by-side installs stay separate)")
check(TopShelfSnapshot.parse(URL(string: "vortx://play?type=movie&id=tt1")!) == nil,
      "an unknown host is ignored")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie")!) == nil, "a missing id is rejected")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?id=tt1")!) == nil, "a missing type is rejected")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie&id=")!) == nil, "an empty id is rejected")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie&id=%20%20")!) == nil,
      "a whitespace-only id is rejected rather than opening a blank page")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=channel&id=tt1")!) == nil,
      "a type the shelf never emits is rejected")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=../../etc&id=tt1")!) == nil,
      "a hostile type is rejected by the allow-list rather than passed to the engine")

let longID = String(repeating: "a", count: 5000)
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie&id=\(longID)")!) == nil,
      "an unbounded id is rejected")

// REGRESSION: any app on the device can send us a URL, and a repeated query name is legal in one.
// Building the query dictionary with Dictionary(uniqueKeysWithValues:) TRAPS on a duplicate key, so
// this exact input used to be a remote crash. It must parse (first value wins) or be rejected, never
// take the process down.
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie&id=tt1&id=tt2")! ) == .open(type: "movie", id: "tt1"),
      "a duplicated query key does not trap, and the first value wins")
check(TopShelfSnapshot.parse(URL(string: "vortx://open?type=movie&type=series&id=tt1")!) == .open(type: "movie", id: "tt1"),
      "a duplicated type does not trap either")

// MARK: Payload codec

section("payload round-trips and rejects a foreign version")

let items = [
    TopShelfSnapshot.Item(id: "tt0111161", type: "movie", title: "A Title", poster: "https://img/1.jpg", progress: 0.42),
    TopShelfSnapshot.Item(id: "tt0903747", type: "series", title: "Another", poster: nil, progress: 0.0),
]
let payload = TopShelfSnapshot.Payload(version: TopShelfSnapshot.currentVersion, writtenAt: Date(), items: items)

section("system shelf identity retains the content type")
let sharedMovie = TopShelfSnapshot.Item(id: "shared:id", type: "movie", title: "Movie", poster: nil, progress: 0)
let sharedSeries = TopShelfSnapshot.Item(id: "shared:id", type: "series", title: "Series", poster: nil, progress: 0)
check(sharedMovie.shelfIdentifier != sharedSeries.shelfIdentifier,
      "movie and series sharing a provider id have distinct system identifiers")
let sharedMovieRefresh = TopShelfSnapshot.Item(id: "shared:id", type: "movie", title: "Updated title", poster: "https://img/new.jpg", progress: 0.9)
check(sharedMovie.shelfIdentifier == sharedMovieRefresh.shelfIdentifier,
      "system identity is stable when title, artwork and progress change")
check(sharedMovie.id == sharedSeries.id, "system identity does not rewrite provider ids")
check(TopShelfSnapshot.parse(TopShelfSnapshot.openURL(type: sharedSeries.type, id: sharedSeries.id)!) == .open(type: "series", id: "shared:id"),
      "namespaced system identity leaves detail actions on the original provider id")
let delimiterType = TopShelfSnapshot.Item(id: "c", type: "a:b", title: "One", poster: nil, progress: 0)
let delimiterID = TopShelfSnapshot.Item(id: "b:c", type: "a", title: "Two", poster: nil, progress: 0)
check(delimiterType.shelfIdentifier != delimiterID.shelfIdentifier,
      "length-prefixing prevents type/id delimiter ambiguity")

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

if let data = try? encoder.encode(payload), let back = try? decoder.decode(TopShelfSnapshot.Payload.self, from: data) {
    check(back.items == items, "items survive an encode/decode round-trip, including a nil poster")
    check(back.version == TopShelfSnapshot.currentVersion, "version survives the round-trip")
} else {
    check(false, "payload encodes and decodes")
}

// A future/past schema must be unreadable rather than mis-rendered: the reader's version gate turns it
// into "no content", which shows the static Top Shelf image.
if let data = try? encoder.encode(TopShelfSnapshot.Payload(version: 99, writtenAt: Date(), items: items)),
   let foreign = try? decoder.decode(TopShelfSnapshot.Payload.self, from: data) {
    check(foreign.version != TopShelfSnapshot.currentVersion, "a foreign version decodes but does not match the gate")
} else {
    check(false, "foreign-version payload decodes for the gate check")
}

// MARK: Managed private artwork path

section("private Trakt artwork gets an exact managed App Group file URL")

let traktArtworkSource = "https://media.trakt.tv/images/movies/000/001/posters/medium/poster.jpg.webp"
let syntheticContainer = URL(fileURLWithPath: "/synthetic-vortx-top-shelf", isDirectory: true)
let syntheticArtwork = syntheticContainer.appendingPathComponent(TopShelfSnapshot.artworkDirectoryName, isDirectory: true)
if let managed = TopShelfSnapshot.localArtworkURL(for: traktArtworkSource, in: syntheticArtwork) {
    let managedRoot = syntheticArtwork.path
    check(managed.path.hasPrefix(managedRoot + "/"), "private artwork stays below the exact managed App Group directory")
    check(managed.pathExtension == "webp", "the managed file preserves a safe image extension")
    check(TopShelfSnapshot.localArtworkURL(for: traktArtworkSource, in: syntheticArtwork) == managed,
          "the same source URL maps to a stable local file")
    check(TopShelfSnapshot.localArtworkURL(for: "https://media.trakt.tv/images/movies/000/002/posters/medium/poster.jpg.webp", in: syntheticArtwork) != managed,
          "different source URLs do not collide in the managed path")
} else {
    check(false, "pure synthetic artwork path is available without an App Group lookup")
}

// MARK: Private publication policy

section("private publication policy separates progress from artwork ownership")

let stableArtwork = [
    TopShelfSnapshot.PrivatePublicationPolicy.ArtworkInput(
        id: "tt0111161",
        type: "movie",
        poster: traktArtworkSource
    )
]
let changedProgress = [
    TopShelfSnapshot.Item(
        id: "tt0111161",
        type: "movie",
        title: "A Title",
        poster: nil,
        progress: 0.88
    )
]
let previouslyPublished = [
    TopShelfSnapshot.Item(
        id: "tt0111161",
        type: "movie",
        title: "A Title",
        poster: "file:///private/var/top-shelf-artwork/poster.webp",
        progress: 0.42
    )
]
check(
    !TopShelfSnapshot.PrivatePublicationPolicy.requiresWarmRestart(
        previousSessionRaw: "session-a",
        currentSessionRaw: "session-a",
        previousArtworkInputs: stableArtwork,
        currentArtworkInputs: stableArtwork
    ),
    "a progress-only refresh does not restart artwork warming"
)
let mergedProgress = TopShelfSnapshot.PrivatePublicationPolicy.mergingCurrentProgress(
    pending: changedProgress,
    previouslyPublished: previouslyPublished
)
check(mergedProgress.first?.progress == 0.88, "a progress-only refresh publishes the new progress")
check(mergedProgress.first?.poster == previouslyPublished.first?.poster,
      "a progress-only refresh preserves the managed local poster")
check(
    TopShelfSnapshot.PrivatePublicationPolicy.requiresWarmRestart(
        previousSessionRaw: "session-a",
        currentSessionRaw: "session-a",
        previousArtworkInputs: stableArtwork,
        currentArtworkInputs: [
            .init(id: "tt0111161", type: "movie", poster: "https://media.trakt.tv/images/movies/changed.webp")
        ]
    ),
    "an artwork URL change restarts warming and permits bounded cache pruning"
)

section("private auth boundaries cannot clear a newer session or local rows")

check(
    !TopShelfSnapshot.PrivatePublicationPolicy.shouldClearObsoletePrivateOwner(
        emittedSessionRaw: "session-old",
        currentSessionRaw: "session-new",
        privateOwnerRaw: "session-new",
        publishedPrivateRows: true
    ),
    "an old auth-boundary event cannot clear a newer private publication"
)
check(
    TopShelfSnapshot.PrivatePublicationPolicy.shouldClearObsoletePrivateOwner(
        emittedSessionRaw: "session-new",
        currentSessionRaw: "session-new",
        privateOwnerRaw: "session-old",
        publishedPrivateRows: true
    ),
    "a current boundary clears an obsolete private owner"
)
check(
    !TopShelfSnapshot.PrivatePublicationPolicy.shouldClearObsoletePrivateOwner(
        emittedSessionRaw: "session-new",
        currentSessionRaw: "session-new",
        privateOwnerRaw: "session-old",
        publishedPrivateRows: false
    ),
    "a current Trakt boundary leaves local overlay rows intact"
)

section("private image response policy bounds redirects and bytes")

check(
    TopShelfSnapshot.PrivatePublicationPolicy.acceptsArtworkResponse(
        finalURLIsFirstParty: true,
        statusCode: 200,
        mimeType: "image/webp",
        expectedContentLength: 64,
        accumulatedBytes: 64
    ),
    "a bounded first-party image response is accepted"
)
check(
    !TopShelfSnapshot.PrivatePublicationPolicy.acceptsArtworkResponse(
        finalURLIsFirstParty: false,
        statusCode: 200,
        mimeType: "image/webp",
        expectedContentLength: 64,
        accumulatedBytes: 64
    ),
    "a redirect whose final URL is not first-party is rejected"
)
check(
    !TopShelfSnapshot.PrivatePublicationPolicy.acceptsArtworkResponse(
        finalURLIsFirstParty: true,
        statusCode: 200,
        mimeType: "image/webp",
        expectedContentLength: Int64(TopShelfSnapshot.maxArtworkBytes) + 1,
        accumulatedBytes: 1
    ),
    "a declared body larger than the cap is rejected before reading"
)
check(
    !TopShelfSnapshot.PrivatePublicationPolicy.acceptsArtworkResponse(
        finalURLIsFirstParty: true,
        statusCode: 200,
        mimeType: "image/webp",
        expectedContentLength: nil,
        accumulatedBytes: TopShelfSnapshot.maxArtworkBytes + 1
    ),
    "an unknown-length body crossing the cap is rejected"
)
check(
    !TopShelfSnapshot.PrivatePublicationPolicy.acceptsArtworkResponse(
        finalURLIsFirstParty: true,
        statusCode: 200,
        mimeType: "text/html",
        expectedContentLength: 64,
        accumulatedBytes: 64
    ),
    "a non-image response is rejected"
)

// MARK: Bounded local-file snapshot fixtures

section("untrusted progress obeys the system shelf's inclusive 0...1 contract")

let managedPoster = syntheticArtwork.appendingPathComponent("fixture.webp").absoluteString
let progressPosters: [String?] = [nil, "https://fixture.invalid/poster.jpg", managedPoster, "http://fixture.invalid/poster.jpg"]
for poster in progressPosters {
    for progress in [-Double.infinity, -Double.leastNonzeroMagnitude, -0.5, 1.0.nextUp, 1.5, Double.infinity, Double.nan] {
        let row = TopShelfSnapshot.Item(id: "tt-progress", type: "movie", title: "Progress", poster: poster, progress: progress)
        check(TopShelfSnapshot.displayable(row, artworkDirectory: syntheticArtwork) == nil,
              "out-of-range or non-finite progress is rejected before every poster branch")
    }
    for progress in [0.0, 0.5, 1.0] {
        let row = TopShelfSnapshot.Item(id: "tt-progress", type: "movie", title: "Progress", poster: poster, progress: progress)
        let shown = TopShelfSnapshot.displayable(row, artworkDirectory: syntheticArtwork)
        let expectedPoster = poster?.hasPrefix("http:") == true ? nil : poster
        check(shown == TopShelfSnapshot.Item(id: row.id, type: row.type, title: row.title,
                                             poster: expectedPoster, progress: progress),
              "valid progress including both endpoints retains the original row and artwork policy")
    }
}

section("snapshot reads and writes use only a disposable local directory")

do {
    let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let directory = fixtureRoot.appendingPathComponent("vortx-top-shelf-bounds-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("snapshot.json", isDirectory: false)
    let missing = directory.appendingPathComponent("absent.json", isDirectory: false)
    let eight = (0..<TopShelfSnapshot.maxItems).map { index in
        TopShelfSnapshot.Item(id: "tmdb:\(index)", type: index.isMultiple(of: 2) ? "movie" : "series",
            title: "Title \(index) — नमस्ते", poster: index.isMultiple(of: 2) ? "https://fixture.invalid/poster/\(index).jpg" : directory.appendingPathComponent("top-shelf-artwork/private-poster-\(index).webp").absoluteString,
            progress: Double(index) / 8)
    }
    check(TopShelfSnapshot.read(from: missing).isEmpty, "an absent explicit fixture returns no content")
    check(TopShelfSnapshot.read(from: directory).isEmpty, "a directory is rejected before opening for snapshot bytes")
    check(TopShelfSnapshot.read(from: URL(string: "https://fixture.invalid/snapshot.json")!).isEmpty,
          "a non-file URL is rejected without a network reader")
    check(!TopShelfSnapshot.write(items, to: directory.appendingPathComponent("missing-parent/snapshot.json")),
          "an unusable explicit fixture destination fails softly")
    let wroteEight = TopShelfSnapshot.write(eight, to: file)
    check(wroteEight, "eight complete rows publish to the disposable file")
    if !wroteEight {
        let diagnostic = try encoder.encode(TopShelfSnapshot.Payload(version: TopShelfSnapshot.currentVersion,
            writtenAt: Date(), items: Array(eight.prefix(TopShelfSnapshot.maxItems))))
        try diagnostic.write(to: file, options: .atomic)
        throw NSError(domain: "TopShelfSnapshotTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Diagnostic encode/atomic-write replay succeeded; original write check remains failed"])
    }
    check(TopShelfSnapshot.read(from: file) == eight, "all eight rows preserve ids, types, Unicode titles, poster URLs and progress")
    let untrustedRows = [
        TopShelfSnapshot.Item(id: "tt1", type: "movie", title: "Outside", poster: "file:///etc/hosts", progress: 0),
        TopShelfSnapshot.Item(id: "tt2", type: "movie", title: "Plain", poster: "http://fixture.invalid/p.jpg", progress: 0),
        TopShelfSnapshot.Item(id: "", type: "movie", title: "No id", poster: nil, progress: 0),
    ]
    let untrusted = directory.appendingPathComponent("untrusted.json")
    _ = TopShelfSnapshot.write(untrustedRows, to: untrusted)
    let shown = TopShelfSnapshot.read(from: untrusted)
    check(shown.map(\.id) == ["tt1", "tt2"], "a row whose action does not round-trip through the link parser is not shown")
    check(shown.allSatisfy { $0.poster == nil },
          "a poster outside the managed artwork folder or not https is dropped, the row kept")
    let progressFile = directory.appendingPathComponent("untrusted-progress.json")
    let invalidProgressRows = [
        TopShelfSnapshot.Item(id: "below", type: "movie", title: "Below", poster: nil, progress: -0.01),
        TopShelfSnapshot.Item(id: "above", type: "series", title: "Above", poster: "https://fixture.invalid/poster.jpg", progress: 1.01),
    ]
    let progressBytes = try encoder.encode(TopShelfSnapshot.Payload(version: TopShelfSnapshot.currentVersion,
        writtenAt: Date(), items: invalidProgressRows + items))
    try progressBytes.write(to: progressFile)
    check(TopShelfSnapshot.read(from: progressFile) == items,
          "the actual bounded file reader excludes corrupt progress without discarding valid neighboring rows")
    let progressResult = TopShelfSnapshot.readResult(from: progressFile)
    check(progressResult.status == .ready && progressResult.items == items,
          "diagnostic and compatibility readers enforce the same progress contract")
    check(try Data(contentsOf: progressFile) == progressBytes,
          "rejecting corrupt progress does not rewrite, normalize or delete saved cache bytes")
    let original = try Data(contentsOf: file)
    check(!TopShelfSnapshot.write(eight, to: file), "unchanged readable content does not rewrite the cache")
    check(try Data(contentsOf: file) == original, "unchanged publication preserves exact cache bytes")

    let link = directory.appendingPathComponent("snapshot-link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    check(TopShelfSnapshot.read(from: link).isEmpty, "a symbolic-link snapshot is rejected")
    check(try Data(contentsOf: file) == original, "rejecting a link leaves its regular target intact")

    var exact = original
    exact.append(Data(repeating: 0x20, count: TopShelfSnapshot.maxSnapshotBytes - exact.count))
    try exact.write(to: file)
    check(TopShelfSnapshot.read(from: file) == eight, "valid JSON exactly at the byte ceiling is accepted")
    var oversized = exact; oversized.append(0x20)
    try oversized.write(to: file)
    check(TopShelfSnapshot.read(from: file).isEmpty, "even valid JSON one byte over the ceiling is rejected")
    check(try Data(contentsOf: file) == oversized, "an oversized read never deletes or repairs cache bytes")
    check(TopShelfSnapshot.write([], to: file), "an explicit empty publication clears an unreadable oversized cache")
    check(TopShelfSnapshot.read(from: file).isEmpty, "the explicit clear reads back as empty")
    let cleared = try decoder.decode(TopShelfSnapshot.Payload.self, from: Data(contentsOf: file))
    check(cleared.version == TopShelfSnapshot.currentVersion && cleared.items.isEmpty,
          "clear writes a valid current-schema empty payload")

    let nine = eight + [eight[0]]
    let nineBytes = try encoder.encode(TopShelfSnapshot.Payload(version: TopShelfSnapshot.currentVersion, writtenAt: Date(), items: nine))
    try nineBytes.write(to: file)
    check(TopShelfSnapshot.read(from: file).isEmpty, "a ninth item is rejected rather than decoded then silently prefixed")
    check((try? decoder.decode(TopShelfSnapshot.Payload.self, from: nineBytes)) == nil,
          "the actual payload decoder enforces the item bound")
    check(try Data(contentsOf: file) == nineBytes, "too-many-item reads preserve the source bytes")

    for malformed in [Data(), Data([0xff]), Data("{\"version\":1,\"items\":[".utf8)] {
        try malformed.write(to: file)
        check(TopShelfSnapshot.read(from: file).isEmpty, "empty, invalid UTF-8 and torn JSON fail softly")
        check(try Data(contentsOf: file) == malformed, "a malformed read is data-preserving")
    }
    let foreign = try encoder.encode(TopShelfSnapshot.Payload(version: 99, writtenAt: Date(), items: eight))
    try foreign.write(to: file)
    check(TopShelfSnapshot.read(from: file).isEmpty, "a complete foreign schema retains the existing version gate")
    check(try Data(contentsOf: file) == foreign, "a foreign version is not rewritten on read")
    check(TopShelfSnapshot.write(eight, to: file), "a later valid publication replaces an invalid cache normally")
    let huge = TopShelfSnapshot.Item(id: "large", type: "movie", title: String(repeating: "x", count: TopShelfSnapshot.maxSnapshotBytes + 1), poster: nil, progress: 0.5)
    check(TopShelfSnapshot.write([huge], to: file), "a new oversized publication still replaces the prior owner's cache")
    check(TopShelfSnapshot.read(from: file).first?.id == huge.id, "an oversized title remains a current actionable tile, not an unreadable cache")
    let rawHuge = try decoder.decode(TopShelfSnapshot.Payload.self, from: Data(contentsOf: file))
    check(rawHuge.items.first?.title.unicodeScalars.count == TopShelfSnapshot.maxOverflowTitleScalars,
          "overflow compacts only the display title without changing saved history or identity")
    check(try Data(contentsOf: file).count <= TopShelfSnapshot.maxSnapshotBytes,
          "the producer never publishes oversized JSON for the bounded reader")
    let compactBytes = try Data(contentsOf: file)
    check(!TopShelfSnapshot.write([huge], to: file), "an unchanged compact overflow projection does not churn the cache")
    check(try Data(contentsOf: file) == compactBytes, "unchanged overflow preserves exact cache bytes")
    let hugeIdentity = TopShelfSnapshot.Item(id: String(repeating: "i", count: TopShelfSnapshot.maxSnapshotBytes + 1), type: "movie", title: "Identity too large", poster: nil, progress: 0)
    check(TopShelfSnapshot.write([hugeIdentity, items[1]], to: file), "a huge identity does not prevent a later valid current row from replacing old content")
    check(TopShelfSnapshot.read(from: file) == [items[1]], "overflow excludes an unrepresentable row without truncating its action identity")
    check(TopShelfSnapshot.write([hugeIdentity], to: file), "a wholly unrepresentable new owner replaces old content with a valid empty cache")
    check(TopShelfSnapshot.read(from: file).isEmpty, "an overflow-only clear cannot retain previous-owner rows")
    check(TopShelfSnapshot.write(eight, to: file), "a normal publication after overflow restores full original metadata")
    check(TopShelfSnapshot.read(from: file) == eight, "normal titles, artwork and progress are never compacted")
    check(TopShelfSnapshot.write([], to: file), "explicit privacy clear still replaces valid content")

    // Diagnostic outcomes must not change the compatibility reader/writer or valid-empty semantics.
    let diagnosticFile = directory.appendingPathComponent("diagnostic.json")
    check(TopShelfSnapshot.readResult(from: nil).status == .noContainer,
          "an unavailable supplied container is distinguished without a real group lookup")
    check(TopShelfSnapshot.readResult(from: missing).status == .unavailableFile,
          "missing fixture bytes are unavailable, not a valid empty snapshot")
    check(TopShelfSnapshot.readResult(from: directory).status == .invalidFile,
          "directory rejection has a fixed diagnostic status")
    check(TopShelfSnapshot.writeResult(eight, to: diagnosticFile) == .written,
          "a changed successful write is distinguished from unchanged content")
    let ready = TopShelfSnapshot.readResult(from: diagnosticFile)
    check(ready.status == .ready && ready.items == eight,
          "a ready result carries exactly the same bounded rows")
    let diagnosticOriginal = try Data(contentsOf: diagnosticFile)
    check(TopShelfSnapshot.writeResult(eight, to: diagnosticFile) == .unchanged,
          "unchanged is a successful no-op, not a write failure")
    let repeatedWrite = TopShelfSnapshot.write(eight, to: diagnosticFile)
    let afterRepeatedWrite = try Data(contentsOf: diagnosticFile)
    check(!repeatedWrite && afterRepeatedWrite == diagnosticOriginal,
          "the Bool wrapper still returns false and preserves bytes for unchanged content")
    let unencodable = TopShelfSnapshot.Item(id: "fixture", type: "movie", title: "Fixture", poster: nil, progress: .nan)
    check(TopShelfSnapshot.writeResult([unencodable], to: diagnosticFile) == .encodingFailed,
          "encoding rejection has a distinct fixed outcome")
    check(try Data(contentsOf: diagnosticFile) == diagnosticOriginal,
          "encoding rejection preserves the previous file")
    check(TopShelfSnapshot.writeResult(eight, to: directory.appendingPathComponent("absent-parent/diagnostic.json")) == .writeFailed,
          "an atomic-write failure is not mislabeled unchanged")
    check(TopShelfSnapshot.writeResult(eight, to: URL(string: "https://fixture.invalid/diagnostic")!) == .invalidDestination,
          "a non-file destination fails without network I/O")
    try Data("{}".utf8).write(to: diagnosticFile)
    check(TopShelfSnapshot.readResult(from: diagnosticFile).status == .invalidPayload,
          "malformed payload is distinct from valid empty content")
    try foreign.write(to: diagnosticFile)
    check(TopShelfSnapshot.readResult(from: diagnosticFile).status == .unsupportedVersion,
          "a complete foreign version retains its diagnostic and rejection")
    try oversized.write(to: diagnosticFile)
    // Use a never-inspected URL for the metadata branch; the reused URL may cache resource values.
    let diagnosticOversizedFile = directory.appendingPathComponent("diagnostic-oversized.json")
    try oversized.write(to: diagnosticOversizedFile)
    check(TopShelfSnapshot.readResult(from: diagnosticOversizedFile).status == .oversized,
          "metadata-confirmed oversize is distinguished without decoding")
    check(TopShelfSnapshot.writeResult([], to: diagnosticFile) == .written,
          "explicit empty still clears a rejected prior publication")
    let emptyResult = TopShelfSnapshot.readResult(from: diagnosticFile)
    check(emptyResult.status == .empty && emptyResult.items.isEmpty,
          "valid empty is explicitly empty, never invalid or unavailable")
    check(TopShelfSnapshot.writeResult([], to: diagnosticFile) == .unchanged && !TopShelfSnapshot.write([], to: diagnosticFile),
          "repeated explicit empty preserves the original no-change Bool")
} catch {
    check(false, "disposable snapshot fixture failed: \(error)")
}

section("bounded byte collection handles short reads, errors and the sentinel byte")

let shortBytes = try! encoder.encode(payload)
var shortOffset = 0
var shortRequests: [Int] = []
let shortResult = TopShelfSnapshot.boundedSnapshotData { requested in
    shortRequests.append(requested)
    guard shortOffset < shortBytes.count else { return nil }
    let count = min(3, min(requested, shortBytes.count - shortOffset))
    defer { shortOffset += count }
    return shortBytes.subdata(in: shortOffset..<(shortOffset + count))
}
check(shortResult == shortBytes, "partial chunks are collected through EOF without truncating JSON")
check(shortRequests.allSatisfy { $0 > 0 && $0 <= 16 * 1024 }, "each byte request is positive and at most 16 KiB")
var supplied = 0
var oversizeRequests: [Int] = []
let sentinelResult = TopShelfSnapshot.boundedSnapshotData { requested in
    oversizeRequests.append(requested)
    let beforeSentinel = TopShelfSnapshot.maxSnapshotBytes - supplied
    let count = beforeSentinel > 0 ? min(1_003, min(requested, beforeSentinel)) : 1
    supplied += count
    return Data(repeating: 0x20, count: count)
}
check(sentinelResult == nil && supplied == TopShelfSnapshot.maxSnapshotBytes + 1,
      "an unknown/growing-length source is rejected after exactly ceiling plus one supplied bytes")
check(oversizeRequests.last == 1, "the final request is the single oversize sentinel byte")
enum FixtureReadError: Error { case failed }
var failedCalls = 0
check(TopShelfSnapshot.boundedSnapshotData { _ in
    failedCalls += 1
    if failedCalls == 1 { return Data([0x7b]) }
    throw FixtureReadError.failed
} == nil && failedCalls == 2, "an I/O error after a partial chunk does not decode a partial snapshot")
check(TopShelfSnapshot.boundedSnapshotData { _ in Data() } == nil, "an empty first chunk is EOF rather than a retry loop")
check(TopShelfSnapshot.boundedSnapshotData { requested in Data(repeating: 0, count: requested + 1) } == nil,
      "a reader violating its requested byte budget is rejected")

// MARK: App Group under a re-signing service

section("the shared group follows what the signed copy was granted")

let canonicalGroup = TopShelfSnapshot.canonicalAppGroupID
let signerGroup = "group.b0eaaf9ad1ed3ea5.1"
check(TopShelfSnapshot.selectAppGroup(granted: [signerGroup], canonical: canonicalGroup) { $0 == canonicalGroup } == canonicalGroup,
      "the project's own group wins when this copy holds it")
check(TopShelfSnapshot.selectAppGroup(granted: [signerGroup], canonical: canonicalGroup) { $0 == signerGroup } == signerGroup,
      "a re-signed copy uses the group its signer granted instead of finding no container")
let grantedA = ["group.zz.second", signerGroup], grantedB = [signerGroup, "group.zz.second"]
let both = { (id: String) in id == signerGroup || id == "group.zz.second" }
check(TopShelfSnapshot.selectAppGroup(granted: grantedA, canonical: canonicalGroup, hasContainer: both)
      == TopShelfSnapshot.selectAppGroup(granted: grantedB, canonical: canonicalGroup, hasContainer: both),
      "an app and its extension granted the same groups in any order settle on the same one")
check(TopShelfSnapshot.selectAppGroup(granted: ["group.*", "com.example.notagroup"], canonical: canonicalGroup) { _ in true } == canonicalGroup,
      "wildcards and non-group identifiers are never used")
check(TopShelfSnapshot.selectAppGroup(granted: [signerGroup], canonical: canonicalGroup) { _ in false } == nil,
      "no granted container leaves the feature off")

let profilePlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Entitlements</key><dict>
<key>com.apple.security.application-groups</key><array><string>\(signerGroup)</string></array>
</dict></dict></plist>
"""
var envelope = Data([0x30, 0x82, 0x2a, 0x1f, 0x06, 0x09])
envelope.append(Data(profilePlist.utf8))
envelope.append(Data([0xa0, 0x82, 0x0b, 0x00]))
check(TopShelfSnapshot.provisionedAppGroups(profile: envelope) == [signerGroup],
      "groups are read from the plist inside the signed profile envelope")
check(TopShelfSnapshot.provisionedAppGroups(profile: Data([0x30, 0x82, 0x00])).isEmpty,
      "an unreadable profile grants nothing")
check(TopShelfSnapshot.isTopShelfExtension(["NSExtension": ["NSExtensionPointIdentifier": "com.apple.tv-top-shelf"]]),
      "the Top Shelf extension is recognised by its extension point")
check(!TopShelfSnapshot.isTopShelfExtension(["NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]])
      && !TopShelfSnapshot.isTopShelfExtension(nil), "other bundles are not the Top Shelf extension")

// MARK: Result

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED: \(failures)")
    exit(1)
}
print("OK")

    }
}
