import Foundation

@main enum PlayerFirstFrameCoverTests {
    static func main() {
        typealias Policy = PlayerFirstFrameCoverPolicy<Int>
        let a = PlayerFirstFrameMedia(libraryID: "public-show", videoID: "episode-a")
        let b = PlayerFirstFrameMedia(libraryID: "public-show", videoID: "episode-b")
        let c = PlayerFirstFrameMedia(libraryID: "other-show", videoID: "episode-a")
        var state = Policy()
        func shown(_ state: Policy, _ media: PlayerFirstFrameMedia, failed: Bool = false,
                   exited: Bool = false, context: Bool = true) -> Bool {
            state.showsArtwork(media: media, failed: failed, exited: exited, contextCurrent: context)
        }
        precondition(shown(state, a), "initial metadata art precedes any load acceptance")
        state.bind(owner: 1, mountGeneration: 10, media: a)
        precondition(shown(state, a), "load acceptance alone must not reveal video")
        precondition(!state.acceptStart(callbackOwner: 1, activeOwner: 1, mountGeneration: 10,
                                        media: a, accepted: false, contextCurrent: true), "unsettled/unadmitted start")
        precondition(!state.acceptStart(callbackOwner: 0, activeOwner: 1, mountGeneration: 10,
                                        media: a, accepted: true, contextCurrent: true), "old-source callback")
        precondition(!state.acceptStart(callbackOwner: 1, activeOwner: nil, mountGeneration: 10,
                                        media: a, accepted: true, contextCurrent: true), "invalidated active request")
        precondition(!state.acceptStart(callbackOwner: 1, activeOwner: 1, mountGeneration: 9,
                                        media: a, accepted: true, contextCurrent: true), "retired AV item generation")
        precondition(!state.acceptStart(callbackOwner: 1, activeOwner: 1, mountGeneration: 10,
                                        media: b, accepted: true, contextCurrent: true), "wrong episode identity")
        precondition(!state.acceptStart(callbackOwner: 1, activeOwner: 1, mountGeneration: 10,
                                        media: a, accepted: true, contextCurrent: false), "replaced account/profile context")
        precondition(shown(state, a))
        precondition(!shown(state, a, failed: true), "error UI owns failure, not the artwork")
        precondition(!shown(state, a, exited: true) && !shown(state, a, context: false))
        precondition(state.acceptStart(callbackOwner: 1, activeOwner: 1, mountGeneration: 10,
                                       media: a, accepted: true, contextCurrent: true))
        precondition(!shown(state, a))
        state.beginPresentation()
        precondition(!shown(state, a), "sheet/foreground onAppear must not re-cover a healthy presentation")
        // There is intentionally no buffering input. Same-media accepted rebind/replacement must keep video visible.
        state.bind(owner: 2, mountGeneration: 11, media: a)
        precondition(!shown(state, a), "same-media retry, source change or retained rebuffer")
        precondition(!state.acceptStart(callbackOwner: 1, activeOwner: 2, mountGeneration: 10,
                                        media: a, accepted: true, contextCurrent: true))
        state.bind(owner: 3, mountGeneration: 12, media: b)
        precondition(shown(state, b), "new incoming episode has its own covered startup")
        precondition(!state.acceptStart(callbackOwner: 2, activeOwner: 3, mountGeneration: 11,
                                        media: b, accepted: true, contextCurrent: true), "outgoing frame cannot reveal incoming episode")
        precondition(!shown(state, a), "cancelled/refused pending advance may restore the last healthy picture")
        state.bind(owner: 4, mountGeneration: 13, media: b)
        precondition(shown(state, b), "incoming episode source hop remains covered until that exact source is accepted")
        precondition(!state.acceptStart(callbackOwner: 3, activeOwner: 4, mountGeneration: 12,
                                        media: b, accepted: true, contextCurrent: true))
        precondition(state.acceptStart(callbackOwner: 4, activeOwner: 4, mountGeneration: 13,
                                       media: b, accepted: true, contextCurrent: true))
        precondition(!shown(state, b) && shown(state, c), "library identity participates, not video ID alone")
        state.retire()
        state.bind(owner: 5, mountGeneration: 14, media: c)
        precondition(!shown(state, c), "late accepted load must not resurrect an exited cover")
        precondition(!state.acceptStart(callbackOwner: 4, activeOwner: 4, mountGeneration: 13,
                                        media: b, accepted: true, contextCurrent: true))
        state.beginPresentation()
        precondition(shown(state, c), "a new presentation starts fresh without inheriting old reveal state")
        let adHoc = PlayerFirstFrameMedia(libraryID: nil, videoID: nil)
        state.bind(owner: 6, mountGeneration: 0, media: adHoc)
        precondition(state.acceptStart(callbackOwner: 6, activeOwner: 6, mountGeneration: 0,
                                       media: adHoc, accepted: true, contextCurrent: true))
        precondition(!shown(state, adHoc), "metadata-free direct playback must not remain covered")
        print("PASS actual first-frame cover policy: exact owner/item/media/context, accepted-start latch, no healthy rebuffer cover, supersession/restore/exit/reset")
    }
}
