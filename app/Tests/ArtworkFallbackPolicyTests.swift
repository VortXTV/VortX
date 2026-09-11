import Foundation

@main
enum ArtworkFallbackPolicyTests {
    @MainActor static func main() async {
        let thumb = "https://example.test/episode.jpg?token=original"
        let poster = "https://example.test/poster.jpg"
        let candidates = ArtworkFallbackPolicy.candidates([nil, "", " \n", "relative.jpg", "data:image/png,AA", thumb, thumb, poster])
        precondition(candidates == [thumb, poster])
        var requests: [String] = []
        let result: String? = await ArtworkFallbackPolicy.firstAvailable(candidates) {
            requests.append($0)
            return $0 == poster ? "poster bytes" : nil
        }
        precondition(result == "poster bytes" && requests == [thumb, poster])
        requests = []
        let primary: String? = await ArtworkFallbackPolicy.firstAvailable(candidates) {
            requests.append($0); return "image"
        }
        precondition(primary == "image" && requests == [thumb])
        let missing: String? = await ArtworkFallbackPolicy.firstAvailable(candidates) { _ in nil }
        precondition(missing == nil)
        let cancelled = Task { @MainActor () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ArtworkFallbackPolicy.firstAvailable(candidates) { _ in
                preconditionFailure("cancelled request started image work")
            }
        }
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil)
        let cancelledDuringLoad = Task { @MainActor () -> String? in
            await ArtworkFallbackPolicy.firstAvailable(candidates) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "obsolete image"
            }
        }
        let obsoleteResult = await cancelledDuringLoad.value
        precondition(obsoleteResult == nil)
        print("Artwork fallback: 6 checks passed")
    }
}
