import Foundation

@main enum EpisodeEngineBindingRequestTests {
    static func main() {
        let old: [String: Any] = ["base": "https://old.example", "path": ["resource": "meta", "type": "series", "id": "other-title"]]
        let native = EpisodeEngineBindingRequest.build(libraryID: "opaque/anime-title", native: true,
            sourceBase: "https://picked.example/config", residentMetaRequest: old, residentSourceBase: "https://old.example")!
        precondition((native.metaRequest["path"] as? [String: Any])?["id"] as? String == "opaque/anime-title")
        precondition(native.sourceBase == "https://picked.example/config")
        print("PASS native binding uses exact opaque title, never the other resident series")
        let cold = EpisodeEngineBindingRequest.build(libraryID: "series", native: true,
            sourceBase: nil, residentMetaRequest: nil, residentSourceBase: nil)!
        precondition((cold.metaRequest["path"] as? [String: Any])?["id"] as? String == "series")
        precondition(cold.sourceBase == "vortx://player")
        print("PASS native cold/prepared binding works without mounted detail metadata")
        precondition(EpisodeEngineBindingRequest.build(libraryID: nil, native: true,
            sourceBase: nil, residentMetaRequest: old, residentSourceBase: nil) == nil)
        precondition(EpisodeEngineBindingRequest.build(libraryID: " ", native: true,
            sourceBase: nil, residentMetaRequest: old, residentSourceBase: nil) == nil)
        print("PASS native absent exact title fails closed")
        precondition(EpisodeEngineBindingRequest.build(libraryID: "series", native: false,
            sourceBase: "https://picked.example", residentMetaRequest: old, residentSourceBase: nil) == nil)
        let legacy = EpisodeEngineBindingRequest.build(libraryID: "other-title", native: false,
            sourceBase: nil, residentMetaRequest: old, residentSourceBase: nil)!
        precondition(legacy.sourceBase == "https://old.example")
        print("PASS legacy matching resident request retained, foreign request rejected")
    }
}
