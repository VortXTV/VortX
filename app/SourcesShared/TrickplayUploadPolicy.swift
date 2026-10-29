import Foundation
import CryptoKit

/// One initial cloud lookup and two quiet retries per exact content key. Player clock calls may consult
/// this policy, but never create overlapping requests or a retry timer. The store's epoch owns completion.
struct TrickplayCommunityFetchPolicy {
    private var attempts = 0
    private var inFlight = false
    private var retryAfter = 0.0

    mutating func begin(now: Double) -> Bool {
        guard now.isFinite, !inFlight, attempts < 3, now >= retryAfter else { return false }
        attempts += 1
        inFlight = true
        return true
    }

    mutating func finish(now: Double, succeeded: Bool) {
        guard inFlight else { return }
        inFlight = false
        retryAfter = succeeded ? .infinity : now + (attempts == 1 ? 30 : 120)
    }

    mutating func reset() { self = Self() }
}

/// Bounds missing-runtime fallback work independently of the 2–4 Hz player clock. The caller cancels
/// the old task on identity change; failed lookups may retry only after a quiet interval.
struct TrickplayRuntimeLookupGate {
    struct Claim: Equatable { let key: String; let generation: UInt64 }
    private var key: String?
    private var generation: UInt64 = 0
    private var inFlight = false
    private var retryAfter = 0.0

    mutating func begin(key: String, now: Double) -> Claim? {
        if self.key != key { self.key = key; inFlight = false; retryAfter = 0 }
        guard !inFlight, now >= retryAfter else { return nil }
        generation &+= 1
        inFlight = true
        return Claim(key: key, generation: generation)
    }

    mutating func finish(_ claim: Claim, now: Double, succeeded: Bool) {
        guard key == claim.key, generation == claim.generation else { return }
        inFlight = false
        retryAfter = succeeded ? .infinity : now + 30
    }

    mutating func cancel() {
        generation &+= 1
        key = nil; inFlight = false; retryAfter = 0
    }
}

/// Local-preview capture follows the same configured playback-time cadence that
/// community coverage and VTT metadata advertise. Frame-drop diagnostics are
/// deliberately absent: telemetry must never disable capture.
///
/// `presentationReady` is a SEPARATE, non-telemetry gate (report item 8: the diagnosed output-drop bursts
/// coincide with trickplay captures run at 0/10/20s, before the display has finished settling). It answers
/// "has the presentation pipeline been stable long enough for a capture to be safe", derived only from
/// elapsed time and the HDMI display-mode-switch state - never from a frame-drop count - so it does not
/// reopen the deliberately-rejected feedback loop above. Defaults to `true` so every other call site (and
/// the existing tests) is unaffected.
struct TrickplayCaptureCadencePolicy {
    static func shouldCapture(
        playbackTime: Double,
        lastCaptureTime: Double,
        intervalSeconds: Double,
        playbackActive: Bool,
        isScrubbing: Bool,
        captureInFlight: Bool,
        presentationReady: Bool = true
    ) -> Bool {
        guard playbackTime.isFinite,
              lastCaptureTime.isFinite,
              intervalSeconds.isFinite,
              intervalSeconds > 0,
              playbackTime > 0,
              playbackActive,
              !isScrubbing,
              !captureInFlight,
              presentationReady else { return false }
        let elapsed = playbackTime - lastCaptureTime
        return elapsed <= -intervalSeconds || elapsed >= intervalSeconds
    }
}

/// Separates the local renderer capture decision from remote/provider preview availability. UHD HDR local
/// grabs can extend the renderer's drawable-acquire work, while a provider sprite sheet has no such cost.
/// Unknown or unprobed media is deliberately non-UHD here, so it fails open to the ordinary local path.
struct TrickplayLocalCaptureEligibilityPolicy {
    /// The renderer path that services a local preview request. libmpv's capture
    /// runs inline with its drawable/present work; AVPlayer's video output pulls
    /// an already-decoded pixel buffer instead. They therefore cannot share the
    /// same UHD HDR safety rule.
    enum CaptureBackend: Equatable, Sendable {
        case libmpvInlineDrawable
        case avPlayerVideoOutput
    }

    enum DynamicRange: Equatable, Sendable {
        case dolbyVision
        case hdr10
        case hlg
        case hdr
        case sdr
        case unknown

        var isHDR: Bool {
            switch self {
            case .dolbyVision, .hdr10, .hlg, .hdr:
                return true
            case .sdr, .unknown:
                return false
            }
        }
    }

    struct Input: Equatable, Sendable {
        let isUltraHighDefinition: Bool
        let dynamicRange: DynamicRange
        let captureBackend: CaptureBackend

