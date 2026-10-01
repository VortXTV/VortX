import Foundation

@main
enum SourcePresentationPolicyTests {
    static func main() {
        let name = "⚡ AIOStreams\n4K · 🇬🇧"
        let description = "🎞️ Episode 01\r\n💾 12.3 GB\n  [RD+] **original**\n"
        precondition(SourcePresentationPolicy.text(name: name, description: description, filename: "discard.mkv") == [name, description])
        precondition(SourcePresentationPolicy.text(name: nil, description: description, filename: "discard.mkv") == [description])
        precondition(SourcePresentationPolicy.text(name: " \n", description: nil, filename: "Episode.01.mkv") == ["Episode.01.mkv"])
        precondition(SourcePresentationPolicy.text(name: nil, description: nil, filename: nil).isEmpty)
        precondition(SourcePresentationPolicy.text(name: "same", description: "same", filename: nil) == ["same", "same"])
        precondition(SourcePresentationPolicy.label(name: "  AIOStreams \n4K", description: "ignored") == "AIOStreams")
        precondition(SourcePresentationPolicy.label(name: "\n", description: "  Episode 9 \nother") == "Episode 9")
        precondition(SourcePresentationPolicy.label(name: nil, description: nil) == "Source")
        precondition(SourcePresentationPolicy.label(name: " ", description: " \n") == "Source")
        precondition(SourcePresentationPolicy.mobileHeroHeight(width: 390, viewport: 800) == 624)
        precondition(SourcePresentationPolicy.mobileHeroHeight(width: 820, viewport: 1100) == 660)
        precondition(SourcePresentationPolicy.mobileHeroHeight(width: 800, viewport: 390) == 360)
        precondition(SourcePresentationPolicy.mobileHeroHeight(width: 0, viewport: 0) == 420)
        precondition(SourcePresentationPolicy.mobileHeroHeight(width: 390, viewport: .nan) == 420)
        precondition(SourcePresentationPolicy.mobileHeroActionOverlap(width: 390, viewport: 800) == 26)
        precondition(SourcePresentationPolicy.mobileHeroActionOverlap(width: 820, viewport: 1100) == 0)
        precondition(SourcePresentationPolicy.mobileHeroActionOverlap(width: 800, viewport: 390) == 0)
        precondition(SourcePresentationPolicy.mobileHeroActionOverlap(width: 0, viewport: 0) == 0)
        precondition(SourcePresentationPolicy.mobileHeroActionOverlap(width: .nan, viewport: 800) == 0)
        print("Source presentation: 19 checks passed")
    }
}
