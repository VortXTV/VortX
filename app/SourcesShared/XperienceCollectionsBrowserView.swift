import SwiftUI
#if os(iOS) || os(macOS)
import UniformTypeIdentifiers
#endif

private extension View {
    @ViewBuilder func xperienceFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}

enum XperiencePresentationPolicy {
    static func ordered(_ collections: [XperienceCollections.Collection]) -> [XperienceCollections.Collection] {
        collections.filter(\.pinToTop) + collections.filter { !$0.pinToTop }
    }
    static func aspectRatio(_ shape: String) -> CGFloat {
        switch shape.uppercased() {
        case "POSTER": return 2.0 / 3.0
        case "LANDSCAPE", "WIDE": return 16.0 / 9.0
        default: return 1
        }
    }
}

/// A manual entry only. Rendering Home never reads a collection export or starts a catalog/art request.
struct XperienceHomeEntry: View {
    var body: some View {
        NavigationLink(value: XperienceHomeRoute.browser) {
            Label("Imported collections", systemImage: "folder.badge.plus")
                .font(Theme.Typography.cardTitle)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowFocusStyle())
        .accessibilityHint("Browse saved collections or import a JSON export")
        .padding(.horizontal, Theme.Space.screenInset)
        .xperienceFocusSection()
    }
}

struct XperienceCollectionsConnectCard: View {
    var body: some View {
        NavigationLink {
            XperienceCollectionsBrowserView()
                #if os(macOS)
                .macBackAffordance()
                #endif
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("Nuvio / Xperience collection imports").font(Theme.Typography.cardTitle)
                    Spacer()
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                Text("Import a JSON collection export and review its installed add-on sources. Saved imports appear beside your VortX collections in Library.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard()
        }
        .vortxCardButton()
    }
}

struct XperienceCollectionsBrowserView: View {
    @StateObject private var model = XperienceCollectionsViewModel()
    @State private var pastedJSON = ""
    @State private var chooserTicket: XperienceFileImportTicket?
    @State private var confirmReplacement = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Import collections").screenTitleStyle()
                Text("Import a collections.json export from Nuvio/Xperience, review its sources, then open Library > Collections to browse its folders.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                supportNotice
                inputCard
                if let message = model.message { Text(message).foregroundStyle(Theme.Palette.textSecondary) }
                if let document = model.preview { previewCard(document) }
                savedImports
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 1_100, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task { if !loaded { loaded = true; model.reload() } }
        .onDisappear {
            chooserTicket = nil
            loaded = false
            pastedJSON = ""
            confirmReplacement = false
            model.stop()
        }
        .onReceive(model.store.revisionEvents) { _ in
            model.retireIfStale()
            if !model.isLive { pastedJSON = ""; chooserTicket = nil; confirmReplacement = false }
        }
        .navigationDestination(for: XperienceBrowserRoute.self) { route in
            if model.accepts(route.generation) { destination(route.page, generation: route.generation) }
            else {
                Text("These collections are no longer available in this profile. Return and reload.")
                    #if os(macOS)
                    .macBackAffordance()
                    #endif
            }
        }
        .confirmationDialog("Replace this saved import?", isPresented: $confirmReplacement, titleVisibility: .visible) {
            Button("Replace saved import", role: .destructive) { model.commitStaged() }
            Button("Cancel", role: .cancel) { model.cancelStaged() }
        } message: {
            Text("Replaces only the selected import namespace in this profile. Other imports and add-ons keep their current data.")
        }
        #if os(iOS) || os(macOS)
        .background {
            if let chooserTicket {
                XperienceFileImportPresenter(ticket: chooserTicket, onResult: finishFileImport)
                    .id(chooserTicket.id)
            }
        }
        #endif
    }

    #if os(iOS) || os(macOS)
    private func finishFileImport(_ originalTicket: XperienceFileImportTicket, result: Result<[URL], Error>) {
        // Result ownership comes from the presenter's immutable value, never this mutable state.
        guard chooserTicket?.id == originalTicket.id else { return }
        chooserTicket = nil
        switch result {
        case .success(let urls):
            if let url = urls.first { model.previewFile(url, ticket: originalTicket) }
            else { model.cancelFileImport(originalTicket) }
        case .failure:
            model.cancelFileImport(originalTicket)
        }
    }
    #endif

