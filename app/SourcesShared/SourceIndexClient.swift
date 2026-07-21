import Foundation

// MARK: - Live Source Index authorization lifecycle

/// Process-local authorization identity for Source Index work. The counters are lock-protected because remote
/// config installs advance them on the installing actor before the UI can be notified. No secret is stored here.
struct SourceIndexLifecycleSnapshot: Hashable, Sendable {
    let sourceGeneration: UInt64
    let sessionGeneration: UInt64
    let consentGeneration: UInt64
}

struct SourceIndexLifecycleTransition: Sendable {
    let retired: SourceIndexLifecycleSnapshot
    let current: SourceIndexLifecycleSnapshot
    let retiredSession: Bool
    let retiredConsent: Bool
}

enum SourceIndexLifecycleClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sourceGeneration: UInt64 = 0
    nonisolated(unsafe) private static var sessionGeneration: UInt64 = 0
    nonisolated(unsafe) private static var consentGeneration: UInt64 = 0

    static func snapshot() -> SourceIndexLifecycleSnapshot {
        lock.withLock {
            SourceIndexLifecycleSnapshot(
                sourceGeneration: sourceGeneration,
                sessionGeneration: sessionGeneration,
                consentGeneration: consentGeneration
            )
        }
    }

    /// Retire all current Source Index work while leaving the shared moat authorization untouched.
    static func closeSource() -> SourceIndexLifecycleTransition {
        advance(session: false, consent: false)
    }

    /// Retire a VortX account session and every Source Index request that belonged to it.
    static func mutateSession() -> SourceIndexLifecycleTransition {
        advance(session: true, consent: false)
    }

    /// Rotate give-to-get authorization on both opt-out and opt-in. The signal is emitted before the preference
    /// write, so each edge needs a fresh source and consent generation: work created in either narrow pre-write
    /// gap is retired by the next edge and cannot become authorized under the reopened scope.
    static func rotateConsentAuthorization() -> SourceIndexLifecycleTransition {
        advance(session: false, consent: true)
    }

    private static func advance(session: Bool, consent: Bool) -> SourceIndexLifecycleTransition {
        lock.withLock {
            let retired = SourceIndexLifecycleSnapshot(
                sourceGeneration: sourceGeneration,
                sessionGeneration: sessionGeneration,
                consentGeneration: consentGeneration
            )
            sourceGeneration &+= 1
            if session { sessionGeneration &+= 1 }
            if consent { consentGeneration &+= 1 }
            return SourceIndexLifecycleTransition(
                retired: retired,
                current: SourceIndexLifecycleSnapshot(
                    sourceGeneration: sourceGeneration,
                    sessionGeneration: sessionGeneration,
                    consentGeneration: consentGeneration
                ),
                retiredSession: session,
                retiredConsent: consent
            )
        }
    }
}

@MainActor
protocol SourceIndexLifecycleParticipant: AnyObject {
    /// Clear any published/selectable Source Index state now. The owning lifecycle scope separately cancels
    /// shared work only through the retired generation, so a delayed cleanup cannot reach reopened requests.
    func sourceIndexLifecycleDidClose(retiredSourceGeneration: UInt64)
}

struct SourceIndexPreferenceGateState: Equatable, Sendable {
    let consent: Bool
    let serve: Bool
    let fleet: Bool
}

/// One weak registry for live serve sources and source-list models. Gate mutations are delivered explicitly at
/// their write boundaries; UserDefaults notification is a fallback for any future direct writer.
@MainActor
final class SourceIndexLifecycleScope {
    static let shared = SourceIndexLifecycleScope()

    typealias GateStateProvider = @Sendable () -> SourceIndexPreferenceGateState
    typealias CancelShared = @Sendable (UInt64) async -> Void
    typealias ClearMoat = @Sendable (UInt64?, UInt64?) async -> Void

    private final class WeakParticipant {
        weak var value: (any SourceIndexLifecycleParticipant)?
        init(_ value: any SourceIndexLifecycleParticipant) { self.value = value }
    }

    private var participants: [WeakParticipant] = []
    private let gateStateProvider: GateStateProvider
    private let cancelShared: CancelShared
    private let clearMoat: ClearMoat
    private var observedGateState: SourceIndexPreferenceGateState
    private var defaultsObserver: NSObjectProtocol?
    private var remoteConfigObserver: NSObjectProtocol?

    init(
        observeMutations: Bool = true,
        gateStateProvider: @escaping GateStateProvider = {
            SourceIndexPreferenceGateState(
                consent: MoatConsent.contributeAndConsume,
                serve: SourceIndexClient.serveEnabled,
                fleet: RemoteConfig.snapshot.isFeatureOn(
                    "sourceIndex", default: RemoteConfigDefaults.featureSourceIndex
                )
            )
        },
        cancelShared: @escaping CancelShared = { retiredGeneration in
            SourceIndexFetchCoalescer.shared.cancel(upToSourceGeneration: retiredGeneration)
        },
        clearMoat: @escaping ClearMoat = { retiredSession, retiredConsent in
            MoatToken.shared.clear(
                retiredSessionGeneration: retiredSession,
                retiredConsentGeneration: retiredConsent
            )
        }
    ) {
        self.gateStateProvider = gateStateProvider
        self.cancelShared = cancelShared
        self.clearMoat = clearMoat
        observedGateState = gateStateProvider()
        guard observeMutations else { return }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.preferencesDidChangeFromDefaults() }
        }
        remoteConfigObserver = NotificationCenter.default.addObserver(
            forName: RemoteConfig.sourceIndexFeatureDidInstall,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let oldFleet = notification.userInfo?[RemoteConfig.sourceIndexOldValueKey] as? Bool
            let newFleet = notification.userInfo?[RemoteConfig.sourceIndexNewValueKey] as? Bool
            let transition = notification.object as? SourceIndexLifecycleTransition
            Task { @MainActor [weak self] in
                self?.remoteConfigDidInstall(oldFleet: oldFleet, newFleet: newFleet, transition: transition)
            }
        }
    }

    func register(_ participant: any SourceIndexLifecycleParticipant) {
        participants.removeAll { $0.value == nil || $0.value === participant }
        participants.append(WeakParticipant(participant))
    }

    /// Called before a known preference writer applies its new values. Advancing first makes rapid off/on
    /// transitions observable even when UserDefaults coalesces its later notification.
    func preferencesWillApply(consent: Bool? = nil, serve: Bool? = nil) {
        let before = observedGateState
        let after = SourceIndexPreferenceGateState(
            consent: consent ?? before.consent,
            serve: serve ?? before.serve,
            fleet: before.fleet
        )
        applyPreferenceTransition(from: before, to: after)
    }

    /// Every restore, adoption, and sign-out retires the current account scope before credentials mutate.
    func sessionWillMutate() {
        apply(SourceIndexLifecycleClock.mutateSession(), clearRetiredMoat: true)
    }

    private func preferencesDidChangeFromDefaults() {
        applyPreferenceTransition(from: observedGateState, to: gateStateProvider())
    }

    private func applyPreferenceTransition(
        from before: SourceIndexPreferenceGateState,
        to after: SourceIndexPreferenceGateState
    ) {
        observedGateState = after
        if before.consent != after.consent {
            apply(SourceIndexLifecycleClock.rotateConsentAuthorization(), clearRetiredMoat: true)
            return
        }
        let wasOpen = before.consent && before.serve && before.fleet
        let isOpen = after.consent && after.serve && after.fleet
        if wasOpen != isOpen {
            apply(SourceIndexLifecycleClock.closeSource(), clearRetiredMoat: false)
        }
    }

    func remoteConfigDidInstall(
        oldFleet: Bool?,
        newFleet: Bool?,
        transition: SourceIndexLifecycleTransition?
    ) {
        guard let newFleet else { return }
        observedGateState = SourceIndexPreferenceGateState(
            consent: observedGateState.consent,
            serve: observedGateState.serve,
            fleet: newFleet
        )
        guard oldFleet == true, newFleet == false, let transition else { return }
        apply(transition, clearRetiredMoat: false)
    }

    private func apply(_ transition: SourceIndexLifecycleTransition, clearRetiredMoat: Bool) {
        participants.removeAll { $0.value == nil }
        for participant in participants.compactMap(\.value) {
            participant.sourceIndexLifecycleDidClose(
                retiredSourceGeneration: transition.retired.sourceGeneration
            )
        }

        let cancelShared = self.cancelShared
        let clearMoat = self.clearMoat
        Task {
            await cancelShared(transition.retired.sourceGeneration)
            guard clearRetiredMoat else { return }
            await clearMoat(
                transition.retiredSession ? transition.retired.sessionGeneration : nil,
                transition.retiredConsent ? transition.retired.consentGeneration : nil
            )
        }
    }
}

