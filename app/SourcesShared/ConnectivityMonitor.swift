import Combine
import Foundation
import Network

/// Process-wide connectivity signal (#120): ONE `NWPathMonitor` on a utility queue, published on the
/// main thread for the SwiftUI shells on every platform (iOS, iPadOS, macOS, tvOS). Until this class,
/// the app had no live network monitoring at all, only one-shot URL probes; with no connection the
/// shells opened onto dead online surfaces even when local Downloads could play.
///
/// Three consumers, three shapes:
///  - `launchOffline`: the launch verdict, set exactly once and never changed. It answers "was the
///    device offline when the app opened?" for the one-shot launch routing (land on Downloads, else
///    Settings, instead of a dead Home). Pinning is ASYMMETRIC because the failure costs are: a
///    wrong ONLINE pin merely keeps pre-feature behavior, while a wrong OFFLINE pin misroutes the
///    whole session with no correction path. A first online verdict pins immediately; a first
///    offline verdict pins only after `offlinePinConfirm` re-confirms the path is STILL down, so
///    the commonest launch shape (opening the app while Wi-Fi is reassociating for a second or two,
///    when the path reports unsatisfied or `.requiresConnection`) never pins a misroute on a
///    healthy network. Because it is pinned once, a mid-session drop can never re-trigger
///    navigation through it.
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

    /// The launch verdict: nil until pinned, then fixed for the life of the process. `true` means the
    /// app LAUNCHED offline (the launch-routing trigger). Pinned asymmetrically: a first online
    /// verdict pins false immediately; a first offline verdict pins true only after `offlinePinConfirm`
    /// re-confirms the path is still down (see `apply`).
    @Published private(set) var launchOffline: Bool?

    /// Fires on the main thread when the debounced state transitions from offline to online.
    let didBecomeOnline = PassthroughSubject<Void, Never>()

    /// Debounce window for state CHANGES: long enough to swallow a Wi-Fi blip or an interface
    /// handover, short enough that a real outage surfaces promptly.
    private let changeDebounce: TimeInterval = 2.5

    /// Confirmation window before pinning `launchOffline = true`: opening the app while Wi-Fi is
    /// still reassociating delivers a first "offline" path for a second or two on a healthy network,
    /// and a wrongly-pinned offline verdict would misroute the whole session.
    private let offlinePinConfirm: TimeInterval = 2.0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tv.vortx.connectivity", qos: .utility)
    private var pending: DispatchWorkItem?
    private var pinConfirmation: DispatchWorkItem?
    private var started = false
    /// Whether `apply` has seen the first path callback (distinct from `launchOffline == nil`, which
    /// also spans the offline confirmation window). Main-thread only.
    private var firstVerdictSeen = false
    /// The freshest RAW path verdict (pre-debounce), so the confirmation work item pins from the
    /// current truth rather than the 2-second-old one. Main-thread only.
    private var lastRawOffline = false

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

    /// Main-thread reducer for path updates. The FIRST verdict drives `isOffline` immediately (there
    /// is no earlier UI state a flap could thrash) and pins `launchOffline` asymmetrically: online
    /// pins at once, offline only schedules the confirmation below. Every verdict after the first
    /// rides the change debounce for `isOffline`.
    private func apply(offline: Bool) {
        lastRawOffline = offline
        if !firstVerdictSeen {
            firstVerdictSeen = true
            isOffline = offline   // banner truth: first verdict immediate, exactly as before
            if offline {
                confirmOfflinePinLater()   // do NOT pin yet: Wi-Fi may just be reassociating
            } else {
                launchOffline = false      // a wrong online pin is harmless (pre-feature behavior)
            }
            return
        }
        // An ONLINE verdict while the offline pin is still awaiting confirmation corrects it
        // immediately (the whole point of the window: the network came up, so the launch was not
        // meaningfully offline and no routing should fire). The banner change rides the debounce below.
        if launchOffline == nil, !offline {
            pinConfirmation?.cancel()
            pinConfirmation = nil
            launchOffline = false
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

    /// Pin `launchOffline` only after `offlinePinConfirm` seconds, and from the FRESHEST raw verdict at
    /// fire time: if the path recovered during the window an earlier online callback already pinned
    /// false (and cancelled this), so firing here normally means the device is genuinely offline. The
    /// shells' launch routing therefore triggers up to ~2s after mount; their `tab == .home` /
    /// `selection == 0` guards make that safe (a user who already navigated is deliberately left alone).
    private func confirmOfflinePinLater() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.launchOffline == nil else { return }
            self.launchOffline = self.lastRawOffline
        }
        pinConfirmation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + offlinePinConfirm, execute: work)
    }
}