        /// Preserve the former conservative behavior until each caller declares
        /// its backend. An omitted backend is treated as the inline libmpv path,
        /// never as the lower-cost AVPlayer pull path.
        init(
            isUltraHighDefinition: Bool,
            dynamicRange: DynamicRange,
            captureBackend: CaptureBackend = .libmpvInlineDrawable
        ) {
            self.isUltraHighDefinition = isUltraHighDefinition
            self.dynamicRange = dynamicRange
            self.captureBackend = captureBackend
        }
    }

    struct Decision: Equatable, Sendable {
        let isUltraHighDefinitionHDR: Bool
        let permitsLocalCapture: Bool
        let permitsRemoteProviderPreviews: Bool
        let captureBackend: CaptureBackend
    }

    static func decision(_ input: Input) -> Decision {
        let isUltraHighDefinitionHDR = input.isUltraHighDefinition && input.dynamicRange.isHDR
        return .init(
            isUltraHighDefinitionHDR: isUltraHighDefinitionHDR,
            permitsLocalCapture: !isUltraHighDefinitionHDR || input.captureBackend == .avPlayerVideoOutput,
            permitsRemoteProviderPreviews: true,
            captureBackend: input.captureBackend
        )
    }
}

/// First-frame + display-settle readiness for trickplay capture (report item 8). The libmpv frame grab
/// scales the drawable INLINE on mpv's VO thread (`MetalLayer.nextDrawable`, right before the very next
/// present), so a capture request that lands during a display-mode renegotiation or in the first seconds of
/// a new renderer generation extends exactly the drawable wait the diagnosed bursts show. Withholding
/// capture until both gates clear keeps every capture's GPU work outside that window without having to move
/// the scale off the VO thread. UHD HDR/DV content gets the longer threshold: it is both the most expensive
/// frame to scale and the specific case the diagnostic log ties to a drop burst.
enum TrickplayPresentationReadinessPolicy {
    static let defaultSettleSeconds: Double = 5
    static let uhdHDRSettleSeconds: Double = 30

    static func isReady(
        elapsedSinceFirstFrame: Double?,
        displaySwitchSettled: Bool,
        isUltraHighDefinitionHDR: Bool
    ) -> Bool {
        guard displaySwitchSettled,
              let elapsedSinceFirstFrame, elapsedSinceFirstFrame.isFinite else {
            return false
        }
        let threshold = isUltraHighDefinitionHDR ? uhdHDRSettleSeconds : defaultSettleSeconds
        return elapsedSinceFirstFrame >= threshold
    }
}

/// Community lookup and local capture are useful with an estimated runtime,
/// but a community POST is keyed by a duration bucket. Keep that publication
/// boundary explicit and testable so a provisional key can never escape into
/// the shared pool.
enum TrickplayCommunityUploadEligibilityPolicy {
    static func permitsUpload(
        communityEnabled: Bool,
        hasRealDuration: Bool
    ) -> Bool {
        communityEnabled && hasRealDuration
    }
}

/// A physical engine or source remount keeps the same stable media key and must
/// retain all local, community, and session capture state. Only a true media or
/// episode-timeline key change starts a fresh capture session.
enum TrickplayCaptureSessionPolicy {
    enum Transition: Equatable {
        case preserve
        case reset
    }

    static func transition(
        from currentMediaKey: String?,
        to nextMediaKey: String?
    ) -> Transition {
        currentMediaKey == nextMediaKey ? .preserve : .reset
    }
}

/// One cancellation lease per scrub owner. The frame cache is shared, so cancellation
/// must stay local to the requesting store rather than retiring independent consumers.
final class TrickplayLocalReadLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Only an attributed native duration event can supply durable capture provenance. A UI/catalog
/// duration never enters this value. The source includes the engine's physical mount at the caller.
struct TrickplayCaptureDurationEvidence<Source: Equatable> {
    private var source: Source?
    private var seconds: Double?

    mutating func observe(_ seconds: Double, source: Source) {
        guard seconds.isFinite, seconds > 0, seconds <= TrickplayCaptureContext.maximumDuration else { return }
        self.source = source
        self.seconds = seconds
    }

    func duration(for source: Source) -> Double? {
        self.source == source ? seconds : nil
    }
}

/// Immutable header for one source/mount's captured timeline. The opaque set receipt is minted only
/// after the caller accepts that source and matches its own native duration event. No URL, token,
/// account, filesystem path or native object identity is serialized.
struct TrickplayCaptureContext: Codable, Equatable, Sendable {
    static let maximumDuration: Double = 7 * 24 * 3600
    let setID: UUID
    let communityKey: String
    let imdb: String
    let season: Int?
    let episode: Int?
    let realDuration: Double
    let nominalInterval: Double

