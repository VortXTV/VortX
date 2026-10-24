import Foundation

/// Logical artwork identity, never a playable/signed URL or a recaptured profile identifier.
struct PlayerFirstFrameMedia: Hashable, Sendable {
    let libraryID: String?
    let videoID: String?
}

/// Presentation-only latch. A load command/file-loaded/buffering event is NOT a start receipt.
/// Call acceptStart only from the existing provenance + start-evidence + audio/asset-sanity transaction.
/// AV owns its item-generation render evidence; MPV's current transaction is settled-clock evidence,
/// not proof that a corresponding Metal drawable was physically presented.
struct PlayerFirstFrameCoverPolicy<Owner: Equatable> {
    private(set) var requestedOwner: Owner?
    private(set) var requestedMountGeneration: UInt64?
    private(set) var requestedMedia: PlayerFirstFrameMedia?
    private(set) var revealedMedia: PlayerFirstFrameMedia?
    private(set) var retired = false

    mutating func beginPresentation() {
        // An ordinary onAppear after a child sheet must not re-cover healthy playback.
        if retired { self = Self() }
    }

    mutating func bind(owner: Owner, mountGeneration: UInt64, media: PlayerFirstFrameMedia) {
        guard !retired else { return }
        requestedOwner = owner
        requestedMountGeneration = mountGeneration
        requestedMedia = media
        // Retain only the last successfully revealed media. Same-media recovery/rebuffer stays visible;
        // a newly issued episode is covered, and a refused/cancelled advance can restore the old picture.
    }

    @discardableResult
    mutating func acceptStart(callbackOwner: Owner, activeOwner: Owner?, mountGeneration: UInt64,
                              media: PlayerFirstFrameMedia, accepted: Bool, contextCurrent: Bool) -> Bool {
        guard !retired, accepted, contextCurrent,
              callbackOwner == activeOwner, requestedOwner == callbackOwner,
              requestedMountGeneration == mountGeneration, requestedMedia == media else { return false }
        revealedMedia = media
        return true
    }

    func showsArtwork(media: PlayerFirstFrameMedia, failed: Bool, exited: Bool, contextCurrent: Bool) -> Bool {
        !retired && !failed && !exited && contextCurrent && revealedMedia != media
    }

    mutating func retire() {
        retired = true
        requestedOwner = nil
        requestedMountGeneration = nil
        requestedMedia = nil
    }
}
