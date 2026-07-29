import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
typealias ScrubImage = NSImage
#elseif canImport(UIKit)
typealias ScrubImage = UIImage
#endif

/// Provides scrub-preview thumbnails from locally captured frames.
/// When no server storyboard is available the player captures a frame every ~10 s of playback
/// and stores it via `recordCapturedFrameData`. During scrubbing `show(time:)` serves the
/// nearest stored frame so the user gets a preview even without a network trickplay service.
@MainActor
final class ScrubThumbnailsStore: ObservableObject {
    @Published private(set) var image: ScrubImage?

    private var localCacheKey: String?
    private static let localFrameCache = LocalTrickplayFrameCache()

    // MARK: Community trickplay (shared across users; 100% fail-soft -> local capture)

    /// The downloaded community sheet, when this title had one. While present, `show(time:)` serves a crop
    /// from it instead of the local cache, so a title brand-new to this device shows previews immediately.
    private var communitySheet: CommunityTrickplay.Sheet?
    /// True when the L1 community fetch returned a set (used to serve it while scrubbing).
    private var communityAlreadyExists = false
    /// Frame count of the community set the L1 fetch returned (0 = none). We only UPLOAD when our own capture
    /// is strictly fuller than this, so a thin community set gets improved (keep-fuller) while a full one is
    /// not needlessly re-POSTed. The worker also keep-fuller-merges as a race safety net.
    private var communityExistingFrameCount = 0
    /// The shareable identity for the current title, set by `configureCommunity`. nil for ad-hoc plays.
    private var communityKey: String?
    private var communityImdb: String?
    private var communitySeason: Int?
    private var communityEpisode: Int?
    private var communityDurationBucket = 0
    private var communitySrcHeight = 0
    /// True only once we have keyed on the REAL playback duration (mpv's `duration` event), not the
    /// provisional `meta.runtime` estimate. The key is allowed to form provisionally so capture starts at
    /// the first positive `timePos` (a debrid MKV may never deliver a `duration` event), but an UPLOAD is
    /// gated on this so a wrong provisional bucket can never write a poisoned community set.
    private var hasRealDuration = false
    /// Raw JPEG frames captured THIS session, time-ordered build input for the upload sprite-sheet.
    private var sessionFrames: [CommunityTrickplay.CapturedFrame] = []
    /// One exact-key upload owner. A session builds at most one progressive sheet after reaching the server's
    /// coverage floor. Teardown can retry a transient failure or replace a materially thinner stored set once.
    /// A deliberate decline and a stored teardown reply are terminal.
    private var uploadPolicy = TrickplayUploadPolicy()
    private var uploadTask: Task<Void, Never>?
    /// Teardown can arrive while the progressive task is still posting. Preserve
    /// the exact old-key frames and metadata rather than reading mutable current
    /// title state after that task completes.
    private struct UploadSnapshot {
        let claim: TrickplayUploadPolicy.Claim
        let imdb: String
        let season: Int?
        let episode: Int?
        let durationBucket: Int
        let srcHeight: Int
        let interval: Double
        let frames: [CommunityTrickplay.CapturedFrame]
    }
    private var deferredUploadSnapshots: [UInt64: UploadSnapshot] = [:]
    /// Low-rate playback telemetry reads this to correlate frame drops with a community-sheet build/upload.
    /// It exposes only activity, never task ownership or mutable policy state.
    var isCommunityUploadInFlight: Bool { uploadTask != nil }
    /// Capture cadence the local pipeline records at (~every 10s); also the sheet/vtt tile interval. Sourced
    /// from the RemoteConfig `trickplay.captureIntervalSecs` dial (clamped 2..60), so the owner can tune
    /// coverage density with no app update. Baked default 10 == the shipping value; a null/out-of-range remote
    /// value keeps 10. Read once at use; the value is stable for a playback session.
    private static var captureInterval: Double { Double(RemoteConfig.snapshot.captureIntervalSecs) }

    func configure(localCacheKey: String?) {
        guard TrickplayCaptureSessionPolicy.transition(
            from: self.localCacheKey,
            to: localCacheKey
        ) == .reset else { return }
        retireCommunityUploadIfNeeded()
        _ = communityIdentityGeneration.advance()
        self.localCacheKey = localCacheKey
        image = nil
        // A new stable media or episode timeline: drop the prior community sheet and session frames.
        communitySheet = nil
        communityAlreadyExists = false
        communityExistingFrameCount = 0
        communityKey = nil
        communityResolveTriedFor = nil
        hasRealDuration = false
        sessionFrames = []
    }

