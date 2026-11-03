import Foundation

// This namespace hosts the WHOLE actual CoreBridge.installNativeSession method unchanged.
// Session/facade/subtitle/Bridge storage and presentation collaborators are synthetic. Controlled
// waits exercise the production installation control flow with the ACTUAL manager cloud authority;
// they do not certify native FIFO/checkpoint durability, app publication or provider playback.
@MainActor enum ProviderCloudInstallationFixture {
    @MainActor final class World {
        var pause: String?
        var visits = Set<String>()
        var release: CheckedContinuation<Void, Never>?
        var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
        var subtitleBegins = 0, subtitleFinishes = 0, created = 0, switches = 0
        var closes = 0, profiles = 0, seeds = 0, boards = 0, libraries = 0
        var savedProfile = AdoptionWorld.owner
        var failProfiles = false, failSeed = false, failOrigin = false
        var callbackRetirements = 0, invalidations = 0, clears = 0
        var closedIDs = Set<UUID>()
        var callback: ((String) -> Void)?
        func visit(_ name: String) async {
            visits.insert(name)
            observers.removeValue(forKey: name)?.forEach { $0.resume() }
            if pause == name { await withCheckedContinuation { release = $0 } }
        }
        func wait(_ name: String) async {
            if visits.contains(name) { return }
            await withCheckedContinuation { observers[name, default: []].append($0) }
        }
        func resume() { pause = nil; let value = release; release = nil; value?.resume() }
    }
    static var world = World()
    struct VortxResourceAddon {}
    struct UserProfile {}
    @MainActor final class ProfileStore { static let shared = ProfileStore() }
    @MainActor final class VortxNativeSession {
        let scope: VortxAccountScope
        var revoked = false
        init(capture: CredentialScopeRegistry.Capture) {
            scope = .init(account: capture.namespace, ownerProfileID: AdoptionWorld.owner.uuidString)
        }
        func revoke() { revoked = true }
    }
    @MainActor enum CredentialPublicationOutbox {
        struct SubtitleRetirement {}
        static func beginSubtitleRetirement(domain: UUID) -> SubtitleRetirement {
            world.subtitleBegins += 1; return .init()
        }
        static func finishSubtitleRetirement(_ value: SubtitleRetirement) { world.subtitleFinishes += 1 }
        static func waitForSubtitleRetirement(_ value: SubtitleRetirement) async { await world.visit("subtitle") }
    }
    @MainActor final class ReadLifetime {
        func retire() -> CredentialPublicationOutbox.SubtitleRetirement { .init() }
        func completeRetirement(_ value: CredentialPublicationOutbox.SubtitleRetirement) {}
    }
    @MainActor final class MetadataFence { func retireInstallation() {} }
    @MainActor final class CallbackLifetime {
        func retire() { world.callbackRetirements += 1 }
        func prepare(_ generation: UUID) {}
        func bind(_ generation: UUID, credential: CredentialScopeRegistry.Capture, sourceID: UUID) {}
    }
    @MainActor final class VortxNativeCoreFacade {
        struct Binding { let profileID: String; let accountGeneration: UUID }
        let sourceID = UUID()
        var watchlistBinding: Binding?
        var registryBinding: Binding?
        private var closed = false
        init() {
            let binding = Binding(profileID: world.savedProfile.uuidString, accountGeneration: UUID())
            watchlistBinding = binding; registryBinding = binding
        }
        static func create(session: VortxNativeSession, registry: [VortxResourceAddon],
            progressAccepted: () -> Void, sourceEvent: () -> Void, changed: (Int) -> Void) async throws -> VortxNativeCoreFacade {
            world.created += 1
            await world.visit("facade")
            return .init()
        }
        func mutateProfiles(_ actions: [VortxJSON], hostEdits: [Int], expectedProfileID: String,
            expectedAccountGeneration: UUID, sourceAuthority: any VortxMutationAuthority) async throws {
            await world.visit("switch")
            try sourceAuthority.withActive {
                guard case .string(let requested)? = actions.first?["id"] else { throw VortxNativeError.invalidSnapshot }
                let binding = Binding(profileID: requested, accountGeneration: expectedAccountGeneration)
                watchlistBinding = binding; registryBinding = binding; world.switches += 1
            }
        }
        func close() { if !closed { closed = true; world.closes += 1; world.closedIDs.insert(sourceID); world.callback?("facade.close") } }
    }
    @MainActor final class CoreBridge {
        static let xperienceContextChangedNote = Notification.Name("fixture.provider-cloud-installation")
        let nativeSubtitleDomain = UUID()
        let nativeFacadeLock = NSRecursiveLock()
        let nativePlaybackReadLifetime = ReadLifetime()
        let nativeMetadataAdmissionFence = MetadataFence()
        let nativeCallbackLifetime = CallbackLifetime()
        var nativeInstallGeneration = UUID(), nativeCallbackGeneration = UUID()
        var nativePlaylistChangeRevision: UInt64 = 0
        var nativeFacadeStorage: VortxNativeCoreFacade?
        var nativeCredentialCapture: CredentialScopeRegistry.Capture?
        var nativeAccountEditRequests: [UUID: Int] = [:]
        var nativePublishedCredentialSlot: String?
        var nativePublishedAccountGeneration: UUID?
        var nativeProfileBaseline: [UserProfile] = []
        var publicationEpoch = UUID()
        var visible: String? = "original"
        struct ClearAuthority { let generation: UUID }
        // Declared original-owner clear collaborator. Actual broad UI cleanup has separate gates.
        func invalidatePublicationEpoch() -> ClearAuthority? {
            publicationEpoch = UUID(); world.invalidations += 1
            return .init(generation: publicationEpoch)
        }
        func clearNativePublishedState(authority: ClearAuthority) -> ClearAuthority? {
            guard originalMetadataClearAuthorityIsCurrent(authority) else { return nil }
            world.clears += 1; visible = nil; return authority
        }
        func originalMetadataClearAuthorityIsCurrent(_ authority: ClearAuthority) -> Bool {
            authority.generation == publicationEpoch && nativeFacadeStorage == nil
        }
        func fixtureInstallSuccessor(capture: CredentialScopeRegistry.Capture) -> VortxNativeCoreFacade {
            let successor = VortxNativeCoreFacade()
            nativeFacadeStorage = successor; nativeCredentialCapture = capture
            nativeInstallGeneration = UUID(); publicationEpoch = UUID()
            nativeProfileBaseline = [.init()]; visible = "successor"
            return successor
        }
        struct Origin { let facade: VortxNativeCoreFacade; let installation: UUID; let capture: CredentialScopeRegistry.Capture }
        func activateNativePresentationBoundary() {}
        func makeNativeSourceCallback(installation: UUID, credential: CredentialScopeRegistry.Capture) -> () -> Void { {} }
        func nativeInstalledSourceOrigin(producer: VortxNativeCoreFacade, installation: UUID,
            credential: CredentialScopeRegistry.Capture) -> Origin? {
            guard !world.failOrigin, nativeFacadeStorage === producer else { return nil }
            return .init(facade: producer, installation: installation, capture: credential)
        }
        func nativeCallbackOriginIsCurrent(_ origin: Origin) -> Bool {
            nativeFacadeStorage === origin.facade && nativeInstallGeneration == origin.installation
                && CredentialScopeRegistry.shared.isCurrent(origin.capture)
        }
        func refreshNativeProfiles() throws { world.profiles += 1; world.callback?("profiles"); if world.failProfiles { throw VortxNativeError.unavailable } }
        func seedNativeInstalledSource(_ origin: Origin) -> Bool { world.seeds += 1; return !world.failSeed && nativeCallbackOriginIsCurrent(origin) }
        func loadBoard() { world.boards += 1 }
        func loadLibrary() { world.libraries += 1; world.callback?("library") }
        // @@ACTUAL_CORE_INSTALLATION@@
    }
    static func cases(makeManager: () throws -> VortXSyncManager) async throws -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        for selection in ["nil", "matching", "different"] {
            for boundary in ["subtitle", "facade", "switch"] {
                if boundary == "switch" && selection != "different" { continue }
                let manager = try makeManager(), source = AdoptionWorld.current
                world = World(); world.pause = boundary
                let authority = try manager.fixtureBoundCloudAuthority(plaintext: source.plaintext, revision: source.revision)
                let bridge = CoreBridge(), capture = CredentialScopeRegistry.shared.capture()
                let requested = selection == "nil" ? nil : (selection == "matching" ? AdoptionWorld.owner : UUID())
                let task = Task { @MainActor in
                    do {
                        try await bridge.installNativeSession(VortxNativeSession(capture: capture), registry: [],
                            capture: capture, initialProfileID: requested, initialProfileSource: authority,
                            installationSource: authority)
                        return true
                    } catch { return false }
                }
                await world.wait(boundary)
                manager.dataKey = Data(repeating: 0x42, count: 32); manager.dataKey = AdoptionWorld.key
                world.resume()
                let completed = await task.value
                results.append((!completed && bridge.nativeFacadeStorage == nil && world.profiles == 0
                    && world.seeds == 0 && world.boards == 0 && world.libraries == 0,
                    "actual installation rejects original source after \(boundary) wait with \(selection) profile"))
                results.append((world.subtitleBegins == 1 && world.subtitleFinishes == 1
                    && world.closes == (boundary == "subtitle" ? 0 : 1),
                    "actual installation balances retirement and closes refused candidate after \(boundary)/\(selection)"))
            }
            let manager = try makeManager(), source = AdoptionWorld.current
            world = World()
            let authority = try manager.fixtureBoundCloudAuthority(plaintext: source.plaintext, revision: source.revision)
            let bridge = CoreBridge(), capture = CredentialScopeRegistry.shared.capture()
            let requested = selection == "nil" ? nil : (selection == "matching" ? AdoptionWorld.owner : UUID())
            try await bridge.installNativeSession(VortxNativeSession(capture: capture), registry: [], capture: capture,
                initialProfileID: requested, initialProfileSource: authority, installationSource: authority)
            results.append((bridge.nativeFacadeStorage != nil && world.profiles == 1 && world.seeds == 1
                && world.boards == 1 && world.libraries == 1 && world.switches == (selection == "different" ? 1 : 0),
                "actual installation accepts live original source with \(selection) profile"))
        }
        let manager = try makeManager(), source = AdoptionWorld.current
        world = World()
        let authority = try manager.fixtureBoundCloudAuthority(plaintext: source.plaintext, revision: source.revision)
        manager.dataKey = Data(repeating: 0x42, count: 32); manager.dataKey = AdoptionWorld.key
        let bridge = CoreBridge(), capture = CredentialScopeRegistry.shared.capture()
        do {
            try await bridge.installNativeSession(VortxNativeSession(capture: capture), registry: [],
                capture: capture, installationSource: authority)
            results.append((false, "pre-retired source unexpectedly installed"))
        } catch {
            results.append((world.subtitleBegins == 0 && world.created == 0 && bridge.nativeFacadeStorage == nil,
                "actual installation refuses already-retired original source before subtitle effects"))
        }
        try await bridge.installNativeSession(VortxNativeSession(capture: capture), registry: [], capture: capture)
        results.append((bridge.nativeFacadeStorage != nil && world.boards == 1 && world.libraries == 1,
            "actual local-only installation remains available without a cloud source"))
        for failure in ["profiles", "seed", "origin", "source-after-library"] {
            let manager = try makeManager(), source = AdoptionWorld.current
            world = World(); world.failProfiles = failure == "profiles"
            world.failSeed = failure == "seed"; world.failOrigin = failure == "origin"
            let authority = try manager.fixtureBoundCloudAuthority(plaintext: source.plaintext, revision: source.revision)
            let bridge = CoreBridge(), capture = CredentialScopeRegistry.shared.capture()
            world.callback = { name in
                if failure == "source-after-library" && name == "library" {
                    manager.dataKey = Data(repeating: 0x42, count: 32); manager.dataKey = AdoptionWorld.key
                }
            }
            do {
                try await bridge.installNativeSession(VortxNativeSession(capture: capture), registry: [],
                    capture: capture, hostProfiles: [.init()], installationSource: authority)
                results.append((false, "post-bind failure unexpectedly succeeded: \(failure)"))
            } catch {
                results.append((bridge.nativeFacadeStorage == nil && bridge.nativeCredentialCapture == nil
                    && bridge.nativeProfileBaseline.isEmpty && world.callbackRetirements == 1
                    && world.closes == 1 && world.invalidations == 1 && world.clears == 1 && bridge.visible == nil,
                    "actual failed-install helper retires only the bound candidate after \(failure)"))
                results.append((world.subtitleBegins == world.subtitleFinishes,
                    "actual post-bind cleanup balances original subtitle retirement after \(failure)"))
            }
        }
        do {
            let manager = try makeManager(), source = AdoptionWorld.current
            world = World(); world.failProfiles = true
            let authority = try manager.fixtureBoundCloudAuthority(plaintext: source.plaintext, revision: source.revision)
            let bridge = CoreBridge(), capture = CredentialScopeRegistry.shared.capture()
            var successor: VortxNativeCoreFacade?
            world.callback = { name in
                guard name == "facade.close", successor == nil else { return }
                successor = bridge.fixtureInstallSuccessor(capture: capture)
            }
            do {
                try await bridge.installNativeSession(VortxNativeSession(capture: capture), registry: [],
                    capture: capture, hostProfiles: [.init()], installationSource: authority)
                results.append((false, "reentrant cleanup unexpectedly succeeded"))
            } catch {
                results.append((successor != nil && bridge.nativeFacadeStorage === successor
                    && bridge.nativeCredentialCapture == capture && bridge.visible == "successor"
                    && world.clears == 0 && world.callbackRetirements == 1
                    && !world.closedIDs.contains(successor!.sourceID),
                    "actual failed-install cleanup preserves successor installed reentrantly by detached close"))
            }
        }
        return results
    }
}
