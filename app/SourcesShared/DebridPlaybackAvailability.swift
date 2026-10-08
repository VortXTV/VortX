import Foundation

/// Eligibility to attempt resolution, not proof that startup or an NZB create will succeed. Ranking must
/// never start a runtime or contact a provider. The resolver owns its bounded endpoint wait and capabilities.
enum UsenetPlaybackAdmissionPolicy {
    enum LocalRuntime: Equatable { case unavailable, native, legacy }

    static func canResolve(remoteConfigured: Bool, localRuntime: @autoclosure () -> LocalRuntime,
                           savedProviderConfigured: @autoclosure () -> Bool,
                           addonServersAvailable: @autoclosure () -> Bool) -> Bool {
        remoteConfigured || (localRuntime() != .unavailable && (addonServersAvailable() || savedProviderConfigured()))
    }
}

final class DebridPlaybackAvailability: @unchecked Sendable {
    static let shared = DebridPlaybackAvailability()

    private let lock = NSLock()
    private var torBoxConfigured = false
    private var usenetProviderConfigured = false

    private init() {}

    func publish(torBoxConfigured: Bool) {
        lock.withLock {
            self.torBoxConfigured = torBoxConfigured
        }
    }

    /// Whether the user configured their own usenet provider (the on-device NNTP path). Published at launch
    /// and on every credential mutation by `UsenetProviderStore`.
    func publishUsenetProvider(_ configured: Bool) {
        lock.withLock {
            self.usenetProviderConfigured = configured
        }
    }

    /// Actual selected-runtime capability. A native Full build can attempt bounded startup before it has
    /// published an endpoint; a missing native binary/slice cannot. Never borrow a legacy listener in native
    /// mode, and never start a process as a side effect of ranking or a Watch button's computed property.
    static var localUsenetRuntime: UsenetPlaybackAdmissionPolicy.LocalRuntime {
        #if VORTX_NO_EMBEDDED_SERVER
        return .unavailable
        #else
        if StremioServer.nativeTransportSelected {
            #if os(macOS)
            return Bundle.main.path(forResource: "vortx-streaming-server", ofType: nil) != nil ? .native : .unavailable
            #else
            return VortxNativeServerFlag.isSupported ? .native : .unavailable
            #endif
        }
        return StremioServer.usenetNodeBase != nil ? .legacy : .unavailable
        #endif
    }

    /// The per-stream gate reads fresh owner-scoped saved credentials only when remote availability or
    /// validated add-on hints cannot already admit it. Neither an unavailable runtime nor Lite reads them.
    func canResolveUsenet(savedProviderConfigured: @autoclosure () -> Bool,
                          addonServersAvailable: @autoclosure () -> Bool) -> Bool {
        UsenetPlaybackAdmissionPolicy.canResolve(
            remoteConfigured: canResolveUsenetRemotely, localRuntime: Self.localUsenetRuntime,
            savedProviderConfigured: savedProviderConfigured(), addonServersAvailable: addonServersAvailable())
    }

    var canResolveUsenet: Bool {
        let saved = lock.withLock { usenetProviderConfigured }
        return canResolveUsenet(savedProviderConfigured: saved, addonServersAvailable: false)
    }

    /// TorBox remains available without either local runtime, including Lite. Its existing cache/resolve
    /// priority is owned by DebridCoordinator, independently of the row's admission decision.
    var canResolveUsenetRemotely: Bool {
        lock.withLock { torBoxConfigured }
    }
}