    var isValid: Bool {
        Self.hex(communityKey, count: 40)
            && imdb.range(of: #"^tt[0-9]{6,20}$"#, options: .regularExpression) != nil
            && [season, episode].allSatisfy { $0.map { (0...100_000).contains($0) } ?? true }
            && realDuration.isFinite && realDuration >= 10 && realDuration <= Self.maximumDuration
            && nominalInterval.isFinite && (2...60).contains(nominalInterval)
    }

    static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// A self-contained frame receipt, paired with the existing JPEG by its full byte and filename hashes.
/// The reversible legacy filename stays out of metadata because custom media IDs may contain secrets. Times retain
/// the exact CapturedFrame input; they are explicitly player-request times, not renderer frame PTS.
/// Receipts do not assert full coverage. A future export must validate every JPEG and header before
/// constructing a timestamped sprite, and must use the original builder's coverage/gap rules.
struct TrickplayCaptureReceipt: Codable, Equatable, Sendable {
    static let maximumJSONBytes = 16 * 1024
    static let maximumJPEGBytes = 2 * 1024 * 1024
    let schema: Int
    let context: TrickplayCaptureContext
    let frameID: UUID
    let frameNameSHA256: String
    let bucket: Int
    let captureTime: Double
    let jpegBytes: Int
    let jpegSHA256: String
    let mediaKeySHA256: String
    let timestampBasis: String
    let durationBasis: String
    let sourceReceiptKind: String
    let completeTimeline: Bool

    init?(context: TrickplayCaptureContext, frameID: UUID = UUID(), frameNameSHA256: String,
          bucket: Int, captureTime: Double, jpegBytes: Int, jpegSHA256: String,
          mediaKeySHA256: String) {
        schema = 1
        self.context = context; self.frameID = frameID; self.frameNameSHA256 = frameNameSHA256
        self.bucket = bucket; self.captureTime = captureTime; self.jpegBytes = jpegBytes
        self.jpegSHA256 = jpegSHA256; self.mediaKeySHA256 = mediaKeySHA256
        timestampBasis = "player_capture_request"
        durationBasis = "owned_native_duration_event"
        sourceReceiptKind = "accepted_native_load_and_mount"
        completeTimeline = false
        guard isValid else { return nil }
    }

    var isValid: Bool {
        schema == 1 && context.isValid && !completeTimeline
            && timestampBasis == "player_capture_request"
            && durationBasis == "owned_native_duration_event"
            && sourceReceiptKind == "accepted_native_load_and_mount"
            && captureTime.isFinite && captureTime >= 0 && captureTime <= context.realDuration
            && bucket >= 0 && bucket == Int(floor(captureTime / 2))
            && (1...Self.maximumJPEGBytes).contains(jpegBytes)
            && TrickplayCaptureContext.hex(jpegSHA256, count: 64)
            && TrickplayCaptureContext.hex(mediaKeySHA256, count: 64)
            && TrickplayCaptureContext.hex(frameNameSHA256, count: 64)
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= maximumJSONBytes,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["schema", "context", "frameID", "frameNameSHA256", "bucket", "captureTime",
                                  "jpegBytes", "jpegSHA256", "mediaKeySHA256", "timestampBasis",
                                  "durationBasis", "sourceReceiptKind", "completeTimeline"],
              let header = fields["context"] as? [String: Any],
              Set(header.keys).isSubset(of: ["setID", "communityKey", "imdb", "season", "episode",
                                             "realDuration", "nominalInterval"]),
              Set(["setID", "communityKey", "imdb", "realDuration", "nominalInterval"]).isSubset(of: Set(header.keys)),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
}

/// Data-only disk seam for local trickplay frames. LocalTrickplayFrameCache owns
/// scheduling and decoded-image memory; this keeps its existing on-disk address
/// stable and lets a fresh cache instance read a prior session's bytes.
struct TrickplayFrameDiskStore {
    let directory: URL

    func write(_ data: Data, mediaKey: String, bucket: Int,
               captureReceipt: TrickplayCaptureReceipt? = nil,
               permitsCaptureReceipt: () -> Bool = { false }) throws {
        let frame = fileURL(mediaKey: mediaKey, bucket: bucket)
        let receiptURL = captureReceiptURL(mediaKey: mediaKey, bucket: bucket)
        // Invalidate the old association BEFORE replacing its JPEG. Any interruption leaves an
        // ordinary local preview, never an old timestamp/source receipt attached to new bytes.
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            try FileManager.default.removeItem(at: receiptURL)
        }
        try data.write(to: frame, options: .atomic)
        guard let receipt = captureReceipt, permitsCaptureReceipt(), receipt.isValid,
              receipt.frameNameSHA256 == Self.filenameSHA256(frame.lastPathComponent), receipt.bucket == bucket,
              receipt.jpegBytes == data.count else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(receipt.context)
        let headerURL = captureHeaderURL(setID: receipt.context.setID)
        if FileManager.default.fileExists(atPath: headerURL.path) {
            guard Self.regularData(headerURL, maximum: TrickplayCaptureReceipt.maximumJSONBytes) == header else {
                throw CaptureWriteError.invalidExistingHeader
            }
        } else {
            try writeCaptureFile(header, to: headerURL, permits: permitsCaptureReceipt)
        }
        let encoded = try encoder.encode(receipt)
        guard encoded.count <= TrickplayCaptureReceipt.maximumJSONBytes,
              permitsCaptureReceipt() else { return }
        try writeCaptureFile(encoded, to: receiptURL, permits: permitsCaptureReceipt)
    }

    /// Durable export admission. Legacy JPEGs alone, partial JSON, missing immutable set headers,
    /// overwritten frames, unknown schemas and a mismatched content/cut key all fail closed.
    func capturedFrame(mediaKey: String, bucket: Int, mediaKeySHA256: String,
                       sha256: (Data) -> String,
                       communityKey: (TrickplayCaptureContext) -> String?) -> (TrickplayCaptureReceipt, Data)? {
        guard let metadata = Self.regularData(captureReceiptURL(mediaKey: mediaKey, bucket: bucket),
                                             maximum: TrickplayCaptureReceipt.maximumJSONBytes),
              let receipt = TrickplayCaptureReceipt.decode(metadata),
              receipt.bucket == bucket, receipt.mediaKeySHA256 == mediaKeySHA256,
              receipt.frameNameSHA256 == Self.filenameSHA256(fileURL(mediaKey: mediaKey, bucket: bucket).lastPathComponent),
              communityKey(receipt.context) == receipt.context.communityKey,
              let jpeg = Self.regularData(fileURL(mediaKey: mediaKey, bucket: bucket),
                                         maximum: TrickplayCaptureReceipt.maximumJPEGBytes),
              jpeg.count == receipt.jpegBytes, sha256(jpeg) == receipt.jpegSHA256 else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let expectedHeader = try? encoder.encode(receipt.context),
              Self.regularData(captureHeaderURL(setID: receipt.context.setID),
                               maximum: TrickplayCaptureReceipt.maximumJSONBytes) == expectedHeader else { return nil }
        return (receipt, jpeg)
    }

    func captureFrameName(mediaKey: String, bucket: Int) -> String {
        fileURL(mediaKey: mediaKey, bucket: bucket).lastPathComponent
    }

    private enum CaptureWriteError: Error { case invalidExistingHeader }

    func captureReceiptName(mediaKey: String, bucket: Int) -> String {
        "frame-\(Self.filenameSHA256(captureFrameName(mediaKey: mediaKey, bucket: bucket))).capture.json"
    }

    private static func filenameSHA256(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func captureReceiptURL(mediaKey: String, bucket: Int) -> URL {
        directory.appendingPathComponent(captureReceiptName(mediaKey: mediaKey, bucket: bucket))
    }

    private func captureHeaderURL(setID: UUID) -> URL {
        directory.appendingPathComponent("set-\(setID.uuidString.lowercased()).capture-set.json")
    }

    private func writeCaptureFile(_ data: Data, to destination: URL, permits: () -> Bool) throws {
        guard permits() else { return }
        // Same-directory publication leaves partial writes unreferenced. Temporary files are ordinary
        // cache files too, so the existing TTL/disk-budget pruner can remove an interrupted temporary.
        let temporary = directory.appendingPathComponent("pending-\(UUID().uuidString.lowercased()).capture.json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard permits() else { return }
        try FileManager.default.moveItem(at: temporary, to: destination)
        if !permits() { try? FileManager.default.removeItem(at: destination) }
    }

    private static func regularData(_ url: URL, maximum: Int) -> Data? {
        guard let before = try? FileManager.default.attributesOfItem(atPath: url.path),
              before[.type] as? FileAttributeType == .typeRegular,
              let size = before[.size] as? NSNumber, size.intValue > 0, size.intValue <= maximum,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximum + 1), data.count == size.intValue,
              data.count <= maximum,
              let after = try? FileManager.default.attributesOfItem(atPath: url.path),
              (before as NSDictionary).isEqual(after as NSDictionary) else { return nil }
        return data
    }

    func data(mediaKey: String, bucket: Int) -> Data? {
        try? Data(contentsOf: fileURL(mediaKey: mediaKey, bucket: bucket))
    }

    /// The stored frame whose bucket is CLOSEST to `targetBucket` in either direction, for this media only.
    /// A last-resort scrub fallback: when no frame sits within the primary at-or-before lookback (a scrub past
    /// what has been captured, or into a gap wider than that window), the nearest captured frame still gives an
    /// approximate preview instead of "unavailable". Enumerates this media's files once; nil when it has none.
    /// Runs off the main thread (called only from the cache's ioQueue).
    func nearest(mediaKey: String, targetBucket: Int,
                 shouldContinue: () -> Bool = { true }) -> (bucket: Int, data: Data)? {
        guard shouldContinue() else { return nil }
        let prefix = filePrefix(mediaKey) + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        var bestBucket: Int?
        var bestDistance = Int.max
        for file in files {
            guard shouldContinue() else { return nil }
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".jpg") else { continue }
            let middle = name.dropFirst(prefix.count).dropLast(4)   // strip "<prefix>-" and ".jpg" -> bucket digits
            guard let bucket = Int(middle) else { continue }
            let distance = abs(bucket - targetBucket)
            if distance < bestDistance || (distance == bestDistance && bucket > (bestBucket ?? -1)) {
                bestDistance = distance; bestBucket = bucket
            }
        }
        guard shouldContinue(), let bestBucket,
              let data = data(mediaKey: mediaKey, bucket: bestBucket) else { return nil }
        return (bestBucket, data)
    }

    private func fileURL(mediaKey: String, bucket: Int) -> URL {
        directory.appendingPathComponent(
            "\(filePrefix(mediaKey))-\(bucket).jpg"
        )
    }

    private func filePrefix(_ mediaKey: String) -> String {
        Data(mediaKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}


/// Future V2 receipts only. This is a bounded, in-memory export snapshot, never a new persisted index.
/// Times remain the original player capture-request times; neither full coverage nor renderer PTS is inferred.
struct TrickplayDurableExportSnapshot: Sendable {
    struct Frame: Sendable {
        let receipt: TrickplayCaptureReceipt
        let jpeg: Data
        let receiptData: Data
        let frameName: String
        let receiptName: String
    }
    let id: UUID
    let context: TrickplayCaptureContext
    let frames: [Frame]
    let headerName: String
    let headerData: Data

    var filenames: Set<String> {
        Set(frames.flatMap { [$0.frameName, $0.receiptName] } + [headerName])
    }
}

/// Queue-confined, process-local pins. Tokens never survive restart and a stale release cannot remove a
/// successor's pins. A same-name store invalidates reclaim even for an A -> B -> A byte sequence.
struct TrickplayDurableExportClaims: Sendable {
    private(set) var activeID: UUID?
    private(set) var pinned: Set<String> = []
    private var invalidated = false

    mutating func begin(_ snapshot: TrickplayDurableExportSnapshot) -> Bool {
        guard activeID == nil else { return false }
        activeID = snapshot.id; pinned = snapshot.filenames; invalidated = false
        return true
    }
    mutating func willWrite(_ names: Set<String>) {
        if !pinned.isDisjoint(with: names) { invalidated = true }
    }
    func permitsReclaim(_ id: UUID) -> Bool { activeID == id && !invalidated }
    mutating func release(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil; pinned = []; invalidated = false
    }
}

extension TrickplayCaptureContext {
    /// Exact native duration and cadence are additional admission evidence beyond the coarse cloud key.
    func hasSameExportIdentity(as other: Self) -> Bool {
        isValid && other.isValid && communityKey == other.communityKey && imdb == other.imdb
            && season == other.season && episode == other.episode
            && realDuration == other.realDuration && nominalInterval == other.nominalInterval
    }
}

extension TrickplayFrameDiskStore {
    static let exportMaximumDirectoryEntries = 8192
    static let exportMaximumFrames = 600
    static let exportMaximumJPEGBytes = 64 * 1024 * 1024

    /// Called only on LocalTrickplayDiskWorker's serial utility queue. Fail closed on a malformed,
    /// partial, overwritten, mismatched or oversized V2 candidate. Legacy JPEGs are never promoted.
    func exportSnapshot(mediaKey: String, matching expected: TrickplayCaptureContext,
                        sha256: (Data) -> String,
                        communityKey: (TrickplayCaptureContext) -> String?,
                        entryLimit: Int = TrickplayFrameDiskStore.exportMaximumDirectoryEntries,
                        frameLimit: Int = TrickplayFrameDiskStore.exportMaximumFrames,
                        jpegByteLimit: Int = TrickplayFrameDiskStore.exportMaximumJPEGBytes,
                        shouldContinue: () -> Bool) -> TrickplayDurableExportSnapshot? {
        var enumerationFailed = false
        guard (1...Self.exportMaximumDirectoryEntries).contains(entryLimit),
              (2...Self.exportMaximumFrames).contains(frameLimit),
              (1...Self.exportMaximumJPEGBytes).contains(jpegByteLimit),
              expected.isValid, shouldContinue(), communityKey(expected) == expected.communityKey,
              let entries = FileManager.default.enumerator(at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                  errorHandler: { _, _ in enumerationFailed = true; return false }) else { return nil }
        let mediaHash = sha256(Data(mediaKey.utf8))
        var groups: [UUID: [TrickplayDurableExportSnapshot.Frame]] = [:]
        var count = 0, frameCount = 0, jpegBytes = 0
        while let url = entries.nextObject() as? URL {
            count += 1
            guard shouldContinue(), count <= entryLimit else { return nil }
            let name = url.lastPathComponent
            guard name.hasPrefix("frame-"), name.hasSuffix(".capture.json") else { continue }
            // Unknown/partial sidecars make selection ambiguous. Leave the cache untouched.
            guard let raw = Self.regularData(url, maximum: TrickplayCaptureReceipt.maximumJSONBytes),
                  let receipt = TrickplayCaptureReceipt.decode(raw) else { return nil }
            guard receipt.mediaKeySHA256 == mediaHash else { continue }
            guard receipt.context.hasSameExportIdentity(as: expected),
                  name == captureReceiptName(mediaKey: mediaKey, bucket: receipt.bucket),
                  let (checked, jpeg) = capturedFrame(mediaKey: mediaKey, bucket: receipt.bucket,
                      mediaKeySHA256: mediaHash, sha256: sha256, communityKey: communityKey),
                  checked == receipt,
                  Self.regularData(url, maximum: TrickplayCaptureReceipt.maximumJSONBytes) == raw else { return nil }
            frameCount += 1; jpegBytes += jpeg.count
            guard frameCount <= frameLimit, jpegBytes <= jpegByteLimit else { return nil }
            let frame = TrickplayDurableExportSnapshot.Frame(receipt: checked, jpeg: jpeg,
                receiptData: raw, frameName: captureFrameName(mediaKey: mediaKey, bucket: checked.bucket),
                receiptName: name)
            groups[receipt.context.setID, default: []].append(frame)
        }
        guard shouldContinue(), !enumerationFailed else { return nil }
        // Never merge mounts/sets. Selection is deterministic and each complete candidate is validated.
        for frames in groups.values {
            guard Set(frames.map { $0.receipt.bucket }).count == frames.count,
                  Set(frames.map { $0.receipt.captureTime }).count == frames.count,
                  Set(frames.map { $0.receipt.frameID }).count == frames.count,
                  let context = frames.first?.receipt.context,
                  frames.allSatisfy({ $0.receipt.context == context }) else { return nil }
        }
        guard let frames = groups.values.sorted(by: {
            if $0.count != $1.count { return $0.count > $1.count }
            return ($0.first?.receipt.context.setID.uuidString ?? "")
                < ($1.first?.receipt.context.setID.uuidString ?? "")
        }).first, frames.count >= 2,
              let context = frames.first?.receipt.context else { return nil }
        let headerName = "set-\(context.setID.uuidString.lowercased()).capture-set.json"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let header = try? encoder.encode(context),
              Self.regularData(directory.appendingPathComponent(headerName),
                  maximum: TrickplayCaptureReceipt.maximumJSONBytes) == header else { return nil }
        return TrickplayDurableExportSnapshot(id: UUID(), context: context,
            frames: frames.sorted { $0.receipt.captureTime < $1.receipt.captureTime },
            headerName: headerName, headerData: header)
    }

    /// Serial with the only supported writer and pruner. Preflight every byte before deleting anything;
    /// then recheck each exact pair and the live permit at its deletion boundary. A partial reclaim is safe:
    /// a crash can leave an unindexed JPEG, which cannot become export input on restart.
    func reclaim(_ snapshot: TrickplayDurableExportSnapshot, permits: () -> Bool) {
        func unchanged(_ frame: TrickplayDurableExportSnapshot.Frame) -> Bool {
            Self.regularData(directory.appendingPathComponent(frame.receiptName),
                maximum: TrickplayCaptureReceipt.maximumJSONBytes) == frame.receiptData
                && Self.regularData(directory.appendingPathComponent(frame.frameName),
                    maximum: TrickplayCaptureReceipt.maximumJPEGBytes) == frame.jpeg
        }
        guard permits(), snapshot.frames.allSatisfy(unchanged),
              Self.regularData(directory.appendingPathComponent(snapshot.headerName),
                  maximum: TrickplayCaptureReceipt.maximumJSONBytes) == snapshot.headerData else { return }
        for frame in snapshot.frames {
            guard permits(), unchanged(frame) else { return }
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(frame.receiptName))
                guard permits(), Self.regularData(directory.appendingPathComponent(frame.frameName),
                    maximum: TrickplayCaptureReceipt.maximumJPEGBytes) == frame.jpeg else { return }
                try FileManager.default.removeItem(at: directory.appendingPathComponent(frame.frameName))
            } catch { return }
        }
        var enumerationFailed = false
        guard permits(), let entries = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { return }
        var count = 0
        while let url = entries.nextObject() as? URL {
            count += 1
            guard permits(), count <= Self.exportMaximumDirectoryEntries else { return }
            let name = url.lastPathComponent
            guard name.hasPrefix("frame-"), name.hasSuffix(".capture.json") else { continue }
            guard let data = Self.regularData(url, maximum: TrickplayCaptureReceipt.maximumJSONBytes),
                  let receipt = TrickplayCaptureReceipt.decode(data),
                  receipt.context.setID != snapshot.context.setID else { return }
        }
        guard permits(), !enumerationFailed, Self.regularData(directory.appendingPathComponent(snapshot.headerName),
            maximum: TrickplayCaptureReceipt.maximumJSONBytes) == snapshot.headerData else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(snapshot.headerName))
    }
}

/// One shared cancellation predicate for every expensive stage of an owned
/// community-upload task. The task that owns the policy is the same task that
/// composes, encodes, and posts, so cancellation remains observable throughout.
enum TrickplayOwnedWorkGate {
    static func permitsStage(taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled
    }
}

/// Per accepted media load circuit breaker for local frame grabs. Remote/community previews remain
/// available; this only stops repeatedly asking a renderer that has proven it cannot supply a frame.
struct TrickplayLocalCaptureBreaker: Equatable, Sendable {
    private(set) var consecutiveNilCaptures = 0
    private(set) var isOpen = false
    static let nilCaptureLimit = 3

