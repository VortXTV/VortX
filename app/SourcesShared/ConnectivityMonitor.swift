import Combine
import Foundation
import Network

/// Process-wide connectivity signal (#120): ONE `NWPathMonitor` on a utility queue, published on the
/// main thread for the SwiftUI shells on every platform (iOS, iPadOS, macOS, tvOS). Until this class,
/// the app had no live network monitoring at all, only one-shot URL probes; with no connection the
/// shells opened onto dead online surfaces even when local Downloads could play.
///
/// Three consumers, three shapes:
///  - `launchOffline`: the FIRST path verdict after `start()`, set exactly once and never changed.
///    It answers "was the device offline when the app opened?" for the one-shot launch routing
///    (land on Downloads, else Settings, instead of a dead Home). Because it is pinned to the first
///    verdict, a mid-session drop can never re-trigger navigation through it.
///  - `isOffline`: the live banner signal. The first verdict applies immediately (there is no earlier
///    UI state a flap could thrash); every LATER change is debounced by `changeDebounce` so a brief
///    Wi-Fi blip or a route handover does not flicker the "You're offline" chip in and out.
///  - `didBecomeOnline`: fires on the debounced offline-to-online transition, for consumers that want
///    to refresh content when connectivity returns. Navigation is deliberately NOT such a consumer:
///    the shells clear the banner and leave the user exactly where they are.
///
/// Dependency-free by design (Foundation + Network + Combine only): no engine, no account, no UI, so
/// every target that compiles SourcesShared can start it without dragging anything else in.
final class ConnectivityMonitor: ObservableObject {
    static let shared = ConnectivityMonitor()

    /// True when the device has no usable network path (`NWPath.status != .satisfied`). Immediate for
    /// the first verdict, debounced for every change after it. Published on the main thread.
    @Published private(set) var isOffline = false

    /// The first path verdict after `start()`: nil until the monitor reports once, then fixed for the
    /// life of the process. `true` means the app LAUNCHED offline (the launch-routing trigger).
    @Published private(set) var launchOffline: Bool?

    /// Fires on the main thread when the debounced state transitions from offline to online.
    let didBecomeOnline = PassthroughSubject<Void, Never>()

    /// Debounce window for state CHANGES: long enough to swallow a Wi-Fi blip or an interface
    /// handover, short enough that a real outage surfaces promptly.
    private let changeDebounce: TimeInterval = 2.5

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tv.vortx.connectivity", qos: .utility)
    private var pending: DispatchWorkItem?
    private var started = false

    private init() {}

    /// Start watching. Called once from each app's `@main` init (main thread); later calls no-op.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            DispatchQueue.main.async { self?.apply(offline: offline) }
        }
        monitor.start(queue: queue)
    }

    /// Main-thread reducer for path updates: the first verdict lands immediately (and pins
    /// `launchOffline`); every subsequent change rides the debounce.
    private func apply(offline: Bool) {
        if launchOffline == nil {
            launchOffline = offline
            isOffline = offline
            return
        }
        // Any new verdict supersedes a pending one. This is what makes a flap a no-op: the bounce-back
        // cancels the not-yet-applied change and then matches the current state, so nothing publishes.
        pending?.cancel()
        pending = nil
        guard offline != isOffline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOffline != offline else { return }
            self.isOffline = offline
            if !offline { self.didBecomeOnline.send() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + changeDebounce, execute: work)
    }
}
