import Foundation

@main
enum CinemaPreviewSynopsisTests {
    static func main() {
        func synopsis(_ json: String, id: String = "tt123", type: String = "series") -> String? {
            CinemaPreviewSynopsis.description(in: Data(json.utf8), id: id, type: type)
        }
        precondition(synopsis(#"{"meta":{"id":"tt123","type":"series","description":"  About this show.  "}}"#) == "About this show.")
        precondition(synopsis(#"{"meta":{"id":"other","type":"series","description":"Wrong title"}}"#) == nil)
        precondition(synopsis(#"{"meta":{"id":"tt123","type":"movie","description":"Wrong type"}}"#) == nil)
        precondition(synopsis(#"{"meta":{"id":"tt123","description":"Synopsis without optional type"}}"#) != nil)
        precondition(synopsis(#"{"meta":{"id":"tt123","description":" \n "}}"#) == nil)
        precondition(synopsis(#"{"meta":null}"#) == nil)
        precondition(synopsis("bad JSON") == nil)
        precondition(CinemaPreviewSynopsis.description(in: Data(repeating: 32, count: 2 * 1024 * 1024 + 1), id: "tt123", type: "series") == nil)
        print("CinemaPreviewSynopsisTests: 8 checks passed")
    }
}
