import Foundation

// The runner inserts the maintained Foundation-only policy and actual selected caller declarations.
// Engine/transport doubles make suspension and mount admission deterministic; they are not native proof.
// INSERT_POLICY

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

final class Lifecycle: @unchecked Sendable {
    static let shared = Lifecycle()
    let lock = NSLock()
    var session: UInt64 = 1
    var consent: UInt64 = 1
    var allowed = true
    var epoch = UUID()
    func read<T>(_ action: (Lifecycle) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return action(self)
    }
    func revokeConsentAndRegrant() { read { $0.consent &+= 2; $0.allowed = true } }
    func replaceAccountAndReturn() { read { $0.session &+= 2 } }
    func replaceApplicationEpoch() { read { $0.epoch = UUID() } }
}
enum SourceIndexLifecycleClock {
    struct Snapshot { let sessionGeneration: UInt64; let consentGeneration: UInt64 }
    static func snapshot() -> Snapshot {
        Lifecycle.shared.read { .init(sessionGeneration: $0.session, consentGeneration: $0.consent) }
    }
}
enum MoatConsent { static var contributeAndConsume: Bool { Lifecycle.shared.read { $0.allowed } } }
enum LegacyWatchOwnership {
    static func applicationEpochIsCurrent(_ epoch: UUID) -> Bool { Lifecycle.shared.read { $0.epoch == epoch } }
}
struct PlayerLoadToken: Hashable, Sendable { let id = UUID() }
struct Meta { var videoId: String }
@MainActor final class CoreBridge { var ownerAvailable = true; var targetCurrent = true }
struct MutationTarget {
    @MainActor func stillOwnsCurrentContext(core: CoreBridge) -> Bool { core.targetCurrent }
}
struct PlayerSubtitleAlignmentOwner: Sendable {
    let applicationEpoch: UUID
    @MainActor static func capture(core: CoreBridge, target: MutationTarget) -> Self? {
        core.ownerAvailable ? .init(applicationEpoch: Lifecycle.shared.read { $0.epoch }) : nil
    }
}
enum PlayerExternalSubtitleSelectionResult {
    case aligned, selectedWithoutAlignment, failed, superseded, needsStop
    var succeeded: Bool {
        switch self { case .aligned, .selectedWithoutAlignment: true; default: false }
    }
}
@MainActor protocol PlayerEngine: AnyObject {
    var activeLoadToken: PlayerLoadToken? { get }
    var subtitleAlignmentRevision: UInt64? { get }
    func addExternalSubtitle(url: String, title: String, lang: String, completion: ((Bool) -> Void)?)
    func selectLocalExternalSubtitleAutomatically(_ source: PlayerLocalSubtitleSource,
        title: String, lang: String, owner: PlayerSubtitleAlignmentOwner?,
        expectedLoad: PlayerLoadToken, expectedRevision: UInt64,
        completion: @escaping (PlayerExternalSubtitleSelectionResult) -> Void) -> UInt64?
    func cancelAutomaticSubtitleAlignment(ifRequestGeneration: UInt64)
}
// INSERT_PRESENTATION

