// Standalone executable for the decode-failure quarantine shared by the three profile-scoped source stores.
// VortX has no Xcode test bundle, so compile the REAL production store files with minimal dependency stubs:
//
//   xcrun swiftc -o /tmp/store-decode-quarantine-test \
//     app/SourcesShared/LastStreamStore.swift \
//     app/SourcesShared/SourcePin.swift \
//     app/SourcesShared/SavedLinksStore.swift \
//     app/Tests/StoreDecodeQuarantineContractTests.swift && \
//     /tmp/store-decode-quarantine-test
//
// WHAT IS AT STAKE. All three stores decode their persisted blob with `try?` and, on a decode FAILURE, used
// to fall straight to an empty in-memory view. The very next write (`LastStreamStore.record`, any
// `SourcePinStore` pin/unpin/clearAll -> persist, or any `SavedLinksStore` save/remove -> persist) then
// ENCODED that empty view back over the primary key: one unreadable byte silently discarded every remembered
// resume stream / every pinned source / every saved magnet, with nothing left to recover from. The persisted
// shape differs per store - a `[String: Entry]` dict (LastStream), a `Blob` struct (SourcePin), and a bare
// `[Entry]` array (SavedLinks) - but the quarantine wraps the outermost decode identically in all three. The
// fix, ported from SeriesSourceSticky, distinguishes "empty store" from "did not decode": on a decode failure
// it copies the raw bytes to a `<key>.undecodable` sidecar ONCE, before any write can land, emits one
// identifier-free line, and runs the session on the empty view (fail-open).
//
// The contract proven here, against the real production code:
//   1. a corrupt blob does NOT wipe: the sidecar is written and the ORIGINAL bytes are still present until a
//      genuine record/pin write happens;
//   2. that genuine write may overwrite the primary key, but the sidecar copy survives it (recoverable);
//   3. the sidecar is written ONCE - a second decode failure does not overwrite the first, still-original
//      copy with post-wipe bytes;
//   4. a genuinely EMPTY store reads empty WITHOUT quarantining and without emitting a line.

import Foundation
import Combine

// MARK: - Minimal dependency stubs (the real symbols live in other files not compiled into this test)

/// Records every durable line so the test can assert exactly one line per quarantine and that it names no id.
enum DiagnosticsLog {
    nonisolated(unsafe) static var lines: [String] = []
    static func log(_ category: String, _ message: String) { lines.append("[\(category)] \(message)") }
    static func reset() { lines = [] }
}

/// Only `LastStreamStore.logResume` touches this; the quarantine path never calls it, but the file must link.
enum VXProbeRedaction {
    static func identityToken(_ raw: String) -> String { "tok" }
}

/// `SourcePin.activeProfileKey` reads `ProfileStore.shared.activeID?.uuidString`.
final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID?
}

/// `SourcePinStore` calls these three; none touch persistence, so no-op / empty is faithful for this test.
enum StreamRanking {
    static func invalidateCaches() {}
    static func qualityLabel(_ stream: CoreStream) -> String { "" }
    static func releaseFlavor(_ stream: CoreStream) -> String { "" }
}

/// `SourcePinStore.makePin` reads `stream.behaviorHints?.bingeGroup`; the quarantine test never builds one.
struct CoreStream {
    struct BehaviorHints { var bingeGroup: String? }
    var behaviorHints: BehaviorHints?
}

// MARK: - Harness

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func expect(_ condition: Bool, _ what: String) {
    if condition { passed += 1; print("PASS  \(what)") }
    else { failed += 1; print("FAIL  \(what)") }
}

let corruptA = Data("this is not a valid store blob {{{".utf8)
let corruptB = Data("a different unreadable blob ]]]".utf8)

func defaults() -> UserDefaults { UserDefaults.standard }

// MARK: - LastStreamStore contract

