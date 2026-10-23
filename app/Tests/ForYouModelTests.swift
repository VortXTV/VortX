import Foundation

// Compiled by scripts/test-for-you-model.sh as main.swift beside the real ForYouInterests.swift and
// ForYouDiscover.swift, with VortxJSON and VortxNativeError extracted from production sources.

var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() { failures += 1; print("FAIL line \(line): \(message)") }
}
func json(_ text: String) -> VortxJSON { try! JSONDecoder().decode(VortxJSON.self, from: Data(text.utf8)) }
func throwsError(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }

let fixedNow = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!

// MARK: Tolerant decoding: another app may omit lists or write values this version does not know.

let empty = try! json("{}").decode(ForYouInterests.self)
expect(empty == ForYouInterests(), "an empty object decodes to empty, undecided interests")
let partial = try! json(#"{"genres":["scifi","laterGenre"],"eras":["recent"],"decided":true,"futureKey":1}"#).decode(ForYouInterests.self)
expect(partial.genreChoices == [.scifi], "unknown genre keys are ignored for use")
expect(partial.genres == ["scifi", "laterGenre"], "unknown genre keys are kept as written")
expect(partial.decided && partial.eraChoices == [.recent], "decided and eras decode")

let looseCollection = try! json(#"{"id":"0f8fad5b-d9cb-469f-a165-70867728950e","name":"Later","rules":{"type":"documentaryOnly","sort":"trending","genres":["drama"]}}"#)
    .decode(SmartCollection.self)
expect(looseCollection.rules.type == .all && looseCollection.rules.sort == .popular, "unknown type and sort fall back to defaults")
expect(looseCollection.home == false && looseCollection.createdAt == 0, "missing home and createdAt default")
let bare = try! json(#"{"id":"0f8fad5b-d9cb-469f-a165-70867728950e","name":"Bare"}"#).decode(SmartCollection.self)
expect(bare.rules == SmartCollectionRules(), "missing rules default to an empty rule set")

let made = SmartCollection.make(name: "Villeneuve night", rules: SmartCollectionRules(), home: true)
let roundTrip = try! ForYouSync.value(made).decode(SmartCollection.self)
expect(roundTrip == made, "a collection round-trips through the sync value")
expect(ForYouSync.isCollectionField(made.field), "a made collection's field is a valid collection field")

// MARK: Structural validation only: one bad register must never reject a whole host document.

expect(!throwsError { try ForYouSync.validate(ForYouInterests.field, value: .null) }, "a cleared interests register is valid")
expect(!throwsError { try ForYouSync.validate(ForYouInterests.field, value: json(#"{"genres":7,"newer":{"x":[1]}}"#)) },
       "content this version cannot decode is still structurally valid")
expect(throwsError { try ForYouSync.validate(ForYouInterests.field, value: .array([])) }, "a non-object value is rejected")
expect(throwsError { try ForYouSync.validate("forYou.other", value: .null) }, "an unknown forYou field is rejected")
expect(throwsError { try ForYouSync.validate("forYou.collection.0F8FAD5B-D9CB-469F-A165-70867728950E", value: .null) },
       "a collection id must be a lowercase uuid")
expect(throwsError { try ForYouSync.validate("forYou.collection.not-a-uuid", value: .null) }, "a malformed collection id is rejected")
let huge = VortxJSON.object(["name": .string(String(repeating: "x", count: ForYouSync.maxBytes))])
expect(throwsError { try ForYouSync.validate(made.field, value: huge) }, "oversized values are rejected")

// MARK: Reading a host document

let deletedID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427"
let wrongID = "6fa459ea-ee8a-4ca4-894e-db77e160355e"
let host = json("""
{"profiles":{"\(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!.uuidString)":{"fields":{
  "forYou.interests":{"clock":3,"actor":"a","value":{"genres":["thriller"],"decided":true}},
  "forYou.collection.\(made.id)":{"clock":4,"actor":"a","value":\(String(decoding: try! JSONEncoder().encode(made), as: UTF8.self))},
  "forYou.collection.\(deletedID)":{"clock":5,"actor":"a","value":null},
  "forYou.collection.\(wrongID)":{"clock":6,"actor":"a","value":{"id":"\(deletedID)","name":"Moved"}},
  "watchlist.movie.dHQx":{"clock":7,"actor":"a","value":null}
}}}}
""")
let read = ForYouSync.read(host: host, profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
expect(read.interests?.genreChoices == [.thriller] && read.interests?.decided == true, "interests are read for the profile")
expect(read.collections.map(\.id) == [made.id], "deleted and mismatched collections are skipped")
expect(ForYouSync.read(host: host, profileID: UUID()).interests == nil, "another profile has no interests")

// MARK: Eras

expect(ForYouEra.span([.eightiesNineties, .twoThousands], currentYear: 2026) == (1980, 2009), "adjacent eras widen")
expect(ForYouEra.span([.classics, .recent], currentYear: 2026) == (nil, nil), "open-ended eras stay open")
expect(ForYouEra.span([.recent], currentYear: 2026) == (2022, nil), "recent is the last five years")

// MARK: Row plan

var interests = ForYouInterests(genres: ["scifi", "thriller", "comedy"], extras: ["kdrama"], eras: ["recent"],
                                people: [ForYouPerson(id: 137427, name: "Denis Villeneuve", department: "Directing"),
                                         ForYouPerson(id: 1373737, name: "Florence Pugh", department: "Acting")],
                                decided: true)
let plan = ForYouQuery.plan(interests, now: fixedNow)
expect(plan.map(\.id) == ["forYou.genre.scifi", "forYou.person.137427", "forYou.extra.kdrama",
                          "forYou.genre.thriller", "forYou.person.1373737"], "rows alternate genre, person and scene")
expect(plan.map(\.title) == ["Recent sci-fi you'd rate highly", "From Denis Villeneuve", "Korean drama",
                             "Recent thrillers you'd rate highly", "With Florence Pugh"], "row titles follow the mockup")
expect(plan[0].source == .discover(
    movie: "with_genres=878&sort_by=popularity.desc&vote_average.gte=7.0&vote_count.gte=300&primary_release_date.gte=2022-01-01&primary_release_date.lte=2026-10-13",
    tv: "with_genres=10765&sort_by=popularity.desc&vote_average.gte=7.5&vote_count.gte=200&first_air_date.gte=2022-01-01&first_air_date.lte=2026-10-13"),
    "a genre row asks for popular, well-rated titles released in the era")
expect(plan[2].source == .discover(movie: nil,
    tv: "with_original_language=ko&sort_by=popularity.desc&vote_average.gte=7.0&vote_count.gte=80&first_air_date.gte=2022-01-01&first_air_date.lte=2026-10-13"),
    "Korean drama searches series only")
if case .discover(_, let tv) = plan[3].source { expect(tv == nil, "thrillers have no TV genre on TMDB") }
expect(plan[1].source == .person(137427), "a person row reads their work")
interests.eras = []
expect(ForYouQuery.plan(interests, now: fixedNow).first?.title == "Sci-fi you'd rate highly", "no era gives the plain title")
interests.eras = ["80s90s"]
expect(ForYouQuery.plan(interests, now: fixedNow).first?.title == "Sci-fi from the 80s and 90s", "a single older era names it")
expect(ForYouQuery.plan(ForYouInterests(), now: fixedNow).isEmpty, "no interests, no rows")
let many = ForYouInterests(genres: ["scifi", "drama", "crime"], extras: ["anime", "british", "standup"],
                           people: (1...4).map { ForYouPerson(id: $0, name: "P\($0)") })
expect(ForYouQuery.plan(many, now: fixedNow).count == ForYouQuery.maxRows, "rows are capped")

// MARK: Smart collection queries

var villeneuve = SmartCollectionRules()
villeneuve.genres = ["scifi", "thriller"]
villeneuve.people = [ForYouPerson(id: 137427, name: "Denis Villeneuve", department: "Directing")]
villeneuve.yearFrom = 2010
villeneuve.minRating = 7
villeneuve.type = .movie
villeneuve.sort = .rating
villeneuve.hideWatched = true
expect(ForYouQuery.collectionSource(villeneuve, now: fixedNow) == .discover(
    movie: "with_genres=878%7C53&with_people=137427&sort_by=vote_average.desc&vote_average.gte=7.0&vote_count.gte=300&primary_release_date.gte=2010-01-01&primary_release_date.lte=2026-10-13",
    tv: nil), "the mockup's collection becomes one movie query")
villeneuve.type = .all
if case .discover(_, let tv) = ForYouQuery.collectionSource(villeneuve, now: fixedNow) {
    expect(tv == nil, "TMDB's TV discover has no people filter, so people rules search movies only")
}

var anime = SmartCollectionRules()
anime.extras = ["anime", "kdrama"]
anime.genres = ["comedy"]
expect(ForYouQuery.collectionSource(anime, now: fixedNow) == .discover(
    movie: "with_genres=16&with_original_language=ja&sort_by=popularity.desc&vote_count.gte=100&primary_release_date.lte=2026-10-13",
    tv: "with_genres=16&with_original_language=ja&sort_by=popularity.desc&vote_count.gte=50&first_air_date.lte=2026-10-13"),
    "the first scene applies, and a scene that sets a genre replaces the genre rule")

var horror = SmartCollectionRules()
horror.genres = ["horror"]
horror.yearTo = 1999
horror.sort = .newest
expect(ForYouQuery.collectionSource(horror, now: fixedNow) == .discover(
    movie: "with_genres=27&sort_by=primary_release_date.desc&vote_count.gte=20&primary_release_date.lte=1999-12-31", tv: nil),
    "a genre with no TV equivalent skips TV, and an old end year bounds the window")
var future = SmartCollectionRules()
future.yearTo = 2030
future.type = .series
expect(ForYouQuery.collectionSource(future, now: fixedNow) == .discover(
    movie: nil, tv: "sort_by=popularity.desc&vote_count.gte=50&first_air_date.lte=2026-10-13"),
    "an end year in the future is clamped to today")

// MARK: Home section order: a new section lands where it ships, even in a customized layout.

let tv = HomeRail.tvDefaultOrder
expect(HomeRailPreferences.arrange(saved: [], defaults: tv) == tv, "an un-customized Home keeps the shipped order")
expect(tv.prefix(2) == [.forYou, .smartCollections], "For You and smart collections sit under Continue Watching")
let customized = ["addonCatalogs", "collectionsHub", "topPicks", "laterRail"]
let arranged = HomeRailPreferences.arrange(saved: customized, defaults: tv)
expect(Array(arranged.prefix(5)) == [.forYou, .smartCollections, .addonCatalogs, .collectionsHub, .topPicks],
       "new sections with no saved predecessor go to the top, saved ones keep their order")
expect(arranged.firstIndex(of: .becauseYouWatched) == arranged.firstIndex(of: .topPicks)! + 1,
       "a missing section follows its nearest default predecessor")
expect(Set(arranged) == Set(tv) && arranged.count == tv.count, "every default section appears exactly once, unknown ones dropped")
expect(HomeRailPreferences.arrange(saved: ["topPicks", "topPicks"], defaults: tv).filter { $0 == .topPicks }.count == 1,
       "a duplicated saved section appears once")
expect(HomeRailPreferences.arrange(saved: ["editorialCollections", "topPicks"], defaults: tv).contains(.editorialCollections) == false,
       "a section another platform has is dropped here")

print("for-you model: \(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
