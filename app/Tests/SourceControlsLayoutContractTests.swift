import Foundation

@main
enum SourceControlsLayoutContractTests {
    static func main() throws {
        let source = try String(contentsOfFile: "app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        let controls = source.components(separatedBy: "@ViewBuilder private var controlBar: some View {")[1]
            .components(separatedBy: "/// The visible quality dropdown")[0]
        precondition(!controls.contains("HStack(spacing: Theme.Space.sm) {\n                    // Watch-Now"))
        precondition(controls.contains("VStack(alignment: .leading, spacing: Theme.Space.sm) {\n                    // Watch-Now"))
        let selectors = controls.components(separatedBy: "FlowLayout(spacing: Theme.Space.sm) {")[1]
            .components(separatedBy: "}")[0]
        for menu in ["qualityMenu", "launchPlayerMenu", "audioLanguageMenu"] {
            precondition(selectors.contains(menu))
        }
        precondition(controls.contains(".disabled(loading)"))
        precondition(controls.contains("playBest(groups.flatMap(\\.streams), best)"))
        let glass = try String(contentsOfFile: "app/SourcesShared/GlassStyle.swift", encoding: .utf8)
        let chip = glass.components(separatedBy: "func vortxGlassChip(selected: Bool, tint: Color = Theme.Palette.accent) -> some View {")[1]
            .components(separatedBy: "/// A list-row / stream-row")[0]
        precondition(chip.contains("hugsTightly: true"))
        precondition(chip.contains("activeFill: selected ? tint.opacity(VortXGlass.chipSelectedAlpha) : nil"))
        precondition(chip.contains("opaqueTVFill: Theme.Palette.surface2"))
        let filter = source.components(separatedBy: "private struct AddonFilterChip: View {")[1]
            .components(separatedBy: "// MARK: Sort control")[0]
        precondition(filter.contains("Capsule().fill(selected ? Theme.Palette.accent : Theme.Palette.surface2)"))
        precondition(filter.contains("if selected { Image(systemName: \"checkmark\") }"))
        precondition(filter.contains(".accessibilityAddTraits(selected ? [.isSelected] : [])"))
        precondition(filter.contains("selected: sourceFilter == nil") && filter.contains("selectSourceAddon(nil)"))
        precondition(filter.contains("selected: sourceFilter == group.addon") && filter.contains("selectSourceAddon(group.addon)"))
        let selection = source.components(separatedBy: "private func selectSourceAddon(_ addon: String?) {")[1]
            .components(separatedBy: "private var filterBar")[0]
        precondition(selection.contains("selectedSourceAddon = addon") && selection.contains("sourceFilter = addon"))
        // All must reveal the list too, before the optional per-addon expansion branch is evaluated.
        precondition(selection.components(separatedBy: "if let addon {")[0].contains("showAllSources = true"))
        precondition(selection.contains("collapsed.remove(addon)"))
        precondition(selection.contains("groups.first { $0.addon == name }?.id"))
        precondition(selection.contains("?? \"cinema-source-list\""))
        precondition(selection.contains("DispatchQueue.main.async { jumpToSource?(anchor) }"))
        precondition(source.contains(".id(\"cinema-source-\\(wg.group.id)\")")
                     && source.contains(".id(\"cinema-source-list\")"))
        print("Source controls layout: wrapping selectors, retained actions and one-rim chip rendering passed")
    }
}
