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
        print("Source controls layout: 7 checks passed")
    }
}
