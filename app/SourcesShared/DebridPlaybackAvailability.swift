import Foundation

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

    /// A usenet source can be resolved when EITHER a TorBox key OR the user's own usenet provider is
    /// configured. On the Lite build (no embedded server) the built-in NNTP path is compiled out, so only a
    /// TorBox key can resolve usenet there; a usenet-provider credential entered on Lite does not falsely
    /// enable a usenet row.
    var canResolveUsenet: Bool {
        lock.withLock {
            #if VORTX_NO_EMBEDDED_SERVER
            return torBoxConfigured
            #else
            return torBoxConfigured || usenetProviderConfigured
            #endif
        }
    }
}
