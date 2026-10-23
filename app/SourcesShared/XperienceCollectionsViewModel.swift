import Foundation
import Combine

/// Exact UI-facing boundary agreed with the native store owner. No raw register or transport label API.
@MainActor
protocol XperienceCollectionsUIStore {
    var revisionEvents: AnyPublisher<UUID, Never> { get }
    func capture() throws -> XperienceImportLease
    func isCurrent(_ lease: XperienceImportLease) -> Bool
    func candidates(_ lease: XperienceImportLease) throws -> [XperienceAddonBinding.Candidate]
    func namespaces(_ lease: XperienceImportLease) throws -> [XperienceSavedNamespace]
    func append(document: XperienceCollections.Document, label: String,
                bindings: [String: XperienceAddonBinding.Mapping], lease: XperienceImportLease) async throws -> XperienceSavedNamespace
    func replace(namespace: XperienceSavedNamespace, document: XperienceCollections.Document, label: String,
                 bindings: [String: XperienceAddonBinding.Mapping], lease: XperienceImportLease) async throws -> XperienceSavedNamespace
}

extension XperienceCollectionsStore: XperienceCollectionsUIStore {
    var revisionEvents: AnyPublisher<UUID, Never> { $revision.eraseToAnyPublisher() }
}

/// Captured before a platform chooser is presented; the native lease is never replaced at completion.
struct XperienceFileImportTicket: Identifiable {
    let admission: XperienceFileChooserAdmission.Ticket
    fileprivate let lease: XperienceImportLease
    var id: UUID { admission.id }
    var generation: UUID { admission.generation }
}

enum XperienceHomeRoute: Hashable { case browser }

struct XperienceBrowserRoute: Hashable {
    enum Page: Hashable {
        case collection(String, String)
        case folder(String, String, String?)
        case catalog(String, String, String, Int)
        case detail(String, String, String)
    }
    let generation: UUID
    let page: Page
}

struct XperienceBindingPreview: Identifiable {
    struct Choice: Identifiable { let id: String; let title: String }
    let id: String
    let title: String
    let status: String
    let choices: [Choice]
    let selection: String?
}

struct XperienceCatalogRequest {
    let generation: UUID
    let source: XperienceCollections.Source
    let candidate: XperienceAddonBinding.Candidate
}

/// Owns only presentation state. Native admission, registry snapshots, CAS and readback stay in the store.
@MainActor
final class XperienceCollectionsViewModel: ObservableObject {
    let store: any XperienceCollectionsUIStore
    @Published private(set) var namespaces: [XperienceSavedNamespace] = []
    @Published private(set) var preview: XperienceCollections.Document?
    @Published private(set) var bindingRows: [XperienceBindingPreview] = []
    @Published private(set) var generation = UUID()
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var label = "Imported collections"
    @Published var destination = "append"

    private var lease: XperienceImportLease?
    private var installed: [XperienceAddonBinding.Candidate] = []
    private var mappings: [String: XperienceAddonBinding.Mapping] = [:]
    private var sourceOrder: [(key: String, title: String, source: XperienceCollections.Source)] = []
    private var choices: [String: [String: XperienceAddonBinding.Mapping]] = [:]
    private var readTask: Task<Void, Never>?
    private var readWorker: Task<XperienceCollections.Document, Error>?
    private var readRequestID = UUID()
    private var chooserAdmission = XperienceFileChooserAdmission()
    private var saveTask: Task<Void, Never>?
    private var saveRequestID = UUID()
    private var pending: Commit?
    private struct Commit {
        let generation: UUID
        let lease: XperienceImportLease
        let document: XperienceCollections.Document
        let label: String
        let bindings: [String: XperienceAddonBinding.Mapping]
        let replacement: XperienceSavedNamespace?
    }
    enum Failure: Error { case unavailable, bindingRequired, stale }

    init(store: any XperienceCollectionsUIStore) { self.store = store }
    convenience init() { self.init(store: XperienceCollectionsStore()) }

    var isLive: Bool { lease.map(store.isCurrent) ?? false }
    var replacesNamespace: Bool { destination != "append" }
    var unavailableSourceCount: Int {
        sourceOrder.filter { entry in
            guard let mapping = mappings[entry.key] else { return true }
            if case .resolved = XperienceAddonBinding.resolve(entry.source, installed: installed, mapping: mapping) { return false }
            return true
        }.count
    }

