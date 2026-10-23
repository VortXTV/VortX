// Synthetic lifecycle and pool fault tests for the actual curation production types.
// Root runs these in its allocated serial lane with the actual integrated source. Synthetic data,
// injected read authority and a controlled image loader perform no network, native or secure writes.
import Combine
import CoreGraphics
import Foundation

@MainActor enum CurationPresentationLifecycleTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        checks += 1
    }

    // Combine subjects synchronize subscribers internally. This test-only box allows sending the
    // notification hint from a worker without pretending that the UI/fixture itself is Sendable.
    final class Notes: @unchecked Sendable {
        let subject = PassthroughSubject<Void, Never>()
        func send() { subject.send(()) }
    }

    @MainActor final class AuthorityFixture {
        let profileID = UUID()
        var epoch = UUID()
        var registers: [String: VortxJSON] = [:]
        var captures = 0
        var retired = 0

        func capture() -> CurationReadAuthority {
            captures += 1
            let originalEpoch = epoch
            return .init(profileID: profileID, importRegisters: registers,
                isCurrent: { self.epoch == originalEpoch },
                currentImportRegisters: { self.registers },
                retire: { self.retired += 1 })
        }
    }

    actor Gate<Value: Sendable> {
        private var entered = Set<String>()
        private var pending: [String: CheckedContinuation<Value, Never>] = [:]
        func enter(_ key: String) async -> Value {
            entered.insert(key)
            return await withCheckedContinuation { pending[key] = $0 }
        }
        func hasEntered(_ key: String) -> Bool { entered.contains(key) }
        func count() -> Int { entered.count }
        func release(_ key: String, _ value: Value) { pending.removeValue(forKey: key)?.resume(returning: value) }
    }

    static func eventually(_ condition: @escaping () async -> Bool) async throws {
        // Bounded deterministic checkpoints instead of wall-clock sleeps. A failure identifies a
        // missing lifecycle/queue transition; it never starts a transport to make a fixture progress.
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        throw Failure.assertion("expected checkpoint was not reached")
    }

    static func lifetime(_ fixture: AuthorityFixture, identities: Notes = .init(),
                         contexts: Notes = .init(),
                         retire: @escaping @MainActor (UUID) -> Void = { _ in }) -> CurationReadLifetime {
        CurationReadLifetime(captureAuthority: { fixture.capture() },
            identityChanges: identities.subject.eraseToAnyPublisher(),
            contextChanges: contexts.subject.eraseToAnyPublisher(), retireCaches: retire)
    }

    static func document(title: String = "Original") throws -> XperienceCollections.Document {
        try XperienceCollections.project(.array([.object([
            "id": .string("collection"), "title": .string(title),
            "folders": .array([.object([
                "id": .string("folder"), "title": .string("Folder"),
                "sources": .array([.object([
                    "provider": .string("addon"), "addonId": .string("fixture.addon"),
                    "type": .string("movie"), "catalogId": .string("fixture")
                ])])
            ])])
        ])]))
    }

    static func namespace(_ id: UUID, document: XperienceCollections.Document,
                          digest: String = String(repeating: "a", count: 64),
                          clock: Int64 = 1) throws -> (field: String, register: VortxJSON) {
        let source = document.collections[0].folders[0].sources[0]
        let mapping = XperienceAddonBinding.Mapping(manifestID: "fixture.addon", transportDigest: digest)
        let edit = try XperienceImportNamespace.append(document: document, label: "Synthetic",
            namespace: id, bindings: [XperienceAddonBinding.key(for: source): mapping])
        return (edit.field, .object([
            "clock": .integer(clock), "actor": .string("11111111-1111-4111-8111-111111111111"),
            "value": edit.value
        ]))
    }

    static func authorityLossIsSynchronousAndCannotRevive() async throws {
        for cause in ["credential generation", "native installation", "native registry"] {
            let fixture = AuthorityFixture(), contexts = Notes()
            var evictions: [UUID] = []
            let owner = lifetime(fixture, contexts: contexts) { evictions.append($0) }
            let original = owner.generation, token = owner.artworkLifetime
            var revokedBeforePublication = false
            let subscription = owner.$generation.dropFirst().sink { _ in
                revokedBeforePublication = !token.isActive
            }
            let originalEpoch = fixture.epoch
            fixture.epoch = UUID()
            let revokedWhenPostingReturned = await Task.detached {
                contexts.send()
                return !token.isActive
            }.value
            try require(revokedWhenPostingReturned && revokedBeforePublication,
                        "\(cause) revokes the original lock token in the posting turn before UI publication")
            try require(!owner.accepts(original) && evictions.contains(original) && fixture.retired == 1,
                        "\(cause) retires the original cache owner and original authority")
            fixture.epoch = originalEpoch
            contexts.send()
            try require(!owner.accepts(original) && !token.isActive && fixture.captures == 1,
                        "\(cause) A-B-A cannot revive or recapture the original read")
            subscription.cancel()
        }
    }

    static func publishedIdentityIsUnconditionallyRetired() throws {
        let fixture = AuthorityFixture(), identities = Notes()
        let owner = lifetime(fixture, identities: identities)
        let original = owner.generation, token = owner.artworkLifetime
        // The captured getter still reports A, as @Published willSet does at this boundary.
        identities.send()
        try require(!owner.accepts(original) && !token.isActive && fixture.captures == 1,
                    "identity willSet retires before getters change and cannot recapture A-B-A")
    }

    static func unchangedOwnACKPreservesOriginalRead() throws {
        let fixture = AuthorityFixture(), contexts = Notes(), id = UUID()
        let doc = try document(), saved = try namespace(id, document: doc)
        fixture.registers = [saved.field: saved.register]
        let owner = lifetime(fixture, contexts: contexts)
        let original = owner.generation, token = owner.artworkLifetime
        try require(owner.bindImports([id.uuidString.lowercased(): doc.fingerprint]),
                    "visible namespace pins its exact original register")
        contexts.send()
        fixture.registers["xperience.import." + UUID().uuidString.lowercased()] = .object(["value": .null])
        contexts.send()
        try require(owner.accepts(original) && token.isActive && fixture.retired == 0 && fixture.captures == 1,
                    "unchanged own ACK and an unrelated namespace preserve original read authority")
    }

    static func namespaceReplacementBindingAndRemovalRetire() throws {
        for cause in ["document replacement", "binding replacement", "register metadata", "tombstone", "removal"] {
            let fixture = AuthorityFixture(), contexts = Notes(), id = UUID()
            let doc = try document(), saved = try namespace(id, document: doc)
            fixture.registers = [saved.field: saved.register]
            var evicted: [UUID] = []
            let owner = lifetime(fixture, contexts: contexts) { evicted.append($0) }
            let original = owner.generation, token = owner.artworkLifetime
            try require(owner.bindImports([id.uuidString.lowercased(): doc.fingerprint]),
                        "\(cause) fixture binds the original namespace")
            switch cause {
            case "document replacement":
                fixture.registers[saved.field] = try namespace(id, document: document(title: "Replacement")).register
            case "binding replacement":
                let changed = try namespace(id, document: doc, digest: String(repeating: "b", count: 64)).register
                let projection = try XperienceSavedNamespace.read(field: saved.field, register: changed)
                try require(projection.document.fingerprint == doc.fingerprint,
                            "binding-only change keeps document fingerprint unchanged")
                fixture.registers[saved.field] = changed
            case "register metadata": fixture.registers[saved.field] = try namespace(id, document: doc, clock: 2).register
            case "tombstone": fixture.registers[saved.field] = .object(["clock": .integer(2),
                "actor": .string("11111111-1111-4111-8111-111111111111"), "value": .null])
            default: fixture.registers.removeValue(forKey: saved.field)
            }
            contexts.send()
            try require(!owner.accepts(original) && !token.isActive && evicted.contains(original),
                        "\(cause) clears the original presentation and requests both cache evictions")
            fixture.registers[saved.field] = saved.register
            contexts.send()
            try require(!owner.accepts(original) && fixture.captures == 1,
                        "\(cause) restored bytes cannot revive a retired original owner")
        }
    }

    static func laterBindingCannotRecaptureReplacement() throws {
        let fixture = AuthorityFixture(), id = UUID()
        let originalDoc = try document(), original = try namespace(id, document: originalDoc)
        fixture.registers = [original.field: original.register]
        let owner = lifetime(fixture)
        let token = owner.artworkLifetime
        let replacementDoc = try document(title: "Later")
        fixture.registers[original.field] = try namespace(id, document: replacementDoc).register
        try require(!owner.bindImports([id.uuidString.lowercased(): replacementDoc.fingerprint]),
                    "a later import-model read cannot select replacement bytes under the original target")
        try require(!token.isActive && fixture.captures == 1,
                    "failed evidence binding retires instead of recapturing")
    }

    static func title(_ id: String) -> MetaPreview {
        .init(id: id, type: "movie", name: id, poster: nil, posterShape: nil, popularity: nil)
    }

    static func sourceQueueAndLateResultCannotSurviveRetirement() async throws {
        let pool = CurationSourceRequestPool(), token = CurationArtworkLifetime()
        let gate = Gate<CurationLoadedTitles>(), result = CurationLoadedTitles([title("synthetic")])
        let prefix = token.id.uuidString + "|"
        let first = Task { try await pool.load(key: prefix + "first", lifetime: token) { await gate.enter("first") } }
        let second = Task { try await pool.load(key: prefix + "second", lifetime: token) { await gate.enter("second") } }
        try await eventually { await gate.count() == 2 }
        let queued = Task { try await pool.load(key: prefix + "queued", lifetime: token) { await gate.enter("queued") } }
        try await eventually { await pool.state(lifetime: token.id).queued == 1 }
        token.revoke()
        await pool.retire(lifetime: token.id)
        let state = await pool.state(lifetime: token.id)
        try require(state.jobs == 0 && state.queued == 0 && state.cached == 0,
                    "source retirement cancels queued jobs and evicts original cached rows")
        await gate.release("first", result); await gate.release("second", result)
        for work in [first, second, queued] {
            do { _ = try await work.value; throw Failure.assertion("retired source returned late rows") }
            catch is CancellationError { checks += 1 }
        }
        let starts = await gate.count(), after = await pool.state(lifetime: token.id)
        try require(starts == 2 && after.cached == 0,
                    "a revoked queued source never enters its operation and late rows never enter cache")
    }

    static func sourceCacheIsEvicted() async throws {
        let pool = CurationSourceRequestPool(), token = CurationArtworkLifetime()
        let key = token.id.uuidString + "|cached"
        _ = try await pool.load(key: key, lifetime: token) { CurationLoadedTitles([title("cached")]) }
        let before = await pool.state(lifetime: token.id)
        try require(before.cached == 1, "source fixture retains a completed nonempty row")
        token.revoke(); await pool.retire(lifetime: token.id)
        let after = await pool.state(lifetime: token.id)
        try require(after.cached == 0, "source retirement removes completed rows as well as active jobs")
    }

    static func image() throws -> CurationArtworkImage {
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage() else { throw Failure.assertion("CGImage fixture") }
        return CurationArtworkImage(image)
    }

    static func artworkQueueAndCacheCannotSurviveRetirement() async throws {
        let gate = Gate<CurationArtworkImage>(), image = try image()
        let pool = CurationArtworkPool(loader: { key, _, _ in await gate.enter(key) })
        let token = CurationArtworkLifetime()
        let first = Task { try await pool.load(url: "first", resourceID: "first", lifetime: token, thumbnailDimension: 64) }
        let second = Task { try await pool.load(url: "second", resourceID: "second", lifetime: token, thumbnailDimension: 64) }
        try await eventually { await gate.count() == 2 }
        let queued = Task { try await pool.load(url: "queued", resourceID: "queued", lifetime: token, thumbnailDimension: 64) }
        try await eventually { await pool.state(lifetime: token.id).queued == 1 }
        token.revoke(); await pool.retire(lifetime: token.id)
        await gate.release("first", image); await gate.release("second", image)
        for work in [first, second, queued] {
            do { _ = try await work.value; throw Failure.assertion("retired artwork returned late pixels") }
            catch is CancellationError { checks += 1 }
        }
        let starts = await gate.count(), state = await pool.state(lifetime: token.id)
        try require(starts == 2 && state.cached == 0 && state.bytes == 0 && state.queued == 0,
                    "artwork revocation rejects resumed waiters and late pixels without cache retention")

        let cachePool = CurationArtworkPool(loader: { _, _, _ in image }), cacheToken = CurationArtworkLifetime()
        _ = try await cachePool.load(url: "cached", resourceID: "cached", lifetime: cacheToken, thumbnailDimension: 64)
        let cached = await cachePool.state(lifetime: cacheToken.id)
        try require(cached.cached == 1 && cached.bytes > 0, "artwork fixture retains completed pixels")
        cacheToken.revoke(); await cachePool.retire(lifetime: cacheToken.id)
        let evicted = await cachePool.state(lifetime: cacheToken.id)
        try require(evicted.cached == 0 && evicted.bytes == 0, "artwork retirement removes retained pixels and cost")
    }

    static func run() async throws {
        try await authorityLossIsSynchronousAndCannotRevive()
        try publishedIdentityIsUnconditionallyRetired()
        try unchangedOwnACKPreservesOriginalRead()
        try namespaceReplacementBindingAndRemovalRetire()
        try laterBindingCannotRecaptureReplacement()
        try await sourceQueueAndLateResultCannotSurviveRetirement()
        try await sourceCacheIsEvicted()
        try await artworkQueueAndCacheCannotSurviveRetirement()
    }
}
