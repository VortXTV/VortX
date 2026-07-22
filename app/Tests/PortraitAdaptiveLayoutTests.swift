// PortraitAdaptiveLayoutTests: executable production contracts plus deterministic geometry for
// INS-260722-01. Compile the exact seams that the SwiftUI views call, then run the receipt:
//
//     xcrun swiftc -D PORTRAIT_ADAPTIVE_LAYOUT_CONTRACT_ONLY \
//       app/SourcesShared/AddonStoreView.swift \
//       app/SourcesShared/CatalogPreferences.swift \
//       app/Tests/PortraitAdaptiveLayoutTests.swift \
//       -o /tmp/portrait-adaptive-layout-tests
//     /tmp/portrait-adaptive-layout-tests

import Foundation

private let viewportWidth = 375.0       // iPhone SE (2nd generation), portrait
private let screenInset = 20.0          // Theme.Space.screenInset on iOS
private let storeExtraInset = 12.0      // AddonStoreView's non-tvOS edge inset
private let cardInset = 20.0            // Theme.Space.md on each card edge
private let storeAvailable = viewportWidth - 2 * (screenInset + storeExtraInset + cardInset)
private let catalogAvailable = viewportWidth - 2 * (screenInset + cardInset)
private let largestAppTextScale = 1.40  // ThemeManager.textScaleRange.upperBound

private final class Harness {
    private(set) var failures = 0
    private(set) var checks = 0

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() {
            print("  ok   \(name)")
        } else {
            failures += 1
            print("  FAIL \(name)")
        }
    }
}

/// A deterministic upper-level intrinsic-width estimate. The exact glyph rasterizer is not the contract:
/// this deliberately uses a conservative average glyph width and the production 140% app text ceiling.
private func textWidth(_ text: String, basePointSize: Double, horizontalPadding: Double = 0) -> Double {
    Double(text.count) * basePointSize * largestAppTextScale * 0.56 + horizontalPadding
}

private func wrappedLineWidths(children: [Double], spacing: Double, available: Double) -> [Double] {
    var lines: [Double] = []
    var line = 0.0
    for child in children {
        let proposed = line == 0 ? child : line + spacing + child
        if line > 0, proposed > available {
            lines.append(line)
            line = child
        } else {
            line = proposed
        }
    }
    if line > 0 { lines.append(line) }
    return lines
}

private func sourceRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("SourcesShared").path) {
        return cwd
    }
    if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("app/SourcesShared").path) {
        return cwd.appendingPathComponent("app")
    }
    fatalError("Run from the repository root or app directory")
}

private func read(_ relativePath: String) -> String {
    let url = sourceRoot().appendingPathComponent(relativePath)
    guard let value = try? String(contentsOf: url, encoding: .utf8) else {
        fatalError("Could not read \(url.path)")
    }
    return value
}

private func section(_ source: String, from startMarker: String, until endMarker: String) -> String? {
    guard let start = source.range(of: startMarker),
          let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else { return nil }
    return String(source[start.lowerBound..<end.lowerBound])
}

