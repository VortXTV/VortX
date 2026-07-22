import Foundation
#if !DEBRID_LIBRARY_LIVENESS_TEST
import SwiftUI
#endif

/// Credential-revision and attempt ordering for one asynchronously loaded debrid-library value.
/// Foundation-only so the standalone ordering gate compiles and exercises this exact production type.
@MainActor
final class DebridLibraryLoadStateMachine<Value: Sendable> {
    enum Phase: Equatable { case idle, loading, loaded }
    typealias Loader = @Sendable () async -> DebridVersionedResult<Value>

    private let credentialStore: DebridCredentialSnapshotStore
    private let emptyValue: Value
    private let loader: Loader

    private(set) var phase: Phase = .idle
    private(set) var value: Value
    private(set) var loadedRevision: UInt64?
    private(set) var nextAttemptID: UInt64 = 0
    private(set) var activeAttemptID: UInt64?
    var stateDidChange: (@MainActor (DebridLibraryLoadStateMachine<Value>) -> Void)?

    init(
        credentialStore: DebridCredentialSnapshotStore,
        initialValue: Value,
        emptyValue: Value,
        loader: @escaping Loader
    ) {
        self.credentialStore = credentialStore
        self.value = initialValue
        self.emptyValue = emptyValue
        self.loader = loader
    }

    func loadIfNeeded(snapshot: DebridCredentialSnapshot) async {
        guard loadedRevision != snapshot.revision else { return }
        await performLoad(snapshot: snapshot)
    }

    func reload(snapshot: DebridCredentialSnapshot) async {
        await performLoad(snapshot: snapshot)
    }

    private func performLoad(snapshot: DebridCredentialSnapshot) async {
        guard let attemptID = beginAttempt(for: snapshot) else { return }
        guard !snapshot.keys.isEmpty else {
            _ = mutateIfActive(attemptID: attemptID, snapshot: snapshot) {
                value = emptyValue
                loadedRevision = snapshot.revision
                phase = .loaded
                activeAttemptID = nil
            }
            return
        }

        guard mutateIfActive(attemptID: attemptID, snapshot: snapshot, mutation: {
            phase = .loading
        }) else { return }

        let result = await loader()
        guard !Task.isCancelled else {
            recoverAfterInterruptedAttempt(attemptID: attemptID, snapshot: snapshot)
            return
        }
        guard result.revision == snapshot.revision else {
            recoverAfterInterruptedAttempt(attemptID: attemptID, snapshot: snapshot)
            return
        }

        var didPublish = false
        let revisionAccepted = credentialStore.compareAndPublish(
            revision: result.revision,
            mutation: {
                guard self.activeAttemptID == attemptID,
                      self.credentialStore.load() == snapshot,
                      !Task.isCancelled else { return }
                value = result.value
                loadedRevision = snapshot.revision
                phase = .loaded
                activeAttemptID = nil
                stateDidChange?(self)
                didPublish = true
            }
        )
        guard revisionAccepted && didPublish else {
            recoverAfterInterruptedAttempt(attemptID: attemptID, snapshot: snapshot)
            return
        }
    }

    private func beginAttempt(for snapshot: DebridCredentialSnapshot) -> UInt64? {
        precondition(nextAttemptID < UInt64.max, "debrid library attempt id exhausted")
        nextAttemptID += 1
        let attemptID = nextAttemptID
        var activated = false
        _ = credentialStore.compareAndPublish(revision: snapshot.revision) {
            guard self.credentialStore.load() == snapshot else { return }
            self.activeAttemptID = attemptID
            self.stateDidChange?(self)
            activated = true
        }
        return activated ? attemptID : nil
    }

    @discardableResult
    private func mutateIfActive(
        attemptID: UInt64,
        snapshot: DebridCredentialSnapshot,
        mutation: @MainActor () -> Void
    ) -> Bool {
        var mutated = false
        let revisionAccepted = credentialStore.compareAndPublish(
            revision: snapshot.revision,
            mutation: {
                guard self.activeAttemptID == attemptID,
                      self.credentialStore.load() == snapshot else { return }
                mutation()
                stateDidChange?(self)
                mutated = true
            }
        )
        return revisionAccepted && mutated
    }

    private func recoverAfterInterruptedAttempt(
        attemptID: UInt64,
        snapshot: DebridCredentialSnapshot
    ) {
        _ = mutateIfActive(attemptID: attemptID, snapshot: snapshot, mutation: {
            activeAttemptID = nil
            phase = loadedRevision == snapshot.revision ? .loaded : .idle
        })
    }
}

