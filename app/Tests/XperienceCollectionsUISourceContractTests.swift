// Source boundaries only, not file-provider, native CAS or device acceptance evidence.
// Run after integration from the repository root with: swift app/Tests/XperienceCollectionsUISourceContractTests.swift
import Foundation

var failures = 0
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("PASS  \(message)") }
    else { failures += 1; print("FAIL  \(message)") }
}
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
@MainActor func source(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }
let view = source("app/SourcesShared/XperienceCollectionsBrowserView.swift")
let model = source("app/SourcesShared/XperienceCollectionsViewModel.swift")
let tv = source("app/SourcesTV/HomeView.swift")
let touch = source("app/SourcesiOS/iOSRootView.swift")
let collections = source("app/SourcesShared/CurationCollectionsIntegration.swift")
let scope = source("app/SourcesShared/CurationReadScope.swift")
let integrations = source("app/SourcesShared/IntegrationsSettingsView.swift")
require(!view.isEmpty && !model.isEmpty, "UI source exists")
require(view.contains("#if os(iOS) || os(macOS)\n/// One immutable presenter identity") && view.contains("allowedContentTypes: [.json]"),
        "file import is conditionally available on iOS and Mac")
require(view.contains("if let ticket = model.beginFileImport() { chooserTicket = ticket }") &&
        model.contains("func previewFile(_ url: URL, ticket originalTicket: XperienceFileImportTicket)"),
        "file admission captures a ticket before the chooser and requires that original ticket")
require(view.contains("SecureField(\"Paste JSON export content\"") && view.contains("pastedJSON = \"\""),
        "paste JSON input is hidden and cleared")
require(model.contains("XperienceImportPrivacy.validate(edit)") && model.contains("self.installPreview(document, existingMappings: [:])"),
        "whole raw export passes privacy admission before preview")
let commit = model.components(separatedBy: "func commitStaged() {").last?.components(separatedBy: "func collection(namespace").first ?? ""
require(!commit.isEmpty && !commit.contains("store.capture()") && commit.contains("lease: commit.lease"),
        "save retains the original lease and never recaptures a successor")
require(view.contains("confirmationDialog(\"Replace this saved import?\"") && model.contains("let replacement: XperienceSavedNamespace?"),
        "namespace replacement requires confirmation of staged inputs")
require(model.contains("namespace.bindings[XperienceAddonBinding.key(for: source)]") &&
        model.contains("installed: installed, mapping: mapping"), "browsing requires a saved exact installed-instance mapping")
require(view.contains("XperienceCatalogClient.load(source: request.source, candidate: request.candidate") &&
        view.contains("model.accepts(request.generation)"), "guarded catalog results are fenced before publication")
for forbidden in ["URLSession", "installAddon(", "canonicalTransport", "transportDigest", "safeHost", "AsyncImage", "PosterImageLoader", "seedBackdrop:", "seedLogo:", "autoPlayOnAppear:"] {
    require(!view.contains(forbidden), "view does not expose or use \(forbidden)")
}
require(view.contains("collections.filter(\\.pinToTop) + collections.filter { !$0.pinToTop }") &&
        view.contains("if collection.showAllTab"), "pinned ordering and optional All visibility use export semantics")
require(view.contains("DetailView(type: type, id: id)") && view.contains("iOSDetailView(id: id, type: type, title: title)"),
        "title selection opens existing native detail routes")
require(!tv.contains("XperienceHomeEntry()") && tv.contains("navigationDestination(for: XperienceHomeRoute.self)") &&
        tv.contains("CurationCollectionsHome(resolved:") && tv.contains("railPrefs.arrange(HomeRail.tvDefaultOrder)"),
        "tvOS retains its registered import route while collections stay inside arranged Home sections")
require(!touch.contains("XperienceHomeEntry()") && touch.contains("navigationDestination(for: XperienceHomeRoute.self)") &&
        touch.contains("CurationCollectionsHome(onOpen:") && touch.contains("railPrefs.arrange(HomeRail.iOSDefaultOrder)"),
        "iOS and Mac retain native detail callbacks without an unconditional import entry above Home sections")
