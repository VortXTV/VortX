// Pure contracts for the iOS detail follow-up.
//
//     mkdir -p _build/ios-detail-followup-20260905
//     swiftc app/SourcesiOS/iOSDetailPresentation.swift \
//       app/Tests/IOSDetailPresentationPolicyTests.swift \
//       -o _build/ios-detail-followup-20260905/presentation-tests
//     _build/ios-detail-followup-20260905/presentation-tests

import Foundation

private final class Harness {
    private(set) var failures = 0
    private(set) var checks = 0

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() {
            print("  PASS \(name)")
        } else {
            failures += 1
            print("  FAIL \(name)")
        }
    }
}

private func sourceText() -> String {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let path = cwd.appendingPathComponent("app/SourcesiOS/iOSDetailView.swift")
    guard let source = try? String(contentsOf: path, encoding: .utf8) else {
        fatalError("Could not read \(path.path)")
    }
    return source
}

@main
private enum IOSDetailPresentationPolicyTests {
    static func main() {
        let harness = Harness()
        print("IOSDetailPresentationPolicyTests")

        let portrait320 = IOSDetailHeroLayout.heroHeight(viewport: 568, width: 320)
        let portrait375 = IOSDetailHeroLayout.heroHeight(viewport: 667, width: 375)
        let portrait430 = IOSDetailHeroLayout.heroHeight(viewport: 844, width: 430)
        harness.check(abs(portrait320 - 568 * 0.78) < 0.001, "320pt portrait hero uses 78% viewport")
        harness.check(abs(portrait375 - 667 * 0.78) < 0.001, "375pt portrait hero uses 78% viewport")
        harness.check(abs(portrait430 - 844 * 0.78) < 0.001, "430pt portrait hero uses 78% viewport")

        let landscape = IOSDetailHeroLayout.heroHeight(viewport: 375, width: 812)
        harness.check(landscape < portrait320, "landscape hero is shorter than portrait")
        harness.check(landscape <= 375, "landscape hero leaves room for controls")
        harness.check(IOSDetailHeroLayout.constrainedControlWidth(
            intrinsicWidth: 900, availableWidth: 280
        ) == 280, "overlong Dynamic-Type control is constrained to the row width")
        harness.check(IOSDetailHeroLayout.constrainedControlWidth(
            intrinsicWidth: 148, availableWidth: 280
        ) == 148, "ordinary controls retain their intrinsic width")
        harness.check(IOSDetailHeroLayout.heroHeight(viewport: 0, width: 375)
                      == IOSDetailHeroLayout.invalidViewportFallback,
                      "invalid viewport uses deterministic fallback")
        harness.check(IOSDetailHeroLayout.heroHeight(viewport: .nan, width: 375)
                      == IOSDetailHeroLayout.invalidViewportFallback,
                      "non-finite viewport uses deterministic fallback")

        let name = " 4K REMUX 🎬\nDirector's Cut "
        let description = "HDR10+  •  Atmos\n  custom spacing preserved  "
        let rendered = IOSStreamPresentationData.make(
            name: name, description: description, filename: "wrong-fallback.mkv"
        )
        harness.check(rendered.title == name, "default title preserves literal name, spacing, newline, emoji")
        harness.check(rendered.detail == description,
                      "default detail preserves literal multiline description and spacing")
        harness.check(rendered.title != rendered.detail, "distinct name and description remain distinct")

        let identical = "Cached 🎬\n4K"
        let deduplicated = IOSStreamPresentationData.make(
            name: identical, description: identical, filename: "ignored.mkv"
        )
        harness.check(deduplicated.title == identical && deduplicated.detail == nil,
                      "identical heading and body do not render twice")

        let fallback = IOSStreamPresentationData.make(name: "", description: "  \n", filename: "fallback.mkv")
        harness.check(fallback.title == "fallback.mkv" && fallback.detail == nil,
                      "filename is used only when configured name and description are empty")
        let descriptionOnly = IOSStreamPresentationData.make(
            name: nil, description: "Provider-owned description\nline two", filename: "not-used.mkv"
        )
        harness.check(descriptionOnly.title == "Provider-owned description\nline two" && descriptionOnly.detail == nil,
                      "description-only add-on text stays literal without filename substitution")

        let source = sourceText()
        harness.check(source.contains("hero(width: geo.size.width, height: geo.size.height)"),
                      "episode body passes measured viewport height into its hero")
        harness.check(source.contains("#if os(iOS)\n        let showsPrimaryControls = false\n        let showsSecondaryControls = true")
                      && source.contains("let showsPrimaryControls = true\n        let showsSecondaryControls = true")
                      && source.contains("showsPrimaryControls: showsPrimaryControls")
                      && source.contains("showsSecondaryControls: showsSecondaryControls"),
                      "episode source list keeps iOS secondary-only controls and Mac primary controls")
        harness.check(source.contains("if showAllSources || (!showsPrimaryControls && !showsSecondaryControls)"),
                      "episode secondary-only mode keeps the full source rail collapsed")
        harness.check(source.contains("if showsSecondaryControls")
                      && source.contains("var constrainOversizedChildren = false")
                      && source.contains("FlowLayout(spacing: Theme.Space.sm, constrainOversizedChildren: true)")
                      && source.contains("constrainedControlWidth")
                      && source.contains("ProposedViewSize(width: width, height: nil)"),
                      "source/detail controls opt into wrapping intrinsic-width layout")
        harness.check(source.contains("#if os(iOS)\n        let includePrimary = false\n        #else\n        let includePrimary = true")
                      && source.contains("detailHeroPrimaryAction")
                      && source.contains(".overlay(alignment: .bottom)"),
                      "iOS detail hero owns the primary CTA while Mac keeps heroBelow")
        harness.check(source.contains("IOSDetailHeroLayout.heroHeight(viewport: height, width: width)"),
                      "iOS hero path uses the shared portrait/landscape geometry policy")
        harness.check(source.contains("let band = min(1000, min(viewport * 0.72, viewport - reservedForContent))"),
                      "macOS pinned hero sizing formula remains intact")
        harness.check(source.contains("IOSStreamPresentationData.make(")
                      && source.contains("name: stream.name")
                      && source.contains("description: stream.description")
                      && source.contains("filename: stream.behaviorHints?.filename"),
                      "default source rows use name/description before filename")
        harness.check(source.contains("if compactLabels {")
                      && source.contains("} else if pinned || (debridCached && !formatterCached) {")
                      && source.contains("if debridCached && !formatterCached")
                      && source.contains("let formatterCached = StreamRanking.isCached"),
                      "parsed quality/flavour summary is compact opt-in with native state supplemental")
        harness.check(source.contains("sourceListView(width: geo.size.width)\n                episodeOverviewText"),
                      "episode synopsis follows the source action/list surface")
        harness.check(source.contains("#endif\n\n    /// The episode overview follows the hero action surface"),
                      "episode overview helper is available outside the macOS-only block")
        harness.check(source.contains(".toolbar(.hidden, for: .navigationBar)")
                      && source.contains("RestoreSwipeBack()"),
                      "episode iOS path hides only its native bar and restores swipe-back")

        print("receipt checks=\(harness.checks) failures=\(harness.failures)")
        if harness.failures > 0 { exit(1) }
    }
}
