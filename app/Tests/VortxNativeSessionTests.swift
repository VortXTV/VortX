import Foundation
import CryptoKit

private final class SessionABI: VortxRuntimeABI, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt = 0
    private var states: [UInt: String] = [:]
    private var playbackUnavailable = false
    func failPlaybackQueries() { lock.withLock { playbackUnavailable = true } }
    func create(ownerID: String, ownerName: String) -> UInt {
        hydrate("{\"roster\":{\"profiles\":{\"\(ownerID)\":{\"id\":\"\(ownerID)\",\"owner\":true,\"deleted\":false,\"addons\":\"own\"},\"kid\":{\"id\":\"kid\",\"owner\":false,\"addons\":\"share_primary\"}}},\"activeProfileId\":\"\(ownerID)\",\"libraries\":{\"kid\":{},\"\(ownerID)\":{\"watchContexts\":{\"episode\":{\"name\":\"Retain context\",\"durationMs\":1200001}}}}}")
    }
    func hydrate(_ snapshot: String) -> UInt {
        lock.lock(); defer { lock.unlock() }; next += 1; states[next] = snapshot; return next
    }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var state = try? JSONSerialization.jsonObject(with: Data(states[handle]!.utf8)) as? [String: Any],
              let action = try? JSONSerialization.jsonObject(with: Data(action.utf8)) as? [String: Any] else { return nil }
        if action["type"] as? String == "fail" { return "{\"ok\":false}" }
        if action["type"] as? String == "bind_sync_scope" {
            let roster = state["roster"] as! [String: Any]
            let profiles = roster["profiles"] as! [String: [String: Any]]
            let owner = profiles.first { $0.value["owner"] as? Bool == true }!.key
            state["nativeSync"] = ["schemaVersion": 1, "scope": action["scope"]!, "ownerProfileId": owner]
            states[handle] = String(decoding: try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self)
            return "{\"ok\":true}"
        }
        if action["type"] as? String == "switch_profile" { state["activeProfileId"] = action["id"] }
        if action["type"] as? String == "merge_native_sync" {
            guard let incoming = action["document"] as? [String: Any],
                  incoming["scope"] as? String == (state["nativeSync"] as? [String: Any])?["scope"] as? String else { return "{\"ok\":false}" }
            state["nativeSync"] = incoming
        }
        state["fixtureMutation"] = action["value"] ?? now
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { states[handle] = String(decoding: data, as: UTF8.self) }
        return "{\"ok\":true}"
    }
    func resolve(_ handle: UInt, request: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var query = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any] else { return nil }
        if query["kind"] as? String == "installed_addons" { query["addons"] = [] }
        if query["kind"] as? String == "profile_playback" {
            if playbackUnavailable { return "{\"kind\":\"error\"}" }
            query["continueWatching"] = [["metaId": "unsaved-series", "videoId": "opaque-video", "name": "In progress", "type": "series", "offsetMs": 120001, "durationMs": 1200001, "updatedAt": 1700000000, "watched": false, "timesWatched": 0]]
            query["history"] = [["metaId": "watched-movie", "name": "Watched movie", "type": "movie", "offsetMs": 0, "durationMs": 1000000, "updatedAt": 1700000001, "watched": true, "timesWatched": 2]]
            query["watchedVideoIdsByTitle"] = ["unsaved-series": ["other-video"]]
            query["watchedTitles"] = ["watched-movie": 2]
            query["resumeById"] = ["opaque-video": ["offsetMs": 120001, "durationMs": 1200001, "updatedAt": 1700000000], "finished": NSNull()]
        }
        if query["kind"] as? String == "resume_point" { query["resume"] = ["offsetMs": 3001, "durationMs": 100000, "updatedAt": 1700000000] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: query), as: UTF8.self)
    }
    func state(_ handle: UInt) -> String? { lock.lock(); defer { lock.unlock() }; return states[handle] }
    func delta(_ handle: UInt) -> String? { "{}" }
    func free(_ handle: UInt) { lock.lock(); defer { lock.unlock() }; precondition(states.removeValue(forKey: handle) != nil) }
}