require(!collections.isEmpty && collections.contains("ForEach(editableCollections)") &&
        collections.contains("ticket.isCurrent ? store.collections : []") &&
        collections.contains("store.captureLegacyEdit(original, isNew: existing == nil)"),
        "legacy labels and editor gestures use the original current common read owner")
require(scope.contains("@ObservedObject private var lifetime: CurationReadLifetime") &&
        scope.contains("ticket.isCurrent && ticket.artworkLifetime.isActive && store.ready"),
        "nested collection destinations independently observe and gate their original lifetime")
require(integrations.contains("XperienceCollectionsConnectCard()") && integrations.contains("NuvioConnectCard()"),
        "JSON import and existing manifest-link import remain distinct")
require(view.contains("Save first checks your VortX account backup and may merge account updates on this device. The import is confirmed after its local save; cloud upload is separate.") &&
        !view.contains("Save checks and synchronizes your VortX account first"),
        "Save copy distinguishes account preparation and local acknowledgement from cloud upload")
// Resource ownership boundaries. These assertions inspect wiring; they do not execute cancellation.
require(model.contains("private var readWorker: Task<XperienceCollections.Document, Error>?") &&
        model.contains("withTaskCancellationHandler") && model.contains("worker.cancel()"),
        "the detached import worker has an owner and parent cancellation propagation")
let fileRead = model.components(separatedBy: "nonisolated private static func readSelectedFile").last ?? ""
require(fileRead.contains("while data.count <= XperienceCollections.maximumBytes {\n            try Task.checkCancellation()") &&
        fileRead.components(separatedBy: "try Task.checkCancellation()").count >= 5,
        "bounded file chunks cooperatively observe cancellation before and after reads")
require(model.contains("let document = try XperienceCollections.parse(data)\n            try Task.checkCancellation()") &&
        model.contains("try XperienceImportPrivacy.validate(edit)\n            try Task.checkCancellation()"),
        "parse and privacy stages cannot publish after worker cancellation")
require(view.contains(".onDisappear {") && view.contains("model.stop()") &&
        model.contains("chooserAdmission.invalidate()"),
        "leaving the browser invalidates chooser authority and stops input and save work")
require(model.contains("self.readRequestID == requestID") && model.contains("self.saveRequestID == requestID"),
        "retired import and save callbacks cannot publish into successor work")
require(view.contains("@State private var loadTask: Task<Void, Never>?") &&
        view.contains(".onDisappear { cancelLoad() }") && view.contains("loadTask?.cancel(); loadTask = nil"),
        "catalog pages retain and cancel their request owner")
require(view.contains("Button(\"Load more\") { startLoad(next: true) }") &&
        view.contains("Button(\"Retry\") { startLoad(next: false) }") &&
        !view.contains("Task { await load(next: true) }") && !view.contains("Task { await load(next: false) }"),
        "initial, retry and pagination requests share the catalog owner")
require(view.contains("loadRequestID == requestID") && view.contains("cancelLoad(clear: true)"),
        "catalog publication and cleanup are fenced by request and profile generations")
require(view.contains(".accessibilityAddTraits(model.destination == \"append\" ? .isSelected : [])") &&
        view.contains(".accessibilityAddTraits(row.selection == choice.id ? .isSelected : [])") &&
        view.contains(".accessibilityAddTraits(row.selection == nil ? .isSelected : [])"),
        "destination and installed-instance choices expose their selected state")
require(view.contains("Use this installed instance for \\(row.title)") &&
        model.contains("Installed instance \\(index + 1)"),
        "binding hints identify the safe source label while preserving ordinal instance labels")
let routes = view.components(separatedBy: "@ViewBuilder private func destination").last?.components(separatedBy: "private func card").first ?? ""
require(routes.components(separatedBy: ".macBackAffordance()").count == 5 &&
        view.contains("Return and reload.\")\n                    #if os(macOS)\n                    .macBackAffordance()"),
        "all pushed browser pages and the stale route fallback retain Mac Back and keyboard escape")
