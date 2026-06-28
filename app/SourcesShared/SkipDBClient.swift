import Foundation

/// Submission client for api.skipdb.tv. Reads are handled by SkipTimestampService;
/// this handles authenticated writes (POST a segment) and cache invalidation after a submit.
enum SkipDBClient {

    enum SkipDBError: LocalizedError {
        case noKey
        case serverError(Int, String?)
        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No SkipDB API key. Add one in Settings → Metadata services."
            case .serverError(let code, let msg):
                return msg ?? "SkipDB returned \(code)"
            }
        }
    }

    struct SubmitRequest: Encodable {
        let imdb_id: String
        let season: Int?
        let episode: Int?
        let segment_type: String
        let start_ms: Int
        let end_ms: Int
        let duration_ms: Int?
    }

    static func submit(_ req: SubmitRequest) async throws {
        guard let key = ApiKeys.skipDBKey() else { throw SkipDBError.noKey }
        guard let url = URL(string: "https://api.skipdb.tv/api/segments") else { return }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlReq.httpBody = try JSONEncoder().encode(req)
        urlReq.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: urlReq)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = try? JSONDecoder().decode([String: String].self, from: data)
            throw SkipDBError.serverError(http.statusCode, msg?["error"])
        }
    }

    /// Remove the cached SkipDB entry for an episode so the next fetch gets fresh data.
    static func invalidateCache(imdbId: String, season: Int?, episode: Int?, durationSeconds: Double) async {
        let bucket = Int(durationSeconds / 10) * 10
        let key = "skipdb:\(imdbId):\(season ?? 0):\(episode ?? 0):\(bucket)"
        await SkipTimestampStore.shared.invalidate(for: key)
    }
}
