// Run from repository root:
// swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors -o /tmp/usenet-routing-policy \
//   app/SourcesShared/UsenetRoutingPolicy.swift app/Tests/UsenetRoutingPolicyTests.swift && /tmp/usenet-routing-policy

import Foundation

private actor AttemptRecorder {
    private(set) var routes: [DebridUsenetRoute] = []
    func record(_ route: DebridUsenetRoute) { routes.append(route) }
}

@main
private enum UsenetRoutingPolicyTests {
    static func main() async throws {
        let addon = ["nntps://addon-a.example:563/4", "nntps://addon-b.example:563/4"]
        let saved = "nntps://saved.example:563/8"
        let initial = UsenetRoutingPolicy.localAttempts(addonServers: addon, savedServer: saved)
        try check(initial.map(\.route) == [.addonNNTP, .savedNNTP], "addon precedes saved provider")
        try check(initial.first?.servers == addon, "addon server order remains intact in one create attempt")

        let afterAddon = UsenetRoutingPolicy.localAttempts(addonServers: addon, savedServer: saved,
                                                            excluding: [.addonNNTP])
        try check(afterAddon.map(\.route) == [.savedNNTP], "addon failure advances sequentially to saved")

        let duplicate = UsenetRoutingPolicy.localAttempts(addonServers: [saved], savedServer: saved)
        try check(duplicate.map(\.route) == [.addonNNTP], "equivalent saved provider is not pooled or retried")

        let afterSaved = UsenetRoutingPolicy.localAttempts(addonServers: addon, savedServer: saved,
                                                            excluding: [.addonNNTP, .savedNNTP])
        try check(afterSaved.isEmpty, "saved-route recovery cannot restart known-failed addon")

        let recorder = AttemptRecorder()
        let resolved = try await UsenetRoutingPolicy.firstSuccessful(initial) { attempt in
            await recorder.record(attempt.route)
            if attempt.route == .addonNNTP { throw URLError(.cannotConnectToHost) }
            return "loopback-stream"
        }
        try check(resolved?.0 == .savedNNTP, "injected addon create failure retries saved provider")
        let routes = await recorder.routes
        try check(routes == [.addonNNTP, .savedNNTP], "injected transport stays sequential")

        let cancelled = Task {
            try await UsenetRoutingPolicy.firstSuccessful(initial) { attempt in
                if attempt.route == .addonNNTP { throw CancellationError() }
                return "must-not-run"
            }
        }
        do {
            _ = try await cancelled.value
            throw NSError(domain: "UsenetRoutingPolicy", code: 2)
        } catch is CancellationError {
            // expected: the saved provider was never invoked
        }
        print("PASS  bounded sequential Usenet routing policy")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "UsenetRoutingPolicy", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
