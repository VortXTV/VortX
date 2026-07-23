// AddonReorderMetaResolutionTests - proves the SHIPPED metadata resolver honors the add-on reorder.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so
// this compiles the REAL production model file (app/SourcesShared/CoreModels.swift) with the same minimal
// dependency stubs the episode-identity tests use, and asserts against the actual shipped
// `CoreMetaDetails.meta` computed property - NOT a re-implemented copy. `meta` is the detail-page metadata
// pick (synopsis / poster / logo language, #144): given the engine's raw `meta_items` (in `profile.addons`
// order) it must return the meta whose add-on is EARLIEST in the user's applied reorder, so a user whose
// #1 add-on is a localized meta provider sees that provider's metadata even though the engine lists the
// protected English Cinemeta first.
//
// Run (compiles the REAL `AddonPriorityOrder` too, since `CoreMetaDetails.meta` now resolves its rank and
// identity through the shared primitive - so this test exercises the exact shipped dedup + canonical rule):
//
//     xcrun swiftc -o /tmp/addon-reorder-meta-test \
//       app/SourcesShared/AddonPriorityOrder.swift \
//       app/SourcesShared/CoreModels.swift \
//       app/SourcesShared/SubtitleReleaseFingerprint.swift \
//       app/Tests/AddonReorderMetaResolutionTests.swift && \
//       /tmp/addon-reorder-meta-test

import Foundation

// MARK: - Minimal CoreModels dependencies (mirror of the episode-identity test stub set; the reorder
// entry points are made settable so the test can drive the applied order).

enum DebridService: String { case torBox }
struct DebridEpisode { let season: Int; let episode: Int }

enum LastStreamStore {
    struct Entry {
        let videoId: String
        let url: String
        let type: String
        let debridService: String?
        let infoHash: String?
        let linkSavedAt: Date?
        let debridTorrentId: Int?
        let debridFileId: Int?
        let fileIdx: Int?
        let season: Int?
        let episode: Int?
    }
}

actor DebridCoordinator {
    static let shared = DebridCoordinator()
    func reresolve(service: DebridService, infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?,
                   episode: DebridEpisode? = nil, requiresSemanticSelection: Bool) async throws -> URL {
        throw StubError.unavailable
    }
}

enum StubError: Error { case unavailable }

// The one symbol CoreMetaDetails.meta consults for the applied order. `appliedAddonOrder` is settable so the
// test can supply an explicit reorder. The identity + dedup rule is the REAL `AddonPriorityOrder` (compiled
// above), not a stub, so this asserts the shipped canonical / first-occurrence behavior directly.
enum VortXSyncManager { static var appliedAddonOrder: [String] = [] }

final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum StremioServer {
    static let base = "http://127.0.0.1:11470"
    static let trailerResolverBase = "https://trailer.invalid"
}

enum PlaybackSettings { static let torrentsDisabled = false }

// MARK: - Test

@main
private struct AddonReorderMetaResolutionTests {
    static let english = "https://cinemeta.strem.io/manifest.json"   // engine lists this first (protected)
    static let french = "https://fr.cinemeta.example/manifest.json"  // the user's chosen #1 meta provider

    static var failures = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)") }
    }

    static func metaItem(id: String, name: String) -> CoreMetaItem {
        CoreMetaItem(id: id, type: "movie", name: name, poster: nil, background: nil, logo: nil,
                     description: nil, releaseInfo: nil, runtime: nil, links: nil, videos: nil,
                     trailerStreams: nil, behaviorHints: nil)
    }

    static func readyEntry(base: String, name: String) -> CoreMetaEntry {
        CoreMetaEntry(
            request: CoreResourceRequest(base: base, path: CoreResourcePath(resource: "meta", type: "movie", id: "tt1")),
            content: .ready(metaItem(id: "tt1", name: name)))
    }

    static func main() {
        print("Add-on reorder - real metadata resolution (CoreMetaDetails.meta)\n")

        // Engine order: English (protected, index 0) BEFORE French - the exact #144 shape.
        let details = CoreMetaDetails(
            metaItems: [readyEntry(base: english, name: "English synopsis"),
                        readyEntry(base: french, name: "Synopsis en français")],
            streams: [], metaStreams: nil, libraryItem: nil, watchedVideoIds: nil)

        // No reorder yet: the resolver returns the engine's first ready meta (English), unchanged behavior.
        VortXSyncManager.appliedAddonOrder = []
        check(details.meta?.name == "English synopsis",
              "META: with no reorder, the detail meta is the engine-first add-on (unchanged)")

        // The user reorders their French provider to #1: the SHIPPED resolver must now answer French even
        // though the engine still lists English first (which is exactly the defect the reorder must drive).
        // The applied order is written with the REAL shared canonical identity, the same rule meta reads by.
        VortXSyncManager.appliedAddonOrder = [AddonPriorityOrder.canonical(french), AddonPriorityOrder.canonical(english)]
        check(details.meta?.name == "Synopsis en français",
              "META: after reorder, the detail meta resolves from the reordered #1 add-on (French), not engine-first")

        // A reorder that lists only OTHER add-ons leaves this title's providers un-placed, so the resolver
        // falls back to engine order (never nil, never dropped).
        VortXSyncManager.appliedAddonOrder = ["https://unrelated.example/manifest.json"]
        check(details.meta?.name == "English synopsis",
              "META: an unrelated reorder falls back to engine order (no add-on placed for this title)")

        // DEDUP (M2): a duplicated synced entry keeps the FIRST occurrence, the same policy the stream and
        // catalog seams use. French listed twice then English still resolves French, and never traps/doubles.
        VortXSyncManager.appliedAddonOrder = [AddonPriorityOrder.canonical(french),
                                              AddonPriorityOrder.canonical(french),
                                              AddonPriorityOrder.canonical(english)]
        check(details.meta?.name == "Synopsis en français",
              "META: a duplicated applied entry keeps first-occurrence (shared dedup policy), still resolves French")

        // H3: the meta pick uses the shared canonical identity, so an applied entry differing only by PATH
        // case does NOT match a provider (the old whole-string lowercasing would have collapsed them). Here
        // the reorder names the French provider with an upper-cased PATH, so it fails to place and the pick
        // falls back to engine-first English.
        let frenchPathCased = french.replacingOccurrences(of: "manifest.json", with: "MANIFEST.json")
        VortXSyncManager.appliedAddonOrder = [AddonPriorityOrder.canonical(frenchPathCased)]
        check(details.meta?.name == "English synopsis",
              "META: a path-case-only applied entry does not match the provider (canonical identity, H3)")

        print("")
        if failures == 0 {
            print("PASS: shipped CoreMetaDetails.meta honors the add-on reorder")
            exit(0)
        } else {
            print("FAIL: \(failures) assertion(s) failed")
            exit(1)
        }
    }
}