/// Client for VortX's community SOURCE INDEX at `sources.vortx.tv` ("Singularity"): the pooled record of which
/// torrent sources exist for a title, corroborated across users.
///
/// TWO halves, both 100% fail-soft (any miss / error / offline is a silent no-op; nothing ever blocks or slows
/// playback or a screen):
///
///   1. HOARD (default ON, anonymous): whenever the app assembles a title's stream results from its add-ons /
///      debrid / usenet / torrent sources, it reports the source DESCRIPTORS -- NOT the media, NOT any account
///      token or user id. Torrent-only v1 sends { kind, id, quality, sizeBytes, seeders? }, where `id` is an
///      exact 40-hex infohash. Raw HTTP and usenet URLs are never uploaded. Fire-and-forget, batched, deduped
///      by infohash.
///
///   2. SERVE (opt-in): when the user turns the Singularity toggle ON AND is signed in, the detail / stream
///      screen reads the corroborated pooled sources for the title and MERGES them into the stream list as
///      community torrent sources. Each returned infohash is resolved by the user's own debrid pipeline.
///      HTTP and usenet have no v1 consumer contract and are dropped. Empty on any miss; signed-out disables
///      the read entirely (hard login gate, matching the worker).
///
/// GIVE-TO-GET: every method is additionally gated on `MoatConsent.contributeAndConsume`. If the user has
/// opted out of the anonymized-data pool, this client neither contributes nor consumes.
///
/// GATING (VortX-only): `sources.vortx.tv` is in `VortXEdgeAuth.gatedHosts`, so BOTH the POST and the GET are
/// HMAC-signed. Signing is a safe no-op without a provisioned secret (the worker's observe mode allows it).
enum SourceIndexClient {

    // MARK: - Public models

    /// Torrent-only v1 has one wire kind.
    enum Kind: String { case torrent }

    /// One anonymized source descriptor for the HOARD upload. Carries ONLY public, non-personal fields.
    struct Descriptor: Encodable, Sendable {
        let kind: String
        let id: String            // normalized 40-hex torrent infohash
        let quality: String       // e.g. "4K", "1080p", "Other" (from StreamRanking.qualityLabel)
        let sizeBytes: Int64      // 0 when the add-on advertised no size
        let seeders: Int?         // when advertised
    }

    /// One corroborated source the pool returns for SERVE. `id` matches the descriptor id space.
    struct PooledSource: Decodable, Sendable {
        let kind: String?
        let id: String?
        let quality: String?
        let sizeBytes: Int64?
        let seeders: Int?
        let corroboration: Int?   // number of distinct witnesses; the worker only returns >= its quarantine floor
    }

    private struct ContributionBody: Encodable {
        let content_id: String
        let sources: [Descriptor]
    }

    // MARK: - Content id (colon form: imdb[:season:episode])

    /// The pool `content_id` for a title, in the worker's colon form (`tt0903747` for a movie, `tt…:S:E` for an
    /// episode). nil when the value carries no canonical title id (ad-hoc paste-a-link plays have no shareable
    /// id), and nil for a PARTIAL coordinate pair -- see `SourceIndexIdentity.contentKey` for why widening a
    /// half-resolved episode context to the show-wide key is a data-mixing bug, not a graceful fallback.
    ///
    /// Reduction to the TITLE id happens inside the shared resolver, which every caller now goes through:
    /// series call sites pass `behaviorHints.defaultVideoId`, which is often already "tt...:1:1", and appending
    /// this episode's :S:E to that produced "tt...:1:1:3:5", failed the canonical regex, and silently removed
    /// every episode of every such show from the pool (no contribute, no serve).
    ///
    /// IMDb ONLY (decision REQ-260721-33). A tmdb value canonicalizes to a title head here but is refused by
    /// `canonicalContentID` at the end, so it never becomes a key; see that function for why.
    ///
    /// SCOPE: this is the LOW-LEVEL entry, for shared code that has already resolved a single title id. View
    /// and coordinator code must not call it -- those callers state ROLES via `contentID(roles:)` or, for a
    /// Continue-Watching card, `resumeContentID`. `IdentityCallerGateTests` fails if that is violated.
    static func contentID(imdbId: String?, season: Int? = nil, episode: Int? = nil) -> String? {
        guard let bounded = SourceIndexIdentity.boundedIdentityInput(imdbId),
              let titleID = SourceIndexContract.canonicalTitleID(bounded) else {
            diag(.contentIDSkip, reason: .notATitleID,
                 counts: [(.rawLen, SourceIndexDiag.identityLength(imdbId))])
            return nil
        }
        guard let composed = SourceIndexIdentity.contentKey(titleID: titleID, season: season, episode: episode) else {
            diag(.contentIDSkip, reason: .nonCanonicalEpisodeKey,
                 counts: [(.hasSeason, season == nil ? 0 : 1), (.hasEpisode, episode == nil ? 0 : 1)])
            return nil
        }
        return composed
    }

    /// The pool `content_id` for a SCREEN, from its named identity roles.
    ///
    /// This is the entry point every view and coordinator uses. It exists so that no screen ever picks which
    /// of its several ids "is" the title: it declares what each id IS (catalog, default-video, current-video)
    /// and what the page is (movie / series / live), and the shared resolver applies the one authority rule.
    /// The previous shape took an ordered array, and the ORDER decided authority, which is how an add-on's
    /// episode-shaped `defaultVideoId` came to outrank the catalog id of the page the user was on.
    static func contentID(
        roles: SourceIndexIdentity.Roles,
        season: Int? = nil,
        episode: Int? = nil
    ) -> String? {
        contentID(imdbId: SourceIndexIdentity.resolve(roles).titleID, season: season, episode: episode)
    }

    /// The pool `content_id` for a Continue-Watching DIRECT RESUME, which has no page to arbitrate between its
    /// two ids: the library item id and the stored last-played video id.
    ///
    /// Returns nil when those two disagree on the canonical TITLE HEAD. That is the check that catches the
    /// worked failure (`item tt1375666` + stored video `tt0903747:1:1` published Game-of-Thrones groups under
    /// `tt1375666:1:1`); the old guard compared episode NUMBERS, which matched, so it caught nothing.
    ///
    /// A nil return means ONLY "contribute nothing to the pool". It is never a playback gate: both resume
    /// paths continue to resume the user's own stored link on a mismatch, unchanged.
    static func resumeContentID(
        itemID: String?,
        videoID: String?,
        season: Int? = nil,
        episode: Int? = nil
    ) -> String? {
        guard let key = SourceIndexIdentity.resumeKey(
            itemID: itemID, videoID: videoID, season: season, episode: episode
        ) else {
            diag(.contentIDSkip, reason: .resumeIdentityMismatch,
                 counts: [(.rawLen, SourceIndexDiag.identityLength(itemID)),
                          (.contentLen, SourceIndexDiag.identityLength(videoID))])
            return nil
        }
        return key
    }

    // MARK: - Diagnostics (bounded categories only)

    /// Sink seam for the bounded diagnostics. Production writes to the exportable diag log; the standalone
    /// contract harness swaps in a capture so it can PROVE that no rejected add-on text and no catalog id ever
    /// reaches the output, including newline-bearing and very long inputs.
    nonisolated(unsafe) private static var diagnosticSinkStorage: @Sendable (String) -> Void = {
        VXProbe.log("sing", $0)
    }
    private static let diagnosticSinkLock = NSLock()

    static var diagnosticSink: @Sendable (String) -> Void {
        get { diagnosticSinkLock.withLock { diagnosticSinkStorage } }
        set { diagnosticSinkLock.withLock { diagnosticSinkStorage = newValue } }
    }

    /// The ONLY way this file emits a diagnostic. Every textual part of a line -- the event label, the bail
    /// reason, the pool outcome, and each count's KEY -- is a case of a closed enum declared in
    /// SourceIndexIdentity.swift. There is no `String` parameter left, so free text genuinely cannot be
    /// interpolated in from a call site.
    ///
    /// The previous version of this comment claimed exactly that while `event` and the count keys were both
    /// plain `String`, and a verifier compiled a call that interpolated a raw identifier straight into the
    /// event label. The claim is now enforced by the type rather than asserted by the comment.
    ///
    /// What this does NOT constrain, stated precisely instead of glossed: a count VALUE is an `Int`, so a call
    /// site can still put a number derived from an identifier on a line. That is why the only identity-derived
    /// number emitted anywhere here comes from `SourceIndexDiag.identityLength`, which is capped and bucketed.
    static func diag(
        _ event: SourceIndexDiag.Event,
        reason: SourceIndexDiag.Reason? = nil,
        outcome: SourceIndexDiag.Outcome? = nil,
        counts: [(SourceIndexDiag.Count, Int)] = []
    ) {
        diagnosticSink(SourceIndexDiag.line(event, reason: reason, outcome: outcome, counts: counts))
    }

