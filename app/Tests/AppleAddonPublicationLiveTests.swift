import Foundation
import CryptoKit

/// Controls only synthetic checkpoint acknowledgement while the production C ABI still runs.
private final class AddonCheckpointGate: VortxCheckpointStore, @unchecked Sendable {
    enum Failure: Error { case refused }
    let backing: VortxEncryptedCheckpointStore
    private let condition = NSCondition()
    private var reject = false
    private var hold = false
    private var entered = false
    init(_ backing: VortxEncryptedCheckpointStore) { self.backing = backing }
    func rejectNext() { condition.withLock { reject = true } }
    func holdNext() { condition.withLock { entered = false; hold = true } }
    func release() { condition.withLock { hold = false; condition.broadcast() } }
    func waitUntilEntered() async throws {
        for _ in 0..<400 {
            if condition.withLock({ entered }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure.refused
    }
    private func authorize() throws {
        condition.lock(); defer { condition.unlock() }
        if reject { reject = false; throw Failure.refused }
        if hold {
            entered = true
            while hold { condition.wait() }
        }
    }
    func read(scope: VortxAccountScope) throws -> String? { try backing.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { try backing.readHostPreferences(scope: scope) }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { try backing.readLegacyMaterial(scope: scope) }
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? { try backing.readLegacyProfileEdits(scope: scope) }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws { try authorize(); try backing.commit(snapshot, scope: scope) }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        try authorize(); try backing.commit(snapshot, scope: scope, hostPreferences: hostPreferences)
    }
}

/// Exact production CoreCtx/manifest declarations and the real packaged native C ABI.
/// No app, customer account, provider, Keychain, player or media process participates.
@main @MainActor enum AppleAddonPublicationLiveTests {
    enum Failure: Error { case assertion(String) }
    static let owner = "10000000-0000-0000-0000-000000000022"
    static let shared = "20000000-0000-0000-0000-000000000022"
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
    }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func decode(_ facade: VortxNativeCoreFacade) throws -> CoreCtx {
        guard let data = facade.stateData("ctx") else { throw Failure.assertion("missing native ctx") }
        return try JSONDecoder().decode(CoreCtx.self, from: data)
    }
    static func reject(_ value: VortxJSON) throws {
        do {
            _ = try value.decode(CoreCtx.self)
            throw Failure.assertion("malformed whole roster was accepted")
        } catch is DecodingError {}
    }
    static func main() async {
        do { try await run() }
        catch {
            // Decoding paths and fixture assertion text are safe; never dump transport/raw state.
            if case DecodingError.keyNotFound(let key, let context) = error {
                print("RED Apple add-on publication: missing key=\(key.stringValue) path=\(context.codingPath.map(\.stringValue).joined(separator: "."))")
            } else { print("FAIL Apple add-on publication: \(error)") }
            exit(1)
        }
    }
    static func run() async throws {
        let port = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let holdStreams = URL(fileURLWithPath: CommandLine.arguments[3])
        defer { try? FileManager.default.removeItem(at: holdStreams) }
        let transport = try VortxCResourceTransport()
        let bridge = VortxResourceBridge(transport: transport)
        var fetched: [VortxResourceAddon] = []
        for index in 0..<22 {
            let url = "http://127.0.0.1:\(port)/addon-\(String(format: "%02d", index))/manifest.json"
            let addon = VortxResourceAddon(id: "wire-\(index)", transportUrl: url, manifest: nil)
            let response = try await bridge.load(ownerID: owner, request: .init(resource: .manifest, type: "", id: ""), addons: [addon])
            try check(response.groups.count == 1 && response.groups[0].status == .ready, "loopback manifest did not load")
            let manifest = response.groups[0].content!
            try check(index == 21 ? manifest["catalogs"]?.array?.count == 1 : manifest["catalogs"] == nil,
                      "wire fixture must retain absent catalogs")
            fetched.append(.init(id: addon.id, transportUrl: url, manifest: manifest))
        }
        let scope = VortxAccountScope(account: "synthetic.addon-publication", ownerProfileID: owner)
        let checkpoint = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        let session = try VortxNativeSession(scope: scope, ownerName: "Synthetic Owner", abi: VortxCABI(), store: checkpoint,
                                            transport: transport, allowNewAccount: true)
        let order = Array(fetched.reversed()).map(\.transportUrl)
        var actions = try fetched.map { addon in try raw(.object(["type": .string("install_addon"), "profileId": .string(owner),
            "addon": .object(["transportUrl": .string(addon.transportUrl), "manifest": addon.manifest!])])) }
        actions.append(try raw(.object(["type": .string("reorder_addons"), "profileId": .string(owner),
                                      "transportUrls": .array(order.map(VortxJSON.string))])))
        _ = try await session.dispatch(actions, now: 1000)
        let registry = try await session.resourceRegistry()
        try check(registry.map(\.transportUrl) == order && registry.count == 22, "native order or membership changed")
        for addon in registry {
            let original = fetched.first { $0.transportUrl == addon.transportUrl }!
            // The kernel normalizes manifest extensions. Its accepted receipt, rather than the
            // external wire object, is the raw source CoreBridge must retain unchanged.
            if original.manifest?["catalogs"] == nil {
                try check(addon.manifest?["catalogs"] == .array([]), "kernel stream-only catalog default changed")
            } else {
                try check(addon.manifest?["catalogs"]?.array?.count == 1 && addon.manifest?["catalogs"]?.array?.first?["id"] == .string("popular"), "kernel changed catalog declaration")
            }
            try check(addon.manifest?["name"] == original.manifest?["name"], "kernel changed manifest identity")
        }
        let streamOnly = registry.last!
        let sources = try await bridge.load(ownerID: owner, request: .init(resource: .stream, type: "movie", id: "fixture-movie"), addons: [streamOnly])
        try check(sources.groups.count == 1 && sources.groups[0].status == .ready,
                  "installed stream-only add-on did not load actual HTTP sources")
        try check(sources.groups[0].content?["streams"]?.array?.first?["behaviorHints"]?["proxyHeaders"]?["request"]?["X-Synthetic"] == .string("retained"),
                  "resource extensions lost")
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: registry, changed: { _ in })
        let rawContext = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("ctx")!)
        try check(rawContext["profile"]?["addons"]?.array?.map { $0["manifest"] } == registry.map(\.manifest),
                  "facade presentation receipt mutated raw descriptors")
        print("Actual native/HTTP proof: 22 ordered add-ons installed; wire catalog omission becomes canonical empty array; stream-only HTTP sources loaded")

