// Standalone policy and source-boundary checks; this does not prove tvOS remote interaction.
// From the repository root, compile together with app/SourcesTV/TVSettingsCategoryPolicy.swift.
// The optional first executable argument is the repository root for the source-boundary checks.
import Foundation

@main
private enum TVSettingsCategoryPolicyTests {
    static func main() {
        var failures = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                print("PASS  \(message)")
            } else {
                failures += 1
                print("FAIL  \(message)")
            }
        }

        let categories = TVSettingsCategory.allCases
        let routedSections = categories.flatMap(\.sections)
        require(Set(categories.map(\.id)).count == categories.count, "category IDs are unique")
        require(categories.allSatisfy { !$0.sections.isEmpty }, "every category has content")
        require(routedSections.count == SettingsSearchSection.allCases.count &&
                Set(routedSections) == Set(SettingsSearchSection.allCases),
                "categories route every section exactly once")
        require(categories.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty && !$0.systemImage.isEmpty },
                "every category supplies a label, hint and symbol")
        require(TVSettingsCategory.advanced.sections == [.advanced],
                "mpv and diagnostic controls have a direct category")

        require(SettingsSearchSection.matchingSections(for: "") == SettingsSearchSection.allCases,
                "empty search preserves the complete inventory")
        require(SettingsSearchSection.matchingSections(for: " \n\t ") == SettingsSearchSection.allCases,
                "whitespace is an empty search")
        require(SettingsSearchSection.matchingSections(for: "  MPV\n") == [.advanced, .about],
                "search normalizes case and whitespace across categories")
        require(SettingsSearchSection.matchingSections(for: "add profile") == [.profiles],
                "profile actions stay searchable")
        require(SettingsSearchSection.matchingSections(for: "export log") == [.advanced],
                "diagnostic export stays searchable")
        require(SettingsSearchSection.matchingSections(for: "subtitle") == [.audioSubtitle, .subtitle],
                "related sections stay visible together")
        require(SettingsSearchSection.matchingSections(for: "restore") == [.backup],
                "backup restore stays searchable")
        require(SettingsSearchSection.matchingSections(for: "no-such-setting-84619").isEmpty,
                "unknown terms produce an empty result")

        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        guard let settings = try? String(contentsOf: root.appendingPathComponent("app/SourcesTV/SettingsView.swift"), encoding: .utf8) else {
            FileHandle.standardError.write(Data("FAIL  read tvOS Settings source\n".utf8))
            exit(1)
        }
        require(settings.contains("NavigationLink(value: category)") &&
                settings.contains(".navigationDestination(for: TVSettingsCategory.self)"),
                "category links use the existing native navigation stack")
        require(settings.contains("ForEach(matchingSettingsSections, id: \\.self)") &&
                settings.contains("SettingsSearchSection.matchingSections(for: settingsQuery)"),
                "global search renders results from the complete policy")
        require(settings.contains("ForEach(category.sections, id: \\.self)"),
                "category content reuses the typed section route")
        require(settings.contains(".fullScreenCover(item: $editingProfile)") &&
                settings.contains("ProfileEditorView(original: profile)"),
                "profile editing retains the existing PIN-gated editor")
        require(settings.contains(".fullScreenCover(isPresented: $showDiagExport, onDismiss:") &&
                settings.contains("VXDiagExport.shared.stop()"),
                "diagnostic export retains its presentation and shutdown owner")

        if failures > 0 {
            FileHandle.standardError.write(Data("\n\(failures) tvOS Settings category failure(s)\n".utf8))
            exit(1)
        }
        print("\nALL PASS")
    }
}
