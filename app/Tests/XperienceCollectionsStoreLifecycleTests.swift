// Executes actual Store/ViewModel code with a controlled synthetic CoreBridge boundary.
// Native checkpoint/ABI, secure account transport, rendering and device proof remain separate.
import Combine
import CoreFoundation
import Foundation

@main @MainActor enum XperienceCollectionsStoreLifecycleTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        checks += 1
        print("PASS \(message)")
    }
    static func document(_ id: String) throws -> XperienceCollections.Document {
        try XperienceCollections.project(.array([.object([
            "id": .string(id), "title": .string("Synthetic collection"), "folders": .array([])
        ])]))
    }
    static func start(_ store: XperienceCollectionsStore, _ lease: XperienceImportLease, _ id: String)
        throws -> Task<XperienceSavedNamespace, Error> {
        let document = try document(id)
        return Task { try await store.append(document: document, label: "Synthetic import", bindings: [:], lease: lease) }
    }
    static func rejects(_ expected: XperiencePersistenceFailure,
                        _ operation: () async throws -> Void) async throws {
        do { try await operation(); throw Failure.assertion("expected controlled rejection") }
        catch let failure as XperiencePersistenceFailure {
            try require(failure == expected, "controlled rejection is \(expected)")
        }
    }
    static func resetPublishedContext() {
        ProfileStore.shared.activeID = UUID()
        VortXSyncManager.shared.isSignedIn = true
    }

    static func ownACK() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let lease = try store.capture(), before = store.revision
        let save = try start(store, lease, "own-ack")
        let id = await core.waitForSave(at: 0)
        try require(core.preparationCount == 1 && core.syntheticPublications == 0,
                    "own-ACK fixture reached submitted save before publication")
        try core.publish(id)
        await core.observeNotification { core.notify() }
        try require(store.isCurrent(lease) && core.captures[0].lifetime.isActive,
                    "exact own ACK before continuation retains the original lease and lifetime")
        try require(store.revision == before, "own ACK notification is not a synthetic Save continuation")
        core.finish(id)
        let saved = try await save.value
        let expectedDocument = try document("own-ack")
        try require(saved.document.fingerprint == expectedDocument.fingerprint,
                    "actual Store continuation decodes the acknowledged namespace")
        try require(store.isCurrent(lease) && store.revision != before, "successful continuation advances presentation")
        let replacementDocument = try document("own-replacement"), replacementRevision = store.revision
        let replacement = Task {
            try await store.replace(namespace: saved, document: replacementDocument,
                label: "Synthetic replacement", bindings: [:], lease: lease)
        }
        let replacementID = await core.waitForSave(at: 1)
        try core.publish(replacementID)
        await core.observeNotification { core.notify() }
        try require(store.isCurrent(lease) && store.revision == replacementRevision,
                    "replacement own ACK preserves exact baseline CAS without fabricating completion")
        core.finish(replacementID)
        let replaced = try await replacement.value
        try require(replaced.namespace == saved.namespace && replaced.document.fingerprint == replacementDocument.fingerprint,
                    "actual replacement continuation retains only its selected namespace")
    }

    static func changedRegisters() async throws {
        for kind in ["unrelated", "unknown", "wrong-own-value", "before-submission"] {
            resetPublishedContext()
            let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
            if kind == "before-submission" { core.holdPreparation = true }
            let lease = try store.capture()
            let save = try start(store, lease, kind)
            let id: UUID?
            if kind == "before-submission" {
                await core.waitForPreparation()
                id = nil
                core.registers["xperience.import.10000000-0000-4000-8000-000000000088"] = .object(["value": .null])
            } else {
                id = await core.waitForSave(at: 0)
                let extra: [String: VortxJSON]
                if kind == "unrelated" {
                    let peer = try XperienceImportNamespace.append(document: document("peer"), label: "Synthetic peer")
                    extra = [peer.field: .object(["clock": .integer(1), "actor": .string("10000000-0000-4000-8000-000000000002"), "value": peer.value])]
                } else if kind == "unknown" {
                    extra = ["xperience.import.future": .object(["future": .bool(true)])]
                } else { extra = [:] }
                try core.publish(id!, extra: extra, alterValue: kind == "wrong-own-value")
            }
            await core.observeNotification { core.notify() }
            try require(!store.isCurrent(lease) && !core.captures[0].lifetime.isActive,
                        "\(kind) notification retires observation and original worker lifetime")
            if let id { core.finish(id) } else { core.releasePreparation() }
            try await rejects(.staleContext) { _ = try await save.value }
        }
    }

    static func profileABA() async throws {
        resetPublishedContext()
        let original = ProfileStore.shared.activeID
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let lease = try store.capture()
        var sawBeforeSetter = false
        let listener = store.$revision.dropFirst().sink { _ in
            // Actual invalidate publishes this only after revocation. The surrounding Published
            // activeID setter still contains the old profile; subscriber ordering is irrelevant.
            sawBeforeSetter = ProfileStore.shared.activeID == original
                && !store.isCurrent(lease) && !core.captures[0].lifetime.isActive
        }
        ProfileStore.shared.activeID = UUID()
        try require(sawBeforeSetter, "profile publication revokes the original lifetime before the setter completes")
        listener.cancel()
        ProfileStore.shared.activeID = original
        try require(!store.isCurrent(lease), "profile A-to-B-to-A cannot reactivate the original lease")
        let successor = try store.capture()
        try require(store.isCurrent(successor) && !core.captures[0].lifetime.isActive,
                    "fresh profile gesture gets a distinct active lifetime")
    }

    static func contextRetirement() async throws {
        for kind in ["credential", "installation", "registry"] {
            resetPublishedContext()
            let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
            let lease = try store.capture()
            let save = try start(store, lease, kind)
            let id = await core.waitForSave(at: 0)
            switch kind {
            case "credential": core.context.credential = UUID()
            case "installation": core.context.installation = UUID()
            default: core.context.registry = UUID()
            }
            // These epoch checks belong to the synthetic boundary. The real Store must reject
            // the obsolete captured target without trying to acquire a successor itself.
            await core.observeCurrentCheck { core.notifyContext() }
            try require(!store.isCurrent(lease) && !core.captures[0].lifetime.isActive,
                        "\(kind) notification retires actual Store observation and original worker lifetime")
            try require(core.captures.count == 1, "\(kind) notification never recaptures successor authority")
            // Only an explicit new gesture can capture replacement authority.
            let successor = try store.capture()
            try require(!core.captures[0].lifetime.isActive && store.isCurrent(successor),
                        "\(kind) retirement revokes old lifetime and requires explicit fresh capture")
            core.finish(id)
            try await rejects(.staleContext) { _ = try await save.value }
            try require(core.syntheticPublications == 0, "\(kind) retired save has no synthetic publication")
        }
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let lease = try store.capture()
        VortXSyncManager.shared.isSignedIn = false
        VortXSyncManager.shared.isSignedIn = true
        try require(!store.isCurrent(lease) && !core.captures[0].lifetime.isActive,
                    "signed-in false-to-true retires original observation instead of reviving it")
    }

    static func pendingIdentity() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let oldLease = try store.capture()
        let oldSave = try start(store, oldLease, "old")
        let oldID = await core.waitForSave(at: 0)
        let newLease = try store.capture()
        let newSave = try start(store, newLease, "new")
        let newID = await core.waitForSave(at: 1)
        try require(!core.captures[0].lifetime.isActive, "superseding save fixture has retired the old lifetime")
        core.finish(oldID, error: XperiencePersistenceFailure.staleContext)
        try await rejects(.staleContext) { _ = try await oldSave.value }
        core.rejectPreparation = true // A lost pending gate must fail, not hang a mutant test.
        try await rejects(.busy) {
            _ = try await store.append(document: document("third"), label: "Synthetic third", bindings: [:], lease: newLease)
        }
        try require(core.preparationCount == 2, "old deferred cleanup cannot clear the successor pending save")
        core.rejectPreparation = false
        try core.publish(newID)
        await core.observeNotification { core.notify() }
        core.finish(newID)
        _ = try await newSave.value
        try require(store.isCurrent(newLease), "successor save survives old continuation and cleanup")
    }

    static func cancellation() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let lease = try store.capture()
        core.holdPreparation = true
        let preparing = try start(store, lease, "cancel-prepare")
        await core.waitForPreparation()
        preparing.cancel(); core.releasePreparation()
        try await rejects(.cancelled) { _ = try await preparing.value }
        try require(core.saveIDs.isEmpty && core.syntheticPublications == 0,
                    "cancellation during preparation never enters native-submission seam")
        core.holdPreparation = false
        let saving = try start(store, lease, "cancel-save")
        let id = await core.waitForSave(at: 0)
        saving.cancel()
        do { try core.publish(id); throw Failure.assertion("cancelled latch admitted a synthetic publication") }
        catch VortxNativeHostFieldMutationError.cancelled { checks += 1 }
        core.finish(id)
        try await rejects(.cancelled) { _ = try await saving.value }
        try require(store.isCurrent(lease), "cancelled save retains browsing lease without inventing a new lifetime")
        let next = try start(store, lease, "after-cancel")
        let nextID = await core.waitForSave(at: 1)
        try core.publish(nextID); core.finish(nextID)
        _ = try await next.value
        try require(core.syntheticPublications == 1, "cancelled pending save is cleared for an explicit retry")
    }

    static func viewModelStop() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let model = XperienceCollectionsViewModel(store: store)
        let json = String(decoding: try XperienceCollections.canonicalData(document("ui-stop").raw), as: UTF8.self)
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = model.$preview.compactMap { $0 }.first().sink { _ in continuation.resume() }
            model.previewPaste(json)
        }
        subscription?.cancel()
        try require(model.preview != nil && model.isLive, "actual ViewModel preview activates the UI cancellation fixture")
        guard let original = model.previewIdentity else { throw Failure.assertion("missing preview identity") }
        _ = model.stageSave(original)
        let id = await core.waitForSave(at: 0)
        // Read the actual private owner without widening a production API or adding test flags.
        // Fail closed if its name/type changes, rather than guessing that queued work settled.
        let taskSlots = Mirror(reflecting: model).children.filter { $0.label == "saveTask" }
        guard taskSlots.count == 1,
              let optionalTask = taskSlots[0].value as? Task<Void, Never>?,
              let originalSaveTask = optionalTask else { throw Failure.assertion("actual UI save task owner unavailable") }
        model.stop()
        try require(model.preview == nil && !model.busy, "actual ViewModel stop clears pending presentation")
        do { try core.publish(id); throw Failure.assertion("UI stop failed to cancel its original save task") }
        catch VortxNativeHostFieldMutationError.cancelled { checks += 1 }
        core.finish(id)
        await originalSaveTask.value
        try require(model.preview == nil && !model.busy && model.message != "Saved this import to the current profile.",
                    "cancelled old save cannot publish a success or restore cleared UI state")
        try require(core.syntheticPublications == 0, "UI stop before synthetic checkpoint leaves no publication")
    }

    static func rawObservation() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let source = try XperienceImportNamespace.appendRaw(document: document("raw-observation"), label: "Original", bindings: [:])
        let exact = Data("340282366920938463463374607431768211455".utf8)
        var value = try OwnerHistoryExactJSON.Object(source.raw.value); value.set("futureExact", exact)
        var register = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        register.set("clock", Data("7".utf8))
        register.set("actor", try OwnerHistoryExactJSON.string("10000000-0000-4000-8000-000000000001"))
        register.set("value", try value.encoded()); register.set("futureRegister", exact)
        let original = try register.encoded()
        core.rawRegisterFixtures[source.field] = try VortxRawHostRegister.prepared(original)
        let lease = try store.capture(), revision = store.revision
        // Whitespace is not a change in the observed register structure. Exact numeric
        // tokens and every unknown sibling still participate in the immutable evidence.
        core.rawRegisterFixtures[source.field] = try VortxRawHostRegister.prepared(Data(" \n".utf8) + original + Data(" \n".utf8))
        await core.observeNotification { core.notify() }
        try require(store.isCurrent(lease) && store.revision == revision, "raw semantic observation keeps unchanged whitespace publication conflated")
        let saved = try store.namespaces(lease)[0]
        let replacement = Task {
            try await store.replace(namespace: saved, document: document("raw-renamed"), label: "Renamed", bindings: [:], lease: lease)
        }
        let id = await core.waitForSave(at: 0)
        try core.publish(id)
        await core.observeNotification { core.notify() }
        try require(store.isCurrent(lease), "complete raw own ACK retains original Store lifetime")
        core.finish(id)
        _ = try await replacement.value
        let acknowledged = core.rawRegisterFixtures[source.field]!
        let acknowledgedRegister = try OwnerHistoryExactJSON.Object(acknowledged.bytes)
        let acknowledgedValue = try OwnerHistoryExactJSON.Object(acknowledged.value)
        try require(acknowledgedRegister["futureRegister"] == exact && acknowledgedValue["futureExact"] == exact,
                    "actual Store replacement retains complete raw future value and metadata through its synthetic boundary")
        var changed = acknowledgedRegister
        changed.set("futureRegister", Data("340282366920938463463374607431768211454".utf8))
        core.rawRegisterFixtures[source.field] = try VortxRawHostRegister.prepared(changed.encoded())
        await core.observeNotification { core.notify() }
        try require(!store.isCurrent(lease) && !core.captures[0].lifetime.isActive && core.captures.count == 1,
                    "unknown raw metadata change retires the actual Store observation without successor recapture")
    }

    static func isolatedInstalledBindingChoice() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let catalogs: VortxJSON = .array([.object(["type": .string("movie"), "id": .string("popular")])])
        core.installedProjection = try XperienceInstalledCatalogs.project([
            .init(id: "bad", transportUrl: "https://catalog.example.invalid/a bad/manifest.json",
                manifest: .object(["id": .string("fixture.a"), "catalogs": catalogs])),
            .init(id: "valid", transportUrl: "https://catalog.example.invalid/a/manifest.json?configuration=synthetic",
                manifest: .object(["id": .string("fixture.a"), "catalogs": catalogs]))
        ])
        let admitted = try XperienceCollections.project(.array([.object(["id": .string("collection"),
            "title": .string("Synthetic"), "futureOpaque": .string("retain"), "folders": .array([
                .object(["id": .string("folder"), "title": .string("Folder"), "sources": .array([
                    .object(["provider": .string("addon"), "addonId": .string("fixture.a"),
                        "type": .string("movie"), "catalogId": .string("popular")])])])])])]))
        let model = XperienceCollectionsViewModel(store: store)
        var subscription: AnyCancellable?
        let text = String(decoding: try XperienceCollections.canonicalData(admitted.raw), as: UTF8.self)
        await withCheckedContinuation { continuation in
            subscription = model.$preview.compactMap { $0 }.first().sink { _ in continuation.resume() }
            model.previewPaste(text)
        }
        subscription?.cancel()
        guard let row = model.bindingRows.first else { throw Failure.assertion("missing isolated installed row") }
        try require(row.selection == nil && model.unavailableSourceCount == 1,
                    "actual ViewModel does not auto-map a surviving malformed-same-ID sibling")
        try require(row.choices.count == 1 && row.choices[0].title == "Installed instance 2",
                    "actual ViewModel offers only the valid original installed position")
        try require(row.status.contains("unavailable") && !row.status.contains("https://"),
                    "unresolved installed state is bounded and actionable without config output")
        guard let original = model.previewIdentity else { throw Failure.assertion("missing preview identity") }
        model.chooseInstance(row: row.id, choice: row.choices[0].id, original: original)
        try require(model.bindingRows[0].selection != nil && model.unavailableSourceCount == 0,
                    "explicit valid original mapping resolves through actual ViewModel wrapper")
        try require(model.preview?.raw == admitted.raw && core.captures.count == 1 && core.syntheticPublications == 0,
                    "binding choice preserves raw preview and original capture without a write")
        let successor = try await loadPreview(model, admitted)
        model.chooseInstance(row: row.id, choice: row.choices[0].id, original: successor)
        let currentSelection = model.bindingRows[0].selection
        model.chooseInstance(row: row.id, choice: "unavailable", original: original)
        try require(currentSelection != nil && model.bindingRows[0].selection == currentSelection,
                    "same-ID old binding action cannot clear successor preview mapping")
        model.stop()
    }

    static func loadPreview(_ model: XperienceCollectionsViewModel, _ value: XperienceCollections.Document) async throws -> XperiencePresentationIdentity {
        let text = String(decoding: try XperienceCollections.canonicalData(value.raw), as: UTF8.self)
        let previous = model.previewIdentity
        var subscription: AnyCancellable?
        await withCheckedContinuation { continuation in
            subscription = model.$previewIdentity.compactMap { $0 }.filter { $0 != previous }.first().sink { _ in continuation.resume() }
            model.previewPaste(text)
        }
        subscription?.cancel()
        guard let original = model.previewIdentity else { throw Failure.assertion("missing installed preview identity") }
        return original
    }

    static func originalPreviewGestures() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let model = XperienceCollectionsViewModel(store: store)
        let document = try document("same-rendered-identifiers")
        let first = try await loadPreview(model, document)
        model.setLabel("Original edited label", original: first)
        try require(model.label == "Original edited label", "current preview label gesture remains usable")
        let second = try await loadPreview(model, document)
        try require(first != second && core.captures.count == 2, "same document receives a distinct original preview identity")
        model.setLabel("STALE", original: first)
        model.setDestination("append", original: first)
        model.chooseInstance(row: "unused", choice: "unavailable", original: first)
        let staleConfirmation = model.stageSave(first)
        try require(model.label == "Imported collections" && model.destination == "append" && staleConfirmation == nil && !model.busy,
                    "old label, destination, mapping and Save actions cannot target successor preview")
        try require(model.previewIdentity == second && core.captures.count == 2 && core.saveIDs.isEmpty,
                    "denied old gestures neither recapture ownership nor start a save")
        model.stop()
        model.setLabel("AFTER STOP", original: second)
        _ = model.stageSave(second)
        try require(model.previewIdentity == nil && model.preview == nil && !model.busy && core.saveIDs.isEmpty,
                    "stop retires preview gesture authority before delayed edits or Save")
    }

    static func originalSavedReviewAndConfirmation() async throws {
        resetPublishedContext()
        let core = CoreBridge(), store = XperienceCollectionsStore(core: core)
        let edit = try XperienceImportNamespace.appendRaw(document: document("saved-gesture"), label: "Original saved import", bindings: [:])
        var register = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        register.set("clock", Data("7".utf8))
        register.set("actor", try OwnerHistoryExactJSON.string("10000000-0000-4000-8000-000000000001"))
        register.set("value", edit.raw.value)
        core.rawRegisterFixtures[edit.field] = try VortxRawHostRegister.prepared(register.encoded())
        let model = XperienceCollectionsViewModel(store: store)
        model.reload()
        guard let oldList = model.savedIdentity else { throw Failure.assertion("missing original saved list") }
        model.reload()
        guard let list = model.savedIdentity else { throw Failure.assertion("missing successor saved list") }
        model.reviewSaved(edit.field, original: oldList)
        try require(model.preview == nil && model.savedIdentity == list && core.captures.count == 2,
                    "old saved-row callback cannot recapture or resolve against successor list")
        model.reviewSaved(edit.field, original: list)
        guard let previewA = model.previewIdentity, let confirmA = model.stageSave(previewA) else {
            throw Failure.assertion("missing original replacement confirmation")
        }
        try require(core.captures.count == 2 && model.destination == edit.field,
                    "current saved review retains its original lease and raw replacement namespace")
        model.reviewSaved(edit.field, original: list)
        guard let previewB = model.previewIdentity, let confirmB = model.stageSave(previewB) else {
            throw Failure.assertion("missing successor replacement confirmation")
        }
        model.setDestination("append", original: previewA)
        model.setLabel("STALE REPLACEMENT", original: previewA)
        try require(model.destination == edit.field && model.label == "Original saved import",
                    "old preview cannot redirect or relabel the new replacement")
        model.cancelStaged(confirmA)
        model.commitStaged(confirmA)
        try require(!model.busy && core.saveIDs.isEmpty && previewA != previewB && confirmA != confirmB,
                    "old confirm and cancel cannot submit or clear successor confirmation")
        model.commitStaged(confirmB)
        let id = await core.waitForSave(at: 0)
        let tasks = Mirror(reflecting: model).children.filter { $0.label == "saveTask" }
        guard tasks.count == 1, let task = tasks[0].value as? Task<Void, Never>?, let task else {
            throw Failure.assertion("missing exact successor save task")
        }
        try core.publish(id); core.finish(id)
        await task.value
        try require(core.syntheticPublications == 1 && core.captures.count == 2 && model.preview == nil && model.savedIdentity != list,
                    "current confirmation saves once and rotates saved-row identity without owner recapture")
        model.reviewSaved(edit.field, original: list)
        try require(model.preview == nil && core.captures.count == 2,
                    "acknowledged list revision retires previously rendered row actions")
        model.stop()
    }

    static func run() async throws {
        let selected = CommandLine.arguments.dropFirst().first ?? "all"
        let cases: [(String, () async throws -> Void)] = [
            ("own-ack", ownACK), ("changed-registers", changedRegisters), ("profile-aba", profileABA),
            ("context-retirement", contextRetirement), ("pending-identity", pendingIdentity),
            ("cancellation", cancellation), ("ui-stop", viewModelStop), ("raw-observation", rawObservation), ("installed-isolation", isolatedInstalledBindingChoice),
            ("original-preview", originalPreviewGestures), ("original-saved-confirmation", originalSavedReviewAndConfirmation)
        ]
        guard selected == "all" || cases.contains(where: { $0.0 == selected }) else { throw Failure.assertion("unknown case") }
        for (name, operation) in cases where selected == "all" || selected == name {
            try await operation()
            print("PASS case \(name)")
        }
        print("PASS actual Store/ViewModel lifecycle checks: \(checks); synthetic CoreBridge boundary only")
    }
    static func main() {
        // Keep the real main run loop active: Store notifications deliberately use RunLoop.main.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("FAIL lifecycle harness watchdog: an expected boundary was not reached"); exit(1)
        }
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL lifecycle harness: \(error)"); exit(1) }
        }
        CFRunLoopRun()
    }
}
