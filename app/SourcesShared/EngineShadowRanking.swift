import Foundation
import os

#if canImport(VortXCore)
import VortXCore
#endif

/// SHADOW MODE for the VortX engine's stream ranker: the first on-device increment of the core
/// cutover. When the flag is ON, every stream list the Swift ranker orders is ALSO handed to the
/// vortx-core engine (`vortx_resolve_json`, kind "streams"), and the two orders are compared and
/// LOGGED. Nothing the user sees changes: the Swift order still drives the UI; the engine result
/// only feeds DiagnosticsLog + os.Logger so divergence can be pulled off a device.
///
/// Acceptance built in: each shadow pass calls the engine TWICE with byte-identical input and
/// verifies the two ranked outputs are byte-identical (the engine's fixed-point determinism
/// promise, resolve.rs "byte-reproducible across the Swift, Kotlin, and TS bridges").
///
/// Flag: UserDefaults bool "vortx.engineShadowRanking" (default OFF), or env
/// VORTX_ENGINE_SHADOW=1 for dev runs. Developer-facing; no settings UI in this increment.
enum EngineShadowRanking {
    static let flagKey = "vortx.engineShadowRanking"

    private static let log = Logger(subsystem: "com.stremiox.app", category: "engine-shadow")
    private static let queue = DispatchQueue(label: "vortx.engine.shadow", qos: .utility)

    /// Big titles return thousands of streams; the shadow compares a prefix so the JSON pass stays
    /// cheap. Both rankers see the SAME capped list, so the comparison stays apples-to-apples.
    private static let maxStreams = 400

