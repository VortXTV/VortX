// Direct executable coverage for native-debrid URL acceptance and redirect guards.
//
// Run:
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/DebridPublicURLPolicy.swift app/Tests/DebridPublicURLPolicyTests.swift \
//     -o /tmp/debrid-public-url-policy && /tmp/debrid-public-url-policy

import Foundation

@main
struct DebridPublicURLPolicyTests {
    static func main() {
        var failures: [String] = []
        var checks = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        func permits(_ value: String, addresses: [String]) -> Bool {
            DebridPublicURLPolicy.permits(URL(string: value)!, resolvingAddresses: { _ in addresses })
        }

        expect(permits("https://cdn.example.test/video.mkv", addresses: ["8.8.8.8"]),
               "public HTTPS CDN link is accepted")
        expect(permits("http://cdn.example.test/video.mkv", addresses: ["2001:4860:4860::8888"]),
               "public IPv6 HTTP CDN link is accepted")
        expect(!permits("file:///etc/passwd", addresses: []), "file scheme is rejected")
        expect(!permits("ftp://cdn.example.test/video.mkv", addresses: ["8.8.8.8"]), "non-HTTP scheme is rejected")
        expect(!permits("https://token@cdn.example.test/video.mkv", addresses: ["8.8.8.8"]), "userinfo is rejected")
        expect(!permits("https://127.0.0.1/video.mkv", addresses: []), "IPv4 loopback is rejected")
        expect(!permits("https://[::1]/video.mkv", addresses: []), "IPv6 loopback is rejected")
        expect(!permits("https://10.0.0.7/video.mkv", addresses: []), "RFC1918 IPv4 is rejected")
        expect(!permits("https://[fd00::7]/video.mkv", addresses: []), "unique-local IPv6 is rejected")
        expect(!permits("https://[fe80::7]/video.mkv", addresses: []), "link-local IPv6 is rejected")
        expect(!permits("https://cdn.example.test/video.mkv", addresses: ["8.8.8.8", "169.254.10.1"]),
               "mixed public and link-local DNS answers fail closed")
        expect(!permits("https://cdn.example.test/video.mkv", addresses: ["224.0.0.1"]),
               "multicast DNS answer is rejected")
        expect(!permits("https://cdn.example.test/video.mkv", addresses: []), "unresolved host is rejected")

        let publicRedirect = URLRequest(url: URL(string: "https://redirect.example.test/path")!)
        let privateRedirect = URLRequest(url: URL(string: "https://127.0.0.1/path")!)
        expect(DebridPublicURLPolicy.permittedRedirectRequest(publicRedirect, resolvingAddresses: { _ in ["8.8.8.8"] }) != nil,
               "redirect to a public CDN address is permitted")
        expect(DebridPublicURLPolicy.permittedRedirectRequest(privateRedirect) == nil,
               "redirect to loopback is cancelled before follow")

        if failures.isEmpty {
            print("PASS: \(checks) debrid public URL policy checks")
        } else {
            failures.forEach { fputs("FAIL: \($0)\\n", stderr) }
            exit(1)
        }
    }
}
