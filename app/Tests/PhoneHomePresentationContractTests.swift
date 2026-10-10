import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath

func source(_ path: String) throws -> String {
    try String(contentsOfFile: root + "/" + path, encoding: .utf8)
}

var checks = 0
func expect(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    checks += 1
}

let sourceText = try source("app/SourcesiOS/iOSRootView.swift")
let home = sourceText.components(separatedBy: "struct iOSHomeView: View {")[1]
    .components(separatedBy: "/// Reorder + hide the Home rows")[0]
let library = sourceText.components(separatedBy: "struct iOSLibraryView: View {")[1]
    .components(separatedBy: "/// The offline-downloads section")[0]
let libraryHero = library.components(separatedBy: "private var heroCandidates: [FeaturedHeroItem] {")[1]
    .components(separatedBy: "private var usesOverlayLibrary")[0]
let discover = sourceText.components(separatedBy: "struct iOSDiscoverView: View {")[1]

expect(sourceText.contains("homeModeButton(\"Discover\", discover: true)"),
       "Home keeps the root Browse route while presenting its user-facing label as Discover")
expect(sourceText.contains("private func homeModeButton(_ title: LocalizedStringKey, discover: Bool)"),
       "Home mode selection uses the Discover route flag")
expect(sourceText.contains("UIDevice.current.userInterfaceIdiom == .phone")
       && sourceText.contains("horizontalSizeClass == .compact"),
       "compact Home presentation is limited to a compact iPhone width")

expect(home.contains("private var homeAmbientCanvas: some View")
       && home.contains("HomeCinemaAtmosphere(tint: homeHeroTint?.value(for: homeHeroTintKey) ?? Theme.Palette.accent")
       && home.contains("reduceTransparency: reduceTransparency, highContrast: accessibilityContrast == .increased"),
       "Home reuses its current hero tint with a profile-accent and accessibility fallback")
expect(home.contains("FeaturedHeroView(model: hero, onOpen: { path.append($0) }")
       && home.contains("RoundedRectangle(cornerRadius: 28, style: .continuous)")
       && home.contains(".padding(.horizontal, 16)"),
       "phone Home wraps the shared hero in a continuous rounded inset card")
expect(home.contains("if compactPhoneHome")
       && home.contains("else {\n            FeaturedHeroView(model: hero, onOpen: { path.append($0) }, eyebrow: String(localized: \"Featured\"),"),
       "iPad and Mac keep the existing direct shared-hero call site")
expect(home.contains("reduceMotion") && home.contains("onOpen: { path.append($0) }"),
       "the local wrapper preserves hero rotation accessibility and navigation actions")
expect(!home.contains("averageColor") && !home.contains("CGImage") && !home.contains("dominantColor"),
       "Home tint does not introduce repeated full-size artwork analysis")

expect(library.contains("private var heroCandidateSignature: [String]")
       && library.contains(".onChange(of: heroCandidateSignature)"),
       "Library reseeding observes its bounded candidate identity signature")
expect(libraryHero.contains("return overlayHeroCandidates")
       && libraryHero.contains("(core.library?.catalog ?? []).prefix(5)")
       && !libraryHero.contains("profiles.libraryItems"),
       "Library hero candidates keep engine data prefix-bounded and avoid overlay dictionary sorting")
expect(library.contains(".onReceive(profiles.$watch)")
       && library.contains("refreshOverlayHeroCandidates()"),
       "overlay hero candidates refresh from the published watch mutation signal")
expect(!library.contains(".onChange(of: core.revision)"),
       "Library no longer reseeds its full candidate pool for every core revision")
expect(discover.contains("private var heroCandidateSignature: [String]")
       && discover.contains(".onChange(of: heroCandidateSignature)"),
       "Discover reseeding observes its bounded candidate identity signature")
expect(!discover.contains(".onChange(of: core.revision)"),
       "Discover no longer reseeds its full candidate pool for every core revision")

print("PhoneHomePresentationContractTests: \(checks) checks passed")
