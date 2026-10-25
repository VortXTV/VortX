import SwiftUI

/// One shared title/episode action. IDs are copied from already admitted detail metadata, never a source URL.
@MainActor
struct PlaybackTitleQueueButton: View {
    let candidate: PlaybackTitleQueuePolicy.Candidate
    var onInteraction: () -> Void = {}
    @ObservedObject private var queue = PlaybackTitleQueue.shared
    @State private var showActions = false
    @State private var message: String?

    var body: some View {
        Button { onInteraction(); showActions = true } label: {
            Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityHint("Play this title next, add it to the end, or edit the playback queue.")
        .confirmationDialog("Playback queue", isPresented: $showActions, titleVisibility: .visible) {
            Button("Play next") { add(.next) }
            Button("Add to end") { add(.last) }
            Button("Open queue") { queue.showEditor() }
        }
        .alert("Playback queue", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(message ?? "") }
    }

    private func add(_ placement: PlaybackTitleQueuePolicy.Placement) {
        if !queue.enqueue(candidate, placement: placement) {
            message = queue.admissionProblem
        }
    }
}

/// Button-based reorder is usable with touch, a mouse, VoiceOver and the Siri Remote.
/// The same state owner drives every engine and Apple platform; no drag-only or index-based writes.
@MainActor
struct PlaybackTitleQueueEditor: View {
    @ObservedObject private var queue = PlaybackTitleQueue.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Playback queue").font(.title2.bold())
                    Spacer()
                    Button("Done") { dismiss() }
                }
                Text("Up to 100 titles. This session queue clears when VortX closes or you change profile or account.")
                    .font(.callout).foregroundStyle(.secondary)
                if let active = queue.activeEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current item").font(.headline)
                        title(active)
                        if !FullscreenPlaybackGate.shared.playerActive {
                            Button("Retry current item") { _ = queue.retryCurrent() }
                        }
                    }
                }
                if queue.upcoming.isEmpty {
                    Text("Add titles from their detail page to build your queue.")
                        .foregroundStyle(.secondary)
                } else {
                    if queue.canStart {
                        Button { _ = queue.requestNext() } label: { Label("Play queue", systemImage: "play.fill") }
                    }
                    Text("Up next · \(queue.upcoming.count)").font(.headline)
                    ForEach(Array(queue.upcoming.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 10) {
                            title(entry)
                            HStack(spacing: 18) {
                                Button { queue.move(entry.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                                    .disabled(index == 0)
                                Button { queue.move(entry.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                                    .disabled(index + 1 == queue.upcoming.count)
                                Button(role: .destructive) { queue.remove(entry.id) } label: { Label("Remove", systemImage: "minus.circle") }
                            }
                            .font(.callout)
                        }
                        .padding(.vertical, 10)
                        Divider()
                    }
                    Button("Clear upcoming titles", role: .destructive) { queue.clearUpcoming() }
                }
            }
            .padding(32)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .tint(Theme.Palette.accent)
    }

    private func title(_ entry: PlaybackTitleQueuePolicy.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: entry.candidate.title).font(.headline)
            if let label = entry.candidate.episodeLabel {
                Text(verbatim: label).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Remains reachable on source failure and after a pre-first-frame player closes. Retrying mints a
/// fresh intent for the same stable head; it never marks watched or advances an unfinished title.
@MainActor
struct PlaybackTitleQueueRouteActions: View {
    let routeID: UUID
    @ObservedObject private var queue = PlaybackTitleQueue.shared
    @ObservedObject private var gate = FullscreenPlaybackGate.shared
    @State private var message: String?

    var body: some View {
        if queue.route?.id == routeID {
            HStack(spacing: 20) {
                Button("Retry queued title") {
                    if !queue.retryPending(routeID) { message = queue.admissionProblem }
                }
                Button("Edit queue") { queue.showEditor() }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .disabled(gate.playerActive)
            .alert("Playback queue", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(message ?? "") }
        }
    }
}

/// Incoming willSet values are checked directly. The bounded queue does no network, disk or clock work.
@MainActor
struct PlaybackTitleQueueBoundaryObserver: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onReceive(ProfileStore.shared.$activeID) { PlaybackTitleQueue.shared.activeProfileWillChange($0) }
            .onReceive(ProfileStore.shared.$profiles) { PlaybackTitleQueue.shared.profilesWillChange($0) }
            .onReceive(ProfileStore.shared.$pickedThisLaunch) { PlaybackTitleQueue.shared.pickedThisLaunchWillChange($0) }
            .onReceive(CoreBridge.shared.$revision) { _ in PlaybackTitleQueue.shared.invalidateIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: StremioAccount.credentialBoundaryDidChange)) { _ in
                PlaybackTitleQueue.shared.invalidateIfNeeded()
            }
    }
}