    mutating func reset() {
        consecutiveNilCaptures = 0
        isOpen = false
    }

    /// Returns true exactly once, when the breaker opens.
    mutating func recordCapture(hadData: Bool) -> Bool {
        if hadData {
            reset()
            return false
        }
        guard !isOpen else { return false }
        consecutiveNilCaptures += 1
        if consecutiveNilCaptures >= Self.nilCaptureLimit {
            isOpen = true
            return true
        }
        return false
    }
}

/// Small state machine that keeps community trickplay useful without rebuilding the
/// full sprite sheet every minute. Each exact content key gets one progressive
/// attempt once its capture is storable, plus at most one teardown attempt after a
/// failure, progressive decline, or material coverage growth. A declined progressive
/// remains one-shot; a declined or stored teardown response is final for that key.
struct TrickplayUploadPolicy {
    /// Clock updates repeat the same real duration; only its first confirmation changes upload eligibility.
    /// New captures and content-key changes have their own admission paths.
    static func shouldReconsiderSameKeyDuration(hadRealDuration: Bool, incomingIsReal: Bool) -> Bool {
        incomingIsReal && !hadRealDuration
    }

    enum Kind: Equatable, Sendable {
        case progressive
        case final
    }

    enum Outcome: Equatable, Sendable {
        case stored
        case rejected
        case failed
    }