@MainActor final class VortXSyncManager {
    static let shared = VortXSyncManager()
    var isSignedIn = true
}
enum VXProbe {
    static func log(_ category: String, _ message: String) {}
    static func event(_ category: String, _ message: String) {}
}
enum SubtitlePoolClient {
    struct PooledSubtitle: Sendable {
        let id: Int; let contentKey: String; let lang: String; let format: String; let url: URL
    }
    // INSERT_FENCE
    // INSERT_LEDGER
    @MainActor static func downloadData(_ sub: PooledSubtitle, isSignedIn: Bool) async -> Data? {
        await withCheckedContinuation { TestTransport.pending.append($0) }
    }
    @MainActor static func download(_ sub: PooledSubtitle, isSignedIn: Bool) async -> URL? {
        await Task.yield()
        return URL(fileURLWithPath: "/owned-by-existing-pool-cache.srt")
    }
}
@MainActor enum TestTransport {
    static var pending: [CheckedContinuation<Data?, Never>] = []
    static func finish(_ data: Data?) {
        expect(pending.count == 1, "one suspended pool transport")
        pending.removeFirst().resume(returning: data)
    }
}
@MainActor class MPVMetalViewController: PlayerEngine {
    struct Request {
        let generation: UInt64
        let source: PlayerLocalSubtitleSource
        let load: PlayerLoadToken
        let revision: UInt64
        let completion: (PlayerExternalSubtitleSelectionResult) -> Void
    }
    var activeLoadToken: PlayerLoadToken? = .init()
    var subtitleAlignmentRevision: UInt64? = 1
    var localRequests: [Request] = []
    var manualAdds = 0
    var manualSucceeds = true
    var mounts = 0
    var canceled: Set<UInt64> = []
    func addExternalSubtitle(url: String, title: String, lang: String, completion: ((Bool) -> Void)?) {
        manualAdds += 1; completion?(manualSucceeds)
    }
    func selectLocalExternalSubtitleAutomatically(_ source: PlayerLocalSubtitleSource,
        title: String, lang: String, owner: PlayerSubtitleAlignmentOwner?,
        expectedLoad: PlayerLoadToken, expectedRevision: UInt64,
        completion: @escaping (PlayerExternalSubtitleSelectionResult) -> Void) -> UInt64? {
        guard source.permitsUse(), owner != nil, activeLoadToken == expectedLoad,
              subtitleAlignmentRevision == expectedRevision else { completion(.superseded); return nil }
        subtitleAlignmentRevision = expectedRevision &+ 1
        let generation = expectedRevision &+ 1
        localRequests.append(.init(generation: generation, source: source, load: expectedLoad,
            revision: generation, completion: completion))
        return generation
    }
    func cancelAutomaticSubtitleAlignment(ifRequestGeneration generation: UInt64) { canceled.insert(generation) }
    func attemptMount(_ result: PlayerExternalSubtitleSelectionResult) {
        let request = localRequests.removeFirst()
        guard !canceled.contains(request.generation), request.source.permitsUse(),
              activeLoadToken == request.load, subtitleAlignmentRevision == request.revision else {
            request.completion(.superseded); return
        }
        mounts += 1; request.completion(result)
    }
}
@MainActor final class Coordinator { var player: (any PlayerEngine)? = MPVMetalViewController() }
@MainActor class HarnessState {
    let coordinator = Coordinator()
    let core = CoreBridge()
    let playbackMutationTarget = MutationTarget()
    var communityContentKey: String? = "tt123:1:1"
    var curMeta: Meta? = .init(videoId: "episode-A")
    var subtitleLoadingURL: String?
    var subtitlePresentationEpoch = UUID()
    var subtitleAlignmentPresentation: SubtitleAlignmentPresentationRequest?
    // Task/cancellation storage for the actual shared invalidator. No add-on transport is invoked
    // by this pooled-caller harness; guarded-file/parser code below is production, not a facade.
    var addonSubtitlePreparationTask: Task<Void, Never>?
    var subtitlePoolRequests = SubtitlePoolClient.RequestOwnership()
    var addedPooledIDs: Set<Int> = []
    var subtitleLoadFailed = false
    var panelShowsSubtitleList = false
    var showOptions = false
    var panel: Int? = 1
    var panelRows: [Int] = []
    var subDelay: Double = 0
    var pooledSeededOffset = false
    var subtitleDelayAppliedLoadToken: PlayerLoadToken?
    var notes: [String] = []
    func rows(for panel: Int) -> [Int] { [] }
    func refreshPanelRowsPreservingAccessibilityFocus() {}
    func applyCurrentSubtitleDelayIfReady(force: Bool) {}
    func restoreSubtitleTimingOffsetIfReady() {}
    func pooledLabel(_ sub: SubtitlePoolClient.PooledSubtitle) -> String { sub.lang }
    func langName(_ lang: String) -> String { lang }
    func showEngineNote(_ note: String) { notes.append(note) }
    // INSERT_INVALIDATE
    // INSERT_PUBLICATION
}
// Production PlayerScreen and TVPlayerView are value types. A class receiver here changes
// Swift's escaping-closure capture rules and wrongly rejects their unmodified caller bodies.
// Keep the receiver a struct and share only its state, like the views' reference-backed @State.
@MainActor protocol PooledPicking {
    var state: HarnessState { get }
    func selectPooledSubtitle(_ sub: SubtitlePoolClient.PooledSubtitle, auto: Bool)
}
extension PooledPicking {
    var coordinator: Coordinator { state.coordinator }
    var core: CoreBridge { state.core }
    var playbackMutationTarget: MutationTarget { state.playbackMutationTarget }
    var communityContentKey: String? {
        get { state.communityContentKey }
        nonmutating set { state.communityContentKey = newValue }
    }
    var curMeta: Meta? {
        get { state.curMeta }
        nonmutating set { state.curMeta = newValue }
    }
    var subtitleLoadingURL: String? {
        get { state.subtitleLoadingURL }
        nonmutating set { state.subtitleLoadingURL = newValue }
    }
    var subtitlePresentationEpoch: UUID {
        get { state.subtitlePresentationEpoch }
        nonmutating set { state.subtitlePresentationEpoch = newValue }
    }
    var subtitleAlignmentPresentation: SubtitleAlignmentPresentationRequest? {
        get { state.subtitleAlignmentPresentation }
        nonmutating set { state.subtitleAlignmentPresentation = newValue }
    }
    var subtitlePoolRequests: SubtitlePoolClient.RequestOwnership {
        get { state.subtitlePoolRequests }
        nonmutating set { state.subtitlePoolRequests = newValue }
    }
    var addedPooledIDs: Set<Int> {
        get { state.addedPooledIDs }
        nonmutating set { state.addedPooledIDs = newValue }
    }
    var subtitleLoadFailed: Bool {
        get { state.subtitleLoadFailed }
        nonmutating set { state.subtitleLoadFailed = newValue }
    }
    var panelShowsSubtitleList: Bool { state.panelShowsSubtitleList }
    var showOptions: Bool { state.showOptions }
    var panel: Int? { state.panel }
    var panelRows: [Int] {
        get { state.panelRows }
        nonmutating set { state.panelRows = newValue }
    }
    var subDelay: Double { state.subDelay }
    var pooledSeededOffset: Bool {
        get { state.pooledSeededOffset }
        nonmutating set { state.pooledSeededOffset = newValue }
    }
    var subtitleDelayAppliedLoadToken: PlayerLoadToken? {
        get { state.subtitleDelayAppliedLoadToken }
        nonmutating set { state.subtitleDelayAppliedLoadToken = newValue }
    }
    var notes: [String] { state.notes }
    func rows(for panel: Int) -> [Int] { state.rows(for: panel) }
    func refreshPanelRowsPreservingAccessibilityFocus() { state.refreshPanelRowsPreservingAccessibilityFocus() }
    func applyCurrentSubtitleDelayIfReady(force: Bool) { state.applyCurrentSubtitleDelayIfReady(force: force) }
    func restoreSubtitleTimingOffsetIfReady() { state.restoreSubtitleTimingOffsetIfReady() }
    func pooledLabel(_ sub: SubtitlePoolClient.PooledSubtitle) -> String { state.pooledLabel(sub) }
    func langName(_ lang: String) -> String { state.langName(lang) }
    func showEngineNote(_ note: String) { state.showEngineNote(note) }
    func invalidateSubtitleAlignmentPresentation() { state.invalidateSubtitleAlignmentPresentation() }
    func permitsSubtitlePublication(loadToken: PlayerLoadToken?, videoID: String?, presentationID: UUID) -> Bool {
        state.permitsSubtitlePublication(loadToken: loadToken, videoID: videoID, presentationID: presentationID)
    }
}
@MainActor struct AppleHarness: PooledPicking {
    let state = HarnessState()
    // INSERT_APPLE_CALLERS
}
@MainActor struct TVHarness: PooledPicking {
    let state = HarnessState()
    // INSERT_TV_CALLERS
}
@MainActor func settle(until predicate: () -> Bool) async {
    for _ in 0..<200 {
        if predicate() { return }
        await Task.yield()
    }
    preconditionFailure("caller failed to reach bounded deterministic suspension/settlement")
}
@MainActor func exercise<H: PooledPicking>(_ make: () -> H, label: String) async {
    let subtitle = SubtitlePoolClient.PooledSubtitle(id: 7, contentKey: "tt123:1:1", lang: "en",
        format: "srt", url: URL(string: "https://subtitles.vortx.tv/subs/tt123/7.srt")!)
    let body = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)
    // Actual manual route remains ordinary file selection.
    do {
        let harness = make(); let player = harness.coordinator.player as! MPVMetalViewController
        harness.selectPooledSubtitle(subtitle, auto: false)
        await settle { player.manualAdds == 1 }
        expect(player.localRequests.isEmpty, "manual pool pick must retain ordinary selection")
        expect(harness.addedPooledIDs.contains(7), "manual success bookkeeping")
    }
    // Actual automatic caller passes immutable data and owns its exact engine completion.
    do {
        let harness = make(); let player = harness.coordinator.player as! MPVMetalViewController
        harness.selectPooledSubtitle(subtitle, auto: true)
        await settle { TestTransport.pending.count == 1 }
        var submitted = body
        TestTransport.finish(submitted)
        submitted[submitted.startIndex] = 57
        await settle { player.localRequests.count == 1 }
        expect(player.localRequests[0].source.data == body, "owned Data survives producer mutation")
        expect(player.manualAdds == 0, "automatic caller must not re-enter ordinary download/mount")
        player.attemptMount(.aligned)
        expect(harness.addedPooledIDs.contains(7) && harness.pooledSeededOffset, "aligned outcome and timing bookkeeping")
        expect(harness.subtitleLoadingURL == nil, "automatic success releases loading latch")
    }
    // Unreliable/unsupported reference selects the requested raw subtitle through the same receipt.
    do {
        let harness = make(); let player = harness.coordinator.player as! MPVMetalViewController
        harness.selectPooledSubtitle(subtitle, auto: true)
        await settle { TestTransport.pending.count == 1 }; TestTransport.finish(body)
        await settle { player.localRequests.count == 1 }; player.attemptMount(.selectedWithoutAlignment)
        expect(harness.addedPooledIDs.contains(7) && !harness.pooledSeededOffset, "raw fallback stays ordinary timing")
    }
    // Every original caller admission is exercised across a real async suspension.
    for mutation in 0..<8 {
        let harness = make(); let player = harness.coordinator.player as! MPVMetalViewController
        harness.selectPooledSubtitle(subtitle, auto: true)
        await settle { TestTransport.pending.count == 1 }
        switch mutation {
        case 0: harness.invalidateSubtitleAlignmentPresentation() // Off or another explicit decision.
        case 1: player.subtitleAlignmentRevision = 9 // Manual timing/track change without UI cancellation.
        case 2:
            harness.curMeta = .init(videoId: "episode-B"); player.activeLoadToken = .init()
            harness.curMeta = .init(videoId: "episode-A"); player.activeLoadToken = .init() // A-B-A.
        case 3: harness.coordinator.player = MPVMetalViewController()
        case 4: Lifecycle.shared.revokeConsentAndRegrant() // Boolean consent can return; generation cannot.
        case 5: harness.core.targetCurrent = false
        case 6: Lifecycle.shared.replaceAccountAndReturn()
        default: Lifecycle.shared.replaceApplicationEpoch()
        }
        TestTransport.finish(body)
        await settle { harness.subtitleLoadingURL == nil }
        expect(player.localRequests.isEmpty && player.manualAdds == 0, "stale caller cannot begin a mount: \(mutation)")
        expect(harness.addedPooledIDs.isEmpty && !harness.subtitleLoadFailed && harness.notes.isEmpty,
            "automatic stale decision remains silent: \(mutation)")
    }
    do {
        let harness = make(); let player = harness.coordinator.player as! MPVMetalViewController
        harness.selectPooledSubtitle(subtitle, auto: true)
        await settle { TestTransport.pending.count == 1 }; TestTransport.finish(nil)
        await settle { harness.subtitleLoadingURL == nil }
        expect(player.localRequests.isEmpty && player.manualAdds == 0 && harness.notes.isEmpty
            && !harness.subtitleLoadFailed, "automatic failed body stays silent without an ordinary retry")
    }
    // The actual caller passes a live consent fence to the deferred engine consumer.
    do {
        let harness = make(); let player = harness.coordinator.player as! MPVMetalViewController
        harness.selectPooledSubtitle(subtitle, auto: true)
        await settle { TestTransport.pending.count == 1 }; TestTransport.finish(body)
        await settle { player.localRequests.count == 1 }
        Lifecycle.shared.revokeConsentAndRegrant()
        expect(!player.localRequests[0].source.permitsUse(), "queued byte consumer must see original fence retirement")
        player.attemptMount(.aligned)
        expect(player.mounts == 0 && harness.addedPooledIDs.isEmpty, "revoked queued work cannot mount")
    }
    // Cancel only the original engine request after download; a same-URL successor must survive.
    do {
        let harness = make(); let player = harness.coordinator.player as! MPVMetalViewController
        harness.selectPooledSubtitle(subtitle, auto: true)
        await settle { TestTransport.pending.count == 1 }; TestTransport.finish(body)
        await settle { player.localRequests.count == 1 }
        let generation = player.localRequests[0].generation
        harness.invalidateSubtitleAlignmentPresentation()
        expect(player.canceled.contains(generation), "caller must retain callee's original cancellation token")
        harness.selectPooledSubtitle(subtitle, auto: true)
        await settle { TestTransport.pending.count == 1 }
        let successor = harness.subtitleAlignmentPresentation?.id
        player.attemptMount(.aligned)
        expect(harness.subtitleAlignmentPresentation?.id == successor && harness.subtitleLoadingURL != nil,
            "late canceled completion cannot clear same-URL successor")
        TestTransport.finish(body)
        await settle { player.localRequests.count == 1 }; player.attemptMount(.aligned)
        expect(player.mounts == 1 && harness.addedPooledIDs.contains(7), "successor retains its own authority")
    }
    print("PASS actual \(label) pool callers: route, Data ownership, raw fallback, A-B-A, manual revision, engine, consent, cancellation")
}
@main struct TestMain {
    @MainActor static func main() async {
        let url = URL(string: "https://subtitles.vortx.tv/subs/7.srt")!
        expect(PlayerLocalSubtitleSource(data: Data(), format: "srt", identityURL: url,
            permitsUse: { true }) == nil, "empty body rejected")
        expect(PlayerLocalSubtitleSource(data: Data([1]), format: "html", identityURL: url,
            permitsUse: { true }) == nil, "unsupported body format rejected")
        expect(PlayerLocalSubtitleSource(data: Data([1]), format: "srt",
            identityURL: URL(fileURLWithPath: "/unowned-cache-file.srt"),
            permitsUse: { true }) == nil, "file URL does not mint a remote identity or file ownership")
        expect(PlayerLocalSubtitleSource(data: Data([1]), format: "srt", identityURL: url,
            permitsUse: { false }) == nil, "retired body cannot enter an engine")
        await exercise({ AppleHarness() }, label: "iOS/macOS")
        await exercise({ TVHarness() }, label: "tvOS")
    }
}
