import Foundation

/// Explicit synthetic credential/defaults/coordinator boundary. Actual store methods and the actual
/// failure-closed Keychain CAS class are compiled unchanged by the selector. No real credential IO.
private final class SyntheticCredentialBackend: @unchecked Sendable {
    var values: [String: String] = [:]
    var readFailure = false, failWrite = false, wrongReadback = false
    var alternateWrittenValue: String?
    var rejectTransaction = false
    var writes = 0, purgeCount = 0, runPurgeHookAt = 1
    var purgeHook: (() -> Void)?
    var writeHook: (() -> Void)?
    lazy var store = KeychainFailureClosedStore(readSecure: { [weak self] slot in
        guard let self, !self.readFailure else { return .failure }
        if self.wrongReadback, !slot.hasSuffix(".invalid"), self.values[slot] != nil { return .value("synthetic-wrong-readback") }
        return self.values[slot].map(CredentialDurableReadResult.value) ?? .missing
    }, writeSecure: { [weak self] value, slot in
        guard let self else { return .failure }
        if !slot.hasSuffix(".invalid") {
            if self.failWrite { return .failure }
            self.writes += 1
            let hook = self.writeHook; self.writeHook = nil; hook?()
        }
        if value != nil, !slot.hasSuffix(".invalid"), let alternate = self.alternateWrittenValue {
            self.values[slot] = alternate
        } else { self.values[slot] = value }
        return .success
    }, invalidationAccount: { $0 + ".invalid" }, invalidationSentinel: "invalid",
       isLegacyInvalidated: { _ in false }, clearLegacyInvalidated: { _ in }, purgeAllLegacy: {},
       purgeLegacy: { [weak self] _ in
        guard let self else { return }
        self.purgeCount += 1
        if self.purgeCount == self.runPurgeHookAt {
            let hook = self.purgeHook; self.purgeHook = nil; hook?()
        }
    }, mutationTransaction: { [weak self] operation in
        guard let self, !self.rejectTransaction else { return .failure }
        return operation()
    })
}

// Only legacy methods compile against these inert collaborators. Settled methods get the explicit
// fixture IO; none of this enum's methods is an alternate successful settlement implementation.
enum Keychain {
    static func string(_ slot: String) -> String? { nil }
    static func confirmedString(_ slot: String) -> CredentialDurableReadResult { .failure }
    @discardableResult static func set(_ value: String?, for slot: String) -> CredentialMutationResult { .failure }
    static func confirmedRead(_ slot: String, isCurrentOwner: () -> Bool) -> KeychainFailureClosedStore.ConfirmedRead? { nil }
    static func compareAndSetConfirmed(_ expected: KeychainFailureClosedStore.ConfirmedRead, with replacement: String?,
        for slot: String, isCurrentOwner: () -> Bool) -> CredentialMutationResult { .failure }
}
@MainActor enum CredentialPublicationOutbox {
    enum Acquisition { case acquired, busy }
    static var busy = false
    static func acquireBoundary() -> Acquisition { if busy { return .busy }; busy = true; return .acquired }
    static func endBoundary() { busy = false }
}
@MainActor final class VortXSyncManager {
    static let shared = VortXSyncManager()
    func requestSyncSoon() { preconditionFailure("settlement must not nudge sync") }
}
@MainActor final class MediaServerCoordinator {
    static let shared = MediaServerCoordinator()
    var installed: [MediaServerConfig] = []
    func reload(configs: [MediaServerConfig]) { installed = configs }
    func matchesInstalledConfiguration(_ configs: [MediaServerConfig]) -> Bool { installed == configs }
}

@MainActor private final class World {
    let secure = SyntheticCredentialBackend()
    var list: Data?, removed: [String: Double] = [:]
    var active = true, syncOK = true, persistOK = true, corruptPersist = false, coordinatorOK = true
    var persistCount = 0, coordinatorCount = 0
    var revokePersist = false
    var afterPlanningRead: (() -> Void)?
    var installed: [MediaServerConfig] = []
    func mediaIO() -> MediaServerStore.SyncSettlementIO {
        .init(credential: { self.secure.store.confirmedString($0) },
            confirmedRead: { slot, owns in
                let result = self.secure.store.confirmedRead(slot, isCurrentOwner: owns)
                let hook = self.afterPlanningRead; self.afterPlanningRead = nil; hook?()
                return result
            },
            compare: { self.secure.store.compareAndSetConfirmed($0, with: $1, account: $2, isCurrentOwner: $3) },
            list: { self.list }, removed: { self.removed }, synchronize: { self.syncOK },
            persist: { bytes, removed, owns in
                guard owns() else { return false }; self.persistCount += 1; self.removed = removed
                if self.revokePersist { self.active = false }
                guard owns() else { return false }
                self.list = self.corruptPersist ? Data("synthetic-bad-readback".utf8) : bytes
                return self.persistOK
            }, coordinator: { configs in
                self.coordinatorCount += 1; self.installed = configs
                MediaServerCoordinator.shared.reload(configs: configs)
                return self.coordinatorOK && MediaServerCoordinator.shared.matchesInstalledConfiguration(configs)
            })
    }
    func iptvIO() -> IPTVPlaylistStore.SyncSettlementIO {
        .init(credential: { self.secure.store.confirmedString($0) },
            confirmedRead: { slot, owns in
                let result = self.secure.store.confirmedRead(slot, isCurrentOwner: owns)
                let hook = self.afterPlanningRead; self.afterPlanningRead = nil; hook?()
                return result
            },
            compare: { self.secure.store.compareAndSetConfirmed($0, with: $1, account: $2, isCurrentOwner: $3) },
            list: { self.list }, removed: { self.removed }, synchronize: { self.syncOK },
            persist: { bytes, removed, owns in
                guard owns() else { return false }; self.persistCount += 1; self.removed = removed
                if self.revokePersist { self.active = false }
                guard owns() else { return false }
                self.list = self.corruptPersist ? Data("synthetic-bad-readback".utf8) : bytes
                return self.persistOK
            })
    }
}