    private var supportNotice: some View {
        card {
            Text("Your Collections library").font(Theme.Typography.cardTitle)
            Text("Imported folders use the same static collection presentation as VortX collections. Collection pins and folder order stay within Collections; Home keeps your saved section order and visibility.")
            Text("Unsupported fields stay saved. Animated artwork does not autoplay. You can link a saved catalog source to a collection you create in VortX.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var inputCard: some View {
        card {
            Text("Import JSON").font(Theme.Typography.cardTitle)
            #if os(iOS) || os(macOS)
            Button {
                if let ticket = model.beginFileImport() { chooserTicket = ticket }
            } label: { Label("Choose collections.json", systemImage: "doc.badge.plus") }
                .buttonStyle(PrimaryActionStyle()).disabled(model.busy)
            #else
            Text("Paste the complete collections.json content using the Apple TV keyboard or your iPhone keyboard.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            #endif
            SecureField("Paste JSON export content", text: $pastedJSON)
                .autocorrectionDisabled(true)
                .privacySensitive()
                .accessibilityLabel("Collection JSON content, hidden for privacy")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button {
                let input = pastedJSON
                pastedJSON = ""
                model.previewPaste(input)
            } label: { Label(model.busy ? "Preparing preview…" : "Preview pasted JSON", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(ChipButtonStyle()).disabled(model.busy || pastedJSON.isEmpty)
            Text("Use file content, not a collection URL. This flow does not fetch export links or install add-ons.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func previewCard(_ document: XperienceCollections.Document) -> some View {
        card {
            Text("Import preview").font(Theme.Typography.cardTitle)
            Text("\(document.collections.count) collections · \(document.collections.flatMap(\.folders).count) folders")
            TextField("Import name", text: $model.label).autocorrectionDisabled(true)
            Text("Save destination").font(Theme.Typography.label)
            ScrollView(.horizontal) {
                HStack {
                    Button("Append as a new import") { model.destination = "append" }
                        .buttonStyle(ChipButtonStyle(selected: model.destination == "append"))
                        .accessibilityAddTraits(model.destination == "append" ? .isSelected : [])
                        .accessibilityHint("Save as a separate import in this profile")
                    ForEach(model.namespaces, id: \.field) { namespace in
                        Button("Replace \(namespace.label)") { model.destination = namespace.field }
                            .buttonStyle(ChipButtonStyle(selected: model.destination == namespace.field))
                            .accessibilityAddTraits(model.destination == namespace.field ? .isSelected : [])
                            .accessibilityHint("Select this import as the replacement destination; saving asks for confirmation")
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            .xperienceFocusSection()
            if !document.notices.isEmpty {
                Text("Some exported providers or presentation fields are not supported. Their raw values stay saved; unavailable sources stay visible in the preview.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.warn)
            }
            ForEach(model.bindingRows) { row in
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(row.title).font(Theme.Typography.label)
                    Text(row.status).foregroundStyle(Theme.Palette.textSecondary)
                    if !row.choices.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(row.choices) { choice in
                                    Button(choice.title) { model.chooseInstance(row: row.id, choice: choice.id) }
                                        .buttonStyle(ChipButtonStyle(selected: row.selection == choice.id))
                                        .accessibilityAddTraits(row.selection == choice.id ? .isSelected : [])
                                        .accessibilityHint("Use this installed instance for \(row.title)")
                                }
                                Button("Leave unavailable") { model.chooseInstance(row: row.id, choice: "unavailable") }
                                    .buttonStyle(ChipButtonStyle(selected: row.selection == nil))
                                    .accessibilityAddTraits(row.selection == nil ? .isSelected : [])
                                    .accessibilityHint("Keep \(row.title) unavailable without discarding its layout")
                            }
                            .padding(.vertical, Theme.Space.xs)
                        }
                        .xperienceFocusSection()
                    }
                }
            }
            if model.unavailableSourceCount > 0 {
                Text("\(model.unavailableSourceCount) sources will stay unavailable. You can save their layout and review sources again after installing the required add-ons.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.warn)
            }
            Text("Instance numbers follow the installed add-on registry order. Configured addresses and private parameters stay hidden. If the instances are unclear, leave that source unavailable.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Text("Save first checks your VortX account backup and may merge account updates on this device. The import is confirmed after its local save; cloud upload is separate.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Button {
                if model.stageSave() { confirmReplacement = true }
            } label: { Label(model.busy ? "Saving…" : "Save import", systemImage: "square.and.arrow.down") }
                .buttonStyle(PrimaryActionStyle()).disabled(model.busy || !model.isLive)
        }
    }

    private var savedImports: some View {
        card {
            HStack {
                Text("Saved in this profile").font(Theme.Typography.cardTitle)
                Spacer()
                Button("Reload") { model.reload() }.buttonStyle(ChipButtonStyle()).disabled(model.busy)
            }
            if model.namespaces.isEmpty { Text("No saved collections are available.").foregroundStyle(Theme.Palette.textSecondary) }
            ForEach(model.namespaces, id: \.field) { namespace in
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(namespace.label).font(Theme.Typography.cardTitle)
                    ForEach(XperiencePresentationPolicy.ordered(namespace.document.collections), id: \.id) { collection in
                        Label(collection.title, systemImage: collection.pinToTop ? "pin.fill" : "folder")
                            .padding(Theme.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Review sources or replace this import") { model.reviewSaved(namespace.field) }
                        .buttonStyle(ChipButtonStyle()).disabled(model.busy)
                }
                .xperienceFocusSection()
            }
        }
    }

    @ViewBuilder private func destination(_ page: XperienceBrowserRoute.Page, generation: UUID) -> some View {
        switch page {
        case .collection(let namespace, let collection):
            XperienceCollectionPage(model: model, namespace: namespace, collectionID: collection)
                #if os(macOS)
                .macBackAffordance()
                #endif
        case .folder(let namespace, let collection, let folder):
            XperienceFolderPage(model: model, namespace: namespace, collectionID: collection, folderID: folder)
                #if os(macOS)
                .macBackAffordance()
                #endif
        case .catalog(let namespace, let collection, let folder, let source):
            XperienceCatalogPage(model: model, namespace: namespace, collectionID: collection,
                                  folderID: folder, sourceIndex: source, routeGeneration: generation)
                #if os(macOS)
                .macBackAffordance()
                #endif
        case .detail(let type, let id, let title):
            #if os(tvOS)
            DetailView(type: type, id: id)
            #else
            iOSDetailView(id: id, type: type, title: title)
                #if os(macOS)
                .macBackAffordance()
                #endif
            #endif
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md, content: content)
            .padding(Theme.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard().xperienceFocusSection()
    }
}

#if os(iOS) || os(macOS)
/// One immutable presenter identity per original chooser gesture. Old platform callbacks retain
/// their original ticket even after the browser disappears, reappears or presents another chooser.
private struct XperienceFileImportPresenter: View {
    let ticket: XperienceFileImportTicket
    let onResult: (XperienceFileImportTicket, Result<[URL], Error>) -> Void
    @State private var presented = false

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .fileImporter(isPresented: $presented, allowedContentTypes: [.json], allowsMultipleSelection: false) { [ticket, onResult] result in
                onResult(ticket, result)
            }
            .onAppear { presented = true }
            .onDisappear { presented = false }
    }
}
#endif

private struct XperienceCollectionPage: View {
    @ObservedObject var model: XperienceCollectionsViewModel
    let namespace: String
    let collectionID: String
    var body: some View {
        ScrollView {
            if let collection = model.collection(namespace: namespace, id: collectionID) {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text(collection.title).screenTitleStyle()
                    if collection.showAllTab {
                        NavigationLink(value: model.route(.folder(namespace, collectionID, nil))) { Label("All catalogs", systemImage: "square.grid.2x2") }
                            .buttonStyle(ChipButtonStyle())
                    }
                    if collection.viewMode.uppercased() == "ROWS" {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            ForEach(collection.folders, id: \.id) { folder in folderLink(folder, isRow: true) }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300))], spacing: Theme.Space.lg) {
                            ForEach(collection.folders, id: \.id) { folder in folderLink(folder, isRow: false) }
                        }
                    }
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
    private func folderLink(_ folder: XperienceCollections.Folder, isRow: Bool) -> some View {
        NavigationLink(value: model.route(.folder(namespace, collectionID, folder.id))) {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "folder.fill").font(Theme.Typography.screenTitle)
                    .frame(maxWidth: .infinity)
                    .frame(height: isRow ? 64 : nil)
                    .aspectRatio(isRow ? nil : XperiencePresentationPolicy.aspectRatio(folder.tileShape), contentMode: .fit)
                    .accessibilityHidden(true)
                if !folder.hideTitle { Text(folder.title).font(Theme.Typography.cardTitle) }
            }
            .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowFocusStyle()).accessibilityLabel(folder.title)
    }
}

private struct XperienceFolderPage: View {
    @ObservedObject var model: XperienceCollectionsViewModel
    let namespace: String
    let collectionID: String
    let folderID: String?
    var body: some View {
        ScrollView {
            if let collection = model.collection(namespace: namespace, id: collectionID) {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text(folderID.flatMap { id in collection.folders.first { $0.id == id }?.title } ?? "All catalogs").screenTitleStyle()
                    Text("Open a catalog to load its titles. Catalogs follow the exported folder and source order.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    ForEach(collection.folders.filter { folderID == nil || $0.id == folderID }, id: \.id) { folder in
                        Text(folder.title).font(Theme.Typography.cardTitle)
                        ForEach(Array(folder.sources.enumerated()), id: \.offset) { index, source in
                            if source.isAddon {
                                NavigationLink(value: model.route(.catalog(namespace, collectionID, folder.id, index))) {
                                    Text("\(source.type ?? "") · \(source.catalogID ?? "Catalog")")
                                        .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(RowFocusStyle())
                            } else {
                                Text("Unsupported source provider retained in this folder").foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                    }
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

private struct XperienceCatalogPage: View {
    @ObservedObject var model: XperienceCollectionsViewModel
    let namespace: String
    let collectionID: String
    let folderID: String
    let sourceIndex: Int
    let routeGeneration: UUID
    @State private var items: [CoreMeta] = []
    @State private var offset = 0
    @State private var busy = false
    @State private var more = false
    @State private var message: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadRequestID = UUID()
    private struct Identity: Hashable { let type: String; let id: String }
    var body: some View {
        ScrollView {
            if model.accepts(routeGeneration) {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Catalog").screenTitleStyle()
                    if let message { Text(message).foregroundStyle(Theme.Palette.textSecondary) }
                    if busy { ProgressView().accessibilityLabel("Loading catalog") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300))], spacing: Theme.Space.md) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            NavigationLink(value: model.route(.detail(item.type, item.id, item.name))) {
                                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                                    Image(systemName: "film").font(Theme.Typography.screenTitle).accessibilityHidden(true)
                                    Text(item.name).font(Theme.Typography.cardTitle).lineLimit(3)
                                }
                                .padding(Theme.Space.md).frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                            }
                            .buttonStyle(RowFocusStyle()).accessibilityLabel(item.name)
                        }
                    }
                    if more {
                        Button("Load more") { startLoad(next: true) }
                            .buttonStyle(ChipButtonStyle()).disabled(busy)
                    }
                    if !busy && items.isEmpty {
                        Button("Retry") { startLoad(next: false) }.buttonStyle(ChipButtonStyle())
                    }
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { if items.isEmpty { startLoad(next: false) } }
        .onDisappear { cancelLoad() }
        .onValueChange(of: model.generation) { _ in
            if !model.accepts(routeGeneration) { cancelLoad(clear: true) }
        }
        .onReceive(model.store.revisionEvents) { _ in
            if !model.accepts(routeGeneration) { cancelLoad(clear: true) }
        }
    }

    @MainActor private func startLoad(next: Bool) {
        guard !busy, model.accepts(routeGeneration) else { return }
        loadTask?.cancel()
        let requestID = UUID()
        loadRequestID = requestID
        busy = true; message = nil
        loadTask = Task { await load(next: next, requestID: requestID) }
    }

    @MainActor private func cancelLoad(clear: Bool = false) {
        loadRequestID = UUID()
        loadTask?.cancel(); loadTask = nil
        busy = false
        if clear { items = []; offset = 0; more = false; message = nil }
    }

    @MainActor private func load(next: Bool, requestID: UUID) async {
        defer {
            // A retired request must not clear the busy flag or owner of its successor.
            if loadRequestID == requestID { busy = false; loadTask = nil }
        }
        guard !Task.isCancelled, loadRequestID == requestID, model.accepts(routeGeneration) else { return }
        do {
            let request = try model.catalogRequest(namespace: namespace, collectionID: collectionID, folderID: folderID, index: sourceIndex)
            let page = try await XperienceCatalogClient.load(source: request.source, candidate: request.candidate, skip: next ? offset : nil)
            guard !Task.isCancelled, loadRequestID == requestID,
                  model.accepts(request.generation), model.accepts(routeGeneration) else { return }
            if !next { items = []; offset = 0 }
            var seen = Set(items.map { Identity(type: $0.type, id: $0.id) })
            for item in page where seen.insert(.init(type: item.type, id: item.id)).inserted && items.count < XperienceCatalogClient.maximumItems { items.append(item) }
            offset += page.count
            let supportsSkip = request.candidate.catalogs.contains { catalog in
                catalog.supportsSkip &&
                request.source.type.map { catalog.type.utf8.elementsEqual($0.utf8) } == true &&
                request.source.catalogID.map { catalog.id.utf8.elementsEqual($0.utf8) } == true
            }
            more = supportsSkip && !page.isEmpty && items.count < XperienceCatalogClient.maximumItems
            if items.count >= XperienceCatalogClient.maximumItems { message = "This browser shows up to \(XperienceCatalogClient.maximumItems) titles per catalog." }
            else if page.isEmpty && items.isEmpty { message = "This catalog returned no titles." }
        } catch is CancellationError {
            // Cancellation is an owned lifecycle transition, not a user-facing catalog error.
        } catch {
            guard !Task.isCancelled, loadRequestID == requestID,
                  model.accepts(routeGeneration) else { return }
            message = (error as? XperienceCatalogClient.Failure)?.errorDescription
                ?? "This catalog is unavailable. Return to the import preview and review its source mapping."
        }
    }
}
