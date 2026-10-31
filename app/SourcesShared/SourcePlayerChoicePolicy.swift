import Foundation

/// Ordinary header-free HTTP(S) handoffs retain LAN/NAS/Tailscale add-on compatibility. Only resolved
/// torrents need the explicitly selected server's media origin/path. Cast preflight applies its own
/// stricter receiver policy; eligibility for an installed external player does not authorize Cast.
enum SourcePlayerChoicePolicy {
    static func canHandOffExternally(
        url: URL?,
        isTorrent: Bool,
        isUsenet: Bool,
        requestHeaders: [String: String]?,
        selectedServerURL: URL? = nil
    ) -> Bool {
        guard !isUsenet, requestHeaders?.isEmpty ?? true, let url else { return false }
        return isTorrent
            ? ReceiverURLPolicy.permitsTorrent(url, selectedServer: selectedServerURL)
            : ReceiverURLPolicy.permitsExternalHandoff(url)
    }
}
