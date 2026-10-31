// RECOVERY PROPOSAL ONLY. UNRUN in this session.
// Future focused harness: swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors
// -D TRICKPLAY_E2E_POLICY_TESTING -parse-as-library CommunityTrickplay.swift
// TrickplayUploadPolicy.swift TrickplayDurableExportTests.swift -o <approved-output>
// Invoke with one disposable fixture directory under the canonical VortX recovery tree.
// These data-only tests deliberately use synthetic bytes: no image decoder, live cache, player or network.
import Foundation
import CryptoKit

@main
enum TrickplayDurableExportTests {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func key(_ context: TrickplayCaptureContext) -> String? {
        let raw = "\(context.imdb):\(context.season ?? 0):\(context.episode ?? 0):\(Int(floor(context.realDuration / 10) * 10))"
        return Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func context(setID: UUID = UUID(), duration: Double = 100.625,
                                interval: Double = 10, season: Int? = 3, episode: Int? = 22) -> TrickplayCaptureContext {
        let raw = "tt1234567:\(season ?? 0):\(episode ?? 0):\(Int(floor(duration / 10) * 10))"
        let k = Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return TrickplayCaptureContext(setID: setID, communityKey: k, imdb: "tt1234567", season: season,
            episode: episode, realDuration: duration, nominalInterval: interval)
    }
    private struct Fixture {
        let directory: URL
        let media = "synthetic:v2:episode"
        var disk: TrickplayFrameDiskStore { TrickplayFrameDiskStore(directory: directory) }
        init(root: URL, name: String) throws {
            directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ time: Double, context: TrickplayCaptureContext, byte: UInt8 = 0x31) throws {
            let bucket = Int(floor(time / 2)), data = Data(repeating: byte, count: 128)
            let receipt = TrickplayCaptureReceipt(context: context,
                frameNameSHA256: sha(Data(disk.captureFrameName(mediaKey: media, bucket: bucket).utf8)),
                bucket: bucket, captureTime: time, jpegBytes: data.count, jpegSHA256: sha(data),
                mediaKeySHA256: sha(Data(media.utf8)))!
            try disk.write(data, mediaKey: media, bucket: bucket, captureReceipt: receipt,
                permitsCaptureReceipt: { true })
        }
        func select(_ expected: TrickplayCaptureContext, entryLimit: Int = 8192,
                    frameLimit: Int = 600, jpegByteLimit: Int = 64 * 1024 * 1024,
                    shouldContinue: () -> Bool = { true }) -> TrickplayDurableExportSnapshot? {
            disk.exportSnapshot(mediaKey: media, matching: expected, sha256: sha, communityKey: key,
                entryLimit: entryLimit, frameLimit: frameLimit, jpegByteLimit: jpegByteLimit,
                shouldContinue: shouldContinue)
        }
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        func read(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    }

