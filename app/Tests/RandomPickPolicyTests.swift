import Foundation

@main
enum RandomPickPolicyTests {
    struct Generator: RandomNumberGenerator {
        var calls = 0
        mutating func next() -> UInt64 { calls += 1; return UInt64.max / 2 }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func video(_ id: String, _ season: Int? = 1, _ episode: Int? = 1,
                      released: String? = nil, title: String? = nil) -> CoreVideo {
        CoreVideo(id: id, title: title, released: released, overview: nil,
                  thumbnail: nil, season: season, episode: episode)
    }

    static func main() {
        RandomPickPlayPolicyTests.run()
        PlaybackPreparationStateTests.run()
        VortxMetaLoadingProjectionTests.run()
        RandomPickNavigationOwnerTests.run()
        let now = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
        let episodes = [video("special", 0, 0), video("unknown"), video("malformed", released: "not-a-date"),
                        video("past", released: "2026-10-23"), video("today", released: "2026-10-24"),
                        video("future-day", released: "2026-10-25"),
                        video("future-time", released: "2026-10-24T12:00:01Z"),
                        video("future-fractional", released: "2026-10-24T12:00:00.100Z"),
                        video("padded-future", released: "  2026-10-25T00:00:00Z \n"),
                        video("padded-future-day", released: " 2026-10-25 "),
                        video("exact-now", released: "2026-10-24T12:00:00Z"),
                        video("invalid-day", released: "2026-02-30"),
                        video("unavailable"), video("missing-season", nil), video("missing-episode", 1, nil),
                        video("negative", -1), video("", 1, 1), video(" \n ", 1, 1),
                        video("duplicate"), video("duplicate", title: "Alternate title"),
                        video("duplicate-date", released: "2026-10-25"), video("duplicate-date", released: "2026-10-23"),
                        video("ambiguous", 1, 1), video("ambiguous", 1, 2)]
        let eligible = RandomPickPolicy.eligibleEpisodes(episodes, now: now, knownUnavailableIDs: ["unavailable"])
        expect(Set(eligible.map(\.id)) == Set(["special", "unknown", "malformed", "past", "today",
                                               "exact-now", "invalid-day", "duplicate", "duplicate-date"]), "episode eligibility")
        expect(eligible.filter { $0.id == "duplicate" }.count == 1, "exact duplicate collapses")
        expect(eligible.first { $0.id == "duplicate" }?.title == nil, "same coordinates retain first eligible descriptive metadata")
        expect(RandomPickPolicy.releaseDate(video("leap", released: "2024-02-29")) != nil, "leap date")
        expect(RandomPickPolicy.releaseDate(video("bad", released: "2025-02-29")) == nil, "strict date")
        expect(RandomPickPolicy.eligibleEpisodes([], now: now).isEmpty, "empty metadata")

        let state = CoreLibState(timeOffset: 99, duration: 100, videoId: "old", timesWatched: 2)
        let saved = CoreCWItem(id: "same", type: "movie", name: "Saved", poster: nil, state: state)
        let otherType = CoreCWItem(id: "same", type: "series", name: "Series", poster: nil, state: state)
        var removed = saved; removed.removed = true
        var temporary = saved; temporary.temp = true
        var historyOnly = saved; historyOnly.previouslyWatched = true
        let live = CoreCWItem(id: "channel", type: "tv", name: "Live", poster: nil, state: state)
        let blankID = CoreCWItem(id: " \n ", type: "movie", name: "Title", poster: nil, state: state)
        let blankName = CoreCWItem(id: "blank", type: "series", name: " \t ", poster: nil, state: state)
        let library = RandomPickPolicy.eligibleLibraryItems([saved, saved, otherType, removed, temporary, historyOnly, live, blankID, blankName])
        expect(library.count == 2, "library identity includes type and excludes unsaved bookkeeping")
        expect(saved.state.timeOffset == 99 && saved.state.timesWatched == 2, "pick preserves saved state")

        let profileA = UUID(), profileB = UUID()
        var session = RandomPickPolicy.Session()
        var generator = Generator()
        let record = RandomPickPolicy.episodeRecord(video("ep", 0, 0), type: "series")
        let first = session.select([record], profileID: profileA, scope: "detail:series", using: &generator)!
        expect(session.accepts(first, profileID: profileA, scope: "detail:series", ownerIsCurrent: true,
                               currentRecord: record), "current owner accepts exact record")
        expect(!session.accepts(first, profileID: profileB, scope: "detail:series", ownerIsCurrent: true,
                                currentRecord: record), "profile changed")
        expect(!session.accepts(first, profileID: profileA, scope: "other", ownerIsCurrent: true,
                                currentRecord: record), "title/filter/segment scope changed")
        expect(!session.accepts(first, profileID: profileA, scope: "detail:series", ownerIsCurrent: false,
                                currentRecord: record), "native owner epoch changed, including A-B-A")
        expect(!session.accepts(first, profileID: profileA, scope: "detail:series", ownerIsCurrent: true,
                                currentRecord: nil), "record disappeared")
        let changedCoordinates = RandomPickPolicy.episodeRecord(video("ep", 0, 1), type: "series")
        expect(!session.accepts(first, profileID: profileA, scope: "detail:series", ownerIsCurrent: true,
                                currentRecord: changedCoordinates), "same opaque ID changed coordinates")
        let changedMetadata = RandomPickPolicy.episodeRecord(video("ep", 0, 0, title: "Replaced"), type: "series")
        expect(!session.accepts(first, profileID: profileA, scope: "detail:series", ownerIsCurrent: true,
                                currentRecord: changedMetadata), "same coordinates changed metadata")
        let otherTypeRecord = RandomPickPolicy.episodeRecord(video("ep", 0, 0), type: "movie")
        expect(!session.accepts(first, profileID: profileA, scope: "detail:series", ownerIsCurrent: true,
                                currentRecord: otherTypeRecord), "same ID wrong type")
        let second = session.select([record], profileID: profileA, scope: "detail:series", using: &generator)!
        expect(first.id != second.id, "Pick again creates a unique generation even for the same result")
        expect(!session.accepts(first, profileID: profileA, scope: "detail:series", ownerIsCurrent: true,
                                currentRecord: record), "old Open/Play/Pick-again callbacks cannot borrow new ticket")
        let alternative = RandomPickPolicy.episodeRecord(video("other", 0, 1), type: "series")
        let third = session.select([record, alternative], profileID: profileA, scope: "detail:series", using: &generator)!
        expect(third.record == alternative, "Pick again avoids previous typed identity when alternatives exist")
        let fourth = session.select([record, alternative], profileID: profileA, scope: "detail:series", using: &generator)!
        expect(fourth.record == record, "two-record Pick again alternates eligible identities")
        let singleton = session.select([record], profileID: profileA, scope: "detail:series", using: &generator)!
        expect(singleton.record == record && singleton.id != fourth.id, "singleton remains selectable with fresh authority")
        session.clear()
        expect(!session.accepts(second, profileID: profileA, scope: "detail:series", ownerIsCurrent: true,
                                currentRecord: record), "A-B-A, dismissal and route-pop revocation")
        let calls = generator.calls
        expect(session.select([], profileID: profileA, scope: "empty", using: &generator) == nil, "empty pool")
        expect(calls == generator.calls, "empty pool does not sample RNG")

        let source = RandomPickPolicy.EpisodeSource(identity: .init(type: "series", id: "show"), name: "Show",
                                                    poster: nil, background: nil, videos: [video("ep", 0, 0)])
        let changedSource = RandomPickPolicy.EpisodeSource(identity: source.identity, name: source.name,
            poster: nil, background: nil, videos: [video("ep", 0, 1)])
        expect(source != changedSource, "metadata-source receipt includes exact records")
        print("RandomPickPolicyTests PASS (actual policy and extracted production model declarations)")
    }
}
