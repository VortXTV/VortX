import Foundation

// The script compiles unchanged production lifecycle clock/scope/default notification observer,
// coalescer, and SourceIndexServeSource request/publication methods. Only surrounding app types,
// identity/rendering, and held successful pooled input are synthetic. No providers, accounts,
// credentials, media, private torrent admission, or installed Core are accessed.
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
protocol ObservableObject: AnyObject {}
struct CoreStream: Sendable { let marker: Int }
enum SourceContributorSettlement: Equatable { case inactive, pending, terminal }
enum SourceIndexContract { static func canonicalContentID(_ value: String) -> String? { value } }
enum SourceIndexIdentity {
    struct PublicationTarget: Equatable, Sendable { let contentID: String }
    typealias TargetResolution = PublicationTarget
    static func validatedTarget(_ value: TargetResolution) -> PublicationTarget? { value }
}
enum AuxiliarySourcePipeline {
    struct Call: Sendable { let resolution: SourceIndexIdentity.TargetResolution }
}
enum MoatConsent { static let contributeAndConsume = true }
enum RemoteConfigDefaults { static let featureSourceIndex = true }
enum RemoteConfig {
    struct Snapshot {
        func isFeatureOn(_ key: String, default value: Bool) -> Bool { value }
    }
    static let snapshot = Snapshot()
    static let sourceIndexFeatureDidInstall = Notification.Name("synthetic.sourceIndex.install")
    static let sourceIndexOldValueKey = "old"
    static let sourceIndexNewValueKey = "new"
}
actor MoatToken {
    static let shared = MoatToken()
    func clear(retiredSessionGeneration: UInt64?, retiredConsentGeneration: UInt64?) {}
}
enum DebridService { case torBox }
struct DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}
@MainActor final class VortXSyncManager {
    static let shared = VortXSyncManager()
    let isSignedIn = true
}
enum SourceIndexClient {
    struct PooledSource: Sendable { let marker: Int }
    struct ServeCapabilities: Sendable {
        let canPlayDirectHTTP: Bool
        let hasUsenet: Bool
        let debridProviders: Set<String>
    }
    enum Event { case refreshPublishSkipped, refreshPublish }
    enum Reason { case staleOrCancelled }
    enum Count { case built, streams }
    static let serveEnabled = true
    static let isEnabled = true
    static func configuredDebridProviders() -> Set<String> { [] }
    static func fetchPooled(contentID: String, isSignedIn: Bool) async -> [PooledSource] { [] }
    static func streams(from rows: [PooledSource], capabilities: ServeCapabilities) -> [CoreStream] {
        rows.map { CoreStream(marker: $0.marker) }
    }
    static func diag(_ event: Event, reason: Reason? = nil, counts: [(Count, Int)]) {}
}
final class LiveServeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    func value() -> Bool { lock.withLock { open } }
    func set(_ value: Bool) { lock.withLock { open = value } }
}
@MainActor final class LiveAccountGate { var open = true }
actor HeldFetch {
    private var continuations: [Int: CheckedContinuation<[SourceIndexClient.PooledSource], Never>] = [:]
    private var calls = 0
    func run() async -> [SourceIndexClient.PooledSource] {
        calls += 1
        let call = calls
        return await withCheckedContinuation { continuations[call] = $0 }
    }
    func count() -> Int { calls }
    func release(_ call: Int, marker: Int) {
        precondition(continuations[call] != nil, "held request must have started")
        continuations.removeValue(forKey: call)?.resume(
            returning: [SourceIndexClient.PooledSource(marker: marker)])
    }
}

@main struct SourceIndexPublicationGenerationTests {
    @MainActor private static var failures = 0
    @MainActor private static let target = AuxiliarySourcePipeline.Call(
        resolution: SourceIndexIdentity.PublicationTarget(contentID: "synthetic-current-page"))

