import Foundation

/// The origin of a resolved NZB playback URL.  It is deliberately provenance only: no NZB URL, NNTP host,
/// or credential crosses this boundary into the player or persisted play state.
enum DebridUsenetRoute: String, CaseIterable, Sendable, Equatable {
    case addonNNTP
    case savedNNTP
    case torBoxCloud
}

/// Keeps account use serial and explicit.  Add-on servers are attempted as one ordered request (the Node
/// engine owns the server ordering); a saved account is only a second request after that request fails.
enum UsenetRoutingPolicy {
    struct LocalAttempt: Sendable, Equatable {
        let route: DebridUsenetRoute
        let servers: [String]
    }

    static func localAttempts(addonServers: [String], savedServer: String?,
                              excluding: Set<DebridUsenetRoute> = []) -> [LocalAttempt] {
        var attempts: [LocalAttempt] = []
        if !addonServers.isEmpty, !excluding.contains(.addonNNTP) {
            attempts.append(LocalAttempt(route: .addonNNTP, servers: addonServers))
        }
        if let savedServer, !savedServer.isEmpty, !excluding.contains(.savedNNTP),
           !addonServers.contains(where: { equivalentServer($0, savedServer) }) {
            attempts.append(LocalAttempt(route: .savedNNTP, servers: [savedServer]))
        }
        return attempts
    }

    static func remaining(after route: DebridUsenetRoute?) -> [DebridUsenetRoute] {
        DebridUsenetRoute.allCases.filter { $0 != route }
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

    private static func equivalentServer(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = URLComponents(string: lhs), let b = URLComponents(string: rhs) else {
            return lhs == rhs
        }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port && a.user == b.user && a.password == b.password
            && a.path == b.path
    }
}
