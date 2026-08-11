// Static source contract for the hardened Apple OAuth broker and its durable-auth composition.
//
// RUN:
//   swiftc -D TRAKT_OAUTH_BROKER_CONTRACT_ONLY -parse-as-library \
//     app/SourcesShared/TraktModels.swift \
//     app/Tests/TraktOAuthBrokerContractTests.swift \
//     -o /tmp/trakt-oauth-broker-contract-tests && \
//   /tmp/trakt-oauth-broker-contract-tests
//
// Production auth/model typecheck without the unrelated app graph:
//   swiftc -swift-version 5 -D TRAKT_OAUTH_SOURCE_TYPECHECK -parse-as-library -typecheck \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/TraktScrobbleProgressPolicy.swift \
//     app/SourcesShared/VortXEdgeAuth.swift \
//     app/SourcesShared/TraktModels.swift \
//     app/SourcesShared/TraktAuth.swift \
//     app/Tests/TraktOAuthBrokerContractTests.swift
//
// The executable Trakt session suite owns network-fixture and credential-transaction behavior. This
// companion contract keeps the production source boundary load-bearing: no direct OAuth fallback,
// client-secret seam, redirect, cookie, cache, unbounded-body, or unsigned-broker regression may land.

import Foundation

#if TRAKT_OAUTH_BROKER_CONTRACT_ONLY || TRAKT_OAUTH_SOURCE_TYPECHECK
// TraktModels normally receives these shared date formatters from CoreModels. Keep this standalone
// contract focused on the OAuth response model instead of pulling CoreModels' unrelated graph.
extension ISO8601DateFormatter {
    static let epg = ISO8601DateFormatter()
    static let epgFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
#endif

#if TRAKT_OAUTH_SOURCE_TYPECHECK
/// Narrow production-source seams for a real TraktModels + TraktAuth typecheck. Runtime behavior remains
/// covered by TraktSessionSecurityTests; these stubs deliberately do not emulate persistence or logging.
enum Keychain {
    static func string(_ account: String) -> String? { nil }
    @discardableResult
    static func set(_ value: String?, for account: String) -> CredentialMutationResult { .success }
    static func durableString(_ account: String) -> CredentialDurableReadResult { .missing }
    static func confirmedString(_ account: String) -> CredentialDurableReadResult { .missing }
}

enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) {}
}
#endif