@MainActor private final class ProviderSettlementTaskBox { var task: Task<MediaServerStore.SyncSettlement, Never>? }

@main private enum AccountProviderSyncSettlementTests {
    static let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let sibling = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static func ms(_ id: UUID) -> String { "vortx.mediaserver." + id.uuidString + ".token" }
    static let iptvSlot = "vortx.iptv.cred.synthetic-playlist"
    static func media(_ added: Int = 1000, token: String? = "synthetic-remote", name: String = "Remote") throws -> String {
        var row: [String: Any] = ["id": id.uuidString, "kind": "jellyfin", "name": name, "urls": ["https://synthetic.invalid"], "addedAt": added]
        if let token { row["token"] = token }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1, "servers": [row], "removed": [:]]), as: UTF8.self)
    }
    static func iptv(_ added: Int = 1000, credential: String? = #"{"m3uURL":"https://synthetic.invalid/list"}"#) throws -> String {
        var row: [String: Any] = ["id": "synthetic-playlist", "kind": "m3u", "name": "Synthetic", "transportUrl": "https://synthetic.invalid/manifest.json", "createdAt": added]
        if let credential { row["cred"] = credential }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1, "playlists": [row], "removed": [:]]), as: UTF8.self)
    }
    @MainActor static func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: " + message) }
    static func settled(_ result: MediaServerStore.SyncSettlement) -> Bool { if case .settled = result { return true }; return false }
    static func settled(_ result: IPTVPlaylistStore.SyncSettlement) -> Bool { if case .settled = result { return true }; return false }
    @MainActor static func main() async throws {
        // F3 composition: select the actual manager exclusion policy, then execute the whole actual
        // checked store against its original persisted planning rows. All IO is the declared synthetic
        // backend; the credential deletion still runs the actual capability/CAS implementation.
        do {
            let old = MediaServerRecord(id: id, name: "old", kind: .jellyfin, urls: [], userId: "", addedAt: Date(timeIntervalSince1970: 1))
            let kept = MediaServerRecord(id: sibling, name: "kept", kind: .plex, urls: [], userId: "", addedAt: Date(timeIntervalSince1970: 3))
            let world = World(), prior = "10000000-0000-0000-0000-000000000003"
            world.list = try JSONEncoder().encode([old, kept]); world.removed = [prior: 500]
            world.secure.values[ms(id)] = "old-token"; world.secure.values[ms(sibling)] = "kept-token"
            let excluded = VortXSyncManager.receivedProviderSettingsExclusions(media: true, iptv: false)
            // Model only the call site's incoming empty legacy baseline; honor its actual exclusions.
            if !excluded.contains("vortx.mediaServers.list") { world.list = Data("[]".utf8) }
            if !excluded.contains("vortx.mediaServers.removed") { world.removed = [:] }
            let baseline = try JSONDecoder().decode([MediaServerRecord].self, from: world.list!)
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO(), servers: baseline)
            let source = String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1, "servers": [], "removed": [id.uuidString: 2000]]), as: UTF8.self)
            check(settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })),
                "protected empty cold media baseline permits actual pure-tombstone settlement")
            check(world.secure.values[ms(id)] == nil && world.secure.writes == 1
                && world.secure.values[ms(sibling)] == "kept-token" && store.servers == [kept]
                && world.removed[prior] == 500 && world.removed[id.uuidString] == 2000,
                "cold media tombstone performs actual credential CAS and retains unrelated rows credentials and removals")
        }
        do {
            let old = IPTVPlaylist(id: "synthetic-playlist", name: "old", kind: .m3u, transportUrl: "https://synthetic.invalid/manifest", createdAt: Date(timeIntervalSince1970: 1))
            let kept = IPTVPlaylist(id: "kept", name: "kept", kind: .m3u, transportUrl: "https://synthetic.invalid/kept", createdAt: Date(timeIntervalSince1970: 3))
            let world = World(), keptSlot = "vortx.iptv.cred.kept"
            world.list = try JSONEncoder().encode([old, kept]); world.removed = ["prior": 500]
            world.secure.values[iptvSlot] = #"{"m3uURL":"https://synthetic.invalid/old"}"#
            world.secure.values[keptSlot] = #"{"m3uURL":"https://synthetic.invalid/kept"}"#
            let retainedCredential = world.secure.values[keptSlot]
            let excluded = VortXSyncManager.receivedProviderSettingsExclusions(media: false, iptv: true)
            if !excluded.contains("vortx.iptv.playlists") { world.list = Data("[]".utf8) }
            if !excluded.contains("vortx.iptv.removed") { world.removed = [:] }
            let baseline = try JSONDecoder().decode([IPTVPlaylist].self, from: world.list!)
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO(), playlists: baseline)
            let source = String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1, "playlists": [], "removed": ["synthetic-playlist": 2000]]), as: UTF8.self)
            check(settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })),
                "protected empty cold IPTV baseline permits actual pure-tombstone settlement")
            check(world.secure.values[iptvSlot] == nil && world.secure.writes == 1
                && world.secure.values[keptSlot] == retainedCredential && store.playlists == [kept]
                && world.removed["prior"] == 500 && world.removed["synthetic-playlist"] == 2000,
                "cold IPTV tombstone performs actual credential CAS and retains unrelated rows credentials and removals")
        }
        check(VortXSyncManager.receivedProviderSettingsExclusions(media: false, iptv: false).isEmpty,
            "ordinary settings-only receive has no new provider exclusions")
        // Enter reads/checked receive from the actual setter's cleanup callback. Its generation
        // is reserved but no transaction/account lock/backend write has begun. No threads or fake
        // busy Boolean substitutes for the actual store-owned lifetime.
        do {
            let backend = SyntheticCredentialBackend(), slot = "pending-set"
            backend.values[slot] = "old"; let secure = backend.store
            var readRefused = false, remoteWrites = -1
            backend.purgeHook = {
                let during = secure.confirmedRead(slot, isCurrentOwner: { true })
                readRefused = during == nil
                if let during { _ = secure.compareAndSetConfirmed(during, with: "remote", account: slot, isCurrentOwner: { true }) }
                remoteWrites = backend.writes
            }
            check(secure.set("local-owner", for: slot) == .success,
                "pending original setter completes instead of being retired by later receive CAS")
            check(readRefused && remoteWrites == 0 && backend.values[slot] == "local-owner" && backend.writes == 1,
                "reserved-but-undurable setter yields no witnessed read or remote write")
            check(secure.confirmedRead(slot, isCurrentOwner: { true })?.result == .value("local-owner"),
                "successful setter releases lifecycle lease for successor read")
        }
        do {
            let backend = SyntheticCredentialBackend(), slot = "pending-replace"
            backend.values[slot] = "old"; let secure = backend.store
            guard let prior = secure.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
            var readRefused = false, casRefused = false
            backend.runPurgeHookAt = backend.purgeCount + 1
            backend.purgeHook = {
                readRefused = secure.confirmedRead(slot, isCurrentOwner: { true }) == nil
                casRefused = secure.compareAndSetConfirmed(prior, with: "remote", account: slot, isCurrentOwner: { true }) == .failure
            }
            check(secure.replaceConfirmedUTF8(expected: Data("old".utf8), with: Data("local-renewal".utf8), account: slot) == .success,
                "pending original exact replacer retains its original compare and result")
            check(readRefused && casRefused && backend.values[slot] == "local-renewal" && backend.writes == 1,
                "read and CAS cannot overtake pending replacer whose generation is not reserved yet")
        }
        do {
            let backend = SyntheticCredentialBackend(), slot = "pending-cas"; let secure = backend.store
            guard let prior = secure.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
            var readRefused = false, nestedCASRefused = false
            backend.runPurgeHookAt = backend.purgeCount + 1
            backend.purgeHook = {
                readRefused = secure.confirmedRead(slot, isCurrentOwner: { true }) == nil
                nestedCASRefused = secure.compareAndSetConfirmed(prior, with: "nested-remote", account: slot, isCurrentOwner: { true }) == .failure
            }
            check(secure.compareAndSetConfirmed(prior, with: "original-remote", account: slot, isCurrentOwner: { true }) == .success,
                "outer actual CAS retains sole lease after rejected reentrant CAS exits")
            check(readRefused && nestedCASRefused && backend.values[slot] == "original-remote" && backend.writes == 1,
                "pending CAS cannot mint reads or be overtaken by nested same-generation CAS")
        }
        for mode in ["set-transaction", "replace-encoding", "cas-owner"] {
            let backend = SyntheticCredentialBackend(), slot = "failed-lifetime"; let secure = backend.store
            let result: CredentialMutationResult
            switch mode {
            case "set-transaction":
                backend.rejectTransaction = true; result = secure.set("unpersisted", for: slot); backend.rejectTransaction = false
            case "replace-encoding":
                result = secure.replaceConfirmedUTF8(expected: Data([0xff]), with: Data("remote".utf8), account: slot)
            default:
                guard let observed = secure.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
                result = secure.compareAndSetConfirmed(observed, with: "remote", account: slot, isCurrentOwner: { false })
            }
            check(result == .failure && backend.writes == 0, "failed " + mode + " retains original no-write result")
            guard let next = secure.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("failed method leaked lifetime lease") }
            check(secure.compareAndSetConfirmed(next, with: "successor", account: slot, isCurrentOwner: { true }) == .success,
                "failed " + mode + " releases actual lifetime for positive successor read/CAS")
        }
        do {
            let backend = SyntheticCredentialBackend(), slot = "failed-write-lifetime"; let secure = backend.store
            backend.failWrite = true
            check(secure.set("unpersisted", for: slot) == .failure && secure.confirmedRead(slot, isCurrentOwner: { true }) == nil,
                "failed setter remains unavailable by actual invalidation marker")
            backend.failWrite = false
            check(secure.set("local-recovered", for: slot) == .success && secure.confirmedRead(slot, isCurrentOwner: { true })?.result == .value("local-recovered"),
                "failed write releases lease while retaining marker policy until genuine successful setter")
        }
        do {
            let world = World(), source = try media(), slot = ms(id)
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            var receive: MediaServerStore.SyncSettlement?, writesAtReceive = -1
            world.secure.purgeHook = {
                receive = store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })
                writesAtReceive = world.secure.writes
            }
            check(world.secure.store.set("local-owner", for: slot) == .success,
                "media pending-before-lock schedule preserves genuine original setter")
            check(receive.map { !settled($0) } == true && writesAtReceive == 0 && world.secure.values[slot] == "local-owner" && world.persistCount == 0 && store.servers.isEmpty,
                "actual media receive refuses earlier in-flight setter without credential/metadata mutation")
            check(settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })) && world.secure.values[slot] == "local-owner",
                "media successor receive works after setter returns and retains local authority")
        }
        do {
            let old = IPTVPlaylist(id: "synthetic-playlist", name: "old", kind: .m3u, transportUrl: "https://synthetic.invalid/manifest", createdAt: Date(timeIntervalSince1970: 1))
            let world = World(), local = #"{"m3uURL":"https://synthetic.invalid/local"}"#
            world.list = try JSONEncoder().encode([old]); world.secure.values[iptvSlot] = #"{"m3uURL":"https://synthetic.invalid/old"}"#
            let source = String(decoding: try JSONSerialization.data(withJSONObject: ["v":1,"playlists":[],"removed":["synthetic-playlist":2000]]), as: UTF8.self)
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO(), playlists: [old])
            var receive: IPTVPlaylistStore.SyncSettlement?, writesAtReceive = -1
            world.secure.purgeHook = {
                receive = store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })
                writesAtReceive = world.secure.writes
            }
            check(world.secure.store.set(local, for: iptvSlot) == .success,
                "IPTV tombstone pending-before-lock schedule preserves genuine original setter")
            check(receive.map { !settled($0) } == true && writesAtReceive == 0 && world.secure.values[iptvSlot] == local && world.persistCount == 0 && store.playlists == [old],
                "actual IPTV tombstone cannot delete earlier pending local credential or metadata")
            check(world.secure.store.confirmedRead(iptvSlot, isCurrentOwner: { true })?.result == .value(local),
                "IPTV refused receive does not leak nested lifetime or publication exclusion")
        }
        // Actual CAS: planning read survives neither a same-value intent nor missing-slot fill
        // completed before CAS entry. The backend is synthetic; the read witness and CAS are real.
        for sameValue in [false, true] {
            let backend = SyntheticCredentialBackend(), slot = "synthetic-cas"
            if sameValue { backend.values[slot] = "local" }
            let secure = backend.store
            guard let observed = secure.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
            check(secure.set("local", for: slot) == .success, "ordinary local writer completes between planning and CAS")
            let priorWrites = backend.writes
            check(secure.compareAndSetConfirmed(observed, with: nil, account: slot, isCurrentOwner: { true }) == .failure,
                "CAS entry rejects " + (sameValue ? "same-value planning-generation replacement" : "local fill after missing planning read"))
            check(backend.values[slot] == "local" && backend.writes == priorWrites, "retired planning capability cannot delete newer credential")
        }
        // Retain the distinct later cleanup interleaving as well.
        for sameValue in [false, true] {
            let backend = SyntheticCredentialBackend(), slot = "synthetic-cas"
            if sameValue { backend.values[slot] = "local" }
            let secure = backend.store
            guard let observed = secure.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
            backend.runPurgeHookAt = backend.purgeCount + 1
            backend.purgeHook = { _ = secure.set("local", for: slot) }
            check(secure.compareAndSetConfirmed(observed, with: "remote", account: slot, isCurrentOwner: { true }) == .failure,
                "CAS cleanup rejects " + (sameValue ? "same-value new generation" : "local fill before write"))
            check(backend.values[slot] == "local", "CAS preserves newer local credential")
        }
        do {
            let backend = SyntheticCredentialBackend(); var owns = true
            let secure = backend.store
            guard let observed = secure.confirmedRead("synthetic-cas", isCurrentOwner: { owns }) else { preconditionFailure("planning read") }
            backend.runPurgeHookAt = backend.purgeCount + 1
            backend.purgeHook = { owns = false }
            check(secure.compareAndSetConfirmed(observed, with: "remote", account: "synthetic-cas", isCurrentOwner: { owns }) == .failure && backend.writes == 0,
                "revocation during CAS cleanup forbids credential mutation")
        }
        do {
            let backend = SyntheticCredentialBackend(); var owns = true
            let secure = backend.store
            guard let observed = secure.confirmedRead("synthetic-cas", isCurrentOwner: { owns }) else { preconditionFailure("planning read") }
            owns = false
            check(secure.compareAndSetConfirmed(observed, with: "remote", account: "synthetic-cas", isCurrentOwner: { owns }) == .failure && backend.writes == 0,
                "owner retired after planning cannot enter credential CAS")
        }
        do {
            let backend = SyntheticCredentialBackend(); var owns = true
            backend.purgeHook = { owns = false }
            check(backend.store.confirmedRead("synthetic-cas", isCurrentOwner: { owns }) == nil && backend.writes == 0,
                "retirement during planning cleanup yields no capability")
        }
        do {
            let backend = SyntheticCredentialBackend(); backend.readFailure = true
            check(backend.store.confirmedRead("synthetic-cas", isCurrentOwner: { true }) == nil && backend.writes == 0,
                "unavailable backend yields no confirmed-read capability")
        }
        do {
            let backend = SyntheticCredentialBackend(), other = SyntheticCredentialBackend(), slot = "synthetic-cas"
            guard let observed = backend.store.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
            check(other.store.compareAndSetConfirmed(observed, with: "remote", account: slot, isCurrentOwner: { true }) == .failure && other.writes == 0,
                "capability from another secure-store instance cannot authorize a write")
            check(backend.store.compareAndSetConfirmed(observed, with: "remote", account: "other-slot", isCurrentOwner: { true }) == .failure && backend.writes == 0,
                "capability for another slot cannot authorize a write")
        }
        do {
            let backend = SyntheticCredentialBackend(), slot = "synthetic-cas", candidate = "\u{00e9}", alternate = "e\u{0301}"
            check(candidate == alternate && Data(candidate.utf8) != Data(alternate.utf8), "canonical equality is weaker than credential UTF8 identity")
            guard let observed = backend.store.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
            backend.alternateWrittenValue = alternate
            check(backend.store.compareAndSetConfirmed(observed, with: candidate, account: slot, isCurrentOwner: { true }) == .failure,
                "CAS itself rejects canonically equivalent byte-different replacement readback")
            check(backend.values[slot + ".invalid"] == "invalid" && backend.store.confirmedString(slot) == .failure,
                "inexact replacement remains invalidated and unavailable to confirmed readers")
        }
        for replacement in [Optional("exact-remote"), nil] {
            let backend = SyntheticCredentialBackend(), slot = "synthetic-cas"
            if replacement == nil { backend.values[slot] = "exact-old" }
            guard let observed = backend.store.confirmedRead(slot, isCurrentOwner: { true }) else { preconditionFailure("planning read") }
            check(backend.store.compareAndSetConfirmed(observed, with: replacement, account: slot, isCurrentOwner: { true }) == .success,
                "current capability exact value/delete readback succeeds")
            check(AccountProviderSyncBlob.sameCredential(backend.store.confirmedString(slot), replacement.map(CredentialDurableReadResult.value) ?? .missing),
                "successful CAS final readback matches exact expected state")
            check(backend.store.compareAndSetConfirmed(observed, with: "replay", account: slot, isCurrentOwner: { true }) == .failure,
                "successful CAS consumes old generation capability")
        }
        do {
            let backend = SyntheticCredentialBackend(), slot = "synthetic-cas"; var owns = true
            guard let observed = backend.store.confirmedRead(slot, isCurrentOwner: { owns }) else { preconditionFailure("planning read") }
            backend.writeHook = { owns = false }
            check(backend.store.compareAndSetConfirmed(observed, with: "remote", account: slot, isCurrentOwner: { owns }) == .failure && backend.values[slot + ".invalid"] == "invalid",
                "owner retirement during write cannot clear uncertainty or claim success")
        }
        for sameValue in [false, true] {
            let world = World(), slot = ms(id)
            let old = MediaServerRecord(id: id, name: "old", kind: .jellyfin, urls: [], userId: "", addedAt: Date(timeIntervalSince1970: 1))
            if sameValue { world.list = try JSONEncoder().encode([old]); world.secure.values[slot] = "local" }
            let secure = world.secure.store
            world.afterPlanningRead = { _ = secure.set("local", for: slot) }
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO(), servers: sameValue ? [old] : [])
            let source = sameValue ? String(decoding: try JSONSerialization.data(withJSONObject: ["v":1,"servers":[],"removed":[id.uuidString:2000]]), as: UTF8.self) : try media()
            check(!settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })),
                "actual media planning refuses same-value tombstone replacement or local slot fill before CAS")
            check(world.secure.values[slot] == "local" && world.persistCount == 0 && store.servers == (sameValue ? [old] : []),
                "retired media plan preserves token and original records")
        }
        for sameValue in [false, true] {
            let world = World(), local = #"{"m3uURL":"https://synthetic.invalid/local"}"#
            let old = IPTVPlaylist(id: "synthetic-playlist", name: "old", kind: .m3u, transportUrl: "https://synthetic.invalid/manifest.json", createdAt: Date(timeIntervalSince1970: 1))
            if sameValue { world.list = try JSONEncoder().encode([old]); world.secure.values[iptvSlot] = local }
            let secure = world.secure.store
            world.afterPlanningRead = { _ = secure.set(local, for: iptvSlot) }
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO(), playlists: sameValue ? [old] : [])
            let source = sameValue ? String(decoding: try JSONSerialization.data(withJSONObject: ["v":1,"playlists":[],"removed":["synthetic-playlist":2000]]), as: UTF8.self) : try iptv()
            check(!settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })),
                "actual IPTV planning refuses same-value tombstone replacement or local slot fill before CAS")
            check(world.secure.values[iptvSlot] == local && world.persistCount == 0 && store.playlists == (sameValue ? [old] : []),
                "retired IPTV plan preserves raw credential and original records")
        }
        do {
            let old = MediaServerRecord(id: id, name: "old", kind: .jellyfin, urls: [], userId: "", addedAt: Date(timeIntervalSince1970: 1))
            let world = World(); world.list = try JSONEncoder().encode([old]); world.secure.values[ms(id)] = "old-token"
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO(), servers: [old])
            var root = try OwnerHistoryExactJSON.Object(Data(media(3000, token: "new-token").utf8))
            root.set("removed", try JSONSerialization.data(withJSONObject: [id.uuidString:2000]))
            check(settled(store.applySyncBlobSettled(String(decoding: try root.encoded(), as: UTF8.self), operationID: UUID(), isCurrent: { world.active })),
                "media tombstone and newer remote re-add settle against one original capability")
            check(world.secure.values[ms(id)] == "new-token" && world.secure.writes == 1 && store.servers.first?.addedAt == Date(timeIntervalSince1970: 3),
                "media coalesces slot effects without fabricated intermediate absence")
        }
        do {
            let old = IPTVPlaylist(id: "synthetic-playlist", name: "old", kind: .m3u, transportUrl: "https://synthetic.invalid/manifest", createdAt: Date(timeIntervalSince1970: 1))
            let world = World(); world.list = try JSONEncoder().encode([old]); world.secure.values[iptvSlot] = #"{"m3uURL":"https://synthetic.invalid/old"}"#
            let replacement = #"{"m3uURL":"https://synthetic.invalid/new","future":{"number":1.00}}"#
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO(), playlists: [old])
            var root = try OwnerHistoryExactJSON.Object(Data(iptv(3000, credential: replacement).utf8))
            root.set("removed", try JSONSerialization.data(withJSONObject: ["synthetic-playlist":2000]))
            check(settled(store.applySyncBlobSettled(String(decoding: try root.encoded(), as: UTF8.self), operationID: UUID(), isCurrent: { world.active })),
                "IPTV tombstone and newer remote re-add settle against one original capability")
            check(world.secure.values[iptvSlot].map { Data($0.utf8) } == Data(replacement.utf8) && world.secure.writes == 1 && store.playlists.first?.createdAt == Date(timeIntervalSince1970: 3),
                "IPTV coalesces slot effects and preserves raw replacement bytes")
        }
        do {
            let world = World(), source = try media(), operation = UUID()
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            let result = store.applySyncBlobSettled(source, operationID: operation, isCurrent: { world.active })
            guard case .settled(let receipt) = result else { preconditionFailure("media positive refused") }
            check(receipt.matches(source: source, operationID: operation), "media receipt binds exact source and receive UUID")
            check(!receipt.matches(source: source + " ", operationID: operation) && !receipt.matches(source: source, operationID: UUID()), "media receipt cannot cover different source/receive")
            check(world.secure.values[ms(id)] == "synthetic-remote" && store.servers.count == 1 && !store.servers[0].needsReauth,
                "media actual merge installs missing token and metadata")
            check(world.persistCount == 1 && world.coordinatorCount == 1 && world.installed.first?.apiKey == "synthetic-remote", "media verifies persistence and actual projected coordinator input")
        }
        do {
            let world = World(), source = try media()
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            store.fixtureQueueLegacyCoordinatorReload()
            check(settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })), "checked media publication completes before return")
            await store.fixtureDrainLegacyCoordinatorReload()
            check(MediaServerCoordinator.shared.installed == world.installed && !world.installed.isEmpty,
                "older queued coordinator task cannot overwrite checked publication")
        }
        do {
            let world = World(), source = try media(), box = ProviderSettlementTaskBox()
            world.secure.writeHook = { box.task?.cancel() }
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            box.task = Task { store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active }) }
            let result = await box.task!.value
            check(!settled(result) && world.persistCount == 0,
                "Task cancellation during credential IO cannot claim completion or publish metadata")
            check(world.secure.store.set("local-after-cancel", for: ms(id)) == .success && world.secure.store.confirmedRead(ms(id), isCurrentOwner: { true })?.result == .value("local-after-cancel"),
                "cancelled checked apply releases actual CAS lease for genuine local successor")
        }
        for noToken in [false, true] {
            let world = World(), source = try media(token: noToken ? nil : "remote")
            world.secure.values[ms(id)] = noToken ? nil : "local-authoritative"
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            check(settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })), "media supports local-authoritative or metadata-only source")
            check(noToken ? (store.servers[0].needsReauth && world.installed.isEmpty) : world.secure.values[ms(id)] == "local-authoritative", "media preserves Keychain authority and needsReauth semantics")
        }
        do {
            let old = MediaServerRecord(id: id, name: "old", kind: .jellyfin, urls: ["https://synthetic.invalid"], userId: "", addedAt: Date(timeIntervalSince1970: 1))
            let kept = MediaServerRecord(id: sibling, name: "kept", kind: .plex, urls: [], userId: "", addedAt: Date(timeIntervalSince1970: 3))
            let world = World(); world.list = try JSONEncoder().encode([old, kept]); world.secure.values[ms(id)] = "old-token"
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO(), servers: [old, kept])
            let source = String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1, "servers": [], "removed": [id.uuidString: 2000]]), as: UTF8.self)
            check(settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })), "media tombstone-only source settles")
            check(store.servers.map(\.id) == [sibling] && world.secure.values[ms(id)] == nil, "media tombstone removes only older local record/credential")
        }
        do {
            let newest = MediaServerRecord(id: id, name: "newer local", kind: .jellyfin, urls: [], userId: "", addedAt: Date(timeIntervalSince1970: 4))
            let world = World(); world.list = try JSONEncoder().encode([newest]); world.secure.values[ms(id)] = "newer-token"
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO(), servers: [newest])
            var root = try OwnerHistoryExactJSON.Object(Data(media().utf8)); root.set("removed", try JSONSerialization.data(withJSONObject: [id.uuidString: 2000]))
            check(settled(store.applySyncBlobSettled(String(decoding: try root.encoded(), as: UTF8.self), operationID: UUID(), isCurrent: { world.active })) && store.servers == [newest] && world.secure.values[ms(id)] == "newer-token", "older remote row/tombstone cannot delete newer local re-add")
        }
        do {
            let old = MediaServerRecord(id: id, name: "old", kind: .jellyfin, urls: [], userId: "", addedAt: Date(timeIntervalSince1970: 1))
            let world = World(); world.list = try JSONEncoder().encode([old]); world.secure.values[ms(id)] = "old-token"
            let secure = world.secure.store
            world.secure.runPurgeHookAt = 2
            world.secure.purgeHook = { _ = secure.set("newer-local-token", for: ms(id)) }
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO(), servers: [old])
            let source = String(decoding: try JSONSerialization.data(withJSONObject: ["v":1,"servers":[],"removed":[id.uuidString:2000]]), as: UTF8.self)
            check(!settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })), "tombstone delete refuses a concurrent credential replacement")
            check(world.secure.values[ms(id)] == "newer-local-token" && store.servers == [old] && world.persistCount == 0,
                "failed delete CAS preserves newer local token and prior records")
        }
        do {
            let world = World(); world.list = Data("unreadable persisted metadata".utf8)
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            check(!settled(store.applySyncBlobSettled(try media(), operationID: UUID(), isCurrent: { world.active })) && world.secure.writes == 0,
                "unreadable current media metadata is unknown not an empty baseline")
        }
        for mode in ["read", "write", "readback", "sync", "persist", "corrupt", "coordinator", "cancel-persist", "cancel-before"] {
            let world = World(), source = try media()
            switch mode {
            case "read": world.secure.readFailure = true
            case "write": world.secure.failWrite = true
            case "readback": world.secure.wrongReadback = true
            case "sync": world.syncOK = false
            case "persist": world.persistOK = false
            case "corrupt": world.corruptPersist = true
            case "coordinator": world.coordinatorOK = false
            case "cancel-persist": world.revokePersist = true
            default: world.active = false
            }
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            check(!settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })), "media refuses " + mode + " without completion receipt")
        }
        for source in [#"{"v":1,"servers":[{"id":"bad"}]}"#, #"{"v":1,"v":1}"#,
                       #"{"v":1,"servers":[{"id":"10000000-0000-0000-0000-000000000001","kind":"plex","name":"x","urls":[]}]}"#] {
            let world = World()
            let store = MediaServerStore(settlementFixtureIO: world.mediaIO())
            check(!settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })) && world.secure.writes == 0,
                "media malformed/ambiguous/missing timestamp source never settles")
        }
        do {
            let world = World(), source = try iptv(), operation = UUID()
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO())
            guard case .settled(let receipt) = store.applySyncBlobSettled(source, operationID: operation, isCurrent: { world.active }) else { preconditionFailure("IPTV positive refused") }
            check(receipt.matches(source: source, operationID: operation) && !receipt.matches(source: source, operationID: UUID()), "IPTV receipt binds exact source and receive")
            check(world.secure.values[iptvSlot] != nil && store.playlists.count == 1 && world.persistCount == 1, "IPTV checks missing credential and metadata adoption")
        }
        do {
            let world = World(); world.secure.values[iptvSlot] = #"{"m3uURL":"https://local.invalid/list","future":"kept"}"#
            let prior = world.secure.values[iptvSlot]
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO())
            check(settled(store.applySyncBlobSettled(try iptv(), operationID: UUID(), isCurrent: { world.active })) && world.secure.values[iptvSlot] == prior,
                "IPTV preserves complete local-authoritative opaque credential bytes")
        }
        do {
            let world = World()
            let original = #"{ "m3uURL":"https://synthetic.invalid/list", "future":{"number":1.00,"order":[3,2,1]}, "xmltvURL":null }"#
            world.secure.values[iptvSlot] = original
            let row = IPTVPlaylist(id: "synthetic-playlist", name: "Synthetic", kind: .m3u, transportUrl: "https://synthetic.invalid/manifest", createdAt: Date(timeIntervalSince1970: 1))
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO(), playlists: [row])
            guard let exported = store.syncBlob() else { preconditionFailure("metadata export missing") }
            let root = try OwnerHistoryExactJSON.Object(Data(exported.utf8))
            let rows = try OwnerHistoryExactJSON.array(root.required("playlists"))
            let emitted = try OwnerHistoryExactJSON.Object(rows[0]).text("cred")
            check(Data(emitted.utf8) == Data(original.utf8), "actual IPTV export retains raw unknown credential fields numeric spelling and order")
            world.secure.readFailure = true
            let unavailable = try OwnerHistoryExactJSON.Object(Data(store.syncBlob()!.utf8))
            let unavailableRows = try OwnerHistoryExactJSON.array(unavailable.required("playlists"))
            check(try OwnerHistoryExactJSON.Object(unavailableRows[0])["cred"] == nil, "IPTV unavailable credential still exports metadata without guessing a secret")
        }
        do {
            let old = IPTVPlaylist(id: "synthetic-playlist", name: "old", kind: .m3u, transportUrl: "https://synthetic.invalid/manifest", createdAt: Date(timeIntervalSince1970: 1))
            let world = World(); world.list = try JSONEncoder().encode([old]); world.secure.values[iptvSlot] = #"{"m3uURL":"https://old.invalid/list"}"#
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO(), playlists: [old])
            let source = #"{"v":1,"playlists":[],"removed":{"synthetic-playlist":2000}}"#
            check(settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })) && store.playlists.isEmpty && world.secure.values[iptvSlot] == nil,
                "IPTV tombstone-only source checks deletion and empty metadata readback")
        }
        do {
            let newer = IPTVPlaylist(id: "synthetic-playlist", name: "newer local", kind: .m3u, transportUrl: "https://local.invalid/manifest", createdAt: Date(timeIntervalSince1970: 4))
            let world = World(); world.list = try JSONEncoder().encode([newer]); world.secure.values[iptvSlot] = #"{"m3uURL":"https://local.invalid/new"}"#
            let before = world.secure.values[iptvSlot]
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO(), playlists: [newer])
            var root = try OwnerHistoryExactJSON.Object(Data(iptv().utf8)); root.set("removed", Data(#"{"synthetic-playlist":2000}"#.utf8))
            check(settled(store.applySyncBlobSettled(String(decoding: try root.encoded(), as: UTF8.self), operationID: UUID(), isCurrent: { world.active })) && store.playlists == [newer] && world.secure.values[iptvSlot] == before,
                "IPTV old remote row/tombstone cannot replace newer local add or credential")
        }
        do {
            let world = World()
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO())
            // Exact source timestamps are required; no Date-now default can certify ordering.
            let source = #"{"v":1,"playlists":[{"id":"synthetic-playlist","name":"x","kind":"m3u","transportUrl":"https://synthetic.invalid"}]}"#
            check(!settled(store.applySyncBlobSettled(source, operationID: UUID(), isCurrent: { world.active })), "IPTV missing source clock never becomes current-time authority")
        }
        for mode in ["read", "write", "persist", "corrupt", "invalid-local", "cancel"] {
            let world = World()
            switch mode {
            case "read": world.secure.readFailure = true
            case "write": world.secure.failWrite = true
            case "persist": world.persistOK = false
            case "corrupt": world.corruptPersist = true
            case "invalid-local": world.secure.values[iptvSlot] = "unreadable-local-credential"
            default: world.active = false
            }
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO())
            check(!settled(store.applySyncBlobSettled(try iptv(), operationID: UUID(), isCurrent: { world.active })), "IPTV refuses " + mode + " without completion")
        }
        do {
            let world = World()
            let store = IPTVPlaylistStore(settlementFixtureIO: world.iptvIO())
            CredentialPublicationOutbox.busy = true
            check(!settled(store.applySyncBlobSettled(try iptv(), operationID: UUID(), isCurrent: { world.active })), "owner publication exclusion never waits or claims settlement")
            CredentialPublicationOutbox.busy = false
        }
        print("All actual provider-store settlement checks passed with explicit synthetic IO.")
    }
}
