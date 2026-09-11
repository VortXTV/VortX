import Foundation

/// The origin of a resolved NZB playback URL.  It is deliberately provenance only: no NZB URL, NNTP host,
/// or credential crosses this boundary into the player or persisted play state.
enum DebridUsenetRoute: String, CaseIterable, Sendable, Equatable {
    case addonNNTP
    case savedNNTP
    case torBoxCloud
}

/// Keeps account use serial and explicit.  Add-on servers are attempted as one ordered request (the Node
/// engine owns the server ordering and performs REAL per-article failover across every server in the
/// `servers` array, see `test/server-nntp.test.js` "real two-provider failover"); a saved account is only a
/// second request after that request fails.
enum UsenetRoutingPolicy {
    struct LocalAttempt: Sendable, Equatable {
        let route: DebridUsenetRoute
        let servers: [String]
    }

    /// Multiple saved servers: the add-on attempt is still ONE create carrying every add-on server, and the
    /// saved attempt is still ONE create carrying the user's enabled servers IN PRIORITY ORDER — the Node
    /// engine already falls back per-article inside a single create, so the app must NOT blindly re-run a
    /// whole NZB download once per saved server. Exact normalized identities are deduped both within the
    /// saved array and against the add-on servers, so no provider is ever contacted twice for one article.
    static func localAttempts(addonServers: [String], savedServers: [String],
                              excluding: Set<DebridUsenetRoute> = []) -> [LocalAttempt] {
        var attempts: [LocalAttempt] = []
        if !addonServers.isEmpty, !excluding.contains(.addonNNTP) {
            attempts.append(LocalAttempt(route: .addonNNTP, servers: addonServers))
        }
        if !excluding.contains(.savedNNTP) {
            var seen = Set(addonServers.map(normalizedServerIdentity))
            var ordered: [String] = []
            for saved in savedServers where !saved.isEmpty {
                let identity = normalizedServerIdentity(saved)
                guard !seen.contains(identity) else { continue }
                seen.insert(identity)
                ordered.append(saved)
            }
            if !ordered.isEmpty {
                attempts.append(LocalAttempt(route: .savedNNTP, servers: ordered))
            }
        }
        return attempts
    }

    /// Legacy single saved-server entry point, preserved for existing callers and tests.
    static func localAttempts(addonServers: [String], savedServer: String?,
                              excluding: Set<DebridUsenetRoute> = []) -> [LocalAttempt] {
        localAttempts(addonServers: addonServers, savedServers: savedServer.map { [$0] } ?? [],
                      excluding: excluding)
    }

    /// Testable sequential transport seam. A cancelled task is never converted into the next provider
    /// attempt; every other create failure is allowed to advance exactly one route.
    static func firstSuccessful<T: Sendable>(_ attempts: [LocalAttempt],
                                             create: @escaping @Sendable (LocalAttempt) async throws -> T) async throws -> (DebridUsenetRoute, T)? {
        for attempt in attempts {
            try Task.checkCancellation()
            do {
                let value = try await create(attempt)
                try Task.checkCancellation()
                return (attempt.route, value)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }
        return nil
    }

    /// Exact normalized server identity (scheme, host, port, user, password — case-insensitive scheme and
    /// host, exactly like the previous `equivalentServer`). Unparseable strings fall back to their raw
    /// value so two identical malformed hints still dedupe.
    static func normalizedServerIdentity(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        let fields = [components.scheme?.lowercased() ?? "",
                components.host?.lowercased() ?? "",
                components.port.map(String.init) ?? "",
                components.user ?? "",
                components.password ?? ""]
        // Length-prefix every decoded field: credentials containing `|` can never collide.
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}