    struct Claim: Equatable, Hashable, Sendable {
        let key: String
        let sequence: UInt64
        let kind: Kind
        let frameCount: Int
    }

    enum Admission: Equatable, Sendable {
        case start(Claim)
        case deferred(Claim)
    }

    struct Completion: Equatable, Sendable {
        let applied: Bool
        let nextClaim: Claim?
    }

    private struct KeyState {
        var isTerminal = false
        var progressiveAttempted = false
        var finalAttempted = false
        var progressiveStoredFrameCount: Int?
        var progressiveFinalBaselineFrameCount: Int?
    }

    private(set) var key: String?
    private(set) var inFlight: Claim?
    private(set) var deferredFinals: [Claim] = []
    private var states: [String: KeyState] = [:]
    private var nextSequence: UInt64 = 1
    private static let maxDeferredFinals = 2

    var isTerminal: Bool {
        guard let key else { return false }
        return states[key]?.isTerminal ?? false
    }

    var progressiveAttempted: Bool {
        guard let key else { return false }
        return states[key]?.progressiveAttempted ?? false
    }

    var finalAttempted: Bool {
        guard let key else { return false }
        return states[key]?.finalAttempted ?? false
    }

    var progressiveStoredFrameCount: Int? {
        guard let key else { return nil }
        return states[key]?.progressiveStoredFrameCount
    }