#if !DEBRID_LIBRARY_LIVENESS_TEST

/// Browse-your-debrid-cloud: lists what is ALREADY sitting in the user's configured debrid accounts
/// (finished torrents / stored files on Real-Debrid, AllDebrid, Premiumize, TorBox) and plays a chosen
/// item straight through the normal player, with no add-on and no re-download.
///
/// Self-contained by design: it reads the existing `DebridKeys` for configured providers, lists + resolves
/// through `DebridCoordinator`, and hands the resolved DIRECT url to the same `PlayerScreen` cover every
/// browse screen uses (`iOSPlayerCover`). The only thing it needs from the app shell is the two environment
/// objects that shell already injects app-wide (`StremioAccount`, `CoreBridge`), so the Settings pass can
/// reach it with a plain `NavigationLink { DebridLibraryView() }`, no extra plumbing.
///
/// Fail-soft throughout: a provider with no key is simply absent; a provider that errors or returns nothing
/// hides its section; a resolve that fails shows an inline notice, never a crash. This UI ALSO runs on macOS
/// (the `VortXMac` target reuses `SourcesiOS`), so it stays touch-and-pointer friendly with no tvOS focus.
struct DebridLibraryView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @ObservedObject private var debrid = DebridKeys.shared
    @StateObject private var model = DebridLibraryModel()
    @State private var launch: iOSPlayerLaunch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header
                content(for: model.phase)
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task(id: debrid.revision) {
            let snapshot = debrid.snapshot
            await model.loadIfNeeded(snapshot: snapshot)
        }
        .refreshable {
            let snapshot = debrid.snapshot
            await model.reload(snapshot: snapshot)
        }
        .iOSPlayerCover($launch, account: account, core: core)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debrid").eyebrowStyle(Theme.Palette.accent)
                    Text("Your cloud").screenTitleStyle()
                }
                Spacer()
                refreshButton
            }
            Text("Play what is already in your debrid account. Finished torrents and stored files stream instantly, straight from the cloud, no add-on needed.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var refreshButton: some View {
        // The shared circular chrome disc (CircleIconDisc on the disc glass primitive, with the standard
        // press/hover feedback) instead of a hand-rolled surface2 circle, so this matches the hero back /
        // overflow discs everywhere else.
        CircleIconButton(systemName: "arrow.clockwise", diameter: Theme.Control.circleChrome) {
            Task {
                let snapshot = debrid.snapshot
                await model.reload(snapshot: snapshot)
            }
        }
        .disabled(model.phase == .loading || !debrid.hasAnyKey)
        .opacity(model.phase == .loading ? 0.5 : 1)
        .accessibilityLabel("Refresh library")
    }

    // MARK: State-driven body

    @ViewBuilder private func content(for phase: DebridLibraryModel.Phase) -> some View {
        if !debrid.hasAnyKey {
            noKeyState
        } else {
            switch phase {
            case .idle, .loading:
                loadingState
            case .loaded:
                if model.sections.isEmpty { emptyState } else { sections }
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if let error = model.resolveError {
                inlineNotice(error)
            }
            ForEach(model.sections) { section in
                providerSection(section)
            }
        }
    }

    private func providerSection(_ section: DebridLibrarySection) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text(section.service.displayName).sectionTitleStyle()
                Text("\(section.items.count)")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            VStack(spacing: Theme.Space.sm) {
                ForEach(section.items) { item in
                    row(item)
                }
            }
        }
    }

    // MARK: Row

    private func row(_ item: DebridLibraryItem) -> some View {
        Button { play(item) } label: {
            HStack(spacing: Theme.Space.md) {
                leadingGlyph(for: item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let meta = metaLine(item) {
                        Text(meta)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .vortxSettingsCard()
        }
        .buttonStyle(.plain)
        .disabled(model.resolvingID != nil)
        .opacity(model.resolvingID != nil && model.resolvingID != item.id ? 0.5 : 1)
    }

    @ViewBuilder private func leadingGlyph(for item: DebridLibraryItem) -> some View {
        ZStack {
            Circle().fill(Theme.Palette.accentSoft).frame(width: 40, height: 40)
            if model.resolvingID == item.id {
                ProgressView().tint(Theme.Palette.accent)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
    }

    // MARK: Empty / loading / no-key / error surfaces

    private var loadingState: some View {
        HStack(spacing: Theme.Space.sm) {
            ProgressView()
            Text("Reading your debrid cloud...")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.vertical, Theme.Space.xl)
    }

    private var emptyState: some View {
        placeholder(icon: "internaldrive",
                    title: "Nothing here yet",
                    message: "When you add torrents or files to your debrid account, they show up here to play.")
    }

    private var noKeyState: some View {
        placeholder(icon: "key",
                    title: "No debrid service connected",
                    message: "Add a Real-Debrid, AllDebrid, Premiumize, or TorBox API key in Settings to browse and play your cloud.")
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    private func inlineNotice(_ text: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.accent)
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    // MARK: Actions + formatting

    private func play(_ item: DebridLibraryItem) {
        // Hop to the main actor for the whole flow: the resolve awaits the DebridCoordinator actor, then the
        // published state (`resolvingID`, `resolveError`) and the view's `launch` binding are mutated back on
        // main. One resolve at a time; ignore taps while another is in flight.
        Task { @MainActor in
            guard model.resolvingID == nil else { return }
            model.resolvingID = item.id
            model.resolveError = nil
            defer { model.resolvingID = nil }
            do {
                let url = try await DebridCoordinator.shared.resolveLibraryItem(item)
                // Paste-a-link style launch: a direct URL with no library item to record progress against.
                launch = iOSPlayerLaunch(url: url, title: item.name, isTorrent: false)
            } catch {
                model.resolveError = "Could not start \"\(item.name)\". The file may have expired from your cloud."
            }
        }
    }

    private func metaLine(_ item: DebridLibraryItem) -> String? {
        var parts: [String] = []
        if let size = Self.sizeText(item.size) { parts.append(size) }
        if let when = Self.dateText(item.added) { parts.append(when) }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }

    private static func sizeText(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func dateText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Section value

/// One provider's slice of the browsable library, grouped for the sectioned list.
private struct DebridLibrarySection: Identifiable {
    let service: DebridService
    let items: [DebridLibraryItem]
    var id: String { service.rawValue }
}

// MARK: - View model

/// Loads the cloud library once per credential revision (and on manual refresh) and tracks the in-flight
/// resolve. `@MainActor` keeps attempt ownership and every published mutation serialized while the actual
/// list/resolve work is awaited on the `DebridCoordinator` actor. No key instantly loads no sections.
@MainActor
final class DebridLibraryModel: ObservableObject {
    typealias Library = [DebridService: [DebridLibraryItem]]
    typealias Phase = DebridLibraryLoadStateMachine<Library>.Phase

    @Published private(set) var phase: Phase = .idle
    @Published fileprivate private(set) var sections: [DebridLibrarySection] = []
    /// The id of the item currently being resolved, so its row shows a spinner and the rest disable.
    @Published var resolvingID: String?
    /// A user-facing resolve failure, shown inline above the sections. Cleared on the next play attempt.
    @Published var resolveError: String?

    private let loadState: DebridLibraryLoadStateMachine<Library>

    init(
        credentialStore: DebridCredentialSnapshotStore = .shared,
        loader: @escaping DebridLibraryLoadStateMachine<Library>.Loader = {
            await DebridCoordinator.shared.cloudLibraryVersioned()
        }
    ) {
        let state = DebridLibraryLoadStateMachine(
            credentialStore: credentialStore,
            initialValue: [:],
            emptyValue: [:],
            loader: loader
        )
        loadState = state
        state.stateDidChange = { [weak self] state in
            self?.apply(state)
        }
    }

    /// First appearance load, guarded per credential revision so tab re-entry does not re-hit every provider.
    func loadIfNeeded(snapshot: DebridCredentialSnapshot) async {
        await loadState.loadIfNeeded(snapshot: snapshot)
    }

    /// (Re)read every configured provider's cloud library and group it in a deterministic provider order.
    func reload(snapshot: DebridCredentialSnapshot) async {
        await loadState.reload(snapshot: snapshot)
    }

    private func apply(_ state: DebridLibraryLoadStateMachine<Library>) {
        phase = state.phase
        sections = DebridService.allCases.compactMap { service -> DebridLibrarySection? in
            guard let items = state.value[service], !items.isEmpty else { return nil }
            return DebridLibrarySection(service: service, items: items)
        }
    }
}
#endif
