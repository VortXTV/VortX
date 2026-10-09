import Foundation
import Darwin

/// A single-use capability for ONE external playback. No URL, nonce, or owner is persisted.
/// Infuse's success means either playlist end OR player close: only position + a genuine known
/// duration (the existing 90% policy), or the viewer's explicit confirmation, establishes watched.
@MainActor
final class InfuseHandoffCoordinator {
    struct Episode: Equatable {
        let id: String
        let season: Int?
        let episode: Int?
    }

    struct Context {
        let metadata: PlaybackMeta
        let duration: Double?
        let episodes: [Episode]
        /// Captured owner and launch-generation authority, never a lookup of a successor's owner.
        let isCurrent: () -> Bool
        let progress: (Double, Double?) -> Void
        let watched: () -> Void
        let acceptedSource: () -> Void
    }

    struct Launch {
        let id: UUID
        let url: URL
    }

    struct Returned: Identifiable, Equatable {
        let id: UUID
        let metadata: PlaybackMeta
        let position: Int?
        let duration: Double?
        let failed: Bool
        var completed: Bool
        let next: Episode?
    }

    private struct Pending {
        let id: UUID
        let stream: String
        let scheme: String
        let context: Context
        var launchIsCurrent: (() -> Bool)?
        var launchConfirmed = false
        var deferredCallback: URL?
    }
    private var pending: Pending?
    private var accepted: (id: UUID, context: Context)?
    private(set) var returned: Returned?

    /// Called on a new internal player session as well as before a new external launch.
    /// A later session supersedes every earlier callback and every earlier confirmation button.
    func invalidate() {
        pending = nil
        accepted = nil
        returned = nil
    }

    func prepare(stream: URL, position: Double, scheme: String, context: Context,
                 allowsLaunch: @escaping () -> Bool = { true }) -> Launch? {
        invalidate()
        guard context.isCurrent(), allowsLaunch(), Self.canTransfer(stream),
              stream.absoluteString.utf8.count <= 16_384, !scheme.isEmpty else { return nil }
        let id = UUID()
        func callback(_ outcome: String) -> URL? {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "infuse-return"
            components.path = "/\(id.uuidString.lowercased())/\(outcome)"
            return components.url
        }
        guard let success = callback("success"), let failure = callback("error"),
              let link = InfuseDeepLink.playURL(stream: stream, metadata: context.metadata,
                                                position: position, success: success, failure: failure) else { return nil }
        pending = Pending(id: id, stream: stream.absoluteString, scheme: scheme,
                          context: context, launchIsCurrent: allowsLaunch)
        return Launch(id: id, url: link)
    }

    /// A delayed OS failure for an old launch cannot tear down its replacement or an accepted return.
    func launchFinished(_ id: UUID, launched: Bool) {
        guard var value = pending, value.id == id, !value.launchConfirmed else { return }
        guard launched, value.context.isCurrent(), value.launchIsCurrent?() == true else {
            pending = nil
            return
        }
        value.launchConfirmed = true
        // The player/view may disappear after launch. Keep only captured owner authority thereafter.
        value.launchIsCurrent = nil
        let deferred = value.deferredCallback
        value.deferredCallback = nil
        pending = value
        if let deferred { handle(deferred) }
    }

    static func isCallback(_ url: URL) -> Bool { url.host?.lowercased() == "infuse-return" }

