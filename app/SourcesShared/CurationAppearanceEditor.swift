import SwiftUI

/// Opened from the existing rules editor after that collection exists. The immutable session was
/// captured at the Appearance gesture. Save writes only the raw-preserving rich companion; the
/// existing rules/name/Home Save remains a separate, clearly named operation in the parent editor.
@MainActor struct CurationAppearanceEditor: View {
    let session: CurationEditSession
    let onFinish: () -> Void
    @ObservedObject private var store = ForYouStore.shared
    @ObservedObject private var defaults = CurationDefaultsModel.shared
    @StateObject private var imports = XperienceCollectionsViewModel()
    @State private var draft: CurationCollection
    @State private var sourcePicker: String?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?

    init(session: CurationEditSession, onFinish: @escaping () -> Void) {
        self.session = session; self.onFinish = onFinish
        _draft = State(initialValue: .legacy(session.collection, companion: session.document))
    }

    var body: some View {
        ScrollView {
            if store.isCurrentRichEdit(session) {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Appearance and folders").screenTitleStyle()
                Text(session.collection.name).sectionTitleStyle()
                Text("Save these settings here. Edit the collection’s rules, name and Home visibility in its collection editor.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                presentation($draft.presentation, collectionLevel: true)
                Toggle("Pin to top of Collections", isOn: $draft.pinned)
                artwork($draft.artwork)
                ForEach(Array(draft.folders.enumerated()), id: \.element.id) { index, folder in
                    folderEditor(folder.id, index: index)
                }
                Button {
                    draft.folders.append(.init(id: UUID().uuidString.lowercased(), name: String(localized: "New folder"), sources: []))
                } label: { Label("Add folder", systemImage: "folder.badge.plus") }
                    .buttonStyle(ChipButtonStyle()).disabled(draft.folders.count >= CurationDocument.maximumFolders)
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                HStack(spacing: Theme.Space.sm) {
                    Button("Save appearance and folders") { save() }
                        .buttonStyle(ChipButtonStyle(selected: true))
                        .disabled(saving)
                    Button("Cancel", action: onFinish).buttonStyle(ChipButtonStyle())
                        .disabled(saving)
                    if saving { ProgressView() }
                }
            }
            .padding(Theme.Space.screenInset)
            .frame(maxWidth: 1_100, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("This collection or profile changed. Open a fresh editor to continue.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    Button("Close", action: onFinish).buttonStyle(ChipButtonStyle())
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task { imports.reload(); await defaults.loadIfNeeded() }
        .onDisappear {
            saveTask?.cancel()
            imports.stop()
            store.retireRichEdit(session)
        }
    }

    private func folderEditor(_ id: String, index: Int) -> some View {
        let binding = Binding<CurationFolder>(
            get: { draft.folders.first(where: { $0.id == id }) ?? CurationFolder(id: id, name: "", sources: []) },
            set: { value in if let index = draft.folders.firstIndex(where: { $0.id == id }) { draft.folders[index] = value } })
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            TextField("Folder name", text: binding.name)
                .font(Theme.Typography.cardTitle).textFieldStyle(.plain)
                .padding(Theme.Space.sm).vortxSettingsCard()
            HStack(spacing: Theme.Space.sm) {
                Button("Move up") { moveFolder(id, delta: -1) }.disabled(index == 0)
                Button("Move down") { moveFolder(id, delta: 1) }.disabled(index + 1 == draft.folders.count)
                Button("Remove folder") { draft.folders.removeAll { $0.id == id } }
            }
            .buttonStyle(ChipButtonStyle())
            presentation(binding.presentation, collectionLevel: false)
            artwork(binding.artwork)
            Text("Sources").eyebrowStyle()
            ForEach(Array(binding.wrappedValue.sources.enumerated()), id: \.element.id) { sourceIndex, source in
                HStack(spacing: Theme.Space.sm) {
                    Text(sourceLabel(source)).font(Theme.Typography.label)
                    Spacer()
                    Button("Move up") { moveSource(source.id, folderID: id, delta: -1) }.disabled(sourceIndex == 0)
                    Button("Move down") { moveSource(source.id, folderID: id, delta: 1) }
                        .disabled(sourceIndex + 1 == binding.wrappedValue.sources.count)
                    Button("Remove") { binding.wrappedValue.sources.removeAll { $0.id == source.id } }
                }
                .buttonStyle(ChipButtonStyle())
            }
            Button("Add source") { sourcePicker = sourcePicker == id ? nil : id }
                .buttonStyle(ChipButtonStyle()).disabled(binding.wrappedValue.sources.count >= 8)
            if sourcePicker == id {
                Button("Collection rules") {
                    addSource(.legacyRules(collectionID: session.collection.id), to: id)
                }
                .buttonStyle(ChipButtonStyle())
                ForEach(defaults.currentCollections()) { collection in
                    ForEach(collection.folders) { folder in
                        ForEach(Array(folder.sources.enumerated()), id: \.element.id) { index, source in
                            Button(curatedSourceLabel(folder, index: index)) {
                                addSource(source.kind, to: id)
                            }
                            .buttonStyle(ChipButtonStyle())
                        }
                    }
                }
                ForEach(imports.namespaces) { namespace in
                    ForEach(CurationImportProjection.collections(namespace)) { collection in
                        ForEach(collection.folders) { folder in
                            ForEach(folder.sources) { source in
                                if case .xperience = source.kind {
                                    Button("\(collection.name) · \(folder.name)") { addSource(source.kind, to: id) }
                                        .buttonStyle(ChipButtonStyle())
                                        .accessibilityHint("Link this saved imported source without copying its private add-on configuration")
                                }
                            }
                        }
                    }
                }
                Text("Import collections to make their saved catalog sources available here.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(Theme.Space.md).vortxSettingsCard()
    }

    private func presentation(_ value: Binding<CurationPresentation>, collectionLevel: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if collectionLevel {
                Text("Layout").eyebrowStyle()
                FlowLayout(spacing: Theme.Space.sm) {
                    ForEach(CurationPresentation.Layout.allCases, id: \.self) { layout in
                        Button(layoutLabel(layout)) { value.wrappedValue.layout = layout }
                            .buttonStyle(ChipButtonStyle(selected: value.wrappedValue.layout == layout))
                            .accessibilityAddTraits(value.wrappedValue.layout == layout ? .isSelected : [])
                    }
                }
                Toggle("Show All", isOn: value.showAll)
            }
            Text("Tile shape").eyebrowStyle()
            FlowLayout(spacing: Theme.Space.sm) {
                ForEach(CurationPresentation.TileShape.allCases, id: \.self) { shape in
                    Button(shapeLabel(shape)) { value.wrappedValue.tileShape = shape }
                        .buttonStyle(ChipButtonStyle(selected: value.wrappedValue.tileShape == shape))
                        .accessibilityAddTraits(value.wrappedValue.tileShape == shape ? .isSelected : [])
                }
            }
            Toggle("Hide tile title", isOn: value.hideTitle)
        }
    }
    private func artwork(_ value: Binding<CurationArtwork>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Static artwork").eyebrowStyle()
            TextField("Cover HTTPS image URL", text: optionalText(value.cover)).privacySensitive()
            TextField("Backdrop HTTPS image URL", text: optionalText(value.backdrop)).privacySensitive()
            TextField("Logo HTTPS image URL", text: optionalText(value.logo)).privacySensitive()
            Text("Use a static HTTPS image address without account keys or private parameters.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
        .textFieldStyle(.plain)
    }
    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            value.wrappedValue = trimmed.isEmpty ? nil : trimmed
        })
    }
    private func moveFolder(_ id: String, delta: Int) {
        guard let i = draft.folders.firstIndex(where: { $0.id == id }), draft.folders.indices.contains(i + delta) else { return }
        draft.folders.swapAt(i, i + delta)
    }
    private func moveSource(_ id: String, folderID: String, delta: Int) {
        guard let f = draft.folders.firstIndex(where: { $0.id == folderID }),
              let i = draft.folders[f].sources.firstIndex(where: { $0.id == id }),
              draft.folders[f].sources.indices.contains(i + delta) else { return }
        draft.folders[f].sources.swapAt(i, i + delta)
    }
    private func addSource(_ kind: CurationSource.Kind, to folderID: String) {
        guard let index = draft.folders.firstIndex(where: { $0.id == folderID }), draft.folders[index].sources.count < 8 else { return }
        draft.folders[index].sources.append(.init(id: UUID().uuidString.lowercased(), kind: kind))
        sourcePicker = nil
    }

    /// Work from the original raw document and mutate only deliberate changed leaves. A typed
    /// projection is never serialized back over unknown future fields or removed-source tombstones.
    private func editedDocument() throws -> CurationDocument {
        var document = session.document
        let original = try document.project()
        document = try document.settingPresentation(draft.presentation, comparedTo: original.presentation)
        document = try document.settingArtwork(draft.artwork, comparedTo: original.artwork)
        if draft.pinned != original.pinned { document = try document.settingPinned(draft.pinned) }
        for old in original.folders where !draft.folders.contains(where: { $0.id == old.id }) {
            document = try document.removingFolder(old.id)
        }
        for folder in draft.folders {
            if !original.folders.contains(where: { $0.id == folder.id }) {
                document = try document.addingFolder(name: folder.name, id: folder.id)
            }
            guard let old = try document.project().folders.first(where: { $0.id == folder.id }) else { throw CurationFailure.invalidEdit }
            if old.name != folder.name { document = try document.renamingFolder(folder.id, name: folder.name) }
            document = try document.settingPresentation(folder.presentation, comparedTo: old.presentation, folderID: folder.id)
            document = try document.settingArtwork(folder.artwork, comparedTo: old.artwork, folderID: folder.id)
            for source in old.sources where !folder.sources.contains(where: { $0.id == source.id }) {
                document = try document.removingSource(source.id, folderID: folder.id)
            }
            for source in folder.sources where !old.sources.contains(where: { $0.id == source.id }) {
                document = try document.addingSource(source, folderID: folder.id)
            }
            document = try document.orderingSources(folder.sources.map(\.id), folderID: folder.id)
        }
        return try document.orderingFolders(draft.folders.map(\.id))
    }

    private func save() {
        guard !saving, store.isCurrentRichEdit(session) else { return }
        saving = true; errorMessage = nil
        saveTask = Task { @MainActor in
            defer { saving = false; saveTask = nil }
            do {
                let document = try editedDocument()
                try await store.saveRich(document, session: session)
                guard !Task.isCancelled else { return }
                onFinish()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = store.isCurrentRichEdit(session)
                    ? String(localized: "Could not save these settings. Check folder names, source limits and static HTTPS artwork addresses.")
                    : String(localized: "This collection or profile changed. Close this editor and open it again.")
            }
        }
    }
    private func curatedSourceLabel(_ folder: CurationFolder, index: Int) -> String {
        let title = "VortX · \(folder.name)"
        guard folder.sources.count != 1 else { return title }
        let source = String(localized: "Source \(index + 1)")
        return title + " · " + source
    }

    private func sourceLabel(_ source: CurationSource) -> String {
        switch source.kind {
        case .legacyRules: return String(localized: "Collection rules")
        case .curated: return String(localized: "VortX collection")
        case .interests: return String(localized: "Your interests")
        case .history: return String(localized: "Watch history")
        case .xperience: return String(localized: "Imported catalog")
        case .addonCatalog: return String(localized: "Installed add-on catalog")
        case .unsupported: return String(localized: "Unsupported source retained")
        }
    }
    private func layoutLabel(_ layout: CurationPresentation.Layout) -> String {
        switch layout {
        case .rows: return String(localized: "Rows")
        case .grid: return String(localized: "Folders")
        case .tabs: return String(localized: "Tabs")
        case .followLayout: return String(localized: "Follow layout")
        }
    }
    private func shapeLabel(_ shape: CurationPresentation.TileShape) -> String {
        switch shape {
        case .poster: return String(localized: "Poster")
        case .square: return String(localized: "Square")
        case .landscape: return String(localized: "Landscape")
        }
    }
}
