// Standalone executable coverage for the production prepared handle.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/prepared-remux-handle \
//     app/Sources/Player/VortXPreparedRemuxPolicy.swift \
//     app/Sources/Player/VortXPreparedRemuxHandle.swift \
//     app/Tests/PreparedRemuxHandleTests.swift && /tmp/prepared-remux-handle

import Foundation

enum VortXMKVRemuxStream {
    enum Mode { case dolbyVision, plain }
}

enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) {}
}

final class VortXRemuxHLSServer: @unchecked Sendable {
    enum PreparationReadiness: Sendable {
        case ready(segmentCount: Int, producedBytes: Int, waitMilliseconds: Int)
        case rejected(reason: String)
    }

    private let lock = NSLock()
    private var ready: Bool
    private var adopted = false
    private var invalidated = false
    private(set) var beginCount = 0
    private(set) var adoptCount = 0
    private(set) var invalidateCount = 0
    let readiness: PreparationReadiness
    let port: UInt16 = 18080

    init(ready: Bool, readiness: PreparationReadiness) {
        self.ready = ready
        self.readiness = readiness
    }

    static func make(
        input: URL,
        headers: [String: String]?,
        mode: VortXMKVRemuxStream.Mode,
        startAtSeconds: Double,
        selectedAudioStreamIndex: Int?,
        preferredAudioLanguages: [String]?,
        audioRejectTerms: [String]?
    ) -> (server: VortXRemuxHLSServer, playlistURL: URL)? {
        HandleServerFactory.shared.make()
    }

    func beginPreparation() {
        lock.lock()
        beginCount += 1
        lock.unlock()
    }

    func awaitPreparedReadiness(timeoutSeconds: Double) async -> PreparationReadiness {
        HandleServerFactory.shared.record(timeout: timeoutSeconds)
        return readiness
    }

    var isPreparedForAdoption: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready && !adopted && !invalidated
    }

    func adoptPrepared(
        onStartupTimeout: @escaping @Sendable (VortXRemuxHLSServer) -> Void
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ready, !adopted, !invalidated else { return false }
        adopted = true
        adoptCount += 1
        return true
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return }
        invalidated = true
        invalidateCount += 1
    }

    func withdrawReadiness() {
        lock.lock()
        ready = false
        lock.unlock()
    }
}

final class HandleServerFactory: @unchecked Sendable {
    static let shared = HandleServerFactory()

    private let lock = NSLock()
    private var nextReadiness: VortXRemuxHLSServer.PreparationReadiness =
        .ready(segmentCount: 3, producedBytes: 12_000, waitMilliseconds: 250)
    private var nextReady = true
    private(set) var createCount = 0
    private(set) var lastServer: VortXRemuxHLSServer?
    private(set) var lastTimeout: Double = 0

    func configure(
        ready: Bool,
        readiness: VortXRemuxHLSServer.PreparationReadiness
    ) {
        lock.lock()
        nextReady = ready
        nextReadiness = readiness
        createCount = 0
        lastServer = nil
        lastTimeout = 0
        lock.unlock()
    }

    func make() -> (server: VortXRemuxHLSServer, playlistURL: URL) {
        lock.lock()
        let server = VortXRemuxHLSServer(ready: nextReady, readiness: nextReadiness)
        createCount += 1
        lastServer = server
        lock.unlock()
        return (server, URL(string: "http://127.0.0.1:18080/master.m3u8")!)
    }

    func record(timeout: Double) {
        lock.lock()
        lastTimeout = timeout
        lock.unlock()
    }
}

