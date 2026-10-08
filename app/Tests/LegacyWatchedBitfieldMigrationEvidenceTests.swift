import Foundation
import CryptoKit

@main
enum LegacyWatchedBitfieldMigrationEvidenceTests {
    private static let profileID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11C")!
    private static let manifest = Data(#"{"id":"catalog","name":"Original catalog","version":"1.0.0"}"#.utf8)
    private static let addon = try! LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
        transportURL: "https://catalog.example/manifest.json", manifest: manifest)
    private static let bitfield = "tt2934286:1:5:5:eJyTZwAAAEAAIA=="

    static func main() async throws {
        try await capturesBoundedOriginalEvidence()
        try await rejectsWrongSourceOrMetadata()
        try await validatesStrictMetadataAndIdentityGuards()
        try await validatesLegacyRootSource()
        try await rejectsRevokedAdmission()
        try await validatesOwnSourceIdentity()
    }

    private static func capturesBoundedOriginalEvidence() async throws {
        let source = sharedSource()
        let metadata = metadata()
        let scope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: profileID)
        let requests = Locked<Int>(0)
        let evidence = try await LegacyWatchedBitfieldMigrationEvidence.capture(
            scope: scope, source: source, rowLocator: .authenticatedOwnerLibrary(index: 0), addon: addon,
            isCurrent: { true }, fetch: { request in
                requests.modify { $0 += 1 }
                return .init(request: request, raw: metadata)
            })
        precondition(requests.value == 1)
        precondition(evidence.watchedVideoIDs == ["tt2934286:1:1", "tt2934286:1:2", "tt2934286:1:3", "tt2934286:1:4", "tt2934286:1:5"])
        precondition(evidence.source == source && evidence.metadata == metadata)
        precondition(evidence.sourceSHA256 == digest(source) && evidence.metadataSHA256 == digest(metadata))
        precondition(evidence.rowLocator.pointer == "/vortx/library/0")
        precondition(evidence.inventory.map(\.id) == (1...5).map { "tt2934286:1:\($0)" })
        let expectedReleased: [Int64?] = [1_104_537_600_000, 1_104_624_000_123, 1_104_710_400_000, 1_104_796_800_000, 1_104_883_200_000]
        precondition(evidence.inventory.map(\.releasedMs) == expectedReleased)
    }

    private static func rejectsWrongSourceOrMetadata() async throws {
        let scope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: profileID)
        let invalidDescriptor = Data(#"{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[]}}"#.utf8)
        await expectFailure {
            _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: invalidDescriptor,
                rowLocator: .authenticatedOwnerLibrary(index: 0), addon: addon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })
        }
        let numericAddon = try! LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
            transportURL: "https://catalog.example/manifest.json", manifest: Data(#"{"id":"catalog","name":"Original catalog","rank":1}"#.utf8))
        let numericSource = Data(#"{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","rank":1.0000000000000001}}]}}"#.utf8)
        await expectFailure {
            _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: numericSource,
                rowLocator: .authenticatedOwnerLibrary(index: 0), addon: numericAddon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })
        }
        await expectFailure {
            _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: sharedSource(),
                rowLocator: .authenticatedOwnerLibrary(index: 0), addon: addon, isCurrent: { true }, fetch: { request in
                    .init(request: request, raw: Data(#"{"meta":{"id":"other","type":"series","videos":[]}}"#.utf8))
                })
        }
        let duplicateKey = Data(#"{"vortx":{"library":[],"library":[]}}"#.utf8)
        await expectFailure {
            _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: duplicateKey,
                rowLocator: .authenticatedOwnerLibrary(index: 0), addon: addon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })
        }
    }

    /// Each invalid scalar below changes exactly one field of a complete, bitmap-addressable
    /// inventory. This proves the rejection belongs to that scalar rather than a missing anchor.
    private static func validatesStrictMetadataAndIdentityGuards() async throws {
        let scope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: profileID)
        let seasonField = #""season":1,"episode":1,"released":"2005-01-01T01:00:00+01:00""#
        await expectFailure {
            _ = try await capture(scope: scope, source: sharedSource(), raw: mutatedMetadata(seasonField, #""season":1.0000000000000001,"episode":1,"released":"2005-01-01T01:00:00+01:00""#))
        }
        await expectFailure {
            _ = try await capture(scope: scope, source: sharedSource(), raw: mutatedMetadata(#""released":"2005-01-01T01:00:00+01:00""#, #""released":"2005-01-01T00:00:00.0001Z""#))
        }
        await expectFailure {
            _ = try await capture(scope: scope, source: sharedSource(), raw: mutatedMetadata(#""released":"2005-01-01T01:00:00+01:00""#, #""released":"10000-01-01T00:00:00Z""#))
        }

        let reorderedAddon = try LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
            transportURL: "https://catalog.example/manifest.json",
            manifest: Data(#"{"version":"1.0.0","name":"Original catalog","id":"catalog"}"#.utf8))
        _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: sharedSource(),
            rowLocator: .authenticatedOwnerLibrary(index: 0), addon: reorderedAddon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })

        // Object-member order is semantically irrelevant even for a nontrivial raw descriptor;
        // this also exercises the byte-keyed linear equality path without Foundation projection.
        let extra = (0..<128).map { index in "\"extra\(index)\":\(index)" }
        let sourceManifest = ([#""id":"catalog""#, #""name":"Original catalog""#, #""version":"1.0.0""#] + extra).joined(separator: ",")
        let reorderedManifest = (extra.reversed() + [#""version":"1.0.0""#, #""name":"Original catalog""#, #""id":"catalog""#]).joined(separator: ",")
        let manyKeySource = Data(#"{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{\#(sourceManifest)}}]}}"#.utf8)
        let manyKeyAddon = try LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
            transportURL: "https://catalog.example/manifest.json", manifest: Data("{\(reorderedManifest)}".utf8))
        _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: manyKeySource,
            rowLocator: .authenticatedOwnerLibrary(index: 0), addon: manyKeyAddon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })

        let precomposedAddon = try LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
            transportURL: "https://catalog.example/manifest.json",
            manifest: Data("{\"id\":\"catalog\",\"name\":\"é\",\"version\":\"1.0.0\"}".utf8))
        let decomposedManifestSource = Data(String(decoding: sharedSource(), as: UTF8.self)
            .replacingOccurrences(of: "Original catalog", with: #"e\u0301"#).utf8)
        await expectFailure {
            _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: decomposedManifestSource,
                rowLocator: .authenticatedOwnerLibrary(index: 0), addon: precomposedAddon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })
        }

        let unicodeSource = Data(#"{"vortx":{"library":[{"id":"\u00e9","type":"series","watched":"\u00e9:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}}"#.utf8)
        let unicodeMetadata = Data(String(decoding: metadata(), as: UTF8.self)
            .replacingOccurrences(of: "tt2934286", with: #"\u00e9"#)
            .replacingOccurrences(of: #""meta":{"id":"\u00e9""#, with: #""meta":{"id":"e\u0301""#).utf8)
        await expectFailure {
            _ = try await capture(scope: scope, source: unicodeSource, raw: unicodeMetadata)
        }
    }

    private static func validatesLegacyRootSource() async throws {
        let scope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: profileID)
        let source = Data(#"{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}"#.utf8)
        let evidence = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: source,
            rowLocator: .authenticatedLegacyRootLibrary(index: 0), addon: addon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })
        precondition(evidence.rowLocator.pointer == "/library/0")
        precondition(evidence.watchedVideoIDs.count == 5)
    }

    private static func rejectsRevokedAdmission() async throws {
        let scope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: profileID)
        let current = Locked<Bool>(true)
        await expectFailure {
            _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: sharedSource(),
                rowLocator: .authenticatedOwnerLibrary(index: 0), addon: addon, isCurrent: { current.value }, fetch: { request in
                    current.modify { $0 = false }
                    return .init(request: request, raw: metadata())
                })
        }
    }

    private static func validatesOwnSourceIdentity() async throws {
        let library = Data(#"{"result":[{"_id":"tt2934286","type":"series","state":{"watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}}]}"#.utf8).base64EncodedString()
        let addons = Data(#"{"result":{"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}}"#.utf8).base64EncodedString()
        let source = Data("{\"schemaVersion\":1,\"libraryResponseBase64\":\"\(library)\",\"addonsResponseBase64\":\"\(addons)\",\"profileOverlayBase64\":\"e30=\"}".utf8)
        let withoutUID = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: profileID)
        await expectFailure {
            _ = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: withoutUID, source: source,
                rowLocator: .ownAccountLibraryResponse(index: 0), addon: addon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })
        }
        let own = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: profileID, verifiedStreamingUID: "uid-a")
        let evidence = try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: own, source: source,
            rowLocator: .ownAccountLibraryResponse(index: 0), addon: addon, isCurrent: { true }, fetch: { request in .init(request: request, raw: metadata()) })
        precondition(evidence.watchedVideoIDs.count == 5)
    }

    private static func sharedSource() -> Data {
        Data(#"{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0"}}]}}"#.utf8)
    }
    private static func metadata() -> Data {
        Data(#"{"meta":{"id":"tt2934286","type":"series","videos":[{"id":"tt2934286:1:5","season":1,"episode":5,"released":"2005-01-05T00:00:00Z"},{"id":"tt2934286:1:1","season":1,"episode":1,"released":"2005-01-01T01:00:00+01:00"},{"id":"tt2934286:1:2","season":1,"episode":2,"released":"2005-01-02T00:00:00.123Z"},{"id":"tt2934286:1:3","season":1,"episode":3,"released":"2005-01-03T00:00:00Z"},{"id":"tt2934286:1:4","season":1,"episode":4,"released":"2005-01-04T00:00:00Z"}]}}"#.utf8)
    }
    private static func mutatedMetadata(_ target: String, _ replacement: String) -> Data {
        let original = String(decoding: metadata(), as: UTF8.self)
        guard let range = original.range(of: target) else { preconditionFailure("Missing valid metadata fixture field") }
        var mutated = original; mutated.replaceSubrange(range, with: replacement)
        return Data(mutated.utf8)
    }
    private static func capture(scope: LegacyWatchedBitfieldMigrationEvidence.Scope, source: Data, raw: Data) async throws -> LegacyWatchedBitfieldMigrationEvidence.Evidence {
        try await LegacyWatchedBitfieldMigrationEvidence.capture(scope: scope, source: source,
            rowLocator: .authenticatedOwnerLibrary(index: 0), addon: addon, isCurrent: { true }, fetch: { request in .init(request: request, raw: raw) })
    }
    private static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private static func expectFailure(_ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("Expected migration evidence rejection") } catch { }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func modify(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
