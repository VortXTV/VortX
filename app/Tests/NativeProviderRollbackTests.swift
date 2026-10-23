import Foundation
import CoreFoundation

private enum CredentialScopeRegistry {
    struct Capture: Equatable { let namespace: String }
}
@MainActor private struct Authority { func capture() -> CredentialScopeRegistry.Capture { .init(namespace: "synthetic.account") } }
private enum VortXSyncCrypto {
    // Encryption is the fixture aperture; upload/verdict/witness/ACK are production code.
    static func sealDocument(dataKey: Data, plaintext: Data, accountId: String, version: Int, writeV2: Bool) -> String? { plaintext.base64EncodedString() }
}
private enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
@MainActor private final class ProviderHarness {
    var stored: Data
    let capture = CredentialScopeRegistry.Capture(namespace: "synthetic.account")
    let actor = "00000000-0000-0000-0000-000000000001"
    var current = true
    var isSignedIn = true
    var isApplyingRemote = false
    var nativePushQueue = NativeForegroundSyncPolicy.PushQueue()
    var nativeDurablePushPending = false
    var pendingNativeMutationPush: CredentialScopeRegistry.Capture?
    var requests = 0
    let credentialAuthority = Authority()
    struct Account { let id = "synthetic.account" }
    var account: Account? = Account()
    var dataKey: Data? = Data([1])
    static let writeSyncDocV2 = false
    var backupUploadFailure: SyncBackupUploadFailure?
    var lastSyncedVersion = 0
    var cloudVersion = 8
    var cloudDocument: [String: Any] = [:]
    var loseResponse = false
    var sentWitnesses: [Int] = []
    init(_ state: VortxNativeProviderCredentials) throws { stored = try state.encoded() }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { current && capture == self.capture }
    func nativeProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials {
        guard isCurrent(capture) else { throw VortxNativeError.superseded }
        return try VortxNativeProviderCredentials(scope: capture.namespace, actor: actor, sealed: stored)
    }
    func saveNativeProviderState(_ state: VortxNativeProviderCredentials, capture: CredentialScopeRegistry.Capture) throws {
        guard isCurrent(capture) else { throw VortxNativeError.superseded }
        stored = try state.encoded()
    }
    /// Production `requestSyncSoon(progressOnly:)` shape; a provider commit is never progress-only.
    var progressOnlyRequests = 0
    func requestSyncSoon(progressOnly: Bool = false) { requests += 1; if progressOnly { progressOnlyRequests += 1 } }
    func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { false }
    func rememberNativeBackup(capture: CredentialScopeRegistry.Capture) -> Bool { true }
    func persistLastSyncedVersion() {}
    func stampSyncSuccess() {}
    static func markSawDocV2(_ accountID: String) { preconditionFailure("v2 disabled") }
    static func documentVersion(_ raw: Any?) -> Int? { raw as? Int }
    func request(_ method: String, _ path: String, body: [String: Any], auth: Bool,
                 credentialCapture: CredentialScopeRegistry.Capture) async -> (Int, [String: Any]?) {
        precondition(method == "PUT" && path == "/v1/backup" && auth)
        let base = body["baseRevision"] as! Int
        let version = body["version"] as! Int
        sentWitnesses.append(base)
        guard base == cloudVersion && version == base + 1 else { return (200, ["accepted": false, "version": cloudVersion]) }
        cloudDocument = try! JSONSerialization.jsonObject(with: Data(base64Encoded: body["document"] as! String)!) as! [String: Any]
        cloudVersion = version
        return loseResponse ? (0, nil) : (200, ["accepted": true])
    }
    func publishRepair() async throws -> Bool {
        guard nativeDurablePushPending else { return false }
        // Synthetic relay GET binds this candidate to its head; the following carrier writes
        // and complete PUT/verdict method are extracted from production without substitution.
        let base = cloudVersion
        var doc = cloudDocument
        let providers = try mergedNativeProviderState(doc, capture: capture)
        /* PRODUCTION_PROVIDER_EXPORT */
        let generation = nativePushQueue.generation
        let outcome = await pushSyncDocAt(doc, version: base + 1, baseRevision: base, credentialCapture: capture)
        guard case .accepted = outcome else { return false }
        nativePushQueue.acknowledge(generation, accepted: true)
        if !nativePushQueue.hasPendingPush { nativeDurablePushPending = false }
        return true
    }
    func apply(_ doc: [String: Any]) throws -> [String: Any] {
        var providers = try mergedNativeProviderState(doc, capture: capture)
        /* PRODUCTION_PROVIDER_PULL_JOIN */
        return try mirrorNativeProviderKeys(providers, original: doc["apiKeys"])
    }
    /* PRODUCTION_PROVIDER_METHODS */
}

