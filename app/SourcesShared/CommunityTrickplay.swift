import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Community trickplay: scrub-preview thumbnails SHARED across users, like Netflix / Plex storyboards.
///
/// Two halves, both 100% fail-soft (any miss / error / offline silently leaves the player on its existing
/// per-device local capture, today's behavior, so there is never a regression):
///
///   1. FETCH-FIRST (`fetch`): on opening a title, compute the content key and GET
///      `trickplay.vortx.tv/tp/{key}`. On a hit, download the sprite-sheet + WEBVTT index ONCE and serve
///      scrub previews by cropping the sprite sub-rect for the scrubbed time, so a title brand new to this
///      device shows previews immediately from the community, with no local generation.
///
///   2. UPLOAD-AFTER-GENERATE (`buildAndUpload`): after the device finishes generating its own local
///      trickplay set, pack the captured JPEG frames into one sprite-sheet, build a matching WEBVTT index,
///      and POST it (first-writer-wins; skipped when the fetch already returned a community set). Gated by a
///      setting and run off the main actor so it never blocks playback.
///
/// CONTENT KEY (computed identically by the Cloudflare Worker):
///   sha1("{imdb}:{season|0}:{episode|0}:{durationBucket}")  durationBucket = floor(duration/10)*10
/// Quality is deliberately NOT in the key (a 720p and 1080p of the same cut share previews); the duration
/// bucket keeps different cuts (theatrical vs extended, or a mismatched file) from colliding.
///
/// Privacy: uploads ONLY the generated sprite + vtt + the content key/metadata (imdb / season / episode /
/// duration-bucket). NEVER an account token, user id, or any PII; none is referenced here.
enum CommunityTrickplay {
    /// The trickplay edge base. Sourced from the RemoteConfig `endpoints.trickplay` dial (validated https +
    /// *.vortx.tv host, else the baked default), so the owner can repoint it with no app update. Baked default
    /// `https://trickplay.vortx.tv` == the shipping value; a null/invalid remote endpoint keeps that default.
    static var baseURL: String { RemoteConfig.snapshot.trickplayEndpoint.absoluteString }

    /// The setting gate (default on, like a normal feature). Mirrors the `stremiox.*` @AppStorage namespace
    /// the player already uses; the 0.4 rename seam (`stremiox.` -> `vortx.`) maps it via SettingsBackup.
    static let settingKey = "stremiox.communityTrickplay"

    static var isEnabled: Bool {
        // RemoteConfig fleet kill-switch `features.communityTrickplay`: a remote `false` force-disables the
        // community layer fleet-wide (fetch AND upload) if the worker is degraded. Baked default true =>
        // absent/null remote is identical to shipping; the user's own setting still governs.
        guard RemoteConfig.snapshot.isFeatureOn("communityTrickplay", default: true) else { return false }
        // Absent default = true. UserDefaults returns false for an unset bool, so check object presence.
        if UserDefaults.standard.object(forKey: settingKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: settingKey)
    }

    /// floor(duration/10)*10, matching the Worker's durationBucket.
    static func durationBucket(_ duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int(floor(duration / 10) * 10)
    }

    // MARK: - Coverage floor (mirrors the Worker, so a doomed upload is never POSTed)

    /// The Worker's serve floor (vortx-trickplay `decision.ts` MIN_SERVE_COVERAGE): a POST whose coverage is
    /// below this is answered `{stored:false, reason:"below_coverage_threshold"}` and discarded, so it is a
    /// wasted round-trip (and, on a shared household IP, eats the per-IP POST budget). Kept in sync with
    /// decision.ts; 0.02 == "play ~6 min of even a 3h film and it stores".
    static let minServeCoverage = 0.02

