// Standalone full-production CurationReadLifetime notification regression. Only its authority,
// app/cache surfaces and unused import-evidence types are small stubs. No native/JSON/artwork IO.
import Combine
import Foundation

enum CurationLifetimeHarnessFailure: Error { case assertion(String), unexpectedDefaultCapture, unusedEvidence }
enum VortxJSON: Sendable {} // This lane never binds/imports a register; no substitute JSON parser.

@MainActor struct CurationReadAuthority {
    let profileID: UUID
    let importRegisters: [String: VortxJSON]
    let isCurrent: @MainActor () -> Bool
    let currentImportRegisters: @MainActor () throws -> [String: VortxJSON]
    let retire: @MainActor () -> Void
    static func capture() throws -> Self { throw CurationLifetimeHarnessFailure.unexpectedDefaultCapture }
}
enum CurationImportReadEvidence {
    static func binding(fingerprints: [String: String], original: [String: VortxJSON],
                        retaining pinned: [String: VortxJSON]) throws -> [String: VortxJSON] {
        throw CurationLifetimeHarnessFailure.unusedEvidence
    }
    static func matches(pinned: [String: VortxJSON], current: [String: VortxJSON]) -> Bool {
        preconditionFailure("Standalone lane must not substitute raw register evidence")
    }
}
enum XperienceCollectionsStore { static let changedNote = Notification.Name("fixture.importChanged") }
enum LibraryAutoAdd { static let watchlistChangedNote = Notification.Name("fixture.watchlistChanged") }
@MainActor enum CurationStaticArtwork {
    static func retire(lifetime: UUID) { preconditionFailure("Inject cache receipt, never artwork IO") }
}
@MainActor enum CurationSourceController {
    static func retireReadLifetime(_ lifetime: UUID) { preconditionFailure("Inject cache receipt, never catalog IO") }
}

@main @MainActor enum CurationReadLifetimeHarness {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CurationLifetimeHarnessFailure.assertion(message) }
        checks += 1
    }
    @MainActor final class AuthorityFixture {
        let profile = UUID()
        var current = true
        var captures = 0
        var retirements = 0
        var retiredCaches = Set<UUID>()
        func capture() -> CurationReadAuthority {
            captures += 1
            return .init(profileID: profile, importRegisters: [:], isCurrent: { self.current },
                         currentImportRegisters: { [:] }, retire: { self.retirements += 1 })
        }
    }

    /// The active flag is sampled on the real posting queue, before MainActor resumes this test.
    static func post(_ name: Notification.Name, original: CurationArtworkLifetime) async -> (Bool, Bool) {
        let rawName = name.rawValue
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { @Sendable in
                NotificationCenter.default.post(name: .init(rawValue: rawName), object: nil)
                continuation.resume(returning: (!Thread.isMainThread, original.isActive))
            }
        }
    }

    static func defaultBackgroundMapsAndContextABA() async throws {
        for note in [VortXSyncManager.credentialScopeDidChangeNote, XperienceCollectionsStore.changedNote,
                     LibraryAutoAdd.watchlistChangedNote, CoreBridge.xperienceContextChangedNote] {
            let fixture = AuthorityFixture()
            // Only authority/cache operations are injected. Both production publisher factories are DEFAULT.
            let lifetime = CurationReadLifetime(captureAuthority: { fixture.capture() },
                                               retireCaches: { id in _ = fixture.retiredCaches.insert(id) })
            let original = lifetime.artworkLifetime
            let generation = lifetime.generation
            try require(original.isActive && lifetime.accepts(generation) && fixture.captures == 1,
                        "actual read lifetime captures one original authority")
            let (backgroundUnchanged, activeUnchanged) = await post(note, original: original)
            try require(backgroundUnchanged && activeUnchanged && lifetime.generation == generation
                        && fixture.retirements == 0 && fixture.captures == 1,
                        "unchanged default background hint preserves the original generation")
            fixture.current = false
            let (backgroundLost, activeAtReturn) = await post(note, original: original)
            try require(backgroundLost && !activeAtReturn,
                        "actual lock-backed artwork token is revoked before background post returns")
            try require(!lifetime.accepts(generation) && lifetime.profileID == nil && fixture.retirements == 1
                        && fixture.retiredCaches.contains(generation),
                        "actual default map retires original authority and its generation caches")
            fixture.current = true
            _ = await post(note, original: original)
            try require(!original.isActive && !lifetime.accepts(generation) && fixture.captures == 1
                        && fixture.retirements == 1,
                        "default background context ABA cannot revive or recapture original read authority")
        }
    }

    static func defaultIdentityABA() throws {
        let priorProfile = ProfileStore.shared.activeID
        let priorSignIn = VortXSyncManager.shared.isSignedIn
        defer { ProfileStore.shared.activeID = priorProfile; VortXSyncManager.shared.isSignedIn = priorSignIn }
        for identity in ["profile", "account"] {
            let fixture = AuthorityFixture()
            ProfileStore.shared.activeID = fixture.profile; VortXSyncManager.shared.isSignedIn = false
            let lifetime = CurationReadLifetime(captureAuthority: { fixture.capture() },
                                               retireCaches: { id in _ = fixture.retiredCaches.insert(id) })
            let original = lifetime.artworkLifetime
            let generation = lifetime.generation
            if identity == "profile" { ProfileStore.shared.activeID = UUID() }
            else { VortXSyncManager.shared.isSignedIn = true }
            try require(!original.isActive && !lifetime.accepts(generation) && fixture.retirements == 1,
                        "actual default Published map revokes before identity setter returns")
            ProfileStore.shared.activeID = fixture.profile; VortXSyncManager.shared.isSignedIn = false
            try require(!original.isActive && !lifetime.accepts(generation) && fixture.captures == 1
                        && fixture.retirements == 1,
                        "default Published identity ABA cannot revive original read lifetime")
        }
    }

    static func main() async throws {
        try await defaultBackgroundMapsAndContextABA()
        try defaultIdentityABA()
        print("PASS actual CurationReadLifetime background notification checks: \(checks)")
    }
}