    // MARK: - Descriptor extraction (pure; no user data)

    /// Build the anonymized descriptor set for a title's assembled source groups. Uses `StreamRanking` as the
    /// single source of truth for quality / size / seeders / classification, so the pool's view matches the
    /// app's. Skips YouTube trailers and every stream without an exact 40-hex torrent infohash. Deduped by
    /// normalized infohash.
    ///
    /// PRIVACY: the debrid-resolved `url` of a torrent that a service already unlocked is a personal link, so it
    /// is never sent. Only the public torrent infohash crosses this boundary. HTTP and usenet identifiers have
    /// no v1 contract and are ignored. No account token, user id, filename, or provider tag is included.
    static func descriptors(from groups: [CoreStreamSourceGroup]) -> [Descriptor] {
        var seen = Set<String>()
        var out: [Descriptor] = []
        for group in groups {
            for stream in group.streams where !stream.isYouTubeTrailer {
                guard let d = descriptor(for: stream) else { continue }
                guard seen.insert(d.kind + "|" + d.id).inserted else { continue }
                out.append(d)
            }
        }
        return out
    }

    /// One descriptor for one stream, or nil when it carries no public identity.
    private static func descriptor(for stream: CoreStream) -> Descriptor? {
        let sizeGB = StreamRanking.sizeForSort(stream)               // GB (0 when unknown)
        let sizeBytes = sizeGB > 0 ? Int64((sizeGB * 1024 * 1024 * 1024).rounded()) : 0
        let quality = StreamRanking.qualityLabel(stream)

        // A resolved torrent may also carry a personal URL. Only its public infohash crosses this boundary.
        // Non-torrent streams have no accepted v1 descriptor and are a clean no-op.
        // A DEBRID-mode add-on returns a resolved `url` row with NO `infoHash`; the public 40-hex then lives
        // only in `sources` as the documented `dht:<40hex>` entry. Without that fallback the entire debrid
        // population contributes nothing at all. The resolved `url` is DELIBERATELY not scanned: it carries a
        // personal debrid token, and only add-on-declared public fields may cross this boundary.
        //
        // PRECEDENCE IS SEMANTIC, most-authoritative first, and it used to be inverted. The explicit `infoHash`
        // field IS the identity; `dht:<40hex>` is the one exactly-specified place a debrid row republishes it.
        // The old order consulted free-form provider text BEFORE the documented `dht:` entry, so add-on-chosen
        // bytes could override a real DHT hash the same row was carrying. That free-text recovery path is gone
        // entirely (see the removal note on SourceIndexContract): with no anchored schema to justify it, the
        // only shapes accepted here are the two that are specified.
        // EXACT-SCHEMA ONLY. An earlier form of this fallback scanned any isolated 40-hex run, which would have
        // lifted a PRIVATE TRACKER PASSKEY out of a `tracker:` URL in `sources` and uploaded it as an infohash
        // (caught in cross-review, REQ-260721-05). `infoHashFromSourceEntry` requires a whole-token match.
        let declaredHash = SourceIndexContract.normalizeInfoHash(stream.infoHash)
            ?? stream.sources?.lazy.compactMap({ SourceIndexContract.infoHashFromSourceEntry($0) }).first
        guard let hash = declaredHash else { return nil }
        let seeders = StreamRanking.seedersForSort(stream)
        return Descriptor(kind: Kind.torrent.rawValue, id: hash, quality: quality,
                          sizeBytes: sizeBytes, seeders: seeders >= 0 ? seeders : nil)
    }

    // MARK: - HOARD: POST /sources/contribute (signed, fire-and-forget)

    /// Report the assembled source descriptors for a title. Gated on consent + the fleet feature flag. Popular
    /// titles routinely resolve far more than one POST can carry (the worker rejects a POST above
    /// `MAX_SOURCES_PER_CONTRIBUTE` = 16), so we chunk the whole deduped set into `batchSize`-descriptor POSTs.
    /// [SourceUploadCoordinator] provides one process-wide per-(content,hash) ledger and reserves every POST a
    /// globally spaced start time, including overlapping detached detail/resume call sites. Each POST is
    /// fire-and-forget from the caller. A started POST has one attempt; any non-2xx or transport failure stops
    /// the current title's remaining batches and extends the shared pacing boundary by one interval.
    static func contribute(contentID: String, descriptors: [Descriptor]) async {
        // Every bail below used to be SILENT. A give-to-get pool whose "give" half fails invisibly is why this
        // shipped dead in the field: a full day of playback produced zero contributions and left no trace.
        // Each exit now names its reason exactly once, so the next diag log answers "why" without a code read.
        guard isEnabled else {
            // The consent VALUE is still not printed. What IS printed is WHICH of the two gates is shut,
            // because they are not the same kind of fact and one combined reason made them indistinguishable:
            // the fleet kill switch is server-side config (something WE did to everyone) while consent is user
            // state. A support reader who cannot tell "we disabled it fleet-wide" from "this user opted out"
            // cannot answer the only question this line exists for. The by-elimination consequence of the
            // split is documented on SourceIndexDiag.Reason.gateOff rather than left to be discovered.
            diag(.contributeSkip, reason: closedGateReason, counts: [(.candidates, descriptors.count)])
            return
        }
        guard SourceIndexContract.canonicalContentID(contentID) == contentID else {
            diag(.contributeSkip, reason: .nonCanonicalContentID,
                 counts: [(.contentLen, SourceIndexDiag.identityLength(contentID))])
            return
        }
        // Revalidate at the network boundary. Descriptor is intentionally a simple value type, so a caller
        // can construct one without going through descriptors(from:); no such value reaches the encoder unless
        // it is torrent-only and carries an exact normalizable 40-hex infohash.
        let uploadable = uploadableDescriptors(descriptors)
        guard !uploadable.isEmpty else {
            diag(.contributeSkip, reason: .nothingUploadable, counts: [(.candidates, descriptors.count)])
            return
        }
        diag(.contributeBegin, counts: [(.candidates, descriptors.count), (.uploadable, uploadable.count)])
        // Read every remote-tunable pacing value ONCE, up front. A config swap partway through this loop would
        // otherwise slice with one batch size and re-validate the encoder against another (dropping the batch),
        // or pace prepareLaunch and finishAttempt on two different intervals for the same POST.
        let perTitleCap = maxDescriptorsPerTitle
        let chunkSize = batchSize
        let intervalNanoseconds = interBatchDelayMs * 1_000_000
        let timeout = requestTimeout
        // Bound the whole title: a pathological title still never sends an unbounded number of batches.
        let all = Array(uploadable.prefix(perTitleCap))
        // batchSize MUST stay <= the worker's MAX_SOURCES_PER_CONTRIBUTE or the whole batch is rejected.
        // Slice into <= batchSize chunks.
        let batches = uploadBatches(all, batchSize: chunkSize, perTitleCap: perTitleCap)

        // EVERY exit below now names itself. They were silent, which is the same defect the reasons above
        // were added to cure one level up: a contribute that stopped after two of five batches, or whose POST
        // was rejected, left a trace identical to one that completed, so "the pool is not filling" had no
        // answer in the log.
        for (i, candidates) in batches.enumerated() {
            guard !Task.isCancelled else {
                diag(.contributeStop, reason: .cancelled, counts: [(.batch, i + 1), (.batches, batches.count)])
                return
            }
            guard let reservation = await SourceUploadCoordinator.shared.reserve(
                contentID: contentID,
                descriptors: candidates
            ) else {
                // Not a failure: every descriptor in this batch is already claimed by this process. Named
                // anyway, so a whole title contributing nothing on a re-open is legible as dedupe, not loss.
                diag(.contributeSkip, reason: .alreadyClaimed,
                     counts: [(.batch, i + 1), (.batches, batches.count), (.descriptors, candidates.count)])
                continue
            }
            guard let data = contributionBody(contentID: contentID,
                                              descriptors: reservation.descriptors,
                                              batchSize: chunkSize) else {
                await SourceUploadCoordinator.shared.release(reservation)
                diag(.contributeSkip, reason: .bodyEncodingFailed,
                     counts: [(.batch, i + 1), (.batches, batches.count)])
                continue
            }

            var committed: [Descriptor]?
            while committed == nil {
                guard !Task.isCancelled else {
                    await SourceUploadCoordinator.shared.release(reservation)
                    diag(.contributeStop, reason: .cancelled,
                         counts: [(.batch, i + 1), (.batches, batches.count)])
                    return
                }
                switch await SourceUploadCoordinator.shared.prepareLaunch(
                    reservation,
                    nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    intervalNanoseconds: intervalNanoseconds,
                    gate: { SourceIndexClient.isEnabled }
                ) {
                case let .wait(delayNanoseconds):
                    do { try await Task<Never, Never>.sleep(nanoseconds: delayNanoseconds) }
                    catch {
                        await SourceUploadCoordinator.shared.release(reservation)
                        diag(.contributeStop, reason: .cancelled,
                             counts: [(.batch, i + 1), (.batches, batches.count)])
                        return
                    }
                case let .launch(descriptors):
                    committed = descriptors
                case .unavailable:
                    // The live gate closed while this batch waited for its pacing slot, or the reservation is
                    // already gone. Distinct from the pre-loop gate check: this one happened MID-TITLE.
                    diag(.contributeStop, reason: closedGateReason,
                         counts: [(.batch, i + 1), (.batches, batches.count)])
                    return
                }
            }

            var req = URLRequest(url: baseURL.appendingPathComponent("sources").appendingPathComponent("contribute"),
                                 timeoutInterval: timeout)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = data
            VortXEdgeAuth.sign(&req)   // gated host: stamp X-VX-Ts / X-VX-Sig / X-VX-Kid
            let request = req
            let chunk = committed ?? []
            guard !chunk.isEmpty else { continue }
            diag(.contributePost, counts: [(.batch, i + 1), (.batches, batches.count),
                                           (.descriptors, chunk.count)])
            // Detached from caller cancellation after commit: once the at-most-once claim is held, exactly one
            // network attempt is launched. The response is ignored and never buffered.
            let succeeded = await runCancellationIndependentAttempt {
                try await sourceIndexTransport.discardResponse(for: request)
            }
            // The POST OUTCOME. Without this a failed POST and a successful POST left byte-identical traces,
            // so an endpoint rejecting every contribution read exactly like a healthy one.
            diag(.contributePostResult, counts: [(.batch, i + 1), (.batches, batches.count),
                                                 (.succeeded, succeeded ? 1 : 0)])
            guard await SourceUploadCoordinator.shared.finishAttempt(
                succeeded: succeeded,
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                intervalNanoseconds: intervalNanoseconds
            ) else {
                diag(.contributeStop, reason: .postFailed,
                     counts: [(.batch, i + 1), (.batches, batches.count)])
                return
            }
        }
    }