    /// Coverage of a would-be upload, computed identically to the Worker's `decision.ts` computeCoverage:
    /// clamp[0,1]( frame_count / max(1, round(durationBucket / interval_s)) ) for the GIVEN frame_count/interval.
    /// A prediction from the RAW capture cadence + session frame count is a conservative estimate, NOT an exact
    /// match to what the Worker stores: when the session outgrows one sheet's tile budget, buildAndUpload
    /// decimates before POSTing, and decimation changes BOTH terms (fewer frames over a longer interval) with
    /// independent rounding, so the stored coverage can land either side of the raw estimate. uploadCanStore
    /// therefore does not rely on the raw number alone; it also evaluates the exact decimated frame_count/interval
    /// buildAndUpload will POST, so it never skips a sheet the Worker would keep. Guarded like the Worker (0 on any
    /// non-positive input).
    static func coverage(frameCount: Int, intervalS: Double, durationBucket: Int) -> Double {
        guard frameCount > 0, intervalS > 0, durationBucket > 0 else { return 0 }
        let expected = max(1, Int((Double(durationBucket) / intervalS).rounded()))
        return min(1, max(0, Double(frameCount) / Double(expected)))
    }

    /// Whether the client should spend a POST on this capture. Returns false ONLY when we can positively
    /// predict the Worker will reject it as below_coverage_threshold; when the duration/interval is unknown we
    /// CANNOT predict, so we fail-open (allow, today's behavior) and let the Worker decide. This never
    /// suppresses a legitimate upload (e.g. a debrid MKV whose bucket is provisional); it only skips the
    /// sub-floor uploads that were being fired ~every 60s and logged as a misleading "-> failed".
    static func uploadCanStore(frameCount: Int, intervalS: Double, durationBucket: Int) -> Bool {
        guard durationBucket > 0, intervalS > 0, frameCount > 0 else { return true }
        // Raw prediction: the sheet exactly as captured (no decimation).
        if coverage(frameCount: frameCount, intervalS: intervalS, durationBucket: durationBucket) >= minServeCoverage {
            return true
        }
        // Decimated prediction: when the session holds more frames than one sheet's tile budget, buildAndUpload
        // does NOT post the raw numbers; it strides the frames down and posts a smaller frame_count over a
        // proportionally larger interval. Because the coverage numerator rounds UP (ceil), the decimated sheet can
        // clear the floor the raw numbers miss, so predicting from the raw numbers alone would wrongly skip a
        // storable sheet. Mirror buildAndUpload's EXACT stride math (budget = min(count, maxTiles);
        // stride = ceil(count / budget); kept = ceil(count / stride); interval *= stride) reading the same live
        // `maxTiles` snapshot it reads, so the predicted sheet matches the POSTed one. Below this, both raw and
        // decimated are sub-floor => the Worker rejects either => skipping is correct.
        let maxTiles = max(1, RemoteConfig.snapshot.trickplayMaxTilesValue)
        guard frameCount > maxTiles else { return false }
        let budget = min(frameCount, maxTiles)
        let stride = Int(ceil(Double(frameCount) / Double(budget)))
        let decimatedCount = Int(ceil(Double(frameCount) / Double(stride)))
        let decimatedInterval = intervalS * Double(stride)
        return coverage(frameCount: decimatedCount, intervalS: decimatedInterval, durationBucket: durationBucket) >= minServeCoverage
    }

