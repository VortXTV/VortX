// Regression contract for issue #220: plex.tv/link is the short-code entry surface, so the PIN request
// must not opt into Plex's long `strong` code form. Run:
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/Tests/PlexPINLinkContractTests.swift -o /tmp/plex-pin-link-contract && /tmp/plex-pin-link-contract
//   xcrun swiftc -D PLEX_PIN_SOURCE_TYPECHECK -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/MediaServerAuth.swift app/Tests/PlexPINLinkContractTests.swift \
//     -o /tmp/plex-pin-link-source-typecheck && /tmp/plex-pin-link-source-typecheck

import Foundation

#if PLEX_PIN_SOURCE_TYPECHECK
enum MediaServerStore {
    static let deviceId = "test-device"
    static let plexClientIdentifier = "test-plex-client"
}

enum MediaServerResolve {
    static func normalizedBase(_ value: String) -> String? { value }
}
#endif

@main
struct PlexPINLinkContractTests {
    static func main() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SourcesShared/MediaServerAuth.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else {
                fputs("FAIL \(name)\n", stderr)
                exit(1)
            }
            print("PASS \(name)")
        }

        expect(source.contains("var linkURL: String { \"https://plex.tv/link\" }"),
               "Plex PIN presents the plex.tv/link entry surface")
        expect(source.contains("URLQueryItem(name: \"strong\", value: \"false\")"),
               "plex.tv/link PIN request explicitly uses the compatible short-code form")
        expect(source.contains("static func plexPollForToken(pin: PlexPin"),
               "changing the PIN shape leaves token polling intact")
        expect(source.contains("static func jellyfinQuickConnectEnabled")
               && source.contains("static func embyAuthByPassword"),
               "changing the Plex PIN leaves Jellyfin and Emby flows intact")
    }
}
