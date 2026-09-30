import Foundation
import TVServices

/// Publishes the Apple TV **Top Shelf** snapshot from the live Continue Watching state.
///
/// This is the app-side half of the hand-off; `SourcesShared/TopShelfSnapshot.swift` is the wire
/// contract, and the `VortXTopShelf` extension is the reader. This file is tvOS-app only and is NOT
/// compiled into the extension, which is what keeps the extension free of the engine models.
///
/// WHY IT LIVES HERE, at the Home model layer: the shelf mirrors the SAME profile-aware Continue
/// Watching selection Home renders. The owner profile goes through
/// `TraktPlaybackShadow.continueWatchingSelection(fallback:libraryItems:)`, while an overlay profile
/// stays on its own private local history. It reads the shared singletons directly, so a call site is a
/// bare `publishCurrent()` and the profile-aware selection rule is written down ONCE, here. Nothing in
/// the watched / sync file set is touched.
enum TopShelfSnapshotWriter {

    private typealias WarmCandidate = TopShelfSnapshot.PrivatePublicationPolicy.ArtworkInput

    private struct ArtworkRowKey: Hashable, Sendable {
        let id: String
        let type: String
    }

    /// One in-flight private-art warm pass. An owner or artwork-set change cancels the previous pass and
    /// advances `publicationGeneration`; a progress-only publication preserves it. The generation check
    /// is the commit fence for out-of-order profile/auth refreshes. The pending queue is published before
    /// this task starts.
    @MainActor private static var warmTask: Task<Void, Never>?
    @MainActor private static var publicationGeneration: UInt64 = 0
    @MainActor private static var authBoundaryInstalled = false
    @MainActor private static var lastPrivateSessionID: TraktSessionID?
    @MainActor private static var lastPrivateArtworkInputs: [WarmCandidate]?
    @MainActor private static var lastPrivatePublished: [TopShelfSnapshot.Item]?
    @MainActor private static var lastPublishedSelectionSource: TraktPlaybackShadow.ContinueWatchingSource?