    /// sha1("{imdb}:{season|0}:{episode|0}:{durationBucket}") as lowercase hex. nil when the imdb id is not a
    /// real `tt…` id (ad-hoc paste-a-link plays have no shareable identity, so they never touch the service).
    static func contentKey(imdbId: String, season: Int?, episode: Int?, duration: Double) -> String? {
        guard imdbId.range(of: #"^tt\d{6,}$"#, options: .regularExpression) != nil else { return nil }
        let bucket = durationBucket(duration)
        guard bucket > 0 else { return nil }
        let raw = "\(imdbId):\(season ?? 0):\(episode ?? 0):\(bucket)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - TMDB-keyed plays -> IMDb identity

    /// The leading `tt…` id inside a raw id string ("tt15239678", "tt14452776:1:2"), or nil. Lets a meta's
    /// `behaviorHints.defaultVideoId` (often "tt…:s:e" on series) seed the shareable identity for free.
    static func ttPrefix(_ raw: String?) -> String? {
        guard let raw, let r = raw.range(of: #"^tt\d{6,}"#, options: .regularExpression) else { return nil }
        return String(raw[r])
    }

    /// tmdb->imdb map, persisted so each title resolves over the network at most ONCE per install. It is read
    /// from `cachedIMDbID` (any thread) and mutated from `resolveIMDbID` (detached tasks) concurrently, so
    /// every access goes through `tmdb2ttLock`. The UserDefaults write runs on a snapshot taken under the lock
    /// but is issued outside it, so a slow defaults write never holds off other readers.
    private static let tmdb2ttDefaultsKey = "stremiox.trickplay.tmdb2tt"
    private static let tmdb2ttLock = NSLock()
    private static var tmdb2ttCache: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: tmdb2ttDefaultsKey) as? [String: String]) ?? [:]
    }()

    /// Synchronous cache lookup: the tt id previously resolved for a raw `tmdb:…` library id, or nil.
    static func cachedIMDbID(for rawId: String) -> String? {
        let key = rawId.lowercased()
        tmdb2ttLock.lock(); defer { tmdb2ttLock.unlock() }
        return tmdb2ttCache[key]
    }

    /// Resolve a `tmdb:…` library id (the identity our hub/TMDB catalogs key plays with) to its `tt…` IMDb id,
    /// so those plays contribute + fetch community trickplay exactly like Cinemeta (`tt…`) plays. THE bug this
    /// kills: every play launched from the TMDB-backed catalogs was dropped by `contentKey`'s tt-guard, so an
    /// account browsing our own hub never fed the pool no matter the device.
    ///
    /// Resolution is our own keyless TMDB edge (`catalogs.vortx.tv/3/{movie|tv}/{id}/external_ids`, edge-signed,
    /// key injected server-side) with a direct-TMDB fallback when the user has a key. Tries the hinted media
    /// type first, then the other (a bare "tmdb:NNN" does not say movie-vs-tv). Cached persistently; fail-soft
    /// nil on an unparseable id / both lookups missing.
    static func resolveIMDbID(rawId: String, seriesHint: Bool) async -> String? {
        let cacheKey = rawId.lowercased()
        tmdb2ttLock.lock()
        let cached = tmdb2ttCache[cacheKey]
        tmdb2ttLock.unlock()
        if let cached { return cached }
        // "tmdb:693134" (canonical), tolerating "tmdb:movie:693134" / "tmdb:tv:693134".
        let parts = cacheKey.split(separator: ":").map(String.init)
        guard parts.first == "tmdb", let numeric = parts.dropFirst().first(where: { Int($0) != nil }) else { return nil }
        let explicit = parts.contains("tv") ? "tv" : (parts.contains("movie") ? "movie" : nil)
        let order = explicit.map { [$0] } ?? (seriesHint ? ["tv", "movie"] : ["movie", "tv"])
        for media in order {
            if let tt = await fetchExternalIMDbID(media: media, tmdbID: numeric) {
                tmdb2ttLock.lock()
                tmdb2ttCache[cacheKey] = tt
                let snapshot = tmdb2ttCache
                tmdb2ttLock.unlock()
                UserDefaults.standard.set(snapshot, forKey: tmdb2ttDefaultsKey)
                VXProbe.log("tp", "resolved \(rawId) -> \(tt) (\(media))")
                return tt
            }
        }
        return nil
    }

