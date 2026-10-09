import SwiftUI

/// Both controls capture through the existing profile discovery transaction. The old Trakt
/// boolean is only a compatibility mirror written by projection application, not a second owner.
struct ContinueWatchingSettingsView: View {
    @AppStorage(ContinueWatchingPreferences.sourceKey) private var source = "local"
    @AppStorage(ContinueWatchingPreferences.windowKey) private var window = "20"
    var body: some View {
        Picker("Continue Watching source", selection: Binding(get: { source }, set: { value in
            if ContinueWatchingPreferences.writeUserChoice(value, forKey: ContinueWatchingPreferences.sourceKey,
                                                           write: { source = value }) { save() }
        })) {
            ForEach(ContinueWatchingService.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
        }
        Picker("Continue Watching range", selection: Binding(get: { window }, set: { value in
            if ContinueWatchingPreferences.writeUserChoice(value, forKey: ContinueWatchingPreferences.windowKey,
                                                           write: { window = value }) { save() }
        })) {
            ForEach(ContinueWatchingWindow.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
        }
        Text("One primary rail for this profile. Service history is read-only and never replaces Local / VortX history. Last 90 days includes dated activity only; unknown dates appear after dated titles in item-count ranges. SIMKL up-next titles start without a resume offset.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func save() {
        ProfileStore.shared.captureDiscovery(continueWatchingEdited: true)
        NotificationCenter.default.post(name: ContinueWatchingPreferences.changedNote, object: nil)
        HomeContinueWatchingSelection.refreshCurrent()
        #if os(tvOS)
        TopShelfSnapshotWriter.publishCurrent()
        #endif
    }
}
