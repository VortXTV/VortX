import Foundation

@main
enum TVQuickViewCatalogRailPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        for enabled in [false, true] {
            expect(TVQuickViewPolicy.presents(enabled: enabled, catalog: true) == enabled,
                   "ordinary catalog uses the actual live preference, including direct Details when off")
            expect(!TVQuickViewPolicy.presents(enabled: enabled, catalog: false, privateIntent: true),
                   "private and noncatalog shortcuts cannot preview")
            expect(!TVQuickViewPolicy.presents(enabled: enabled, catalog: true, hasResume: true)
                && !TVQuickViewPolicy.presents(enabled: enabled, catalog: true, hasDirectPlay: true),
                   "resume and direct-play intents stay owned")
        }
        let supplied = try JSONDecoder().decode(MetaPreview.self, from: Data(#"{"id":"opaque:catalog","type":"anime","name":"Supplied title","poster":"supplied-poster","posterShape":"poster","popularity":987.5}"#.utf8))
        let card = TVCinemaCardPresentation.preview(supplied)
        expect(card.id == supplied.id && card.type == supplied.type && card.title == supplied.name,
               "supplied legacy identity/title/type pass through without canonicalization")
        expect(card.poster == supplied.poster && card.background == nil,
               "a supplied poster remains a poster, not an invented wide backdrop")
        expect(card.runtime == nil && card.releaseInfo == nil && card.rating == nil && card.overview == nil,
               "unavailable preview facts stay absent; popularity is not an IMDb rating")
        expect(card.facts == [.text("Anime")] && card.bodyText.isEmpty,
               "unknown metadata does not become a fabricated preview fact")
        let sparse = try JSONDecoder().decode(MetaPreview.self, from: Data(#"{"id":"tt123","type":"movie","name":""}"#.utf8))
        let sparseCard = TVCinemaCardPresentation.preview(sparse)
        expect(sparseCard.id == "tt123" && sparseCard.title.isEmpty && sparseCard.poster == nil,
               "missing supplied title/art does not trigger a fake value or metadata lookup")
        expect(sparseCard.facts == [.text("Movie")], "sparse legacy preview has only its actual type fact")
        print("TVQuickViewCatalogRailPolicyTests: \(checks) checks passed")
    }
}
