import Foundation

// The production pairing protocol owns this URL-size limit; this harness links no app or account runtime.
enum AddonPairingProtocol { static let maxManifestURLBytes = 2048 }

@main
enum AddonSelfHostedTests {
    static func main() async {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
        }
        // Literal endpoints only: these checks do not make DNS or HTTP requests.
        for host in ["192.168.50.20", "10.20.30.40", "172.16.1.2", "100.64.0.1", "100.127.255.254",
                     "127.0.0.1", "[::1]", "[fd7a:115c:a1e0::1]", "[::ffff:192.168.1.5]",
                     "[64:ff9b::c0a8:105]"] {
            let url = URL(string: "https://\(host):8443/addon/manifest.json")!
            let selected = AddonURLGuard.AccessScope.addon(origin: url)
            let allowed = await AddonURLGuard.validate(url, access: selected)
            let publicOnly = await AddonURLGuard.validate(url)
            check(allowed == nil, "selected private add-on passes: \(host)")
            check(publicOnly != nil, "public catalog/artwork stays public-only: \(host)")
            let otherPort = URL(string: "https://\(host):9443/manifest.json")!
            let rejected = await AddonURLGuard.validate(otherPort, access: selected)
            check(rejected != nil, "a redirect cannot grant private access on another port")
        }
        for host in ["0.0.0.0", "169.254.169.254", "100.100.100.200", "[::]", "[fe80::1]",
                     "[fd00:ec2::254]", "[::ffff:100.100.100.200]"] {
            let url = URL(string: "http://\(host)/manifest.json")!
            let rejection = await AddonURLGuard.validate(url, access: .addon(origin: url))
            check(rejection != nil, "special/metadata destination is not an add-on endpoint: \(host)")
        }
        let origin = URL(string: "https://private.example:443/addon/manifest.json")!
        let scope = AddonURLGuard.AccessScope.addon(origin: origin)
        check(scope.allowsPrivateAddress(for: URL(string: "https://PRIVATE.example/catalog/movie/a.json")!),
              "same-origin resources and default HTTPS port agree")
        check(!scope.allowsPrivateAddress(for: URL(string: "https://other.example/manifest.json")!),
              "different origin does not inherit private access")
        check(!scope.allowsPrivateAddress(for: URL(string: "http://private.example/manifest.json")!),
              "HTTPS downgrade does not inherit private access")
        let credentialURL = URL(string: "https://user:secret@192.168.1.5/manifest.json")!
        let credentialFailure = await AddonURLGuard.validate(credentialURL, access: .addon(origin: credentialURL))
        check(credentialFailure != nil, "userinfo rejection retained")
        let publicURL = URL(string: "https://8.8.8.8/manifest.json")!
        let publicResult = await AddonURLGuard.validate(publicURL)
        check(publicResult == nil, "normal public validation unchanged")
        print("PASS self-hosted add-on policy: \(checks) checks; no network requests")
    }
}