    func route(_ page: XperienceBrowserRoute.Page) -> XperienceBrowserRoute { .init(generation: generation, page: page) }
    func accepts(_ requestedGeneration: UUID) -> Bool { requestedGeneration == generation && isLive }

    /// Called at the original file/paste gesture, before presenting a chooser or reading asynchronously.
    @discardableResult func beginImport() -> Bool {
        stop()
        namespaces = []
        generation = UUID()
        do {
            let captured = try store.capture()
            let registry = try store.candidates(captured)
            let saved = try store.namespaces(captured)
            for namespace in saved {
                let admission = try XperienceImportNamespace.append(document: namespace.document, label: namespace.label)
                try XperienceImportPrivacy.validate(admission)
            }
            guard store.isCurrent(captured) else { throw Failure.stale }
            lease = captured
            installed = registry
            namespaces = saved
            message = nil
            return true
        } catch {
            retire((error as? XperiencePersistenceFailure)?.errorDescription
                ?? "Collections are unavailable for this profile. Reload and try again.")
            return false
        }
    }

    func reload() { _ = beginImport() }

    func retireIfStale() {
        if let lease, !store.isCurrent(lease) {
            retire("The profile or installed add-ons changed. Reload collections before continuing.")
        }
    }

    private func cancelRead() {
        readRequestID = UUID()
        readTask?.cancel(); readTask = nil
        readWorker?.cancel(); readWorker = nil
    }

    func beginFileImport() -> XperienceFileImportTicket? {
        guard beginImport(), let captured = lease, store.isCurrent(captured) else { return nil }
        return .init(admission: chooserAdmission.begin(generation: generation), lease: captured)
    }

    func cancelFileImport(_ originalTicket: XperienceFileImportTicket) {
        guard chooserAdmission.cancel(originalTicket.admission, currentGeneration: generation) else { return }
        cancelRead()
        busy = saveTask != nil
    }

    /// The landing page also disappears when pushing one of this browser's child routes.
    /// Stop input/save work, while retaining the current browsing lease and saved namespaces.
    func stop() {
        chooserAdmission.invalidate()
        saveRequestID = UUID()
        saveTask?.cancel(); saveTask = nil
        clearPreview()
    }

    func previewPaste(_ text: String) {
        guard beginImport() else { return }
        guard text.utf8.count <= XperienceCollections.maximumBytes else {
            message = XperienceCollections.Failure.tooLarge.errorDescription
            return
        }
        guard let captured = lease else { return }
        admit({ Data(text.utf8) }, originalLease: captured, requestGeneration: generation, originalTicket: nil)
    }

    /// The immutable original presentation ticket supplies both admission and the native lease.
    func previewFile(_ url: URL, ticket originalTicket: XperienceFileImportTicket) {
        guard chooserAdmission.admit(originalTicket.admission, currentGeneration: generation) else { return }
        guard store.isCurrent(originalTicket.lease) else { retireIfStale(); return }
        admit({ try Self.readSelectedFile(url) }, originalLease: originalTicket.lease,
              requestGeneration: originalTicket.generation, originalTicket: originalTicket)
    }

    private func canPublishFile(_ originalTicket: XperienceFileImportTicket?) -> Bool {
        guard let originalTicket else { return true }
        return chooserAdmission.permitsPublication(originalTicket.admission, currentGeneration: generation)
    }

    private func finishFile(_ originalTicket: XperienceFileImportTicket?) {
        if let originalTicket { chooserAdmission.finish(originalTicket.admission, currentGeneration: generation) }
    }