@MainActor
func lastStreamContract() {
    let profileID = UUID()   // fresh per run: keys never collide across runs, so the one-time guard is clean
    let primaryKey = "stremiox.lastStream.\(profileID.uuidString)"
    let sidecarKey = primaryKey + ".undecodable"

    // (1) A corrupt blob must NOT be wiped by the mere act of reading it.
    defaults().set(corruptA, forKey: primaryKey)
    defaults().removeObject(forKey: sidecarKey)
    LastStreamStore.invalidateCache()
    DiagnosticsLog.reset()

    let read = LastStreamStore.entry(for: "any-library-id", profileID: profileID)
    expect(read == nil, "LSS-1a: a corrupt store reads as empty for the session (no crash, no entry)")
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "LSS-1b: the raw undecodable bytes are copied to the sidecar")
    expect(defaults().data(forKey: primaryKey) == corruptA,
           "LSS-1c: the ORIGINAL bytes are still at the primary key - a read never overwrote them")
    expect(DiagnosticsLog.lines.count == 1, "LSS-1d: exactly one diagnostic line is emitted")
    let line = DiagnosticsLog.lines.first ?? ""
    expect(line.contains("did not decode") && line.contains("raw bytes kept aside"),
           "LSS-1e: the line says the store did not decode and bytes were kept aside")
    expect(!line.contains(profileID.uuidString),
           "LSS-1f: the line carries no profile id (identifier-free)")

    // (2) A genuine record write may overwrite the primary key, but the sidecar copy survives.
    let entry = LastStreamStore.Entry(videoId: "v", url: "u", title: "t", season: nil, episode: nil,
                                      name: "n", poster: nil, type: "movie", qualityText: nil, savedAt: Date())
    LastStreamStore.record(libraryId: "x", entry: entry, profileID: profileID)
    let afterWrite = defaults().data(forKey: primaryKey)
    let reDecoded = afterWrite.flatMap { try? JSONDecoder().decode([String: LastStreamStore.Entry].self, from: $0) }
    expect(reDecoded?["x"] != nil, "LSS-2a: a genuine record write persists a valid, decodable store")
    expect(afterWrite != corruptA, "LSS-2b: the corrupt bytes are gone from the primary key after a real write")
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "LSS-2c: the sidecar STILL holds the original bytes - the wipe left a recoverable copy")

    // (3) One-time: a second decode failure must not overwrite the still-original sidecar copy.
    defaults().set(corruptB, forKey: primaryKey)
    LastStreamStore.invalidateCache()
    DiagnosticsLog.reset()
    _ = LastStreamStore.entry(for: "any", profileID: profileID)
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "LSS-3a: the sidecar is one-time - the second failure did NOT overwrite the first copy")
    expect(DiagnosticsLog.lines.isEmpty, "LSS-3b: the one-time guard also suppresses a duplicate line")

    // (4) A genuinely empty store reads empty WITHOUT quarantining.
    let emptyID = UUID()
    let emptyPrimary = "stremiox.lastStream.\(emptyID.uuidString)"
    let emptySidecar = emptyPrimary + ".undecodable"
    defaults().removeObject(forKey: emptyPrimary)
    defaults().removeObject(forKey: emptySidecar)
    LastStreamStore.invalidateCache()
    DiagnosticsLog.reset()
    expect(LastStreamStore.entry(for: "any", profileID: emptyID) == nil,
           "LSS-4a: an empty store reads empty")
    expect(defaults().data(forKey: emptySidecar) == nil,
           "LSS-4b: an empty store writes NO sidecar (empty is not a decode failure)")
    expect(DiagnosticsLog.lines.isEmpty, "LSS-4c: an empty store emits no line")

    // Cleanup this run's keys.
    for k in [primaryKey, sidecarKey, emptyPrimary, emptySidecar] { defaults().removeObject(forKey: k) }
}

// MARK: - SourcePinStore contract

