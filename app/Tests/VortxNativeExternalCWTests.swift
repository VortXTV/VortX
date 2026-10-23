import Foundation
import XCTest

/// Production Read + FIFO primitive; injected response/metadata transport only.
/// No native ABI, provider, credential, filesystem, account or device verification is implied.
@MainActor
final class VortxNativeExternalCWTests: XCTestCase {
    private final class Source: VortxMutationAuthority, @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        func revoke() { lock.withLock { active = false } }
        func withActive(_ operation: () throws -> Void) throws {
            try lock.withLock {
                guard active else { throw VortxNativeError.superseded }; try operation()
            }
        }
    }
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
        func release() { open = true; let old = waiters; waiters = []; old.forEach { $0.resume() } }
    }
    private final class Fixture: @unchecked Sendable {
        let lock = NSRecursiveLock(), source = Source()
        let fifo: VortxNativeFIFOAdmission
        private var receipt = UUID()
        private var resolves = 0
        init() { fifo = .init(lock: lock) }
        func changeMetadata() { lock.withLock { receipt = UUID() } }
        func calls() -> Int { lock.withLock { resolves } }
        func read(started: Gate? = nil, release: Gate? = nil) throws -> VortxNativeExternalCW.Read {
            let original = try fifo.capture(source: source) {}
            return .init(original: original, metadataCurrent: { [self] held in
                lock.withLock { held.allSatisfy { $0.receipt == receipt } }
            }, prepare: { [self] id in
                let captured = lock.withLock { receipt }
                if let started { await started.release() }
                if let release { await release.wait() }
                return .init(id: id, type: "series", videos: [.init(id: "opaque-unit", season: 1, episode: 2)], receipt: captured)
            }, resolve: { [self] candidates in
                lock.withLock { resolves += 1 }
                return .init(verdicts: candidates.map { .init(key: $0.key, disposition: .eligible, reason: "clear") },
                             authority: original)
            })
        }
    }
    private func candidate(video: String = "opaque-unit") -> VortxNativeExternalCW.Candidate {
        .init(key: "key", type: "series", metaId: "show", videoId: video,
              titleSpellings: ["show"], season: 1, episode: 2)
    }
    func testPreparedOpaqueMetadataIsRequiredBeforeAnyKernelQuery() async throws {
        let fixture = Fixture(), read = try fixture.read()
        do { _ = try await read.query([candidate()]); XCTFail("unprepared") } catch {}
        XCTAssertEqual(fixture.calls(), 0)
        _ = try await read.prepareMetadata(id: "show")
        let result = try await read.query([candidate()])
        XCTAssertEqual(result.first?.disposition, .eligible)
        XCTAssertEqual(fixture.calls(), 1)
        do { _ = try await read.query([candidate(video: "show:1:2")]); XCTFail("invented ID") } catch {}
        XCTAssertEqual(fixture.calls(), 1)
    }
    func testQueuedNativeIntentDuringMetadataAwaitRejectsEvenAfterSettling() async throws {
        let fixture = Fixture(), started = Gate(), release = Gate()
        let read = try fixture.read(started: started, release: release)
        let task = Task { try await read.prepareMetadata(id: "show") }
        await started.wait()
        let member = try fixture.fifo.admit(); try member.begin(); member.finish()
        await release.release()
        do { _ = try await task.value; XCTFail("stale source") } catch {}
        XCTAssertFalse(read.isCurrent()); XCTAssertEqual(fixture.calls(), 0)
    }
    func testCredentialRetirementAndMetadataABAStayRetired() async throws {
        let fixture = Fixture(), read = try fixture.read()
        _ = try await read.prepareMetadata(id: "show")
        fixture.changeMetadata(); fixture.changeMetadata()
        XCTAssertFalse(read.isCurrent())
        do { _ = try await read.prepareMetadata(id: "other"); XCTFail("recapture") } catch {}
        let replacement = try fixture.read()
        fixture.source.revoke()
        XCTAssertFalse(replacement.isCurrent())
    }
    func testCancellationRetiresOriginalWhileMetadataTransportIgnoresCancellation() async throws {
        let fixture = Fixture(), started = Gate(), release = Gate()
        let read = try fixture.read(started: started, release: release)
        let task = Task { try await read.prepareMetadata(id: "show") }
        await started.wait(); task.cancel()
        XCTAssertFalse(read.isCurrent())
        await release.release()
        do { _ = try await task.value; XCTFail("cancelled") } catch {}
        XCTAssertEqual(fixture.calls(), 0)
    }
    func testMetadataPreparationHasOneBoundedAdmissionPerTitle() async throws {
        let fixture = Fixture(), read = try fixture.read()
        for index in 0..<16 { _ = try await read.prepareMetadata(id: "show-\(index)") }
        do { _ = try await read.prepareMetadata(id: "show-16"); XCTFail("budget") } catch {}
        do { _ = try await read.prepareMetadata(id: "show-0"); XCTFail("duplicate") } catch {}
    }
    func testDecoderRejectsWrongProfileDuplicateKeysAndUnknownEligibility() throws {
        let c = candidate()
        for raw in [
            #"{"kind":"external_cw_eligibility","profileId":"other","verdicts":[{"key":"key","disposition":"eligible","reason":"clear"}]}"#,
            #"{"kind":"external_cw_eligibility","profileId":"profile","verdicts":[{"key":"wrong","disposition":"eligible","reason":"clear"}]}"#,
            #"{"kind":"external_cw_eligibility","profileId":"profile","verdicts":[{"key":"key","disposition":"eligible","reason":"unknown"}]}"#,
            #"{"kind":"external_cw_eligibility","profileId":"profile","verdicts":[{"key":"key","disposition":"future","reason":"clear"}]}"#
        ] { XCTAssertThrowsError(try VortxNativeExternalCW.decode(raw, profileID: "profile", candidates: [c])) }
    }
    func testOpaqueMetadataSpellingMustMatchBytesNotCanonicalStringEquality() async throws {
        let fixture = Fixture(), read = try fixture.read()
        _ = try await read.prepareMetadata(id: "\u{00e9}")
        let changed = VortxNativeExternalCW.Candidate(key: "key", type: "series", metaId: "e\u{0301}",
            videoId: "opaque-unit", titleSpellings: ["e\u{0301}"], season: 1, episode: 2)
        do { _ = try await read.query([changed]); XCTFail("canonical equality substituted an opaque title") } catch {}
        XCTAssertEqual(fixture.calls(), 0)
    }
}
