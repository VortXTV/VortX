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
    /// Frame count at the last upload. Throttles progressive re-uploads and lets the teardown flush skip a
    /// re-send when no new coverage arrived. Replaces the old one-shot `didUpload` (which lost everything to a
    /// missing teardown).
    private var lastUploadedCount = 0
    /// Capture cadence the local pipeline records at (~every 10s); also the sheet/vtt tile interval. Sourced
    /// from the RemoteConfig `trickplay.captureIntervalSecs` dial (clamped 2..60), so the owner can tune
    /// coverage density with no app update. Baked default 10 == the shipping value; a null/out-of-range remote
    /// value keeps 10. Read once at use; the value is stable for a playback session.
    private static var captureInterval: Double { Double(RemoteConfig.snapshot.captureIntervalSecs) }

    func configure(localCacheKey: String?) {
        guard self.localCacheKey != localCacheKey else { return }
        self.localCacheKey = localCacheKey
        image = nil
        // A new title: drop the previous community sheet + session frames.
        communitySheet = nil
        communityAlreadyExists = false
        communityExistingFrameCount = 0
        communityKey = nil
        communityResolveTriedFor = nil
        hasRealDuration = false
        sessionFrames = []
        lastUploadedCount = 0
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
                VXProbe.log("tp", "community NOT keyed (need a tt-imdb id + duration>0): imdb=\(imdbId ?? "nil") dur=\(Int(duration))")
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
        VXProbe.log("tp", "community \(rekeying ? "re-keyed" : "keyed"): \(key) (imdb=\(imdbId) real=\(isRealDuration ? "yes" : "no"))")
        communityKey = key
        communityImdb = imdbId
        communitySeason = season
        communityEpisode = episode
        communityDurationBucket = CommunityTrickplay.durationBucket(duration)
        // A re-key under a new bucket invalidates a fetched sheet (it belonged to the old key); the new
        // fetch below replaces it. Captured session frames stay valid (they are time-indexed, not bucketed).
        if rekeying { communitySheet = nil; communityAlreadyExists = false; communityExistingFrameCount = 0 }
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

    /// One-shot tmdb->imdb resolve, then re-enter `configureCommunity` with the tt identity. Fail-soft.
    private func resolveCommunityIdentity(rawId: String, season: Int?, episode: Int?,
                                          duration: Double, isRealDuration: Bool) {
        guard communityResolveTriedFor != rawId else { return }
        communityResolveTriedFor = rawId
        Task { [weak self] in
            let tt = await CommunityTrickplay.resolveIMDbID(rawId: rawId, seriesHint: season != nil)
            await MainActor.run {
                guard let self else { return }
                guard let tt else {
                    VXProbe.log("tp", "tmdb->imdb resolve FAILED for \(rawId) (session stays local-only)")
                    return
                }
                self.configureCommunity(imdbId: tt, season: season, episode: episode,
                                        duration: duration, isRealDuration: isRealDuration)
            }
        }
    }

    /// Shows the stored frame nearest to `time`. Call while the user is scrubbing. Community sheet first
    /// (shared), then the per-device local cache.
    func show(time: Double) {
        if let sheet = communitySheet, let crop = sheet.crop(at: time) {
            image = crop
            return
        }
        guard let key = localCacheKey,
              let local = Self.localFrameCache.image(for: key, time: time) else {
            image = nil
            return
        }
        image = local
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

    /// Upload DURING playback so trickplay is never lost to a missing teardown (movie ends -> home, sleep,
    /// auto-advance, or jetsam all skip the teardown flush below). Called after EACH kept capture (~every 10s),
    /// this now pushes progressively as soon as even ONE new kept frame beats the stored set: the old
    /// `lastUploadedCount + perMinute` batch gate meant no upload fired during a normal watch, so mid-play
    /// contribution never happened and only a teardown (which frequently never fires) could store anything. The
    /// worker is overwrite-wins / keep-fuller, so each small push just improves the stored set.
    private func maybeUploadProgressively() {
        // Minimum NEW kept frames since the last upload before we push again. 1 == push on every fresh kept frame
        // (capture is ~every 10s, so effectively every ~10s of new coverage). This replaces the old ~1-minute
        // batch so trickplay contributes live, not only at teardown.
        let minNewFrames = 1
        // The community sheet builder needs >= 2 tiles: buildAndUpload's `while budget >= 2` loop is skipped for a
        // single frame, so a 1-frame push is admitted then dropped at the floor (the noisy sorted=1 failure every
        // session). Never spawn a progressive push until we actually have a buildable (>= 2) frame count.
        let minBuildableFrames = 2
        // Evaluate each guard clause up front so the probe can report WHY we do or do not upload this tick.
        let enabled = CommunityTrickplay.isEnabled
        let hasKey = communityKey != nil
        let beatsStored = sessionFrames.count > communityExistingFrameCount   // keep-fuller: don't clobber a fuller set
        let hasNewCoverage = sessionFrames.count >= lastUploadedCount + minNewFrames
        let enoughToBuild = sessionFrames.count >= minBuildableFrames   // sheet builder floors at 2 tiles
        let willUpload = enabled && hasKey && beatsStored && hasNewCoverage && enoughToBuild && communityImdb != nil
        VXProbe.log("tp", "upload-gate frames=\(sessionFrames.count) existing=\(communityExistingFrameCount) lastUploaded=\(lastUploadedCount) minNew=\(minNewFrames) enabled=\(enabled ? "true" : "false") hasKey=\(hasKey ? "true" : "false") imdb=\(communityImdb ?? "nil") beatsStored=\(beatsStored ? "true" : "false") hasNewCoverage=\(hasNewCoverage ? "true" : "false") enoughToBuild=\(enoughToBuild ? "true" : "false") -> \(willUpload ? "UPLOAD" : "skip")")
        // NOTE: the old `hasRealDuration` gate here blocked EVERY upload for a debrid direct-HTTP MKV, because
        // hasRealDuration is only set by mpv's `duration` event, which those streams frequently never deliver.
        // That is exactly the content the owner watches, so trickplay uploaded nothing (build 138 regression).
        // We upload under the provisional (meta.runtime) key instead: durationBucket rounding makes it match
        // the real-duration bucket in the common case, the worker is keep-fuller (a thin set never clobbers a
        // fuller one), and a later real-duration re-key re-uploads under the corrected key. Fully fail-soft.
        guard willUpload, let key = communityKey, let imdb = communityImdb else { return }
        pushUpload(key: key, imdb: imdb)
    }

    /// Teardown flush: send the FULL session set if it grew since the last progressive push. No-op when
    /// disabled / no key / the community already had a set / no new coverage since the last upload.
    func finishAndUploadIfNeeded(srcHeight: Int = 0) {
        if srcHeight > 0 { communitySrcHeight = srcHeight }
        // No hasRealDuration gate (see maybeUploadProgressively) so a debrid MKV that never emitted mpv's
        // `duration` event still flushes on exit. Requires >= 2 kept frames: the sheet builder needs >= 2 tiles
        // (`while budget >= 2`), so a lone-frame flush can only reproduce the sorted=1 drop. Capture is ~every 10s,
        // so a ~20s+ watch stores; a shorter single-frame watch is structurally unbuildable, not dropped in error.
        let enabled = CommunityTrickplay.isEnabled
        let hasKey = communityKey != nil
        let hasFrames = sessionFrames.count >= 2   // sheet builder floors at 2 tiles; a lone frame is unbuildable
        let grewSinceUpload = sessionFrames.count > lastUploadedCount
        let beatsStored = sessionFrames.count > communityExistingFrameCount
        let willFlush = enabled && hasKey && hasFrames && grewSinceUpload && beatsStored && communityImdb != nil
        VXProbe.log("tp", "teardown-flush frames=\(sessionFrames.count) existing=\(communityExistingFrameCount) lastUploaded=\(lastUploadedCount) enabled=\(enabled ? "true" : "false") hasKey=\(hasKey ? "true" : "false") hasFrames=\(hasFrames ? "true" : "false") grewSinceUpload=\(grewSinceUpload ? "true" : "false") beatsStored=\(beatsStored ? "true" : "false") -> \(willFlush ? "FLUSH" : "skip")")
        guard willFlush, let key = communityKey, let imdb = communityImdb else { return }
        pushUpload(key: key, imdb: imdb)
    }

    /// Build + POST the current session frames off the main actor (fail-soft). Records the uploaded count so
    /// the progressive throttle + teardown flush never re-send the same coverage. Logs the result so an empty
    /// server table can be traced (capture vs key vs POST) from the device log.
    private func pushUpload(key: String, imdb: String) {
        lastUploadedCount = sessionFrames.count
        let frames = sessionFrames
        let season = communitySeason, episode = communityEpisode
        let bucket = communityDurationBucket, height = communitySrcHeight
        VXProbe.log("tp", "pushUpload FIRING key=\(key) imdb=\(imdb) frames=\(frames.count)")
        Task.detached(priority: .utility) {
            let ok = await CommunityTrickplay.buildAndUpload(
                key: key, imdbId: imdb, season: season, episode: episode,
                durationBucket: bucket, srcHeight: height,
                intervalS: Self.captureInterval, frames: frames)
            VXProbe.log("tp", "upload key=\(key) frames=\(frames.count) -> \(ok ? "stored" : "failed")")
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
    /// under memory pressure (it observes the system memory warning) — important on iOS, where this runs
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

    init() {
        ioQueue.async { _ = self.cacheDirectory }
    }

    func hasFrames(for key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return ioQueue.sync {
            // NSCache isn't enumerable by prefix; the on-disk presence is the source of truth here.
            let prefix = filePrefix(for: key) + "-"
            let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
            return files.contains { $0.lastPathComponent.hasPrefix(prefix) }
        }
    }

    func store(image: ScrubImage, data: Data, for key: String, time: Double) {
        let bucket = bucketFor(time)
        ioQueue.async {
            self.memory.setObject(image, forKey: self.memKey(key, bucket))
            try? data.write(to: self.fileURL(for: key, bucket: bucket), options: .atomic)
            self.pruneIfNeeded()
        }
    }

    func image(for key: String, time: Double) -> ScrubImage? {
        let target = bucketFor(time)
        return ioQueue.sync {
            let minBucket = max(0, target - maxLookbackBuckets)
            for bucket in stride(from: target, through: minBucket, by: -1) {
                if let cached = memory.object(forKey: memKey(key, bucket)) { return cached }
                let url = fileURL(for: key, bucket: bucket)
                guard let data = try? Data(contentsOf: url),
                      let decoded = ScrubImage(data: data) else { continue }
                memory.setObject(decoded, forKey: memKey(key, bucket))
                return decoded
            }
            return nil
        }
    }

    private func bucketFor(_ time: Double) -> Int { Int(max(0, floor(time / bucketSeconds))) }

    private func fileURL(for key: String, bucket: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(filePrefix(for: key))-\(bucket).jpg")
    }

    private func filePrefix(for key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

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
