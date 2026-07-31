// Standalone source contract for localized iOS and macOS search-section titles.
//
// Run from the repository root:
//   xcrun swiftc app/Tests/iOSSearchSectionLocalizationTests.swift \
//     -o /tmp/ios-search-section-localization && /tmp/ios-search-section-localization

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL  \(message)\n".utf8))
    exit(1)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
    print("PASS  \(message)")
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

private func section(in text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
        fail("find \(start) section")
    }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let sourcePath = URL(fileURLWithPath: root)
    .appendingPathComponent("app/SourcesiOS/iOSRootView.swift").path
guard let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
    fail("read \(sourcePath)")
}

let search = section(in: source, from: "struct iOSSearchView: View",
                     to: "struct iOSDiscoverView: View")
let discover = section(in: source, from: "struct iOSDiscoverView: View",
                       to: "// MARK: - Discover filter panel")

for title in ["Movies", "Series", "Other"] {
    let localized = "String(localized: \"\(title)\")"
    for (name, body) in [("search", search), ("discover", discover)] {
        require(occurrences(of: localized, in: body) == 1,
                "\(title) uses localized text in \(name)")
        require(!body.contains("(\"\(title)\","),
                "\(title) has no raw tuple label in \(name)")
    }
}

print("PASS  iOS search-section localization contract")
