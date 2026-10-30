import SwiftUI

/// Cross-platform saved-playlist library. It uses explicit labeled controls so touch, pointer, VoiceOver and
/// Siri Remote users can reach every operation without drag-only gestures or hidden row swipes.
@MainActor
struct SavedPlaylistLibraryView: View {
    @StateObject private var store = SavedPlaylistStore.shared
    @ObservedObject private var queue = PlaybackTitleQueue.shared
    @State private var newName = ""

    var body: some View {
        List {
            Section("Save current queue") {
                TextField("Playlist name", text: $newName)
                    .accessibilityLabel("New playlist name")
                Button {
                    let name = newName
                    if let intent = store.prepareSaveCurrentQueue(named: name) {
                        Task { await store.perform(intent) }
                    }
                } label: {
                    Label("Save queue as playlist", systemImage: "plus.square.on.square")
                }
                .disabled(!queue.canUseQueue || queue.count > PlaybackTitleQueuePolicy.capacity)
                Text("Saves the titles in this queue to this profile. You can choose when to play them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Saved on this profile") {
                if store.isLoading {
                    ProgressView("Loading saved playlists…")
                } else if store.visibleRecords.isEmpty {
                    Text("No saved playlists yet.").foregroundStyle(.secondary)
                }
                ForEach(store.visibleRecords) { record in
                    NavigationLink {
                        if record.isEditable, let ownerGeneration = store.currentOwnerGeneration {
                            SavedPlaylistDetailView(record: record, ownerGeneration: ownerGeneration)
                        } else {
                            SavedPlaylistUnsupportedView()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.document?.name ?? "Playlist from a newer version")
                                .font(.headline)
                            Text(record.document.map { "\($0.entries.count) titles" }
                                 ?? "Preserved read-only on this version")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .disabled(!store.canBrowseCurrentProfile)
                }
            }

            if !store.visibleDrafts.isEmpty {
                Section("Unresolved edits") {
                    ForEach(store.visibleDrafts) { draft in
                        NavigationLink {
                            if let ownerGeneration = store.currentOwnerGeneration {
                                SavedPlaylistDraftView(draftID: draft.id, ownerGeneration: ownerGeneration)
                            } else {
                                Text("This edit is unavailable for the current profile.")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.document?.name ?? "Playlist deletion draft").font(.headline)
                                Text("Not confirmed on this profile")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }

            Section("Sync status") {
                Text(store.cloudStatusText)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Saved playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") { store.reloadFromUserGesture() }
                    .disabled(store.isLoading)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = store.message {
                Text(message)
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onAppear { store.open() }
        .modifier(SavedPlaylistBoundaryObserver())
    }
}

@MainActor
private struct SavedPlaylistDetailOpening {
    let record: SavedPlaylistRecord
    let ownerGeneration: UUID
}

@MainActor
struct SavedPlaylistDetailView: View {
    @State private var opening: SavedPlaylistDetailOpening
    @StateObject private var store = SavedPlaylistStore.shared
    @ObservedObject private var queue = PlaybackTitleQueue.shared
    @State private var editedName = ""
    @State private var confirmDelete = false
    @State private var receiptObservationToken: UUID?
    @State private var pendingDeleteIntent: SavedPlaylistWriteIntent?
    @State private var detailVisibilityGeneration = UUID()

    private var observedRecord: SavedPlaylistRecord { opening.record }
    private var ownerGeneration: UUID { opening.ownerGeneration }
    private var document: VortxNativePlaylist.Document? { observedRecord.document }
    private var observedRecordIsCurrent: Bool {
        store.record(field: observedRecord.field, ownerGeneration: ownerGeneration) == observedRecord
    }

    init(record: SavedPlaylistRecord, ownerGeneration: UUID) {
        _opening = State(initialValue: SavedPlaylistDetailOpening(record: record, ownerGeneration: ownerGeneration))
        _editedName = State(initialValue: record.document?.name ?? "")
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmDelete },
            set: { isPresented in
                confirmDelete = isPresented
                if !isPresented { pendingDeleteIntent = nil }
            }
        )
    }

    private func performConfirmedDelete(_ intent: SavedPlaylistWriteIntent?,
                                        visibilityGeneration: UUID) {
        guard visibilityGeneration == detailVisibilityGeneration, let intent else { return }
        pendingDeleteIntent = nil
        confirmDelete = false
        Task { await store.perform(intent) }
    }

    var body: some View {
        Form {
            if let document {
                Section("Playlist") {
                    TextField("Name", text: $editedName)
                        .accessibilityLabel("Playlist name")
                    Text("\(document.entries.count) of \(PlaybackTitleQueuePolicy.capacity) titles")
                        .foregroundStyle(.secondary)
                    Button {
                        let value = editedName
                        if let intent = store.prepareRename(record: observedRecord, to: value,
                                                           ownerGeneration: ownerGeneration) {
                            Task { await store.perform(intent) }
                        }
                    } label: { Label("Save name", systemImage: "pencil") }
                    .disabled(!observedRecordIsCurrent || editedName == document.name
                        || editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Cloud status") {
                    if observedRecordIsCurrent {
                        Text(store.receiptLabel(store.receiptState(field: observedRecord.field, ownerGeneration: ownerGeneration)))
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("This playlist changed. Refresh the library and reopen it before editing.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Queue") {
                    Button {
                        store.addToQueue(record: observedRecord, ownerGeneration: ownerGeneration)
                    } label: { Label("Add all to queue", systemImage: "text.badge.plus") }
                    .disabled(!observedRecordIsCurrent || !queue.canEditQueue)
                    Button {
                        if let intent = store.prepareReplaceFromCurrentQueue(
                            record: observedRecord, ownerGeneration: ownerGeneration) {
                            Task { await store.perform(intent) }
                        }
                    } label: { Label("Replace with current queue", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!observedRecordIsCurrent || !queue.canUseQueue)
                    Text("Queue changes are atomic and do not start playback.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Delete playlist", role: .destructive) {
                        guard let intent = store.prepareDelete(record: observedRecord,
                                                               ownerGeneration: ownerGeneration) else { return }
                        pendingDeleteIntent = intent
                        confirmDelete = true
                    }
                    .disabled(!observedRecordIsCurrent)
                }
            } else {
                Text("This saved playlist is no longer available in the current profile.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(document?.name ?? "Saved playlist")
        .confirmationDialog("Delete this playlist?", isPresented: deleteConfirmationBinding, titleVisibility: .visible) {
            let intentAtPresentation = pendingDeleteIntent
            let visibilityAtPresentation = detailVisibilityGeneration
            Button("Delete playlist", role: .destructive) {
                performConfirmedDelete(intentAtPresentation, visibilityGeneration: visibilityAtPresentation)
            }
            Button("Cancel", role: .cancel) { pendingDeleteIntent = nil }
        } message: {
            Text("The playlist will be removed from this profile. Other devices will update after syncing.")
        }
        .onAppear {
            detailVisibilityGeneration = UUID()
            if observedRecordIsCurrent {
                receiptObservationToken = store.beginReceiptObservation(field: observedRecord.field,
                    ownerGeneration: ownerGeneration)
            }
        }
        .onDisappear {
            if let receiptObservationToken {
                store.endReceiptObservation(field: observedRecord.field, ownerGeneration: ownerGeneration,
                    token: receiptObservationToken)
            }
            receiptObservationToken = nil
            detailVisibilityGeneration = UUID()
            pendingDeleteIntent = nil
            confirmDelete = false
        }
    }
}

@MainActor
struct SavedPlaylistDraftView: View {
    let draftID: UUID
    let ownerGeneration: UUID
    @StateObject private var store = SavedPlaylistStore.shared
    @State private var confirmDiscard = false

    private var draft: SavedPlaylistDraft? { store.draft(draftID) }

    var body: some View {
        Form {
            if let draft {
                Section("Retained edit") {
                    Text(draft.document?.name ?? "Playlist deletion")
                        .font(.headline)
                    Text("Your edit is kept until you close the app. Reloading won’t replace it.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Reload saved version") { store.reloadKeepingDraft(draftID) }
                        .disabled(!store.canContinueDraft(draftID))
                    if draft.canSaveAsCopy {
                        Button("Save as a new playlist") {
                            if let intent = store.prepareSaveAsCopy(
                                draftID: draftID, ownerGeneration: ownerGeneration) {
                                Task { await store.perform(intent) }
                            }
                        }
                        .disabled(!store.canContinueDraft(draftID))
                    }
                    Button("Discard this local edit", role: .destructive) { confirmDiscard = true }
                        .disabled(store.isDraftSaving(draftID))
                    if store.isDraftSaving(draftID) {
                        Text("Save in progress. Discard becomes available after it finishes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Retained edit") {
                    Text("This edit is available only while its original account and profile are selected.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Sync status") {
                Text(store.cloudStatusText).font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(draft?.document?.name ?? "Unresolved edit")
        .confirmationDialog("Discard this local edit?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard local edit", role: .destructive) { store.discardDraft(draftID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this in-memory draft will be removed. The saved playlist will not change.")
        }
    }
}

@MainActor
struct SavedPlaylistUnsupportedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.doc").font(.largeTitle)
            Text("Saved by a newer version").font(.title2.bold())
            Text("This playlist is preserved in your profile but can’t be edited here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .navigationTitle("Saved playlist")
    }
}

@MainActor
private struct SavedPlaylistBoundaryObserver: ViewModifier {
    @ObservedObject private var store = SavedPlaylistStore.shared

    func body(content: Content) -> some View {
        content
            .onReceive(CoreBridge.shared.$nativePlaylistChangeRevision.dropFirst()) { _ in
                store.nativePlaylistChangeDidOccur()
            }
            .onReceive(VortXSyncManager.shared.$nativePlaylistCloudReceiptRevision.dropFirst()) { _ in
                store.cloudReceiptRevisionDidChange()
            }
            .onReceive(ProfileStore.shared.$activeID.dropFirst()) { store.activeProfileWillChange(to: $0) }
            .onReceive(ProfileStore.shared.$profiles.dropFirst()) { _ in store.contextDidChange() }
            .onReceive(ProfileStore.shared.$pickedThisLaunch.dropFirst()) { _ in store.contextDidChange() }
            .onReceive(NotificationCenter.default.publisher(for: StremioAccount.credentialBoundaryDidChange)) { _ in
                store.profileBoundaryWillChange()
            }
    }
}
