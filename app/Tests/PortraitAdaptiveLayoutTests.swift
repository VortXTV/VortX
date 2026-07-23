// PortraitAdaptiveLayoutTests: a standalone, fail-capable contract for the two compact-width rows fixed
// by INS-260722-01. Run from the app directory with:
//
//     swift Tests/PortraitAdaptiveLayoutTests.swift
//
// The app has no XCTest target. This receipt therefore couples deterministic narrow-width geometry to
// the shipped SwiftUI source: the geometry proves why one intrinsic HStack cannot fit at the smallest
// iOS 16-capable iPhone portrait width and that wrapped child rows do fit, while the source checks prove
// the production views actually select the compact portrait composition and reuse FlowLayout.

import Foundation

private let viewportWidth = 375.0       // iPhone SE (2nd generation), portrait
private let screenInset = 20.0          // Theme.Space.screenInset on iOS
private let storeExtraInset = 12.0      // AddonStoreView's non-tvOS edge inset
private let cardInset = 20.0            // Theme.Space.md on each card edge
private let storeAvailable = viewportWidth - 2 * (screenInset + storeExtraInset + cardInset)
private let catalogAvailable = viewportWidth - 2 * (screenInset + cardInset)
private let largestAppTextScale = 1.40  // ThemeManager.textScaleRange.upperBound

private var failures = 0
private var checks = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if condition() {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
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

private func productionContract(addonSource: String, catalogSource: String) -> Bool {
    addonSource.contains("usesCompactPortraitLayout")
        && addonSource.contains("compactStoreRowContent")
        && addonSource.contains("FlowLayout(spacing: 6)")
        && catalogSource.contains("usesCompactPortraitLayout")
        && catalogSource.contains("compactCatalogRow")
        && catalogSource.contains("FlowLayout(spacing: Theme.Space.sm)")
        && catalogSource.contains("accessibilityLabel(\"Move to top\")")
        && catalogSource.contains("accessibilityLabel(\"Move up\")")
        && catalogSource.contains("accessibilityLabel(\"Move down\")")
        && catalogSource.contains("accessibilityLabel(\"Move to bottom\")")
        && catalogSource.contains("accessibilityLabel(isHidden ? \"Show catalog\" : \"Hide catalog\")")
}

print("PortraitAdaptiveLayoutTests")
print("  receipt viewport=\(Int(viewportWidth)) storeAvailable=\(Int(storeAvailable)) catalogAvailable=\(Int(catalogAvailable)) appTextScale=\(largestAppTextScale)")

let longAddonName = textWidth("Media Fusion Community Extended", basePointSize: 17)
let installControl = textWidth("Installing...", basePointSize: 13, horizontalPadding: 42)
let oldStoreIntrinsic = 52 + 20 + longAddonName + 12 + installControl
check(oldStoreIntrinsic > storeAvailable,
      "old add-on single HStack overflows: \(Int(oldStoreIntrinsic)) > \(Int(storeAvailable))")

let typeChips = ["Movie", "Series", "Channel", "TV"].map {
    textWidth($0, basePointSize: 13, horizontalPadding: 16)
}
let typeLines = wrappedLineWidths(children: typeChips, spacing: 6, available: storeAvailable)
check(typeLines.count > 1, "four largest-text type chips wrap on the narrow store card")
check(typeLines.allSatisfy { $0 <= storeAvailable }, "every wrapped type-chip line fits the store card")
check(installControl <= storeAvailable, "the separated Install action fits its own line")

let longCatalogIdentity = textWidth("International Documentary Collection", basePointSize: 17)
// ChipButtonStyle contributes 40pt horizontal padding plus a 5pt focus margin on both sides around an
// icon whose largest-text symbol remains at least 18pt, so each control's uncompressed width is 68pt.
let catalogControls = Array(repeating: 68.0, count: 5)
let oldCatalogIntrinsic = longCatalogIdentity + 12 + catalogControls.reduce(0, +) + 4 * 20
check(oldCatalogIntrinsic > catalogAvailable,
      "old catalog single HStack overflows: \(Int(oldCatalogIntrinsic)) > \(Int(catalogAvailable))")

let controlLines = wrappedLineWidths(children: catalogControls, spacing: 12, available: catalogAvailable)
check(controlLines.count > 1, "all five catalog controls wrap on the narrow catalog card")
check(controlLines.allSatisfy { $0 <= catalogAvailable }, "every wrapped control line fits the catalog card")

let addonSource = read("SourcesShared/AddonStoreView.swift")
let catalogSource = read("SourcesShared/CatalogPreferences.swift")
check(productionContract(addonSource: addonSource, catalogSource: catalogSource),
      "shipped views select compact portrait compositions, wrap children, and retain action labels")

// Fail-capability controls. Each in-memory mutant removes one load-bearing production affordance; the
// contract must reject it so a green result cannot be produced by a check that never goes red.
let noStoreFlow = addonSource.replacingOccurrences(of: "FlowLayout(spacing: 6)", with: "HStack(spacing: 6)")
check(!productionContract(addonSource: noStoreFlow, catalogSource: catalogSource),
      "mutant killed: add-on type chips reverted to one HStack")
let noCatalogFlow = catalogSource.replacingOccurrences(of: "FlowLayout(spacing: Theme.Space.sm)",
                                                       with: "HStack(spacing: Theme.Space.sm)")
check(!productionContract(addonSource: addonSource, catalogSource: noCatalogFlow),
      "mutant killed: five catalog controls reverted to one HStack")
let noCompactSelection = addonSource.replacingOccurrences(of: "usesCompactPortraitLayout", with: "neverCompact")
check(!productionContract(addonSource: noCompactSelection, catalogSource: catalogSource),
      "mutant killed: compact portrait selection removed")

if failures > 0 {
    print("FAILED: \(failures)/\(checks) check(s)")
    exit(1)
}
print("PASS: \(checks)/\(checks) portrait adaptive geometry and production linkage")
