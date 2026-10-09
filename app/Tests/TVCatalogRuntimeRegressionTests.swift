import Foundation

@main
enum TVCatalogRuntimeRegressionTests {
    static func main() throws {
        if CommandLine.arguments.contains("--provider") {
            let raw = #"{"id":"native:film","type":"movie","name":"Provider title","imdbRating":"7.9","genres":["Drama","Mystery"]}"#
            let preview = try JSONDecoder().decode(CoreMeta.self, from: Data(raw.utf8))
            guard preview.imdbRating == "7.9" && preview.genres == ["Drama", "Mystery"] else {
                print("TVCatalogProviderMetadataRegressionTests: FAIL — accepted raw-provider facts are discarded")
                exit(43)
            }
            print("TVCatalogProviderMetadataRegressionTests: PASS — authored raw-provider rating and genres survive")
            return
        }
        let raw = #"{"id":"opaque:film","type":"anime","name":"Actual title","poster":"poster","background":"wide","runtime":"126 min","releaseInfo":"2024","description":"Authored synopsis","links":[{"name":"8.2","category":"imdb","url":"rating"}]}"#
        let preview = try JSONDecoder().decode(CoreMeta.self, from: Data(raw.utf8))
        let runtime = Mirror(reflecting: preview).children.first { $0.label == "runtime" }
        guard runtime.map({ String(describing: $0.value) }) == "Optional(\"126 min\")" else {
            print("TVCatalogRuntimeRegressionTests: FAIL — the accepted preview discards authored runtime")
            exit(42)
        }
        precondition(preview.releaseInfo == "2024" && preview.imdbRating == "8.2" && preview.type == "anime")
        print("TVCatalogRuntimeRegressionTests: PASS — authored runtime and existing facts retain their exact identity")
    }
}
