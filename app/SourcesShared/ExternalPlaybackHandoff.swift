import SwiftUI
import Combine

/// The existing legacy overlay writer permits inactive-owner writes; external callbacks must not.
/// Observe the actual selection publisher synchronously so A -> B -> A cannot revive a handoff.
private final class ExternalHandoffProfileEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: UUID?
    private var epoch = UUID()
    private var observation: AnyCancellable?

    init() {
        selected = ProfileStore.shared.activeID
        observation = ProfileStore.shared.$activeID.sink { [weak self] next in
            guard let self else { return }
            self.lock.withLock {
                if self.selected != next { self.selected = next; self.epoch = UUID() }
            }
        }
    }
    func capture() -> UUID { lock.withLock { epoch } }
}

/// Apple shell adapter for the tested callback coordinator. Owners are captured synchronously at the
/// tap, before resume lookup or platform launch can suspend. Stream capabilities live in memory only.
@MainActor
final class ExternalPlaybackHandoff: ObservableObject {
    static let shared = ExternalPlaybackHandoff()
    private let coordinator = InfuseHandoffCoordinator()
    private let profileEpoch = ExternalHandoffProfileEpoch()
    private var generation = UUID()
    private var navigatingNext = false
    private var returnOwnerCheck: (() -> Bool)?
    private var pendingOwnerCheck: (() -> Bool)?
    @Published private(set) var presentation: InfuseHandoffCoordinator.Returned?

    @MainActor struct Request {
        let metadata: PlaybackMeta?
        let account: StremioAccount
        let target: PlaybackMutationTarget
        let credential: CredentialScopeRegistry.Capture
        let generation: UUID
        let profileEpoch: UUID
        let accountGeneration: UInt64
        let signedIn: Bool
        let position: Double?
        /// Only an integrity-accepted duration observed for this exact media, never catalog runtime.
        let duration: Double?
        let episodes: [InfuseHandoffCoordinator.Episode]
        let addon: String?
        let bingeGroup: String?
        let allowsLaunch: () -> Bool

        init(metadata: PlaybackMeta?, account: StremioAccount, target: PlaybackMutationTarget? = nil,
             position: Double? = nil, duration: Double? = nil,
             episodes: [InfuseHandoffCoordinator.Episode] = [], addon: String? = nil, bingeGroup: String? = nil,
             allowsLaunch: @escaping () -> Bool = { true }) {
            self.metadata = metadata
            self.account = account
            self.target = target ?? .capture(core: CoreBridge.shared)
            credential = CredentialScopeRegistry.shared.capture()
            generation = ExternalPlaybackHandoff.shared.generation
            profileEpoch = ExternalPlaybackHandoff.shared.profileEpoch.capture()
            accountGeneration = account.credentialBoundaryGeneration
            signedIn = account.isSignedIn
            self.position = position
            self.duration = duration
            self.episodes = episodes
            self.addon = addon
            self.bingeGroup = bingeGroup
            self.allowsLaunch = allowsLaunch
        }

        var ownerIsCurrent: Bool { ownerCheck()() }

        /// Do not retain allowsLaunch (and the dismissed player/view it may capture) in a return lease.
        func ownerCheck() -> () -> Bool {
            let credential = credential, profileEpoch = profileEpoch, accountGeneration = accountGeneration
            let signedIn = signedIn, account = account, target = target
            return {
                CredentialScopeRegistry.shared.isCurrent(credential)
                    && profileEpoch == ExternalPlaybackHandoff.shared.profileEpoch.capture()
                    && accountGeneration == account.credentialBoundaryGeneration && signedIn == account.isSignedIn
                    && target.stillOwnsCurrentContext(core: CoreBridge.shared)
            }
        }
    }

    struct Prepared: Sendable {
        let url: URL
        let id: UUID?
    }

    func enteredInternalPlayer() {
        generation = UUID()
        coordinator.invalidate()
        if !navigatingNext { presentation = nil }
    }

