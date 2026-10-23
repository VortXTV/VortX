import Combine
import SwiftUI

/// Forwards `CoreBridge` change notifications to one screen only while that screen is on view.
///
/// Every engine event (sources streaming in on a detail page, search results, playback progress) publishes
/// on the bridge, and every screen observing it re-evaluates its whole body. TabView keeps visited tabs alive,
/// so Home, Discover, Library, Search, Add-ons and Settings were all re-rendering underneath whatever the
/// viewer was actually using. Closed, the gate notes that it missed a change; the screen re-reads everything
/// fresh the next time it renders, so nothing is lost, it is only deferred until it can be seen.
final class EngineChangeGate: ObservableObject {
    private var subscription: AnyCancellable?
    private(set) var isOpen = true
    private var missed = false

    init(core: CoreBridge = .shared) {
        subscription = core.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            if self.isOpen { self.objectWillChange.send() } else { self.missed = true }
        }
    }

    /// Opens or closes the gate. Reopening after a missed change sends one change when `announce` is set
    /// (from an event handler); pass false when the screen is already re-rendering for another reason.
    func setOpen(_ open: Bool, announce: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        guard open, missed else { return }
        missed = false
        if announce { objectWillChange.send() }
    }
}

/// The player's engine observation. Every engine event bumps `CoreBridge.revision`, so a player observing the
/// whole bridge rebuilt its entire screen on each one during playback (every progress save, every background
/// load), which made the controls slow to appear on pause. This forwards only the changes the player draws,
/// streams (`streamsEpoch`) and the loaded title (`metaDetails`), and every change while a panel that lists
/// sources is open, so a source list filling in stays live.
final class PlayerEngineChanges: ObservableObject {
    private var subscriptions: [AnyCancellable] = []
    private(set) var followsAll = false

    init(core: CoreBridge = .shared) {
        let drawn = Publishers.Merge(core.$streamsEpoch.dropFirst().map { _ in () },
                                     core.$metaDetails.dropFirst().map { _ in () })
        subscriptions = [
            drawn.sink { [weak self] in self?.objectWillChange.send() },
            core.objectWillChange.sink { [weak self] _ in
                guard let self, self.followsAll else { return }
                self.objectWillChange.send()
            },
        ]
    }

    /// Follow every engine change while a source list is on screen; turning it on catches up once.
    func followAll(_ on: Bool) {
        guard on != followsAll else { return }
        followsAll = on
        if on { objectWillChange.send() }
    }
}

private struct EngineObservationActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while this screen is not on view (another tab is selected, or the player covers it).
    var engineObservationActive: Bool {
        get { self[EngineObservationActiveKey.self] }
        set { self[EngineObservationActiveKey.self] = newValue }
    }
}

/// The shared `CoreBridge`, observed only while `engineObservationActive` holds. Drop-in for
/// `@EnvironmentObject private var core: CoreBridge` on a tab's root screen. A change of visibility re-renders
/// the screen through the environment, which is when the gate opens or closes, so no extra change is sent.
@propertyWrapper
struct VisibleCore: DynamicProperty {
    @StateObject private var gate = EngineChangeGate()
    @Environment(\.engineObservationActive) private var active

    var wrappedValue: CoreBridge { CoreBridge.shared }

    func update() { gate.setOpen(active, announce: false) }
}