    /// Plumb the shareable identity + kick off the L1 community fetch. Call EARLY with a provisional duration
    /// derived from `meta.runtime` (so capture can begin at the first positive `timePos`, since a debrid MKV
    /// may never deliver mpv's `duration` event), then AGAIN with `isRealDuration: true` once the real mpv
    /// duration arrives. The provisional call keys + fetches but never uploads; the real call re-keys if the
    /// duration bucket changed and flips `hasRealDuration` so uploads can begin. Fully fail-soft.
    func configureCommunity(imdbId rawImdbId: String?, season: Int?, episode: Int?, duration: Double,
                            isRealDuration: Bool = true, enabled: Bool = CommunityTrickplay.isEnabled) {
        // TMDB-keyed play (our hub/TMDB catalogs key with `tmdb:…`, not `tt…`): resolve to the IMDb identity
        // so these plays contribute + fetch like any Cinemeta play. THE root cause of an account that never
        // fed the pool from any device: every hub-launched play carried a tmdb id and was dropped below. A
        // cached mapping proceeds inline; a miss kicks ONE async resolve and re-enters with the tt id (the
        // chrome re-calls this every tick anyway, so the cache also catches the next call).
        var imdbId = rawImdbId
        if enabled, let raw = rawImdbId, raw.lowercased().hasPrefix("tmdb") {
            if let tt = CommunityTrickplay.cachedIMDbID(for: raw) {
                imdbId = tt
            } else {
                resolveCommunityIdentity(rawId: raw, season: season, episode: episode,
                                         duration: duration, isRealDuration: isRealDuration)
                return
            }
        }
        guard enabled, let imdbId, duration > 0,
              let key = CommunityTrickplay.contentKey(imdbId: imdbId, season: season, episode: episode, duration: duration)
        else {
            // Diagnose an empty server table: log WHY we never key (the remaining culprits are a non-tt,
            // non-tmdb libraryId, e.g. kitsu:/paste-a-link, or a zero duration).
            if enabled, communityKey == nil {
                VXProbe.log("tp", "community NOT keyed (need a tt-imdb id + duration>0): imdb=\(VXProbeRedaction.identityToken(imdbId)) dur=\(Int(duration))")
            }
            return
        }
        // Mark the real-duration arrival regardless of whether the key changes, so uploads unblock.
        if isRealDuration { hasRealDuration = true }
        // No-op if already keyed on this exact content key (idempotent across repeated calls). The real
        // duration re-keys ONLY when its bucket differs from the provisional one.
        if communityKey == key { return }
        if communityKey != nil, !isRealDuration { return }   // keep the provisional key until the real one lands
        let rekeying = communityKey != nil
        VXProbe.log("tp", "community \(rekeying ? "re-keyed" : "keyed"): \(VXProbeRedaction.identityToken(key)) (imdb=\(VXProbeRedaction.identityToken(imdbId)) real=\(isRealDuration ? "yes" : "no"))")
        communityKey = key
        communityImdb = imdbId
        communitySeason = season
        communityEpisode = episode
        communityDurationBucket = CommunityTrickplay.durationBucket(duration)
        // A community duration-bucket re-key is separate from the stable local media identity above. It
        // invalidates only the fetched sheet; captured session frames remain valid because they are time-indexed.
        if rekeying { communitySheet = nil; communityAlreadyExists = false; communityExistingFrameCount = 0 }
        uploadPolicy.reset(for: key)
        Task { [weak self] in
            let sheet = await CommunityTrickplay.fetch(key: key)
            await MainActor.run {
                guard let self, self.communityKey == key else { return }   // title may have changed
                if let sheet {
                    self.communitySheet = sheet
                    self.communityAlreadyExists = true
                    self.communityExistingFrameCount = sheet.frameCount
                }
            }
        }
    }

