import Foundation
import Combine

/// A complete invite is shared by QR/ShareLink. The encryption key stays in the URL fragment;
/// the relay receives only roomID and the server-issued high-entropy inviteCode.
struct WatchPartyInvite: Equatable {
    let roomID: String
    let inviteCode: String
    let roomKey: Data
    let url: URL
}

enum WatchPartyInviteLink {
    private static let maxURLBytes = 1_024

    static func make(roomID: String, inviteCode: String, roomKey: Data) -> URL? {
        guard token(roomID), token(inviteCode), roomKey.count == 32 else { return nil }
        let fragment = "v=1&room=\(roomID)&invite=\(inviteCode)&key=\(base64URL(roomKey))"
        var c = URLComponents()
        c.scheme = "https"
        c.host = "vortx.tv"
        c.path = "/watch-party"
        c.fragment = fragment
        guard let url = c.url, url.absoluteString.utf8.count <= maxURLBytes,
              parse(url) != nil else { return nil }
        return url
    }

    /// Strictly parses only this app's invite shape. Never log `url`, the fragment, or the key.
    static func parse(_ url: URL) -> WatchPartyInvite? {
        guard url.absoluteString.utf8.count <= maxURLBytes,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https",
              c.host?.lowercased() == "vortx.tv", c.path == "/watch-party",
              c.user == nil, c.password == nil, c.port == nil, c.query == nil,
              let fragment = c.fragment, !fragment.isEmpty,
              let items = URLComponents(string: "https://invite.invalid/?\(fragment)")?.queryItems,
              items.count == 4 else { return nil }
        var fields: [String: String] = [:]
        for item in items {
            guard fields[item.name] == nil, let value = item.value else { return nil }
            fields[item.name] = value
        }
        guard Set(fields.keys) == Set(["v", "room", "invite", "key"]),
              fields["v"] == "1", let room = fields["room"], token(room),
              let invite = fields["invite"], token(invite),
              let encodedKey = fields["key"], let key = decodeBase64URL(encodedKey), key.count == 32,
              c.percentEncodedFragment == "v=1&room=\(room)&invite=\(invite)&key=\(encodedKey)" else { return nil }
        return WatchPartyInvite(roomID: room, inviteCode: invite, roomKey: key, url: url)
    }

    private static func token(_ value: String) -> Bool {
        (22...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) ||
                (48...57).contains($0.value) || $0.value == 45 || $0.value == 95
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) ||
                (48...57).contains($0.value) || $0.value == 45 || $0.value == 95
        }) else { return nil }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), base64URL(data) == value else { return nil }
        return data
    }
}

/// OpenURL composition stores only a validated invite in memory. It never joins a room or writes state.
@MainActor
final class WatchPartyPendingInvite: ObservableObject {
    static let shared = WatchPartyPendingInvite()
    @Published private(set) var invite: WatchPartyInvite?

    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let parsed = WatchPartyInviteLink.parse(url) else { return false }
        invite = parsed
        return true
    }

    func consume() -> WatchPartyInvite? {
        defer { invite = nil }
        return invite
    }
}
