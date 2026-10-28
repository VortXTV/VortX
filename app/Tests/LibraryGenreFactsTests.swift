import Foundation

@main enum LibraryGenreFactsTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        let bytes = Data(#"{"id":"same","type":"movie","name":"Film","links":[{"category":"Genres","name":" Drama "},{"category":"genre","name":"drama"},{"category":"GENRES","name":"Mystery"},{"category":"imdb","name":"8.2"},{"category":"Genres","name":"  "},{"category":"Genres","name":123}]}"#.utf8)
        let meta = try JSONDecoder().decode(CoreMeta.self, from: bytes)
        let wire = try JSONDecoder().decode(VortxJSON.self, from: bytes)
        let facts = LibraryGenreFacts.acceptedMetadata(wire, id: "same", type: "movie")
        expect(facts == ["Drama", "Mystery"], "real accepted CoreMeta genre links normalize without rating/blank/malformed links")
        expect(LibraryGenreFacts.normalized(meta.genres) == facts, "carrier reads the same actual CoreMeta facts")
        expect(LibraryGenreFacts.acceptedMetadata(wire, id: "other", type: "movie") == nil, "different id has no facts")
        expect(LibraryGenreFacts.acceptedMetadata(wire, id: "same", type: "series") == nil, "same id, different type has no facts")
        expect(LibraryGenreFacts.acceptedMetadata(data: bytes, id: "same", type: "movie") == facts, "dictionary bridge retains exact typed facts")
        expect(LibraryGenreFacts.acceptedMetadata(data: Data("invalid".utf8), id: "same", type: "movie") == nil, "unreadable metadata stays unknown")
        let card = LibraryWatchedMutationPolicy.MetaPreview(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster, genres: facts)
        let other = LibraryWatchedMutationPolicy.MetaPreview(id: "same", type: "series", name: "Show", poster: nil, genres: ["Comedy"])
        expect(LibraryWatchedMutationPolicy.detailPreview(targetID: "same", targetType: "movie", ready: [other, card], catalog: nil, decoded: nil) == card,
               "actual detail fallback selects exact type before retaining genre facts")
        let cardData = try JSONSerialization.data(withJSONObject: card.dictionary)
        expect(LibraryGenreFacts.acceptedMetadata(data: cardData, id: "same", type: "movie") == facts,
               "actual menu/detail MetaPreview dictionary retains the accepted links through its adapter")
        let old = LibraryWatchedMutationPolicy.MetaPreview(id: "old", type: "movie", name: "Old", poster: nil)
        expect(old.dictionary["links"] == nil, "old caller remains sparse rather than inventing genre facts")
        expect(LibraryGenreFacts.projected(.array([.string(" Drama "), .string("drama")])) == ["Drama"], "known native facts are readable")
        expect(LibraryGenreFacts.projected(.array([.string("Drama"), .integer(1)])) == nil, "mixed opaque native arrays are not partial evidence")
        expect(LibraryGenreFacts.projected(.object(["future": .unsigned(UInt64.max)])) == nil, "future native shape remains unknown")
        expect(LibraryGenreFacts.projected(nil) == nil && LibraryGenreFacts.projected(.null) == nil
               && LibraryGenreFacts.projected(.array([])) == nil, "missing/null/empty are unknown")
        expect(LibraryGenreFacts.wire(nil) == nil && LibraryGenreFacts.wire([" "]) == nil, "unknown facts are omitted from writes")
        expect(LibraryGenreFacts.wire(facts) == .array([.string("Drama"), .string("Mystery")]), "only normalized display strings enter the optional carrier")
        print("PASS LibraryGenreFactsTests: 15 focused assertions")
    }
}
