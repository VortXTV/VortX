import SwiftUI
import Combine

/// Optional explicit controls for the separately reviewed connector. The caller is the existing
/// SmartCollectionEditor; begin* executes synchronously before the private URL prompt appears.
@MainActor struct XperienceCurationExportControls: View {
    let existing: SmartCollection
    @StateObject private var controller = XperienceCurationExportController(store: ForYouStore.shared)
    @State private var prompt: Prompt?
    @State private var errorMessage: String?
    private struct Prompt: Identifiable {
        let id = UUID()
        let ticket: XperienceCurationExportController.Ticket
        let refresh: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Optional Xperience connection").eyebrowStyle()
            FlowLayout(spacing: Theme.Space.sm) {
                Button("Connect Xperience") { begin { try controller.beginLink(existing) } }
                Button("Connect this device or reconnect") { begin { try controller.beginReconnect(existing) } }
                Button("Refresh now") { begin(refresh: true) { try controller.beginRefresh(existing) } }
            }
            .buttonStyle(ChipButtonStyle())
            if let errorMessage { Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.warn) }
            if let message = controller.message { Text(message).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary) }
        }
        #if os(tvOS)
        .fullScreenCover(item: $prompt) { content($0) }
        #else
        .sheet(item: $prompt) { content($0) }
        #endif
    }
    private func begin(refresh: Bool = false,
                       _ operation: () throws -> XperienceCurationExportController.Ticket) {
        do {
            let ticket = try operation()
            errorMessage = nil
            prompt = .init(ticket: ticket, refresh: refresh)
        } catch {
            errorMessage = String(localized: "This connection could not be opened. A new link needs an unlinked collection; an existing link uses Reconnect or Refresh now.")
        }
    }
    private func content(_ prompt: Prompt) -> some View {
        XperienceCurationExportPrompt(controller: controller, ticket: prompt.ticket, refresh: prompt.refresh) {
            self.prompt = nil
        }
    }
}

@MainActor private struct XperienceCurationExportPrompt: View {
    @ObservedObject var controller: XperienceCurationExportController
    let ticket: XperienceCurationExportController.Ticket
    let refresh: Bool
    let onFinish: () -> Void
    @StateObject private var input: XperienceCurationExportPromptState
    private var busy: Bool { controller.phase == .loading || controller.phase == .saving }

    init(controller: XperienceCurationExportController,
         ticket: XperienceCurationExportController.Ticket, refresh: Bool,
         onFinish: @escaping () -> Void) {
        self.controller = controller; self.ticket = ticket; self.refresh = refresh
        self.onFinish = onFinish
        _input = StateObject(wrappedValue: .init(controller: controller, ticket: ticket))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text(refresh ? "Refresh collection" : "Connect Xperience").screenTitleStyle()
                if !refresh {
                    Text("Paste the private link from Xperience’s Share profile option, then preview and choose a collection. This device keeps the private address in Keychain; VortX profile sync carries the saved collection definition.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    SecureField("Private Share profile URL", text: $input.privateURL)
                        .privacySensitive().autocorrectionDisabled(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Preview") { input.preview() }
                        .buttonStyle(ChipButtonStyle(selected: true)).disabled(busy || input.retired || input.privateURL.isEmpty)
                    ForEach(controller.selections) { selection in
                        Button("\(selection.title) · \(selection.folderCount) folders") { input.selectedID = selection.id }
                            .buttonStyle(ChipButtonStyle(selected: input.selectedID == selection.id))
                            .accessibilityAddTraits(input.selectedID == selection.id ? .isSelected : [])
                    }
                    if !controller.selections.isEmpty {
                        Button("Apply selected collection") { input.apply(onFinish: onFinish) }
                            .buttonStyle(ChipButtonStyle(selected: true)).disabled(busy || input.retired || input.selectedID == nil)
                    }
                }
                if busy { ProgressView().accessibilityLabel(refresh ? "Refreshing collection" : "Preparing collection") }
                if let message = controller.message ?? input.localMessage {
                    Text(message).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
                Text("Refresh runs only when you ask. Existing local folder and source edits stay in this collection.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Button("Cancel") { input.cancel(); onFinish() }.buttonStyle(ChipButtonStyle())
            }
            .padding(Theme.Space.screenInset)
            .frame(maxWidth: 1_000, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task { if refresh { input.refresh(onFinish: onFinish) } }
        .onDisappear { input.cancel() }
        .onReceive(input.$retired) { if $0 { onFinish() } }
    }
}
