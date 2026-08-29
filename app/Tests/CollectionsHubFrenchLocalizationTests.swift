// Standalone source contract for the French Collections hub strings on iOS, macOS, and tvOS.
//
// Run from the repository root:
//   xcrun swiftc app/Tests/CollectionsHubFrenchLocalizationTests.swift \
//     -o /tmp/collections-hub-french-localization && /tmp/collections-hub-french-localization

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL  \(message)\n".utf8))
    exit(1)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
    print("PASS  \(message)")
}

private func source(at root: String, _ relativePath: String) -> String {
    let path = URL(fileURLWithPath: root).appendingPathComponent(relativePath).path
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("read \(path)")
    }
    return content
}

private func frenchValue(for key: String, in strings: [String: Any]) -> String? {
    guard let entry = strings[key] as? [String: Any],
          let localizations = entry["localizations"] as? [String: Any],
          let french = localizations["fr"] as? [String: Any],
          let stringUnit = french["stringUnit"] as? [String: Any] else {
        return nil
    }
    return stringUnit["value"] as? String
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let catalogPath = URL(fileURLWithPath: root).appendingPathComponent("app/Resources/Localizable.xcstrings").path
guard let catalogData = FileManager.default.contents(atPath: catalogPath),
      let catalog = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
      let strings = catalog["strings"] as? [String: Any] else {
    fail("parse \(catalogPath)")
}

let expectedFrench = [
    "Discover": "Découvrir",
    "Trending": "Tendance",
    "Popular": "Populaire",
    "Latest": "Dernières sorties",
    "Upcoming": "À venir",
    "What's hot right now": "Ce qui fait le buzz en ce moment",
    "Most popular movies and shows": "Les films et séries les plus populaires",
    "New movies and episodes": "Nouveaux films et épisodes",
    "Coming soon to theaters and TV": "Bientôt au cinéma et à la télévision",
    "Streaming Services": "Services de streaming",
    "Browse": "Parcourir",
    "Browse by service": "Parcourir par service",
    "Browse by Genre": "Parcourir par genre",
    "Browse by genre": "Parcourir par genre",
    "Browse by Decade": "Parcourir par décennie",
    "Browse by decade": "Parcourir par décennie"
]

for (key, expected) in expectedFrench.sorted(by: { $0.key < $1.key }) {
    require(frenchValue(for: key, in: strings) == expected,
            "French catalog value for \(key)")
}

let model = source(at: root, "app/SourcesShared/CollectionsHubModel.swift")
for literal in ["What's hot right now", "Most popular movies and shows", "New movies and episodes", "Coming soon to theaters and TV"] {
    require(model.contains("return \"\(literal)\""),
            "DiscoverList retains the localizable \(literal) source key")
}

let iOSHub = source(at: root, "app/SourcesiOS/iOSBrowseGridView.swift")
require(iOSHub.contains("hubSection(title: \"Browse by Decade\")"),
        "iOS hub retains the localizable Decade header key")
require(iOSHub.contains("Text(LocalizedStringKey(list.subtitle))"),
        "iOS Discover cards resolve subtitles through the string catalog")
require(iOSHub.contains("Text(LocalizedStringKey(title))"),
        "iOS hub sections resolve their headers through the string catalog")

let tvHub = source(at: root, "app/SourcesTV/BrowseGridView.swift")
require(tvHub.contains("section(title: \"Browse by Decade\", eyebrow: \"Browse by decade\")"),
        "tvOS hub retains the localizable Decade title and eyebrow keys")
require(tvHub.contains("Text(LocalizedStringKey(list.subtitle))"),
        "tvOS Discover cards resolve subtitles through the string catalog")
require(tvHub.contains("String(localized: LocalizedStringResource(stringLiteral: eyebrow))"),
        "tvOS hub resolves eyebrows through the string catalog")
require(tvHub.contains("String(localized: LocalizedStringResource(stringLiteral: title))"),
        "tvOS hub resolves titles through the string catalog")

print("PASS  Collections hub French localization contract")