    /// Revalidate and normalize arbitrary descriptor values immediately before upload, deduped by canonical
    /// infohash. This is the final confidentiality boundary used by both the POST path and deterministic tests.
    static func uploadableDescriptors(_ descriptors: [Descriptor]) -> [Descriptor] {
        var seen: Set<String> = []
        return descriptors.compactMap { descriptor in
            guard descriptor.kind == Kind.torrent.rawValue,
                  let hash = SourceIndexContract.normalizeInfoHash(descriptor.id),
                  seen.insert(hash).inserted else { return nil }
            return Descriptor(
                kind: Kind.torrent.rawValue,
                id: hash,
                quality: SourceIndexContract.normalizeQuality(descriptor.quality),
                sizeBytes: min(max(0, descriptor.sizeBytes), SourceIndexContract.maxSafeSizeBytes),
                seeders: descriptor.seeders.flatMap {
                    (0...SourceIndexContract.maxSeeders).contains($0) ? $0 : nil
                }
            )
        }
    }

    /// The actual POST encoder. It applies the same final boundary itself so a future caller cannot bypass
    /// filtering by invoking the encoder directly.
    static func contributionBody(contentID: String, descriptors: [Descriptor]) -> Data? {
        contributionBody(contentID: contentID, descriptors: descriptors, batchSize: batchSize)
    }

    /// The encoder against an EXPLICIT batch size, so one POST is sliced and re-validated against the same
    /// number even if a RemoteConfig swap lands between those two steps.
    static func contributionBody(contentID: String, descriptors: [Descriptor], batchSize: Int) -> Data? {
        guard SourceIndexContract.canonicalContentID(contentID) == contentID,
              !descriptors.isEmpty,
              descriptors.count <= batchSize else { return nil }
        let sources = uploadableDescriptors(descriptors)
        guard !sources.isEmpty else { return nil }
        return try? JSONEncoder().encode(ContributionBody(content_id: contentID, sources: sources))
    }

    /// Final upload normalization followed by worker-sized chunks. Exposed to the standalone contract harness.
    static func uploadBatches(_ descriptors: [Descriptor]) -> [[Descriptor]] {
        uploadBatches(descriptors, batchSize: batchSize, perTitleCap: maxDescriptorsPerTitle)
    }

    /// Chunking against EXPLICIT bounds, for the same reason the encoder takes one: the whole title must be
    /// sliced with a single consistent pair of values.
    static func uploadBatches(_ descriptors: [Descriptor], batchSize: Int, perTitleCap: Int) -> [[Descriptor]] {
        let step = max(1, batchSize)
        let all = Array(uploadableDescriptors(descriptors).prefix(max(1, perTitleCap)))
        return stride(from: 0, to: all.count, by: step).map {
            Array(all[$0 ..< min($0 + step, all.count)])
        }
    }

    /// Convenience: extract descriptors from `groups` and contribute them for `contentID`. The HOARD entry the
    /// detail screens call.
    static func hoard(contentID: String, groups: [CoreStreamSourceGroup]) async {
        guard isEnabled else { return }
        let descriptors = descriptors(from: groups)
        await contribute(contentID: contentID, descriptors: descriptors)
    }

    /// HOARD the SINGLE source a Continue-Watching / card resume actually plays. The resume path re-resolves one
    /// stored source and plays it WITHOUT assembling the title's full stream groups, so the detail-view `hoard`
    /// never runs for a card resume and those (very common) playbacks never seeded the pool at all. This seeds
    /// exactly that one source from the resume's already-stored fields: no new stream-resolve, no network fan-out,
    /// no hot-path work. Gated identically (contribute re-checks `isEnabled` = consent + fleet flag). Deduped per
    /// content id per process by the shared descriptor ledger, so re-resuming the same title does not re-POST.
    ///
    /// Only TORRENT sources carry a shareable, corroboratable public id (the infohash). A non-torrent resume
    /// (plain direct link) has no poolable id here and is a clean no-op, matching the detail-view descriptor
    /// rules which never send the raw resolved url.
    static func hoardResumedSource(contentID: String, infoHash: String?, quality: String?,
                                   sizeBytes: Int64, sourceTag: String, seeders: Int?) async {
        guard isEnabled else { return }
        guard let hash = SourceIndexContract.normalizeInfoHash(infoHash) else { return }
        _ = sourceTag // Kept for call-site compatibility; provider metadata never crosses the v1 boundary.
        let d = Descriptor(kind: Kind.torrent.rawValue, id: hash,
                           quality: (quality?.isEmpty == false) ? quality! : "Other",
                           sizeBytes: max(0, sizeBytes),
                           seeders: (seeders ?? -1) >= 0 ? seeders : nil)
        await contribute(contentID: contentID, descriptors: [d])
    }

    /// HOARD the FULL assembled source groups a Continue-Watching / card resume produces, once the resume path's
    /// background `loadMeta` has populated them. A card resume plays one stored source WITHOUT opening the detail
    /// view, so the detail-view `hoard` never fires for it; the older `hoardResumedSource` seeded only the
    /// resumed torrent's single infohash. This bridges the gap: the resume already kicks `loadMeta` (for the auto-hop
    /// safety net), which asynchronously fills `streamGroups(forStreamId:)`; we poll for that becoming non-empty
    /// under a short bounded cap, then fire the same full-group `hoard` the detail view uses. Descriptor extraction
    /// still admits only exact torrent infohashes.
    ///
    /// 100% fail-soft + off the hot path: bounded poll (`maxWaitMs`), a hung/empty meta simply times out to a
    /// no-op, and the eventual `hoard` is itself consent + fleet-flag gated. Deduped per exact (content,hash)
    /// by the shared coordinator so torrents arriving in later resume waves remain eligible. `resolveGroups` is called
    /// on the main actor (it reads `CoreBridge`'s published state); nothing here blocks the resume/playback.
    /// The two poll bounds default to the resolved RemoteConfig values (baked 5000 / 250, identical to the
    /// literals they replace) because the production call sites pass neither: a cold-network resume whose meta
    /// settles late is the case this budget exists for, and it has no other backend lever.
    static func hoardResumedGroups(contentID: String,
                                   maxWaitMs: Int = RemoteConfig.snapshot.sourceIndexResumeHoardMaxWaitMs,
                                   pollIntervalMs: Int = RemoteConfig.snapshot.sourceIndexResumeHoardPollIntervalMs,
                                   resolveGroups: @MainActor @Sendable @escaping () -> [CoreStreamSourceGroup]) async {
        guard isEnabled else { return }
        let candidateDescriptors = await resumedDescriptors(
            maxWaitMs: maxWaitMs,
            pollIntervalMs: pollIntervalMs,
            resolveGroups: resolveGroups
        )
        guard !candidateDescriptors.isEmpty else { return }
        await contribute(contentID: contentID, descriptors: candidateDescriptors)
    }

