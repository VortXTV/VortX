import Foundation
import os

/// Submission client for skip segments. A submit fires up to THREE legs concurrently:
///  - skip.vortx.tv (our self-hosted, keyless worker): ALWAYS, no API key required. This is the
///    authoritative leg; overall success means our worker accepted the segment.
///  - api.skipdb.tv (the community database we mirror reads from): best-effort, ONLY when the user
///    has configured a skipdb.tv API key. We give back to the open ecosystem, but a missing key or a
///    community-side failure never blocks the success UI.
///  - the user's optional custom SkipDB-compatible provider (ApiKeys.customSkipURL): best-effort, ONLY
///    when configured. A self-hosted mirror the user points at; a missing URL, missing key, or any
///    failure never blocks the success UI. It is a THIRD-PARTY host, so it is NOT VortX edge-signed.
/// Reads are handled by SkipTimestampService (skip.vortx.tv first, then theIntroDB/SkipDB/custom/AniSkip).
enum SkipDBClient {

    private static let log = Logger(subsystem: "com.stremiox.app", category: "skipsubmit")

    enum SkipDBError: LocalizedError {
        case serverError(Int, String?)
        var errorDescription: String? {
            switch self {
            case .serverError(let code, let msg):
                switch code {
                case 429: return msg ?? "Too many submissions, try again in a bit."
                case 400: return msg ?? "That segment was rejected (check the times)."
                default:  return msg ?? "Skip submission failed (\(code))."
                }
            }
        }
    }

    /// Shared body shape for both legs. `season`/`episode` are omitted (or sent as 0) for a film;
    /// both endpoints treat either as "no episode". `segment_type` is intro|recap|outro|preview
    /// (credits map to "outro" upstream of here).
    struct SubmitRequest: Encodable {
        let imdb_id: String
        let season: Int?
        let episode: Int?
        let segment_type: String
        let start_ms: Int
        let end_ms: Int
        let duration_ms: Int?
    }

    /// Submit to both databases. Throws only when the authoritative skip.vortx.tv leg fails; the
    /// community skipdb.tv leg is best-effort and its outcome is logged but never surfaced.
    static func submit(_ req: SubmitRequest) async throws {
        // Run all legs concurrently. The community + custom legs are gated on their own config.
        async let vortx: Void = submitToVortX(req)
        async let community: Void = submitToCommunity(req)
        async let custom: Void = submitToCustom(req)

        // The best-effort legs never throw; await them so their tasks complete and log.
        _ = await community
        _ = await custom

        // Authoritative leg: propagate its failure to the caller.
        try await vortx
    }

    /// Our keyless worker. No Authorization header.
    private static func submitToVortX(_ req: SubmitRequest) async throws {
        guard let url = URL(string: "https://skip.vortx.tv/skip/contribute") else { return }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONEncoder().encode(req)
        urlReq.timeoutInterval = 10
        VortXEdgeAuth.sign(&urlReq)   // gated host (skip.vortx.tv /skip/contribute): stamp X-VX-Ts / X-VX-Sig
        do {
            let (data, response) = try await URLSession.shared.data(for: urlReq)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let ok = (200..<300).contains(http.statusCode)
            // Fail-soft, values-free diagnostic: leg + status only, never the imdb id / season / times.
            DiagnosticsLog.log("skip", "submit leg=vortx status=\(http.statusCode) ok=\(ok)")
            guard ok else {
                // Errors come back as {"ok": false, "error": "..."}; surface the message if present.
                let msg = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["error"]?.stringValue
                throw SkipDBError.serverError(http.statusCode, msg)
            }
        } catch let error as SkipDBError {
            throw error
        } catch {
            DiagnosticsLog.log("skip", "submit leg=vortx transport-error")
            throw error
        }
    }

    /// The community skipdb.tv leg. Best-effort: no key means no submission and no error; any failure
    /// is logged, not thrown. We give back to the database we read from when the user opts in with a key.
    private static func submitToCommunity(_ req: SubmitRequest) async {
        guard let key = ApiKeys.skipDBKey() else {   // no key: silently skip, our worker has it
            DiagnosticsLog.log("skip", "submit leg=community skipped=no-key")
            return
        }
        guard let url = URL(string: "https://api.skipdb.tv/api/segments") else { return }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlReq.timeoutInterval = 10
        do {
            urlReq.httpBody = try JSONEncoder().encode(req)
            let (_, response) = try await URLSession.shared.data(for: urlReq)
            if let http = response as? HTTPURLResponse {
                DiagnosticsLog.log("skip", "submit leg=community status=\(http.statusCode)")
                if !(200..<300).contains(http.statusCode) {
                    log.info("community skip submit returned \(http.statusCode, privacy: .public) (best-effort, ignored)")
                }
            }
        } catch {
            DiagnosticsLog.log("skip", "submit leg=community transport-error")
            log.info("community skip submit failed (best-effort, ignored): \(String(describing: error), privacy: .public)")
        }
    }

    /// The user's optional custom SkipDB-compatible leg. Best-effort, exactly like the community leg:
    /// no configured URL means no submission and no error; any failure is logged, not thrown. POSTs the
    /// same SubmitRequest body to `<customBase>/api/segments`. NOT VortX edge-signed: this is a
    /// third-party host (VortXEdgeAuth only stamps our own *.vortx.tv hosts), so we never call sign() here.
    private static func submitToCustom(_ req: SubmitRequest) async {
        guard let base = CustomSkipProvider.baseURL() else {   // no/invalid URL: silently skip
            DiagnosticsLog.log("skip", "submit leg=custom skipped=no-url")
            return
        }
        guard let url = URL(string: base + "/api/segments") else { return }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ApiKeys.customSkipKey() {   // optional: some mirrors are keyless
            urlReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlReq.timeoutInterval = 10
        do {
            urlReq.httpBody = try JSONEncoder().encode(req)
            let (_, response) = try await URLSession.shared.data(for: urlReq)
            if let http = response as? HTTPURLResponse {
                DiagnosticsLog.log("skip", "submit leg=custom status=\(http.statusCode)")
                if !(200..<300).contains(http.statusCode) {
                    log.info("custom skip provider submit returned \(http.statusCode, privacy: .public) (best-effort, ignored)")
                }
            }
        } catch {
            DiagnosticsLog.log("skip", "submit leg=custom transport-error")
            log.info("custom skip provider submit failed (best-effort, ignored): \(String(describing: error), privacy: .public)")
        }
    }

    /// Remove the cached VortX skip entry for an episode so the next fetch picks up the submission.
    static func invalidateCache(imdbId: String, season: Int?, episode: Int?, durationSeconds: Double) async {
        let key = SkipTimestampService.vortxCacheKey(imdbId: imdbId, season: season,
                                                     episode: episode, durationSeconds: durationSeconds)
        await SkipTimestampStore.shared.invalidate(for: key)
    }

    /// Minimal JSON value so a contribute error body (mixed bool/string fields) decodes without a
    /// dedicated type; only the `error` string is read.
    private enum JSONValue: Decodable {
        case string(String)
        case bool(Bool)
        case other

        var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s) }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else { self = .other }
        }
    }
}
