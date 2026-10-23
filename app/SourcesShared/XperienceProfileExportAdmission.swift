import Foundation

/// Recovery-only candidate for the parent source writer. No network or storage.
/// Requires the small parseCompleteRaw seam in complete-parser-seam.patch.
/// Not compiled or tested in this task: the parent explicitly prohibited those jobs.
enum XperienceProfileExportAdmission {
    enum Failure: Error, Equatable {
        case invalidEnvelope
        case unsupportedVersion
    }

    struct Projection: Equatable, Sendable {
        let name: String
        let collections: XperienceCollections.Document
        /// Local digest only; the upstream format has no content revision token.
        let opaqueUpstreamRevision: String
        /// Preview-only input for a separately reviewed common-model mapper.
        /// May contain imported add-on credentials or private prompts/list choices.
        /// NEVER persist or sync this object directly.
        let untrustedConfig: VortxJSON
    }

    static func parse(_ data: Data) throws -> Projection {
        // Parse the WHOLE envelope before projection, retaining duplicate-member
        // rejection and byte/depth/node/number bounds even in ignored fields.
        let raw = try XperienceCollections.parseCompleteRaw(data)
        guard case .object(let envelope) = raw,
              envelope["exportType"] == .string("xperienceProfile"),
              let version = envelope["exportVersion"] else {
            throw Failure.invalidEnvelope
        }
        switch version {
        case .integer(1), .unsigned(1): break
        case .integer, .unsigned: throw Failure.unsupportedVersion
        default: throw Failure.invalidEnvelope
        }
        guard case .string(let name) = envelope["name"],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 320,
              case .object(let config) = envelope["config"],
              let collectionValue = config["collections"] else {
            throw Failure.invalidEnvelope
        }
        // Existing projection preserves unknown collection/folder/source fields.
        // Its native import/privacy gate remains required before any save.
        let document = try XperienceCollections.project(collectionValue)
        return Projection(name: name, collections: document,
                          opaqueUpstreamRevision: XperienceCollections.digest(raw),
                          untrustedConfig: .object(config))
    }
}