    /// Descriptor-first resume polling, split from the network submission so the late-arrival decision surface
    /// is deterministic in a standalone test. Direct-only groups yield no candidates and polling continues.
    @MainActor
    static func resumedDescriptors(
        maxWaitMs: Int,
        pollIntervalMs: Int,
        resolveGroups: @MainActor @Sendable @escaping () -> [CoreStreamSourceGroup]
    ) async -> [Descriptor] {
        // The attempt count is DERIVED from two independently clamped values, so it gets its own ceiling: each
        // attempt resolves groups on the MainActor during playback start, and a wide wait over a short interval
        // would otherwise multiply into far more of that than either value alone looks like it buys. The baked
        // pair derives 20 attempts, well under the cap, so this changes nothing today.
        // The CAP, not the resolved count: this function is handed caller-supplied wait/interval values, which
        // need not be the resolved pair, so the ceiling has to be applied here rather than trusted from a
        // precomputed number. (Those were one field and disagreed between `.baked` and `validate({})`.)
        let deadline = min(RemoteConfig.snapshot.sourceIndexResumeHoardAttemptCap,
                           max(1, maxWaitMs / max(1, pollIntervalMs)))
        return await SourceIndexContract.firstNonEmpty(
            attempts: deadline,
            pollIntervalNanoseconds: UInt64(max(1, pollIntervalMs)) * 1_000_000
        ) {
            let groups = resolveGroups()
            return descriptors(from: groups)
        }
    }

    // MARK: - SERVE: GET /sources?content_id=… (signed, opt-in + login-gated)

    /// Read the corroborated pooled sources for `contentID`. Returns `[]` unless the Singularity SERVE toggle is
    /// on AND the user is signed in AND consent is granted AND the fleet flag is on. Fail-soft to `[]` on any
    /// error, on the worker's `login_required` empty read, or when disabled.
    static func fetchPooled(contentID: String, isSignedIn: Bool) async -> [PooledSource] {
        let lifecycle = SourceIndexLifecycleClock.snapshot()
        let liveGate: @Sendable () async -> Bool = {
            guard SourceIndexLifecycleClock.snapshot() == lifecycle,
                  SourceIndexClient.isEnabled,
                  SourceIndexClient.serveEnabled else { return false }
            return await MainActor.run { VortXSyncManager.shared.isSignedIn }
        }
        return await fetchPooledUsing(
            contentID: contentID,
            isSignedIn: isSignedIn,
            gate: liveGate,
            moatProvider: {
                let liveSignedIn = await MainActor.run { VortXSyncManager.shared.isSignedIn }
                return await MoatToken.shared.current(isSignedIn: liveSignedIn)
            },
            transport: { request in try await sourceIndexTransport.boundedGetResponse(for: request) }
        )
    }

    /// The live GET decision boundary with injectable gate/token/transport seams. The gate is checked before
    /// token work, immediately after token mint/cache lookup, and again immediately before transport. A current
    /// nonempty moat token is mandatory, matching the worker's binding read gate.
    static func fetchPooledUsing(
        contentID: String,
        isSignedIn: Bool,
        gate: @escaping @Sendable () async -> Bool,
        moatProvider: @escaping @Sendable () async -> String?,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> [PooledSource] {
        // Validate before logging or constructing a request. A caller-controlled or user-shaped value must not
        // enter telemetry or a query string even if a future call site bypasses contentID(...).
        guard let url = serveURL(contentID: contentID) else {
            diag(.fetchPooledSkip, reason: .malformedServeURL,
                 counts: [(.contentLen, SourceIndexDiag.identityLength(contentID))])
            return []
        }
        // SERVE opt-in gate: toggle on/off + signed-in state + master enable, with the decision logged. Sign-in
        // IS required (owner decision 2026-07-04: keep Singularity results a VortX-user-only benefit; the worker
        // enforces the same login gate and serves an empty list to a tokenless caller). Contribute stays open.
        let initiallyOpen = await gate()
        // Neither the content id nor the sign-in state is loggable: one is viewing history, the other is
        // account state. The open/closed decision is carried by which of the two lines below is emitted.
        diag(.fetchPooledGate)
        guard initiallyOpen else {
            diag(.fetchPooledGateClosed, reason: .gateClosed)
            return []
        }

        var req = URLRequest(url: url, timeoutInterval: requestTimeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)
        let signed = req.value(forHTTPHeaderField: "X-VX-Sig") != nil
        // Moat token: the SERVE gate is login-only AND moat-token-gated. Stamp X-VX-Moat after the edge
        // signature. Fail-soft: no current token returns empty before transport.
        let currentMoat = await moatProvider()
        guard await gate(), let currentMoat, !currentMoat.isEmpty else {
            diag(.fetchPooledGateClosed, reason: .gateChangedOrNoMoat)
            return []
        }
        req.setValue(currentMoat, forHTTPHeaderField: MoatToken.header)
        // The URL is NOT logged: its query string is the content id. Only whether the request got stamped.
        diag(.fetchPooledGet, counts: [(.edgeSigned, signed ? 1 : 0), (.moatToken, 1)])

        do {
            // Both mid-flight gate checks were SILENT returns. F4 requires every bail path to stay
            // distinguishable, and these two are not the same event: one means the gate shut before we spent a
            // request, the other means it shut while the response was already in the air.
            guard await gate() else {
                diag(.fetchPooledGateClosed, reason: .gateClosedBeforeTransport)
                return []
            }
            let (data, resp) = try await transport(req)
            guard await gate() else {
                diag(.fetchPooledGateClosed, reason: .gateClosedAfterTransport)
                return []
            }
            guard let http = resp as? HTTPURLResponse, isSuccessfulHTTPStatus(http.statusCode) else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                diag(.fetchPooledHTTP, reason: .httpNon2xx, counts: [(.status, status)])
                return []
            }
            let decoded = try? JSONDecoder().decode(SourcesResponse.self, from: data)
            let sources = Array((decoded?.sources ?? []).prefix(SourceIndexContract.maxServedSources))
            // The worker `reason` is server-authored text and is still never echoed. It is MAPPED, through a
            // closed client-side enum, onto one of a fixed handful of outcomes.
            //
            // Dropping it outright was a regression, and the reason given for dropping it ("the row count
            // already distinguishes an empty login_required read from a real empty pool") is false: both
            // bodies decode to zero rows, so both emitted this line byte for byte. SERVE is deliberately
            // login-gated, so login_required is the most common correct explanation for an empty pool.
            diag(.fetchPooledHTTPOK,
                 outcome: SourceIndexDiag.Outcome(worker: decoded?.reason),
                 counts: [(.status, http.statusCode), (.corroboratedSources, sources.count)])
            return sources
        } catch {
            // `localizedDescription` embeds the failing URL (hence the content id) on URLError, so only the
            // transport error CODE crosses into the log.
            diag(.fetchPooledHTTP, reason: .httpError,
                 counts: [(.code, (error as? URLError)?.errorCode ?? 0)])
            return []
        }
    }

