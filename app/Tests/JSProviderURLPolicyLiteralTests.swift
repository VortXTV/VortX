// Standalone regressions compiled only with the actual JSProviderURLPolicy.swift.
// No DNS, HTTP, TLS connection, runtime/provider, installed app or live account is invoked.
import Foundation
import Darwin

@main
@MainActor
private enum JSProviderURLPolicyLiteralTests {
    private static var checks = 0
    private static var failures = 0

    static func main() {
        let policy = JSProviderURLPolicy.default
        // These are ordinary syntactic DNS names, NOT proof that any address resolves publicly.
        // The old predicate incorrectly rejects all of the first seven hostnames.
        let dnsNames = [
            "fcastle.example.invalid", "fdstream.example.invalid", "fe8cdn.example.invalid",
            "fe9cdn.example.invalid", "feature.example.invalid", "february.example.invalid",
            "FCASTLE.EXAMPLE.INVALID", "catalog.example.invalid", "127.example.invalid",
            "fc192.168.example.invalid",
        ]
        for host in dnsNames {
            expect(allowed(policy, "https://\(host)/manifest.json"), "DNS name is not an IPv6 prefix: \(host)")
            expect(!JSProviderURLPolicy.isPublicNumericAddress(host), "A DNS name is never a vetted numeric peer: \(host)")
        }

        let privateIPv6 = [
            "::", "::1", "fc00::1", "FC00::1", "fd12:3456::1", "FDAB::1234",
            "fe80::1", "FE80::1", "fe90::1", "fea0::1", "febf::1",
        ]
        for address in privateIPv6 {
            expect(!allowed(policy, "https://[\(address)]/resource"), "Private IPv6 literal remains rejected: \(address)")
            expect(!JSProviderURLPolicy.isPublicNumericAddress(address), "Unbracketed private IPv6 is not public: \(address)")
            expect(!JSProviderURLPolicy.isPublicNumericAddress("[\(address)]"), "Bracketed private IPv6 is not public: \(address)")
        }
        let privateIPv4 = [
            "127.0.0.1", "10.1.2.3", "169.254.1.2", "172.16.0.1", "172.31.255.255",
            "192.168.1.1", "100.64.0.1", "100.127.255.255", "0.0.0.0", "224.0.0.1",
        ]
        for address in privateIPv4 {
            expect(!allowed(policy, "https://\(address)/resource"), "Private IPv4 literal remains rejected: \(address)")
            expect(!JSProviderURLPolicy.isPublicNumericAddress(address), "Private IPv4 is not a public peer: \(address)")
        }
        // The early URL syntax policy has never been the mapped-IP resolver guard. Preserve and
        // exercise the actual numeric-peer guard instead of falsely claiming a new early denial.
        for address in ["::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:192.168.1.1",
                        "::ffff:169.254.1.1", "::ffff:7f00:1", "[::FFFF:127.0.0.1]"] {
            expect(!JSProviderURLPolicy.isPublicNumericAddress(address), "Mapped private address remains rejected: \(address)")
        }
        for address in ["8.8.8.8", "2001:4860:4860::8888", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            expect(JSProviderURLPolicy.isPublicNumericAddress(address), "Existing public numeric address remains accepted: \(address)")
        }
        expect(allowed(policy, "https://[2001:4860:4860::8888]/resource"), "Public IPv6 syntax remains accepted")
        for text in ["http://localhost/private", "https://nested.localhost/private", "https://server.local/private",
                     "file:///etc/hosts", "ftp://fcastle.example.invalid/resource"] {
            expect(!allowed(policy, text), "Other existing URL denials remain: \(text)")
        }
        let denied = JSProviderURLPolicy(deniedHosts: ["FCASTLE.EXAMPLE.INVALID"])
        expect(!allowed(denied, "https://fcastle.example.invalid/manifest.json"), "An explicit hostname denial still wins")
        let compatibilityFlagOff = JSProviderURLPolicy(validationEnabled: false)
        expect(!allowed(compatibilityFlagOff, "https://[fc00::1]/resource"), "Compatibility flag does not disable native URL protection")
        expect(!JSProviderURLPolicy.isPublicNumericAddress("not-an-address"), "Malformed numeric peer remains rejected")

        print("JSProviderURLPolicy literal checks: \(checks), failures: \(failures)")
        if failures != 0 { exit(EXIT_FAILURE) }
    }

    private static func allowed(_ policy: JSProviderURLPolicy, _ text: String) -> Bool {
        guard let url = URL(string: text) else {
            expect(false, "Invalid URL test fixture: \(text)")
            return false
        }
        return policy.isAllowed(url)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
}