@main @MainActor private enum ProviderChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL \(label)"); exit(1) }; print("PASS \(label)")
    }
    static func wire(_ state: VortxNativeProviderCredentials) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.document))
    }
    static func exactLocal(_ state: VortxNativeProviderCredentials) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state.local)
    }
    static func checkOpaqueCredentialConflicts(scope: String, actor: String) throws {
        let precomposed = "\u{00E9}", decomposed = "e\u{0301}"
        expect(precomposed == decomposed && !precomposed.utf8.elementsEqual(decomposed.utf8),
               "fixture distinguishes canonical String equality from opaque credential bytes")
        var left = try VortxNativeProviderCredentials(scope: scope, actor: actor)
        var right = try VortxNativeProviderCredentials(scope: scope, actor: actor)
        try left.edit(["tmdb": .string(precomposed)])
        try right.edit(["tmdb": .string(decomposed)])
        let leftBefore = try exactLocal(left), rightBefore = try exactLocal(right)
        try left.merge(left.document)
        let identical = try exactLocal(left)
        expect(identical == leftBefore, "byte-identical same-stamp credential is idempotent")
        let aliasHarness = try ProviderHarness(left)
        let storedBefore = aliasHarness.stored
        for nested in [false, true] {
            var keys: [String: Any] = ["tmdb": nested ? precomposed : decomposed]
            if nested { keys["metadata"] = ["tmdb": decomposed] }
            var refused = false
            do { _ = try aliasHarness.apply(["nativeProviderCredentials": try wire(left), "apiKeys": keys]) }
            catch { refused = true }
            expect(refused && aliasHarness.stored == storedBefore && !aliasHarness.nativeDurablePushPending && aliasHarness.requests == 0,
                   nested ? "nested credential alias requires exact bytes without mutation or repair"
                          : "top-level credential alias requires exact bytes without mutation or repair")
        }
        let exactAliases = try aliasHarness.apply(["nativeProviderCredentials": try wire(left),
            "apiKeys": ["tmdb": precomposed, "metadata": ["tmdb": precomposed], "future": ["keep": true]]])
        let exactAlias = exactAliases["tmdb"] as! String
        expect(exactAlias.utf8.elementsEqual(precomposed.utf8) && exactAliases["future"] != nil && aliasHarness.requests == 0,
               "matching opaque credential aliases retain unknown siblings and do not echo")
        var rejected = false
        do { try left.merge(right.document) } catch { rejected = true }
        let leftAfter = try exactLocal(left)
        expect(rejected && leftAfter == leftBefore,
               "same-stamp NFC to NFD contradiction rejects without changing document, counter or pending")
        rejected = false
        do { try right.merge(left.document) } catch { rejected = true }
        let rightAfter = try exactLocal(right)
        expect(rejected && rightAfter == rightBefore, "same-stamp NFD to NFC contradiction also preserves all local bytes")
        var cleared = try VortxNativeProviderCredentials(scope: scope, actor: actor)
        try cleared.edit(["tmdb": .null])
        rejected = false
        do { try left.merge(cleared.document) } catch { rejected = true }
        let afterClearConflict = try exactLocal(left)
        expect(rejected && afterClearConflict == leftBefore, "same-stamp null and value remain a rejected contradiction")
        try right.edit(["tmdb": .string(decomposed)])
        try left.merge(right.document)
        let newer = left.mirror(into: [:])["tmdb"]!
        expect(newer.utf8.elementsEqual(decomposed.utf8) && left.local.pending.isEmpty,
               "genuinely newer register preserves exact credential bytes and supersedes only older pending event")
    }
    static func main() async throws {
        let scope = "synthetic.account"
        let actorA = "00000000-0000-0000-0000-000000000001"
        let actorC = "00000000-0000-0000-0000-000000000003"
        try checkOpaqueCredentialConflicts(scope: scope, actor: actorA)
        var warm = try VortxNativeProviderCredentials(scope: scope, actor: actorA)
        try warm.edit(["tmdb": .string("synthetic-old")])
        let old = warm
        warm.acknowledge(warm.local.document.fields)
        try warm.edit(["tmdb": .string("synthetic-new")])
        warm.acknowledge(warm.local.document.fields)
        expect(warm.local.pending.isEmpty, "fixture begins with an already-ACKed provider-only edit")
        let harness = try ProviderHarness(warm)
        let sameNative: [String: Any] = ["opaque": "unchanged-native"]
        let sameHost: [String: Any] = ["opaque": "unchanged-host"]
        let stale: [String: Any] = ["nativeSync": sameNative, "nativeHostPreferences": sameHost,
            "nativeProviderCredentials": try wire(old), "apiKeys": ["tmdb": "synthetic-old", "futureKeys": ["keep": true]]]
        harness.isApplyingRemote = true
        let keys = try harness.apply(stale)
        expect(keys["tmdb"] as? String == "synthetic-new" && keys["futureKeys"] != nil, "joined provider and opaque key sibling survive consistent stale rollback")
        expect(harness.nativeDurablePushPending && harness.nativePushQueue.hasPendingPush && harness.pendingNativeMutationPush == harness.capture,
               "provider-only difference immediately schedules durable repair despite native/host equality and suppression")
        let stateAfter = try harness.nativeProviderState(capture: harness.capture)
        expect(stateAfter.local.pending.isEmpty, "repair does not fabricate a new credential edit")
        // Reopen the retained secure bytes and persisted repair admission after a dropped response.
        let reopenedState = try VortxNativeProviderCredentials(scope: scope, actor: actorA, sealed: harness.stored)
        let reopened = try ProviderHarness(reopenedState)
        reopened.nativeDurablePushPending = harness.nativeDurablePushPending
        reopened.nativePushQueue.request()
        reopened.cloudDocument = stale
        let generation = harness.nativePushQueue.generation
        harness.nativePushQueue.acknowledge(generation, accepted: false)
        expect(harness.nativePushQueue.hasPendingPush && reopened.nativeDurablePushPending,
               "lost upload response and process reopen retain repair admission")
        reopened.loseResponse = true
        let ambiguous = try await reopened.publishRepair()
        expect(!ambiguous && reopened.nativeDurablePushPending && reopened.lastSyncedVersion == 0,
               "actual accepted PUT with lost response leaves durable repair unacknowledged")
        reopened.cloudDocument["concurrentSibling"] = "retained"; reopened.cloudVersion += 1
        reopened.loseResponse = false
        let uploaded = try await reopened.publishRepair()
        expect(uploaded && !reopened.nativeDurablePushPending && reopened.sentWitnesses == [8, 10],
               "actual repair PUT rereads after ambiguous delivery and acknowledges only its exact base")
        let readback = reopened.cloudDocument
        let readbackProvider = try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: readback["nativeProviderCredentials"]!))
        var cold = try VortxNativeProviderCredentials(scope: scope, actor: actorC)
        try cold.merge(readbackProvider)
        expect(cold.mirror(into: [:])["tmdb"] == "synthetic-new" && readback["concurrentSibling"] as? String == "retained",
               "accepted cloud readback restores cold third peer while retaining concurrent sibling")
        let equal = try ProviderHarness(reopenedState)
        _ = try equal.apply(["nativeProviderCredentials": try wire(reopenedState), "apiKeys": ["tmdb": "synthetic-new"]])
        expect(!equal.nativeDurablePushPending && equal.requests == 0, "equal provider carrier does not echo-upload")
        var cleared = warm; try cleared.edit(["tmdb": .null]); cleared.acknowledge(cleared.local.document.fields)
        let clearHarness = try ProviderHarness(cleared)
        let clearKeys = try clearHarness.apply(stale)
        expect(clearHarness.nativeDurablePushPending && clearKeys["tmdb"] == nil, "acknowledged provider clear also repairs rollback without resurrection")
        expect(clearHarness.requests > 0 && clearHarness.progressOnlyRequests == 0,
               "a provider repair wakes an ordinary upload, never the playback-progress window")
        let invalid = try ProviderHarness(warm)
        do {
            _ = try invalid.apply(["nativeProviderCredentials": try wire(old), "apiKeys": ["tmdb": "different-from-register"]])
            preconditionFailure("mismatched mirror accepted")
        } catch {}
        expect(!invalid.nativeDurablePushPending, "invalid carrier/mirror cannot manufacture repair admission")
        invalid.current = false
        do { _ = try invalid.apply(stale); preconditionFailure("retired owner applied") } catch {}
        expect(!invalid.nativeDurablePushPending, "retired credential scope cannot queue repair")
    }
}