    /// Turn canonical pooled torrent infohashes into playable `CoreStream`s. Every non-torrent or malformed row
    /// is dropped before it can enter the user's existing debrid pipeline. Fail-soft.
    static func streams(from pooled: [PooledSource]) -> [CoreStream] {
        let built: [CoreStream] = pooled.prefix(SourceIndexContract.maxServedSources).compactMap { src -> CoreStream? in
            guard let kind = src.kind, let id = src.id, !id.isEmpty else { return nil }
            // Name/desc both say "Singularity" so the source ROW is visibly a Singularity source (the group
            // label is discarded by the quality re-grouping, but this per-stream text survives and renders).
            // MIRROR the worker's serve floor; never exceed it. The worker already applied it before sending
            // (serveFloorForKind() = 1 for torrents, "a torrent infohash is SELF-VERIFYING, so a lone early
            // contributor is never stranded"; general floor env-tunable via CORROBORATION_MIN). This client
            // check previously sat at 2 and discarded exactly the single-witness rows the worker deliberately
            // served -- in a young pool nearly all of them. It is retained at the worker's own value purely as
            // defence against a malformed/absent count, so real policy stays backend-tunable with no app release.
            guard kind == Kind.torrent.rawValue,
                  (src.corroboration ?? 0) >= SourceIndexContract.minimumServedCorroboration,
                  let hash = SourceIndexContract.canonicalStoredInfoHash(id) else { return nil }
            return make(name: "Other · Singularity", description: "Singularity source", infoHash: hash)
        }
        diag(.streamsReconstruct, counts: [(.pooled, pooled.count), (.playable, built.count)])
        return built
    }

    /// Deterministic decode boundary used by the live GET path's contract tests. Invalid JSON is empty and a
    /// valid response cannot admit more rows than the worker's maximum even before reconstruction filters it.
    static func pooledSources(fromResponseData data: Data) -> [PooledSource] {
        guard let decoded = try? JSONDecoder().decode(SourcesResponse.self, from: data) else { return [] }
        return Array((decoded.sources ?? []).prefix(SourceIndexContract.maxServedSources))
    }

    static func pooledSources(statusCode: Int, fromResponseData data: Data) -> [PooledSource] {
        guard isSuccessfulHTTPStatus(statusCode) else { return [] }
        return pooledSources(fromResponseData: data)
    }

    static func isSuccessfulHTTPStatus(_ statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }

    // MARK: - Feature gates

    /// The master gate for the whole client: consent (give-to-get) AND the fleet feature flag. When off, HOARD
    /// and SERVE are both hard no-ops that never touch the network.
    static var isEnabled: Bool {
        MoatConsent.contributeAndConsume && fleetEnabled
    }

    /// The RemoteConfig fleet kill switch on its own. Split out of `isEnabled` so a closed gate can name WHICH
    /// half is shut without a call site having to recompute either half.
    static var fleetEnabled: Bool {
        RemoteConfig.snapshot.isFeatureOn("sourceIndex", default: RemoteConfigDefaults.featureSourceIndex)
    }

    /// Which reason a closed master gate reports. The fleet flag is server-side config and is named outright;
    /// otherwise the user-level gate is what is shut and the neutral spelling is used (the consequence of the
    /// split is documented on `SourceIndexDiag.Reason.gateOff`).
    static var closedGateReason: SourceIndexDiag.Reason {
        fleetEnabled ? .gateOff : .fleetOff
    }

    /// The per-user SERVE opt-in (the "Singularity" Settings toggle). Default ON, absent key reads as true
    /// (give-to-get; still sign-in gated in fetchPooled), mirroring MoatConsent.contributeAndConsume.
    static let serveKey = "vortx.singularity.serve"
    static var serveEnabled: Bool {
        if UserDefaults.standard.object(forKey: serveKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: serveKey)
    }

    // MARK: - Singularity source-group identity (shared by the iOS + tvOS source lists)

    /// The stable group id `merged(into:)` stamps on Singularity's merged source group, so the source lists
    /// can find it without a magic string.
    static let groupID = "vortx.singularity.sources"
    /// The user-facing label on Singularity's source group + rows. Kept as one constant so the row labels
    /// and the merge all read identically.
    ///
    /// NOTE (owner decision): Singularity renders INLINE ONLY, as this one merged group flowing through
    /// the ranked list like any add-on, sortable with the user's sort. The old pinned top-of-list section
    /// (`pinnedStreams` / `pinnedSectionMax`) duplicated the same sources unsortably above the list and
    /// was removed on both platforms.
    static let groupAddon = "Singularity"

    // MARK: - Helpers

    /// The overall per-title cap on descriptors uploaded. Far above real fan-out (a title with more unique
    /// sources than this drops the tail, which is acceptable). At `batchSize` per POST this is at most 125 POSTs.
    /// RemoteConfig can only lower it (clamp 16...2000, baked 2000), so the fleet can shed the tail on a
    /// pathological title without a build but can never buy itself more background POSTs.
    private static var maxDescriptorsPerTitle: Int { RemoteConfig.snapshot.sourceIndexMaxDescriptorsPerTitle }
    /// Descriptors per POST. Sixteen sources produce 49 D1 statements (3 each plus one retention prune), under
    /// Cloudflare D1's 50-query Free-plan invocation limit. Keep this equal to the worker maximum: the clamp
    /// (1...16, baked 16) pins the ceiling there because a larger POST is rejected whole.
    static var batchSize: Int { RemoteConfig.snapshot.sourceIndexBatchSize }
    /// Delay between sequential batch POST starts. Just over one second keeps each process near 55/minute,
    /// leaving headroom within the worker's 240/minute per-IP limit for several devices behind one NAT.
    /// RemoteConfig can only lengthen it (clamp 1100...30000, baked 1100), never crowd the worker faster.
    private static var interBatchDelayMs: UInt64 { UInt64(RemoteConfig.snapshot.sourceIndexInterBatchDelayMs) }
    /// Per-request budget for both the contribute POST and the serve GET. Shorten-only from remote
    /// (clamp 3...8, baked 8) so a slow worker fails fast instead of stacking attempts against itself.
    private static var requestTimeout: TimeInterval { RemoteConfig.snapshot.sourceIndexRequestTimeout }

    /// Source Index has one confidentiality origin. A RemoteConfig value is accepted only when it is an exact
    /// spelling of that HTTPS root; every scheme, host-case, userinfo, port, path, query, or fragment variation
    /// falls back to the baked root before signing or request construction.
    static let bakedBaseURL = URL(string: "https://sources.vortx.tv")!
    static func normalizedBaseURL(override candidate: URL?) -> URL {
        guard let candidate else { return bakedBaseURL }
        let raw = candidate.absoluteString
        guard raw == bakedBaseURL.absoluteString || raw == bakedBaseURL.absoluteString + "/" else {
            return bakedBaseURL
        }
        return bakedBaseURL
    }

    private static var baseURL: URL {
        normalizedBaseURL(override: RemoteConfig.snapshot.endpoint("sources"))
    }

    /// One dedicated no-redirect session is shared by both signed GET and POST paths.
    private static let sourceIndexTransport = SourceIndexHTTPTransport.shared

    /// Pure SERVE request builder shared with standalone tests. Invalid title keys return nil before telemetry
    /// or network work, and the torrent-only kind is always explicit.
    static func serveURL(contentID: String) -> URL? {
        guard SourceIndexContract.canonicalContentID(contentID) == contentID,
              var components = URLComponents(
                url: baseURL.appendingPathComponent("sources"),
                resolvingAgainstBaseURL: false
              ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "content_id", value: contentID),
            URLQueryItem(name: "kind", value: Kind.torrent.rawValue),
        ]
        return components.url
    }

    /// Launch one detached attempt even when the contributing parent task is canceled after commit. There is
    /// no retry here; the Boolean only tells the current batch loop whether it must stop and extend its pacer.
    static func runCancellationIndependentAttempt(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        let attempt = Task.detached { try await operation() }
        do {
            try await attempt.value
            return true
        } catch {
            return false
        }
    }

    /// Build a `CoreStream` via JSON decode (the all-optional field set has no memberwise init), mirroring
    /// `TorBoxSearch.make`.
    private static func make(name: String, description: String, infoHash: String) -> CoreStream? {
        decodeStream(["name": name, "description": description, "infoHash": infoHash])
    }
    private static func decodeStream(_ json: [String: Any]) -> CoreStream? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(CoreStream.self, from: data)
    }

    // MARK: - Decodable wire shape

    private struct SourcesResponse: Decodable {
        let sources: [PooledSource]?
        let reason: String?
    }
}

// MARK: - Source Index HTTP transport

enum SourceIndexTransportError: Error, Equatable {
    case invalidLength
    case tooLarge
    case badStatus(Int)
}

/// Redirects are never followed, including same-origin redirects. Signed Source Index requests are valid only
/// for their original method, path, and body; forwarding them would move authorization headers to a request the
/// client did not sign. Returning nil makes URLSession surface the original 30x response to the caller.
final class SourceIndexNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let redirectObserver: @Sendable (Int) -> Void

    init(redirectObserver: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.redirectObserver = redirectObserver
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectObserver(response.statusCode)
        completionHandler(nil)
    }
}

