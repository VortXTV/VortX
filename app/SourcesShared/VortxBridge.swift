import Foundation
import os
#if canImport(VortxEngine)
import VortxEngine
#endif

// Phase 7 cutover, slice 1: the vortx-core engine enters the shipping app in SHADOW mode only.
//
// `VortxBridge` is a thin Swift wrapper over the vortx-ffi C ABI (VortxEngine.xcframework, the
// vortx-core kernel packaged as a staticlib: vortx_init_runtime / vortx_resolve_json /
// vortx_get_state_json / vortx_string_free / vortx_engine_free). `VortxShadowRanking` is its first
// consumer: behind the `vortxShadowRanking` UserDefaults flag (default OFF) it re-ranks the SAME
// stream list `StreamRanking` just ranked and logs any ordering divergence. The Swift ranker stays
// authoritative; nothing here ever feeds the UI.
//
// The framework links into VortXiOSNative only for this slice, so the whole engine surface is
// guarded with `canImport(VortxEngine)`: every other target (tvOS, Mac, legacy) compiles the no-op
// side and behaves byte-identically.

/// The shadow-ranking feature flag. UserDefaults-backed, default OFF: a build with the flag unset
/// takes exactly one boolean read and no other new code path.
enum VortxShadowFlag {
    static let key = "vortxShadowRanking"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

#if canImport(VortxEngine)

/// Thin wrapper over the vortx-core C ABI, mirroring how `CoreBridge` manages the stremiox_core_*
/// handle: one process-wide instance, every call serialized on one queue (the FFI contract is one
/// call at a time per handle), every returned `char*` freed with `vortx_string_free` exactly once,
/// and the handle freed with `vortx_engine_free` on teardown.
///
/// The kernel is PURE (no network, no disk, no clock), so calls are synchronous and cheap; the
/// bridge does no I/O of its own. It does NOT touch the account token, the Keychain, or any
/// stremio-core state: the runtime is seeded with a fixed local owner id used only for shadow work.
final class VortxBridge {
    static let shared = VortxBridge()

    private static let log = Logger(subsystem: "com.stremiox.app", category: "vortxbridge")

    /// Serializes every FFI call on one handle (the documented thread contract: dispatch and delta
    /// mutate through the pointer, so calls must never overlap).
    private let queue = DispatchQueue(label: "com.stremiox.vortx-ffi", qos: .utility)
    /// The opaque `VortxEngine*` handle. Created lazily on first use, freed in deinit. Guarded by
    /// `queue` (only ever touched inside `queue.sync`).
    private var engine: OpaquePointer?
    /// Set after an init failure so a broken runtime logs once, not per call.
    private var initFailed = false

    private init() {}

    deinit {
        // Null-safe by contract; the singleton normally lives for the process, this is hygiene.
        vortx_engine_free(engine)
    }

    /// Create the runtime on first use. Called only on `queue`.
    private func ensureEngineLocked() -> OpaquePointer? {
        if let engine { return engine }
        guard !initFailed else { return nil }
        // Fixed local identity for the shadow runtime. Deliberately NOT the user's account: the
        // shadow ranks with the engine's default profile prefs and holds no user data.
        engine = vortx_init_runtime("vortx-shadow", "Shadow")
        if engine == nil {
            initFailed = true
            Self.log.error("vortx_init_runtime returned NULL; shadow engine unavailable")
        }
        return engine
    }

    /// Resolve one JSON request (`stream_load` / `settle_streams` / `streams` / ...) through
    /// `vortx_resolve_json`. Returns the response JSON, or nil if the runtime could not be created.
    /// Malformed input comes back as well-formed `{"kind":"error",...}` JSON per the ABI contract,
    /// never nil, so nil strictly means "no engine".
    func resolve(_ requestJSON: String) -> String? {
        queue.sync {
            guard let engine = ensureEngineLocked() else { return nil }
            guard let out = requestJSON.withCString({ vortx_resolve_json(engine, $0) }) else {
                // The ABI only returns NULL for a NULL engine/request, neither of which can happen
                // here; log so a contract break is visible instead of silent.
                Self.log.error("vortx_resolve_json returned NULL")
                return nil
            }
            defer { vortx_string_free(out) }
            return String(cString: out)
        }
    }

    /// The engine's full state document (`vortx_get_state_json`). Diagnostic surface for the shadow.
    func stateJSON() -> String? {
        queue.sync {
            guard let engine = ensureEngineLocked() else { return nil }
            guard let out = vortx_get_state_json(engine) else { return nil }
            defer { vortx_string_free(out) }
            return String(cString: out)
        }
    }

