import SwiftUI
#if canImport(UIKit)
import UIKit
public typealias VXPosterImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias VXPosterImage = NSImage
#endif
import ImageIO
import CoreGraphics

/// The single poster / catalog-art byte loader shared by every native Apple surface (iPhone, iPad, Mac,
/// tvOS). It exists because the app was decoding poster bytes ON the main actor and fetching every poster
/// through `URLSession.shared`, whose default `URLCache` is far too small to hold a catalog page. The result
/// was the "half the posters stay blank + the whole app is laggy on open" report: posters thrashed the tiny
/// shared cache (constant re-fetch), competed with trickplay / ratings / sync on the same connection pool,
/// and each decode blocked the main thread while the user scrolled.
///
/// This loader fixes all three:
///   1. A DEDICATED, generously-sized `URLCache` owned only by this loader's session (built once at launch via
///      `configureSharedCache`) so a whole catalog page of poster bytes stays cached across scrolls and
///      relaunches instead of evicting. It never replaces `URLCache.shared`, so unrelated requests (sync,
///      ratings, l10n, config) keep the small system default and are not pulled into the 512 MB poster store.
///   2. A BOUNDED-concurrency gate (`ConcurrencyGate`) so a grid appearing fires a handful of fetches at a
///      time, never hundreds at once (which is what starved individual posters into coming back empty).
///   3. OFF-MAIN decode + downsample via ImageIO, so the main thread never decodes a poster while scrolling.
///
/// A decoded in-memory `NSCache` sits on top so a poster shown in several rails decodes once. Every miss is
/// retried on the next appear (a scroll-away cancel is not a failure), so a transient miss never latches a
/// permanently blank card. Callers keep their own frame / crop / clip; this only returns the decoded image.
enum PosterImageLoader {

    // MARK: dedicated poster URLCache (built once, owned by this loader's session only)