    @MainActor static func main() throws {
        let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let a = context(), b = context()
        let valid = try Fixture(root: fixtureRoot, name: "valid")
        try valid.write(1.375, context: a); try valid.write(11.875, context: a)
        let snapshot = valid.select(a)!
        expect(snapshot.frames.map { $0.receipt.captureTime } == [1.375, 11.875],
            "exact request times survive; never reconstruct from two-second filenames")
        expect(snapshot.frames.allSatisfy { !$0.receipt.completeTimeline }, "export never asserts a complete timeline")
        expect(snapshot.context.setID == a.setID, "one immutable set is selected")
        let restarted = TrickplayFrameDiskStore(directory: valid.directory)
        expect(restarted.exportSnapshot(mediaKey: valid.media, matching: a, sha256: sha,
            communityKey: key, shouldContinue: { true })?.frames.count == 2,
            "fresh store admits actual persisted V2 bytes after restart")

        let legacy = try Fixture(root: fixtureRoot, name: "legacy")
        try legacy.disk.write(Data(repeating: 0x42, count: 128), mediaKey: legacy.media, bucket: 5)
        expect(legacy.select(a) == nil, "a JPEG filename supplies no timestamp, duration or cut provenance")
        expect(legacy.exists(legacy.disk.captureFrameName(mediaKey: legacy.media, bucket: 5)), "legacy retained")

        let mixed = try Fixture(root: fixtureRoot, name: "separate-sets")
        try mixed.write(1, context: a); try mixed.write(11, context: a)
        try mixed.write(41, context: b); try mixed.write(51, context: b); try mixed.write(61, context: b)
        let selected = mixed.select(a)!
        expect(selected.frames.count == 3 && selected.context.setID == b.setID,
            "choose one fuller set without merging independently captured mounts")
        expect(Set(selected.frames.map { $0.receipt.context.setID }).count == 1, "cross-set merge forbidden")

        let changed = try Fixture(root: fixtureRoot, name: "changed")
        try changed.write(1, context: a); try changed.write(11, context: a)
        let before = changed.select(a)!
        try changed.write(1, context: a, byte: 0x55)
        changed.disk.reclaim(before, permits: { true })
        expect(changed.exists(before.frames[0].frameName) && changed.exists(before.frames[1].frameName),
            "one newer bucket blocks the whole reclaim preflight")
        let afterChanged = changed.select(a)!
        expect(afterChanged.frames[0].jpeg != before.frames[0].jpeg, "newer capture preserved")

        let aba = try Fixture(root: fixtureRoot, name: "aba")
        try aba.write(1, context: a); try aba.write(11, context: a)
        let abaBefore = aba.select(a)!
        try aba.write(1, context: a, byte: 0x72); try aba.write(1, context: a, byte: 0x31)
        aba.disk.reclaim(abaBefore, permits: { true })
        expect(aba.exists(abaBefore.frames[0].frameName), "same JPEG bytes with new frameID are an ABA replacement")

        let noHeader = try Fixture(root: fixtureRoot, name: "missing-header")
        try noHeader.write(1, context: a); try noHeader.write(11, context: a)
        let missing = noHeader.select(a)!
        try FileManager.default.removeItem(at: noHeader.directory.appendingPathComponent(missing.headerName))
        expect(noHeader.select(a) == nil, "partial V2 set without immutable header fails closed")

        let tampered = try Fixture(root: fixtureRoot, name: "tampered-jpeg")
        try tampered.write(1, context: a); try tampered.write(11, context: a)
        let tamperedSnapshot = tampered.select(a)!
        try Data(repeating: 0x61, count: 128).write(to: tampered.directory.appendingPathComponent(tamperedSnapshot.frames[0].frameName))
        expect(tampered.select(a) == nil, "same-size JPEG hash mismatch fails closed")

        let partial = try Fixture(root: fixtureRoot, name: "partial-json")
        try partial.write(1, context: a); try partial.write(11, context: a)
        let partialSnapshot = partial.select(a)!
        try Data("{\"schema\":1".utf8).write(to: partial.directory.appendingPathComponent(partialSnapshot.frames[0].receiptName))
        expect(partial.select(a) == nil, "partially written metadata never yields a partial export")

        expect(valid.select(context(duration: 100.875)) == nil,
            "different exact native duration in the same ten-second cloud bucket is not interchangeable")
        expect(valid.select(context(interval: 20)) == nil, "nominal capture interval must match")
        expect(valid.select(context(episode: 23)) == nil, "episode mismatch fails closed")
        expect(valid.select(a, frameLimit: 1) == nil, "testing cannot weaken buildable lower or production upper bounds")
        expect(mixed.select(a, frameLimit: 4) == nil, "overlimit snapshots are rejected rather than truncated or merged")
        expect(valid.select(a, jpegByteLimit: 255) == nil, "total JPEG allocation is bounded before publication")
        expect(valid.select(a, entryLimit: 2) == nil, "directory enumeration is bounded independently of candidate count")
        var remaining = 3
        expect(valid.select(a, shouldContinue: { remaining -= 1; return remaining > 0 }) == nil,
            "cancellation during scan never publishes a snapshot")

        var claims = TrickplayDurableExportClaims()
        expect(claims.begin(snapshot), "first exporter owns process-local pins")
        expect(!claims.begin(selected), "concurrent exporter cannot claim an overlapping or second set")
        expect(snapshot.filenames.isSubset(of: claims.pinned), "pruner pins cover JPEGs, receipts and header")
        expect(claims.permitsReclaim(snapshot.id), "exact current claim may reclaim after external verification")
        claims.willWrite([snapshot.frames[0].frameName])
        expect(!claims.permitsReclaim(snapshot.id), "serial writer invalidates reclaim before a same-name write")
        claims.release(UUID())
        expect(claims.activeID == snapshot.id, "stale cancellation cannot release another owner's pins")
        claims.release(snapshot.id)
        expect(claims.pinned.isEmpty && claims.begin(selected), "cancellation or failure releases pins for the successor")
        claims.release(snapshot.id)
        expect(claims.activeID == selected.id, "A -> B -> A stale release cannot clear successor claim")
        let restartedClaims = TrickplayDurableExportClaims()
        expect(restartedClaims.activeID == nil && restartedClaims.pinned.isEmpty, "no permanent disk lock after restart")

        let retained = try Fixture(root: fixtureRoot, name: "consent-cancel")
        try retained.write(1, context: a); try retained.write(11, context: a)
        let retainedSnapshot = retained.select(a)!
        retained.disk.reclaim(retainedSnapshot, permits: { false })
        expect(retainedSnapshot.filenames.allSatisfy { retained.exists($0) }, "consent revoked before reclaim retains every file")
        var gates = 0
        retained.disk.reclaim(retainedSnapshot, permits: { gates += 1; return gates <= 1 })
        expect(retainedSnapshot.filenames.allSatisfy { retained.exists($0) }, "cancellation at first delete boundary retains files")
        retained.disk.reclaim(retainedSnapshot, permits: { true })
        expect(retainedSnapshot.filenames.allSatisfy { !retained.exists($0) }, "exact unchanged pair and now-orphan header reclaimed")

        let headerKept = try Fixture(root: fixtureRoot, name: "header-with-newer-receipt")
        try headerKept.write(1, context: a); try headerKept.write(11, context: a)
        let older = headerKept.select(a)!
        try headerKept.write(21, context: a)
        headerKept.disk.reclaim(older, permits: { true })
        expect(headerKept.exists(older.headerName), "set header stays while any newer receipt remains")
        expect(headerKept.exists(headerKept.disk.captureFrameName(mediaKey: headerKept.media, bucket: 10)),
            "unclaimed newer bucket is never reclaimed")

        let times = [1.375, 11.875, 71.25, 81.5]
        let vtt = TrickplayTimeline.makeVTT(captureTimes: times, nominalInterval: 10, cols: 2, tileW: 320, tileH: 180)!
        let cues = TrickplayTimeline.parseVTT(vtt, frameCount: 4, cols: 2, tileW: 320, tileH: 180)!
        expect(cues[1].end == 21.875 && cues[2].start == 71.25, "seek gap fence survives readback witness")
        let witness = TrickplayDurableReadbackWitness(key: a.communityKey, frameCount: 4, cols: 2,
            tileW: 320, tileH: 180, interval: 10, spriteSHA256: "sprite-hash", vttSHA256: sha(Data(vtt.utf8)), cues: cues)
        func matches(key: String? = nil, count: Int = 4, width: Int = 640, interval: Double = 10,
                     spriteHash: String = "sprite-hash", vttHash: String? = nil,
                     downloadedCues: [TrickplayTimelineCue]? = nil) -> Bool {
            witness.matches(requestedKey: key ?? a.communityKey, frameCount: count, cols: 2, tileW: 320,
                tileH: 180, interval: interval, spriteWidth: width, spriteHeight: 360,
                spriteSHA256: spriteHash, vttSHA256: vttHash ?? sha(Data(vtt.utf8)), cues: downloadedCues ?? cues)
        }
        expect(matches(), "exact generated assets, timing, metadata and dimensions validate")
        expect(!matches(key: String(repeating: "a", count: 40)), "exact metadata request key required")
        expect(!matches(count: 3), "keep-fuller or different frame count is insufficient")
        expect(!matches(width: 641), "geometry changes retain local files")
        expect(!matches(interval: 20), "metadata interval must match builder output")
        expect(!matches(spriteHash: "different"), "HTTP 200 sprite without exact byte hash is insufficient")
        expect(!matches(vttHash: "different"), "semantically plausible but byte-different VTT is insufficient")
        let noGap = TrickplayTimeline.makeCues(captureTimes: times, nominalInterval: 100, cols: 2, tileW: 320, tileH: 180)!
        expect(!matches(downloadedCues: noGap), "VTT that bridges the retained seek gap is rejected")
        let endpoint = URL(string: "https://trickplay.vortx.tv")!
        expect(TrickplayDurableReadbackWitness.workerAsset("https://trickplay.vortx.tv/r2/sprites/opaque.jpg", endpoint: endpoint, kind: .sprite) != nil,
            "observed opaque Worker sprite route need not embed the community key")
        expect(TrickplayDurableReadbackWitness.workerAsset("https://trickplay.vortx.tv/r2/vtt/opaque.vtt?sig=synthetic", endpoint: endpoint, kind: .vtt) != nil,
            "same-origin advertised signed URL may be used only in memory")
        for bad in ["https://other.example/r2/sprites/opaque.jpg", "http://trickplay.vortx.tv/r2/sprites/opaque.jpg",
                    "https://u:p@trickplay.vortx.tv/r2/sprites/opaque.jpg", "https://trickplay.vortx.tv/r2/sprites/opaque.jpg#fragment",
                    "https://trickplay.vortx.tv/unknown/opaque.jpg", "https://trickplay.vortx.tv/r2/sprites/a%2fb.jpg"] {
            expect(TrickplayDurableReadbackWitness.workerAsset(bad, endpoint: endpoint, kind: .sprite) == nil,
                "unknown, cross-origin, ambiguous or credential-bearing asset route fails closed")
        }
        print("TrickplayDurableExportTests: \(checks) checks passed")
    }
}
