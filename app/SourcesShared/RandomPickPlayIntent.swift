import Foundation

/// Shared Apple intent: reference identity is allocated only by the explicit preview Play action, never by body.
/// All descendants share this same terminal one-shot; no view reconstruction can re-arm it.
@MainActor
final class RandomPickPlayIntent {
    let ticketID: UUID
    private let access: RandomPickUIAccess
    private var originIsCurrent: (() -> Bool)?
    private var policy = RandomPickPlayPolicy()
    private(set) var source: RandomPickPolicy.EpisodeSource?
    private var video: CoreVideo?

    init(ticketID: UUID, access: RandomPickUIAccess, originIsCurrent: @escaping () -> Bool) {
        self.ticketID = ticketID
        self.access = access
        self.originIsCurrent = originIsCurrent
    }

    var isPending: Bool { policy.state == .pending }
    var isAdmitted: Bool { policy.state == .consumed }
    var requiresFullAccess: Bool {
        switch policy.state {
        case .pending, .resolving: return true
        case .consumed, .revoked: return false
        }
    }

    func routeIsCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
        requiresFullAccess ? access.isCurrent(profiles: profiles, core: core)
            : access.isNavigationCurrent(profiles: profiles, core: core)
    }

    func matchesPublishedProfiles(_ incoming: [UserProfile], pickedThisLaunch: Bool) -> Bool {
        requiresFullAccess ? access.matchesPublishedProfiles(incoming, pickedThisLaunch: pickedThisLaunch)
            : access.matchesPublishedNavigationProfiles(incoming, pickedThisLaunch: pickedThisLaunch)
    }

    /// The first current metadata/episode tuple is immutable for this request. A later hydrate,
    /// changed coordinates, or A -> B -> A publication must not mint replacement authority.
    func bind(meta: CoreMetaItem, video: CoreVideo?, core: CoreBridge, profiles: ProfileStore) -> Bool {
        guard policy.state == .pending, access.isCurrent(profiles: profiles, core: core),
              originIsCurrent?() == true else { revoke(); return false }
        let incoming = RandomPickPolicy.EpisodeSource(meta)
        if let source {
            guard source == incoming, self.video == video else { revoke(); return false }
        } else {
            // Prove inventory membership and duplicate-coordinate admission only once per intent.
            if let video {
                guard RandomPickPolicy.eligibleEpisodes(meta.videos ?? [], now: Date()).contains(video) else {
                    revoke(); return false
                }
            }
            source = incoming
            self.video = video
        }
        return isCurrent(core: core, profiles: profiles)
    }

    func isCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
        guard requiresFullAccess, access.isCurrent(profiles: profiles, core: core), originIsCurrent?() == true else {
            revoke(); return false
        }
        // iOS owns its existing metadata/source-attempt fence. TV binds the additional immutable
        // title/episode receipt here before it can claim its resolver.
        guard let source else { return true }
        guard let current = ResidentMeta.fenced(core.metaDetails?.meta, pageID: source.identity.id, id: { $0.id }),
              RandomPickPolicy.EpisodeSource(current) == source else { revoke(); return false }
        if let video {
            // Exact source equality conserves the one-time membership/ambiguity proof above.
            // Polling/resolver gates only need the selected episode's current date eligibility.
            guard RandomPickPolicy.eligibleEpisodes([video], now: Date()).contains(video) else {
                revoke(); return false
            }
        }
        return true
    }

    func claim(core: CoreBridge, profiles: ProfileStore) -> UUID? {
        let current = isCurrent(core: core, profiles: profiles)
        return policy.claim(enabled: true, current: current)
    }

    func accepts(_ claim: UUID, core: CoreBridge, profiles: ProfileStore, sourceIsCurrent: Bool) -> Bool {
        let current = sourceIsCurrent && isCurrent(core: core, profiles: profiles)
        let accepted = policy.accepts(claim, current: current)
        if !requiresFullAccess { releasePendingEvidence() }
        return accepted
    }

    func consume(_ claim: UUID, core: CoreBridge, profiles: ProfileStore, sourceIsCurrent: Bool) -> Bool {
        let current = sourceIsCurrent && isCurrent(core: core, profiles: profiles)
        let admitted = policy.consume(claim, current: current)
        if !requiresFullAccess { releasePendingEvidence() }
        return admitted
    }

    /// iOS already owns an exact quick-watch generation and checks it at the final handoff.
    /// Consume directly there; a second completion cannot claim or consume this same intent.
    func consume(core: CoreBridge, profiles: ProfileStore) -> Bool {
        guard let claim = claim(core: core, profiles: profiles) else { return false }
        return consume(claim, core: core, profiles: profiles, sourceIsCurrent: true)
    }

    func invalidateMetadata(_ details: CoreMetaDetails?) {
        guard let source else { return }
        let current = ResidentMeta.fenced(details?.meta, pageID: source.identity.id, id: { $0.id })
        if current.map(RandomPickPolicy.EpisodeSource.init) != source { revoke() }
    }

    private func releasePendingEvidence() {
        originIsCurrent = nil
        source = nil
        video = nil
    }

    func revoke() {
        policy.revoke()
        releasePendingEvidence()
    }
}
