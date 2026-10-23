import Foundation

// Add to the existing ForYouStore integration, after common curation methods are integrated.
// Uses the original native installed-registry capture. No separate Xperience namespace write.
extension ForYouStore: XperienceCurationExportStore {
    func captureXperienceExportEdit(_ collection: SmartCollection) throws -> CurationEditSession {
        try captureRichEdit(collection)
    }
    func xperienceExportEditIsCurrent(_ session: CurationEditSession) -> Bool { isCurrentRichEdit(session) }
    func xperienceExportContextIsCurrent(_ session: CurationEditSession) -> Bool {
        guard let target = session.target else { return false }
        return CoreBridge.shared.nativeXperienceContextIsCurrent(target)
    }
    func xperienceExportCandidates(_ session: CurationEditSession) throws -> [XperienceAddonBinding.Candidate] {
        guard isCurrentRichEdit(session) else { throw XperienceExportFailure.staleContext }
        guard let target = session.target else { throw XperienceExportFailure.unavailable }
        return try CoreBridge.shared.nativeXperienceSnapshot(target: target).candidates
    }
    func saveXperienceExport(_ document: CurationDocument, session: CurationEditSession) async throws {
        try await saveRich(document, session: session)
    }
    func retireXperienceExportEdit(_ session: CurationEditSession) { retireRichEdit(session) }
}