    /// Rank an already-fetched stream list (the `streams` resolve request: the settle-side ranking
    /// step of a stream load, fed directly since the host owns its own networking). `streams` are
    /// add-on protocol stream objects; `cached[i]` marks stream i debrid-cached. Returns the ranked
    /// order as indices into `streams` (best first), or nil when the engine is unavailable or the
    /// response did not parse.
    func rankStreams(_ streams: [[String: Any]], cached: [Bool]) -> [Int]? {
        let request: [String: Any] = ["kind": "streams", "streams": streams, "cached": cached]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8),
              let responseJSON = resolve(json),
              let responseData = responseJSON.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else { return nil }
        guard let kind = response["kind"] as? String, kind == "streams",
              let ranked = response["ranked"] as? [[String: Any]]
        else {
            let err = (response["error"] as? String) ?? "unexpected kind"
            Self.log.error("rankStreams: engine answered error: \(err, privacy: .public)")
            return nil
        }
        return ranked.compactMap { $0["raw_index"] as? Int }
    }
}

#endif

/// The shadow ranking diff: rank the SAME assembled inputs `StreamRanking` ranked, through
/// vortx-core, and log divergence. Pure observation: the caller has already published the Swift
/// ranker's result before this runs, and nothing here can reach the UI.
enum VortxShadowRanking {
    private static let log = Logger(subsystem: "com.stremiox.app", category: "vortxshadow")
    /// Bound so a pathological source list cannot make the shadow serialize megabytes of JSON.
    private static let maxStreams = 2000

    /// Fire-and-forget shadow diff over one rebuilt source list. Flag OFF (the default) returns
    /// after a single boolean read. Flag ON spawns a detached utility task, so the live rank and
    /// publish path is never delayed either way.
    ///
    /// - Parameters mirror the live rank call in `SourceListModel.rebuild`: the same assembled
    ///   groups, continuity hint, pin, confirmed-cached hashes, and the frozen prefs snapshot the
    ///   Swift rank ran under (installed as the same task-local, so both rankers read identical
    ///   preferences).
    static func observe(groups: [CoreStreamSourceGroup], continuity: String?, pin: ResolvedPin?,
                        cachedHashes: Set<String>, prefs: SourcePreferences.Snapshot, metaId: String) {
        guard VortxShadowFlag.isOn else { return }
        #if canImport(VortxEngine)
        // Redacted AFTER the flag gate (the doc contract above: flag OFF stays a single boolean read) and
        // BEFORE anything else sees the value: the meta id is a catalog id (viewing history) and every use
        // past this point is an os.Logger line with privacy: .public, so `diff`/`report` only ever receive
        // the producer-side redaction token -- the same convention as SourceListModel's health line. Lines
        // about one title still correlate within one run, which is all the divergence log needs.
        let metaToken = VXProbeRedaction.identityToken(metaId)
        Task.detached(priority: .utility) {
            SourcePreferences.$readingOverride.withValue(prefs) {
                diff(groups: groups, continuity: continuity, pin: pin,
                     cachedHashes: cachedHashes, metaToken: metaToken)
            }
        }
        #else
        // Framework not linked into this target (slice 1 links iOS only): note it (flag-ON only)
        // so a tester on tvOS/Mac knows why nothing diffs, then keep the live path untouched.
        log.info("vortxShadowRanking is ON but VortxEngine is not linked in this target")
        #endif
    }

    #if canImport(VortxEngine)

    /// `metaToken` is the ALREADY-REDACTED stand-in for the page's meta id (`VXProbeRedaction.identityToken`,
    /// applied once in `observe`). Inside this function and everything it calls the value is used for log
    /// lines ONLY -- it keys nothing, fetches nothing, and must never be re-joined with an engine input.
    private static func diff(groups: [CoreStreamSourceGroup], continuity: String?, pin: ResolvedPin?,
                             cachedHashes: Set<String>, metaToken: String) {
        // The shared playable universe, in flat add-on/list order: the same filter playablePairs
        // applies inside StreamRanking (playable and not a bare YouTube trailer row).
        let candidates = groups.flatMap { g in g.streams.map { $0 } }
            .filter { $0.playableURL != nil && !$0.isYouTubeTrailer }
        guard !candidates.isEmpty else { return }
        let sent = Array(candidates.prefix(maxStreams))

        // The authoritative Swift order over the SAME groups (score + continuity + binge + pin,
        // deduplicated by playable URL), exactly what the batch/auto-retry paths consume.
        let swiftOrder = StreamRanking.rankedCandidates(groups, continuity: continuity, pin: pin,
                                                        debridCachedHashes: cachedHashes)
        let swiftKeys = swiftOrder.compactMap { $0.playableURL?.absoluteString }

        // The engine's order over the same universe.
        let streams = sent.map(streamDict)
        let cached = sent.map { s in
            (s.infoHash?.lowercased()).map(cachedHashes.contains) == true
        }
        guard let rankedIndices = VortxBridge.shared.rankStreams(streams, cached: cached) else {
            log.error("shadow[\(metaToken, privacy: .public)]: engine unavailable or bad response; no diff")
            return
        }
        // Map back to streams, then deduplicate by playable URL in ENGINE order (keep the engine's
        // best duplicate), the same rule the Swift side's URL dedup applies to its own order.
        var seen = Set<String>()
        let engineKeys: [String] = rankedIndices.compactMap { i in
            guard sent.indices.contains(i), let url = sent[i].playableURL?.absoluteString else { return nil }
            return seen.insert(url).inserted ? url : nil
        }

        report(metaToken: metaToken, swiftKeys: swiftKeys, engineKeys: engineKeys,
               labelFor: labelIndex(sent), truncated: candidates.count > sent.count, pinned: pin != nil)
    }