private final class MutationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class SessionStore: VortxCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var failure = false
    private var installBeforeFailure = false
    private var block = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func blockNextWrite() { lock.lock(); block = true; lock.unlock() }
    func failWrites(afterInstall: Bool = false) { lock.lock(); failure = true; installBeforeFailure = afterInstall; lock.unlock() }
    func recover() { lock.lock(); failure = false; lock.unlock() }
    func read(scope: VortxAccountScope) throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        lock.lock(); defer { lock.unlock() }
        if block { block = false; entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success) }
        if !failure || installBeforeFailure { value = snapshot }
        if failure { throw VortxNativeError.unavailable }
    }
}

private final class SessionTransport: VortxResourceTransport, @unchecked Sendable {
    final class Token: VortxResourceCancellation, @unchecked Sendable { func cancel() {} }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func makeCancellation() throws -> any VortxResourceCancellation { Token() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        var input = try JSONDecoder().decode(VortxJSON.self, from: Data(requestJSON.utf8))
        if input["request"]?["id"] == .string("slow") { entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success) }
        var groups: [VortxJSON] = []
        if input["request"]?["resource"] == .string("catalog"), let addon = input["addons"]?.array?.first?["id"] {
            let extra = try input["request"]?["extra"]?.decode([[String]].self) ?? []
            let skip = extra.first { $0.first == "skip" }.flatMap { Int($0[1]) } ?? 0
            let items: [VortxJSON] = skip >= 2 ? [] : [.object(["id": .string("page-\(skip)"), "type": .string("movie"), "name": .string("Page \(skip)")])]
            groups = [.object(["addonId": addon, "status": .string("ready"), "content": .object(["metas": .array(items)])])]
        }
        input = .object(["kind": .string("resource_result"), "requestId": input["requestId"]!, "generation": input["generation"]!,
                         "request": input["request"]!, "groups": .array(groups), "cancelled": .bool(false)])
        return String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    }
}

