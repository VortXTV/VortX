import Foundation

#if DOCUMENT_HISTORY_STANDALONE_TEST
// The production target supplies these exact shared models.  The standalone command below uses a
// Foundation-only structural stub so the production mapper itself can be executed without linking the
// full Apple engine module.
struct CoreLibState {
    let timeOffset: Double
    let duration: Double
    let videoId: String?
    let lastWatched: String?
    let flaggedWatched: Int
    let timesWatched: Int

    init(timeOffset: Double, duration: Double, videoId: String?, lastWatched: String? = nil,
         flaggedWatched: Int = 0, timesWatched: Int = 0) {
        self.timeOffset = timeOffset
        self.duration = duration
        self.videoId = videoId
        self.lastWatched = lastWatched
        self.flaggedWatched = flaggedWatched
        self.timesWatched = timesWatched
    }
}

struct CoreCWItem {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let state: CoreLibState
    var removed: Bool? = nil
    var temp: Bool? = nil
}
#endif

/// Executable proof for the production document mapper.  The fixture intentionally models a resident
/// A title/progress that is not present in B's document: only B's exact source rows may enter the snapshot.
@main
private struct BecauseYouWatchedDocumentHistoryTests {
    static func main() {
        // Decode the same JSON wire shapes used by sync. This is important: Apple Foundation bridges
        // JSON numeric 0/1 and true/false through NSNumber, so native Swift dictionary literals do not
        // exercise the production Boolean-vs-number distinction.
        let wire = """
        {
          "library": [
            {"id":"tt0000001","type":"movie","name":"A resident","t":99,"d":100,"v":"movie-a","poster":"a-poster"}
          ],
          "vortx": {
            "library": [
              {"id":"tt0000001","type":"movie","name":"B shared","t":12,"d":100,"v":"movie-b","poster":"b-poster"},
              {"id":"TVDB:12345","type":"tv","name":"B television","t":0,"d":1},
              {"id":"tmdb:123","type":"movie","name":"B zero duration","t":1,"d":0},
              {"id":"kitsu:460","type":"series","name":"B anime","t":1,"d":1},
              {"id":"tt0000001","type":"movie","name":"stale duplicate","t":99,"d":100},
              {"id":"tt0000002","type":"movie","name":"","t":30,"d":90},
              {"id":"tt0000003","type":"movie","name":"invalid true offset","t":true,"d":90},
              {"id":"tt0000004","type":"movie","name":"invalid false duration","t":1,"d":false}
            ],
            "deletedLibrary": ["kitsu:460"]
          }
        }
        """.data(using: .utf8)!
        let document = try! JSONSerialization.jsonObject(with: wire) as! [String: Any]
        let snapshot = BecauseYouWatchedDocumentHistory.snapshot(
            from: document,
            removedIDs: ["tt0000004"])
        precondition(snapshot.library.map(\.id) == ["tt0000001", "tvdb:12345", "tmdb:123"],
                     "only current B document rows survive validation/tombstones")
        precondition(snapshot.library.first?.name == "B shared",
                     "resident A progress cannot replace the first B source row")
        precondition(snapshot.library.first?.state.timeOffset == 12_000,
                     "shared id uses B's document offset, not resident A's offset")
        precondition(snapshot.library.last?.state.timeOffset == 1_000 &&
                     snapshot.library.last?.state.duration == 0,
                     "numeric wire 0/1 values remain numeric rather than Boolean")
        precondition(snapshot.continueWatching.map(\.id) == ["tt0000001", "tmdb:123"],
                     "membership with zero progress does not become watch evidence")
        print("ALL TESTS PASSED")
    }
}