@main
struct PreparedRemuxHandleTests {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    static func main() async {
        await preparedReceiptAndExactOneShotAdoption()
        await mismatchAndStaleCleanupAreOnceOnly()
        await readinessFailureReturnsNoPreparedHandle()
        await readinessLostBeforeAdoptionFallsBackCold()
        print("")
        print(failed == 0 ? "ALL PASS (\(passed) checks)" : "FAILURES: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }

    private static func owner(_ generation: UInt64 = 11) -> VortXPreparedRemuxOwnerIdentity {
        .init(mediaID: "series:1:2", generation: generation, sourceSignature: "addon/release")
    }

    private static func identity(
        owner: VortXPreparedRemuxOwnerIdentity = owner(),
        url: String = "https://cdn.example/episode.mkv"
    ) -> VortXPreparedRemuxIdentity {
        .init(
            owner: owner,
            input: URL(string: url)!,
            headers: ["Authorization": "Bearer exact"],
            mode: .dolbyVision,
            startAtSeconds: 0,
            selectedAudioStreamIndex: nil,
            preferredAudioLanguages: ["en"],
            audioRejectTerms: ["commentary"])
    }

    private static func prepare() async -> VortXPreparedRemuxHandle? {
        await VortXPreparedRemuxHandle.prepare(
            input: URL(string: "https://cdn.example/episode.mkv")!,
            headers: ["Authorization": "Bearer exact"],
            mode: .dolbyVision,
            ownerIdentity: owner(),
            preferredAudioLanguages: ["en"],
            audioRejectTerms: ["commentary"])
    }

    private static func preparedReceiptAndExactOneShotAdoption() async {
        HandleServerFactory.shared.configure(
            ready: true,
            readiness: .ready(segmentCount: 3, producedBytes: 12_000, waitMilliseconds: 250))
        guard let handle = await prepare(), let server = HandleServerFactory.shared.lastServer else {
            expect(false, "a ready server returns a prepared handle")
            return
        }
        expect(handle.readinessReceipt == .init(
            segmentCount: 3, producedBytes: 12_000, waitMilliseconds: 250),
               "the caller receives the bounded segment-ready receipt")
        expect(HandleServerFactory.shared.lastTimeout > 0
                && HandleServerFactory.shared.lastTimeout <= 3 * 60 * 60,
               "production preparation uses a finite readiness bound")
        expect(HandleServerFactory.shared.createCount == 1 && server.beginCount == 1,
               "preparation creates and begins exactly one server")
        let first = handle.adopt(expectedIdentity: identity(), onStartupTimeout: { _ in })
        if case .adopted(let transport) = first {
            expect(transport.server === server && server.adoptCount == 1,
                   "exact adoption reuses the prepared server without a second create")
        } else {
            expect(false, "exact adoption reuses the prepared server without a second create")
        }
        let second = handle.adopt(expectedIdentity: identity(), onStartupTimeout: { _ in })
        if case .rejected(.alreadyConsumed) = second {
            expect(server.adoptCount == 1 && server.invalidateCount == 0,
                   "the adopted handle cannot mount or clean its server twice")
        } else {
            expect(false, "the adopted handle cannot mount or clean its server twice")
        }
    }

    private static func mismatchAndStaleCleanupAreOnceOnly() async {
        HandleServerFactory.shared.configure(
            ready: true,
            readiness: .ready(segmentCount: 2, producedBytes: 8_000, waitMilliseconds: 100))
        guard let handle = await prepare(), let server = HandleServerFactory.shared.lastServer else {
            expect(false, "mismatch fixture prepares")
            return
        }
        let mismatch = handle.adopt(
            expectedIdentity: identity(url: "https://cdn.example/re-resolved.mkv"),
            onStartupTimeout: { _ in })
        if case .rejected(.identityMismatch) = mismatch {
            handle.abandon(reason: "stale-generation")
            expect(server.adoptCount == 0 && server.invalidateCount == 1,
                   "source mismatch retires the exact prepared server once")
        } else {
            expect(false, "source mismatch retires the exact prepared server once")
        }
    }

    private static func readinessFailureReturnsNoPreparedHandle() async {
        HandleServerFactory.shared.configure(
            ready: false,
            readiness: .rejected(reason: "preparation-readiness-timeout"))
        let handle = await prepare()
        expect(handle == nil && HandleServerFactory.shared.lastServer?.invalidateCount == 1,
               "a non-ready transport is cleaned and never reported as prepared")
    }

    private static func readinessLostBeforeAdoptionFallsBackCold() async {
        HandleServerFactory.shared.configure(
            ready: true,
            readiness: .ready(segmentCount: 2, producedBytes: 8_000, waitMilliseconds: 100))
        guard let handle = await prepare(), let server = HandleServerFactory.shared.lastServer else {
            expect(false, "readiness-loss fixture prepares")
            return
        }
        server.withdrawReadiness()
        let outcome = handle.adopt(expectedIdentity: identity(), onStartupTimeout: { _ in })
        if case .rejected(.notReady) = outcome {
            expect(server.adoptCount == 0 && server.invalidateCount == 1,
                   "skip or failure before adoption takes one cold-load cleanup")
        } else {
            expect(false, "skip or failure before adoption takes one cold-load cleanup")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS  \(message)")
        } else {
            failed += 1
            print("FAIL  \(message)")
        }
    }
}
