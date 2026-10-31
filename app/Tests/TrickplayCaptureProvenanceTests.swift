import Foundation
import CryptoKit

@main
enum TrickplayCaptureProvenanceTests {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func key(_ context: TrickplayCaptureContext) -> String? {
        guard context.isValid else { return nil }
        let bucket = Int(floor(context.realDuration / 10) * 10)
        let raw = "\(context.imdb):\(context.season ?? 0):\(context.episode ?? 0):\(bucket)"
        return Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func context(setID: UUID = UUID(), realDuration: Double = 1000.375) -> TrickplayCaptureContext {
        let raw = "tt1234567:3:22:\(Int(floor(realDuration / 10) * 10))"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return TrickplayCaptureContext(setID: setID, communityKey: digest, imdb: "tt1234567",
            season: 3, episode: 22, realDuration: realDuration, nominalInterval: 10)
    }

    private static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    @MainActor static func main() throws {
        // No image decoder, player, network, live cache, account or real source URL is used.
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let disk = TrickplayFrameDiskStore(directory: directory)
        let media = "v:synthetic:episode"
        let bucket = 6
        let jpeg = Data(repeating: 0x31, count: 128)
        let identity = context()
        let receipt = TrickplayCaptureReceipt(context: identity,
            frameNameSHA256: sha(Data(disk.captureFrameName(mediaKey: media, bucket: bucket).utf8)), bucket: bucket,
            captureTime: 12.875, jpegBytes: jpeg.count, jpegSHA256: sha(jpeg),
            mediaKeySHA256: sha(Data(media.utf8)))!
        let read = {
            disk.capturedFrame(mediaKey: media, bucket: bucket, mediaKeySHA256: sha(Data(media.utf8)),
                               sha256: sha, communityKey: key)
        }
        let frameURL = directory.appendingPathComponent(disk.captureFrameName(mediaKey: media, bucket: bucket))
        let receiptURL = directory.appendingPathComponent(disk.captureReceiptName(mediaKey: media, bucket: bucket))
        let headerURL = directory.appendingPathComponent("set-\(identity.setID.uuidString.lowercased()).capture-set.json")

        struct Source: Equatable { let load: Int; let engine: Int; let mount: Int }
        let a = Source(load: 1, engine: 1, mount: 1)
        let b = Source(load: 2, engine: 1, mount: 1)
        let remounted = Source(load: 1, engine: 1, mount: 2)
        let replacedEngine = Source(load: 1, engine: 2, mount: 1)
        var durations = TrickplayCaptureDurationEvidence<Source>()
        expect(durations.duration(for: a) == nil, "no UI/provisional duration may invent a receipt")
        durations.observe(1000.375, source: a)
        expect(durations.duration(for: a) == 1000.375, "retain the exact native duration")
        expect(durations.duration(for: b) == nil, "different load cannot borrow duration")
        expect(durations.duration(for: remounted) == nil, "same-token physical remount is a new source")
        expect(durations.duration(for: replacedEngine) == nil, "engine replacement cannot borrow duration")
        durations.observe(.nan, source: b)
        durations.observe(-1, source: b)
        durations.observe(.infinity, source: b)
        expect(durations.duration(for: b) == nil, "invalid native values do not become evidence")
        durations.observe(900.25, source: b)
        expect(durations.duration(for: a) == nil, "A-to-B-to-A cannot reuse retired source evidence")
        expect(durations.duration(for: b) == 900.25, "the latest exact source retains its own duration")

        expect(identity.isValid && receipt.isValid, "valid native source context and frame")
        expect(receipt.captureTime == 12.875 && receipt.bucket == 6, "bucket is not substituted for capture time")
        expect(!receipt.completeTimeline, "a captured frame never claims complete timeline coverage")
        expect(receipt.timestampBasis == "player_capture_request", "request timestamp is not fabricated frame PTS")
        expect(TrickplayCaptureReceipt.decode(try json(receipt)) == receipt, "receipt round trip")
        var fields = try JSONSerialization.jsonObject(with: json(receipt)) as! [String: Any]
        fields["url"] = "forbidden"
        expect(TrickplayCaptureReceipt.decode(try JSONSerialization.data(withJSONObject: fields)) == nil,
               "unknown schema/URL field fails closed")
        fields.removeValue(forKey: "url")
        fields["completeTimeline"] = true
        expect(TrickplayCaptureReceipt.decode(try JSONSerialization.data(withJSONObject: fields)) == nil,
               "full coverage cannot be forged")
        expect(TrickplayCaptureReceipt.decode(Data("{".utf8)) == nil, "partial metadata is not exportable")
        expect(TrickplayCaptureReceipt(context: identity, frameNameSHA256: "../frame.jpg", bucket: bucket,
            captureTime: 12.875, jpegBytes: jpeg.count, jpegSHA256: sha(jpeg), mediaKeySHA256: sha(Data(media.utf8))) == nil,
            "the filename binding must be a complete one-way digest")
        expect(TrickplayCaptureReceipt(context: identity, frameNameSHA256: receipt.frameNameSHA256, bucket: bucket,
            captureTime: 14.1, jpegBytes: jpeg.count, jpegSHA256: sha(jpeg), mediaKeySHA256: sha(Data(media.utf8))) == nil,
            "a false bucket/time association is rejected")
        expect(TrickplayCaptureReceipt(context: identity, frameNameSHA256: receipt.frameNameSHA256, bucket: bucket,
            captureTime: 12.875, jpegBytes: jpeg.count, jpegSHA256: "0", mediaKeySHA256: sha(Data(media.utf8))) == nil,
            "partial hash is rejected")

        try disk.write(jpeg, mediaKey: media, bucket: bucket)
        expect(disk.data(mediaKey: media, bucket: bucket) == jpeg, "legacy local preview still works")
        expect(read() == nil, "legacy JPEG alone is not promotable")
        try disk.write(jpeg, mediaKey: media, bucket: bucket, captureReceipt: receipt,
                       permitsCaptureReceipt: { true })
        expect(read()?.0 == receipt && read()?.1 == jpeg, "fresh exact-byte receipt can be recovered")
        expect((try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
               "published receipt is owner-only")
        expect((try FileManager.default.attributesOfItem(atPath: headerURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
               "immutable source header is owner-only")
        expect(disk.capturedFrame(mediaKey: media, bucket: bucket, mediaKeySHA256: String(repeating: "0", count: 64),
                                 sha256: sha, communityKey: key) == nil, "wrong local media identity fails")
        expect(disk.capturedFrame(mediaKey: media, bucket: bucket, mediaKeySHA256: sha(Data(media.utf8)),
                                 sha256: sha, communityKey: { _ in nil }) == nil, "recomputed community key is required")
        try Data(repeating: 0x32, count: jpeg.count).write(to: frameURL, options: .atomic)
        expect(read() == nil, "same-size overwritten JPEG cannot retain old metadata")
        try jpeg.write(to: frameURL, options: .atomic)
        try Data("{".utf8).write(to: receiptURL, options: .atomic)
        expect(read() == nil, "interrupted sidecar fails closed")
        try disk.write(jpeg, mediaKey: media, bucket: bucket, captureReceipt: receipt,
                       permitsCaptureReceipt: { true })
        try FileManager.default.removeItem(at: headerURL)
        expect(read() == nil, "missing immutable set header fails closed")
        try disk.write(jpeg, mediaKey: media, bucket: bucket, captureReceipt: receipt,
                       permitsCaptureReceipt: { true })
        try Data("{}".utf8).write(to: headerURL, options: .atomic)
        expect(read() == nil, "changed set header fails closed")
        do {
            try disk.write(jpeg, mediaKey: media, bucket: bucket, captureReceipt: receipt,
                           permitsCaptureReceipt: { true })
            preconditionFailure("an existing changed header must never be overwritten")
        } catch { }
        expect(read() == nil, "failed publication cannot leave a usable stale pair")
        try FileManager.default.removeItem(at: headerURL)
        try disk.write(jpeg, mediaKey: media, bucket: bucket, captureReceipt: receipt,
                       permitsCaptureReceipt: { true })
        try disk.write(Data(repeating: 0x34, count: 128), mediaKey: media, bucket: bucket)
        expect(!FileManager.default.fileExists(atPath: receiptURL.path), "ordinary replacement invalidates old receipt first")
        expect(read() == nil, "ordinary source cannot inherit a prior capture association")
        try disk.write(jpeg, mediaKey: media, bucket: bucket, captureReceipt: receipt,
                       permitsCaptureReceipt: { false })
        expect(read() == nil, "withdrawn consent/cancelled lease cannot publish a new receipt")
        expect(disk.data(mediaKey: media, bucket: bucket) == jpeg, "local preview is independent of contribution consent")
        // Untrusted add-on video IDs may contain configured URLs. The legacy JPEG path stays the
        // same, but neither its reversible spelling nor the original secret enters durable JSON.
        let sentinel = "PROVENANCE_SENTINEL_58491"
        let secretURL = "https://synthetic-user:\(sentinel)@example.invalid/path?token=\(sentinel)"
        let secretMedia = "v:tt1234567:\(secretURL)"
        let secretFrameName = disk.captureFrameName(mediaKey: secretMedia, bucket: bucket)
        let secretContext = context()
        let privateReceipt = TrickplayCaptureReceipt(context: secretContext,
            frameNameSHA256: sha(Data(secretFrameName.utf8)), bucket: bucket,
            captureTime: 12.875, jpegBytes: jpeg.count, jpegSHA256: sha(jpeg),
            mediaKeySHA256: sha(Data(secretMedia.utf8)))!
        try disk.write(jpeg, mediaKey: secretMedia, bucket: bucket, captureReceipt: privateReceipt,
                       permitsCaptureReceipt: { true })
        let privateReceiptName = disk.captureReceiptName(mediaKey: secretMedia, bucket: bucket)
        let privateReceiptURL = directory.appendingPathComponent(privateReceiptName)
        let privateHeaderURL = directory.appendingPathComponent("set-\(secretContext.setID.uuidString.lowercased()).capture-set.json")
        let receiptText = String(decoding: try Data(contentsOf: privateReceiptURL), as: UTF8.self)
        let headerText = String(decoding: try Data(contentsOf: privateHeaderURL), as: UTF8.self)
        let forbiddenIdentityForms = [secretURL, secretMedia, sentinel, "example.invalid", "synthetic-user",
            secretFrameName, String(secretFrameName.dropLast(6)),
            Data(secretURL.utf8).base64EncodedString(), Data(secretMedia.utf8).base64EncodedString(),
            secretURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
            secretMedia.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!]
        for text in [receiptText, headerText, privateReceiptName, privateHeaderURL.lastPathComponent] {
            expect(forbiddenIdentityForms.allSatisfy { !text.contains($0) },
                   "raw, percent-encoded or reversible base64 URL/token identities stay out of metadata and its filenames")
            expect(!text.contains("frameName\":"), "no reversible filename field is serialized")
        }
        expect(disk.capturedFrame(mediaKey: secretMedia, bucket: bucket,
            mediaKeySHA256: sha(Data(secretMedia.utf8)), sha256: sha, communityKey: key)?.0 == privateReceipt,
            "one-way filename binding preserves the existing local JPEG address")
        let wrongName = TrickplayCaptureReceipt(context: secretContext,
            frameNameSHA256: String(repeating: "0", count: 64), bucket: bucket,
            captureTime: 12.875, jpegBytes: jpeg.count, jpegSHA256: sha(jpeg),
            mediaKeySHA256: sha(Data(secretMedia.utf8)))!
        try disk.write(jpeg, mediaKey: secretMedia, bucket: bucket, captureReceipt: wrongName,
                       permitsCaptureReceipt: { true })
        expect(disk.capturedFrame(mediaKey: secretMedia, bucket: bucket,
            mediaKeySHA256: sha(Data(secretMedia.utf8)), sha256: sha, communityKey: key) == nil,
            "a valid-looking but wrong filename digest cannot publish a pair")
        print("PASS: \(checks) durable capture provenance checks; synthetic data/disposable cache only")
    }
}
