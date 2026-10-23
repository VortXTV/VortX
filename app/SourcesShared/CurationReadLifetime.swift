import SwiftUI
import Combine

/// One original read owner for a visible collection hierarchy. Context loss revokes the worker
/// token before publishing a new generation; only an explicit surface reload can create authority.
@MainActor final class CurationReadLifetime: ObservableObject {
    @Published private(set) var generation = UUID()
    private(set) var artworkLifetime = CurationArtworkLifetime(active: false)
    private(set) var profileID: UUID?
    private var authority: CurationReadAuthority?
    private var originalImportRegisters: [String: VortxJSON] = [:]
    private var pinnedImportRegisters: [String: VortxJSON] = [:]
    private let captureAuthority: @MainActor () throws -> CurationReadAuthority
    private let retireCaches: @MainActor (UUID) -> Void
    private var subscriptions = Set<AnyCancellable>()

    init(captureAuthority: @escaping @MainActor () throws -> CurationReadAuthority = { try .capture() },
         identityChanges: AnyPublisher<Void, Never>? = nil,
         contextChanges: AnyPublisher<Void, Never>? = nil,
         retireCaches: @escaping @MainActor (UUID) -> Void = {
             CurationStaticArtwork.retire(lifetime: $0)
             CurationSourceController.retireReadLifetime($0)
         }) {
        self.captureAuthority = captureAuthority; self.retireCaches = retireCaches
        (identityChanges ?? Self.appIdentityChanges()).sink { @Sendable [weak self] in
            // @Published identity events occur in willSet. Invalidate unconditionally here;
            // reading the getters at that point would miss A -> B -> A.
            CurationReadContextDelivery.perform { [weak self] in self?.invalidate() }
        }.store(in: &subscriptions)
        (contextChanges ?? Self.appContextChanges()).sink { @Sendable [weak self] in
            CurationReadContextDelivery.perform { [weak self] in self?.revalidate() }
        }.store(in: &subscriptions)
        renew()
    }

    private static func appIdentityChanges() -> AnyPublisher<Void, Never> {
        Publishers.Merge(ProfileStore.shared.$activeID.dropFirst().map { _ in () },
                         VortXSyncManager.shared.$isSignedIn.dropFirst().map { _ in () })
            .eraseToAnyPublisher()
    }

    private static func appContextChanges() -> AnyPublisher<Void, Never> {
        // Remote host publications use the watchlist note as well as the explicit import note.
        var notes = [VortXSyncManager.credentialScopeDidChangeNote,
                     XperienceCollectionsStore.changedNote, LibraryAutoAdd.watchlistChangedNote]
        notes.append(CoreBridge.xperienceContextChangedNote)
        return Publishers.MergeMany(notes.map { name in
            NotificationCenter.default.publisher(for: name).map { _ in () }.eraseToAnyPublisher()
        }).eraseToAnyPublisher()
    }

    /// Capture once before the synchronous import-model read. bindImports may select evidence
    /// from this snapshot, never refresh it from a successor native target.
    func renew() {
        invalidate()
        do {
            let captured = try captureAuthority()
            guard captured.isCurrent() else { captured.retire(); return }
            authority = captured; profileID = captured.profileID
            originalImportRegisters = captured.importRegisters
            let activeArtwork = CurationArtworkLifetime()
            artworkLifetime = activeArtwork
            generation = activeArtwork.id
        } catch {
            // No signed-in local fallback and no replacement target capture on failure.
        }
    }

    func accepts(_ expected: UUID) -> Bool {
        guard artworkLifetime.isActive, expected == generation, let authority else { return false }
        return authority.isCurrent()
    }

    /// Bind after the synchronous import read and before making its shelf/destination eligible.
    @discardableResult func bindImports(_ fingerprints: [String: String]) -> Bool {
        guard accepts(generation) else { return false }
        do {
            pinnedImportRegisters = try CurationImportReadEvidence.binding(
                fingerprints: fingerprints, original: originalImportRegisters, retaining: pinnedImportRegisters)
            guard importsAreCurrent() else { invalidate(); return false }
            return true
        } catch {
            invalidate(); return false
        }
    }

    /// Notes are hints. Exact original target and selected raw registers decide retirement; own
    /// ACKs and unrelated namespace publications do not fabricate a change or capture a successor.
    func revalidate() {
        guard authority != nil else { return }
        if !accepts(generation) || !importsAreCurrent() { invalidate() }
    }

    private func importsAreCurrent() -> Bool {
        guard !pinnedImportRegisters.isEmpty else { return true }
        guard let authority, authority.isCurrent(),
              let current = try? authority.currentImportRegisters() else { return false }
        return CurationImportReadEvidence.matches(pinned: pinnedImportRegisters, current: current)
    }

    private func invalidate() {
        let retiredGeneration = generation
        artworkLifetime.revoke() // Lock-only barrier precedes authority retirement/publication.
        authority?.retire()
        authority = nil; profileID = nil
        originalImportRegisters = [:]; pinnedImportRegisters = [:]
        let inactiveArtwork = CurationArtworkLifetime(active: false)
        artworkLifetime = inactiveArtwork
        generation = inactiveArtwork.id
        retireCaches(retiredGeneration)
    }
}
