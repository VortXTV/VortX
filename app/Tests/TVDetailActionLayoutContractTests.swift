// Standalone source contract for the tvOS detail action rail.
//
//   swiftc -o /tmp/tv-detail-action-layout-contract app/Tests/TVDetailActionLayoutContractTests.swift \
//     && /tmp/tv-detail-action-layout-contract
//
// The tvOS target is not available to this Foundation-only harness. It protects the layout seam that
// can regress without a type-check failure: a finite-width HStack silently makes long action labels wrap.

import Foundation

private var passed = 0
private var failed = 0

private func expect(_ condition: Bool, _ message: String) {
    if condition {
        passed += 1
        print("PASS  \(message)")
    } else {
        failed += 1
        print("FAIL  \(message)")
    }
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let path = root + "/app/SourcesTV/DetailView.swift"
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("FAIL  could not read \(path)")
    exit(2)
}

guard let railStart = source.range(of: "private struct TVDetailActionRail") else {
    print("FAIL  TVDetailActionRail declaration is missing")
    exit(1)
}

// Extract only the helper's balanced declaration. Checking the remainder of DetailView.swift would let
// a future unrelated `.scrollClipDisabled()` satisfy this contract while the action rail regressed.
guard let railOpen = source[railStart.lowerBound...].firstIndex(of: "{") else {
    print("FAIL  TVDetailActionRail body is missing")
    exit(1)
}
var railDepth = 0
var railCursor = railOpen
var railClose: String.Index?
while railCursor < source.endIndex {
    switch source[railCursor] {
    case "{": railDepth += 1
    case "}":
        railDepth -= 1
        if railDepth == 0 {
            railClose = railCursor
            break
        }
    default: break
    }
    railCursor = source.index(after: railCursor)
    if railClose != nil { break }
}
guard let railClose else {
    print("FAIL  TVDetailActionRail body is unbalanced")
    exit(1)
}
let rail = String(source[railStart.lowerBound...railClose])

expect(rail.contains("ScrollView(.horizontal, showsIndicators: false)"),
       "detail action rail scrolls horizontally")
expect(rail.contains(".fixedSize(horizontal: true, vertical: false)"),
       "detail action rail preserves intrinsic button widths")
expect(rail.contains(".focusSection()"),
       "detail action rail keeps remote traversal in one focus section")
expect(rail.contains(".scrollClipDisabled()"),
       "detail action rail leaves focused scale and glow visible")
expect(rail.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
       "detail action rail remains leading-aligned at every page width")

guard let coreListStart = source.range(of: "struct CoreStreamList: View"),
      let coreListEnd = source.range(of: "/// A horizontal, focus-contained action rail",
                                     range: coreListStart.upperBound..<source.endIndex) else {
    print("FAIL  CoreStreamList/action-rail boundaries are missing")
    exit(1)
}
let coreList = String(source[coreListStart.lowerBound..<coreListEnd.lowerBound])
expect(coreList.contains("TVDetailActionRail {"),
       "movie/source actions use the intrinsic-width rail")
expect(!coreList.contains("HStack(spacing: Theme.Space.md) {"),
       "movie/source actions do not regress to a finite-width action HStack")

guard let heroStart = source.range(of: "private func hero("),
      let heroEnd = source.range(of: "private func heroTrailerLayer",
                                 range: heroStart.upperBound..<source.endIndex) else {
    print("FAIL  series hero boundaries are missing")
    exit(1)
}
let hero = String(source[heroStart.lowerBound..<heroEnd.lowerBound])
expect(hero.contains("TVDetailActionRail(spacing: Theme.Space.sm)"),
       "series hero actions use the same rail")

if failed == 0 {
    print("PASS  tvOS detail action layout contract (\(passed) checks)")
    exit(0)
} else {
    print("FAIL  tvOS detail action layout contract (\(failed) failed, \(passed) passed)")
    exit(1)
}
