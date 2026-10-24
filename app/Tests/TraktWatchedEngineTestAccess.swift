// Test runner appends this access-only extension to an otherwise byte-identical captured copy of
// TraktSyncEngine.swift. It does not replace or reimplement any production read/commit/codec method.
extension TraktSyncEngine {
    static func fixtureNew() -> TraktSyncEngine { TraktSyncEngine() }
    private func fixtureGeneration() -> Int {
        cache.withLock { $0.generation }
    }
    func fixturePull(_ session: TraktSessionID) async {
        await pullWatched(expectedSession: session, gen: fixtureGeneration())
    }
    func fixtureDrain(_ session: TraktSessionID) async {
        await drainQueue(expectedSession: session, gen: fixtureGeneration())
    }
    func fixtureState() -> (Set<String>, Set<String>, String?, Int?, [PendingPush]) {
        cache.withLock { state in
            (state.watchedIDs, state.watchedEpisodeKeys, state.lastActivityFingerprint,
             state.watchedReadVersion, state.pendingPushes)
        }
    }
}