    /// The raw `tmdb:…` id currently being (or already) resolved, so a burst of per-tick `configureCommunity`
    /// calls (timePos handler + wall-clock timer) mints exactly ONE network resolve. Deliberately NOT cleared
    /// on failure: it then marks the id one-shot-failed so the per-tick callers stop re-firing the lookup
    /// (the session stays local-only, exactly the old behavior). Reset per title in `configure`.
    private var communityResolveTriedFor: String?
    /// Captured by async TMDB to IMDb resolution. A first-frame episode re-key advances this
    /// generation, so an outgoing episode's slow completion cannot configure the incoming episode.
    private var communityIdentityGeneration = TrickplayIdentityGeneration()

    /// One-shot tmdb->imdb resolve, then re-enter `configureCommunity` with the tt identity. Fail-soft.
    private func resolveCommunityIdentity(rawId: String, season: Int?, episode: Int?,
                                          duration: Double, isRealDuration: Bool) {
        guard communityResolveTriedFor != rawId else { return }
        communityResolveTriedFor = rawId
        let identityGeneration = communityIdentityGeneration.value
        Task { [weak self] in
            let tt = await CommunityTrickplay.resolveIMDbID(rawId: rawId, seriesHint: season != nil)
            await MainActor.run {
                guard let self,
                      self.communityIdentityGeneration.accepts(identityGeneration) else { return }
                guard let tt else {
                    VXProbe.log("tp", "tmdb->imdb resolve FAILED for \(VXProbeRedaction.identityToken(rawId)) (session stays local-only)")
                    return
                }
                self.configureCommunity(imdbId: tt, season: season, episode: episode,
                                        duration: duration, isRealDuration: isRealDuration)
            }
        }
    }

    /// Monotonic token so a slow disk read+decode that resolves after the user has scrubbed on (or after a
    /// community-sheet / in-memory hit already set a newer frame) is discarded instead of clobbering the
    /// current preview with a stale one.
    private var showToken = 0

    /// Shows the stored frame nearest to `time`. Call while the user is scrubbing. Community sheet first
    /// (shared), then the per-device local cache.
    ///
    /// The synchronous fast paths (community crop + in-memory NSCache hit) assign `image` inline so a warm
    /// scrub stays instant. A cache MISS used to do a blocking `ioQueue.sync` disk read + JPEG decode ON THE
    /// MAIN THREAD during scrubbing; that read+decode is now hopped off the main actor and the resolved frame
    /// is assigned back on the MainActor, gated by `showToken` so a stale late result can't overwrite a newer one.
    func show(time: Double) {
        showToken &+= 1
        if let sheet = communitySheet, let crop = sheet.crop(at: time) {
            image = crop
            return
        }
        guard let key = localCacheKey else {
            image = nil
            return
        }
        // In-memory hit resolves synchronously so a warm scrub is instant and never touches disk.
        if let cached = Self.localFrameCache.memoryImage(for: key, time: time) {
            image = cached
            return
        }
        // Cache miss: read + decode off the main thread, then assign on the MainActor if still current.
        let token = showToken
        Self.localFrameCache.imageAsync(for: key, time: time) { [weak self] resolved in
            Task { @MainActor in
                guard let self, self.showToken == token else { return }   // user scrubbed on; drop the stale frame
                self.image = resolved
            }
        }
    }

    func clear() {
        image = nil
    }

