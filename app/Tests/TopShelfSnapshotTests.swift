// TopShelfSnapshotTests: a standalone, runnable verification of the Apple TV Top Shelf hand-off
// contract, `SourcesShared/TopShelfSnapshot.swift`: the deep-link parser (an OPEN door that any app on
// the device can push URLs through), the link builder, and the payload's Codable round-trip.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// exactly like app/Tests/StreamRankingChipsTests.swift and app/Tests/HouseholdCryptoTests.swift, this is
// a self-contained Swift executable that runs directly with the system toolchain.
//
// UNLIKE those two, this one does NOT re-implement the surface under test: it compiles the REAL
// TopShelfSnapshot.swift alongside it, so there is no second copy to drift out of lockstep. That is
// possible precisely because that file is deliberately Foundation-only and free of every VortX type
// (which is also what keeps the extension's compile surface at one file). Run it with:
//
//     swiftc -O app/SourcesShared/TopShelfSnapshot.swift app/Tests/TopShelfSnapshotTests.swift \
//         -o /tmp/topshelf-tests && /tmp/topshelf-tests
//
// Outside an app bundle there is no App Group container and no Info.plist, so `containerURL` is nil and
// `urlScheme` falls back to "vortx". Both are the documented degrade paths, so the parser and the codec
// are exercised exactly as they run on device; the file I/O half is covered by the on-device check
// (play something, then look at the tvOS Home screen).

import Foundation

// `@main` rather than the top-level script style the other two test files use: those are ONE file run
// with `swift <file>`, where top-level code is legal. This one compiles the real TopShelfSnapshot.swift
// beside it, and in a multi-file build top-level code has no home, so the entry point is explicit.
@main
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

// MARK: Degrade path

section("degrades safely with no usable App Group container")

// This host is macOS, where `containerURL(forSecurityApplicationGroupIdentifier:)` hands back a
// ~/Library/Group Containers path REGARDLESS of entitlements, so it is deliberately not asserted nil
// here: on iOS/tvOS the same call returns nil when the group is not provisioned (the unsigned-build /
// Lite case the writer relies on), and this executable cannot stand in for that. What IS asserted is
// the property that has to hold either way, and it holds under BOTH shapes of the failure: no
// container at all, and a container path whose directory does not exist. Reading and writing must
// fail soft, never throw and never trap.
check(TopShelfSnapshot.read().isEmpty, "read returns [] rather than throwing when there is no snapshot")
check(TopShelfSnapshot.write(items) == false, "write to an unusable container is a silent no-op rather than a crash")

// MARK: Result

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED: \(failures)")
    exit(1)
}
print("OK")

    }
}