    @MainActor private static func expect(_ condition: Bool, _ name: String) {
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name)")
    }
    @MainActor private static func waitUntil(_ check: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<3_000 {
            if await check() { return true }
            await Task.yield()
        }
        return false
    }
    @MainActor private static func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }
    @MainActor private static func source(
        fetch: HeldFetch, serve: LiveServeGate, account: LiveAccountGate
    ) -> SourceIndexServeSource {
        SourceIndexServeSource(fetchPooled: { _, _ in await fetch.run() },
            serveGate: { serve.value() }, accountGate: { account.open })
    }
    @MainActor private static func announceClose(_ transition: SourceIndexLifecycleTransition) {
        // Exact notification/default observer path; its extra MainActor Task is intentionally delayed
        // until a newer request has begun where the test requires that production interleaving.
        NotificationCenter.default.post(name: RemoteConfig.sourceIndexFeatureDidInstall,
            object: transition, userInfo: [RemoteConfig.sourceIndexOldValueKey: true,
                                         RemoteConfig.sourceIndexNewValueKey: false])
    }
    @MainActor private static func announceReopen() async {
        NotificationCenter.default.post(name: RemoteConfig.sourceIndexFeatureDidInstall,
            object: nil, userInfo: [RemoteConfig.sourceIndexOldValueKey: false,
                                   RemoteConfig.sourceIndexNewValueKey: true])
        await drain()
    }
    @MainActor private static func reset(_ source: SourceIndexServeSource) async {
        source.clearResults()
        await SourceIndexFetchCoalescer.shared.cancelAll()
        await drain()
    }

    @MainActor private static func freshOwnerSurvivesOldAnnouncement() async {
        let transition = SourceIndexLifecycleClock.closeSource()
        let fetch = HeldFetch()
        let source = source(fetch: fetch, serve: LiveServeGate(), account: LiveAccountGate())
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 1 }, "new-generation request starts")
        announceClose(transition)
        await drain()
        expect(await SourceIndexFetchCoalescer.shared.activeCount() == 1,
               "old cutoff preserves new shared request")
        expect(source.publishedTarget != nil, "old cutoff preserves new local owner")
        await fetch.release(1, marker: 27)
        expect(await waitUntil { source.streams.first?.marker == 27 },
               "fresh successful result publishes after delayed old notification")
        expect(source.permitsDetachedPublish(sourceEpoch: source.epoch,
                   lifecycle: SourceIndexLifecycleClock.snapshot(), includedSingularity: true),
               "current owned lifecycle permits detached publication")
        let epoch = source.epoch
        announceClose(transition)
        await drain()
        expect(source.streams.first?.marker == 27 && source.epoch == epoch,
               "repeated old cutoff cannot clear newly published rows")
        await announceReopen()
        await reset(source)
    }

    @MainActor private static func sameTargetReopensBeforeDelayedClose() async {
        let serve = LiveServeGate()
        let fetch = HeldFetch()
        let source = source(fetch: fetch, serve: serve, account: LiveAccountGate())
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 1 }, "retired same-target request starts")
        serve.set(false)
        let transition = SourceIndexLifecycleClock.closeSource()
        serve.set(true)
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 2 },
               "same target receives a new owner when lifecycle changes")
        announceClose(transition)
        await drain()
        expect(await SourceIndexFetchCoalescer.shared.activeCount() == 1,
               "delayed cutoff cancels retired shared request only")
        await fetch.release(1, marker: 13)
        await drain()
        expect(source.streams.isEmpty && source.publishedTarget != nil,
               "late retired result cannot borrow reopened target authority")
        await fetch.release(2, marker: 27)
        expect(await waitUntil { source.streams.first?.marker == 27 },
               "reopened same-target owner publishes only its fresh result")
        await announceReopen()
        await reset(source)
    }

    @MainActor private static func currentOffClosesRetiredOwner() async {
        let serve = LiveServeGate()
        let fetch = HeldFetch()
        let source = source(fetch: fetch, serve: serve, account: LiveAccountGate())
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 1 }, "current-off request starts")
        await fetch.release(1, marker: 11)
        expect(await waitUntil { source.streams.first?.marker == 11 },
               "current-off owner has already-published rows")
        serve.set(false)
        let publishedTransition = SourceIndexLifecycleClock.closeSource()
        serve.set(true)
        expect(!source.permitsDetachedPublish(sourceEpoch: source.epoch,
                   lifecycle: SourceIndexLifecycleClock.snapshot(), includedSingularity: true),
               "retired published rows cannot borrow a reopened lifecycle before cleanup")
        expect(source.permitsDetachedPublish(sourceEpoch: source.epoch,
                   lifecycle: SourceIndexLifecycleClock.snapshot(), includedSingularity: false),
               "ordinary detached snapshots remain allowed without Singularity rows")
        serve.set(false)
        announceClose(publishedTransition)
        expect(await waitUntil { source.streams.isEmpty && source.publishedTarget == nil },
               "current off removes already-published retired rows")
        serve.set(true)
        await announceReopen()
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 2 }, "current-off pending replacement starts")
        serve.set(false)
        let transition = SourceIndexLifecycleClock.closeSource()
        announceClose(transition)
        expect(await waitUntil {
            let active = await SourceIndexFetchCoalescer.shared.activeCount()
            return source.publishedTarget == nil && active == 0
        }, "current off cancels retired owner and shared request")
        await fetch.release(2, marker: 13)
        await drain()
        expect(source.streams.isEmpty, "late response cannot publish while current gate is off")
        source.refresh(call: target, isSignedIn: true)
        await drain()
        expect(await fetch.count() == 2 && source.settlementState(for: target.resolution) == .inactive,
               "off gate admits no replacement request")
        serve.set(true)
        await announceReopen()
        await reset(source)
    }

    @MainActor private static func sessionChangeRejectsLateAccountResult() async {
        let account = LiveAccountGate()
        let fetch = HeldFetch()
        let source = source(fetch: fetch, serve: LiveServeGate(), account: account)
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 1 }, "prior-account request starts")
        let before = SourceIndexLifecycleClock.snapshot()
        account.open = false
        SourceIndexLifecycleScope.shared.sessionWillMutate()
        account.open = true
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 2 }, "new account/session starts a fresh owner")
        expect(SourceIndexLifecycleClock.snapshot().sessionGeneration > before.sessionGeneration,
               "session mutation advances authority before reopened work")
        await fetch.release(1, marker: 13)
        await drain()
        expect(source.streams.isEmpty && source.publishedTarget != nil,
               "prior-account response cannot borrow new account authority")
        await fetch.release(2, marker: 17)
        expect(await waitUntil { source.streams.first?.marker == 17 }, "new account owner publishes")
        await reset(source)
    }

    @MainActor private static func liveGatesStillFenceCompletionAndAdmission() async {
        let serve = LiveServeGate()
        let account = LiveAccountGate()
        let fetch = HeldFetch()
        let source = source(fetch: fetch, serve: serve, account: account)
        source.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 1 }, "live-gate request starts")
        serve.set(false)
        await fetch.release(1, marker: 13)
        _ = await waitUntil { await SourceIndexFetchCoalescer.shared.activeCount() == 0 }
        await drain()
        expect(source.streams.isEmpty && source.settlementState(for: target.resolution) == .inactive,
               "live config/enablement gate rejects successful late completion before announcement")
        source.refresh(call: target, isSignedIn: true)
        expect(source.publishedTarget == nil, "explicit off refresh still clears all local identity")
        serve.set(true)
        source.refresh(call: target, isSignedIn: true)
        account.open = false
        await drain()
        expect(await fetch.count() == 1, "account gate is rechecked at task admission")
        await reset(source)
    }

    @MainActor private static func ordinaryOwnerClearPreservesSharedWaiter() async {
        let fetch = HeldFetch()
        let serve = LiveServeGate()
        let account = LiveAccountGate()
        let cleared = source(fetch: fetch, serve: serve, account: account)
        let live = source(fetch: fetch, serve: serve, account: account)
        cleared.refresh(call: target, isSignedIn: true)
        live.refresh(call: target, isSignedIn: true)
        expect(await waitUntil { await fetch.count() == 1 }, "same-lifecycle owners coalesce one request")
        await drain()
        cleared.clearResults()
        await fetch.release(1, marker: 42)
        expect(await waitUntil { live.streams.first?.marker == 42 },
               "ordinary owner clear does not cancel another current shared waiter")
        expect(cleared.streams.isEmpty && cleared.publishedTarget == nil,
               "explicit clear-all rejects its own late result")
        await reset(cleared)
        await reset(live)
    }

    @MainActor static func main() async {
        _ = SourceIndexLifecycleScope.shared
        await freshOwnerSurvivesOldAnnouncement()
        await sameTargetReopensBeforeDelayedClose()
        await currentOffClosesRetiredOwner()
        await sessionChangeRejectsLateAccountResult()
        await liveGatesStillFenceCompletionAndAdmission()
        await ordinaryOwnerClearPreservesSharedWaiter()
        print("Publication generation failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