@main enum VortxNativeSessionTests {
    static func check(_ value: Bool, line: Int = #line) { precondition(value, "session assertion at line \(line)") }
    static func main() async throws {
        check(VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: false, hasLegacyAddonOrderIntent: false))
        check(!VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: true, hasLegacyAddonOrderIntent: false))
        check(!VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: false, hasLegacyAddonOrderIntent: true))
        check(!VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: false, hasLegacyAddonOrderIntent: false, overridingLegacySource: true))
        let scope = VortxAccountScope(account: "account-a", ownerProfileID: "owner")
        let actorA = "00000000-0000-0000-0000-000000000001", actorB = "00000000-0000-0000-0000-000000000002"
        var hostA = try VortxNativeHostPreferences(scope: scope, actor: actorA)
        var hostB = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        try hostA.edit(profileID: "owner", fields: ["avatar": .string("🍿")], scope: scope)
        try hostB.edit(profileID: "owner", fields: ["avatar": .string("moon")], scope: scope)
        try hostA.merge(hostB.document, scope: scope)
        check(try hostA.document["profiles"]?["owner"]?["fields"]?["avatar"]?["value"] == .string("moon"))
        try hostA.edit(profileID: "owner", fields: ["avatar": .null], scope: scope)
        check(try hostA.document["profiles"]?["owner"]?["fields"]?["avatar"]?["clock"] == .integer(2))
        do { try hostA.edit(profileID: "owner", fields: ["pin": .string("1234")], scope: scope); fatalError("host carrier accepted native PIN") } catch {}
        do { try hostA.edit(profileID: "owner", fields: ["future": .object(["apiKey": .string("fixture-secret")])], scope: scope); fatalError("host carrier accepted nested credential") } catch {}
        var equivocal = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        try equivocal.edit(profileID: "owner", fields: ["avatar": .string("different")], scope: scope)
        do { try hostB.merge(equivocal.document, scope: scope); fatalError("host carrier accepted equivocal event") } catch {}
        let restoredHost = try VortxNativeHostPreferences(scope: scope, actor: actorB, sealed: hostA.encoded())
        check(restoredHost.local.actor == actorB && restoredHost.local.counter == 2)
        var credentials = try VortxNativeProviderCredentials(scope: scope.account, actor: actorA)
        try credentials.edit(["tmdb": .string("fixture-nonproduction")])
        let sentCredentials = credentials.local.pending
        try credentials.edit(["tmdb": .null])
        credentials.acknowledge(sentCredentials)
        check(credentials.local.pending["tmdb"]?.value == .null) // old push cannot acknowledge newer clear
        var credentialPeer = try VortxNativeProviderCredentials(scope: scope.account, actor: actorB)
        try credentialPeer.merge(credentials.document)
        check(credentialPeer.mirror(into: ["tmdb": "fixture-old", "future": "retained"]) == ["future": "retained"])
        do { try credentials.edit(["unknownProvider": .string("not-exportable")]); fatalError("unknown provider accepted") } catch {}
        do { try credentials.edit(["traktAccess": .string("incomplete")]); fatalError("incomplete OAuth group accepted") } catch {}
        let credentialArchive = try VortxNativeBootstrapArchive.encode(document: JSONEncoder().encode(VortxJSON.object(["nativeProviderCredentials": try credentials.document])))
        let credentialArchiveJSON = try JSONDecoder().decode(VortxJSON.self, from: credentialArchive)
        check(credentialArchiveJSON["hostDocument"]?["nativeProviderCredentials"] == nil)
        check(credentialArchiveJSON["excludedCredentialPaths"] == .array([.string("/nativeProviderCredentials")]))
        let abi = SessionABI(), store = SessionStore(), transport = SessionTransport()
        let session = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: store, transport: transport, allowNewAccount: true)
        for _ in 0..<2 {
            do { _ = try VortxNativeSession(scope: scope, ownerName: "Other", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true); fatalError("overlapping account writer admitted") }
            catch VortxNativeError.unavailable {}
        }
        do { _ = try VortxNativeSession(scope: .init(account: scope.account, ownerProfileID: "other-owner"), ownerName: "Other", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true); fatalError("same account with a different owner admitted a second writer") }
        catch VortxNativeError.unavailable {}
        let before = try await session.stateJSON()
        do { _ = try await session.dispatch(["{\"type\":\"fail\"}"], now: 2); fatalError("invalid action accepted") }
        catch VortxNativeError.invalidResponse {}
        store.failWrites()
        do { _ = try await session.dispatch(["{\"type\":\"edit\",\"value\":42}"], now: 2); fatalError("unacknowledged state published") }
        catch VortxNativeError.checkpointUncertain {}
        check(try await session.stateJSON() == before)
        do { _ = try await session.dispatch(["{\"type\":\"edit\"}"], now: 3); fatalError("uncertain checkpoint overwritten") }
        catch VortxNativeError.checkpointUncertain {}
        let slow = Task { try await session.loadMeta(request: .init(resource: .meta, type: "series", id: "slow"), stream: nil, addons: []) }
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(transport.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        _ = try await session.loadCatalog(.search, request: .init(resource: .catalog, type: "series", id: "popular"), addons: [])
        if case .loading = await session.screen("meta_details") {} else { fatalError("search clobbered meta slot") }
        await session.close(); transport.release.signal()
        do { _ = try await slow.value; fatalError("closed owner published") } catch VortxNativeError.superseded {}
        check(await session.screen("meta_details") == nil)

        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("sealed")
        let key = SymmetricKey(size: .bits256)
        let archive = try VortxNativeBootstrapArchive.encode(document: Data(#"{"futurePreference":{"keep":42},"apiKeys":{"provider":"fixture-excluded"}}"#.utf8),
                                                              material: Data(#"{"schemaVersion":1,"sourceClock":1000.125}"#.utf8))
        // A separate installation proof authenticates the inventory without sharing account keys.
        // Legacy/unindexed and corrupt history never establish absence for a different account.
        let indexedDirectory = directory.deletingLastPathComponent().appendingPathComponent("indexed-accounts")
        let installKey = SymmetricKey(size: .bits256), keyB = SymmetricKey(size: .bits256)
        let scopeB = VortxAccountScope(account: "account-b", ownerProfileID: scope.ownerProfileID)
        let scopeC = VortxAccountScope(account: "account-c", ownerProfileID: scope.ownerProfileID)
        let legacyA = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key, bootstrap: archive, bootstrapScope: scope)
        try legacyA.commit(before, scope: scope); try legacyA.rememberAuthenticatedScope(scope)
        let indexedB = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: keyB, installationKey: installKey, bootstrap: archive, bootstrapScope: scopeB)
        do { _ = try indexedB.authenticatedCheckpoint(scope: scopeB); fatalError("legacy other-account history admitted new account") } catch {}
        let indexedA = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key, installationKey: installKey)
        check(try indexedA.authenticatedCheckpoint(scope: scope) == before)
        try indexedA.rememberAuthenticatedScope(scope)
        check(try indexedB.authenticatedCheckpoint(scope: scopeB) == nil)
        do { _ = try indexedB.recovery(account: scope.account); fatalError("inventory key decrypted another account") } catch {}
        let stateB = before.replacingOccurrences(of: "account-a", with: "account-b")
        try indexedB.commit(stateB, scope: scopeB)
        let indexedC = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: SymmetricKey(size: .bits256), installationKey: installKey)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("crash between checkpoint and locator admitted new account") } catch {}
        try indexedB.rememberAuthenticatedScope(scopeB)
        check(try indexedC.authenticatedCheckpoint(scope: scopeC) == nil)
        try indexedA.commit(before, scope: scope)
        check(try indexedC.authenticatedCheckpoint(scope: scopeC) == nil)
        let indexedFiles = try FileManager.default.contentsOfDirectory(at: indexedDirectory, includingPropertiesForKeys: nil)
        let accountIndexes = indexedFiles.filter { $0.lastPathComponent.hasPrefix("native-account-v2-") }
        check(accountIndexes.count == 2)
        for file in indexedFiles {
            let sealedBytes = try Data(contentsOf: file)
            check(sealedBytes.range(of: Data("account-a".utf8)) == nil)
            check(sealedBytes.range(of: Data("Retain context".utf8)) == nil)
        }
        let indexPath = accountIndexes[0], indexBytes = try Data(contentsOf: accountIndexes[0])
        try Data("corrupt-index".utf8).write(to: indexPath)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("corrupt inventory admitted new account") } catch {}
        try indexBytes.write(to: indexPath)
        try FileManager.default.removeItem(at: indexPath)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("missing index admitted new account") } catch {}
        try indexedA.rememberAuthenticatedScope(scope); try indexedB.rememberAuthenticatedScope(scopeB)
        check(try indexedC.authenticatedCheckpoint(scope: scopeC) == nil)
        let stateDigest = SHA256.hash(data: scope.authenticatedData).map { String(format: "%02x", $0) }.joined()
        let indexedStateA = indexedDirectory.appendingPathComponent("native-state-v1-\(stateDigest).sealed")
        let validIndexedState = try Data(contentsOf: indexedStateA)
        let prefix = Data("vortx-native-indexed-ciphertext-v2\n".utf8)
        var corrupted = try JSONSerialization.jsonObject(with: validIndexedState.dropFirst(prefix.count)) as! [String: Any]
        var ciphertext = Data(base64Encoded: corrupted["ciphertext"] as! String)!
        ciphertext[ciphertext.startIndex] ^= 1
        corrupted["ciphertext"] = ciphertext.base64EncodedString()
        try (prefix + JSONSerialization.data(withJSONObject: corrupted)).write(to: indexedStateA)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("altered account ciphertext passed inventory proof") } catch {}
        do { _ = try indexedA.recovery(account: scope.account); fatalError("altered account ciphertext passed account authentication") } catch {}
        try validIndexedState.write(to: indexedStateA)
        try FileManager.default.removeItem(at: indexedStateA)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("dangling authenticated index admitted absence") } catch {}
        try validIndexedState.write(to: indexedStateA)
        let accountOnly = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key)
        check(try accountOnly.recovery(account: scope.account)?.state == before)
        // Device-key loss invalidates absence proofs, never the independently encrypted account data.
        let rotatedKey = SymmetricKey(size: .bits256)
        let rotatedA = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key, installationKey: rotatedKey)
        let rotatedB = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: keyB, installationKey: rotatedKey)
        let rotatedC = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: SymmetricKey(size: .bits256), installationKey: rotatedKey)
        do { _ = try rotatedC.authenticatedCheckpoint(scope: scopeC); fatalError("lost installation key established absence") } catch {}
        check(try rotatedA.recovery(account: scope.account)?.state == before)
        try rotatedA.rememberAuthenticatedScope(scope)
        do { _ = try rotatedC.authenticatedCheckpoint(scope: scopeC); fatalError("partially repaired inventory established absence") } catch {}
        check(try rotatedB.recovery(account: scopeB.account)?.state == stateB)
        try rotatedB.rememberAuthenticatedScope(scopeB)
        check(try rotatedC.authenticatedCheckpoint(scope: scopeC) == nil)
        print("Native installation inventory: independent second-account admission, legacy/crash/corrupt/missing-index rejection, account-key isolation and install-key-loss repair passed")
        let encrypted = try VortxEncryptedCheckpointStore(directory: directory, key: key, bootstrap: archive, bootstrapScope: scope)
        try encrypted.commit(before, scope: scope)
        check(try encrypted.read(scope: scope) == before)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let stateFiles = files.filter { $0.lastPathComponent.hasPrefix("native-state-v1-") }
        precondition(stateFiles.count == 1)
        let bytes = try Data(contentsOf: stateFiles[0])
        precondition(bytes.range(of: Data("Retain context".utf8)) == nil)
        func archived(_ bytes: Data) throws -> Data? {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: scope.authenticatedData)
            let envelope = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
            return (envelope["bootstrap"] as? String).flatMap { Data(base64Encoded: $0) }
        }
        check(try archived(bytes) == archive)
        let coldStore = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        check(try coldStore.read(scope: scope) == before)
        check(try coldStore.recovery(account: scope.account) == nil)
        check(try coldStore.authenticatedCheckpoint(scope: scope) == before)
        let changedOwner = VortxAccountScope(account: scope.account, ownerProfileID: "replacement-owner")
        do { _ = try coldStore.authenticatedCheckpoint(scope: changedOwner); fatalError("unindexed checkpoint reset by replacement owner") } catch {}
        try coldStore.rememberAuthenticatedScope(scope)
        let offlineRecovery = try coldStore.recovery(account: scope.account)
        check(offlineRecovery?.scope == scope && offlineRecovery?.state == before && offlineRecovery?.bootstrap == archive)
        check(try coldStore.recovery(account: "other-account") == nil)
        do { _ = try coldStore.authenticatedCheckpoint(scope: changedOwner); fatalError("authenticated locator owner replaced") } catch {}
        try coldStore.commit(before, scope: scope)
        check(try archived(Data(contentsOf: files[0])) == archive)
        let otherScope = VortxAccountScope(account: "account-b", ownerProfileID: scope.ownerProfileID)
        let otherState = before.replacingOccurrences(of: "account-a", with: "account-b")
        try encrypted.commit(otherState, scope: otherScope)
        let otherFile = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0 != files[0] && $0.lastPathComponent.hasPrefix("native-state-") }!
        let otherPlain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: otherFile)), using: key, authenticating: otherScope.authenticatedData)
        check((try JSONSerialization.jsonObject(with: otherPlain) as! [String: Any])["bootstrap"] == nil)
        // Prior raw-runtime files remain readable; their next commit adopts a sealed envelope.
        let legacySealed = try AES.GCM.seal(Data(before.utf8), using: key, authenticating: scope.authenticatedData).combined!
        try legacySealed.write(to: files[0], options: .atomic)
        check(try encrypted.read(scope: scope) == before)
        try encrypted.commit(before, scope: scope)
        check(try archived(Data(contentsOf: files[0])) == archive)
        let wrongKey = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        do { _ = try wrongKey.recovery(account: scope.account); fatalError("wrong key recovered account locator") } catch {}
        do { _ = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: wrongKey, transport: transport, allowNewAccount: true); fatalError("decrypt failure seeded empty owner") }
        catch {}
        let restarted = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: encrypted, transport: transport)
        check(try await restarted.stateJSON() == before)
        await restarted.close()
        let hostSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: encrypted, transport: transport, hostActor: actorA)
        _ = try await hostSession.dispatch([#"{"type":"edit","value":711}"#], now: 7,
                                          hostEdits: [.init(profileID: "owner", fields: ["avatar": .string("moon")])])
        let sealedHost = try encrypted.readHostPreferences(scope: scope)!
        check(try await VortxNativeHostPreferences(scope: scope, actor: actorA, sealed: sealedHost).document == hostSession.hostPreferencesDocument())
        check(try encrypted.read(scope: scope)?.contains("711") == true)
        let validHostState = try encrypted.read(scope: scope)
        for (field, malformed) in [("avatar", VortxJSON.integer(1)), ("playback", .string("invalid")), ("discovery", .string("invalid")), ("addonPreferences", .array([]))] {
            do {
                _ = try await hostSession.dispatch([#"{"type":"edit","value":999}"#], now: 8,
                    hostEdits: [.init(profileID: "owner", fields: [field: malformed])])
                fatalError("malformed presentation field was committed")
            } catch {}
            check(try encrypted.read(scope: scope) == validHostState)
            check(try encrypted.readHostPreferences(scope: scope) == sealedHost)
        }
        await hostSession.close()
        let legacyJSON = "{\"profiles\":[{\"id\":\"retained\"}]}"
        let legacy = try VortxLegacyImport(scope: scope, documents: [VortxLegacyImport.rosterID: legacyJSON])
        do { _ = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true, legacy: legacy); fatalError("legacy account overwritten") }
        catch VortxNativeError.invalidSnapshot {}
        precondition(legacy.documents[VortxLegacyImport.rosterID] == legacyJSON)
        let ambiguousStore = SessionStore()
        let ambiguous = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: ambiguousStore, transport: transport, allowNewAccount: true)
        ambiguousStore.failWrites(afterInstall: true)
        do { _ = try await ambiguous.dispatch(["{\"type\":\"edit\",\"value\":99}"], now: 4); fatalError("uncertain commit acknowledged") }
        catch VortxNativeError.checkpointUncertain {}
        let priorPublication = try await ambiguous.stateJSON()
        let uncertainDisk = try ambiguousStore.read(scope: scope)!
        precondition(priorPublication != uncertainDisk)
        await ambiguous.close(); ambiguousStore.recover()
        let recovered = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: ambiguousStore, transport: transport)
        check(try await recovered.stateJSON() == uncertainDisk)
        await recovered.close()
        let firstImportStore = SessionStore()
        do {
            _ = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: firstImportStore,
                                       transport: transport, allowNewAccount: true, initialActions: [#"{"type":"fail"}"#])
            fatalError("failed cold import published a checkpoint")
        } catch VortxNativeError.invalidResponse {}
        check(try firstImportStore.read(scope: scope) == nil)
        let candidate = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: firstImportStore,
                                                transport: transport, allowNewAccount: true,
                                                initialActions: [#"{"type":"edit","value":314}"#])
        let firstImport = try firstImportStore.read(scope: scope)
        check(firstImport?.contains("314") == true)
        // Revocation reaches a candidate before any facade is installed, not just active UI state.
        VortxNativeSession.revokeAllForOwnerBoundary()
        do { _ = try await candidate.dispatch([#"{"type":"edit","value":315}"#], now: 5); fatalError("uninstalled revoked candidate wrote state") }
        catch VortxNativeError.closed {}
        check(try firstImportStore.read(scope: scope) == firstImport)
        await candidate.close()
        let pagingSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true)
        let pagingManifest = try JSONDecoder().decode(VortxJSON.self, from: Data(#"{"catalogs":[{"id":"popular","type":"movie","name":"Popular","extra":[{"name":"skip"},{"name":"genre","options":["Drama","Comedy"]}]},{"id":"recent","type":"movie","extra":[{"name":"skip"}]}]}"#.utf8))
        let paging = try await VortxNativeCoreFacade.create(session: pagingSession, registry: [.init(id: "paging", transportUrl: "https://fixture.example/manifest.json", manifest: pagingManifest)], changed: { _ in })
        func pagingField(_ field: String) throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: paging.stateData(field)!) }
        func pageDispatch(_ raw: String, _ field: String) async {
            check(paging.dispatch(data: Data(raw.utf8), field: field)); await paging.settled()
        }
        await pageDispatch(#"{"action":"Load","args":{"model":"CatalogsWithExtra","args":{"extra":[]}}}"#, "board")
        await pageDispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadRange","args":{"end":1}}}"#, "board")
        await pageDispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadNextPage","args":0}}"#, "board")
        check(try pagingField("board")["catalogs"]?.array?.first?.array?.count == 2)
        await pageDispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadRange","args":{"end":2}}}"#, "board")
        check(try pagingField("board")["catalogs"]?.array?.count == 2)
        check(try pagingField("board")["catalogs"]?.array?.first?.array?.count == 2) // widening keeps horizontal pages
        await pageDispatch(#"{"action":"Load","args":{"model":"CatalogWithFilters","args":null}}"#, "discover")
        let selectable = try pagingField("discover")["selectable"]!
        check(selectable["types"]?.array?.count == 1 && selectable["catalogs"]?.array?.count == 2)
        check(selectable["extra"]?.array?.first?["options"]?.array?.count == 3)
        let genreRequest = selectable["extra"]!.array![0]["options"]!.array![1]["request"]!
        let genreAction: VortxJSON = .object(["action": .string("Load"), "args": .object(["model": .string("CatalogWithFilters"), "args": .object(["request": genreRequest])])])
        check(paging.dispatch(data: try JSONEncoder().encode(genreAction), field: "discover")); await paging.settled()
        await pageDispatch(#"{"action":"CatalogWithFilters","args":{"action":"LoadNextPage"}}"#, "discover")
        check(try pagingField("discover")["catalog"]?.array?.count == 2)
        let secondPath = try pagingField("discover")["catalog"]!.array![1]["request"]!["path"]!
        check(try secondPath["extra"]?.decode([[String]].self) == [["genre", "Drama"], ["skip", "1"]])
        await pageDispatch(#"{"action":"CatalogWithFilters","args":{"action":"LoadNextPage"}}"#, "discover")
        check(try pagingField("discover")["selectable"]?["next_page"] == .null)
        let exhausted = try pagingField("discover")
        await pageDispatch(#"{"action":"CatalogWithFilters","args":{"action":"LoadNextPage"}}"#, "discover")
        check(try pagingField("discover") == exhausted)
        check(!paging.dispatch(data: Data(#"{"action":"Load","args":{"model":"CatalogWithFilters","args":{"request":{"base":"https://fixture.example/manifest.json","path":{"resource":"catalog","type":"movie","id":"popular","extra":[["genre","Unknown"]]}}}}}"#.utf8), field: "discover"))
        await paging.shutdown()
        let transitionStore = SessionStore()
        let transitionSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: transitionStore, transport: transport, allowNewAccount: true)
        let mutations = MutationCounter()
        let facade = try await VortxNativeCoreFacade.create(session: transitionSession, registry: [], mutationAccepted: { mutations.increment() }, changed: { _ in })
        let nativeCW = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("continue_watching_preview")!)
        check(nativeCW["items"]?.array?.first?["state"]?["timeOffset"] == .integer(120001))
        check(nativeCW["items"]?.array?.first?["state"]?["video_id"] == .string("opaque-video"))
        let nativeLibrary = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("library")!)
        check(nativeLibrary["catalog"] == .array([])) // history/resume is not saved membership
        check(facade.cachedResumeSeconds(id: "opaque-video") == 120.001)
        check(facade.cachedResumeSeconds(id: "finished") == 0)
        check(facade.cachedResumeSeconds(id: "unknown") == nil)
        check(try await facade.resumeSeconds(id: "unknown", profileID: "owner") == 3.001)
        transitionStore.blockNextWrite()
        check(facade.dispatch(data: Data(#"{"action":"Vortx","args":{"type":"switch_profile","id":"kid"}}"#.utf8), field: nil))
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(transitionStore.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        check(!facade.dispatch(data: Data(#"{"action":"Ctx","args":{"action":"AddToLibrary","args":{"id":"tt-old","type":"movie","name":"Old"}}}"#.utf8), field: nil))
        check(facade.lastFailure == "profile_transition_pending")
        check(!facade.dispatchForProfile(.object(["type": .string("report_progress")]), profileID: "owner"))
        check(facade.dispatch(data: Data(#"{"action":"Vortx","args":{"type":"get_state"}}"#.utf8), field: nil))
        transitionStore.release.signal(); await facade.settled()
        let published = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_state")!)
        check(published["activeProfileId"] == .string("kid"))
        check(facade.registryBinding?.profileID == "kid")
        check(facade.lastFailure == nil)
        check(!facade.dispatchForProfile(.object(["type": .string("mark_watched"), "metaId": .string("late")]), profileID: "owner"))
        check(mutations.value == 1) // switch acknowledged; queued get_state does not schedule a push
        check(!facade.reorderAddonURLs([], profileID: "owner"))
        check(facade.reorderAddonURLs([], profileID: "kid"))
        await facade.settled()
        check(mutations.value == 2) // the single admitted local reorder acknowledges once
        let remote: VortxJSON = .object(["schemaVersion": .integer(1), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID), "fixturePeer": .string("retained")])
        let exported = try await facade.mergeSyncDocument(remote)
        check(exported == remote && exported["activeProfileId"] == nil && exported["libraries"] == nil)
        check(mutations.value == 2) // remote merge must not self-echo
        let durable = try JSONDecoder().decode(VortxJSON.self, from: Data(try transitionStore.read(scope: scope)!.utf8))
        check(durable["nativeSync"] == remote && durable["activeProfileId"] == .string("kid"))
        do { _ = try await facade.mergeSyncDocument(.object(["scope": .string("another-account")])); fatalError("foreign account carrier exported") }
        catch VortxNativeError.invalidResponse {}
        abi.failPlaybackQueries()
        do { _ = try await facade.mergeSyncDocument(nil); fatalError("failed playback query exported successful empty history") }
        catch VortxNativeError.invalidResponse {}
        check(!facade.isAvailable && facade.stateData("continue_watching_preview") == nil)
        check(facade.lastFailure == "native_projection_unavailable_reopen_required")
        await facade.shutdown()
        let unavailableSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: transitionStore, transport: transport)
        do { _ = try await VortxNativeCoreFacade.create(session: unavailableSession, registry: [], changed: { _ in }); fatalError("unsupported playback query mounted") }
        catch VortxNativeError.invalidResponse {}
        await unavailableSession.close()
        print("Native session: acknowledged transactions, sealed cold state/context, legacy preservation and independent screen/logout fences passed")
    }
}
