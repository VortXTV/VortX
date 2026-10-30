import Foundation

/// SOURCE PROPOSAL ONLY. No @main; a future reviewed host test must call run with genuine source text.
/// Existing 52 transport cases, 64 document cases, collectors and every existing test remain unchanged.
enum XperienceTransportIdentityRegression {
    private static func candidate(_ transport: String) throws -> XperienceAddonBinding.Candidate {
        try .init(manifestID: "fixture.addon", transport: transport,
                  catalogs: [.init(type: "movie", id: "popular", acceptsGenre: true,
                                   requiresGenre: false, supportsSkip: true)])
    }
    static func run(bindingSource: String, catalogClientSource: String) throws {
        let accepted = [
            ("HTTPS://CATALOG.EXAMPLE.INVALID:0443/manifest.json?x=a%2Fb&x=two+words&", "https://catalog.example.invalid:443/manifest.json?x=a%2Fb&x=two+words&"),
            ("https://catalog.example.invalid:/manifest.json?", "https://catalog.example.invalid/manifest.json?"),
            ("https://caf\u{00e9}.example.invalid/caf\u{00e9}/manifest.json?q=cafe\u{0301}", "https://caf\u{00e9}.example.invalid/caf%C3%A9/manifest.json?q=cafe%CC%81"),
            ("https://\u{65e5}\u{672c}.example.invalid/\u{1f600}/manifest.json?x=%2f&x=%2F", "https://\u{65e5}\u{672c}.example.invalid/%F0%9F%98%80/manifest.json?x=%2f&x=%2F"),
            ("https://%63ATALOG.example.invalid/config%2fone/manifest.json?x=%aF", "https://%63atalog.example.invalid/config%2fone/manifest.json?x=%aF"),
            ("http://10.23.45.67:8080/manifest.json", "http://10.23.45.67:8080/manifest.json"),
            ("https://100.101.102.103/manifest.json", "https://100.101.102.103/manifest.json"),
            ("https://[2001:0DB8:0000:0000:0000:0000:0000:0001]:0443/manifest.json", "https://[2001:0db8:0000:0000:0000:0000:0000:0001]:443/manifest.json"),
            ("https://[FE80::1%25FixtureZone]/manifest.json", "https://[fe80::1%25FixtureZone]/manifest.json"),
            ("https://[::ffff:192.0.2.1]/manifest.json", "https://[::ffff:192.0.2.1]/manifest.json"),
            ("https://[::]/manifest.json", "https://[::]/manifest.json"),
            ("https://[::1]/manifest.json", "https://[::1]/manifest.json"),
            ("https://[1::]/manifest.json", "https://[1::]/manifest.json"),
            ("https://[::192.0.2.1]/manifest.json", "https://[::192.0.2.1]/manifest.json"),
            ("https://[1:2:3:4:5:6:192.0.2.1]/manifest.json", "https://[1:2:3:4:5:6:192.0.2.1]/manifest.json")
        ]
        for (raw, expected) in accepted {
            let value = try candidate(raw)
            precondition(value.canonicalTransport.utf8.elementsEqual(expected.utf8), "Portable identity bytes differ")
            precondition(value.transportDigest == XperienceCollections.digestBytes(Data(expected.utf8)), "Candidate fingerprint differs")
        }
        // Small source proposals: valid configurations cross former fixture-derived production caps.
        for count in [5000, 20000] {
            let raw = "https://catalog.example.invalid/manifest.json?token=" + String(repeating: "a", count: count)
            let value = try candidate(raw)
            precondition(value.canonicalTransport.utf8.elementsEqual(raw.utf8), "Valid long identity rejected or changed")
            precondition(value.transportDigest == XperienceCollections.digestBytes(Data(raw.utf8)))
        }
        let unicodeRaw = "https://catalog.example.invalid/manifest.json?token=" + String(repeating: "\u{00e9}", count: 6000)
        let unicodeExpected = "https://catalog.example.invalid/manifest.json?token=" + String(repeating: "%C3%A9", count: 6000)
        let expanded = try candidate(unicodeRaw)
        precondition(expanded.canonicalTransport.utf8.elementsEqual(unicodeExpected.utf8), "Long UTF8 expansion differs")
        let maximumSourceCount = Int(Int32.max) / 3
        let largestCapacity = try XperienceAddonBinding.transportIdentityCapacity(utf8Count: maximumSourceCount)
        precondition(largestCapacity == maximumSourceCount * 3)
        for count in [-1, maximumSourceCount + 1, Int(Int32.max)] {
            do {
                _ = try XperienceAddonBinding.transportIdentityCapacity(utf8Count: count)
                preconditionFailure("Unrepresentable identity capacity admitted")
            } catch let failure as XperienceAddonBinding.Failure { precondition(failure == .invalidRegistry) }
        }
        let distinct = [
            ("https://caf\u{00e9}.example.invalid/manifest.json", "https://xn--caf-dma.example.invalid/manifest.json"),
            ("https://caf\u{00e9}.example.invalid/manifest.json", "https://cafe\u{0301}.example.invalid/manifest.json"),
            ("https://%63atalog.example.invalid/manifest.json", "https://catalog.example.invalid/manifest.json"),
            ("https://catalog.example.invalid/manifest.json", "https://catalog.example.invalid:443/manifest.json"),
            ("https://catalog.example.invalid/manifest.json", "https://catalog.example.invalid/manifest.json?"),
            ("https://catalog.example.invalid/a%2fb/manifest.json", "https://catalog.example.invalid/a%2Fb/manifest.json"),
            ("https://[fe80::1%25FixtureZone]/manifest.json", "https://[fe80::1%25fixturezone]/manifest.json")
        ]
        for (left, right) in distinct {
            let lhs = try candidate(left); let rhs = try candidate(right)
            precondition(lhs.transportDigest != rhs.transportDigest, "Distinct configured identities collapsed")
        }
        for raw in [
            "https://user@catalog.example.invalid/manifest.json", "https://catalog.example.invalid/manifest.json#",
            "https://catalog.example.invalid:0/manifest.json", "https://catalog.example.invalid:65536/manifest.json",
            "https://catalog.example.invalid:999999999999999999999999/manifest.json",
            "https://catalog.example.invalid/a b/manifest.json", "https://catalog.example.invalid/a\tb/manifest.json",
            "https://catalog.example.invalid/a\u{0085}b/manifest.json", "https://catalog.example.invalid/a%GG/manifest.json",
            "https://catalog.example.invalid/a%/manifest.json", "https://catalog.example.invalid/manifest.json?x=%GG",
            "https://[2001:db8::1/manifest.json", "https://[1::2::3]/manifest.json", "https://[192.0.2.1::]/manifest.json",
            "https://[:1::2]/manifest.json", "https://[1::2:]/manifest.json",
            "https://[fe80::1%FixtureZone]/manifest.json", "https://[fe80::1%25]/manifest.json"
        ] {
            do { _ = try candidate(raw); preconditionFailure("Invalid configured transport admitted") }
            catch let failure as XperienceAddonBinding.Failure { precondition(failure == .invalidRegistry) }
        }

        let sourceDocument = try XperienceCollections.parse(Data(#"[{"id":"c","title":"C","folders":[{"id":"f","title":"F","sources":[{"provider":"addon","addonId":"fixture.addon","type":"movie","catalogId":"popular","genre":"Drama"}]}]}]"#.utf8))
        let source = sourceDocument.collections[0].folders[0].sources[0]
        let configured = try candidate("HTTPS://CAF\u{00e9}.example.invalid:0443/config%2fkeep/manifest.json?x=a%2Fb&x=%aF")
        let request = try XperienceAddonBinding.catalogURL(source: source, candidate: configured, skip: 20)
        let parts = URLComponents(url: request, resolvingAgainstBaseURL: false)
        precondition(parts?.percentEncodedPath == "/config%2fkeep/catalog/movie/popular/genre=Drama&skip=20.json", "Original configured route changed")
        precondition(parts?.percentEncodedQuery == "x=a%2Fb&x=%aF", "Original configured query changed")
        let current = try candidate("https://caf\u{00e9}.example.invalid/manifest.json")
        let old = XperienceAddonBinding.Mapping(manifestID: "fixture.addon",
            transportDigest: "c86be5daa785a1b74d79b940b7360c10d87fade9a393b36f50629b8d06b06c71")
        precondition(XperienceAddonBinding.resolve(source, installed: [current], mapping: old) == .mappingUnavailable,
                     "Old fingerprint must require explicit rebind")
        precondition(XperienceAddonBinding.resolve(source, installed: [current], mapping: current.mapping) == .resolved(current))
        precondition(bindingSource.contains("URLComponents(string: candidate.configuredTransport)"), "Request must use original installed transport")
        precondition(!bindingSource.contains("URLComponents(string: candidate.canonicalTransport)"), "Identity must never become request authority")
        precondition(catalogClientSource.contains("AddonURLGuard.fetch(url, context: .xperienceCatalog)"), "Existing fetch guard must remain")
    }
}