    /// Compare the two orders and emit one summary line (plus a first-divergence detail when they
    /// disagree). Divergence here is DATA, not failure: the engine ranks with its own default prefs
    /// profile in this slice, so the log is the parity work list for retiring StreamRanking.
    private static func report(metaToken: String, swiftKeys: [String], engineKeys: [String],
                               labelFor: [String: String], truncated: Bool, pinned: Bool) {
        // The universes can differ at the margin (Swift's user filters may drop junk/filtered rows
        // that the engine kept). Diff the ORDER over the intersection so a size mismatch does not
        // drown the ordering signal, but report both counts.
        let engineSet = Set(engineKeys)
        let swiftShared = swiftKeys.filter(engineSet.contains)
        let swiftSet = Set(swiftKeys)
        let engineShared = engineKeys.filter(swiftSet.contains)

        let agreePrefix = zip(swiftShared, engineShared).prefix(while: { $0.0 == $0.1 }).count
        let total = min(swiftShared.count, engineShared.count)
        let sameTop = swiftShared.first == engineShared.first

        if agreePrefix == total, swiftShared.count == engineShared.count {
            log.info("shadow[\(metaToken, privacy: .public)]: AGREE order n=\(total) swift=\(swiftKeys.count) engine=\(engineKeys.count) pinned=\(pinned) truncated=\(truncated)")
            return
        }
        let swiftTop = swiftShared.first.flatMap { labelFor[$0] } ?? "-"
        let engineTop = engineShared.first.flatMap { labelFor[$0] } ?? "-"
        log.notice("shadow[\(metaToken, privacy: .public)]: DIVERGE sameTop=\(sameTop) agreePrefix=\(agreePrefix)/\(total) swift=\(swiftKeys.count) engine=\(engineKeys.count) pinned=\(pinned) truncated=\(truncated)")
        if agreePrefix < total {
            let sLabel = labelFor[swiftShared[agreePrefix]] ?? "-"
            let eLabel = labelFor[engineShared[agreePrefix]] ?? "-"
            log.notice("shadow[\(metaToken, privacy: .public)]: first diff at #\(agreePrefix): swift=\(sLabel, privacy: .public) engine=\(eLabel, privacy: .public) | swiftTop=\(swiftTop, privacy: .public) engineTop=\(engineTop, privacy: .public)")
        }
    }

    /// Compact display labels keyed by playable URL, for the divergence log only (release-name
    /// text, never the URL itself: stream URLs can embed debrid account tokens).
    private static func labelIndex(_ streams: [CoreStream]) -> [String: String] {
        var out: [String: String] = [:]
        for s in streams {
            guard let key = s.playableURL?.absoluteString, out[key] == nil else { continue }
            let name = (s.name ?? s.behaviorHints?.filename ?? s.description ?? "?")
                .replacingOccurrences(of: "\n", with: " ")
            out[key] = String(name.prefix(60))
        }
        return out
    }

    /// One add-on protocol stream object for the engine, from the decoded `CoreStream`. Only the
    /// wire fields the engine's ranker parses; app-side synthetics (media-server provenance, nzb
    /// fields) have no engine equivalent yet and are omitted.
    private static func streamDict(_ s: CoreStream) -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = s.url { d["url"] = v }
        if let v = s.ytId { d["ytId"] = v }
        if let v = s.infoHash { d["infoHash"] = v }
        if let v = s.fileIdx { d["fileIdx"] = v }
        if let v = s.externalUrl { d["externalUrl"] = v }
        if let v = s.name { d["name"] = v }
        if let v = s.description { d["description"] = v }
        var hints: [String: Any] = [:]
        if let b = s.behaviorHints {
            if let v = b.bingeGroup { hints["bingeGroup"] = v }
            if let v = b.filename { hints["filename"] = v }
            if let v = b.notWebReady { hints["notWebReady"] = v }
        }
        if !hints.isEmpty { d["behaviorHints"] = hints }
        return d
    }

    #endif
}