/// One bounded, no-redirect URLSession transport used for both Source Index reads and contributions. The
/// injectable configuration is for the standalone real-URLSession redirect harness.
final class SourceIndexHTTPTransport: @unchecked Sendable {
    static let shared = SourceIndexHTTPTransport()

    let session: URLSession

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        redirectObserver: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(
            configuration: configuration,
            delegate: SourceIndexNoRedirectDelegate(redirectObserver: redirectObserver),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Stream actual response bytes into a hard 64 KiB cap. Content-Length is a rejection hint only; an absent
    /// or dishonest header cannot bypass the incremental cap. Cap-plus-one explicitly cancels the task.
    func boundedGetResponse(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let declaredLength = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length")
        guard var accumulator = SourceIndexContract.BoundedBodyAccumulator(contentLength: declaredLength) else {
            bytes.task.cancel()
            throw SourceIndexTransportError.invalidLength
        }
        return try await withTaskCancellationHandler {
            for try await byte in bytes {
                guard accumulator.append(byte) else {
                    bytes.task.cancel()
                    throw SourceIndexTransportError.tooLarge
                }
            }
            return (accumulator.data, response)
        } onCancel: {
            bytes.task.cancel()
        }
    }

    /// Contribution responses are semantically ignored. Drain at most a fixed 512-byte sink, buffer nothing,
    /// and cancel the task after headers plus that minimal drain so an untrusted body cannot consume memory.
    func discardResponse(for request: URLRequest) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw SourceIndexTransportError.badStatus(-1)
        }
        guard SourceIndexClient.isSuccessfulHTTPStatus(http.statusCode) else {
            throw SourceIndexTransportError.badStatus(http.statusCode)
        }
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length")
        if let declaredLength {
            guard let parsed = SourceIndexContract.parsedContentLength(declaredLength),
                  parsed < SourceIndexContract.postResponseDrainBytes else {
                throw SourceIndexTransportError.invalidLength
            }
        }
        var iterator = bytes.makeAsyncIterator()
        for _ in 0..<SourceIndexContract.postResponseDrainBytes {
            guard try await iterator.next() != nil else { return }
        }
        throw SourceIndexTransportError.tooLarge
    }
}

// MARK: - Process-wide HOARD coordination

/// One process-wide actor shared by detail and resume call sites. It atomically reserves descriptor claims, then
/// makes every pending caller re-enter immediately before launch to claim the current global pacing slot.
/// Cancellation before launch releases pending claims; launch commits claims for the process lifetime even when
/// delivery fails. Once bounded capacity is full, new claims stop instead of evicting old claims.
actor SourceUploadCoordinator {
    static let shared = SourceUploadCoordinator()

    private let maxEntries: Int
    private var seen: Set<String> = []
    private var pending: Set<String> = []
    private var reservations: [UInt64: (keys: [String], descriptors: [SourceIndexClient.Descriptor])] = [:]
    private var nextReservationID: UInt64 = 1
    private var nextPostNanoseconds: UInt64?

    init(maxEntries: Int = 40_000) {
        self.maxEntries = maxEntries
    }

    struct Reservation: Sendable {
        let id: UInt64
        let descriptors: [SourceIndexClient.Descriptor]
    }

    enum LaunchDecision: Sendable {
        case wait(UInt64)
        case launch([SourceIndexClient.Descriptor])
        case unavailable
    }

    func reserve(
        contentID: String,
        descriptors: [SourceIndexClient.Descriptor]
    ) -> Reservation? {
        guard maxEntries > 0,
              nextReservationID < UInt64.max,
              SourceIndexContract.canonicalContentID(contentID) == contentID else { return nil }
        var fresh: [SourceIndexClient.Descriptor] = []
        var keys: [String] = []
        var local = Set<String>()
        for descriptor in descriptors {
            guard descriptor.kind == SourceIndexClient.Kind.torrent.rawValue,
                  SourceIndexContract.canonicalStoredInfoHash(descriptor.id) == descriptor.id else { continue }
            let key = contentID + "|" + descriptor.kind + "|" + descriptor.id
            guard !seen.contains(key), !pending.contains(key), local.insert(key).inserted else { continue }
            guard seen.count + pending.count + keys.count < maxEntries else { break }
            keys.append(key)
            fresh.append(descriptor)
        }
        guard !fresh.isEmpty else { return nil }

        let id = nextReservationID
        nextReservationID += 1
        pending.formUnion(keys)
        reservations[id] = (keys, fresh)
        return Reservation(id: id, descriptors: fresh)
    }

    func release(_ reservation: Reservation) {
        guard let stored = reservations.removeValue(forKey: reservation.id) else { return }
        pending.subtract(stored.keys)
    }

    /// Recheck the current global not-before boundary at actual wake time. A delayed sleeper cannot reuse an
    /// expired precomputed slot: the first ready caller atomically claims now, and every other caller gets a
    /// fresh delay. A failure can move the boundary while callers sleep, and they must honor it on re-entry.
    func prepareLaunch(
        _ reservation: Reservation,
        nowNanoseconds: UInt64,
        intervalNanoseconds: UInt64,
        gate: @Sendable () -> Bool = { true }
    ) -> LaunchDecision {
        guard gate() else {
            release(reservation)
            return .unavailable
        }
        guard let stored = reservations[reservation.id] else { return .unavailable }
        let notBefore = nextPostNanoseconds ?? nowNanoseconds
        if nowNanoseconds < notBefore { return .wait(notBefore - nowNanoseconds) }

        reservations.removeValue(forKey: reservation.id)
        pending.subtract(stored.keys)
        seen.formUnion(stored.keys)
        let (next, overflow) = nowNanoseconds.addingReportingOverflow(intervalNanoseconds)
        nextPostNanoseconds = overflow ? UInt64.max : next
        return .launch(stored.descriptors)
    }

    /// A failed committed POST is never retried. It only pushes the next fresh POST at least one normal pacing
    /// interval beyond the observed failure, preventing a broken endpoint from accelerating later batches.
    func finishAttempt(succeeded: Bool, nowNanoseconds: UInt64, intervalNanoseconds: UInt64) -> Bool {
        guard !succeeded else { return true }
        let (candidate, overflow) = nowNanoseconds.addingReportingOverflow(intervalNanoseconds)
        nextPostNanoseconds = max(nextPostNanoseconds ?? nowNanoseconds, overflow ? UInt64.max : candidate)
        return false
    }
}

// MARK: - Active SERVE request coalescing

/// Coalesces only requests that are currently in flight. Completed values and failures are removed before any
/// waiter resumes, so a recreated view always refetches and can never warm-paint a stale prior response.
actor SourceIndexFetchCoalescer {
    static let shared = SourceIndexFetchCoalescer()

    private struct Key: Hashable {
        let contentID: String
        let isSignedIn: Bool
        let sourceGeneration: UInt64
        let sessionGeneration: UInt64
    }

    private struct Entry {
        let id: UInt64
        var waiters: [CheckedContinuation<[SourceIndexClient.PooledSource], Never>]
        var task: Task<Void, Never>?
    }

    private var entries: [Key: Entry] = [:]
    private var nextID: UInt64 = 1

    func fetch(
        contentID: String,
        isSignedIn: Bool,
        lifecycle: SourceIndexLifecycleSnapshot = SourceIndexLifecycleClock.snapshot(),
        operation: @escaping @Sendable () async throws -> [SourceIndexClient.PooledSource]
    ) async -> [SourceIndexClient.PooledSource] {
        let key = Key(
            contentID: contentID,
            isSignedIn: isSignedIn,
            sourceGeneration: lifecycle.sourceGeneration,
            sessionGeneration: lifecycle.sessionGeneration
        )
        return await withCheckedContinuation { continuation in
            if var entry = entries[key] {
                entry.waiters.append(continuation)
                entries[key] = entry
                return
            }

            let id = nextID
            nextID &+= 1
            entries[key] = Entry(id: id, waiters: [continuation], task: nil)
            let task = Task {
                let result: [SourceIndexClient.PooledSource]
                do {
                    result = try await operation()
                } catch {
                    result = []
                }
                finish(key: key, id: id, result: result)
            }
            entries[key]?.task = task
        }
    }

    private func finish(key: Key, id: UInt64, result: [SourceIndexClient.PooledSource]) {
        guard let entry = entries[key], entry.id == id else { return }
        entries.removeValue(forKey: key)
        for waiter in entry.waiters { waiter.resume(returning: result) }
    }

    /// Cancel only retired generations. A delayed gate-close task cannot cancel a fresh request that started
    /// after the gate reopened because its key carries the newer source generation.
    func cancel(upToSourceGeneration retiredGeneration: UInt64) {
        let keys = entries.keys.filter { $0.sourceGeneration <= retiredGeneration }
        let canceled = keys.compactMap { entries.removeValue(forKey: $0) }
        for entry in canceled {
            entry.task?.cancel()
            for waiter in entry.waiters { waiter.resume(returning: []) }
        }
    }

    /// Test/support escape hatch for tearing down the complete actor. Production lifecycle invalidation uses
    /// the generation-bounded variant above.
    func cancelAll() {
        let canceled = Array(entries.values)
        entries.removeAll(keepingCapacity: true)
        for entry in canceled {
            entry.task?.cancel()
            for waiter in entry.waiters { waiter.resume(returning: []) }
        }
    }

    func activeCount() -> Int { entries.count }
}

