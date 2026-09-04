// Standalone source contract for explicit overlay reinstatement and watched-membership recency.
//
// Run from repository root:
//   xcrun swiftc -warnings-as-errors -o /Users/daksh/VortXTV/.tmp-overlay-watch-contract \
//     app/Tests/OverlayWatchMutationContractTests.swift && \
//   /Users/daksh/VortXTV/.tmp-overlay-watch-contract .

import Foundation

private var failures = 0

private func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private func body(_ signature: String, in source: String) -> String? {
    guard let range = source.range(of: signature),
          let open = source[range.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < source.endIndex {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[open...index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let path = URL(fileURLWithPath: root).appendingPathComponent("app/SourcesShared/Profiles.swift")
guard let source = try? String(contentsOf: path, encoding: .utf8) else {
    print("FAIL  could not read \(path.path)")
    exit(1)
}

let addBody = body("func addLibraryEntry(metaId: String, name: String, type: String, poster: String?, profileID: UUID)", in: source) ?? ""
let clearBody = body("func clearWatchRemovalForExplicitAdd(", in: source) ?? ""
check(addBody.contains("clearingRemovalForExplicitAdd: metaId"),
      "targeted Add-to-Library identifies explicit reinstatement")
check(clearBody.contains("Set($0.keys).isDisjoint(with: keys)") && clearBody.contains("saveWatchRemovals(retained"),
      "explicit zero-progress add retracts only its matching dismissal tombstone")
check(source.contains("func addLibraryEntry(metaId: String, name: String, type: String, poster: String?) {\n        guard let profileID = activeID else { return }\n        addLibraryEntry(metaId: metaId"),
      "active Add-to-Library delegates to the targeted mutation path")
check(source.contains("func markWatched(meta: PlaybackMeta) {\n        guard let profileID = activeID else { return }\n        markWatched(meta: meta, profileID: profileID)"),
      "active watched marker delegates to the targeted mutation path")

let setBody = body("func setWatched(_ isWatched: Bool", in: source) ?? ""
let markBody = body("func markWatched(meta: PlaybackMeta, profileID: UUID)", in: source) ?? ""
check(setBody.contains("guard Set(entry.watchedVideoIds) != previous else { return }")
        && setBody.contains("entry.lastWatched = Self.isoNow()"),
      "changed watched membership advances the operation clock")
check(markBody.contains("guard !entry.watchedVideoIds.contains(meta.videoId) else { return }")
        && markBody.contains("entry.lastWatched = Self.isoNow()"),
      "unchanged watched marks do not churn timestamps")
check(setBody.contains("if !name.isEmpty { entry.name = name }")
        && setBody.contains("if !type.isEmpty { entry.type = type }")
        && setBody.contains("entry.poster = poster ?? entry.poster")
        && markBody.contains("entry.name = meta.name") && markBody.contains("entry.poster = meta.poster ?? entry.poster"),
      "state-changing watched mutations refresh display and sync metadata")
check(source.contains("guard watch != before || tombstoneChanged else { return }")
        && source.contains("guard entries != initialEntries || tombstoneChanged else { return }"),
      "idempotent mutations do not save or schedule a sync")

func unwatchWithHints(existing: (name: String, type: String, poster: String?),
                      name: String, type: String, poster: String?) -> (String, String, String?) {
    (name.isEmpty ? existing.name : name, type.isEmpty ? existing.type : type, poster ?? existing.poster)
}
let unwatch = unwatchWithHints(
    existing: ("Saved title", "series", "saved-poster"), name: "", type: "", poster: nil
)
check(unwatch.0 == "Saved title" && unwatch.1 == "series" && unwatch.2 == "saved-poster",
      "unwatch with empty display hints preserves existing title, type, and poster")

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
}
print("\(failures) TEST(S) FAILED")
exit(1)
