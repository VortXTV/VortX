// Standalone source contract for issue #212: Debrid Cloud belongs beside Play Link in Apple Search,
// is absent from Settings navigation, reuses the established resolver, and routes playback through each
// platform's normal player presenter.
//
// Run from the repository root:
//   xcrun swiftc app/Tests/DebridCloudSearchPlacementContractTests.swift \
//     -o /tmp/debrid-cloud-search-placement && /tmp/debrid-cloud-search-placement

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL  \(message)\n".utf8))
    exit(1)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
    print("PASS  \(message)")
}

private let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? FileManager.default.currentDirectoryPath)

private func source(_ relativePath: String) -> String {
    let path = root.appendingPathComponent(relativePath).path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("read \(relativePath)")
    }
    return text
}

private func section(_ text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
        fail("find section from \(start) to \(end)")
    }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

private func containsInOrder(_ text: String, _ needles: [String]) -> Bool {
    var cursor = text.startIndex
    for needle in needles {
        guard let range = text.range(of: needle, range: cursor..<text.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

let iosRoot = source("app/SourcesiOS/iOSRootView.swift")
let iosSearch = section(iosRoot, from: "struct iOSSearchView: View", to: "struct iOSDiscoverView: View")
require(containsInOrder(iosSearch, ["Button { showOpenLink = true }", "NavigationLink { DebridLibraryView() }"]),
        "iOS and Mac Search place Debrid Cloud after Play Link")
require(iosSearch.contains("Label(\"Debrid Cloud\", systemImage: \"cloud\")"),
        "iOS and Mac Search expose a clear Debrid Cloud action")
require(iosSearch.contains("ViewThatFits(in: .horizontal)"),
        "phone Search preserves both actions at compact widths")

let tvSearch = source("app/SourcesTV/SearchView.swift")
require(containsInOrder(tvSearch, ["Button { showOpenLink = true }", "NavigationLink { DebridLibraryView() }"]),
        "Apple TV Search places Debrid Cloud beside Play Link")
require(tvSearch.contains(".focusSection()"), "Apple TV action row participates in remote focus")

let settings = source("app/SourcesiOS/iOSSettingsView.swift")
require(!settings.contains("NavigationLink(\"Your debrid cloud\")"),
        "iOS and Mac Settings no longer duplicate Debrid Cloud navigation")

let project = source("app/project.yml")
let tvTarget = section(project, from: "  VortXTV:", to: "  VortXTVLite:")
require(tvTarget.contains("SourcesiOS/DebridLibraryView.swift"),
        "Apple TV target compiles the shared Debrid Cloud browser")

let cloud = source("app/SourcesiOS/DebridLibraryView.swift")
for state in ["noKeyState", "loadingState", "emptyState", "inlineNotice"] {
    require(cloud.contains(state), "Debrid Cloud retains \(state) handling")
}
require(cloud.contains("DebridCoordinator.shared.cloudLibrary()"),
        "Debrid Cloud reuses the existing provider aggregation")
require(cloud.contains("DebridCoordinator.shared.resolveLibraryItem(item)"),
        "Debrid Cloud reuses the existing item resolver")
require(cloud.contains("presenter.request = PlaybackRequest(url: url, title: item.name)"),
        "Apple TV selection launches through PlayerPresenter")
require(cloud.contains(".iOSPlayerCover($launch, account: account, core: core)"),
        "iOS and Mac selection retains the normal player cover")
require(cloud.contains(".vortxCardButton()"),
        "Apple TV cloud rows use visible custom focus treatment")

print("PASS  Debrid Cloud Search placement contract")