private func occurrences(of needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

private func replacingFirst(_ needle: String, with replacement: String,
                            in source: String, after anchor: String) -> String {
    guard let anchorRange = source.range(of: anchor),
          let targetRange = source.range(of: needle, range: anchorRange.upperBound..<source.endIndex) else {
        return source
    }
    var mutated = source
    mutated.replaceSubrange(targetRange, with: replacement)
    return mutated
}

/// Structural wiring checks are deliberately scoped to the real production functions. Executable seams below
/// prove the decisions and mutations; these checks prove the SwiftUI controls actually call those seams.
private func productionWiringContract(addonSource: String, catalogSource: String) -> Bool {
    guard let compactAddon = section(addonSource,
                                     from: "private func compactStoreRowContent",
                                     until: "private func addonLogo"),
          let compactCatalog = section(catalogSource,
                                       from: "private func compactCatalogRow",
                                       until: "private func catalogIdentity"),
          let moveToTop = section(catalogSource,
                                  from: "private func moveToTopButton",
                                  until: "private func moveUpButton"),
          let visibility = section(catalogSource,
                                   from: "private func visibilityButton",
                                   until: "private func move(_ keys"),
          let move = section(catalogSource,
                             from: "private func move(_ keys",
                             until: "/// Reorder every catalog"),
          let header = section(catalogSource,
                               from: "private var header",
                               until: "private var scrollBody"),
          let listBody = section(catalogSource,
                                 from: "private var listBody",
                                 until: "@ViewBuilder\n    private func row") else { return false }

    let activationCall = "PortraitAdaptiveLayoutContract.usesCompactPortrait("
    return occurrences(of: activationCall, in: addonSource) == 1
        && occurrences(of: activationCall, in: catalogSource) == 1
        && addonSource.contains("#if os(iOS)\n    private func compactStoreRowContent")
        && addonSource.contains("#if os(iOS)\n    @ViewBuilder\n    private func compactTypeChips")
        && catalogSource.contains("#if os(iOS)\n    private func compactCatalogRow")
        && compactAddon.contains("compactTypeChips(addon)")
        && compactAddon.contains("installControl(addon, isInstalled: isInstalled, isInstalling: isInstalling)")
        && addonSource.contains("FlowLayout(spacing: 6)")
        && compactCatalog.contains("FlowLayout(spacing: Theme.Space.sm)")
        && compactCatalog.contains("moveToTopButton(keys, index: index)")
        && compactCatalog.contains("moveUpButton(keys, index: index)")
        && compactCatalog.contains("moveDownButton(keys, index: index, total: total)")
        && compactCatalog.contains("moveToBottomButton(keys, index: index, total: total)")
        && compactCatalog.contains("visibilityButton(info, isHidden: isHidden)")
        && moveToTop.contains("Button { move(keys, from: index, to: 0) }")
        && move.contains("CatalogRowMutationContract.moving(keys, from: from, to: to)")
        && move.contains("prefs.reorder(next)")
        && visibility.contains("prefs.setHidden(info.key, CatalogRowMutationContract.toggledHidden(isHidden))")
        && header.contains("HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs)")
        && header.contains("Text(\"Group by add-on order\")")
        && header.contains(".fixedSize(horizontal: false, vertical: true)")
        && header.contains(".frame(maxWidth: .infinity, alignment: .leading)")
        && header.contains(".accessibilityLabel(\"Group by add-on order\")")
        && !header.contains("Label(\"Group by add-on order\", systemImage:")
        && !header.contains(".fixedSize()")
        && listBody.contains(".onMove { source, dest in")
        && listBody.contains("keys.move(fromOffsets: source, toOffset: dest)")
        && listBody.contains("prefs.reorder(keys)")
        && catalogSource.contains("accessibilityLabel(\"Move to top\")")
        && catalogSource.contains("accessibilityLabel(\"Move up\")")
        && catalogSource.contains("accessibilityLabel(\"Move down\")")
        && catalogSource.contains("accessibilityLabel(\"Move to bottom\")")
        && catalogSource.contains("accessibilityLabel(isHidden ? \"Show catalog\" : \"Hide catalog\")")
}

@main
private enum PortraitAdaptiveLayoutTests {
    static func main() {
        let harness = Harness()
        print("PortraitAdaptiveLayoutTests")
        print("  receipt viewport=\(Int(viewportWidth)) storeAvailable=\(Int(storeAvailable)) catalogAvailable=\(Int(catalogAvailable)) appTextScale=\(largestAppTextScale)")

        // Execute the exact predicate called by both shipping views. A production mutant that returns false
        // for compact portrait turns this assertion red while regular width and landscape stay on the old path.
        harness.check(PortraitAdaptiveLayoutContract.usesCompactPortrait(
            horizontalIsCompact: true, verticalIsCompact: false
        ), "production predicate activates compact portrait")
        harness.check(!PortraitAdaptiveLayoutContract.usesCompactPortrait(
            horizontalIsCompact: true, verticalIsCompact: true
        ), "production predicate preserves compact-width landscape")
        harness.check(!PortraitAdaptiveLayoutContract.usesCompactPortrait(
            horizontalIsCompact: false, verticalIsCompact: false
        ), "production predicate preserves regular-width portrait")

        // Execute the same pure mutations called by the real button actions.
        let keys = ["first", "second", "third"]
        harness.check(CatalogRowMutationContract.moving(keys, from: 2, to: 0) == ["third", "first", "second"],
                      "production move seam sends a catalog to top")
        harness.check(CatalogRowMutationContract.moving(keys, from: 0, to: 2) == ["second", "third", "first"],
                      "production move seam sends a catalog to bottom")
        harness.check(CatalogRowMutationContract.moving(keys, from: -1, to: 0) == nil,
                      "production move seam rejects invalid indices")
        harness.check(CatalogRowMutationContract.toggledHidden(false),
                      "production visibility seam hides a visible catalog")
        harness.check(!CatalogRowMutationContract.toggledHidden(true),
                      "production visibility seam shows a hidden catalog")

        let longAddonName = textWidth("Media Fusion Community Extended", basePointSize: 17)
        let installControl = textWidth("Installing...", basePointSize: 13, horizontalPadding: 42)
        let oldStoreIntrinsic = 52 + 20 + longAddonName + 12 + installControl
        harness.check(oldStoreIntrinsic > storeAvailable,
                      "old add-on single HStack overflows: \(Int(oldStoreIntrinsic)) > \(Int(storeAvailable))")

        let typeChips = ["Movie", "Series", "Channel", "TV"].map {
            textWidth($0, basePointSize: 13, horizontalPadding: 16)
        }
        let typeLines = wrappedLineWidths(children: typeChips, spacing: 6, available: storeAvailable)
        harness.check(typeLines.count > 1, "four largest-text type chips wrap on the narrow store card")
        harness.check(typeLines.allSatisfy { $0 <= storeAvailable },
                      "every wrapped type-chip line fits the store card")
        harness.check(installControl <= storeAvailable, "the separated Install action fits its own line")

        let longCatalogIdentity = textWidth("International Documentary Collection", basePointSize: 17)
        let catalogControls = Array(repeating: 68.0, count: 5)
        let oldCatalogIntrinsic = longCatalogIdentity + 12 + catalogControls.reduce(0, +) + 4 * 20
        harness.check(oldCatalogIntrinsic > catalogAvailable,
                      "old catalog single HStack overflows: \(Int(oldCatalogIntrinsic)) > \(Int(catalogAvailable))")
        let controlLines = wrappedLineWidths(children: catalogControls, spacing: 12, available: catalogAvailable)
        harness.check(controlLines.count > 1, "all five catalog controls wrap on the narrow catalog card")
        harness.check(controlLines.allSatisfy { $0 <= catalogAvailable },
                      "every wrapped control line fits the catalog card")
        let groupActionWidth = 18 + 8
            + textWidth("Group by add-on order", basePointSize: 13, horizontalPadding: 40)
        harness.check(groupActionWidth <= catalogAvailable,
                      "largest app-text group action fits the narrow catalog header")

        let addonSource = read("SourcesShared/AddonStoreView.swift")
        let catalogSource = read("SourcesShared/CatalogPreferences.swift")
        harness.check(productionWiringContract(addonSource: addonSource, catalogSource: catalogSource),
                      "shipping SwiftUI branches call the executable seams and retain every action")

        let noStoreFlow = addonSource.replacingOccurrences(of: "FlowLayout(spacing: 6)",
                                                            with: "HStack(spacing: 6)")
        harness.check(!productionWiringContract(addonSource: noStoreFlow, catalogSource: catalogSource),
                      "mutant killed: add-on type chips reverted to one HStack")
        let noCatalogFlow = catalogSource.replacingOccurrences(of: "FlowLayout(spacing: Theme.Space.sm)",
                                                                with: "HStack(spacing: Theme.Space.sm)")
        harness.check(!productionWiringContract(addonSource: addonSource, catalogSource: noCatalogFlow),
                      "mutant killed: five catalog controls reverted to one HStack")
        let emptyInstall = replacingFirst(
            "installControl(addon, isInstalled: isInstalled, isInstalling: isInstalling)",
            with: "EmptyView()",
            in: addonSource,
            after: "private func compactStoreRowContent"
        )
        harness.check(!productionWiringContract(addonSource: emptyInstall, catalogSource: catalogSource),
                      "mutant killed: compact Install control replaced by EmptyView")
        let noMoveToTop = replacingFirst(
            "Button { move(keys, from: index, to: 0) }",
            with: "Button { }",
            in: catalogSource,
            after: "private func moveToTopButton"
        )
        harness.check(!productionWiringContract(addonSource: addonSource, catalogSource: noMoveToTop),
                      "mutant killed: Move to top action replaced by a no-op")
        let noVisibilityMutation = replacingFirst(
            "prefs.setHidden(info.key, CatalogRowMutationContract.toggledHidden(isHidden))",
            with: "()",
            in: catalogSource,
            after: "private func visibilityButton"
        )
        harness.check(!productionWiringContract(addonSource: addonSource, catalogSource: noVisibilityMutation),
                      "mutant killed: visibility action replaced by a no-op")
        let noDragReorder = catalogSource.replacingOccurrences(of: ".onMove { source, dest in",
                                                                with: ".onDelete { source in")
        harness.check(!productionWiringContract(addonSource: addonSource, catalogSource: noDragReorder),
                      "mutant killed: drag reorder removed")
        let iconOnlyGroupAction = replacingFirst(
            "Text(\"Group by add-on order\")",
            with: "EmptyView()",
            in: catalogSource,
            after: "private var header"
        )
        harness.check(!productionWiringContract(addonSource: addonSource,
                                                catalogSource: iconOnlyGroupAction),
                      "mutant killed: group action lost its visible title")
        let allAxisFixedGroupAction = replacingFirst(
            ".fixedSize(horizontal: false, vertical: true)",
            with: ".fixedSize()",
            in: catalogSource,
            after: "private var header"
        )
        harness.check(!productionWiringContract(addonSource: addonSource,
                                                catalogSource: allAxisFixedGroupAction),
                      "mutant killed: group action restored all-axis fixed sizing")

        if harness.failures > 0 {
            print("FAILED: \(harness.failures)/\(harness.checks) check(s)")
            exit(1)
        }
        print("PASS: \(harness.checks)/\(harness.checks) executable portrait layout contract")
    }
}
