import Foundation

/// Read-only offers retain their original native and metadata ownership until use.
enum VortxNativeExternalCW {
    struct Candidate: Codable, Equatable, Sendable {
        let key: String
        let type: String
        let metaId: String
        let videoId: String
        let titleSpellings: [String]
        let season: Int?
        let episode: Int?
    }
    struct Metadata: Sendable {
        struct Video: Equatable, Sendable {
            let id: String
            let season: Int?
            let episode: Int?
        }
        let id: String
        let type: String
        let videos: [Video]
        let receipt: UUID
    }
    struct Verdict: Decodable, Equatable, Sendable {
        enum Disposition: String, Decodable, Sendable { case eligible, suppressed, unresolved }
        let key: String
        let disposition: Disposition
        let reason: String
    }
    struct Request: Encodable {
        let kind = "external_cw_eligibility"
        let profileId: String
        let candidates: [Candidate]
    }
    struct Response: Decodable {
        let kind: String
        let profileId: String
        let verdicts: [Verdict]
    }
    static func decode(_ raw: String, profileID: String, candidates: [Candidate]) throws -> [Verdict] {
        guard raw.utf8.count <= 32_768 else { throw VortxNativeError.invalidResponse }
        let response = try JSONDecoder().decode(Response.self, from: Data(raw.utf8))
        guard response.kind == "external_cw_eligibility", response.profileId == profileID,
              response.verdicts.count == candidates.count,
              Set(response.verdicts.map { Data($0.key.utf8) }).count == candidates.count,
              Set(response.verdicts.map { Data($0.key.utf8) }) == Set(candidates.map { Data($0.key.utf8) }),
              response.verdicts.allSatisfy({ $0.disposition != .eligible || $0.reason == "clear" }) else {
            throw VortxNativeError.invalidResponse
        }
        return response.verdicts
    }

    struct Resolution: Sendable {
        let verdicts: [Verdict]
        let authority: any VortxMutationAuthority
    }
    /// Small Session-owned epoch, not a source authority. Retirement takes only this lock.
    /// Real lease/original FIFO/draft locks surround it; only the runtime reservation follows.
    final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = UUID()
        func capture() -> UUID { lock.withLock { value } }
        func retire() { lock.withLock { value = UUID() } }
        func withActive(_ expected: UUID, _ operation: () throws -> Void) throws {
            try lock.withLock {
                guard expected == value else { throw VortxNativeError.superseded }
                try operation()
            }
        }
    }

    final class Read: @unchecked Sendable {
        private let lock = NSLock()
        private var owned: [Metadata] = []
        private var attempted: Set<Data> = []
        private var queryStarted = false
        private var publicationAuthority: (any VortxMutationAuthority)?
        private let original: VortxNativeFIFOAdmission.ReadCapability
        private let metadataCurrent: @Sendable ([Metadata]) -> Bool
        private let prepare: @Sendable (String) async throws -> Metadata
        private let resolve: @Sendable ([Candidate]) async throws -> Resolution
        init(original: VortxNativeFIFOAdmission.ReadCapability,
             metadataCurrent: @escaping @Sendable ([Metadata]) -> Bool,
             prepare: @escaping @Sendable (String) async throws -> Metadata,
             resolve: @escaping @Sendable ([Candidate]) async throws -> Resolution) {
            self.original = original; self.prepare = prepare
            self.metadataCurrent = metadataCurrent; self.resolve = resolve
        }
        func isCurrent() -> Bool {
            do {
                let retained = lock.withLock { (publicationAuthority, owned) }
                // Do not wrap the composite receipt in original.withActive: it owns the
                // lease -> original source/FIFO order itself.
                let authority: any VortxMutationAuthority = retained.0 ?? original
                try authority.withActive {
                    guard metadataCurrent(retained.1) else { throw VortxNativeError.superseded }
                }
                return true
            } catch { return false }
        }
        /// Called only for the bounded slice of a completely read inventory. It reuses this
        /// original native read; neither metadata success nor an error can mint a replacement.
        func prepareMetadata(id: String) async throws -> Metadata {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard isCurrent(), !id.isEmpty, id.utf8.count <= 512 else { throw VortxNativeError.superseded }
                let admitted = lock.withLock { () -> Bool in
                    let exactID = Data(id.utf8)
                    guard attempted.count < 16, !attempted.contains(exactID) else { return false }
                    attempted.insert(exactID); return true
                }
                guard admitted else { throw VortxNativeError.superseded }
                let value = try await prepare(id)
                try Task.checkCancellation()
                guard isCurrent(), value.id.utf8.elementsEqual(id.utf8), value.type == "series" else { throw VortxNativeError.superseded }
                // Store the exact returned receipt before the final check, never compare raw values
                // alone: replace -> restore of identical metadata still retires an older receipt.
                lock.withLock { owned.append(value) }
                guard isCurrent() else { throw VortxNativeError.superseded }
                return value
            } onCancel: { [original] in original.cancel() }
        }
        func query(_ candidates: [Candidate]) async throws -> [Verdict] {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard isCurrent(), !candidates.isEmpty, candidates.count <= 16,
                      Set(candidates.map { Data($0.key.utf8) }).count == candidates.count else { throw VortxNativeError.superseded }
                for candidate in candidates {
                    let owners = lock.withLock { owned.filter { $0.id.utf8.elementsEqual(candidate.metaId.utf8) && $0.type == candidate.type } }
                    guard owners.count == 1, let owner = owners.first,
                          candidate.titleSpellings.contains(where: { $0.utf8.elementsEqual(candidate.metaId.utf8) }),
                          owner.videos.filter({ $0.id.utf8.elementsEqual(candidate.videoId.utf8) }).count == 1,
                          owner.videos.filter({ $0.season == candidate.season && $0.episode == candidate.episode }).count == 1,
                          owner.videos.filter({ $0.id.utf8.elementsEqual(candidate.videoId.utf8) && $0.season == candidate.season
                              && $0.episode == candidate.episode }).count == 1 else { throw VortxNativeError.invalidResponse }
                }
                // One bounded query owns one receipt. Retrying this Read with a new draft
                // could revive a previously offered card after A -> B -> A, so never recapture.
                let admitted = lock.withLock { () -> Bool in
                    guard !queryStarted else { return false }; queryStarted = true; return true
                }
                guard admitted else { throw VortxNativeError.superseded }
                let result = try await resolve(candidates)
                try Task.checkCancellation()
                lock.withLock { publicationAuthority = result.authority }
                guard isCurrent() else { throw VortxNativeError.superseded }
                return result.verdicts
            } onCancel: { [original] in original.cancel() }
        }
    }
}