let filePreview = model.components(separatedBy: "func previewFile(_ url: URL, ticket").last?.components(separatedBy: "private func canPublishFile").first ?? ""
require(filePreview.contains("chooserAdmission.admit(originalTicket.admission, currentGeneration: generation)") &&
        filePreview.contains("originalLease: originalTicket.lease") &&
        filePreview.contains("requestGeneration: originalTicket.generation, originalTicket: originalTicket"),
        "the exact original chooser ticket supplies read admission, lease and generation")
require(!filePreview.contains("guard isLive") && !filePreview.contains("let captured = lease") &&
        !filePreview.contains("store.capture()") && !view.contains("inputVisible"),
        "negative control rejects latest-lease and boolean-visibility chooser admission")
let presenter = view.components(separatedBy: "private struct XperienceFileImportPresenter").last?.components(separatedBy: "private struct XperienceCollectionPage").first ?? ""
require(presenter.contains("let ticket: XperienceFileImportTicket") &&
        presenter.contains("{ [ticket, onResult] result in") && presenter.contains("onResult(ticket, result)") &&
        view.contains(".id(chooserTicket.id)"),
        "each provider completion captures its own immutable presentation ticket")
require(model.contains("chooserAdmission.cancel(originalTicket.admission, currentGeneration: generation)") &&
        view.contains("model.cancelFileImport(originalTicket)") &&
        view.contains("model.previewFile(url, ticket: originalTicket)"),
        "success, failure and cancellation carry the same original ticket")
require(model.contains("chooserAdmission.permitsPublication(originalTicket.admission, currentGeneration: generation)") &&
        model.contains("self.store.isCurrent(captured), self.canPublishFile(originalTicket)"),
        "the original chooser ticket remains active through file publication")
require(!view.contains("model.previewFile(url)") && !view.contains("model.cancelInput()"),
        "negative control rejects ticketless result and cancellation calls")
let defaultsModel = source("app/SourcesShared/CurationDefaultsModel.swift")
let defaultsShelf = source("app/SourcesShared/CurationDefaultsHomeShelf.swift")
let appearance = source("app/SourcesShared/CurationAppearanceEditor.swift")
let curated = source("app/SourcesShared/CuratedCollections.swift")
require(collections.contains("return defaults.currentCollections() + store.richCollections") &&
        collections.contains(".task { await defaults.loadIfNeeded() }") &&
        defaultsModel.contains("fallback: @escaping Fallback = { CurationStarterCollections.collections }"),
        "remote public definitions retain the local fallback and join one shared metadata model")
for (platform, home) in [("TV", tv), ("iOS/Mac", touch)] {
    let hub = home.components(separatedBy: "case .collectionsHub:").dropFirst().first?
        .components(separatedBy: "case .topPicks:").first ?? ""
    require(home.components(separatedBy: "CurationDefaultsHomeShelf(").count == 2 &&
            hub.contains("CurationDefaultsHomeShelf(") && hub.contains("showCollectionsHub, CollectionsHubModel.isAvailable"),
            "\(platform) inserts one defaults shelf only in the existing arranged Home hub")
}
require(defaultsShelf.contains("defaults.currentCollections().filter { $0.id != \"vortx.discover\" }") &&
        defaultsShelf.contains("guard ticket.isCurrent else { return [] }") &&
        defaultsShelf.contains("CurationCollectionDestination(collection: collection, ticket: ticket, onOpen: onOpen)"),
        "Home avoids duplicate Discover and retains original read ownership and detail routing")
let selectedEditorial = curated.components(separatedBy: "static func collectionTitles(for id: String)").last?
    .components(separatedBy: "/// Build the editorial rails once").first ?? ""
require(selectedEditorial.contains("definitions.first(where: { $0.id == id })") &&
        selectedEditorial.contains("return await fetch(definition: definition)") && !selectedEditorial.contains("fetchAll") &&
        appearance.contains("ForEach(defaults.currentCollections())"),
        "editorial folders resolve only a known selected definition without loading every rail")
if failures > 0 { print("\n\(failures) Xperience UI source failure(s)"); exit(1) }
print("\nALL PASS")