    /// Selects the current capture key without destroying admitted work from the
    /// previous key. At most one upload runs and at most two final snapshots wait,
    /// so rapid title changes cannot create an unbounded queue.
    mutating func reset(for key: String?) {
        guard self.key != key else { return }
        self.key = key
        if let key, states[key] == nil {
            states[key] = KeyState()
        }
        pruneRetiredStates()
    }

    mutating func request(
        key: String,
        kind: Kind,
        frameCount: Int,
        existingFrameCount: Int,
        coverageReady: Bool
    ) -> Admission? {
        if self.key != key { reset(for: key) }
        var state = states[key] ?? KeyState()
        guard !state.isTerminal,
              frameCount >= 2,
              frameCount > existingFrameCount,
              coverageReady else { return nil }

        switch kind {
        case .progressive:
            guard inFlight == nil,
                  !state.progressiveAttempted else { return nil }
            state.progressiveAttempted = true
        case .final:
            guard !state.finalAttempted else { return nil }
            if let baseline = state.progressiveFinalBaselineFrameCount {
                let materialGrowth = max(6, baseline / 4)
                guard frameCount >= baseline + materialGrowth else { return nil }
            }
            if inFlight != nil,
               deferredFinals.count >= Self.maxDeferredFinals {
                return nil
            }
            state.finalAttempted = true
        }
        states[key] = state

        let claim = Claim(
            key: key,
            sequence: nextSequence,
            kind: kind,
            frameCount: frameCount
        )
        nextSequence &+= 1
        if inFlight != nil {
            deferredFinals.append(claim)
            return .deferred(claim)
        }
        inFlight = claim
        return .start(claim)
    }

