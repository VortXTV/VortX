import Foundation

/// A denial-only projection of retained, not-yet-attributed host evidence. An empty result
/// is NOT permission to offer a card: native, metadata, source, and draft authority remain required.
enum VortxNativeExternalCWPending {
    struct Denials: Sendable {
        private let candidates: [VortxNativeExternalCW.Candidate]
        private var reasons: [Data: String] = [:]

        init(candidates: [VortxNativeExternalCW.Candidate]) throws {
            guard !candidates.isEmpty, candidates.count <= 16,
                  Set(candidates.map { Data($0.key.utf8) }).count == candidates.count,
                  candidates.allSatisfy({ candidate in
                      candidate.type == "series" && !candidate.metaId.isEmpty
                          && candidate.metaId.utf8.count <= 512 && !candidate.key.isEmpty
                          && candidate.key.utf8.count <= 512 && candidate.titleSpellings.count <= 16
                          && candidate.titleSpellings.contains(where: { $0.utf8.elementsEqual(candidate.metaId.utf8) })
                          && candidate.titleSpellings.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
                  }) else { throw VortxNativeError.invalidResponse }
            self.candidates = candidates
        }

        mutating func denyTitle(_ title: String, reason: String) {
            for candidate in candidates where candidate.titleSpellings.contains(where: {
                $0.utf8.elementsEqual(title.utf8)
            }) { reasons[Data(candidate.key.utf8)] = reason }
        }
        mutating func denyUnattributable(reason: String) {
            for candidate in candidates { reasons[Data(candidate.key.utf8)] = reason }
        }
        func reason(for candidateKey: String) -> String? { reasons[Data(candidateKey.utf8)] }

        /// May only narrow an already validated native verdict. Never turns suppressed or
        /// unresolved into eligible, and never manufactures a unit/title identity.
        func narrowing(_ verdicts: [VortxNativeExternalCW.Verdict]) throws -> [VortxNativeExternalCW.Verdict] {
            guard verdicts.count == candidates.count,
                  Set(verdicts.map { Data($0.key.utf8) }) == Set(candidates.map { Data($0.key.utf8) }) else {
                throw VortxNativeError.invalidResponse
            }
            return verdicts.map { verdict in
                guard verdict.disposition == .eligible, let reason = reason(for: verdict.key) else { return verdict }
                return .init(key: verdict.key, disposition: .unresolved, reason: reason)
            }
        }

        /// Cold worker only. Parse exact source bytes for attribution; never re-encode or
        /// replace the archive. Opaque title IDs use UTF-8 equality, including NFC/NFD.
        mutating func overlay(_ bytes: Data, profileID: String, reason: String,
                              check: () throws -> Void) throws {
            try check()
            let root = try VortxProfileOverlayWitness.decodeObject(json: bytes)
            guard Set(root.keys).isSubset(of: ["vortx", "webProgress"]) else {
                denyUnattributable(reason: reason); return
            }
            func selected(_ raw: Any?) throws -> Any? {
                guard let raw else { return nil }
                guard let profiles = raw as? [String: Any], profiles.count == 1,
                      let entry = profiles.first, entry.key.utf8.elementsEqual(profileID.utf8) else {
                    throw VortxNativeError.invalidSnapshot
                }
                return entry.value
            }
            var knownTitles: [(id: String, type: String)] = []
            if let raw = root["vortx"] {
                guard let vortx = raw as? [String: Any], Set(vortx.keys) == ["byProfile"],
                      let bucket = try selected(vortx["byProfile"]) as? [String: Any] else {
                    throw VortxNativeError.invalidSnapshot
                }
                // Unknown bucket fields could carry watch intent. That is genuinely unknown
                // attribution, not a blanket denial merely because a known other title is pending.
                if !Set(bucket.keys).isSubset(of: ["library", "watched", "removed", "ownerHistory"]) {
                    denyUnattributable(reason: reason)
                }
                for field in ["library", "ownerHistory"] {
                    guard let raw = bucket[field] else { continue }
                    guard let rows = raw as? [Any] else { denyUnattributable(reason: reason); continue }
                    for rawRow in rows {
                        try check()
                        guard let row = rawRow as? [String: Any], let id = row["id"] as? String, !id.isEmpty else {
                            denyUnattributable(reason: reason); continue
                        }
                        // Known movie-only rows cannot mask a series candidate. Missing/unknown
                        // type is not clearance; the exact title remains denied conservatively.
                        if let type = row["type"] as? String, ["series", "movie"].contains(type) {
                            knownTitles.append((id, type))
                        }
                        if row["type"] as? String != "movie" { denyTitle(id, reason: reason) }
                    }
                }
                if let raw = bucket["watched"] {
                    if let rows = raw as? [String: Any] {
                        for (id, row) in rows {
                            try check()
                            guard !id.isEmpty, row is [String: Any] else { denyUnattributable(reason: reason); continue }
                            denyTitle(id, reason: reason)
                        }
                    } else { denyUnattributable(reason: reason) }
                }
                try removals(bucket["removed"], knownTitles: knownTitles, reason: reason, check: check)
            }
            if let raw = root["webProgress"] {
                guard let web = raw as? [String: Any], Set(web.keys) == ["removed"],
                      let removed = web["removed"] as? [String: Any], Set(removed.keys) == ["byProfile"] else {
                    throw VortxNativeError.invalidSnapshot
                }
                try removals(selected(removed["byProfile"]), knownTitles: knownTitles, reason: reason, check: check)
            }
            try check()
        }

        private mutating func removals(_ raw: Any?, knownTitles: [(id: String, type: String)],
                                      reason: String, check: () throws -> Void) throws {
            guard let raw else { return }
            guard let rows = raw as? [Any] else { denyUnattributable(reason: reason); return }
            for rawRow in rows {
                try check()
                guard let row = rawRow as? [String: Any], let keys = row["keys"] as? [String], !keys.isEmpty else {
                    denyUnattributable(reason: reason); continue
                }
                for key in keys {
                    // Use the actual ingress matcher, not a new opaque-ID parser. The matcher
                    // only broadens denial; it never establishes equivalence or eligible identity.
                    let matches = candidates.filter { candidate in
                        candidate.titleSpellings.contains { title in
                            VortxLegacyBootstrapMaterial.removalMatches(key, meta: title, type: candidate.type)
                        }
                    }
                    for candidate in matches { reasons[Data(candidate.key.utf8)] = reason }
                    if matches.isEmpty && !knownTitles.contains(where: {
                        VortxLegacyBootstrapMaterial.removalMatches(key, meta: $0.id, type: $0.type)
                    }) {
                        // An unresolved removal alias may refer to this candidate: unlike a
                        // known other library row, it has no verified title attribution here.
                        denyUnattributable(reason: reason)
                    }
                }
            }
        }
    }
}
