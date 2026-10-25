import Combine
import Foundation

/// Process-local, profile/account-owned ordering; all playback still uses the normal detail resolver.
@MainActor
final class PlaybackTitleQueue: ObservableObject {
    static let shared = PlaybackTitleQueue()

    typealias Token = PlaybackTitleQueueToken

    final class Route: Identifiable {
        let id: UUID
        let token: Token
        let entry: PlaybackTitleQueuePolicy.Entry
        let intent: RandomPickPlayIntent
        @MainActor
        fileprivate init(token: Token, entry: PlaybackTitleQueuePolicy.Entry, intent: RandomPickPlayIntent) {
            self.id = token.ticketID
            self.token = token
            self.entry = entry
            self.intent = intent
        }
    }

    private struct MediaIdentity: Equatable {
        let contentID: String
        let videoID: String
        let type: String
        init(_ meta: PlaybackMeta) {
            contentID = meta.libraryId; videoID = meta.videoId; type = meta.type
        }
    }

    // Notify after all state writes: @Published emits in willSet, and hosts must see one coherent route.
    @Published private(set) var change = UUID()
    private var policy = PlaybackTitleQueuePolicy()
    private var owner: RandomPickUIAccess?
    private var activeMedia: MediaIdentity?
    private var activeToken: Token?
    private var automaticAdvances = 0
    private(set) var route: Route?
    private(set) var editorID: UUID?

    private var core: CoreBridge { .shared }
    private var profiles: ProfileStore { .shared }
    private init() {}

    var upcoming: [PlaybackTitleQueuePolicy.Entry] { ownsContext ? policy.upcoming : [] }
    var activeEntry: PlaybackTitleQueuePolicy.Entry? { ownsContext ? policy.active?.entry : nil }
    var count: Int { ownsContext ? policy.count : 0 }
    var canStart: Bool { ownsContext && policy.active == nil && !policy.upcoming.isEmpty }

    var admissionProblem: String {
        if profiles.needsPicker || profiles.active == nil {
            return "Choose your profile before editing the playback queue."
        }
        if ownsContext, policy.count >= PlaybackTitleQueuePolicy.capacity {
            return "The queue is full. Remove a title before adding another. A queue can hold 100 titles."
        }
        if RandomPickUIAccess.capture(profiles: profiles, core: core) == nil {
            return "The playback session isn't ready. Finish selecting or restoring your profile, then try again."
        }
        return "Your playback session changed. Open the queue and try again."
    }

    private var ownsContext: Bool {
        guard let owner else { return false }
        return owner.isNavigationCurrent(profiles: profiles, core: core)
            && owner.target.stillOwnsCurrentContext(core: core)
    }

    @discardableResult
    func enqueue(_ candidate: PlaybackTitleQueuePolicy.Candidate,
                 placement: PlaybackTitleQueuePolicy.Placement) -> Bool {
        invalidateIfNeeded()
        if owner == nil { owner = RandomPickUIAccess.capture(profiles: profiles, core: core) }
        guard ownsContext, policy.enqueue(candidate, placement: placement) else { return false }
        invalidatePendingRoute()
        publish()
        return true
    }

    func remove(_ id: UUID) {
        guard validate(), policy.remove(id) else { return }
        invalidatePendingRoute(); publish()
    }

    func move(_ id: UUID, by delta: Int) {
        guard validate(), policy.move(id, by: delta) else { return }
        invalidatePendingRoute(); publish()
    }

    func clearUpcoming() {
        guard validate() else { return }
        policy.clearUpcoming(); invalidatePendingRoute(); publish()
    }

    func showEditor() {
        invalidateIfNeeded()
        invalidatePendingRoute()
        editorID = UUID(); publish()
    }

    func dismissEditor(_ id: UUID) {
        guard editorID == id else { return }
        editorID = nil; publish()
    }

    /// Explicit retry after closing a failed player. No retry/advance runs merely because it disappeared.
    @discardableResult
    func retryCurrent() -> Bool {
        guard validate(), !FullscreenPlaybackGate.shared.playerActive, policy.retryActive() else { return false }
        activeMedia = nil
        activeToken = nil
        if requestNext() { return true }
        publish(); return false
    }

    @discardableResult
    func requestNext() -> Bool {
        guard validate(), let ticket = policy.nextTicket(), let entry = policy.upcoming.first,
              let access = RandomPickUIAccess.capture(profiles: profiles, core: core) else { return false }
        invalidatePendingRoute()
        let token = Token(ticketID: ticket.id, entryID: ticket.entryID, revision: ticket.revision,
                          contentID: entry.candidate.contentID, type: entry.candidate.type,
                          videoIDHint: entry.candidate.videoIDHint) { [weak self] contentID, videoID, type in
            guard let self, self.ownsContext, self.route?.id == ticket.id,
                  self.policy.accepts(ticket) else { return false }
            return entry.candidate.contentID == contentID && entry.candidate.type == type
                && (entry.candidate.videoIDHint == nil || entry.candidate.videoIDHint == videoID)
        }
        let intent = RandomPickPlayIntent(ticketID: ticket.id, access: access, playbackQueueToken: token) { [weak self] in
            guard let self else { return false }
            return self.ownsContext && self.route?.id == ticket.id && self.policy.accepts(ticket)
        }
        route = Route(token: token, entry: entry, intent: intent)
        editorID = nil
        publish()
        return true
    }

