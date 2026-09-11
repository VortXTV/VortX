/// A paused foreground session may need a fresh server port or provider link on explicit Play, but it
/// must not remount merely because its playhead did not advance while paused. The exact load owns this
/// deferred request; changing source/episode/engine cannot inherit an earlier mount's recovery.
struct ForegroundMountRevalidation<Owner: Equatable> {
    struct Request {
        let suspendedFor: Double
        let playHeadAtSuspension: Double?
    }

    private var pending: (owner: Owner, request: Request)?

    mutating func deferUntilPlay(owner: Owner, suspendedFor: Double, playHeadAtSuspension: Double?) {
        pending = (owner, Request(suspendedFor: suspendedFor, playHeadAtSuspension: playHeadAtSuspension))
    }

    mutating func consume(owner: Owner?, isPaused: Bool) -> Request? {
        guard let pending else { return nil }
        guard owner == pending.owner else { self.pending = nil; return nil }
        guard !isPaused else { return nil }
        self.pending = nil
        return pending.request
    }

    mutating func clear() { pending = nil }
}
