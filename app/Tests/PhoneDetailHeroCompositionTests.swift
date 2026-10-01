import Foundation

@main
enum PhoneDetailHeroCompositionTests {
    static func main() throws {
        let source = try String(contentsOfFile: "app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        precondition(source.contains("heroBelow(width: width, scrollToSources: scrollToSources)\n                .padding(.top, -overlap)"))
        precondition(source.contains("Theme.Space.lg + heroActionOverlap(width: width, viewport: height)"))
        precondition(source.contains("episodePrimaryAction\n                .padding(.horizontal, Theme.Space.md)\n                .padding(.top, -overlap)"))
        precondition(source.contains("Task { await playBest(groups.flatMap(\\.streams), labeledBest: best) }"))
        precondition(source.contains(".disabled(loading || preparing || best?.playableURL(isEpisode: true) == nil)"))
        precondition(source.contains("showsPrimaryPlayButton: !heroOwnsPrimaryPlay"))
        precondition(source.contains("heroOwnsPrimaryPlay: SourcePresentationPolicy.mobileHeroActionOverlap("))
        precondition(source.contains("lhs.showsPrimaryPlayButton == rhs.showsPrimaryPlayButton"))
        precondition(source.contains("if showsPrimaryPlayButton {"))
        // Dynamic Type can grow the primary button: no fixed button-height or offset removes its hit area.
        precondition(SourcePresentationPolicy.mobileHeroActionOverlap(width: 390, viewport: 844) == 26)
        precondition(SourcePresentationPolicy.mobileHeroActionOverlap(width: 600, viewport: 844) == 0)
        print("PASS phone hero seam, existing episode resolution, disabled loading, selector ownership and tablet isolation")
    }
}