    /// Re-ranking runs per render; only shadow a given (streams, cached) snapshot once.
    private static let dedupeLock = NSLock()
    private static var lastSnapshotHash: Int = 0

    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["VORTX_ENGINE_SHADOW"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Hand the already-fetched (and already user-filtered) stream groups to the engine and log the
    /// divergence against the Swift ranker. Never blocks the caller beyond snapshotting scores that
    /// StreamRanking just memoized; never changes what the user sees.
    static func shadowCompare(_ groups: [CoreStreamSourceGroup]) {
        guard isEnabled else { return }
        let flat = Array(groups.flatMap { $0.streams }.prefix(maxStreams))
        guard flat.count > 1 else { return }

        // Snapshot everything preference-dependent on the CALLER's thread, exactly where the real
        // ranking pass just ran, so SourcePreferences/TrackPreferences see the same state. Scores
        // are memoized by StreamRanking, so this is cache hits, not a re-parse.
        let swiftScores = flat.map { StreamRanking.score($0) }
        let cached = flat.map { StreamRanking.isCached($0, StreamRanking.signature($0)) }
        let languages = TrackPreferences.current.audioLanguages

        var hasher = Hasher()
        for s in flat { hasher.combine(s.id) }
        for c in cached { hasher.combine(c) }
        let snapshot = hasher.finalize()
        dedupeLock.lock()
        let seen = snapshot == lastSnapshotHash
        lastSnapshotHash = snapshot
        dedupeLock.unlock()
        guard !seen else { return }

        // The Swift baseline: the global play order (score desc, stable by input index), the same
        // rule rankedGroups applies per group and best() applies globally.
        let swiftOrder = flat.indices.sorted {
            swiftScores[$0] != swiftScores[$1] ? swiftScores[$0] > swiftScores[$1] : $0 < $1
        }

        guard let request = buildRequest(flat, cached: cached, languages: languages) else {
            log.error("shadow request JSON build failed (n=\(flat.count))")
            return
        }
        queue.async { runShadow(request: request, swiftOrder: swiftOrder, swiftScores: swiftScores, count: flat.count) }
    }

    /// The engine's resolve request: the wire shape of resolve.rs ResolveRequest::Streams. Field
    /// names must match vortx-protocol's serde renames (url / ytId / infoHash / fileIdx /
    /// externalUrl / name / description / behaviorHints.filename+bingeGroup) or they silently
    /// deserialize as absent. Serialized ONCE so both engine calls get byte-identical input.
    private static func buildRequest(_ streams: [CoreStream], cached: [Bool], languages: [String]) -> String? {
        var streamsJSON: [[String: Any]] = []
        streamsJSON.reserveCapacity(streams.count)
        for s in streams {
            var d: [String: Any] = [:]
            if let v = s.url { d["url"] = v }
            if let v = s.ytId { d["ytId"] = v }
            if let v = s.infoHash { d["infoHash"] = v }
            if let v = s.fileIdx { d["fileIdx"] = v }
            if let v = s.externalUrl { d["externalUrl"] = v }
            if let v = s.name { d["name"] = v }
            if let v = s.description { d["description"] = v }
            var hints: [String: Any] = [:]
            if let v = s.behaviorHints?.filename { hints["filename"] = v }
            if let v = s.behaviorHints?.bingeGroup { hints["bingeGroup"] = v }
            if !hints.isEmpty { d["behaviorHints"] = hints }
            streamsJSON.append(d)
        }
        // Explicit prefs, so the engine does not depend on its own profile store here: cached_first
        // mirrors the Swift +8000 cached bonus; preferred_languages mirrors the language demotion.
        // The Swift source-type tier order has no engine twin yet (SourceClass is a different axis),
        // a known, expected divergence source for this increment.
        let request: [String: Any] = [
            "kind": "streams",
            "streams": streamsJSON,
            "cached": cached,
            "prefs": [
                "cached_first": true,
                "preferred_languages": languages,
                "source_type_order": [String](),
                "keyword_include": [String](),
                "keyword_exclude": [String](),
            ],
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request, options: []),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    #if canImport(VortXCore)

    /// One engine runtime for the process. The streams resolve is a read-only query with explicit
    /// prefs, so no state or persistence is involved; the handle only carries the default profile.
    private static let engineHandle: OpaquePointer? = vortx_init_runtime("owner", "Owner")

    private static func resolveJSON(_ request: String) -> String? {
        guard let engine = engineHandle else { return nil }
        return request.withCString { c -> String? in
            guard let out = vortx_resolve_json(engine, c) else { return nil }
            defer { vortx_string_free(out) }
            return String(cString: out)
        }
    }

    private static func runShadow(request: String, swiftOrder: [Int], swiftScores: [Int], count: Int) {
        // The acceptance gate: same stream list in, byte-identical ranked order out, twice.
        guard let first = resolveJSON(request), let second = resolveJSON(request) else {
            emit("engine call failed (handle=\(engineHandle == nil ? "nil" : "ok"), n=\(count))", error: true)
            return
        }
        let deterministic = first == second
        if !deterministic {
            emit("DETERMINISM FAIL: two identical requests returned different bytes (n=\(count), a=\(first.utf8.count)B, b=\(second.utf8.count)B)", error: true)
        }

        guard let parsed = parseRanked(first) else {
            emit("unparseable engine response: \(String(first.prefix(200)))", error: true)
            return
        }
        let engineOrder = parsed.map { $0.rawIndex }

        // Divergence shape vs the Swift order.
        let top1Match = engineOrder.first == swiftOrder.first
        let overlap5 = Set(engineOrder.prefix(5)).intersection(Set(swiftOrder.prefix(5))).count
        let firstDivergence = zip(engineOrder, swiftOrder).enumerated().first { $1.0 != $1.1 }?.offset
        let compared = min(engineOrder.count, swiftOrder.count)
        let agreeing = zip(engineOrder, swiftOrder).filter { $0 == $1 }.count

        let engineTop = parsed.prefix(5).map { "\($0.rawIndex):\($0.score)" }.joined(separator: ",")
        let swiftTop = swiftOrder.prefix(5).map { "\($0):\(swiftScores[$0])" }.joined(separator: ",")
        emit("determinism=\(deterministic ? "ok" : "FAIL") n=\(count) engineRanked=\(engineOrder.count) " +
             "top1Match=\(top1Match) top5Overlap=\(overlap5)/5 firstDiv=\(firstDivergence.map(String.init) ?? "none") " +
             "agree=\(agreeing)/\(compared) engineTop5=[\(engineTop)] swiftTop5=[\(swiftTop)]")
    }

    private static func parseRanked(_ json: String) -> [(rawIndex: Int, score: Int64)]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["kind"] as? String == "streams",
              let ranked = obj["ranked"] as? [[String: Any]] else { return nil }
        return ranked.compactMap { entry in
            guard let idx = entry["raw_index"] as? Int else { return nil }
            let score = (entry["score"] as? NSNumber)?.int64Value ?? 0
            return (rawIndex: idx, score: score)
        }
    }

    #else

    /// Targets that do not link VortXCore.xcframework (e.g. the web-host shell) compile the shadow
    /// to a no-op after the flag check.
    private static func runShadow(request: String, swiftOrder: [Int], swiftScores: [Int], count: Int) {}

    #endif

    private static func emit(_ message: String, error: Bool = false) {
        if error { log.error("\(message, privacy: .public)") } else { log.info("\(message, privacy: .public)") }
        DiagnosticsLog.log("engine-shadow", message)
    }
}
