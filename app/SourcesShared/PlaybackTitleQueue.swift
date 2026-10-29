import Combine
import Foundation

/// Profile/account-owned catalog ordering. Durable bytes are local-only and playback still uses the normal
/// detail/source resolver with a fresh route; resolved URLs, headers, leases and player tickets never persist.
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

    /// Opaque original queue-owner witness. Capture it at the user gesture before any asynchronous playlist
    /// read. Attachment identity makes A -> B -> A a different target even when the stable partition matches.
    struct PlaylistImportTarget {
        fileprivate let owner: PlaybackTitleQueueDurabilityOwner
        fileprivate let attachment: PlaybackTitleQueueDurability.Attachment
    }

    /// Catalog-only queue metadata for playlist creation. The target is checked again on every read; callers
    /// never receive a successor profile's queue merely because it became current after their gesture.
    struct PlaylistSnapshot: Equatable, Sendable {
        let candidates: [PlaybackTitleQueuePolicy.Candidate]
        let remainingCapacity: Int
    }

    private struct MediaIdentity: Equatable {
        let contentID: String
        let videoID: String
        let type: String
        init(_ meta: PlaybackMeta) {
            contentID = meta.libraryId; videoID = meta.videoId; type = meta.type
        }
    }

    // Notify after all state writes: @Published emits in willSet, and hosts must see one coherent route/phase.
    @Published private(set) var change = UUID()
    private var policy = PlaybackTitleQueuePolicy()
    private var owner: RandomPickUIAccess?
    private var persistenceOwner: PlaybackTitleQueueDurabilityOwner?
    private var persistenceAttachment: PlaybackTitleQueueDurability.Attachment?
    private(set) var persistencePhase: PlaybackTitleQueuePersistencePhase = .inactive
    private var lastMutationProblem: String?
    private(set) var completionPaused = false
    private(set) var awaitingQueueStart = false
    private var activeMedia: MediaIdentity?
    private var activeToken: Token?
    private var automaticAdvances = 0
    private(set) var route: Route?
    private(set) var editorID: UUID?

    private var core: CoreBridge { .shared }
    private var profiles: ProfileStore { .shared }
    private lazy var durability = PlaybackTitleQueueDurability { [weak self] event in
        self?.handleDurabilityEvent(event)
    }
    private init() {}

    var upcoming: [PlaybackTitleQueuePolicy.Entry] { ownsContext ? policy.upcoming : [] }
    var activeEntry: PlaybackTitleQueuePolicy.Entry? { ownsContext ? policy.active?.entry : nil }
    var count: Int { ownsContext ? policy.count : 0 }
    var canStart: Bool {
        canUseQueue && policy.active == nil && !policy.upcoming.isEmpty
    }
    var canUseQueue: Bool {
        guard ownsContext, let persistenceOwner, let persistenceAttachment,
              persistenceOwner.isCurrent(profiles: profiles, core: core),
              persistencePhase.allowsEditing else { return false }
        return durability.canUseAttachment(persistenceAttachment)
    }
    var canEditQueue: Bool {
        guard canUseQueue, let persistenceAttachment else { return false }
        return durability.canAcceptWrite(for: persistenceAttachment)
    }
    var canContinueCompletedQueue: Bool {
        completionPaused && canEditQueue && !FullscreenPlaybackGate.shared.playerActive
            && activeToken != nil && policy.active != nil
    }

    var persistenceStatusText: String {
        if let lastMutationProblem { return lastMutationProblem }
        switch persistencePhase {
        case .inactive:
            return "Choose a profile."
        case .restoring:
            return "Loading your saved queue…"
        case .ready:
            return "No saved queue on this device for this profile yet."
        case .saving(let pending):
            return pending == 1
                ? "Saving on this device…"
                : "Saving on this device… \(pending) changes waiting."
        case .saved:
            return "Saved on this device for this profile."
        case .failed(_):
            return "We couldn’t confirm the queue was saved. Retry saving before editing."
        }
    }

    var admissionProblem: String {
        if let lastMutationProblem { return lastMutationProblem }
        if profiles.needsPicker || profiles.active == nil {
            return "Choose a profile."
        }
        if case .restoring = persistencePhase {
            return "The local saved queue is still loading. Try again when loading finishes."
        }
        if case .failed = persistencePhase {
            return "We couldn’t confirm the queue was saved. Retry saving before editing."
        }
        if ownsContext, policy.count >= PlaybackTitleQueuePolicy.capacity {
            return "The queue is full. Remove a title before adding another. A queue can hold 100 titles."
        }
        if persistencePhase.allowsEditing, !canEditQueue {
            return "Saving on this device is still catching up. Wait before making another change."
        }
        if RandomPickUIAccess.capture(profiles: profiles, core: core) == nil {
            return "The playback session isn't ready. Finish selecting or restoring your profile, then try again."
        }
        return "Your profile or playback session changed. Open the queue and try again."
    }

    private var ownsContext: Bool {
        guard let owner else { return false }
        return owner.isNavigationCurrent(profiles: profiles, core: core)
            && owner.target.stillOwnsCurrentContext(core: core)
    }

    /// Capture only an already restored, usable queue. Import never activates or substitutes a newer owner.
    func capturePlaylistImportTarget() -> PlaylistImportTarget? {
        invalidateIfNeeded()
        guard canUseQueue, let persistenceOwner, let persistenceAttachment,
              persistenceOwner.isCurrent(profiles: profiles, core: core),
              durability.canUseAttachment(persistenceAttachment) else { return nil }
        return .init(owner: persistenceOwner, attachment: persistenceAttachment)
    }

    func playlistSnapshot(for target: PlaylistImportTarget) -> PlaylistSnapshot? {
        guard playlistTargetIsCurrent(target, requireWriteSlot: false) else { return nil }
        let entries = policy.durableEntries
        return .init(
            candidates: entries.map(\.candidate),
            remainingCapacity: max(0, PlaybackTitleQueuePolicy.capacity - entries.count)
        )
    }

    /// Establish the exact live owner, then queue its bounded disk read behind every previously accepted write.
    /// No edit is admitted until the read result is published back to this same attachment.
    func activateCurrentOwner() {
        invalidateIfNeeded()
        guard owner == nil else { return }
        guard let access = RandomPickUIAccess.capture(profiles: profiles, core: core),
              let durableOwner = PlaybackTitleQueueDurabilityOwner.capture(
                access: access, profiles: profiles, core: core
              ) else { return }
        owner = access
        persistenceOwner = durableOwner
        let attached = durability.attach(durableOwner)
        persistenceAttachment = attached.0
        persistencePhase = attached.1
        publish()
    }

    @discardableResult
    func enqueue(_ candidate: PlaybackTitleQueuePolicy.Candidate,
                 placement: PlaybackTitleQueuePolicy.Placement) -> Bool {
        invalidateIfNeeded()
        if owner == nil {
            activateCurrentOwner()
            return false
        }
        guard let prepared = prepareDurableMutation({
            $0.enqueue(candidate, placement: placement)
        }) else { return false }
        return admitAndCommit(prepared) { self.invalidatePendingRoute() }
    }

    /// One playlist import is one local queue transaction. True means its immutable local durability write
    /// was admitted; cloud save/sync has separate truth. Rejection preserves both caller input and live queue.
    @discardableResult
    func appendCandidates(
        _ candidates: [PlaybackTitleQueuePolicy.Candidate],
        target: PlaylistImportTarget
    ) -> Bool {
        invalidateIfNeeded()
        // This check intentionally precedes UUID generation and canonical encoding.
        guard playlistTargetIsCurrent(target, requireWriteSlot: true) else { return false }
        guard !candidates.isEmpty else {
            lastMutationProblem = "This playlist has no titles to add. Nothing changed."
            publish()
            return false
        }
        guard candidates.count <= PlaybackTitleQueuePolicy.capacity - policy.count else {
            lastMutationProblem = "That playlist won’t fit in the queue. Remove titles and try again. Nothing changed."
            publish()
            return false
        }
        guard let prepared = prepareDurableMutation({
            $0.appendCandidates(candidates)
        }) else { return false }
        return admitAndCommit(prepared, playlistTarget: target) {
            self.invalidatePendingRoute()
        }
    }

    func remove(_ id: UUID) {
        guard let prepared = prepareDurableMutation({ $0.remove(id) }) else { return }
        _ = admitAndCommit(prepared) { self.invalidatePendingRoute() }
    }

    func move(_ id: UUID, by delta: Int) {
        guard let prepared = prepareDurableMutation({ $0.move(id, by: delta) }) else { return }
        _ = admitAndCommit(prepared) { self.invalidatePendingRoute() }
    }

    func clearUpcoming() {
        guard let prepared = prepareDurableMutation({ staged in
            guard !staged.upcoming.isEmpty else { return false }
            staged.clearUpcoming()
            return true
        }) else { return }
        _ = admitAndCommit(prepared) { self.invalidatePendingRoute() }
    }

    func showEditor() {
        invalidateIfNeeded()
        if owner == nil { activateCurrentOwner() }
        invalidatePendingRoute()
        editorID = UUID()
        publish()
    }

    func dismissEditor(_ id: UUID) {
        guard editorID == id else { return }
        editorID = nil
        publish()
    }

    @discardableResult
    func retryPersistence() -> Bool {
        guard case .failed = persistencePhase else { return false }
        guard let persistenceOwner, let persistenceAttachment,
              persistenceOwner.isCurrent(profiles: profiles, core: core) else {
            reset()
            return false
        }
        lastMutationProblem = nil
        persistencePhase = durability.retry(persistenceAttachment)
        publish()
        return true
    }

    /// Explicit retry after closing a failed player. No retry/advance runs merely because it disappeared.
    @discardableResult
    func retryCurrent() -> Bool {
        guard !FullscreenPlaybackGate.shared.playerActive,
              let prepared = prepareDurableMutation({ $0.retryActive() }),
              admitAndCommit(prepared, sideEffects: {
                  self.activeMedia = nil
                  self.activeToken = nil
                  self.completionPaused = false
              }) else { return false }
        awaitingQueueStart = !requestNext()
        if awaitingQueueStart { publish() }
        return true // The retry transition was accepted even if navigation changed before its route.
    }

    @discardableResult
    func requestNext() -> Bool {
        guard canUseQueue, let ticket = policy.nextTicket(), let entry = policy.upcoming.first,
              let access = RandomPickUIAccess.capture(profiles: profiles, core: core) else { return false }
        invalidatePendingRoute()
        let token = Token(ticketID: ticket.id, entryID: ticket.entryID, revision: ticket.revision,
                          contentID: entry.candidate.contentID, type: entry.candidate.type,
                          videoIDHint: entry.candidate.videoIDHint) { [weak self] contentID, videoID, type in
            guard let self, self.canUseQueue, self.route?.id == ticket.id,
                  self.persistenceOwner?.isCurrent(profiles: self.profiles, core: self.core) == true,
                  self.policy.accepts(ticket) else { return false }
            return entry.candidate.contentID == contentID && entry.candidate.type == type
                && (entry.candidate.videoIDHint == nil || entry.candidate.videoIDHint == videoID)
        }
        let intent = RandomPickPlayIntent(ticketID: ticket.id, access: access, playbackQueueToken: token) { [weak self] in
            guard let self else { return false }
            return self.canUseQueue && self.route?.id == ticket.id
                && self.persistenceOwner?.isCurrent(profiles: self.profiles, core: self.core) == true
                && self.policy.accepts(ticket)
        }
        awaitingQueueStart = false
        route = Route(token: token, entry: entry, intent: intent)
        editorID = nil
        publish()
        return true
    }

    /// Explicit retry only. Never silently replay a failed resolver or a pre-frame player failure.
    /// The pending stable entry/order is conserved; the route ID, intent and source witness are fresh.
    @discardableResult
    func retryPending(_ id: UUID) -> Bool {
        guard validateOperational(), !FullscreenPlaybackGate.shared.playerActive,
              let route, route.id == id, policy.active == nil,
              policy.upcoming.first?.id == route.entry.id else { return false }
        return requestNext()
    }

    /// The token came from the exact source-admitted intent; never infer it from whichever queue is current.
    @discardableResult
    func acceptStarted(_ token: Token?, meta: PlaybackMeta) -> Bool {
        guard let token, validateLiveOwner() else { return false }
        if policy.active?.ticket.id == token.ticketID {
            return activeToken === token && activeMedia == MediaIdentity(meta)
        }
        guard let route, route.token === token, token.sourceAdmitted,
              matches(route.entry.candidate, meta),
              let prepared = prepareDurableMutation({
                  $0.acceptStarted(.init(
                    id: token.ticketID, entryID: token.entryID, revision: token.revision
                  ))
              }) else { return false }
        return admitAndCommit(prepared) {
            self.activeMedia = MediaIdentity(meta)
            self.activeToken = token
            self.completionPaused = false
            self.route = nil
        }
    }

    /// Invoke only from the existing accepted-EOF branch, after Sleep/Watch Credits/paused-boundary rules.
    /// The caller has already selected its ownsActive branch. When saving is unavailable, keep ownership of
    /// that EOF but retain the active item and issue no finish, route, or queue-advance side effect.
    @discardableResult
    func completed(_ token: Token?, meta: PlaybackMeta) -> Bool {
        guard let token else { return false }
        let exactOwned = ownsActive(token, meta: meta)
        switch PlaybackTitleQueueOwnedEOFPolicy.decide(
            exactActiveOwned: exactOwned,
            durabilityCanAdmit: exactOwned && canAcceptDurableMutation()
        ) {
        case .notOwned:
            return false
        case .claimWithoutMutation:
            completionPaused = true
            automaticAdvances = 0
            publish()
            return true
        case .stageDurableFinish:
            break
        }

        guard let prepared = prepareDurableMutation({ $0.finish(token.ticketID) }),
              admitAndCommit(prepared, sideEffects: {
                  self.activeMedia = nil
                  self.activeToken = nil
                  self.completionPaused = false
                  if !prepared.policy.upcoming.isEmpty { self.automaticAdvances += 1 }
              }) else {
            // The live owner was already proven. Preserve an explicit, recoverable completed-item pause.
            completionPaused = true
            automaticAdvances = 0
            publish()
            return true
        }
        awaitingQueueStart = !prepared.policy.upcoming.isEmpty && !requestNext()
        if awaitingQueueStart { publish() }
        return true
    }

    /// Explicit recovery of an already-proven EOF; no history/scrobble/completion API is called again.
    @discardableResult
    func continueCompletedQueue() -> Bool {
        guard completionPaused, !FullscreenPlaybackGate.shared.playerActive,
              let token = activeToken, validateLiveOwner(),
              policy.active?.ticket.id == token.ticketID,
              let prepared = prepareDurableMutation({ $0.finish(token.ticketID) }),
              admitAndCommit(prepared, sideEffects: {
                  self.activeMedia = nil
                  self.activeToken = nil
                  self.completionPaused = false
                  self.automaticAdvances = 0
              }) else { return false }
        awaitingQueueStart = !prepared.policy.upcoming.isEmpty && !requestNext()
        if awaitingQueueStart { publish() }
        return true
    }

    /// An explicit skip saves the player's real progress through its existing leavePlayback path.
    /// It does not call markWatched, finishedWatching, a synthetic EOF, or any completion API.
    @discardableResult
    func nextManually(_ token: Token?) -> Bool {
        guard let token, validateLiveOwner(), activeToken === token,
              !policy.upcoming.isEmpty,
              let prepared = prepareDurableMutation({ $0.finish(token.ticketID) }),
              admitAndCommit(prepared, sideEffects: {
                  self.activeMedia = nil
                  self.activeToken = nil
                  self.completionPaused = false
                  self.automaticAdvances = 0
              }) else { return false }
        awaitingQueueStart = !requestNext()
        if awaitingQueueStart { publish() }
        return true // The accepted skip must close its original player even when route creation fails.
    }

    func ownsActive(_ token: Token?, meta: PlaybackMeta) -> Bool {
        guard let token else { return false }
        return validateLiveOwner() && activeToken === token && policy.active?.ticket.id == token.ticketID
            && activeMedia == MediaIdentity(meta)
    }

    func shouldConfirmAdvance(_ token: Token?, meta: PlaybackMeta, after count: Int) -> Bool {
        ownsActive(token, meta: meta) && !policy.upcoming.isEmpty
            && automaticAdvances + 1 >= max(1, count)
    }

    func noteInteraction(_ token: Token?) {
        guard let token, validateLiveOwner(), activeToken === token,
              policy.active?.ticket.id == token.ticketID else { return }
        automaticAdvances = 0
    }

    func dismissRoute(_ id: UUID) {
        guard route?.id == id else { return }
        invalidatePendingRoute()
        publish()
    }

    func invalidateIfNeeded() {
        guard owner != nil, !ownsContext else { return }
        reset()
    }

    /// Publishers fire in willSet. Revoke route authority against the incoming boundary immediately. Accepted
    /// writes retain their original immutable partition/payload and continue in the durability lane.
    func profilesWillChange(_ incoming: [UserProfile]) {
        guard let owner,
              !owner.matchesPublishedNavigationProfiles(incoming, pickedThisLaunch: profiles.pickedThisLaunch)
        else { return }
        reset()
    }

    func activeProfileWillChange(_ incoming: UUID?) {
        guard let owner, incoming != owner.profile.id else { return }
        reset()
    }

    func pickedThisLaunchWillChange(_ incoming: Bool) {
        guard let owner,
              !owner.matchesPublishedNavigationProfiles(profiles.profiles, pickedThisLaunch: incoming)
        else { return }
        reset()
    }

    private func validateLiveOwner() -> Bool {
        invalidateIfNeeded()
        guard ownsContext, let persistenceOwner else { return false }
        return persistenceOwner.isCurrent(profiles: profiles, core: core)
    }

    private func validateOperational() -> Bool {
        validateLiveOwner() && persistencePhase.allowsEditing
    }

    private func canAcceptDurableMutation() -> Bool {
        guard validateOperational(), let persistenceAttachment else { return false }
        return durability.canAcceptWrite(for: persistenceAttachment)
    }

    private func playlistTargetIsCurrent(
        _ target: PlaylistImportTarget,
        requireWriteSlot: Bool
    ) -> Bool {
        guard persistenceAttachment == target.attachment,
              target.owner.isCurrent(profiles: profiles, core: core),
              persistencePhase.allowsEditing,
              durability.canUseAttachment(target.attachment) else { return false }
        return !requireWriteSlot || durability.canAcceptWrite(for: target.attachment)
    }

    private func prepareDurableMutation(
        _ mutation: (inout PlaybackTitleQueuePolicy) -> Bool
    ) -> PlaybackTitleQueuePreparedMutation? {
        guard canUseQueue else { return nil }
        switch PlaybackTitleQueueMutationTransaction.prepare(current: policy, mutation: mutation) {
        case .unchanged:
            return nil
        case .rejected(let failure):
            lastMutationProblem = mutationProblem(for: failure)
            publish()
            return nil
        case .prepared(let prepared):
            return prepared
        }
    }

    /// Durability admission is synchronous on the main actor. The immutable write is queued first; only then
    /// are the staged policy and related live authority published as one coherent state transition.
    private func admitAndCommit(
        _ prepared: PlaybackTitleQueuePreparedMutation,
        playlistTarget: PlaylistImportTarget? = nil,
        sideEffects: () -> Void = {}
    ) -> Bool {
        let admittedOwner: PlaybackTitleQueueDurabilityOwner
        let admittedAttachment: PlaybackTitleQueueDurability.Attachment
        if let playlistTarget {
            guard playlistTargetIsCurrent(playlistTarget, requireWriteSlot: true) else { return false }
            admittedOwner = playlistTarget.owner
            admittedAttachment = playlistTarget.attachment
        } else if let persistenceOwner, let persistenceAttachment {
            admittedOwner = persistenceOwner
            admittedAttachment = persistenceAttachment
        } else {
            lastMutationProblem = "Your profile or playback session changed. Nothing changed."
            publish()
            return false
        }
        switch durability.admit(
            prepared, attachment: admittedAttachment, owner: admittedOwner
        ) {
        case .accepted(let phase):
            policy = prepared.policy
            persistencePhase = phase
            lastMutationProblem = nil
            sideEffects()
            publish()
            return true
        case .rejected(_):
            lastMutationProblem = "We couldn’t accept that queue change for saving. Nothing changed."
            publish()
            return false
        }
    }

    private func mutationProblem(for failure: PlaybackTitleQueueArchiveCodec.Failure) -> String {
        switch failure {
        case .oversized:
            return "That queue change is too large to save on this device. Nothing changed."
        case .malformed, .unsupportedSchema, .invalidShape, .invalidEntry,
             .duplicateEntry, .tooManyEntries:
            return "We couldn’t prepare that queue change safely. Nothing changed."
        }
    }

    private func handleDurabilityEvent(_ event: PlaybackTitleQueueDurability.Event) {
        let attachment: PlaybackTitleQueueDurability.Attachment
        switch event {
        case .restored(let supplied, _, _): attachment = supplied
        case .phase(let supplied, _): attachment = supplied
        }
        guard attachment == persistenceAttachment else { return }
        guard let persistenceOwner,
              persistenceOwner.isCurrent(profiles: profiles, core: core) else {
            reset()
            return
        }

        switch event {
        case .restored(_, let entries, let existed):
            // Editing is disabled while restoring. Still require pristine state so a late callback can never
            // overwrite a local mutation if that invariant changes in a later UI refactor.
            guard policy.count == 0, route == nil, activeToken == nil,
                  policy.restorePending(entries) else {
                persistencePhase = .failed(
                    "A stale local queue restore was rejected. Existing in-memory edits were preserved."
                )
                publish()
                return
            }
            persistencePhase = existed ? .saved : .ready
        case .phase(_, let phase):
            persistencePhase = phase
        }
        publish()
    }

    private func matches(_ candidate: PlaybackTitleQueuePolicy.Candidate, _ meta: PlaybackMeta) -> Bool {
        candidate.contentID == meta.libraryId && candidate.type == meta.type
            && (candidate.videoIDHint == nil || candidate.videoIDHint == meta.videoId)
    }

    private func invalidatePendingRoute() {
        route?.intent.revoke()
        route = nil
    }

    private func publish() {
        change = UUID()
    }

    private func reset() {
        invalidatePendingRoute()
        if let persistenceAttachment { durability.detach(persistenceAttachment) }
        editorID = nil
        owner = nil
        persistenceOwner = nil
        persistenceAttachment = nil
        persistencePhase = .inactive
        lastMutationProblem = nil
        completionPaused = false
        awaitingQueueStart = false
        policy = PlaybackTitleQueuePolicy()
        activeMedia = nil
        activeToken = nil
        automaticAdvances = 0
        publish()
    }
}