    /// Retires the selected content key in one transition. The final reservation
    /// is made before selection moves to the next content, so callers can snapshot
    /// the old frames without manually racing a separate final request and reset.
    mutating func retireCurrent(
        frameCount: Int,
        existingFrameCount: Int,
        coverageReady: Bool,
        selecting nextKey: String?
    ) -> Admission? {
        guard let retiringKey = key else {
            reset(for: nextKey)
            return nil
        }
        let admission = request(
            key: retiringKey,
            kind: .final,
            frameCount: frameCount,
            existingFrameCount: existingFrameCount,
            coverageReady: coverageReady
        )
        reset(for: nextKey)
        return admission
    }

    /// Applies only the exact active claim. A completion may belong to a retired
    /// key, because admitted old-key work survives a title change. It can start at
    /// most one eligible deferred final; duplicates and superseded completions do
    /// not mutate the current key.
    mutating func complete(_ claim: Claim, outcome: Outcome) -> Completion {
        guard inFlight == claim else {
            return Completion(applied: false, nextClaim: nil)
        }
        inFlight = nil
        var state = states[claim.key] ?? KeyState()
        switch outcome {
        case .stored:
            if claim.kind == .progressive {
                state.progressiveStoredFrameCount = claim.frameCount
                state.progressiveFinalBaselineFrameCount = claim.frameCount
            } else {
                state.isTerminal = true
            }
        case .rejected:
            if claim.kind == .progressive {
                state.progressiveFinalBaselineFrameCount = claim.frameCount
            } else {
                state.isTerminal = true
            }
        case .failed:
            break
        }
        states[claim.key] = state

        let next = dequeueEligibleFinal()
        inFlight = next
        pruneRetiredStates()
        return Completion(applied: true, nextClaim: next)
    }

    private mutating func dequeueEligibleFinal() -> Claim? {
        while !deferredFinals.isEmpty {
            let candidate = deferredFinals.removeFirst()
            guard let state = states[candidate.key],
                  !state.isTerminal else { continue }
            if let baseline = state.progressiveFinalBaselineFrameCount {
                let materialGrowth = max(6, baseline / 4)
                guard candidate.frameCount >= baseline + materialGrowth else {
                    continue
                }
            }
            return candidate
        }
        return nil
    }

    private mutating func pruneRetiredStates() {
        let retained = Set(
            [key, inFlight?.key].compactMap { $0 }
                + deferredFinals.map(\.key)
        )
        states = states.filter { retained.contains($0.key) }
    }
}
