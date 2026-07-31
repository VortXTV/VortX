// Standalone regression harness for Home board range decisions.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/home-catalog-load-policy-tests \
//     app/SourcesShared/HomeCatalogLoadPolicy.swift \
//     app/Tests/HomeCatalogLoadPolicyTests.swift && \
//     /tmp/home-catalog-load-policy-tests

import Foundation

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

func sourceRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("app/SourcesShared").path) {
        return cwd.appendingPathComponent("app/SourcesShared")
    }
    if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("SourcesShared").path) {
        return cwd.appendingPathComponent("SourcesShared")
    }
    fatalError("Run from the repository root or app directory")
}

func source(_ name: String) -> String {
    let url = sourceRoot().appendingPathComponent(name)
    guard let value = try? String(contentsOf: url, encoding: .utf8) else {
        fatalError("Could not read \(url.path)")
    }
    return value
}

func section(_ source: String, from start: String, until end: String) -> String {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return ""
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

@main
enum HomeCatalogLoadPolicyTests {
    static func main() {
        check("88 visible rows do not stop a 100-wide board with 122 engine catalogs",
              HomeCatalogLoadPolicy.hasNextPage(loaded: 100, engineCatalogTotal: 122))
        check("pagination stops only when the raw engine total is covered",
              !HomeCatalogLoadPolicy.hasNextPage(loaded: 122, engineCatalogTotal: 122))
        check("a catalog order change hydrates every raw engine index",
              HomeCatalogLoadPolicy.fullLoadDepth(
                current: 100,
                engineCatalogTotal: 122,
                installedCatalogTotal: 122
              ) == 122)
        check("installed manifests provide the startup fallback before a board emit",
              HomeCatalogLoadPolicy.fullLoadDepth(
                current: 30,
                engineCatalogTotal: 0,
                installedCatalogTotal: 122
              ) == 122)
        check("a wider existing window is preserved",
              HomeCatalogLoadPolicy.fullLoadDepth(
                current: 150,
                engineCatalogTotal: 122,
                installedCatalogTotal: 122
              ) == 150)
        check("the default window remains at least 30 rows",
              HomeCatalogLoadPolicy.fullLoadDepth(
                current: 0,
                engineCatalogTotal: 6,
                installedCatalogTotal: 6
              ) == 30)

        let bridge = source("CoreBridge.swift")
        let preferences = source("CatalogPreferences.swift")
        let nextPage = section(
            bridge,
            from: "var boardHasNextPage: Bool",
            until: "func loadBoardNextPage"
        )
        let loadBoard = section(
            bridge,
            from: "func loadBoard(rows:",
            until: "private var boardRowsLoaded"
        )
        let orderChange = section(
            bridge,
            from: "func catalogOrderDidChange()",
            until: "func ensureLiveCatalogsLoaded"
        )
        let refreshAddons = section(
            bridge,
            from: "private func refreshAddons()",
            until: "/// Remove an installed addon"
        )
        let boardRebuild = section(
            bridge,
            from: "private func scheduleBoardRebuild()",
            until: "private func buildBoardRows()"
        )
        let reload = section(
            preferences,
            from: "func reloadFromDefaults()",
            until: "func isHidden"
        )
        let hidden = section(
            preferences,
            from: "func setHidden(_ key: String, _ value: Bool) {\n        CatalogPrefsStore.setHidden",
            until: "func reorder"
        )
        let reorder = section(
            preferences,
            from: "func reorder(_ keys:",
            until: "/// Editor:"
        )

        check("production pagination uses the raw engine total",
              nextPage.contains("HomeCatalogLoadPolicy.hasNextPage")
                && !nextPage.contains("boardRows.count"))
        check("a cold board load preserves an existing explicit order",
              loadBoard.contains("CatalogPrefsStore.order().isEmpty")
                && loadBoard.contains("HomeCatalogLoadPolicy.fullLoadDepth")
                && loadBoard.contains("\"end\": requestedRows"))
        check("order changes hydrate the full raw range before rebuilding",
              orderChange.contains("guard !CatalogPrefsStore.order().isEmpty")
                && orderChange.contains("HomeCatalogLoadPolicy.fullLoadDepth")
                && orderChange.contains("includeTombstoned: true")
                && orderChange.contains("includeDisabled: true")
                && orderChange.contains("\"action\": \"LoadRange\"")
                && orderChange.contains("rebuildBoardRows()"))
        check("local reorder routes through full-range hydration",
              reorder.contains("CoreBridge.shared.catalogOrderDidChange()"))
        check("synced or restored order routes through full-range hydration",
              reload.contains("if orderChanged")
                && reload.contains("CoreBridge.shared.catalogOrderDidChange()"))
        check("a late ctx hydrate completes an already-restored order",
              refreshAddons.contains("if !CatalogPrefsStore.order().isEmpty")
                && refreshAddons.contains("ensureCatalogOrderRangeLoaded"))
        check("the authoritative board total closes any interim manifest-count gap",
              boardRebuild.contains("self.boardCatalogTotal = boardState?.catalogs.count ?? 0")
                && boardRebuild.contains("if !CatalogPrefsStore.order().isEmpty")
                && boardRebuild.contains("ensureCatalogOrderRangeLoaded(installedCatalogTotal: 0)"))
        check("a local visibility-only change remains a row rebuild",
              hidden.contains("CoreBridge.shared.rebuildBoardRows()")
                && !hidden.contains("catalogOrderDidChange"))

        finish()
    }

    static func finish() {
        print("")
        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}