// MARK: - Per-view SERVE contributor

/// A per-detail-view `@StateObject` that reads the community source index for the current title and publishes
/// the corroborated, actionable sources as one extra group to MERGE into the list -- the SERVE half. Mirrors
/// `TorBoxSearchSource`'s shape exactly. Gated inside `SourceIndexClient` (toggle OFF / signed-out / no consent
/// / fleet-off all yield an empty group), so the source list is unchanged unless the user opted in.
@MainActor
final class SourceIndexServeSource: ObservableObject, SourceIndexLifecycleParticipant {
    /// The corroborated community streams, ready to merge. Empty until a fetch completes (and always when the
    /// SERVE toggle is off / signed out / consent withdrawn).
    @Published private(set) var streams: [CoreStream] = [] { didSet { epoch &+= 1 } }
    /// Monotonic epoch bumped whenever `streams` is REPLACED. `SourceListModel` folds this into its
    /// O(1) rebuild signature (a single Int compare instead of hashing the array).
    private(set) var epoch = 0

    private var lastContentID: String?
    /// Canonical identity for the rows currently owned by this source. The source-list assembler checks it
    /// before merging so a detached E2 snapshot cannot be reused for E3.
    var publishedContentID: String? { lastContentID }
    private var task: Task<Void, Never>?

    typealias FetchPooled = @Sendable (String, Bool) async throws -> [SourceIndexClient.PooledSource]
    typealias ServeGate = @Sendable () -> Bool
    typealias AccountGate = @MainActor @Sendable () -> Bool
    private let fetchPooled: FetchPooled
    private let serveGate: ServeGate
    private let accountGate: AccountGate
    private let coalescer: SourceIndexFetchCoalescer
    private var refreshGeneration: UInt64 = 0

    init(
        fetchPooled: @escaping FetchPooled = { contentID, isSignedIn in
            await SourceIndexClient.fetchPooled(contentID: contentID, isSignedIn: isSignedIn)
        },
        serveGate: @escaping ServeGate = {
            SourceIndexClient.serveEnabled && SourceIndexClient.isEnabled
        },
        accountGate: @escaping AccountGate = {
            VortXSyncManager.shared.isSignedIn
        },
        coalescer: SourceIndexFetchCoalescer = .shared
    ) {
        self.fetchPooled = fetchPooled
        self.serveGate = serveGate
        self.accountGate = accountGate
        self.coalescer = coalescer
        SourceIndexLifecycleScope.shared.register(self)
    }

    /// Fetch pooled sources for `contentID` when SERVE is enabled + the user is signed in (owner decision
    /// 2026-07-04: Singularity results are a VortX-user-only benefit). Fail-soft + deduped by content id. Safe
    /// to call on every meta change / `.task` / `.onAppear`.
    func refresh(contentID requestedContentID: String?, isSignedIn _: Bool) {
        guard serveGate(), accountGate() else {
            invalidateLocal(clearIdentity: true)
            return
        }
        let contentID = requestedContentID.flatMap { candidate in
            SourceIndexContract.canonicalContentID(candidate) == candidate ? candidate : nil
        }
        let identityChanged = contentID != lastContentID
        if identityChanged {
            invalidateLocal(clearIdentity: false)
            lastContentID = contentID
        }

        guard identityChanged, let contentID else { return }

        let lifecycle = SourceIndexLifecycleClock.snapshot()
        let generation = refreshGeneration
        let fetchPooled = self.fetchPooled
        let serveGate = self.serveGate
        let accountGate = self.accountGate
        let coalescer = self.coalescer
        task = Task { [weak self] in
            guard accountGate(), SourceIndexLifecycleClock.snapshot() == lifecycle else { return }
            let pooled = await coalescer.fetch(contentID: contentID, isSignedIn: true, lifecycle: lifecycle) {
                try await fetchPooled(contentID, true)
            }
            let built = SourceIndexClient.streams(from: pooled)
            guard !Task.isCancelled, let self,
                  self.refreshGeneration == generation,
                  self.lastContentID == contentID,
                  SourceIndexLifecycleClock.snapshot() == lifecycle,
                  serveGate(),
                  accountGate() else {
                SourceIndexClient.diag(.refreshPublishSkipped, reason: .staleOrCancelled,
                                       counts: [(.built, built.count)])
                return
            }
            SourceIndexClient.diag(.refreshPublish, counts: [(.streams, built.count)])
            self.streams = built
        }
    }

    /// Empty the published community streams and invalidate this owner's waiter. Ordinary title changes do not
    /// cancel shared coalescing; a replacement view may still join an active request for the same title.
    func clearResults() {
        invalidateLocal(clearIdentity: true)
    }

    func sourceIndexLifecycleDidClose(retiredSourceGeneration: UInt64) {
        invalidateLocal(clearIdentity: true)
    }

    /// SourceListModel's detached publish fence. Empty snapshots may rebuild ordinary sources while the gate is
    /// closed; a snapshot that contained Singularity rows must still match this source, lifecycle, and live gate.
    func permitsDetachedPublish(
        sourceEpoch: Int,
        lifecycle: SourceIndexLifecycleSnapshot,
        includedSingularity: Bool
    ) -> Bool {
        guard epoch == sourceEpoch, SourceIndexLifecycleClock.snapshot() == lifecycle else { return false }
        return !includedSingularity || (serveGate() && accountGate())
    }

    private func invalidateLocal(clearIdentity: Bool) {
        refreshGeneration &+= 1
        task?.cancel()
        task = nil
        if clearIdentity { lastContentID = nil }
        if !streams.isEmpty { streams = [] }
    }

    /// Merge the community sources into `groups` as its OWN named source group, exactly like any other add-on.
    /// Singularity's corroborated sources appear under the "Singularity" label whenever the pool has any for this
    /// title, EVEN when one of your own add-ons also returns the same release: add-ons are never deduped against
    /// one another, so Singularity is not either (that is what made it invisible on titles your add-ons already
    /// cover). We drop only internal duplicates within Singularity's own list, by infoHash. Empty pool (SERVE off
    /// / not signed in / fleet-off / nothing corroborated) is a pure pass-through, so the list is unchanged.
    func merged(into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        Self.merge(streams, into: groups)
    }

    /// The pure merge. `nonisolated static` so `SourceListModel`'s off-main assembly can run it over a
    /// snapshotted `streams` array without hopping to the main actor; the instance `merged(into:)`
    /// wraps it for the existing main-actor call sites.
    ///
    /// DELIBERATELY SILENT: the old per-call `[sing] merged` probe fired on every SwiftUI body eval
    /// (thousands of lines, ~150 ms apart, on a loading title) and was the log-flood symptom of the
    /// main-thread source-list storm. The `[sing] merged` health log now lives in
    /// `SourceListModel.rebuild`, once per coalesced rebuild, where its frequency is the metric.
    nonisolated static func merge(_ extra: [CoreStream], into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard !extra.isEmpty else { return groups }
        var seen: Set<String> = []
        var own: [CoreStream] = []
        for s in extra {
            // Torrent-only v1 keys each pooled source by its canonical 40-hex infohash.
            guard let hash = SourceIndexContract.canonicalStoredInfoHash(s.infoHash) else { continue }
            let key = "t:" + hash
            if seen.insert(key).inserted { own.append(s) }
        }
        // NOTE: `own` is deduped ONLY within Singularity's own list by torrent infohash. It is deliberately NOT
        // deduped against the user's add-on groups, so a
        // release your add-ons already return still appears under the Singularity label.
        guard !own.isEmpty else { return groups }
        return groups + [CoreStreamSourceGroup(id: SourceIndexClient.groupID, addon: SourceIndexClient.groupAddon, streams: own)]
    }
}