    /// Invalidate first, then resolve the exact captured owner's resume. A superseding player/launch
    /// or A -> B -> A account transition cannot make a suspended resume lookup valid again.
    func prepare(stream: URL, metadata: PlaybackMeta?, request: Request?) async -> Prepared? {
        guard InfuseHandoffCoordinator.canTransfer(stream) else { return nil }
        guard let request else {
            // Non-library links can still open, but have no authority to write history or watched state.
            enteredInternalPlayer()
            return InfuseDeepLink.playURL(stream: stream, metadata: metadata).map { Prepared(url: $0, id: nil) }
        }
        guard request.generation == generation, request.ownerIsCurrent, request.allowsLaunch(),
              SourcePlayerChoicePolicy.canHandOffExternally(url: stream, isTorrent: false,
                                                            isUsenet: false, requestHeaders: nil) else { return nil }
        enteredInternalPlayer()
        let launchGeneration = generation
        guard let meta = request.metadata, meta.type == "movie" || meta.usesSeriesLifecycle else {
            return InfuseDeepLink.playURL(stream: stream, metadata: request.metadata, position: request.position ?? 0)
                .map { Prepared(url: $0, id: nil) }
        }
        let position: Double
        if let supplied = request.position { position = supplied }
        else {
            #if VORTX_NATIVE_DATA_ENGINE
            position = await CoreBridge.shared.nativeResumeSeconds(for: meta, target: request.target)
            #else
            position = await request.account.resumeOffset(for: meta)
            #endif
        }
        guard generation == launchGeneration, request.ownerIsCurrent, request.allowsLaunch(), !Task.isCancelled else { return nil }
        let ownerIsCurrent = request.ownerCheck()
        let account = request.account, target = request.target
        let addon = request.addon, bingeGroup = request.bingeGroup
        pendingOwnerCheck = ownerIsCurrent
        let isCurrent: () -> Bool = { [weak self] in self?.generation == launchGeneration && ownerIsCurrent() }
        let context = InfuseHandoffCoordinator.Context(
            metadata: meta, duration: request.duration, episodes: request.episodes,
            isCurrent: isCurrent,
            progress: { position, duration in
                guard isCurrent() else { return }
                // Native report_progress explicitly accepts zero as unknown, preserves a stored known
                // duration and does not infer completion. Legacy writers retain their >0 contract.
                guard duration != nil || CoreBridge.shared.usesNativeProfileState else { return }
                Task { @MainActor in
                    guard isCurrent() else { return }
                    await account.saveProgress(for: meta, positionSeconds: position,
                                               durationSeconds: duration ?? 0, target: target)
                }
            },
            watched: {
                guard isCurrent() else { return }
                CoreBridge.shared.markPlaybackWatched(meta, target: target)
            },
            acceptedSource: {
                guard isCurrent(), meta.usesSeriesLifecycle else { return }
                SeriesSourceSticky.record(seriesKey: meta.libraryId, addon: addon, bingeGroup: bingeGroup)
            }
        )
        let scheme = Bundle.main.object(forInfoDictionaryKey: "VortXURLScheme") as? String ?? ""
        return coordinator.prepare(stream: stream, position: position, scheme: scheme,
                                   context: context, allowsLaunch: request.allowsLaunch)
            .map { Prepared(url: $0.url, id: $0.id) }
    }

    func launchFinished(_ prepared: Prepared, launched: Bool) {
        if let id = prepared.id { coordinator.launchFinished(id, launched: launched) }
        if let result = coordinator.currentReturn(), result.id == prepared.id, result.id != presentation?.id {
            navigatingNext = false
            returnOwnerCheck = pendingOwnerCheck
            presentation = result
        }
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        let handled = coordinator.handle(url)
        if handled, let result = coordinator.currentReturn(), result.id != presentation?.id {
            navigatingNext = false
            returnOwnerCheck = pendingOwnerCheck
            presentation = result
        } else if handled { refresh() }
        return handled
    }

    func refresh() {
        if navigatingNext {
            if returnOwnerCheck?() != true { dismiss() }
        } else { presentation = coordinator.currentReturn() }
    }
    func dismiss() {
        generation = UUID()
        coordinator.invalidate()
        presentation = nil
        navigatingNext = false
        returnOwnerCheck = nil
        pendingOwnerCheck = nil
    }