        // Verify the actual native path separately: the kernel already defaults absent catalogs.
        let context = try decode(facade)
        try check(context.profile.addons.map(\.transportUrl) == order, "Apple roster order changed")
        try check(context.profile.addons.count == 22 && context.profile.addons.filter(\.hasCatalogs).count == 1,
                  "Apple publication omitted stream-only or catalog add-ons")
        try check(context.profile.addons.allSatisfy(\.providesStreams), "stream capability lost")
        let load: VortxJSON = .object(["action": .string("Load"), "args": .object(["model": .string("CatalogsWithExtra"), "args": .object(["extra": .array([])])])])
        try check(facade.dispatch(data: try JSONEncoder().encode(load), field: "board"), "catalog dispatch refused")
        let range: VortxJSON = .object(["action": .string("CatalogsWithExtra"), "args": .object(["action": .string("LoadRange"), "args": .object(["start": .integer(0), "end": .integer(30)])])])
        try check(facade.dispatch(data: try JSONEncoder().encode(range), field: "board"), "catalog range dispatch refused")
        await facade.settled()
        let board = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("board")!)
        try check(board["catalogs"]?.array?.count == 1 && board["catalogs"]?.array?.first?.array?.first?["content"]?["type"] == .string("Ready"), "catalog peer did not remain ready")

        // The periodic sync caller merges into this facade. A semantically unchanged merge must
        // not retire the current registry or a real, already-started loopback resource load.
        let unchangedCarrier = try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: nil)
        let fetchingBinding = facade.registryBinding!
        let fetchingReceipt = facade.captureEpisodeSourceRegistry()!
        try Data("hold".utf8).write(to: holdStreams)
        let streamPath: VortxJSON = .object(["resource": .string("stream"), "type": .string("movie"), "id": .string("fixture-movie"), "extra": .array([])])
        let metaPath: VortxJSON = .object(["resource": .string("meta"), "type": .string("movie"), "id": .string("fixture-movie"), "extra": .array([])])
        let metaLoad: VortxJSON = .object(["action": .string("Load"), "args": .object(["model": .string("MetaDetails"),
            "args": .object(["metaPath": metaPath, "streamPath": streamPath])])])
        try check(facade.dispatch(data: try JSONEncoder().encode(metaLoad), field: "meta_details"), "held source load refused")
        var sourceEntered = false
        for _ in 0..<400 {
            if FileManager.default.fileExists(atPath: holdStreams.path + ".entered") { sourceEntered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try check(sourceEntered, "actual loopback source request did not begin")
        _ = try await facade.mergeAccountDocument(unchangedCarrier["nativeSync"], hostRemote: unchangedCarrier["nativeHostPreferences"], legacyMaterial: nil)
        try check(facade.registryBinding == fetchingBinding && fetchingReceipt.isCurrent(), "unchanged sync invalidated active source registry")
        try FileManager.default.removeItem(at: holdStreams)
        await facade.settled()
        let sourceScreen = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("meta_details")!)
        try check(sourceScreen["streams"]?.array?.count == 22 && sourceScreen["streams"]?.array?.allSatisfy { $0["content"]?["type"] == .string("Ready") } == true,
                  "unchanged sync cancelled or lost in-flight source publication")
        print("Unchanged nonnil native/account carrier merge while actual HTTP sources are held PASS: registry epoch retained and all 22 sources publish Ready")

        func dispatch(_ action: VortxJSON) async throws {
            let wrapped = VortxJSON.object(["action": .string("Vortx"), "args": action])
            try check(facade.dispatch(data: try JSONEncoder().encode(wrapped), field: "native_state"), "native action admission failed")
            await facade.settled()
            try check(facade.lastFailure == nil, "native action settlement failed")
        }
        try await dispatch(.object(["type": .string("add_profile"), "id": .string(shared), "name": .string("Synthetic Viewer")]))
        try await dispatch(.object(["type": .string("patch_profile"), "id": .string(shared), "edits": .array([
            .object(["field": .string("disabledAddons"), "value": .array([.string(order[0])])])])]))
        try await dispatch(.object(["type": .string("switch_profile"), "id": .string(shared)]))
        try check(try decode(facade).profile.addons.map(\.transportUrl) == Array(order.dropFirst()), "shared profile visibility or order wrong")
        try await dispatch(.object(["type": .string("switch_profile"), "id": .string(owner)]))
        try check(try decode(facade).profile.addons.map(\.transportUrl) == order, "owner roster inherited child filtering")
        let tombstoned = order[1]
        try await dispatch(.object(["type": .string("remove_addon"), "profileId": .string(owner), "transportUrl": .string(tombstoned)]))
        try check(try decode(facade).profile.addons.map(\.transportUrl) == order.filter { $0 != tombstoned }, "native tombstone not honored by Apple roster")
        let state = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_state")!)
        let removal = state["nativeSync"]?["addons"]?[owner]?["records"]?[tombstoned]
        try check(removal?["removedAt"] != nil && removal?["removedAt"] != .null && removal?["removedAt"] != removal?["addedAt"], "durable deletion clock missing")
        try await dispatch(.object(["type": .string("switch_profile"), "id": .string(shared)]))
        try check(try decode(facade).profile.addons.map(\.transportUrl) == order.filter { $0 != order[0] && $0 != tombstoned }, "shared profile resurrected tombstone")

        let valid = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("ctx")!)
        for bad in [VortxJSON.null, .string("wrong"), .object([:]), .integer(3), .array([.null]), .array([.object(["id": .string("missing-type")])])] {
            var descriptor = valid["profile"]!["addons"]!.array!.first!.decodeObject()
            var manifest = descriptor["manifest"]!.decodeObject(); manifest["catalogs"] = bad
            descriptor["manifest"] = .object(manifest)
            try reject(.object(["profile": .object(["addons": .array([.object(descriptor)])])]))
        }
        try reject(.object(["profile": .object(["addons": .string("wrong")])]))
        try reject(.object(["profile": .object(["addons": .array([.object(["manifest": .object(["resources": .array([.string("stream")])]), "transportUrl": .string("https://synthetic.invalid/manifest.json")])])])]))
        try check(try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("ctx")!) == valid,
                  "typed decode changed the native raw receipt")
        await facade.shutdown()
        let gate = AddonCheckpointGate(checkpoint)
        let cold = try VortxNativeSession(scope: scope, ownerName: "Synthetic Owner", abi: VortxCABI(), store: gate, transport: transport)
        try check(try await cold.resourceRegistry().map(\.transportUrl) == order.filter { $0 != order[0] && $0 != tombstoned },
                  "cold checkpoint resurrected tombstone or lost shared visibility")
        print("Native baseline PASS: 22 typed roster/order; one HTTP catalog; owner/shared visibility; durable tombstone; malformed whole receipts reject; accepted native raw receipt untouched")
        let updateFacade = try await VortxNativeCoreFacade.create(session: cold, registry: cold.resourceRegistry(), changed: { _ in })
        func updateDispatch(_ action: VortxJSON, field: String) async throws {
            try check(updateFacade.dispatch(data: try JSONEncoder().encode(action), field: field), "update fixture dispatch refused")
            await updateFacade.settled()
            try check(updateFacade.lastFailure == nil, "update fixture settlement failed")
        }
        try await updateDispatch(.object(["action": .string("Vortx"), "args": .object(["type": .string("switch_profile"), "id": .string(owner)])]), field: "native_state")
        let updatedURL = order.last!
        let oldDescriptor = try JSONDecoder().decode(VortxJSON.self, from: updateFacade.stateData("ctx")!)["profile"]!["addons"]!.array!.first { $0["transportUrl"] == .string(updatedURL) }!
        var updatedManifest = fetched.first { $0.transportUrl == updatedURL }!.manifest!.decodeObject()
        updatedManifest["name"] = .string("Synthetic Updated Add-on")
        let requestedManifest = VortxJSON.object(updatedManifest)
        let duplicateInstall: VortxJSON = .object(["action": .string("Ctx"), "args": .object(["action": .string("InstallAddonLocal"), "args": .object([
            "transportUrl": .string(updatedURL), "manifest": requestedManifest])])])
        try check(!updateFacade.dispatch(data: try JSONEncoder().encode(duplicateInstall), field: "ctx") && updateFacade.lastFailure == "invalid_or_duplicate_addon",
                  "native duplicate install contract changed")
        print("Existing-URL InstallAddonLocal rejected: actual native duplicate admission confirms Update must select authoritative ReplaceAddonLocal")
        let replacement: VortxJSON = .object(["action": .string("Ctx"), "args": .object(["action": .string("ReplaceAddonLocal"), "args": .object([
            "old": oldDescriptor, "new": .object(["transportUrl": .string(updatedURL), "manifest": requestedManifest])])])])
        try await updateDispatch(replacement, field: "ctx")
        let updatedContext = try decode(updateFacade)
        try check(updatedContext.profile.addons.map(\.transportUrl) == order.filter { $0 != tombstoned }, "same-URL update changed order or resurrected tombstone")
        try check(updatedContext.profile.addons.first { $0.transportUrl == updatedURL }?.manifest.name == "Synthetic Updated Add-on", "native replacement did not commit new manifest")
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requestedManifest)) as! [String: Any]
        let previous = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldDescriptor["manifest"]!)) as! [String: Any]
        let probe = AddonConfirmationProbe(nativeFacade: updateFacade)
        try probe.refresh()
        probe.usesNativeProfileState = false
        let published = probe.rawAddonsByUrl[updatedURL]!["manifest"] as! [String: Any]
        try check(probe.confirmedInstalled(updatedURL, replacingManifest: nil, expectedManifest: expected), "legacy first install membership confirmation changed")
        try check(probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: published), "legacy exact manifest confirmation changed")
        try check(!probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "legacy wire mismatch must not be relaxed")
        probe.usesNativeProfileState = true
        print("Actual replacement PASS: native same-URL update committed canonical manifest with empty catalogs; existing order, visibility and tombstone preserved")
        try check(probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected),
                  "production confirmedInstalled rejects acknowledged native same-URL update because canonical manifest differs from wire manifest")
        var mismatched = expected; mismatched["name"] = "Unacknowledged name"
        try check(!probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: mismatched), "unacknowledged manifest was confirmed")
        func updateAction(_ manifest: VortxJSON) throws -> VortxJSON {
            let current = try JSONDecoder().decode(VortxJSON.self, from: updateFacade.stateData("ctx")!)["profile"]!["addons"]!.array!.first { $0["transportUrl"] == .string(updatedURL) }!
            return .object(["action": .string("Ctx"), "args": .object(["action": .string("ReplaceAddonLocal"), "args": .object([
                "old": current, "new": .object(["transportUrl": .string(updatedURL), "manifest": manifest])])])])
        }
        // Repeated identical wire input still needs this operation's acknowledgement.
        try await updateDispatch(updateAction(requestedManifest), field: "ctx")
        try probe.refresh()
        try check(probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "repeat same-URL update did not confirm")
        try check(probe.addons.map(\.transportUrl) == order.filter { $0 != tombstoned }, "repeat update changed order")
        try await updateFacade.rebindRegistry(cold.resourceRegistry(), expected: updateFacade.registryBinding!)
        try probe.refresh()
        try check(!probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "explicit rebind reused old acknowledgement")
        try await updateDispatch(updateAction(requestedManifest), field: "ctx")
        gate.holdNext()
        var lateManifest = updatedManifest; lateManifest["name"] = .string("Synthetic Late Update")
        let heldAction = try updateAction(.object(lateManifest))
        try check(updateFacade.dispatch(data: try JSONEncoder().encode(heldAction), field: "ctx"), "held update was not admitted")
        try await gate.waitUntilEntered()
        // This rejected newer operation retires the held operation's confirmation epoch.
        try check(!updateFacade.dispatch(data: try JSONEncoder().encode(duplicateInstall), field: "ctx"), "superseding duplicate unexpectedly admitted")
        gate.release(); await updateFacade.settled(); try probe.refresh()
        let lateExpected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VortxJSON.object(lateManifest))) as! [String: Any]
        try check(probe.addons.first { $0.transportUrl == updatedURL }?.manifest.name == "Synthetic Late Update", "held native mutation did not complete")
        try check(!probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: lateExpected), "late older completion crossed operation epoch")
        try await updateDispatch(updateAction(requestedManifest), field: "ctx")
        for profile in [shared, owner] {
            try await updateDispatch(.object(["action": .string("Vortx"), "args": .object(["type": .string("switch_profile"), "id": .string(profile)])]), field: "native_state")
        }
        try probe.refresh()
        try check(!probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "profile ABA reused old addon update receipt")
        try await updateDispatch(updateAction(requestedManifest), field: "ctx")
        let updatedRaw = try JSONDecoder().decode(VortxJSON.self, from: updateFacade.stateData("ctx")!)["profile"]!["addons"]!.array!.first { $0["transportUrl"] == .string(updatedURL) }!
        try await updateDispatch(.object(["action": .string("Ctx"), "args": .object(["action": .string("UninstallAddonLocal"), "args": updatedRaw])]), field: "ctx")
        try probe.refresh()
        try check(!probe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "removal reused old acknowledgement")
        await updateFacade.shutdown()
        let otherScope = VortxAccountScope(account: "synthetic.other-addon-account", ownerProfileID: owner)
        let otherStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("other-account"), key: SymmetricKey(size: .bits256))
        let otherGate = AddonCheckpointGate(otherStore)
        let otherSession = try VortxNativeSession(scope: otherScope, ownerName: "Other Synthetic Owner", abi: VortxCABI(), store: otherGate, transport: transport, allowNewAccount: true)
        _ = try await otherSession.dispatch([raw(.object(["type": .string("install_addon"), "profileId": .string(owner), "addon": .object(["transportUrl": .string(updatedURL), "manifest": requestedManifest])]))], now: 1000)
        let otherFacade = try await VortxNativeCoreFacade.create(session: otherSession, registry: otherSession.resourceRegistry(), changed: { _ in })
        let otherProbe = AddonConfirmationProbe(nativeFacade: otherFacade); try otherProbe.refresh()
        try check(otherProbe.addons.contains { $0.transportUrl == updatedURL } && !otherProbe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "new account borrowed old acknowledgement")
        let firstInstall = fetched[1]
        let firstInstallAction: VortxJSON = .object(["action": .string("Ctx"), "args": .object(["action": .string("InstallAddonLocal"), "args": .object([
            "transportUrl": .string(firstInstall.transportUrl), "manifest": firstInstall.manifest!])])])
        try check(otherFacade.dispatch(data: try JSONEncoder().encode(firstInstallAction), field: "ctx"), "new native install refused")
        await otherFacade.settled(); try otherProbe.refresh()
        let firstInstallExpected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(firstInstall.manifest!)) as! [String: Any]
        try check(otherProbe.confirmedInstalled(firstInstall.transportUrl, replacingManifest: nil, expectedManifest: firstInstallExpected), "first native install did not acknowledge canonical receipt")
        let otherDescriptor = try JSONDecoder().decode(VortxJSON.self, from: otherFacade.stateData("ctx")!)["profile"]!["addons"]!.array!.first!
        let otherReplacement: VortxJSON = .object(["action": .string("Ctx"), "args": .object(["action": .string("ReplaceAddonLocal"), "args": .object([
            "old": otherDescriptor, "new": .object(["transportUrl": .string(updatedURL), "manifest": requestedManifest])])])])
        try check(otherFacade.dispatch(data: try JSONEncoder().encode(otherReplacement), field: "ctx"), "other account update refused")
        await otherFacade.settled(); try otherProbe.refresh()
        try check(otherProbe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "other account did not acknowledge its own accepted update")
        let beforeRejected = try JSONDecoder().decode(VortxJSON.self, from: otherFacade.stateData("ctx")!)
        var refusedManifest = updatedManifest; refusedManifest["name"] = .string("Synthetic Refused Update")
        let refusedReplacement: VortxJSON = .object(["action": .string("Ctx"), "args": .object(["action": .string("ReplaceAddonLocal"), "args": .object([
            "old": otherDescriptor, "new": .object(["transportUrl": .string(updatedURL), "manifest": .object(refusedManifest)])])])])
        otherGate.rejectNext()
        try check(otherFacade.dispatch(data: try JSONEncoder().encode(refusedReplacement), field: "ctx"), "checkpoint-rejected fixture was not admitted")
        await otherFacade.settled()
        try check(try JSONDecoder().decode(VortxJSON.self, from: otherFacade.stateData("ctx")!) == beforeRejected, "rejected checkpoint changed published registry")
        try check(otherFacade.lastFailure == "checkpoint_uncertain_reopen_required", "rejected checkpoint did not require safe reopen")
        try otherProbe.refresh()
        try check(!otherProbe.confirmedInstalled(updatedURL, replacingManifest: previous, expectedManifest: expected), "rejected checkpoint borrowed previous acknowledgement")
        await otherFacade.shutdown()
        let otherCold = try VortxNativeSession(scope: otherScope, ownerName: "Other Synthetic Owner", abi: VortxCABI(), store: otherStore, transport: transport)
        let acceptedColdRegistry = try await otherCold.resourceRegistry()
        try check(acceptedColdRegistry.count == 2 && acceptedColdRegistry.first { $0.transportUrl == updatedURL }?.manifest?["name"] == .string("Synthetic Updated Add-on"), "rejected checkpoint corrupted last accepted roster")
        await otherCold.close()
        let protectedScope = VortxAccountScope(account: "synthetic.protected-addon-account", ownerProfileID: owner)
        let protectedStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("protected-account"), key: SymmetricKey(size: .bits256))
        let protectedSession = try VortxNativeSession(scope: protectedScope, ownerName: "Protected Synthetic Owner", abi: VortxCABI(), store: protectedStore, transport: transport, allowNewAccount: true)
        let protectedInput: VortxJSON = .object(["transportUrl": .string(updatedURL), "manifest": requestedManifest,
            "flags": .object(["protected": .bool(true), "official": .bool(true)])])
        _ = try await protectedSession.dispatch([raw(.object(["type": .string("install_addon"), "profileId": .string(owner), "addon": protectedInput]))], now: 1000)
        let protectedBefore = try await protectedSession.addonSnapshot()
        try check(protectedBefore.inventories[owner]?.first?["flags"]?["protected"] == .bool(true), "protected fixture was not accepted as protected")
        let protectedFacade = try await VortxNativeCoreFacade.create(session: protectedSession, registry: protectedSession.resourceRegistry(), changed: { _ in })
        let protectedReplacement: VortxJSON = .object(["action": .string("Ctx"), "args": .object(["action": .string("ReplaceAddonLocal"), "args": .object([
            "old": protectedInput, "new": .object(["transportUrl": .string(updatedURL), "manifest": .object(refusedManifest)])])])])
        _ = protectedFacade.dispatch(data: try JSONEncoder().encode(protectedReplacement), field: "ctx")
        await protectedFacade.settled()
        try check(try await protectedSession.addonSnapshot() == protectedBefore && protectedFacade.lastFailure != nil,
                  "same-URL native update changed a protected member")
        await protectedFacade.shutdown()
        print("Protected native member refresh fails closed without changing authoritative descriptor")
        print("GREEN native add-on confirmation: first install and repeated canonical replacement acknowledged; legacy unchanged; wrong input, rejected checkpoint, explicit rebind, controlled late completion, profile ABA, removal and new account fail closed")
    }
}

private extension VortxJSON {
    func decodeObject() -> [String: VortxJSON] { guard case .object(let value) = self else { preconditionFailure("fixture expected object") }; return value }
}
