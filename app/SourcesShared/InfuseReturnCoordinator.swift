import Foundation

/// Brings the viewer's stopping point back from Infuse. Each Infuse launch is registered with a one-time
/// token in its `x-success` callback; when Infuse calls back, the position is saved through the native
/// progress path, and only for the profile that started playback, so Continue Watching and other
/// devices pick it up like any built-in playback.
@MainActor
enum InfuseReturnCoordinator {
    private static let storeKey = "vortx.infuse.handoffs"
    /// A callback that cold-launches VortX arrives before the account is mounted; these spaced retries
    /// (seconds) cover a normal launch, and every return to the foreground tries again after that.
    private static let retryDelays: [UInt64] = [1, 2, 4, 8, 15, 30]
    private static var retryTask: Task<Void, Never>?

    /// The Infuse link for `stream`, starting at `startSeconds` (the saved resume point when nil) and
    /// carrying the callbacks that report back. Without a title or an active profile there is nothing to
    /// save into, so the plain link is returned.
    static func launchURL(stream: URL, meta: PlaybackMeta?, startSeconds: Double?, durationSeconds: Double?) async -> URL? {
        guard let meta, let profile = ProfileStore.shared.activeID else {
            return InfuseDeepLink.playURL(stream: stream, metadata: meta, startSeconds: startSeconds)
        }
        var start = startSeconds
        if start == nil {
            start = await CoreBridge.shared.nativeResumeSeconds(for: meta, target: .capture(core: CoreBridge.shared))
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let scheme = TopShelfSnapshot.urlScheme
        guard let success = InfuseReturnPolicy.callbackURL(scheme: scheme, token: token, succeeded: true),
              let failure = InfuseReturnPolicy.callbackURL(scheme: scheme, token: token, succeeded: false) else {
            return InfuseDeepLink.playURL(stream: stream, metadata: meta, startSeconds: start)
        }
        let handoff = InfuseReturnPolicy.makeHandoff(token: token, stream: stream, meta: meta, profileID: profile.uuidString,
                                                     durationSeconds: durationSeconds ?? residentRuntimeSeconds(for: meta), now: Date())
        save(InfuseReturnPolicy.pruned(load() + [handoff], now: Date()))
        DiagnosticsLog.log("infuse", "handoff start=\(InfuseReturnPolicy.startPosition(start) ?? 0) runtime_known=\(handoff.durationSeconds != nil)")
        return InfuseDeepLink.playURL(stream: stream, metadata: meta, startSeconds: start, success: success, failure: failure)
    }

    /// The open detail page's runtime for `meta`: a movie's measured duration when it has played here,
    /// else the metadata runtime (per episode for a series). Nil when the page shows another title.
    private static func residentRuntimeSeconds(for meta: PlaybackMeta) -> Double? {
        let core = CoreBridge.shared
        guard let loaded = core.metaDetails?.meta, loaded.id == meta.libraryId else { return nil }
        let measured = core.metaDetails?.libraryItem.map { $0.state.duration / 1000 }.flatMap { $0 > 0 ? $0 : nil }
        return meta.usesSeriesLifecycle ? (loaded.runtimeSeconds ?? measured) : (measured ?? loaded.runtimeSeconds)
    }

    /// Handles an inbound URL if it is an Infuse callback. Returns false for any other link.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let callback = InfuseReturnPolicy.parse(url, scheme: TopShelfSnapshot.urlScheme) else { return false }
        var handoffs = InfuseReturnPolicy.pruned(load(), now: Date())
        guard let index = handoffs.firstIndex(where: { $0.token == callback.token }) else {
            DiagnosticsLog.log("infuse", "return ignored reason=unknown_handoff")
            save(handoffs)
            return true
        }
        guard let progress = InfuseReturnPolicy.progress(for: handoffs[index], callback: callback) else {
            let reason = !callback.succeeded ? "infuse_error" : (handoffs[index].durationSeconds == nil ? "runtime_unknown" : "no_usable_position")
            DiagnosticsLog.log("infuse", "return saved=false reason=\(reason)")
            handoffs.remove(at: index)
            save(handoffs)
            return true
        }
        handoffs[index].returnedPositionSeconds = progress.position
        save(handoffs)
        applyReturned()
        return true
    }

    /// Saves every position Infuse returned, once the profile that started it is the mounted one. Called
    /// on each callback and whenever the app becomes active.
    static func applyReturned() {
        if applyOnce() { scheduleRetry() }
    }

    /// One pass over the returned positions. True while some still wait for their profile to mount.
    private static func applyOnce() -> Bool {
        let handoffs = InfuseReturnPolicy.pruned(load(), now: Date())
        guard handoffs.contains(where: { $0.returnedPositionSeconds != nil }) else { save(handoffs); return false }
        let core = CoreBridge.shared
        let target = PlaybackMutationTarget.capture(core: core)
        var waiting = false
        var remaining: [InfuseHandoff] = []
        for handoff in handoffs {
            guard let position = handoff.returnedPositionSeconds, let duration = handoff.durationSeconds else {
                remaining.append(handoff); continue
            }
            guard case .native(let binding?) = target, binding.profileID.uuidString.lowercased() == handoff.profileID,
                  core.nativePlaybackTargetIsCurrent(target) else {
                waiting = true; remaining.append(handoff); continue
            }
            core.reportNativeProgress(for: handoff.meta, positionSeconds: position, durationSeconds: duration, target: target)
            DiagnosticsLog.log("infuse", "return saved=true")
        }
        save(remaining)
        return waiting
    }

    private static func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor in
            for delay in retryDelays {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                if !applyOnce() { break }
            }
            retryTask = nil
        }
    }

    private static func load() -> [InfuseHandoff] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([InfuseHandoff].self, from: data)) ?? []
    }

    private static func save(_ handoffs: [InfuseHandoff]) {
        if handoffs.isEmpty { UserDefaults.standard.removeObject(forKey: storeKey); return }
        guard let data = try? JSONEncoder().encode(handoffs) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
