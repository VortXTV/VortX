// Compile-only contract. Include this file alongside the REAL app production sources in the
// strict Swift 6 lane; it is deliberately not a standalone RAM/fake-provider executable.
// It never initializes a singleton, performs I/O, captures credentials, or mints native authority.
// Source-text checks cannot replace this compiler obligation or the separate behavioral gates.

private func requireExternalSyncSendable<Value: Sendable>(_: Value.Type) {}

func externalSyncOwnerCompileContract(
    shadow: TraktPlaybackShadow,
    coordinator: ScrobbleCoordinator,
    traktRatings: TraktRatingsStore,
    traktSync: TraktSyncEngine,
    simklRatings: SIMKLRatingsStore,
    simklWatched: SIMKLWatchedShadow
) {
    requireExternalSyncSendable(TraktPlaybackShadow.self)
    requireExternalSyncSendable(ScrobbleCoordinator.self)
    requireExternalSyncSendable(TraktPlaybackShadow.ContinueWatchingSelection.self)
    requireExternalSyncSendable(TraktRatingsStore.self)
    requireExternalSyncSendable(TraktSyncEngine.self)
    requireExternalSyncSendable(SIMKLRatingsStore.self)
    requireExternalSyncSendable(SIMKLWatchedShadow.self)
    requireExternalSyncSendable(TraktSyncSnapshotEnvelope.self)
    requireExternalSyncSendable(SIMKLRatingsCore.self)
    requireExternalSyncSendable(SIMKLWatchedCore.self)
    let ownerCapture: @Sendable () -> Void = {
        _ = shadow
        _ = coordinator
        _ = traktRatings
        _ = traktSync
        _ = simklRatings
        _ = simklWatched
    }
    _ = ownerCapture
}