    static func canTransfer(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return false }
        guard rawHost.utf8.count <= 255 else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.isEmpty else { return false }
        // Literal parsing only, no resolver/DNS. inet_aton also covers URL loaders' legacy octal,
        // hexadecimal, shortened and integer IPv4 forms; inet_pton normalizes IPv6 spellings.
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4.s_addr) { bytes in bytes[0] != 127 && bytes.contains(where: { $0 != 0 }) }
        }
        let literal = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, literal, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { bytes in
                let zeroPrefix = bytes.prefix(15).allSatisfy { $0 == 0 }
                if zeroPrefix && bytes[15] <= 1 { return false }
                let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
                let compatible = bytes.prefix(12).allSatisfy { $0 == 0 }
                if mapped || compatible {
                    return bytes[12] != 127 && bytes.suffix(4).contains(where: { $0 != 0 })
                }
                return true
            }
        }
        return true
    }

    /// Return true for our callback namespace, even on rejection, so no generic router logs its URL.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard Self.isCallback(url) else { return false }
        guard url.absoluteString.utf8.count <= 32_768,
              let pending, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == pending.scheme, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { return true }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty,
              path[1] == pending.id.uuidString.lowercased() else { return true }
        guard pending.context.isCurrent() else { invalidate(); return true }
        let items = parts.queryItems ?? []
        func single(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        let failed = path[2] == "error"
        let position: Int?
        if path[2] == "success" {
            guard items.count == 2, single("lastPlayedUrl") == pending.stream,
                  let raw = single("position"), !raw.isEmpty, raw.count <= 6,
                  raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let seconds = Int(raw), seconds <= 604_800 else { return true }
            position = seconds
        } else if failed {
            // We launch exactly one stream. Multiple failures or an unrelated stream are not ours.
            guard single("failedUrl") == pending.stream,
                  let code = single("errorCode"), !code.isEmpty, code.count <= 8,
                  code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  items.allSatisfy({ ["failedUrl", "errorCode", "errorMessage"].contains($0.name) }),
                  items.filter({ $0.name == "errorMessage" }).count <= 1 else { return true }
            position = nil
        } else { return true }

        if !pending.launchConfirmed {
            guard pending.launchIsCurrent?() == true else { invalidate(); return true }
            // A fast return may beat the OS completion. Retain only the first valid bounded callback;
            // no mutation is admitted until the exact launch is confirmed, and a failure discards it.
            if self.pending?.deferredCallback == nil { self.pending?.deferredCallback = url }
            return true
        }

        // Consume BEFORE publishing/mutating. Reentrant, duplicate and replayed URLs are now inert.
        self.pending = nil
        accepted = (pending.id, pending.context)
        let duration = pending.context.duration.flatMap {
            $0.isFinite && $0 > 0 && $0 <= 604_800 && Double(position ?? 0) <= $0 + 2 ? $0 : nil
        }
        // An out-of-range timestamp is not completion evidence for this file's captured duration.
        let completed = position.map { p in
            duration.map { Double(p) >= $0 * 0.9 && Double(p) <= $0 + 2 } ?? false
        } ?? false
        returned = Returned(id: pending.id, metadata: pending.context.metadata, position: position,
                            duration: duration, failed: failed, completed: completed,
                            next: failed ? nil : Self.nextEpisode(after: pending.context.metadata, in: pending.context.episodes))
        guard !failed, let position else { return true }
        pending.context.acceptedSource()
        pending.context.progress(Double(position), duration)
        if completed { pending.context.watched() }
        return true
    }

    func currentReturn() -> Returned? {
        guard let accepted else {
            // Foreground activation commonly precedes onOpenURL. Reading presentation while the
            // callback is still pending must not consume its capability (nor may a malformed URL).
            if let pending, !pending.context.isCurrent() { invalidate() }
            return nil
        }
        guard accepted.context.isCurrent() else { invalidate(); return nil }
        return returned
    }

    @discardableResult
    func confirmWatched(_ id: UUID) -> Bool {
        guard let value = currentReturn(), value.id == id, !value.failed,
              !value.completed, let accepted else { return false }
        returned?.completed = true
        accepted.context.watched()
        return true
    }

    static func nextEpisode(after current: PlaybackMeta, in inventory: [Episode]) -> Episode? {
        guard current.usesSeriesLifecycle else { return nil }
        // Opaque episode IDs are never synthesized from a title id. Refuse ambiguous inventory.
        let ordered = inventory.filter { item in
            guard let season = item.season, let episode = item.episode else { return false }
            return season >= 0 && episode >= 0 && (current.season == 0 || season > 0)
        }.sorted { ($0.season!, $0.episode!, $0.id) < ($1.season!, $1.episode!, $1.id) }
        guard Set(ordered.map(\.id)).count == ordered.count,
              let index = ordered.firstIndex(where: { $0.id == current.videoId }), index + 1 < ordered.count,
              ordered[index].season == current.season, ordered[index].episode == current.episode else { return nil }
        let next = ordered[index + 1]
        guard ordered.filter({ $0.season == next.season && $0.episode == next.episode }).count == 1,
              ordered.filter({ $0.season == ordered[index].season && $0.episode == ordered[index].episode }).count == 1 else { return nil }
        guard (next.season!, next.episode!) > (ordered[index].season!, ordered[index].episode!) else { return nil }
        return next
    }
}