    /// Explicit retry only. Never silently replay a failed resolver or a pre-frame player failure.
    /// The pending stable entry/order is conserved; the route ID, intent and source witness are fresh.
    @discardableResult
    func retryPending(_ id: UUID) -> Bool {
        guard validate(), !FullscreenPlaybackGate.shared.playerActive,
              let route, route.id == id, policy.active == nil,
              policy.upcoming.first?.id == route.entry.id else { return false }
        return requestNext()
    }

    /// The token came from the exact source-admitted intent; never infer it from whichever queue is current.
    @discardableResult
    func acceptStarted(_ token: Token?, meta: PlaybackMeta) -> Bool {
        guard let token, validate() else { return false }
        if policy.active?.ticket.id == token.ticketID {
            return activeToken === token && activeMedia == MediaIdentity(meta) // same-source recovery is not a second consumption
        }
        guard let route, route.token === token, token.sourceAdmitted,
              matches(route.entry.candidate, meta), policy.acceptStarted(.init(
                id: token.ticketID, entryID: token.entryID, revision: token.revision
              )) else { return false }
        activeMedia = MediaIdentity(meta)
        activeToken = token
        self.route = nil
        publish()
        return true
    }

    /// Invoke only from the existing accepted-EOF branch, after Sleep/Watch Credits/paused-boundary rules.
    /// True also means the final queued item finished: stop rather than falling into unrelated series binge.
    @discardableResult
    func completed(_ token: Token?, meta: PlaybackMeta) -> Bool {
        guard let token, validate(), activeToken === token, activeMedia == MediaIdentity(meta),
              policy.finish(token.ticketID) else { return false }
        activeMedia = nil
        activeToken = nil
        if !policy.upcoming.isEmpty { automaticAdvances += 1 }
        if !requestNext() { publish() }
        return true
    }

    /// An explicit skip saves the player's real progress through its existing leavePlayback path.
    /// It does not call markWatched, finishedWatching, a synthetic EOF, or any completion API.
    @discardableResult
    func nextManually(_ token: Token?) -> Bool {
        guard let token, validate(), activeToken === token, !policy.upcoming.isEmpty,
              policy.finish(token.ticketID) else { return false }
        activeMedia = nil
        activeToken = nil
        automaticAdvances = 0
        if requestNext() { return true }
        publish(); return false
    }

    func ownsActive(_ token: Token?, meta: PlaybackMeta) -> Bool {
        guard let token else { return false }
        return ownsContext && activeToken === token && policy.active?.ticket.id == token.ticketID && activeMedia == MediaIdentity(meta)
    }

    func shouldConfirmAdvance(_ token: Token?, meta: PlaybackMeta, after count: Int) -> Bool {
        ownsActive(token, meta: meta) && !policy.upcoming.isEmpty && automaticAdvances + 1 >= max(1, count)
    }

    func noteInteraction(_ token: Token?) {
        guard let token, ownsContext, activeToken === token, policy.active?.ticket.id == token.ticketID else { return }
        automaticAdvances = 0
    }

    func dismissRoute(_ id: UUID) {
        guard route?.id == id else { return }
        invalidatePendingRoute(); publish() // retains the entry when cancelled or sources are unavailable
    }

    func invalidateIfNeeded() {
        guard owner != nil, !ownsContext else { return }
        reset()
    }

    /// Publishers fire in willSet. Validate the incoming boundary, not the still-old stored roster.
    func profilesWillChange(_ incoming: [UserProfile]) {
        guard let owner,
              !owner.matchesPublishedNavigationProfiles(incoming, pickedThisLaunch: profiles.pickedThisLaunch) else { return }
        reset()
    }

    func activeProfileWillChange(_ incoming: UUID?) {
        guard let owner, incoming != owner.profile.id else { return }
        reset()
    }

    func pickedThisLaunchWillChange(_ incoming: Bool) {
        guard let owner,
              !owner.matchesPublishedNavigationProfiles(profiles.profiles, pickedThisLaunch: incoming) else { return }
        reset()
    }

    private func validate() -> Bool { invalidateIfNeeded(); return ownsContext }

    private func matches(_ candidate: PlaybackTitleQueuePolicy.Candidate, _ meta: PlaybackMeta) -> Bool {
        candidate.contentID == meta.libraryId && candidate.type == meta.type
            && (candidate.videoIDHint == nil || candidate.videoIDHint == meta.videoId)
    }

    private func invalidatePendingRoute() { route?.intent.revoke(); route = nil }
    private func publish() { change = UUID() }
    private func reset() {
        invalidatePendingRoute(); editorID = nil; owner = nil; policy = PlaybackTitleQueuePolicy(); activeMedia = nil; activeToken = nil
        automaticAdvances = 0; publish()
    }
}