    /// Heavy frame processing (JPEG decode + macOS near-black rasterization/sampling), kept OFF the main
    /// actor. `nonisolated` + `static` so a background capture-queue caller can run it before hopping to the
    /// main actor: previously this decode + the macOS cgImage rasterization + the isBlackImage pixel sample all
    /// ran on @MainActor (the capture completion hops to main before touching store state), so every ~10s a 4K
    /// JPEG was decoded on the UI thread, contributing to jank. Returns the decoded image, or nil when the JPEG
    /// failed to decode or the frame is near-black (unrendered) and should be dropped. Fail-soft: logs the drop.
    nonisolated static func decodeCapturedFrame(_ data: Data, at time: Double) -> ScrubImage? {
        guard let decoded = ScrubImage(data: data) else {
            VXProbe.log("tp", "dropping frame at \(Int(time))s: JPEG decode failed")
            return nil
        }
        #if canImport(AppKit)
        // macOS-only unrendered-frame guard. This USED to silently drop the frame with no log, which made it a
        // prime suspect for the owner-device zero-contribution bug: a libmpv 4K/HDR/DV frame can JPEG-decode to a
        // CGImage that is NOT plain 8-bit/32-bpp (wide-gamut / 16-bit-per-component), and the old sampler hardcoded
        // an 8-bit RGBA byte layout (x*4 striding, <30 thresholds), so it could read garbage and wrongly flag EVERY
        // real frame as black - dropping them all before sessionFrames.append, with zero trace. isBlackImage is now
        // format-guarded (only samples a safe 8-bit/32-bpp buffer; any other layout is treated as NOT black so a
        // valid frame is never discarded on a format we can't sample), and the drop is logged so it is traceable.
        //
        // SIZE-BASED OVERRIDE (task 3): a real detailed frame JPEG-compresses to tens of KB, while a truly black /
        // unrendered frame compresses to ~2-4 KB. So a frame whose encoded JPEG is >= nonBlackByteFloor is DEFINITELY
        // not black no matter what the pixel sampler reads (the sampler misfires on 10-bit/HDR frames). We only drop
        // as near-black when BOTH the sampler says black AND the encoded size is small. The probe below logs the
        // encoded size + sampler verdict + keep decision so every frame's fate is visible in the terminal log.
        let nonBlackByteFloor = 8000
        var samplerBlack = false
        if let cgImage = decoded.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            samplerBlack = isBlackImage(cgImage)
        }
        let bigEnoughToBeReal = data.count >= nonBlackByteFloor
        let kept = bigEnoughToBeReal || !samplerBlack
        VXProbe.log("tp", "frame at \(Int(time))s bytes=\(data.count) samplerBlack=\(samplerBlack ? "true" : "false") kept=\(kept ? "true" : "false")")
        if !kept {
            VXProbe.log("tp", "dropping frame at \(Int(time))s: near-black (unrendered) bytes=\(data.count)")
            return nil
        }
        #else
        // Non-AppKit platforms have no pixel sampler here, so nothing is dropped as near-black; still emit the probe
        // so the log shows the size verdict for every captured frame on every platform.
        VXProbe.log("tp", "frame at \(Int(time))s bytes=\(data.count) samplerBlack=n/a kept=true")
        #endif
        return decoded
    }

    /// Stores a captured frame for future scrub previews. Convenience path that decodes on the CURRENT actor
    /// (the caller's context) then records; the player capture path instead calls `decodeCapturedFrame` off the
    /// main actor and `recordDecodedFrame` on it, to keep the heavy decode off the UI thread.
    func recordCapturedFrameData(_ data: Data, at time: Double) {
        guard let decoded = Self.decodeCapturedFrame(data, at: time) else { return }
        recordDecodedFrame(decoded, data: data, at: time)
    }

    /// Light main-actor state mutations for an already-decoded (and black-checked) frame: cache the tile and
    /// buffer the raw JPEG for a possible community upload. Keep the heavy decode/black-check in
    /// `decodeCapturedFrame` so only this small tail touches @MainActor state.
    func recordDecodedFrame(_ decoded: ScrubImage, data: Data, at time: Double) {
        guard let key = localCacheKey, !key.isEmpty else { return }
        Self.localFrameCache.store(image: decoded, data: data, for: key, time: time)
        // Keep the raw JPEG for a possible community upload (bounded; the worker caps at 600 tiles anyway).
        // Buffer EVEN when a community set already exists, so a fuller local capture can improve a thin one.
        if communityKey != nil, sessionFrames.count < 600 {
            sessionFrames.append(CommunityTrickplay.CapturedFrame(time: time, jpeg: data))
            maybeUploadProgressively()   // upload DURING playback, not only at a teardown that may never fire
        }
    }

    /// Upload during playback once the local capture is storable. Teardown may replace it once after material
    /// coverage growth. A deliberate decline is terminal; a transport/build failure gets one teardown retry.
    private func maybeUploadProgressively() {
        guard CommunityTrickplay.isEnabled,
              let key = communityKey,
              let imdb = communityImdb else { return }
        let coverageReady = CommunityTrickplay.uploadCanStore(
            frameCount: sessionFrames.count, intervalS: Self.captureInterval, durationBucket: communityDurationBucket)
        let admission = uploadPolicy.request(
            key: key, kind: .progressive, frameCount: sessionFrames.count,
            existingFrameCount: communityExistingFrameCount, coverageReady: coverageReady
        )
        VXProbe.log(
            "tp",
            "progressive-gate frames=\(sessionFrames.count) existing=\(communityExistingFrameCount) coverageReady=\(coverageReady ? "true" : "false") terminal=\(uploadPolicy.isTerminal ? "true" : "false") inFlight=\(uploadPolicy.inFlight == nil ? "false" : "true") -> \(admission == nil ? "skip" : "UPLOAD")"
        )
        guard let admission else { return }
        admitUpload(admission, imdb: imdb)
    }

    /// Teardown flush. This is the first attempt when playback ended before a progressive upload, or the single
    /// retry after a transient progressive failure. It never repeats a stored or deliberately declined key.
    func finishAndUploadIfNeeded(srcHeight: Int = 0) {
        if srcHeight > 0 { communitySrcHeight = srcHeight }
        guard CommunityTrickplay.isEnabled,
              let key = communityKey,
              let imdb = communityImdb else { return }
        let coverageReady = CommunityTrickplay.uploadCanStore(
            frameCount: sessionFrames.count, intervalS: Self.captureInterval, durationBucket: communityDurationBucket)
        let admission = uploadPolicy.request(
            key: key, kind: .final, frameCount: sessionFrames.count,
            existingFrameCount: communityExistingFrameCount, coverageReady: coverageReady
        )
        VXProbe.log(
            "tp",
            "teardown-gate frames=\(sessionFrames.count) existing=\(communityExistingFrameCount) coverageReady=\(coverageReady ? "true" : "false") terminal=\(uploadPolicy.isTerminal ? "true" : "false") inFlight=\(uploadPolicy.inFlight == nil ? "false" : "true") -> \(admission == nil ? "skip" : "FLUSH")"
        )
        guard let admission else { return }
        admitUpload(admission, imdb: imdb)
    }

    /// Atomically reserve and snapshot the old key before a title or episode
    /// switch clears its mutable capture state. If an explicit teardown already
    /// reserved the final, the policy returns nil and this remains once-only.
    private func retireCommunityUploadIfNeeded() {
        guard CommunityTrickplay.isEnabled,
              communityKey != nil,
              let imdb = communityImdb else {
            uploadPolicy.reset(for: nil)
            return
        }
        let coverageReady = CommunityTrickplay.uploadCanStore(
            frameCount: sessionFrames.count,
            intervalS: Self.captureInterval,
            durationBucket: communityDurationBucket
        )
        let admission = uploadPolicy.retireCurrent(
            frameCount: sessionFrames.count,
            existingFrameCount: communityExistingFrameCount,
            coverageReady: coverageReady,
            selecting: nil
        )
        VXProbe.log(
            "tp",
            "retirement-gate frames=\(sessionFrames.count) existing=\(communityExistingFrameCount) coverageReady=\(coverageReady ? "true" : "false") -> \(admission == nil ? "skip" : "PRESERVE")"
        )
        guard let admission else { return }
        admitUpload(admission, imdb: imdb)
    }

    private func admitUpload(
        _ admission: TrickplayUploadPolicy.Admission,
        imdb: String
    ) {
        let claim: TrickplayUploadPolicy.Claim
        switch admission {
        case .start(let admitted), .deferred(let admitted):
            claim = admitted
        }
        let snapshot = UploadSnapshot(
            claim: claim,
            imdb: imdb,
            season: communitySeason,
            episode: communityEpisode,
            durationBucket: communityDurationBucket,
            srcHeight: communitySrcHeight,
            interval: Self.captureInterval,
            frames: Array(sessionFrames.prefix(claim.frameCount))
        )
        switch admission {
        case .start:
            pushUpload(snapshot)
        case .deferred:
            deferredUploadSnapshots[claim.sequence] = snapshot
            VXProbe.log(
                "tp",
                "upload deferred key=\(VXProbeRedaction.identityToken(claim.key)) frames=\(snapshot.frames.count)"
            )
        }
    }

    /// Build and POST one immutable policy-owned snapshot. The task retains this
    /// store until completion so an admitted teardown drain survives UI teardown.
    private func pushUpload(_ snapshot: UploadSnapshot) {
        let claim = snapshot.claim
        let key = claim.key
        VXProbe.log("tp", "pushUpload FIRING key=\(VXProbeRedaction.identityToken(key)) imdb=\(VXProbeRedaction.identityToken(snapshot.imdb)) frames=\(snapshot.frames.count)")
        uploadTask = Task(priority: .utility) { [self] in
            let outcome = await CommunityTrickplay.buildAndUpload(
                key: key, imdbId: snapshot.imdb,
                season: snapshot.season, episode: snapshot.episode,
                durationBucket: snapshot.durationBucket,
                srcHeight: snapshot.srcHeight,
                intervalS: snapshot.interval, frames: snapshot.frames)
            // Honest result: a 200 the Worker consciously declined (below_coverage_threshold, a keep-fuller race
            // with another contributor, a remote frameBounds drop) is "rejected(reason)", NOT "failed". Reserve
            // "failed" for a real transport error, a non-200, or a local build failure that never POSTed.
            let resultLabel: String
            switch outcome {
            case .stored: resultLabel = "stored"
            case .rejected(let reason): resultLabel = "rejected(\(reason))"
            case .failed: resultLabel = "failed"
            }
            VXProbe.log("tp", "upload key=\(VXProbeRedaction.identityToken(key)) frames=\(snapshot.frames.count) -> \(resultLabel)")
            let policyOutcome: TrickplayUploadPolicy.Outcome
            switch outcome {
            case .stored: policyOutcome = .stored
            case .rejected: policyOutcome = .rejected
            case .failed: policyOutcome = .failed
            }
            let completion = uploadPolicy.complete(claim, outcome: policyOutcome)
            guard completion.applied else { return }
            uploadTask = nil

            let nextSnapshot = completion.nextClaim.flatMap {
                deferredUploadSnapshots.removeValue(forKey: $0.sequence)
            }
            let queuedSequences = Set(uploadPolicy.deferredFinals.map(\.sequence))
            deferredUploadSnapshots = deferredUploadSnapshots.filter {
                queuedSequences.contains($0.key)
            }
            if let nextSnapshot {
                VXProbe.log(
                    "tp",
                    "upload draining deferred final key=\(VXProbeRedaction.identityToken(nextSnapshot.claim.key)) frames=\(nextSnapshot.frames.count)"
                )
                pushUpload(nextSnapshot)
            }
        }
    }

    /// Samples five points; considers the frame black (unrendered) if four or more are near-black.
    ///
    /// FORMAT-GUARDED: the raw byte sampler below is only valid for a plain 8-bit, 32-bits-per-pixel buffer
    /// (RGBA/BGRA - the first three channels are colour on both, so a <30 test on bytes [off..off+2] holds).
    /// A libmpv 4K/HDR/DV capture can JPEG-decode to a 16-bit-per-component or otherwise non-32bpp CGImage; for
    /// those the byte striding + <30 threshold are meaningless and previously flagged EVERY frame as black,
    /// silently discarding all community frames on the owner's Mac. So anything that is not a safe 8-bit/32bpp
    /// buffer returns false (NOT black) - never discard a real frame on a layout we cannot sample.
    #if canImport(AppKit)
    // nonisolated: pure pixel sampling with no main-actor state, so the nonisolated `decodeCapturedFrame`
    // (run off the main thread on the capture queue) can call it without an actor hop.
    nonisolated private static func isBlackImage(_ cgImage: CGImage) -> Bool {
        guard cgImage.width > 0, cgImage.height > 0 else { return false }
        // Only trust the raw sampler on a plain 8-bit, 4-byte-per-pixel image. Bail (not-black) otherwise.
        guard cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32 else { return false }
        let w = cgImage.width, h = cgImage.height
        guard let data = cgImage.dataProvider?.data else { return false }
        let bytes = CFDataGetBytePtr(data)
        let bpr = cgImage.bytesPerRow
        let len = CFDataGetLength(data)
        let points = [(w/4, h/4), (3*w/4, h/4), (w/2, h/2), (w/4, 3*h/4), (3*w/4, 3*h/4)]
        let blackCount = points.filter { x, y in
            let off = y * bpr + x * 4
            guard off + 3 < len else { return false }
            return (bytes?[off] ?? 0) < 30 && (bytes?[off+1] ?? 0) < 30 && (bytes?[off+2] ?? 0) < 30
        }.count
        return blackCount >= 4
    }
    #endif
}

