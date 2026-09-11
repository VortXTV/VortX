import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }; print("PASS \(message)")
}
private func links(_ json: String) -> [CoreLink]? {
    struct Fixture: Decodable { let links: [CoreLink]? }
    return try! JSONDecoder().decode(Fixture.self, from: Data(json.utf8)).links
}

@main enum MediaRelationsTests {
static func main() {
let fixture = #"""
{"links":[
 {"category":"prequel","name":"Movie One","url":"stremio:///detail/movie/tt001"},
 {"category":"sequel","name":"Anime %","url":"stremio:///detail/series/kitsu%3A4726%3Fpart%3D1"},
 {"category":"related","name":"Web Route","url":"https://web.stremio.com/#/detail/series/anilist%3A11061"},
 {"category":"sequel","name":"Duplicate","url":"stremio:///detail/movie/tt001"},
 {"category":"next","name":"Not a relation","url":"stremio:///detail/movie/tt999"},
 {"category":"related","name":"External","url":"https://example.com/detail/movie/tt777"},
 {"category":"related","name":"Malformed","url":"stremio:///detail/movie"},
 {"category":"related","name":"","url":"stremio:///detail/movie/tt888"}
]}
"""#
let parsed = MediaRelations.entries(from: links(fixture), selfIDs: ["tt001"])
check(parsed.count == 2, "real engine links keep good rows and reject duplicate/self/unsafe/malformed")
check(parsed[0].kind == .sequel && parsed[0].id == "kitsu:4726?part=1", "encoded anime id is preserved")
check(parsed[1].id == "anilist:11061" && parsed[1].type == "series", "web Stremio detail route parses")
check(MediaRelations.parseInternalDetailURL("https://example.com/#/detail/movie/tt1") == nil, "external host rejected")

struct Part: Identifiable { let id: String }
let parts = [Part(id: "tmdb:1"), Part(id: "tmdb:2"), Part(id: "tmdb:3")]
let neighbors = MediaRelations.releaseNeighbors(parts, currentID: "tmdb:2", id: \.id)
check(neighbors.previous?.id == "tmdb:1" && neighbors.next?.id == "tmdb:3", "movie collection chronology preserves order")
check(MediaRelations.releaseNeighbors(parts, currentID: "tmdb:9", id: \.id).previous == nil, "missing movie gets no invented neighbors")
print("ALL MEDIA RELATIONS TESTS PASSED")
check(MediaRelations.parseInternalDetailURL("stremio:///detail/series/kitsu%253A123")?.id == "kitsu%3A123", "decode an opaque ID exactly once")
check(MediaRelations.parseInternalDetailURL("stremio://evil/detail/movie/tt1") == nil, "authority rejected")
check(MediaRelations.parseInternalDetailURL("stremio:///detail/movie/tt1?token=x") == nil, "query rejected")
check(MediaRelations.parseInternalDetailURL("https://u@web.stremio.com/#/detail/movie/tt1") == nil, "userinfo rejected")
check(MediaRelations.parseInternalDetailURL("https://web.stremio.com/other#/detail/movie/tt1") == nil, "unrelated web path rejected")
}
}
