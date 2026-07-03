#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import AVFoundation

/// Serves the DV-for-MKV streaming remux (`VortXMKVRemuxStream`) to AVPlayer as a `vortxremux://` custom-scheme
/// asset. AVPlayer refuses to load a custom scheme itself, so it hands every content-information + data request
/// to this `AVAssetResourceLoaderDelegate`, which answers them out of the growing `VortXRemuxBuffer`:
///   - The content-information request advertises `video/mp4` and a placeholder large content length, but
///     deliberately does NOT advertise byte-range access (`isByteRangeAccessSupported = false`, forward-only
///     Phase 1) so AVPlayer streams sequentially instead of issuing seeks this linear remux cannot serve. The
///     true length is unknown until the remux finishes; the large placeholder keeps AVPlayer requesting forward
///     without EOF-ing early.
///   - Each data request is served on a background dispatch queue: bytes already produced are handed back
///     immediately; a request that outruns the buffer BLOCKS on the buffer's condition until bytes arrive,
///     the stream finishes (short/empty tail), or it fails (finish the request with an error so the chrome's
///     AVPlayer -> libmpv fallback fires).
///
/// One loader instance backs one playback session. `invalidate()` stops the remux and unblocks any in-flight
/// request. All delegate callbacks are dispatched to a dedicated serial queue set on the resource loader, so
/// the blocking reads never touch the main thread.
final class VortXRemuxResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "vortxremux"

    /// A placeholder content length. We don't know the true remuxed size until the trailer is written, and
    /// a fragmented-MP4 stream is inherently open-ended to AVPlayer. A large finite value lets AVPlayer issue
    /// forward byte-range reads without treating the asset as zero-length or immediately hitting EOF. The
    /// buffer's real EOF (a short read at `atEnd`) is what actually terminates delivery.
    private static let placeholderLength: Int64 = 1 << 42   // ~4 TiB, far past any real movie

    private let stream: VortXMKVRemuxStream
    private let queue = DispatchQueue(label: "vortx.dvremux.loader")
    private var invalidated = false
    private let invalidateLock = NSLock()

    /// Build a loader that will drive `stream`. The caller starts the stream (or we start it lazily on the
    /// first request) and mounts an `AVURLAsset(url:)` whose scheme is `vortxremux`.
    init(stream: VortXMKVRemuxStream) {
        self.stream = stream
        super.init()
    }

    /// Convenience: wrap a debrid URL + headers into a stream + loader + the `vortxremux://` asset URL.
    /// Returns nil if the URL can't be rewritten to the custom scheme.
    static func make(input: URL, headers: [String: String]?) -> (loader: VortXRemuxResourceLoader, assetURL: URL)? {
        guard var comps = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = scheme
        guard let assetURL = comps.url else { return nil }
        let stream = VortXMKVRemuxStream(input: input.absoluteString, headers: headers)
        return (VortXRemuxResourceLoader(stream: stream), assetURL)
    }

    /// Begin remuxing. Call once before / as the asset is mounted.
    func start() { stream.start() }

    /// Stop remuxing and unblock any waiting data request. Idempotent.
    func invalidate() {
        invalidateLock.lock()
        let already = invalidated
        invalidated = true
        invalidateLock.unlock()
        guard !already else { return }
        stream.cancel()
    }

    private var isInvalidated: Bool {
        invalidateLock.lock(); defer { invalidateLock.unlock() }; return invalidated
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // Only handle our scheme; anything else, decline so AVFoundation errors normally.
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }

        queue.async { [weak self] in
            self?.serve(loadingRequest)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // The buffer read loop polls `loadingRequest.isCancelled` via the closure below, so cancellation is
        // observed on the next wait tick; nothing extra to do here.
    }

    // MARK: Request servicing (serial loader queue)

    private func serve(_ request: AVAssetResourceLoadingRequest) {
        if let info = request.contentInformationRequest {
            info.contentType = "public.mpeg-4"          // UTI for MP4 (video/mp4)
            // FORWARD-ONLY (Phase 1): advertise NO byte-range access. That makes AVPlayer stream the fragmented
            // MP4 sequentially via a single open-ended request from offset 0 (handled by the loop below) instead
            // of issuing random far-future seeks that this linear remux cannot serve without stalling the loader
            // thread for the whole movie. Real seeking is a documented Phase-2 TODO (needs a seekable input +
            // keyframe-indexed restart). The placeholder length keeps AVPlayer from treating the asset as
            // zero-length / early-EOF; the buffer's real EOF (`atEnd`) is what terminates delivery.
            info.isByteRangeAccessSupported = false
            info.contentLength = Self.placeholderLength
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        let requestedOffset = Int(dataRequest.requestedOffset)
        // requestsAllDataToEndOfResource means "give me everything from offset on"; use a big span.
        let requestedLength = dataRequest.requestsAllDataToEndOfResource
            ? Int.max - requestedOffset
            : dataRequest.requestedLength

        var cursor = requestedOffset
        var remaining = requestedLength

        while remaining > 0 {
            if request.isCancelled || isInvalidated {
                request.finishLoading(with: NSError(domain: "vortx.dvremux", code: -999,
                                                    userInfo: [NSLocalizedDescriptionKey: "cancelled"]))
                return
            }
            let chunk = min(remaining, 1 << 20)    // hand back up to 1 MiB per read to keep memory flat
            let result = stream.buffer.read(offset: cursor, length: chunk, cancelled: { [weak request] in
                request?.isCancelled ?? true
            })
            if let failure = result.failure {
                request.finishLoading(with: NSError(domain: "vortx.dvremux", code: -1,
                                                    userInfo: [NSLocalizedDescriptionKey: failure]))
                return
            }
            if !result.data.isEmpty {
                dataRequest.respond(with: result.data)
                cursor += result.data.count
                remaining -= result.data.count
            }
            if result.atEnd {
                // No more bytes will ever arrive: satisfy the request with what we delivered.
                request.finishLoading()
                return
            }
            // else loop: more bytes are coming, keep filling this request.
        }
        request.finishLoading()
    }
}
#endif