@MainActor
func sourcePinContract() {
    let profileID = UUID()
    ProfileStore.shared.activeID = profileID
    let primaryKey = "stremiox.sourcePins.\(profileID.uuidString)"
    let sidecarKey = primaryKey + ".undecodable"
    let store = SourcePinStore.shared

    // (1) A corrupt blob must NOT be wiped by reload().
    defaults().set(corruptA, forKey: primaryKey)
    defaults().removeObject(forKey: sidecarKey)
    DiagnosticsLog.reset()

    store.reload()
    expect(store.entry.isEmpty && store.global == nil,
           "SPS-1a: a corrupt store reloads as empty for the session")
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "SPS-1b: the raw undecodable bytes are copied to the sidecar")
    expect(defaults().data(forKey: primaryKey) == corruptA,
           "SPS-1c: the ORIGINAL bytes are still at the primary key - reload never overwrote them")
    expect(DiagnosticsLog.lines.count == 1, "SPS-1d: exactly one diagnostic line is emitted")
    let line = DiagnosticsLog.lines.first ?? ""
    expect(line.contains("did not decode") && line.contains("raw bytes kept aside"),
           "SPS-1e: the line says the store did not decode and bytes were kept aside")
    expect(!line.contains(profileID.uuidString),
           "SPS-1f: the line carries no profile id (identifier-free)")

    // (2) A genuine write (unpin -> persist) overwrites the primary key, sidecar survives.
    store.unpin(scope: .global, context: SourcePinContext(metaId: "m", isSeries: false))
    let afterWrite = defaults().data(forKey: primaryKey)
    let reDecoded = afterWrite.flatMap { try? JSONDecoder().decode(SourcePinBlobProbe.self, from: $0) }
    expect(reDecoded != nil, "SPS-2a: a genuine pin write persists a valid, decodable store")
    expect(afterWrite != corruptA, "SPS-2b: the corrupt bytes are gone from the primary key after a real write")
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "SPS-2c: the sidecar STILL holds the original bytes - the wipe left a recoverable copy")

    // (3) One-time: a second decode failure must not overwrite the still-original sidecar copy.
    defaults().set(corruptB, forKey: primaryKey)
    DiagnosticsLog.reset()
    store.reload()
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "SPS-3a: the sidecar is one-time - the second failure did NOT overwrite the first copy")
    expect(DiagnosticsLog.lines.isEmpty, "SPS-3b: the one-time guard also suppresses a duplicate line")

    // (4) A genuinely empty store reloads empty WITHOUT quarantining.
    let emptyID = UUID()
    ProfileStore.shared.activeID = emptyID
    let emptyPrimary = "stremiox.sourcePins.\(emptyID.uuidString)"
    let emptySidecar = emptyPrimary + ".undecodable"
    defaults().removeObject(forKey: emptyPrimary)
    defaults().removeObject(forKey: emptySidecar)
    DiagnosticsLog.reset()
    store.reload()
    expect(store.entry.isEmpty && store.global == nil, "SPS-4a: an empty store reloads empty")
    expect(defaults().data(forKey: emptySidecar) == nil,
           "SPS-4b: an empty store writes NO sidecar (empty is not a decode failure)")
    expect(DiagnosticsLog.lines.isEmpty, "SPS-4c: an empty store emits no line")

    for k in [primaryKey, sidecarKey, emptyPrimary, emptySidecar] { defaults().removeObject(forKey: k) }
}

/// A structural probe matching `SourcePinStore.Blob`, to assert the persisted bytes decode as the real shape.
private struct SourcePinBlobProbe: Codable {
    var entry: [String: SourcePin]
    var global: SourcePin?
}

// MARK: - SavedLinksStore contract