// MARK: - Local frame cache

private final class LocalTrickplayFrameCache {
    private let bucketSeconds: Double = 2
    private let maxLookbackBuckets = 180        // ~6 min back at 2 s per bucket
    private let ttl: TimeInterval = 48 * 3600
    private let maxDiskBytes: Int64 = 256 * 1024 * 1024
    private let ioQueue = DispatchQueue(label: "com.stremiox.trickplay.localcache", qos: .utility)
    /// Bounded in-memory layer of decoded thumbnails. NSCache caps the resident count AND auto-evicts
    /// under memory pressure (it observes the system memory warning), important on iOS, where this runs
    /// in-process alongside the embedded streaming server and mpv's 4K decode buffers, so an UNBOUNDED
    /// frame map (the original [String:[Int:ScrubImage]], which neither store nor image(for:) ever pruned)
    /// would add straight onto the jetsam pressure. Anything evicted stays on disk and re-decodes on demand.
    private let memory: NSCache<NSString, ScrubImage> = {
        let cache = NSCache<NSString, ScrubImage>()
        #if os(iOS) || os(tvOS)
        cache.countLimit = 40    // ~40 resident thumbnails; the embedded server shares this app's budget
        #else
        cache.countLimit = 240   // macOS server is a separate process, so the app can hold more
        #endif
        return cache
    }()
    private var lastPrune = Date.distantPast

