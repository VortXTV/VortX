import SwiftUI

/// Shared iOS/tvOS/macOS editor.  Endpoint metadata and the API key both remain Keychain-only;
/// this screen intentionally has no AppStorage fields and never renders a saved key.
struct NZBIndexerSettingsView: View {
    @State private var scope = NZBIndexerStore.captureScope()
    @State private var document = NZBIndexerStore.load()
    @State private var storeError: String?
    @State private var editing: NZBIndexerConfig?
    @State private var showingEditor = false
    var body: some View {
        List {
            Section {
                Text("Search enabled Newznab indexers directly when opening a movie or episode. Their NZB results join the normal source list and next-episode search; playback uses your configured Usenet route.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let storeError { Text(storeError).font(.footnote).foregroundStyle(.red) }
            }
            Section("Indexers") {
                ForEach(document.indexers) { indexer in
                    Button { editing = indexer; showingEditor = true } label: {
                        HStack { VStack(alignment: .leading) { Text(indexer.name); Text(NZBIndexerEndpointPolicy.hostOnly(indexer.endpoint) ?? "Invalid endpoint").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(indexer.enabled ? "On" : "Off").foregroundStyle(.secondary) }
                    }
                }
                .onDelete { offsets in
                    guard NZBIndexerStore.isCurrent(scope) else { return }
                    for offset in offsets { _ = NZBIndexerStore.remove(indexerID: document.indexers[offset].id, scope: scope) }
                    reload(); CoreBridge.shared.nzbIndexerConfigurationDidChange()
                }
                Button { editing = NZBIndexerConfig(name: "NZBGeek", endpoint: "https://api.nzbgeek.info/api"); showingEditor = true } label: { Label("Add Newznab indexer", systemImage: "plus") }
            }
        }
        .navigationTitle("NZB indexers")
        .sheet(isPresented: $showingEditor, onDismiss: { editing = nil }) {
            if let editing { NZBIndexerEditor(config: editing, scope: scope) { reload(); showingEditor = false } }
        }
        .onAppear { scope = NZBIndexerStore.captureScope(); reload() }
    }
    private func reload() { document = NZBIndexerStore.load(scope: scope); storeError = NZBIndexerStore.readError(scope: scope) }
}

private struct NZBIndexerEditor: View {
    let scope: NZBIndexerStore.Scope
    let config: NZBIndexerConfig; let saved: () -> Void
    @State private var name = ""; @State private var endpoint = ""; @State private var apiKey = ""; @State private var enabled = true; @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(config: NZBIndexerConfig, scope: NZBIndexerStore.Scope, saved: @escaping () -> Void) { self.config = config; self.scope = scope; self.saved = saved; _name = State(initialValue: config.name); _endpoint = State(initialValue: config.endpoint); _enabled = State(initialValue: config.enabled) }
    var body: some View {
        NavigationStack { Form {
            TextField("Name", text: $name); endpointField; apiKeyField
            Text("Leave the API key blank to keep the existing saved key.").font(.footnote).foregroundStyle(.secondary)
            Toggle("Enabled", isOn: $enabled)
            if let error { Text(error).foregroundStyle(.red) }
            if NZBIndexerStore.load(scope: scope).indexers.contains(where: { $0.id == config.id }) {
                Button("Remove indexer", role: .destructive) { guard NZBIndexerStore.isCurrent(scope), NZBIndexerStore.remove(indexerID: config.id, scope: scope) != nil else { error = "Could not remove this indexer."; return }; apiKey = ""; CoreBridge.shared.nzbIndexerConfigurationDidChange(); saved(); dismiss() }
            }
        }.navigationTitle("Indexer").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { apiKey = ""; dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }}
    }
    private func save() {
        guard NZBIndexerStore.isCurrent(scope) else { apiKey = ""; dismiss(); return }
        guard case .success = NZBIndexerEndpointPolicy.validate(endpoint) else { error = "Enter a valid HTTPS endpoint without credentials or a fragment."; return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a name."; return }
        let next = NZBIndexerConfig(id: config.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: endpoint, enabled: enabled)
        guard NZBIndexerStore.save(next, apiKey: apiKey.isEmpty ? nil : apiKey, scope: scope) != nil else { error = "Could not securely save this indexer."; return }
        apiKey = ""; CoreBridge.shared.nzbIndexerConfigurationDidChange(); saved(); dismiss()
    }
    @ViewBuilder private var endpointField: some View {
        #if os(iOS) || os(tvOS)
        TextField("HTTPS API endpoint", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        TextField("HTTPS API endpoint", text: $endpoint)
        #endif
    }
    @ViewBuilder private var apiKeyField: some View {
        #if os(iOS) || os(tvOS)
        SecureField("API key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        SecureField("API key", text: $apiKey)
        #endif
    }
}