    /// The loader's OWN generously-sized `URLCache`, wired only into `PosterImageLoader.session` below. The
    /// default iOS shared cache is ~4 MB memory / ~20 MB disk, which cannot hold one catalog page of posters,
    /// so `.returnCacheDataElseLoad` re-fetched nearly every poster on every scroll. Sized here to comfortably
    /// hold many pages of poster JPEGs so the cache actually serves them. This deliberately does NOT touch
    /// `URLCache.shared`: replacing the process-wide cache would swallow every unrelated request (sync,
    /// ratings, l10n, config) into this 512 MB poster store. Kept separate so posters get their big cache and
    /// everything else keeps the system default.
    private static let cache: URLCache = {
        // 64 MB memory / 512 MB disk: posters are small JPEGs, so this holds thousands of them and survives
        // relaunch (disk), which is exactly what turns the poster grid from "re-fetch everything" into
        // "serve from cache". Well within the increased-memory entitlement the native targets already carry.
        let memoryCapacity = 64 * 1024 * 1024
        let diskCapacity = 512 * 1024 * 1024
        return URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: "vortx-images")
    }()

    /// Retained for call-site compatibility: forces the dedicated cache + session to build once at launch,
    /// before any image request, so the first poster page is served warm. Idempotent (lazy statics build once).
    static func configureSharedCache() {
        _ = session
        VXProbe.log("poster", "configureSharedCache built dedicated poster cache memory=64MB disk=512MB diskPath=vortx-images")
    }

    /// Privacy: a poster URL can carry a title id (and, for some art sources, signed query params) in its path,
    /// so probe logs only ever record the HOST, never the raw URL. Enough to tell which art source served a
    /// poster without leaking what the user is browsing. Evaluated lazily inside `VXProbe.log`'s autoclosure.
    private static func probeHost(_ urlString: String?) -> String {
        guard let raw = urlString, let host = URL(string: raw)?.host else { return "?" }
        return host
    }

    // MARK: bounded-concurrency image session

    /// A dedicated session for image bytes so poster fetches share a connection pool sized for many small
    /// GETs and do NOT contend with `URLSession.shared` (sync, ratings, trickplay, add-on manifests). Uses the
    /// loader's OWN large `cache` (not `URLCache.shared`) for disk persistence; `.returnCacheDataElseLoad` is
    /// set per request.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    /// Caps how many poster fetches run at once. A grid appearing enqueues dozens of loads; without a cap they
    /// all hit the network simultaneously and starve each other (the blank-poster symptom). 6 in flight keeps
    /// the pipe full without the stampede.
    private actor ConcurrencyGate {
        private let limit: Int
        private var active = 0
        // Waiters are FIFO but keyed by id so a cancelled waiter can be pulled out of the middle of the queue
        // (a scrolled-off cell whose .task is cancelled while still waiting for a permit) without disturbing the
        // others. `order` preserves the hand-off order; `pending` holds the suspended continuations. Each
        // continuation resumes with a Bool: true = permit granted, false = removed by cancellation.
        private var pending: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        private var order: [UInt64] = []
        private var nextID: UInt64 = 0
        init(limit: Int) { self.limit = limit }

        /// Acquire a permit. Returns `true` if a permit was granted, `false` if the caller was cancelled while
        /// waiting (in which case NO permit is held and the caller must not call `release()`). Cancellation-safe:
        /// a cancelled waiter removes itself from the queue and hands its already-counted permit to the next
        /// waiter, so a scroll-away cancel never leaks a permit and slowly starves the grid.
        func acquire() async -> Bool {
            if active < limit { active += 1; return true }
            if Task.isCancelled { return false }
            let id = nextID
            nextID &+= 1
            // Wait for a permit HANDED OFF by release() or pulled by cancelWaiter(); the permit is already
            // counted in `active`, so we must NOT increment again on the grant path (doing so, plus a fresh
            // acquire slipping in during the decrement/resume gap, let `active` exceed `limit` and over-admit
            // loads, the very stampede this gate prevents). The continuation resumes with the outcome exactly
            // once: true = permit held, false = removed by cancellation. Enqueue and removal are actor-
            // serialized, so there is no double-resume.
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    order.append(id)
                    pending[id] = continuation
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }

        func release() {
            // Hand the permit to the next waiter if any (active unchanged - the permit just moves); otherwise
            // free it. `order` may hold ids already removed by cancellation, so skip past those.
            while let id = order.first {
                order.removeFirst()
                if let continuation = pending.removeValue(forKey: id) { continuation.resume(returning: true); return }
            }
            active -= 1
        }

        /// A waiter cancelled while suspended: pull it from the queue and resume it with `false` so it holds no
        /// permit, then hand the place it held in line to the NEXT waiter (or free it). No-op if it was already
        /// granted a permit or already removed (release ran first): its id is gone from `pending`.
        private func cancelWaiter(_ id: UInt64) {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            order.removeAll { $0 == id }
            continuation.resume(returning: false)
            // A suspended waiter holds NO permit: `active` is incremented only on acquire's fast path or by
            // release's hand-off, never on enqueue. So there is nothing to free or hand off here. Calling
            // release() would spuriously drop a permit the waiter never held and drive `active` negative.
        }
    }
    private static let gate = ConcurrencyGate(limit: 6)

    // MARK: decoded-image memory cache

    /// In-memory decoded cache on top of the URLCache (bytes). Keyed by the resolved URL so a poster shown in
    /// several rails decodes once; evicted under memory pressure by `NSCache`.
    private static let memory: NSCache<NSURL, VXPosterImage> = {
        let c = NSCache<NSURL, VXPosterImage>()
        c.countLimit = 500
        return c
    }()

    /// A synchronous decoded-cache peek so a view can paint instantly on a cache hit without a task hop.
    static func cached(_ url: URL) -> VXPosterImage? { memory.object(forKey: url as NSURL) }

    // MARK: load

    /// Load + decode a poster image for `urlString`, off the main thread, bounded, cached. Returns nil on a
    /// real failure OR on cancellation (the caller treats nil-from-cancel as "retry next appear", so a
    /// scroll-away never latches a blank card). `maxPixel` downsamples very large art to a sane on-card size.
    static func load(_ urlString: String?, maxPixel: CGFloat = 900) async -> VXPosterImage? {
        VXProbe.log("poster", "load ENTRY host=\(probeHost(urlString)) maxPixel=\(Int(maxPixel))")
        guard let raw = urlString, !raw.isEmpty, let url = URL(string: raw) else {
            VXProbe.log("poster", "load BAIL bad/empty host=\(probeHost(urlString)) -> nil")
            return nil
        }
        if let hit = memory.object(forKey: url as NSURL) {
            VXProbe.log("poster", "memory-cache HIT host=\(probeHost(raw)) -> returning cached")
            return hit
        }
        VXProbe.log("poster", "memory-cache MISS host=\(probeHost(raw))")

        // A cancelled acquire holds NO permit, so return without releasing (releasing here would free a permit
        // we never took and let `active` drift below zero, over-admitting loads). Only release when granted.
        guard await gate.acquire() else {
            VXProbe.log("poster", "gate ACQUIRE cancelled host=\(probeHost(raw)) -> nil (no permit held)")
            return nil
        }
        VXProbe.log("poster", "gate ACQUIRE granted host=\(probeHost(raw))")
        defer { Task { await gate.release() } }
        // A cancel between acquiring the gate and starting the fetch: bail without a network hit.
        if Task.isCancelled {
            VXProbe.log("poster", "cancelled after gate, before fetch host=\(probeHost(raw)) -> nil-because-cancelled")
            return nil
        }

        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .returnCacheDataElseLoad   // poster art is immutable; prefer the (now large) disk cache
            // Sign via HEADERS (not a query signature) for our gated art hosts (poster.vortx.tv / erdb.vortx.tv):
            // this path owns the URLRequest, and headers are NOT part of the URLCache key, so the large disk
            // cache above stays warm. A query-signed URL would carry a per-second `vts` and change the cache key
            // every second, reintroducing the "re-fetch every poster" thrash this loader exists to fix. No-op
            // (fail-open) for any non-gated host (tmdb / metahub / add-on art) and for an unprovisioned build.
            VortXEdgeAuth.sign(&req)
            let (data, _) = try await session.data(for: req)
            VXProbe.log("poster", "fetch OK host=\(probeHost(raw)) bytes=\(data.count)")
            if Task.isCancelled {
                VXProbe.log("poster", "cancelled after fetch, before decode host=\(probeHost(raw)) -> nil-because-cancelled")
                return nil
            }
            // Decode + downsample OFF the main thread so scrolling never blocks on a poster decode.
            guard let image = decode(data, maxPixel: maxPixel) else {
                VXProbe.log("poster", "decode FAILED host=\(probeHost(raw)) bytes=\(data.count) -> nil-because-failed")
                return nil
            }
            memory.setObject(image, forKey: url as NSURL)
            VXProbe.log("poster", "load SUCCESS host=\(probeHost(raw)) image=\(Int(image.size.width))x\(Int(image.size.height))")
            return image
        } catch {
            VXProbe.log("poster", "fetch ERROR host=\(probeHost(raw)) error=\(error.localizedDescription) -> nil-because-failed (or cancel; caller retries)")
            return nil   // includes URLError.cancelled; the caller retries on the next appear
        }
    }

    // MARK: dominant (average) color for the hero / detail backdrop tint

    /// Cached average colors, keyed by art URL. A tiny class box because NSCache stores objects; bounded
    /// so a long browse session can't grow it without limit (entries are 3 CGFloats, the cap is generous).
    private final class TintBox {
        let red: CGFloat, green: CGFloat, blue: CGFloat
        init(red: CGFloat, green: CGFloat, blue: CGFloat) { (self.red, self.green, self.blue) = (red, green, blue) }
    }
    private static let tintCache: NSCache<NSURL, TintBox> = {
        let c = NSCache<NSURL, TintBox>()
        c.countLimit = 300
        return c
    }()

    /// The average color of the art at `urlString`, for the dynamic hero/detail backdrop tint. CHEAP by
    /// construction: bytes come from the same dedicated poster URLCache (so a backdrop the screen is
    /// already showing re-serves from disk), the decode is ImageIO downsampled to ~32 px, and the average
    /// is read from an 8x8 render of that thumbnail (64 pixels). Returns nil on any miss (no art, fetch or
    /// decode failure, fully transparent image) so every caller keeps its current fixed-gradient fallback.
    /// Never touches the decoded poster `memory` cache (a 32 px thumbnail must not replace a card's image).
    static func averageColor(_ urlString: String?) async -> Color? {
        guard let raw = urlString, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        if let hit = tintCache.object(forKey: url as NSURL) {
            return Color(red: hit.red, green: hit.green, blue: hit.blue)
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad   // art is immutable; the big poster disk cache serves repeats
        VortXEdgeAuth.sign(&req)                      // headers only, so the cache key stays stable (see load())
        guard let (data, _) = try? await session.data(for: req), !Task.isCancelled,
              let image = decode(data, maxPixel: 32) else { return nil }
        #if canImport(UIKit)
        let cg = image.cgImage
        #elseif canImport(AppKit)
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        guard let cg, let tint = averageColor(of: cg) else { return nil }
        tintCache.setObject(TintBox(red: tint.red, green: tint.green, blue: tint.blue), forKey: url as NSURL)
        VXProbe.log("poster", "averageColor host=\(probeHost(raw)) r=\(Int(tint.red * 255)) g=\(Int(tint.green * 255)) b=\(Int(tint.blue * 255))")
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }

    /// Draw the (already tiny) image into an 8x8 RGBA context and average the 64 pixels, alpha-weighted so
    /// transparent regions (logo art) don't drag the tint toward black. nil when everything is transparent.
    private static func averageColor(of cg: CGImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3])
            guard alpha > 0 else { continue }
            // Premultiplied components sum directly; dividing the totals by the alpha total un-premultiplies.
            r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); a += alpha
        }
        guard a > 0 else { return nil }
        return (CGFloat(min(1, r / a)), CGFloat(min(1, g / a)), CGFloat(min(1, b / a)))
    }

    // MARK: off-main ImageIO decode + downsample

    /// Decode `data` to a downsampled image using ImageIO's thumbnail path, which decodes straight to the
    /// target size (cheaper than full-decode-then-resize) and never touches UIKit/AppKit on the main thread.
    private static func decode(_ data: Data, maxPixel: CGFloat) -> VXPosterImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            let fallback = VXPosterImage(data: data)   // fall back to the platform decoder (e.g. a format ImageIO thumbnails oddly)
            VXProbe.log("poster", "decode ImageIO source-create FAILED bytes=\(data.count) -> platform-decoder fallback=\(fallback != nil ? "ok" : "nil")")
            return fallback
        }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ] as [CFString: Any] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            let fallback = VXPosterImage(data: data)
            VXProbe.log("poster", "decode ImageIO thumbnail FAILED bytes=\(data.count) -> platform-decoder fallback=\(fallback != nil ? "ok" : "nil")")
            return fallback
        }
        VXProbe.log("poster", "decode ImageIO ok pixels=\(cg.width)x\(cg.height)")
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}
