import SwiftUI

/// Records preference writes on the `[settings]` channel (`SettingsChangeLog`) only while the Settings screen it
/// wraps is on view, using the same visibility as `VisibleCore`. One modifier on each platform's Settings root.
struct SettingsChangeRecorder: ViewModifier {
    @Environment(\.engineObservationActive) private var visible

    func body(content: Content) -> some View {
        content
            .task(id: visible) { SettingsChangeLog.setWatching(visible) }   // on appear and on every visibility change
            .onDisappear { SettingsChangeLog.setWatching(false) }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                SettingsChangeLog.logChanges()
            }
    }
}
