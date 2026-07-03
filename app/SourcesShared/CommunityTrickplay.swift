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
///      scrub previews by cropping the sprite sub-rect for the scrubbed time — so a title brand new to this
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
/// duration-bucket). NEVER an account token, user id, or any PII — none is referenced here.
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

    /// tmdb->imdb map, persisted so each title resolves over the network at most ONCE per install.
    private static let tmdb2ttDefaultsKey = "stremiox.trickplay.tmdb2tt"
    private static var tmdb2ttCache: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: tmdb2ttDefaultsKey) as? [String: String]) ?? [:]
    }()

    /// Synchronous cache lookup: the tt id previously resolved for a raw `tmdb:…` library id, or nil.
    static func cachedIMDbID(for rawId: String) -> String? { tmdb2ttCache[rawId.lowercased()] }

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
        if let hit = tmdb2ttCache[cacheKey] { return hit }
        // "tmdb:693134" (canonical), tolerating "tmdb:movie:693134" / "tmdb:tv:693134".
        let parts = cacheKey.split(separator: ":").map(String.init)
        guard parts.first == "tmdb", let numeric = parts.dropFirst().first(where: { Int($0) != nil }) else { return nil }
        let explicit = parts.contains("tv") ? "tv" : (parts.contains("movie") ? "movie" : nil)
        let order = explicit.map { [$0] } ?? (seriesHint ? ["tv", "movie"] : ["movie", "tv"])
        for media in order {
            if let tt = await fetchExternalIMDbID(media: media, tmdbID: numeric) {
                tmdb2ttCache[cacheKey] = tt
                UserDefaults.standard.set(tmdb2ttCache, forKey: tmdb2ttDefaultsKey)
                NSLog("[trickplay] resolved %@ -> %@ (%@)", rawId, tt, media)
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

    /// Build a sprite-sheet + WEBVTT index from the device's captured frames and POST it (first-writer-wins).
    /// Runs entirely off the main actor. Returns true only if the server stored a NEW set. Never throws.
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
    ) async -> Bool {
        guard isEnabled else { return false }
        let sorted = frames.sorted { $0.time < $1.time }
        // Store even a tiny capture (>=1 frame); the owner asked that even ~5s of coverage be kept + served.
        // Frame bounds come from the RemoteConfig `trickplay.minFrames`/`maxFrames` dials (clamped min 1..10,
        // max 30..600). Baked defaults (min 1, max 600) == the shipping literals, so a null/out-of-range
        // remote value is behaviorally identical to today.
        let frameBounds = RemoteConfig.snapshot.trickplayFrameBounds
        guard sorted.count >= frameBounds.min, sorted.count <= frameBounds.max else { return false }

        // Tile size: 16:9 at 480 wide is the local capture's native shape (480px, aspect-preserved).
        let tileW = 480, tileH = 270
        let cols = Int(ceil(sqrt(Double(sorted.count))))   // roughly square sheet to bound max dimension
        let rows = Int(ceil(Double(sorted.count) / Double(cols)))

        guard let sheetJPEG = renderSheet(frames: sorted, tileW: tileW, tileH: tileH, cols: cols, rows: rows)
        else { return false }
        // Defensive: keep the upload under the worker's 3 MB cap.
        guard sheetJPEG.count <= 3 * 1024 * 1024 else { return false }

        let vtt = buildVTT(frameCount: sorted.count, cols: cols, tileW: tileW, tileH: tileH, intervalS: intervalS)

        let meta: [String: Any] = [
            "imdb": imdbId,
            "season": season ?? 0,
            "episode": episode ?? 0,
            "durationBucket": durationBucket,
            "frame_count": sorted.count,
            "tile_w": tileW,
            "tile_h": tileH,
            "interval_s": intervalS,
            "cols": cols,
            "src_height": srcHeight,
        ]
        return await post(key: key, sprite: sheetJPEG, vtt: vtt, meta: meta)
    }

    /// Compose the frames into one sheet bitmap and JPEG-encode it. Each frame is drawn scaled-to-fill into
    /// its tile cell. Returns nil on any drawing/encoding failure.
    private static func renderSheet(frames: [CapturedFrame], tileW: Int, tileH: Int, cols: Int, rows: Int) -> Data? {
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
        guard let composed = ctx.makeImage() else { return nil }
        return composed.jpegData(quality: 0.7)
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

    /// POST the multipart body. Returns true only on `{ ok:true, stored:true }`. Never throws.
    private static func post(key: String, sprite: Data, vtt: String, meta: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(baseURL)/tp/\(key)"),
              let metaJSON = try? JSONSerialization.data(withJSONObject: meta),
              let metaString = String(data: metaJSON, encoding: .utf8) else { return false }

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
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (obj["stored"] as? Bool) == true
        } catch {
            return false
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
