import Foundation

enum FMP4Fixtures {
    struct Fixture {
        let initSegment: Data
        let firstFragment: Data
    }

    static func load(_ name: String) -> Fixture? {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = directory.appendingPathComponent("fixtures/\(name).mp4.b64")
        guard let encoded = try? String(contentsOf: url, encoding: .utf8),
              let whole = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let parts = FMP4.splitInitAndFirstFragment(whole) else { return nil }
        return Fixture(initSegment: parts.initSegment, firstFragment: parts.fragment)
    }
}
