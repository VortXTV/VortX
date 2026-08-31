// Standalone contract for Apple Add-to-Library and watched mutation routing.
//
// Run from the repository root:
//
//   xcrun swiftc -warnings-as-errors -o /tmp/library-watched-contract \
//     app/Tests/LibraryWatchedMutationContractTests.swift && \
//   /tmp/library-watched-contract

import Foundation

private var failures = 0

private func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func functionBody(in source: String, signature: String) -> String? {
    guard let signatureRange = source.range(of: signature),
          let openBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var cursor = openBrace
    while cursor < source.endIndex {
        if source[cursor] == "{" { depth += 1 }
        if source[cursor] == "}" {
            depth -= 1
            if depth == 0 { return String(source[openBrace...cursor]) }
        }
        cursor = source.index(after: cursor)
    }
    return nil
}

private func ownerMutationViolations(in source: String) -> [String] {
    guard let add = functionBody(in: source, signature: "func addDetailToLibrary()"),
          let mark = functionBody(in: source, signature: "func markWatched(_ isWatched: Bool)") else {
        return ["shared detail mutation function is missing"]
    }
    var violations: [String] = []
    if !add.contains("guard ProfileStore.shared.activeUsesEngineHistory else")
        || !add.contains("ProfileStore.shared.addLibraryEntry")
        || !add.contains("dispatchCtx([\"action\": \"AddToLibrary\"") {
        violations.append("owner and overlay library adds do not have separate durable routes")
    }
    if !add.contains("detailMetaPreview()") || !source.contains("private func detailMetaPreview()")
        || !source.contains("[\"id\": detail.id, \"type\": detail.type, \"name\": detail.name]") {
        violations.append("detail add has no decoded-detail fallback when raw meta state is unavailable")
    }
    if !mark.contains("for v in metaDetails?.meta?.videos ?? []")
        || !mark.contains("MarkVideoAsWatched")
        || !mark.contains("MarkAsWatched\", \"args\": isWatched") {
        violations.append("whole-title watch does not update both per-video ticks and aggregate state")
    }
    if !mark.contains("if overlayMarkWatched(isWatched") {
        violations.append("overlay watched mutation can fall through to the account route")
    }
    return violations
}

private func staleMembershipViolations(in source: String) -> [String] {
    guard let libraryBranch = functionBody(in: source, signature: "func handleEvent(_ data: Data)") else {
        return ["CoreBridge.handleEvent is missing"]
    }
    if libraryBranch.contains("(current.watchedVideoIds?.count ?? 0) != (details?.watchedVideoIds?.count ?? 0)") {
        return ["library refresh compares watched-id count instead of membership"]
    }
    return libraryBranch.contains("WatchedMembershipPolicy.changed(current.watchedVideoIds, details?.watchedVideoIds)")
        ? [] : ["library refresh does not republish an equal-count watched-id replacement"]
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let sourcePath = URL(fileURLWithPath: root).appendingPathComponent("app/SourcesShared/CoreBridge.swift").path
guard let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
    print("FAIL  could not read CoreBridge.swift under \(root)")
    exit(1)
}

let ownerViolations = ownerMutationViolations(in: source)
check(ownerViolations.isEmpty, "owner dispatch and overlay persistence stay independently routed")
for violation in ownerViolations { print("      \(violation)") }

let membershipViolations = staleMembershipViolations(in: source)
check(membershipViolations.isEmpty, "equal-count watched-id replacements republish the detail page")
for violation in membershipViolations { print("      \(violation)") }

let oldAggregateOnly = """
func markWatched(_ isWatched: Bool) {
    if isWatched { dispatchMetaDetails([\"action\": \"MarkAsWatched\", \"args\": true]); return }
}
"""
check(!ownerMutationViolations(in: oldAggregateOnly).isEmpty,
      "gate rejects the aggregate-only whole-series watched regression")

if failures > 0 { exit(1) }