    /// One `external_ids` lookup: our keyless edge first (signed; worker holds the key), then TMDB direct with
    /// the user's own key when present. nil on any miss.
    private static func fetchExternalIMDbID(media: String, tmdbID: String) async -> String? {
        func read(_ url: URL?, sign: Bool) async -> String? {
            guard let url else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 10)
            if sign { VortXEdgeAuth.sign(&req) }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return ttPrefix(obj["imdb_id"] as? String)
        }
        let edge = RemoteConfig.snapshot.catalogsEndpoint.absoluteString
        if let tt = await read(URL(string: "\(edge)/\(media)/\(tmdbID)/external_ids"), sign: true) { return tt }
        if let key = ApiKeys.tmdbKey() {
            // SECURITY: this URL carries the user's TMDB key as api_key=. Never log it verbatim (VXProbe / diag).
            return await read(URL(string: "https://api.themoviedb.org/3/\(media)/\(tmdbID)/external_ids?api_key=\(key)"), sign: false)
        }
        return nil
    }

    // MARK: - Fetch-first (L1 community layer)

    /// A community sprite-sheet ready to crop. `tiles` maps a frame index to its (x,y) origin in the sheet;
    /// `tileW`/`tileH` are the per-tile size; `intervalS` the seconds between tiles.
    struct Sheet {
        let image: ScrubImage
        let cgImage: CGImage
        let tileW: Int
        let tileH: Int
        let intervalS: Double
        let frameCount: Int
        let cols: Int

        /// The cropped tile nearest `time`, drawn from the sheet sub-rect. nil if out of range.
        func crop(at time: Double) -> ScrubImage? {
            guard frameCount > 0, cols > 0, intervalS > 0 else { return nil }
            let idx = max(0, min(frameCount - 1, Int((time / intervalS).rounded(.down))))
            let col = idx % cols
            let row = idx / cols
            let rect = CGRect(x: col * tileW, y: row * tileH, width: tileW, height: tileH)
            guard let sub = cgImage.cropping(to: rect) else { return nil }
            #if canImport(AppKit)
            return NSImage(cgImage: sub, size: NSSize(width: tileW, height: tileH))
            #else
            return UIImage(cgImage: sub)
            #endif
        }
    }

    private struct FetchResponse: Decodable {
        let sprite: String
        let vtt: String?
        let tile_w: Int
        let tile_h: Int
        let interval_s: Double
        let frame_count: Int
        let cols: Int
    }

    /// GET the community set for `key` and, on a hit, download + decode the sprite. Returns nil on any miss /
    /// error (404, offline, decode failure) so the caller falls back to local generation. Never throws.
    static func fetch(key: String) async -> Sheet? {
        guard let url = URL(string: "\(baseURL)/tp/\(key)") else { return nil }
        do {
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("application/json", forHTTPHeaderField: "accept")
            VortXEdgeAuth.sign(&req)   // gated host (trickplay.vortx.tv /tp/<key>): stamp X-VX-Ts / X-VX-Sig
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            // NOTE: the sprite (meta.sprite) is on the R2 public asset host, NOT a gated *.vortx.tv
            // service host, so it intentionally stays unsigned (that route is exempt).
            let meta = try JSONDecoder().decode(FetchResponse.self, from: data)
            guard meta.frame_count > 0, meta.cols > 0, meta.tile_w > 0, meta.tile_h > 0,
                  meta.interval_s > 0, let spriteURL = URL(string: meta.sprite) else { return nil }

            let (imgData, imgResp) = try await URLSession.shared.data(
                for: URLRequest(url: spriteURL, timeoutInterval: 12))
            guard let imgHttp = imgResp as? HTTPURLResponse, imgHttp.statusCode == 200,
                  let image = ScrubImage(data: imgData), let cg = image.cgImageForCrop else { return nil }

            return Sheet(image: image, cgImage: cg, tileW: meta.tile_w, tileH: meta.tile_h,
                         intervalS: meta.interval_s, frameCount: meta.frame_count, cols: meta.cols)
        } catch {
            return nil
        }
    }

    // MARK: - Upload-after-generate (sprite-sheet build + POST)

    /// One captured local frame: its JPEG bytes and the playback time it was grabbed at.
    struct CapturedFrame {
        let time: Double
        let jpeg: Data
    }

    /// The outcome of an upload attempt, so the caller can log honestly instead of collapsing everything that is
    /// not `stored` into "failed": `stored` (the Worker kept a NEW set), `rejected` (a 200 the Worker consciously
    /// declined, e.g. below_coverage_threshold or a keep-fuller race, carrying the Worker's reason), or `failed`
    /// (a real transport error, a non-200, or a local build failure that never POSTed).
    enum UploadOutcome {
        case stored
        case rejected(String)
        case failed
    }

    /// Build a sprite-sheet + WEBVTT index from the device's captured frames and POST it (first-writer-wins).
    /// Runs entirely off the main actor. Returns `.stored` only if the server stored a NEW set, `.rejected(reason)`
    /// for a 200 the Worker declined, and `.failed` for a transport/non-200 error or a local build failure that
    /// never POSTed. Never throws.
    ///
    /// `intervalS` is the capture cadence the local pipeline uses (~10s). Frames are sorted by time, packed
    /// left-to-right / top-to-bottom into a grid, and each tile is downscaled to ~480x270 (16:9) so the
    /// sheet stays tiny. The WEBVTT maps each tile's time window to `sprite#xywh=x,y,w,h` (Jellyfin/Plex web
    /// convention); the app crops the sub-rect itself, so no native trickplay support is needed.
    static func buildAndUpload(
        key: String,
        imdbId: String,
        season: Int?,
        episode: Int?,
        durationBucket: Int,
        srcHeight: Int,
        intervalS: Double,
        frames: [CapturedFrame]
    ) async -> UploadOutcome {
        guard isEnabled else { return .failed }
        let sorted = frames.sorted { $0.time < $1.time }
        // Store even a tiny capture (>=1 frame); the owner asked that even ~5s of coverage be kept + served.
        // Frame bounds come from the RemoteConfig `trickplay.minFrames`/`maxFrames` dials (clamped min 1..10,
        // max 30..600). Baked defaults (min 1, max 600) == the shipping literals, so a null/out-of-range
        // remote value is behaviorally identical to today.
        let frameBounds = RemoteConfig.snapshot.trickplayFrameBounds
        // The sheet builder below needs >= 2 tiles (`while budget >= 2`). Clamp the effective lower bound to 2 so a
        // 1-frame set is rejected up front with a clear reason instead of silently falling through the geometry loop
        // and failing at the floor with a misleading "compose/encode failure" log.
        let minFrames = max(2, frameBounds.min)
        guard sorted.count >= minFrames, sorted.count <= frameBounds.max else {
            VXProbe.log("tp", "buildAndUpload skipped: sorted=\(sorted.count) below buildable floor \(minFrames) (need >=2 tiles)")
            return .failed
        }

        // Bound one sheet to a 3 MB-safe tile budget. A long watch produces far more 480x270 tiles than fit
        // under the worker's 3 MB cap, so the full-session sheet blew the cap and the upload was dropped before
        // the POST ever fired (the "frames=401 -> failed" case). Instead of TRUNCATING to the first N tiles
        // (which would only ever preview the film's opening), DECIMATE evenly across the whole capture so the
        // sheet still spans the entire duration, just at a coarser scrub interval. A short watch (<= budget) is
        // untouched: stride 1, effectiveInterval == intervalS, identical to before.
        let maxTiles = max(1, RemoteConfig.snapshot.trickplayMaxTilesValue)
        // Tile size: 16:9 at 320 wide. Smaller than the 480px local capture so a `maxTiles`-tile sheet stays a
        // fraction of the pixels of the old 480x270 sheet, keeping q0.7 under the 3 MB cap in the common case.
        let tileW = 320, tileH = 180
        let maxBytes = 3 * 1024 * 1024

        // UNCONDITIONAL byte-bound. A sheet must satisfy TWO server limits: <= 3 MB (MAX_UPLOAD_BYTES) and
        // >= 2 frames (the worker rejects frame_count < MIN_FRAME_COUNT=2). Start at the configured tile budget
        // and, on a 3 MB overflow OR a compose/encode failure, HALVE the budget and rebuild the WHOLE geometry
        // (stride, effective frames, effectiveInterval, cols, rows) together so the render, the vtt, and the meta
        // always describe ONE consistent grid. The floor is 2 tiles: a 2-tile 320x180 sheet (640x180) cannot
        // approach 3 MB, so a legitimate capture is never dropped for size, only ever for a true allocation or
        // encoder failure at the floor. Coverage is invariant under decimation (frame_count shrinks as
        // effectiveInterval grows), so a re-decimated sheet still clears the worker's MIN_SERVE_COVERAGE floor.
        var budget = min(sorted.count, maxTiles)
        var picked: (jpeg: Data, count: Int, cols: Int, interval: Double)?
        while budget >= 2 {
            let stride = sorted.count > budget ? Int(ceil(Double(sorted.count) / Double(budget))) : 1
            let effective = stride > 1
                ? sorted.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
                : sorted
            let effectiveInterval = intervalS * Double(stride)
            let cols = max(1, Int(ceil(sqrt(Double(effective.count)))))
            let rows = Int(ceil(Double(effective.count) / Double(cols)))

            guard let composed = renderSheetImage(frames: effective, tileW: tileW, tileH: tileH, cols: cols, rows: rows) else {
                VXProbe.log("tp", "buildAndUpload compose FAILED tiles=\(effective.count) cols=\(cols) rows=\(rows) budget=\(budget) -> re-decimate")
                if budget == 2 { break }
                budget = max(2, budget / 2)
                continue
            }
            var fit: Data?
            for q in [0.7, 0.5, 0.4] {
                if let d = composed.jpegData(quality: CGFloat(q)), d.count <= maxBytes { fit = d; break }
            }
            if let fit {
                picked = (fit, effective.count, cols, effectiveInterval)
                break
            }
            VXProbe.log("tp", "buildAndUpload over 3MB at q0.4 tiles=\(effective.count) cols=\(cols) rows=\(rows) budget=\(budget) -> re-decimate")
            if budget == 2 { break }
            budget = max(2, budget / 2)
        }
        guard let picked else {
            VXProbe.log("tp", "buildAndUpload could not build a >=2-tile sheet under 3MB (compose/encode failure at floor, sorted=\(sorted.count)) -> dropped")
            return .failed
        }

        let vtt = buildVTT(frameCount: picked.count, cols: picked.cols, tileW: tileW, tileH: tileH, intervalS: picked.interval)

        let meta: [String: Any] = [
            "imdb": imdbId,
            "season": season ?? 0,
            "episode": episode ?? 0,
            "durationBucket": durationBucket,
            "frame_count": picked.count,
            "tile_w": tileW,
            "tile_h": tileH,
            "interval_s": picked.interval,
            "cols": picked.cols,
            "src_height": srcHeight,
        ]
        return await post(key: key, sprite: picked.jpeg, vtt: vtt, meta: meta)
    }

    /// Compose the frames into one sheet bitmap and return the composed CGImage (the caller JPEG-encodes it,
    /// re-encoding at descending quality until it fits the upload cap). Each frame is drawn scaled-to-fill into
    /// its tile cell. Returns nil on any drawing failure.
    private static func renderSheetImage(frames: [CapturedFrame], tileW: Int, tileH: Int, cols: Int, rows: Int) -> CGImage? {
        let sheetW = cols * tileW, sheetH = rows * tileH
        guard sheetW > 0, sheetH > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        ctx.interpolationQuality = .medium

        for (i, frame) in frames.enumerated() {
            guard let src = ScrubImage(data: frame.jpeg)?.cgImageForCrop else { continue }
            let col = i % cols
            let row = i / cols
            // CGContext origin is bottom-left; lay tiles out top-to-bottom so the index order matches the vtt.
            let y = (rows - 1 - row) * tileH
            ctx.draw(src, in: CGRect(x: col * tileW, y: y, width: tileW, height: tileH))
        }
        return ctx.makeImage()
    }

    /// WEBVTT mapping each tile window [t, t+interval) to `sprite#xywh=x,y,w,h`. Matches the worker's expected
    /// layout (row-major, cols per row).
    private static func buildVTT(frameCount: Int, cols: Int, tileW: Int, tileH: Int, intervalS: Double) -> String {
        var lines = ["WEBVTT", ""]
        for i in 0..<frameCount {
            let start = Double(i) * intervalS
            let end = Double(i + 1) * intervalS
            let col = i % cols
            let row = i / cols
            let x = col * tileW, y = row * tileH
            lines.append("\(vttTime(start)) --> \(vttTime(end))")
            lines.append("sprite#xywh=\(x),\(y),\(tileW),\(tileH)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func vttTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let ms = Int((seconds - Double(total)) * 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// POST the multipart body. `.stored` only on `{ ok:true, stored:true }`; a 200 the Worker declined is
    /// `.rejected(reason)` (the Worker's `reason`, e.g. below_coverage_threshold or a keep-fuller race); a
    /// transport error, a non-200, or a body we cannot build is `.failed`. Never throws.
    private static func post(key: String, sprite: Data, vtt: String, meta: [String: Any]) async -> UploadOutcome {
        guard let url = URL(string: "\(baseURL)/tp/\(key)"),
              let metaJSON = try? JSONSerialization.data(withJSONObject: meta),
              let metaString = String(data: metaJSON, encoding: .utf8) else { return .failed }

        let boundary = "vortx-tp-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        // sprite file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"sprite\"; filename=\"sprite.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(sprite)
        body.append("\r\n".data(using: .utf8)!)
        // vtt file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"vtt\"; filename=\"index.vtt\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/vtt\r\n\r\n".data(using: .utf8)!)
        body.append(vtt.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        // meta field
        field("meta", metaString)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        req.httpBody = body
        VortXEdgeAuth.sign(&req)   // gated host (trickplay.vortx.tv /tp/<key> POST): stamp X-VX-Ts / X-VX-Sig
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let ok = (obj?["ok"] as? Bool) == true
            let stored = (obj?["stored"] as? Bool) == true
            // Probe the POST so a failed upload (edge-auth sig rejection, 4xx, worker error) is visible with its
            // reason in the terminal log, not just a silent false. Trim the body to the first 200 chars.
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count)B>"
            let bodyHead = String(bodyStr.prefix(200))
            VXProbe.log("tp", "POST \(url.absoluteString) httpStatus=\(code) ok=\(ok ? "true" : "false") stored=\(stored ? "true" : "false") body=\(bodyHead)")
            guard code == 200 else { return .failed }
            if stored { return .stored }
            // 200 but not stored: the Worker accepted the request and consciously declined it. Surface its `reason`
            // (below_coverage_threshold, a keep-fuller race, a frameBounds drop) so the caller logs "rejected", not
            // "failed". Fall back to a generic label if the Worker omitted a machine reason.
            let reason = (obj?["reason"] as? String) ?? "declined"
            return .rejected(reason)
        } catch {
            let errHead = String(String(describing: error).prefix(200))
            VXProbe.log("tp", "POST \(url.absoluteString) httpStatus=err ok=false stored=false body=\(errHead)")
            return .failed
        }
    }
}

// MARK: - Cross-platform image helpers

extension ScrubImage {
    /// A CGImage suitable for cropping/drawing, on both AppKit and UIKit.
    var cgImageForCrop: CGImage? {
        #if canImport(AppKit)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}

extension CGImage {
    /// JPEG-encode a CGImage at the given quality, on both platforms.
    func jpegData(quality: CGFloat) -> Data? {
        #if canImport(AppKit)
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return UIImage(cgImage: self).jpegData(compressionQuality: quality)
        #endif
    }
}
