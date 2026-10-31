import Foundation

@main enum LibraryGenreFilterTests {
    struct Row: Equatable { let id: String; let type: String; let marker: Int }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func key(_ row: Row) -> LibraryGenreFilter.Key { .init(id: row.id, type: row.type) }
    static func main() {
        let movie = Row(id: "same", type: "movie", marker: 1)
        let series = Row(id: "same", type: "series", marker: 2)
        let unknown = Row(id: "unknown", type: "movie", marker: 3)
        let rows = [series, unknown, movie]
        let projection = LibraryGenreFilter.Projection([
            .init(key: key(movie), genres: [" Drama ", "drama", "Mystery"]),
            .init(key: key(series), genres: ["Comedy"]),
            .init(key: key(unknown), genres: nil),
        ], selected: .all)
        expect(projection.filter(rows, selected: .all, key: key) == rows, "All preserves admitted row order and all other fields")
        expect(projection.filter(rows, selected: .unknown, key: key) == [unknown], "unknown older entries remain reachable")
        expect(projection.filter(rows, selected: .genre("DRAMA"), key: key) == [movie], "same id different type cannot borrow facts")
        expect(projection.filter(rows, selected: .genre("comedy"), key: key) == [series], "actual selected type matches its own facts")
        expect(projection.choices.filter { $0.id == "genre:drama" }.count == 1, "whitespace and case variants make one stable control")
        expect(projection.choices.prefix(2).map(\.id) == ["all", "unknown"], "All and Unknown controls are stable")
        let unadmitted = Row(id: "outside", type: "movie", marker: 4)
        expect(projection.filter([unadmitted], selected: .all, key: key).isEmpty, "display projection grants no membership to out-of-inventory rows")
        let selected = LibraryGenreFilter.Choice.genre("Drama")
        let afterRemoval = LibraryGenreFilter.Projection([.init(key: key(unknown), genres: [])], selected: selected)
        expect(afterRemoval.choices.contains(selected), "a selected missing genre remains visible/focus-stable until cleared")
        expect(afterRemoval.filter([unknown], selected: selected, key: key).isEmpty, "selected missing genre is an explicit empty result")
        expect(afterRemoval.filter([unknown], selected: .all, key: key) == [unknown], "All clears the empty filter")
        let oldUnknown = LibraryGenreFilter.Projection([.init(key: key(movie), genres: [" ", "\n"])], selected: .all)
        expect(oldUnknown.filter([movie], selected: .unknown, key: key) == [movie], "blank/default-empty remains unknown, not a fabricated genre")
        let literal = LibraryGenreFilter.Choice.genre("Unknown genre")
        expect(literal != .unknown && LibraryGenreFilter.Choice.genre("All genres") != .all, "provider labels cannot collide with built-in selection ids")
        let newOwner = LibraryGenreFilter.Projection([.init(key: key(movie), genres: ["Horror"])], selected: .all)
        expect(newOwner.filter([movie], selected: selected, key: key).isEmpty, "a fresh owner's same typed id uses only its own facts")
        let pass = Set([key(series)])
        expect(projection.filter(rows, selected: .all, key: key).filter { pass.contains(key($0)) } == [series],
               "typed smart-pass intersection cannot admit the same-id movie")
        expect(projection.filter(rows, selected: .genre("Drama"), key: key).filter { pass.contains(key($0)) }.isEmpty,
               "a nonmatching genre cannot silently relax a pre-existing watched/smart pass")
        let added = LibraryGenreFilter.Projection([.init(key: key(movie), genres: ["Action", "Drama"])], selected: selected)
        expect(added.choices.first { $0 == selected }?.id == selected.id, "inserting a genre before the selection keeps its stable identity")
        let raw: VortxJSON = .array([.string("Drama"), .integer(1)])
        let malformed = LibraryGenreFilter.Projection([.init(key: key(movie), genres: LibraryGenreFacts.projected(raw))], selected: .all)
        expect(malformed.filter([movie], selected: .unknown, key: key) == [movie], "mixed public arrays remain Unknown through the real read guard")
        print("PASS LibraryGenreFilterTests: 17 focused assertions")
    }
}