/// The third store shares the silent-wipe shape, but its persisted value is a bare `[Entry]` ARRAY (not a
/// dict or a struct), so the quarantine wraps the array decode. The genuine-write probe re-decodes the same
/// array shape to prove `save` persisted valid, recoverable bytes.
@MainActor
func savedLinksContract() {
    let profileID = UUID()   // fresh per run: keys never collide across runs, so the one-time guard is clean
    let primaryKey = "stremiox.savedLinks.\(profileID.uuidString)"
    let sidecarKey = primaryKey + ".undecodable"

    // (1) A corrupt blob must NOT be wiped by the mere act of reading it.
    defaults().set(corruptA, forKey: primaryKey)
    defaults().removeObject(forKey: sidecarKey)
    SavedLinksStore.invalidate(profileID)
    DiagnosticsLog.reset()

    let read = SavedLinksStore.all(profileID: profileID)
    expect(read.isEmpty, "SLS-1a: a corrupt store reads as empty for the session (no crash, no entries)")
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "SLS-1b: the raw undecodable bytes are copied to the sidecar")
    expect(defaults().data(forKey: primaryKey) == corruptA,
           "SLS-1c: the ORIGINAL bytes are still at the primary key - a read never overwrote them")
    expect(DiagnosticsLog.lines.count == 1, "SLS-1d: exactly one diagnostic line is emitted")
    let line = DiagnosticsLog.lines.first ?? ""
    expect(line.contains("did not decode") && line.contains("raw bytes kept aside"),
           "SLS-1e: the line says the store did not decode and bytes were kept aside")
    expect(!line.contains(profileID.uuidString),
           "SLS-1f: the line carries no profile id (identifier-free)")

    // (2) A genuine save write overwrites the primary key, but the sidecar copy survives.
    let entry = SavedLinksStore.Entry(id: "magnet:?xt=urn:btih:abc", link: "magnet:?xt=urn:btih:abc",
                                      name: "n", poster: nil, isMagnet: true, savedAt: Date())
    SavedLinksStore.save(entry, profileID: profileID)
    let afterWrite = defaults().data(forKey: primaryKey)
    let reDecoded = afterWrite.flatMap { try? JSONDecoder().decode([SavedLinksStore.Entry].self, from: $0) }
    expect(reDecoded?.contains { $0.id == "magnet:?xt=urn:btih:abc" } == true,
           "SLS-2a: a genuine save write persists a valid, decodable [Entry] array")
    expect(afterWrite != corruptA, "SLS-2b: the corrupt bytes are gone from the primary key after a real write")
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "SLS-2c: the sidecar STILL holds the original bytes - the wipe left a recoverable copy")

    // (3) One-time: a second decode failure must not overwrite the still-original sidecar copy.
    defaults().set(corruptB, forKey: primaryKey)
    SavedLinksStore.invalidate(profileID)
    DiagnosticsLog.reset()
    _ = SavedLinksStore.all(profileID: profileID)
    expect(defaults().data(forKey: sidecarKey) == corruptA,
           "SLS-3a: the sidecar is one-time - the second failure did NOT overwrite the first copy")
    expect(DiagnosticsLog.lines.isEmpty, "SLS-3b: the one-time guard also suppresses a duplicate line")

    // (4) A genuinely empty store reads empty WITHOUT quarantining.
    let emptyID = UUID()
    let emptyPrimary = "stremiox.savedLinks.\(emptyID.uuidString)"
    let emptySidecar = emptyPrimary + ".undecodable"
    defaults().removeObject(forKey: emptyPrimary)
    defaults().removeObject(forKey: emptySidecar)
    SavedLinksStore.invalidate(emptyID)
    DiagnosticsLog.reset()
    expect(SavedLinksStore.all(profileID: emptyID).isEmpty,
           "SLS-4a: an empty store reads empty")
    expect(defaults().data(forKey: emptySidecar) == nil,
           "SLS-4b: an empty store writes NO sidecar (empty is not a decode failure)")
    expect(DiagnosticsLog.lines.isEmpty, "SLS-4c: an empty store emits no line")

    // Cleanup this run's keys.
    for k in [primaryKey, sidecarKey, emptyPrimary, emptySidecar] { defaults().removeObject(forKey: k) }
}

// MARK: - Run

@main
struct StoreDecodeQuarantineContract {
    @MainActor
    static func main() {
        lastStreamContract()
        sourcePinContract()
        savedLinksContract()
        print("")
        print(failed == 0 ? "ALL PASS (\(passed) checks)" : "FAILURES: \(failed) of \(passed + failed) checks")
        exit(failed == 0 ? 0 : 1)
    }
}