@main
private enum TraktOAuthBrokerContractTests {
    static func main() {
        var failures = 0

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                print("PASS  \(message)")
            } else {
                failures += 1
                print("FAIL  \(message)")
            }
        }

        let app = appRoot()
        let repository = app.deletingLastPathComponent()
        let configurationSources = [
            read(repository, "app/Config/ExternalSync.xcconfig.example"),
            read(app, "Resources/Info-iOS.plist"),
            read(app, "Resources/Info-macOS.plist"),
            read(app, "ResourcesTV/Info-tvOS.plist"),
            read(app, "project.yml"),
        ]
        let models = read(app, "SourcesShared/TraktModels.swift")
        let settings = read(app, "SourcesShared/ExternalServicesSettingsView.swift")
        let service = read(app, "SourcesShared/TraktService.swift")
        let auth = read(app, "SourcesShared/TraktAuth.swift")
        let simkl = read(app, "SourcesShared/SIMKLAuth.swift")
        let edge = read(app, "SourcesShared/VortXEdgeAuth.swift")

        check(!containsClientSecret(configurationSources + [auth, simkl]),
              "Apple config, Trakt, and SIMKL sources contain no OAuth client-secret plumbing")
        check(models.contains("let session: String")
                && models.contains("case session")
                && !models.contains("let deviceCode")
                && !models.contains("case deviceCode"),
              "device-start response exposes an opaque broker session, not Trakt device code")
        check(settings.contains("pollForToken(session: dc.session")
                && !settings.contains("pollForToken(deviceCode:")
                && settings.contains("revokeAndSignOut"),
              "Trakt settings use broker-session polling and broker revoke")
        check(service.contains("session: code.session")
                && !service.contains("deviceCode: code.deviceCode")
                && service.contains("revokeAndSignOut")
                && service.contains("public client ID"),
              "service integration guidance describes the broker session contract")
        check(auth.contains("static let brokerBase = \"https://oauth.vortx.tv\"")
                && auth.contains("brokerSourceID = \"vortx-oauth-v2\"")
                && auth.contains("/v1/oauth/trakt/device/start")
                && auth.contains("/v1/oauth/trakt/device/poll")
                && auth.contains("/v1/oauth/trakt/refresh")
                && auth.contains("/v1/oauth/trakt/revoke"),
              "Trakt OAuth uses only the fixed four-route VortX broker")
        check(!auth.contains("/oauth/device/code")
                && !auth.contains("/oauth/device/token")
                && !auth.contains("/oauth/token"),
              "Trakt OAuth never falls back to direct provider endpoints")
        check(auth.contains("signOAuthV2")
                && auth.contains("VortXEdgeAuth.canSignOAuthV2")
                && edge.contains("signOAuthV2")
                && edge.contains("oauthBodyDigestHeader")
                && edge.contains("oauthNonceHeader"),
              "broker requests require the body-bound OAuth v2 signer")
        check(auth.contains("httpShouldSetCookies = false")
                && auth.contains("httpCookieAcceptPolicy = .never")
                && auth.contains("httpCookieStorage = nil")
                && auth.contains("urlCredentialStorage = nil")
                && auth.contains("urlCache = nil")
                && auth.contains("httpShouldHandleCookies = false"),
              "broker transport disables cookies, credentials, and shared cache state")
        check(auth.contains("TraktOAuthNoRedirectDelegate")
                && auth.contains("completionHandler(nil)"),
              "broker transport rejects redirects instead of forwarding a signed POST")
        check(auth.contains("16 * 1024")
                && auth.contains("64 * 1024")
                && auth.contains("Content-Length")
                && auth.contains("session.bytes(for: request)"),
              "broker request and streaming response bodies are bounded")
        check(auth.contains("pollForToken(session:")
                && auth.contains("revokeAndSignOut")
                && auth.contains("BrokerPollResponse")
                && auth.contains("BrokerRefreshResponse"),
              "Trakt auth exposes only the reviewed opaque-session broker API")
        check(auth.contains("CredentialScopeRegistry.shared.isCurrent(capture)")
                && auth.contains("loginAttempts.owns(code: session")
                && auth.contains("currentSessionID(ownerNamespace: capture.namespace) == expectedSession")
                && auth.contains("storeRefreshedToken(token, ownerCapture: capture)"),
              "broker awaits retain owner, login-generation, session, and durable refresh fences")
        check(simkl.contains("static let clientID")
                && simkl.contains("requestPin")
                && !containsClientSecret([simkl]),
              "SIMKL PIN auth remains public-client-ID-only")
        check(!logsCredentialValues(auth),
              "Trakt diagnostics never interpolate OAuth credential values")
        check(brokerViolations(auth) == 0
                && brokerViolations(auth.replacingOccurrences(
                    of: "makeBrokerRequest",
                    with: "makeRequest"
                )) > 0
                && brokerViolations(auth.replacingOccurrences(
                    of: "signOAuthV2",
                    with: "sign"
                )) > 0,
              "direct-request and legacy-signer mutations turn the Apple broker contract red")

        do {
            let payload = Data("""
            {
              "session": "broker-session",
              "user_code": "ABCD-EFGH",
              "verification_url": "https://trakt.tv/activate",
              "expires_in": 600,
              "interval": 5
            }
            """.utf8)
            let deviceStart = try JSONDecoder().decode(TraktDeviceCode.self, from: payload)
            check(deviceStart.session == "broker-session"
                    && deviceStart.userCode == "ABCD-EFGH"
                    && deviceStart.expiresIn == 600
                    && deviceStart.interval == 5,
                  "broker device-start response decodes its opaque session")

            let encoded = try JSONEncoder().encode(deviceStart)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            check(object?["session"] as? String == "broker-session"
                    && object?["device_code"] == nil,
                  "broker device-start response never serializes Trakt device code")
        } catch {
            check(false, "broker device-start response is Codable: \(error)")
        }

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }

    private static func appRoot() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("SourcesShared").path) {
            return cwd
        }
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("app/SourcesShared").path) {
            return cwd.appendingPathComponent("app")
        }
        fatalError("Run from the repository root or app directory")
    }

    private static func containsClientSecret(_ values: [String]) -> Bool {
        let forbidden = [
            "TRAKT_CLIENT_SECRET", "SIMKL_CLIENT_SECRET", "TraktClientSecret", "SIMKLClientSecret",
            "client_secret", "clientSecret",
        ]
        return values.contains { value in forbidden.contains(where: value.contains) }
    }

    private static func logsCredentialValues(_ source: String) -> Bool {
        let forbidden = ["accessToken", "refreshToken", "access_token", "refresh_token"]
        return source.split(separator: "\n").contains { line in
            line.contains("DiagnosticsLog.log") && forbidden.contains(where: line.contains)
        }
    }

    private static func brokerViolations(_ source: String) -> Int {
        var count = 0
        if source.contains("/oauth/device/code")
            || source.contains("/oauth/device/token")
            || source.contains("/oauth/token") {
            count += 1
        }
        if !source.contains("makeBrokerRequest") || !source.contains("signOAuthV2") {
            count += 1
        }
        if !source.contains("TraktOAuthNoRedirectDelegate")
            || !source.contains("64 * 1024") {
            count += 1
        }
        return count
    }

    private static func read(_ root: URL, _ relativePath: String) -> String {
        let url = root.appendingPathComponent(relativePath)
        guard let value = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Could not read \(url.path)")
        }
        return value
    }
}
