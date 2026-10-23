import Foundation

/// Cold/source-transition validator. All fingerprints come from native Rust; exact canonical
/// evidence output is compared as bytes, with no VortxJSON number conversion.
struct OwnerHistoryExactSourceValidation: Sendable {
    let abi: any VortxRuntimeABI
    struct Canonical: Sendable {
        let evidence: Data
        let receipt: Data
    }
    func canonicalize(_ evidence: Data) throws -> Canonical {
        guard evidence.count <= OwnerHistorySessionRuntime.maximumBytes,
              let input = String(data: evidence, encoding: .utf8), !input.utf8.contains(0),
              let output = abi.canonicalizeOwnerHistoryEvidence(input),
              output.utf8.count <= OwnerHistorySessionRuntime.maximumBytes else { throw VortxNativeError.unavailable }
        let object = try OwnerHistoryExactJSON.Object(Data(output.utf8))
        guard Set(object.fields.keys) == ["kind", "evidence", "receipt"],
              try object.text("kind") == "owner_history_evidence" else { throw VortxNativeError.invalidResponse }
        return try .init(evidence: object.required("evidence"), receipt: object.required("receipt"))
    }
    func validate(snapshot: Data, journal: VortxNativeOwnerHistoryJournal, scope: VortxAccountScope,
                  authority: any VortxMutationAuthority) throws {
        try authority.withActive {}
        let root = try OwnerHistoryExactJSON.Object(snapshot)
        let native = try OwnerHistoryExactJSON.Object(root.required("nativeSync"))
        guard try OwnerHistoryExactJSON.sameText(native.text("scope"), scope.account),
              try OwnerHistoryExactJSON.sameText(native.text("ownerProfileId"), scope.ownerProfileID) else {
            throw VortxNativeError.invalidSnapshot
        }
        let schema = try JSONDecoder().decode(Int.self, from: native.required("schemaVersion"))
        guard let historyBytes = native["ownerHistory"] else {
            guard (1...5).contains(schema), journal.entries.isEmpty else { throw VortxNativeError.invalidSnapshot }
            try authority.withActive {}; return
        }
        guard schema == 6 else { throw VortxNativeError.invalidSnapshot }
        let history = try OwnerHistoryExactJSON.Object(historyBytes)
        guard Set(history.fields.keys) == ["schemaVersion", "capability", "sources", "attestations"],
              try JSONDecoder().decode(Int.self, from: history.required("schemaVersion")) == 1,
              try history.text("capability") == "vortx.owner-history-fallback/1" else {
            throw VortxNativeError.invalidSnapshot
        }
        let carrier = try OwnerHistoryExactJSON.Object(history.required("sources"))
        guard Set(carrier.fields.keys) == ["sources"] else { throw VortxNativeError.invalidSnapshot }
        let sources = try OwnerHistoryExactJSON.Object(carrier.required("sources"))
        let attestations = try OwnerHistoryExactJSON.Object(history.required("attestations"))
        guard !sources.fields.isEmpty, Set(sources.fields.keys) == Set(attestations.fields.keys) else {
            throw VortxNativeError.invalidSnapshot
        }
        let replay = try journal.replayAll(expectedSourceIDs: Set(sources.fields.keys), authority: authority)
        for id in sources.fields.keys.sorted() {
            try Task.checkCancellation()
            let proof = try OwnerHistoryExactJSON.Object(attestations.required(id))
            guard Set(proof.fields.keys) == ["binding", "receipt"] else { throw VortxNativeError.invalidSnapshot }
            let replayed = try canonicalize(replay.evidenceBySourceID[id]!)
            let stored = try canonicalize(sources.required(id))
            let receipt = try OwnerHistoryExactJSON.Object(replayed.receipt)
            guard replayed.evidence == stored.evidence, replayed.receipt == stored.receipt,
                  try receipt.text("sourceId") == id,
                  try OwnerHistoryExactJSON.canonical(proof.required("receipt"))
                    == OwnerHistoryExactJSON.canonical(replayed.receipt),
                  try OwnerHistoryExactJSON.canonical(proof.required("binding"))
                    == OwnerHistoryExactJSON.canonical(VortxNativeHostFieldEvidence.canonicalData(replay.bindingBySourceID[id]!)),
                  try OwnerHistoryExactJSON.canonical(replayed.receipt)
                    == OwnerHistoryExactJSON.canonical(VortxNativeHostFieldEvidence.canonicalData(replay.receiptBySourceID[id]!))
            else { throw VortxNativeError.invalidSnapshot }
        }
        try authority.withActive {}
    }
}