    /// Composite NSCache key for one stream's time bucket (`#` never appears in the base64 stream prefix).
    private func memKey(_ key: String, _ bucket: Int) -> NSString { "\(key)#\(bucket)" as NSString }

    private lazy var cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("trickplay-local", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private lazy var diskStore = TrickplayFrameDiskStore(directory: cacheDirectory)

    init() {
        ioQueue.async { _ = self.cacheDirectory }
    }

    func store(image: ScrubImage, data: Data, for key: String, time: Double) {
        let bucket = bucketFor(time)
        ioQueue.async {
            self.memory.setObject(image, forKey: self.memKey(key, bucket))
            try? self.diskStore.write(data, mediaKey: key, bucket: bucket)
            self.pruneIfNeeded()
        }
    }

    /// Synchronous in-memory-only lookup: returns the nearest already-decoded thumbnail without ever touching
    /// disk, so a warm scrub can resolve on the main thread with no I/O. Returns nil on a miss; the caller
    /// then falls back to `imageAsync` for the off-thread read+decode.
    func memoryImage(for key: String, time: Double) -> ScrubImage? {
        let target = bucketFor(time)
        let minBucket = max(0, target - maxLookbackBuckets)
        for bucket in stride(from: target, through: minBucket, by: -1) {
            if let cached = memory.object(forKey: memKey(key, bucket)) { return cached }
        }
        return nil
    }

    /// Off-main-thread read + JPEG decode of the nearest stored frame. Runs on the private `ioQueue` and calls
    /// `completion` (also on `ioQueue`) with the decoded image or nil. Kept async so scrubbing never blocks the
    /// main thread on a disk read + decode; the in-memory fast path is `memoryImage(for:)` above.
    func imageAsync(for key: String, time: Double, completion: @escaping (ScrubImage?) -> Void) {
        let target = bucketFor(time)
        ioQueue.async {
            let minBucket = max(0, target - self.maxLookbackBuckets)
            for bucket in stride(from: target, through: minBucket, by: -1) {
                if let cached = self.memory.object(forKey: self.memKey(key, bucket)) { completion(cached); return }
                guard let data = self.diskStore.data(mediaKey: key, bucket: bucket),
                      let decoded = ScrubImage(data: data) else { continue }
                self.memory.setObject(decoded, forKey: self.memKey(key, bucket))
                completion(decoded)
                return
            }
            completion(nil)
        }
    }

    private func bucketFor(_ time: Double) -> Int { Int(max(0, floor(time / bucketSeconds))) }

    private func pruneIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPrune) > 600 else { return }
        lastPrune = now
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        var retained: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for file in files {
            guard let vals = try? file.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true else { continue }
            let modified = vals.contentModificationDate ?? .distantPast
            let size = Int64(vals.fileSize ?? 0)
            if now.timeIntervalSince(modified) > ttl { try? FileManager.default.removeItem(at: file); continue }
            total += size
            retained.append((file, modified, size))
        }
        if total > maxDiskBytes {
            for item in retained.sorted(by: { $0.date < $1.date }) {
                if total <= maxDiskBytes { break }
                try? FileManager.default.removeItem(at: item.url)
                total -= item.size
            }
        }
    }

}