    /// Redirects are admitted only while every hop remains an exact first-party Trakt image URL. The
    /// initial URL is validated before the request starts; this delegate closes the privacy gap where a
    /// trusted CDN URL could redirect the app's private image fetch to an unrelated host.
    private final class ArtworkSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let redirects = TraktArtworkPolicy.RedirectBudget()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url,
                  TraktArtworkPolicy.isFirstPartyArtwork(url.absoluteString),
                  redirects.admit(taskID: task.taskIdentifier) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            redirects.finish(taskID: task.taskIdentifier)
        }
    }

    /// Private, cookie-free image session. Trakt's CDN image bytes are written into the managed App Group
    /// cache below; the extension later reads a local file URL and never re-fetches the raw CDN URL.
    private static let artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ArtworkSessionDelegate(), delegateQueue: nil)
    }()

    /// User setting: mirror Continue Watching onto the tvOS Home screen's Top Shelf.
    ///
    /// Opt-OUT (default on) because the shelf is the feature. It is worth a switch at all because the
    /// Top Shelf is visible to anyone who wakes the TV, without opening VortX and without passing the
    /// profile picker, so what you are part-way through is on show in the room. Someone who does not
    /// want that needs a way to say so.
    static let showKey = "vortx.topShelf.showContinueWatching"
    static let showDefault = true

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: showKey) as? Bool ?? showDefault
    }

    /// Rebuild and publish the shelf from the CURRENT engine + profile state.
    ///
    /// Main-actor because it reads `@Published` state off `CoreBridge` / `ProfileStore`. Cheap and
    /// idempotent: it caps at 8 items, and the store's own content diff means an unchanged Home
    /// refresh writes nothing and wakes nothing. Safe to call from every Home re-seed.
    @MainActor
    static func publishCurrent() {
        installAuthBoundaryObserver()
        // Setting OFF publishes an EMPTY shelf rather than skipping the write. The snapshot outlives
        // the process, so merely not refreshing would leave the last row sitting on the Home screen:
        // the exact thing the user just asked us to stop showing.
        guard isEnabled else {
            cancelWarm(clearArtwork: true)
            publish([])
            return
        }

        let profiles = ProfileStore.shared
        // The SAME rule Home renders by: the owner profile rides the Trakt-aware account selection,
        // while an overlay profile rides its own private synced history. Without this an overlay
        // profile's shelf would show the owner's titles (or the owner's Trakt rows).
        let selection: TraktPlaybackShadow.ContinueWatchingSelection
        if profiles.activeUsesEngineHistory {
            selection = TraktPlaybackShadow.shared.continueWatchingSelection(
                fallback: CoreBridge.shared.continueWatching,
                libraryItems: CoreBridge.shared.library?.catalog ?? []
            )
        } else {
            selection = .init(items: profiles.cwItems, source: .local, sessionID: nil)
        }
        let pending = items(from: selection.items, source: selection.source)
        // Keep the warm identity exactly aligned with the queue above. Raw Trakt state can still carry
        // finished, removed, or temporary seeds; those rows never render and must not consume one of the
        // bounded eight private-image requests.
        let sourceItems = Array(selection.items.lazy
            .filter {
                EpisodePlaybackIdentity.usesSeriesLifecycle(type: $0.type) || !$0.isFinished
            }
            .filter { $0.removed != true && $0.temp != true }
            .prefix(TopShelfSnapshot.maxItems)
            .map { WarmCandidate(id: $0.id, type: $0.type, poster: $0.poster) })

        // A private Trakt row is published immediately with nil artwork. The only later replacement is
        // a local file URL produced by the bounded first-party warm pass; joined third-party artwork is
        // intentionally not sent to the system and never triggers a new request.
        // The managed directory contains only private Trakt art. Clear it on every new selection so a
        // toggle-off, overlay switch, or fallback to engine history cannot leave an unreferenced prior
        // account's images behind in the shared container.
        if selection.source == .trakt,
           let sessionID = selection.sessionID,
           TopShelfSnapshot.containerURL != nil,
           lastPublishedSelectionSource == .trakt,
           let previouslyPublished = lastPrivatePublished,
           !TopShelfSnapshot.PrivatePublicationPolicy.requiresWarmRestart(
               previousSessionRaw: lastPrivateSessionID?.rawValue,
               currentSessionRaw: sessionID.rawValue,
               previousArtworkInputs: lastPrivateArtworkInputs,
               currentArtworkInputs: sourceItems
           ) {
            // Home re-seeds frequently. Progress/title changes are a new publication, not a new image
            // owner: preserve managed file posters and the in-flight warm pass, then publish the fresh
            // progress immediately. This avoids a CDN request and cache prune on every playback tick.
            let updated = TopShelfSnapshot.PrivatePublicationPolicy.mergingCurrentProgress(
                pending: pending,
                previouslyPublished: previouslyPublished
            )
            lastPrivatePublished = updated
            publish(updated)
            return
        }
        cancelWarm(clearArtwork: true)
        lastPublishedSelectionSource = selection.source
        publish(pending)
        guard selection.source == .trakt,
              let sessionID = selection.sessionID,
              TopShelfSnapshot.containerURL != nil else { return }

        lastPrivateSessionID = sessionID
        lastPrivateArtworkInputs = sourceItems
        lastPrivatePublished = pending
        let generation = publicationGeneration
        warmTask = Task.detached(priority: .utility) {
            await warmTraktArtwork(
                sourceItems: sourceItems,
                sessionID: sessionID,
                generation: generation
            )
        }
    }

    /// Clear the shelf. Used when the shell can no longer vouch for what the shelf would say.
    @MainActor
    static func clear() {
        cancelWarm(clearArtwork: true)
        lastPublishedSelectionSource = nil
        publish([])
    }

    // MARK: Mapping

    /// Flatten the engine's local Continue Watching into the wire items. Kept as a compatibility overload
    /// for existing call sites and tests; private Trakt rows use the source-aware overload below.
    static func items(from cw: [CoreCWItem]) -> [TopShelfSnapshot.Item] {
        items(from: cw, source: .local)
    }

    /// Flatten one profile-aware Continue Watching selection into the wire items. A local engine row keeps
    /// its existing raw HTTP(S) poster behavior. A Trakt selection starts with nil poster fields so a
    /// third-party joined URL can never escape into the system Top Shelf.
    static func items(
        from cw: [CoreCWItem],
        source: TraktPlaybackShadow.ContinueWatchingSource
    ) -> [TopShelfSnapshot.Item] {
        cw.lazy
            // The rail's own prune rule. `CoreBridge` already applies `isFinished` before publishing
            // the rail, but the shelf re-applies it rather than trusting that, because a shelf is
            // rendered from a FILE that can outlive the process that wrote it: a title finished on
            // another device and synced down must not linger on the TV's Home screen.
            .filter {
                EpisodePlaybackIdentity.usesSeriesLifecycle(type: $0.type) || !$0.isFinished
            }
            // Removed / temp entries are not "in the library" (see CoreCWItem), so they have no
            // business on the Home screen even while the engine still carries them in the bucket.
            .filter { $0.removed != true && $0.temp != true }
            .prefix(TopShelfSnapshot.maxItems)
            .map {
                TopShelfSnapshot.Item(
                    id: $0.id,
                    type: $0.type,
                    title: $0.name,
                    poster: shelfPoster($0.poster, source: source),
                    progress: shelfProgress($0.progress)
                )
            }
    }

    /// Watch progress, guaranteed finite and inside 0…1.
    ///
    /// `CoreCWItem.progress` already clamps, so in practice this is a pass-through. It exists because
    /// a non-finite value here would be silently CORROSIVE rather than merely wrong: JSONEncoder throws
    /// on a NaN or an infinity by default, so a single bad item would fail the whole encode, the write
    /// would return false, and the shelf would quietly freeze on its last good content forever with
    /// nothing in the log to say why. The engine feeds `progress` from add-on-supplied durations, which
    /// is not a source worth betting a silent permanent failure on for the cost of one comparison.
    /// `TVTopShelfSectionedItem.playbackProgress` documents the same 0…1 requirement on the far side.
    private static func shelfProgress(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// The poster URL to hand the system for a LOCAL engine row.
    ///
    /// This is the RAW add-on / metahub poster, deliberately NOT routed through our own
    /// `poster.vortx.tv` baked-art service, for two independent reasons:
    ///
    ///  1. The system fetches Top Shelf art itself, out of process, on its own schedule, with no
    ///     chance for us to attach headers. Our art edge is behind the `X-VX-*` signing gate, so a
    ///     header-signed URL is not an option here (that is what `PosterImageLoader` does, and it
    ///     works only because the fetch is ours).
    ///  2. The header-less variant (`VortXEdgeAuth.signedURL`) bakes a per-second `vts` that the
    ///     workers accept only within a 300s skew window. A snapshot routinely sits on disk for hours
    ///     or days between writes, and the shelf is rendered when the app is NOT running, so nothing
    ///     can re-sign it. Every signed URL we could write would be expired long before the system
    ///     asked for it, and the shelf would be permanently art-less the moment the edge leaves
    ///     OBSERVE mode. A raw poster is un-gated, needs no headers, and does not expire.
    ///
    /// Returns nil for a non-http(s) URL. An item with no art still renders (title + progress), so a
    /// missing poster costs a tile's picture, never the row.
    private static func shelfPoster(
        _ raw: String?,
        source: TraktPlaybackShadow.ContinueWatchingSource
    ) -> String? {
        // A Trakt row's poster is account-private input. Even if it joined a local catalog row, handing
        // that URL to the system would let Top Shelf fetch a third party outside the app's ownership and
        // would violate Trakt's cache-before-hotlink requirement. The warmer below admits only a validated
        // first-party `*.trakt.tv/images/` URL and replaces it with a managed local file URL.
        guard source == .local else { return nil }
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return raw
    }

    // MARK: Publish

    @MainActor
    private static func installAuthBoundaryObserver() {
        guard !authBoundaryInstalled else { return }
        authBoundaryInstalled = true
        TraktAuthBoundary.observe(key: "trakt-top-shelf") { emittedSessionID in
            // The auth boundary is synchronous and may be announced from a credential worker. Hop to
            // the main actor before touching the generation/task state or notifying TVServices. The
            // emitted session is part of the event: an old callback must not clear a newer publication.
            Task { @MainActor in
                let observedGeneration = publicationGeneration
                handleAuthBoundary(
                    emittedSessionID: emittedSessionID,
                    observedGeneration: observedGeneration
                )
            }
        }
    }

    @MainActor
    private static func handleAuthBoundary(
        emittedSessionID: TraktSessionID?,
        observedGeneration: UInt64
    ) {
        guard observedGeneration == publicationGeneration,
              TraktAuth.storedSessionID == emittedSessionID,
              TopShelfSnapshot.PrivatePublicationPolicy.shouldClearObsoletePrivateOwner(
                  emittedSessionRaw: emittedSessionID?.rawValue,
                  currentSessionRaw: TraktAuth.storedSessionID?.rawValue,
                  privateOwnerRaw: lastPrivateSessionID?.rawValue,
                  publishedPrivateRows: lastPublishedSelectionSource == .trakt
              ) else { return }

        // Only an obsolete private owner is cleared. A stale auth event never reaches this branch, and a
        // local overlay publication is left intact rather than replaced by an empty shelf.
        cancelWarm(clearArtwork: true)
        lastPublishedSelectionSource = nil
        publish([])
    }

    @MainActor
    private static func cancelWarm(clearArtwork: Bool) {
        publicationGeneration &+= 1
        warmTask?.cancel()
        warmTask = nil
        if clearArtwork {
            lastPrivateSessionID = nil
            lastPrivateArtworkInputs = nil
            lastPrivatePublished = nil
            lastPublishedSelectionSource = nil
            TopShelfSnapshot.clearArtworkCache()
        }
    }

    /// Fetch at most the eight selected private rows one at a time, then commit each response only while
    /// the original account/profile publication still owns the generation. The Top Shelf gets a pending
    /// title/progress queue immediately; a later commit merely fills local file URLs for successful art.
    private static func warmTraktArtwork(
        sourceItems: [WarmCandidate],
        sessionID: TraktSessionID,
        generation: UInt64
    ) async {
        var replacements: [ArtworkRowKey: String] = [:]

        for candidate in sourceItems.prefix(TopShelfSnapshot.maxItems) {
            guard !Task.isCancelled,
                  let raw = candidate.poster,
                  TraktArtworkPolicy.isFirstPartyArtwork(raw),
                  let url = URL(string: raw),
                  let data = await fetchTraktArtwork(from: url) else { continue }

            // Store on the main actor so the ownership check and the file write are ordered with the auth
            // boundary/profile publication. A stale task can therefore not write an old account's image
            // after the boundary has cleared the managed directory.
            let stored: (owned: Bool, url: URL?) = await MainActor.run {
                guard generation == publicationGeneration,
                      TraktAuth.storedSessionID == sessionID,
                      isEnabled,
                      lastPrivateSessionID == sessionID,
                      lastPrivateArtworkInputs == sourceItems,
                      lastPublishedSelectionSource == .trakt else { return (false, nil) }
                return (true, TopShelfSnapshot.storeArtwork(data, for: raw))
            }
            guard stored.owned else { return }
            if let localURL = stored.url {
                replacements[ArtworkRowKey(id: candidate.id, type: candidate.type)] = localURL.absoluteString
            }
        }

        guard !Task.isCancelled else { return }
        let replacementURLs = replacements
        await MainActor.run {
            guard generation == publicationGeneration,
                  TraktAuth.storedSessionID == sessionID,
                  isEnabled,
                  lastPrivateSessionID == sessionID,
                  lastPrivateArtworkInputs == sourceItems,
                  lastPublishedSelectionSource == .trakt,
                  let current = lastPrivatePublished else { return }
            let updated = current.map { item -> TopShelfSnapshot.Item in
                guard let local = replacementURLs[ArtworkRowKey(id: item.id, type: item.type)] else {
                    return item
                }
                return TopShelfSnapshot.Item(id: item.id, type: item.type, title: item.title, poster: local, progress: item.progress)
            }
            lastPrivatePublished = updated
            publish(updated)
        }
    }

    private static func fetchTraktArtwork(from url: URL) async -> Data? {
        guard !Task.isCancelled,
              TraktArtworkPolicy.isFirstPartyArtwork(url.absoluteString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await artworkSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  let finalURL = response.url,
                  TraktArtworkPolicy.isFirstPartyArtwork(finalURL.absoluteString),
                  TopShelfSnapshot.PrivatePublicationPolicy.acceptsArtworkResponse(
                      finalURLIsFirstParty: true,
                      statusCode: http.statusCode,
                      mimeType: http.mimeType,
                      expectedContentLength: http.expectedContentLength,
                      accumulatedBytes: 1
                  ) else { return nil }
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), TopShelfSnapshot.maxArtworkBytes))
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                // Returning from the AsyncBytes sequence tears down this request; do not let an
                // unknown-length response accumulate beyond the managed per-image bound.
                guard data.count < TopShelfSnapshot.maxArtworkBytes else { return nil }
                data.append(byte)
            }
            guard TopShelfSnapshot.PrivatePublicationPolicy.acceptsArtworkResponse(
                finalURLIsFirstParty: TraktArtworkPolicy.isFirstPartyArtwork(finalURL.absoluteString),
                statusCode: http.statusCode,
                mimeType: http.mimeType,
                expectedContentLength: http.expectedContentLength,
                accumulatedBytes: data.count
            ) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    @MainActor
    private static func publish(_ items: [TopShelfSnapshot.Item]) {
        // No container => unsigned build / no App Group / Lite. Nothing to do, nothing to log loudly.
        guard TopShelfSnapshot.containerURL != nil else { return }
        let changed = TopShelfSnapshot.write(items)
        guard changed else { return }
        // Only nudge the system when the content actually moved: this wakes the extension, so firing
        // it on every unchanged Home re-seed would be pure churn.
        TVTopShelfContentProvider.topShelfContentDidChange()
        DiagnosticsLog.log("topshelf", "published \(items.count) item(s)")
    }
}