    func confirmWatched(_ id: UUID) {
        _ = coordinator.confirmWatched(id)
        refresh()
    }

    func nextEpisode(_ id: UUID) -> InfuseHandoffCoordinator.Episode? {
        guard let result = coordinator.currentReturn(), result.id == id,
              !result.failed, result.completed else { return nil }
        return result.next
    }

    func chooseNext(_ id: UUID) -> InfuseHandoffCoordinator.Episode? {
        guard let next = nextEpisode(id), returnOwnerCheck?() == true else { return nil }
        navigatingNext = true
        return next
    }

    static func episodes(_ videos: [CoreVideo]) -> [InfuseHandoffCoordinator.Episode] {
        videos.filter { $0.releasedDate.map { $0 <= Date() } ?? true }
            .map { .init(id: $0.id, season: $0.season, episode: $0.episode) }
    }
}

/// Mounted above the normal shell so callbacks do not depend on a dismissed player view surviving.
/// This sheet never opens a stream automatically: Next uses the existing exact-episode source screen.
private struct ExternalPlaybackReturnModifier: ViewModifier {
    @ObservedObject private var handoff = ExternalPlaybackHandoff.shared
    @ObservedObject private var core = CoreBridge.shared
    @ObservedObject private var profiles = ProfileStore.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { phase in if phase == .active { handoff.refresh() } }
            .onReceive(core.objectWillChange) { _ in
                guard handoff.presentation != nil else { return }
                Task { @MainActor in handoff.refresh() }
            }
            .onReceive(profiles.objectWillChange) { _ in
                Task { @MainActor in handoff.refresh() }
            }
            .sheet(item: Binding(get: { handoff.presentation }, set: { if $0 == nil { handoff.dismiss() } })) { result in
                ExternalPlaybackReturnView(result: result).id(result.id)
            }
    }
}

private struct ExternalPlaybackReturnView: View {
    let result: InfuseHandoffCoordinator.Returned
    @ObservedObject private var handoff = ExternalPlaybackHandoff.shared
    @State private var next: InfuseHandoffCoordinator.Episode?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let next {
                    #if os(tvOS)
                    DetailView(type: result.metadata.type, id: result.metadata.libraryId, initialVideoID: next.id)
                    #else
                    iOSDetailView(id: result.metadata.libraryId, type: result.metadata.type,
                                  title: result.metadata.name, initialVideoID: next.id)
                    #endif
                } else {
                    VStack(spacing: 20) {
                        Text(result.failed ? "Infuse could not play this source" : "Returned from Infuse").font(.title2)
                        Text(result.metadata.name).font(.headline)
                        if let season = result.metadata.season, let episode = result.metadata.episode {
                            Text("Season \(season), Episode \(episode)")
                        }
                        if let position = result.position {
                            Text("Returned at \(position / 60):\(String(format: "%02d", position % 60))")
                        }
                        if !result.failed {
                            let completed = handoff.presentation?.completed == true
                            Text(completed ? "Marked watched." : "Closing Infuse does not mean you finished. Mark watched only if you finished this title.")
                                .multilineTextAlignment(.center)
                            if !completed {
                                Button("Mark watched") { handoff.confirmWatched(result.id) }
                            }
                            if let episode = result.next {
                                Button(completed ? "Choose next episode · S\(episode.season ?? 0) E\(episode.episode ?? 0)"
                                                : "Mark watched and choose next episode") {
                                    if !completed { handoff.confirmWatched(result.id) }
                                    next = handoff.chooseNext(result.id)
                                }
                            }
                        } else {
                            Text("No progress or watched status was changed. Choose another source to try again.")
                                .multilineTextAlignment(.center)
                        }
                        Button("Done") { handoff.dismiss(); dismiss() }
                    }
                    .padding(32)
                    .frame(maxWidth: 650)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { handoff.dismiss(); dismiss() } } }
        }
    }
}

extension View {
    func externalPlaybackReturns() -> some View { modifier(ExternalPlaybackReturnModifier()) }
}