    private func admit(_ read: @escaping @Sendable () throws -> Data,
                       originalLease captured: XperienceImportLease, requestGeneration: UUID,
                       originalTicket: XperienceFileImportTicket?) {
        guard accepts(requestGeneration), store.isCurrent(captured), canPublishFile(originalTicket) else { retireIfStale(); return }
        cancelRead()
        let requestID = readRequestID
        busy = true
        message = nil
        // Keep a handle to the unstructured worker: cancellation of the awaiting task alone
        // does not cancel Task.detached. The handler also covers cancellation before awaiting.
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try read()
            try Task.checkCancellation()
            let document = try XperienceCollections.parse(data)
            try Task.checkCancellation()
            // Check the entire raw export before showing any imported label or title.
            let edit = try XperienceImportNamespace.append(document: document, label: "Imported collections")
            try Task.checkCancellation()
            try XperienceImportPrivacy.validate(edit)
            try Task.checkCancellation()
            return document
        }
        readWorker = worker
        readTask = Task { [weak self] in
            do {
                let document = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.readRequestID == requestID,
                      self.generation == requestGeneration else { return }
                guard self.store.isCurrent(captured), self.canPublishFile(originalTicket) else { self.retireIfStale(); return }
                self.finishFile(originalTicket)
                self.readTask = nil; self.readWorker = nil
                self.installPreview(document, existingMappings: [:])
                self.busy = false
            } catch {
                guard let self, !Task.isCancelled, self.readRequestID == requestID,
                      self.generation == requestGeneration else { return }
                self.readTask = nil; self.readWorker = nil
                self.busy = false
                guard self.store.isCurrent(captured), self.canPublishFile(originalTicket) else { self.retireIfStale(); return }
                self.finishFile(originalTicket)
                guard !(error is CancellationError) else { return }
                self.message = (error as? XperienceCollections.Failure)?.errorDescription
                    ?? "Could not read this JSON export. Choose a complete collections.json file or paste its JSON content."
            }
        }
    }

    func reviewSaved(_ field: String) {
        guard isLive else { retireIfStale(); return }
        guard beginImport(), let namespace = namespaces.first(where: { $0.field == field }) else { return }
        destination = namespace.field
        label = namespace.label
        installPreview(namespace.document, existingMappings: namespace.bindings)
    }

    private func installPreview(_ document: XperienceCollections.Document,
                                existingMappings: [String: XperienceAddonBinding.Mapping]) {
        preview = document
        mappings = existingMappings
        sourceOrder = []
        var seen = Set<String>()
        for collection in document.collections {
            for folder in collection.folders {
                for source in folder.sources {
                    let key = XperienceAddonBinding.key(for: source)
                    guard seen.insert(key).inserted else { continue }
                    sourceOrder.append((key, "\(collection.title) / \(folder.title) / \(source.catalogID ?? "Source")", source))
                    if mappings[key] == nil,
                       case .resolved(let candidate) = XperienceAddonBinding.resolve(source, installed: installed) {
                        mappings[key] = candidate.mapping
                    }
                }
            }
        }
        rebuildBindingRows()
    }

    private func rebuildBindingRows() {
        choices = [:]
        bindingRows = sourceOrder.map { entry in
            let resolution = XperienceAddonBinding.resolve(entry.source, installed: installed, mapping: mappings[entry.key])
            let eligible = installed.enumerated().filter { _, candidate in
                if case .resolved = XperienceAddonBinding.resolve(entry.source, installed: [candidate], mapping: candidate.mapping) { return true }
                return false
            }
            var selection: String?
            let offered = eligible.map { index, candidate -> XperienceBindingPreview.Choice in
                let id = String(index)
                choices[entry.key, default: [:]][id] = candidate.mapping
                if mappings[entry.key] == candidate.mapping { selection = id }
                // Registry order distinguishes instances without exposing a configured URL or fingerprint.
                return .init(id: id, title: "Installed instance \(index + 1)")
            }
            let status: String
            switch resolution {
            case .resolved:
                status = mappings[entry.key] == nil
                    ? "This source stays unavailable until an installed instance is selected"
                    : "Bound to an exact installed instance"
            case .ambiguous: status = "Choose which installed instance supplies this catalog"
            case .missing: status = "The required add-on and catalog are not installed"
            case .mappingUnavailable: status = "The saved installed instance is unavailable; choose again"
            case .unsupportedProvider: status = "This source provider is retained but cannot be browsed"
            case .unsupportedGenreConfiguration: status = "This catalog does not support the exported genre configuration"
            case .invalidRegistry: status = "The installed registry is ambiguous; resolve duplicate instances first"
            }
            return .init(id: entry.key, title: entry.title, status: status, choices: offered, selection: selection)
        }
    }

    func chooseInstance(row: String, choice: String) {
        guard isLive else { retireIfStale(); return }
        if choice == "unavailable" { mappings.removeValue(forKey: row) }
        else if let mapping = choices[row]?[choice] { mappings[row] = mapping }
        rebuildBindingRows()
    }

    /// Capture all commit inputs before the replacement confirmation becomes visible.
    func stageSave() -> Bool {
        guard !busy, let lease, store.isCurrent(lease), let preview else { retireIfStale(); return false }
        let replacement = destination == "append" ? nil : namespaces.first { $0.field == destination }
        guard destination == "append" || replacement != nil else { message = "Choose an available saved import."; return false }
        pending = Commit(generation: generation, lease: lease, document: preview,
                         label: label, bindings: mappings, replacement: replacement)
        if replacement == nil { commitStaged() }
        return replacement != nil
    }

    func cancelStaged() { pending = nil }

    func commitStaged() {
        guard let commit = pending, accepts(commit.generation), store.isCurrent(commit.lease) else { pending = nil; retireIfStale(); return }
        pending = nil
        let requestID = UUID()
        saveRequestID = requestID
        busy = true
        saveTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.saveRequestID == requestID,
                  self.accepts(commit.generation), self.store.isCurrent(commit.lease) else { return }
            do {
                if let target = commit.replacement {
                    _ = try await self.store.replace(namespace: target, document: commit.document,
                        label: commit.label, bindings: commit.bindings, lease: commit.lease)
                } else {
                    _ = try await self.store.append(document: commit.document, label: commit.label,
                        bindings: commit.bindings, lease: commit.lease)
                }
                guard !Task.isCancelled, self.saveRequestID == requestID,
                      self.accepts(commit.generation), self.store.isCurrent(commit.lease) else { return }
                self.namespaces = try self.store.namespaces(commit.lease)
                self.saveTask = nil
                self.clearPreview()
                self.message = "Saved this import to the current profile."
            } catch {
                guard !Task.isCancelled, self.saveRequestID == requestID,
                      self.generation == commit.generation else { return }
                self.saveTask = nil
                if let failure = error as? XperiencePersistenceFailure,
                   failure == .persistenceUncertain || failure == .staleContext || failure == .staleRegister {
                    self.retire(failure.errorDescription ?? "Reload collections before continuing.")
                    return
                }
                self.busy = false
                self.message = (error as? XperiencePersistenceFailure)?.errorDescription
                    ?? (error as? XperienceCollections.Failure)?.errorDescription
                    ?? "The import could not be saved. Reload a fresh preview and try again."
            }
        }
    }

    func collection(namespace field: String, id: String) -> XperienceCollections.Collection? {
        guard isLive else { return nil }
        return namespaces.first { $0.field == field }?.document.collections.first { $0.id == id }
    }

    func catalogRequest(namespace field: String, collectionID: String, folderID: String, index: Int) throws -> XperienceCatalogRequest {
        guard isLive, let namespace = namespaces.first(where: { $0.field == field }),
              let collection = namespace.document.collections.first(where: { $0.id == collectionID }),
              let folder = collection.folders.first(where: { $0.id == folderID }), folder.sources.indices.contains(index) else { throw Failure.unavailable }
        let source = folder.sources[index]
        guard let mapping = namespace.bindings[XperienceAddonBinding.key(for: source)],
              case .resolved(let candidate) = XperienceAddonBinding.resolve(source, installed: installed, mapping: mapping) else { throw Failure.bindingRequired }
        return .init(generation: generation, source: source, candidate: candidate)
    }

    /// VortX-authored semantic sources may use a current installed catalog only when its exact
    /// manifest/type/catalog tuple has one legitimate configured instance. Ambiguity stays visible.
    func catalogRequest(unambiguousInstalledSource source: XperienceCollections.Source) throws -> XperienceCatalogRequest {
        guard isLive,
              case .resolved(let candidate) = XperienceAddonBinding.resolve(source, installed: installed) else {
            throw Failure.bindingRequired
        }
        return .init(generation: generation, source: source, candidate: candidate)
    }

    private func clearPreview() {
        cancelRead()
        preview = nil; bindingRows = []; mappings = [:]; sourceOrder = []; choices = [:]
        pending = nil; busy = false; destination = "append"; label = "Imported collections"
    }

    private func retire(_ text: String) {
        stop()
        namespaces = []; installed = []; lease = nil
        generation = UUID(); message = text
    }

    nonisolated private static func readSelectedFile(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Failure.unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= XperienceCollections.maximumBytes {
            try Task.checkCancellation()
            let allowance = min(65_536, XperienceCollections.maximumBytes + 1 - data.count)
            guard let chunk = try handle.read(upToCount: allowance), !chunk.isEmpty else { break }
            try Task.checkCancellation()
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard data.count <= XperienceCollections.maximumBytes else { throw XperienceCollections.Failure.tooLarge }
        return data
    }
}
