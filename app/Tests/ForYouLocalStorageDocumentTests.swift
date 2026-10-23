import Foundation

@main
enum ForYouLocalStorageDocumentTests {
    static func main() throws {
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        typealias Records = [String: [String: String]]
        let original: Records = [
            "profile-a": ["interests": "original", "future-field": "preserved"],
            "profile-b": ["collection": "other profile"]
        ]
        let bytes = try JSONEncoder().encode(original)
        let absent = try ForYouLocalStorageDocument.decodeForMutation(nil, as: Records.self, empty: [:])
        check(absent.isEmpty, "only an absent object may start empty")
        var decoded = try ForYouLocalStorageDocument.decodeForMutation(bytes, as: Records.self, empty: [:])
        check(decoded == original, "valid existing records survive decoding")
        check(decoded["profile-a"]?["future-field"] == "preserved", "unknown dictionary fields survive")
        let explicitEmpty = try ForYouLocalStorageDocument.decodeForMutation(Data("{}".utf8), as: Records.self, empty: [:])
        check(explicitEmpty.isEmpty, "a valid explicitly empty document remains supported")

        let rejected: [Any] = [
            "not data", 17, NSNull(), Data(), Data("{".utf8), Data("null".utf8),
            Data("[]".utf8), Data("{\"future-root-shape\":17}".utf8)
        ]
        for object in rejected {
            var admitted = false
            do {
                _ = try ForYouLocalStorageDocument.decodeForMutation(object, as: Records.self, empty: [:])
                admitted = true
            } catch ForYouLocalStorageDocument.Failure.unreadable {
                check(true, "present unreadable records return the explicit preserved-data error")
            } catch {
                check(false, "unexpected error type: \(error)")
            }
            check(!admitted, "corruption or an unknown shape cannot reach the replacement-write boundary")
        }
        decoded["profile-a"]?["interests"] = "updated"
        check(decoded["profile-b"] == original["profile-b"], "editing one profile retains another profile")
        check(decoded["profile-a"]?["future-field"] == "preserved", "editing retains unknown saved fields")
        check(try JSONDecoder().decode(Records.self, from: bytes) == original, "the original supplied bytes remain untouched")
        let encoded = try JSONEncoder().encode(decoded)
        check(try JSONDecoder().decode(Records.self, from: encoded) == decoded, "valid mutation encoding still round-trips")
        print("\(checks - failures)/\(checks) checks passed")
        if failures != 0 { throw NSError(domain: "ForYouLocalStorageDocumentTests", code: 1) }
    }
}
