#if VORTX_NATIVE_DATA_ENGINE
import SwiftUI

/// A pending legacy-history import must be visible even when there is only one profile and the
/// picker never appears. This notice does not cover or disable an already usable native session.
struct NativeWatchedMigrationNotice: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var sync = VortXSyncManager.shared
    @State private var retryTask: Task<Void, Never>?
    @State private var retryGeneration: UUID?

    var body: some View {
        if sync.isSignedIn, !sync.nativeWatchedMigrationPending.isEmpty {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved history needs episode metadata")
                        .font(.headline)
                    Text(core.hasNativeSession
                         ? "Some older history is waiting for its original add-on. Your current library remains available."
                         : "First-time setup is waiting for episode metadata from an original add-on. Your saved history is preserved.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: retry) {
                    Text(retryGeneration == nil ? "Retry" : "Retrying…")
                        .frame(minHeight: 44)
                }
                .disabled(retryGeneration != nil)
                .accessibilityLabel("Retry saved-history migration")
            }
            .padding(Theme.Space.md)
            .foregroundStyle(Theme.Palette.textPrimary)
            .background(Theme.Palette.surface1)
            .onDisappear(perform: cancelRetry)
            .onChange(of: sync.account?.id) { _ in cancelRetry() }
            .onChange(of: profiles.activeID) { _ in cancelRetry() }
        }
    }

    private func retry() {
        guard retryGeneration == nil else { return }
        let generation = UUID()
        let accountID = sync.account?.id
        let profileID = profiles.activeID
        retryGeneration = generation
        retryTask = Task { @MainActor in
            guard !Task.isCancelled, retryGeneration == generation,
                  sync.account?.id == accountID, profiles.activeID == profileID else { return }
            await sync.retryNativeWatchedMigration()
            guard !Task.isCancelled, retryGeneration == generation else { return }
            retryGeneration = nil
            retryTask = nil
        }
    }

    private func cancelRetry() {
        retryGeneration = nil
        retryTask?.cancel()
        retryTask = nil
    }
}
#endif
