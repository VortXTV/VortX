import Foundation
import XCTest

/// Authored source cases only; UNRUN. These call the actual production pure admission
/// helpers. They are not a mock native validator, transaction authority or cold-mount proof.
final class OwnerHistoryColdCoordinatorTests: XCTestCase {
    private typealias Exact = OwnerHistoryExactJSON
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let child = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private var scope: VortxAccountScope { .init(account: "cold-source-test", ownerProfileID: owner.uuidString) }
    private func target(_ uid: String = "owner-uid") -> OwnerHistorySessionCoordinator.Target {
        .init(profileID: owner, verifiedUID: uid)
    }
    private func local() throws -> Data {
        let journal = try VortxNativeOwnerHistoryJournal(scope: scope.account, ownerProfileID: owner)
        var value = try Exact.Object(Data("{}".utf8))
        value.set("kind", try Exact.string("vortx.owner-history.local/1"))
        value.set("journalBase64", try Exact.string(journal.encoded().base64EncodedString()))
        value.set("pending", Data("{}".utf8))
        return try value.encoded()
    }
    private func native() throws -> Data {
        var profile = try Exact.Object(Data(#"{"name":"Owner","owner":true,"account":{"kind":"local_only"},"future":{"negativeZero":-0,"wide":9007199254740993}}"#.utf8))
        profile.set("id", try Exact.string(owner.uuidString))
        var record = try Exact.Object(Data("{}".utf8)); record.set("profile", try profile.encoded())
        var profiles = try Exact.Object(Data("{}".utf8)); profiles.set(owner.uuidString, try record.encoded())
        var value = try Exact.Object(Data(#"{"schemaVersion":6,"ownerHistory":{"schemaVersion":1},"future":{"n":-0}}"#.utf8))
        value.set("scope", try Exact.string(scope.account))
        value.set("ownerProfileId", try Exact.string(owner.uuidString))
        value.set("profiles", try profiles.encoded())
        // Deliberately not a full replay fixture. Only coldSnapshot shape is tested here;
        // prepareColdPeer must independently reject this incomplete history.
        return try value.encoded()
    }

    func testExplicitCarrierSelectorRetainsOpaqueBytes() throws {
        let uid = "owner-e\u{301}"
        let bytes = try local()
        let carrier = try OwnerHistoryAccountExport.sourceCarrier(local: bytes, scope: scope, readOwnerUID: uid)
        XCTAssertEqual(Data(try OwnerHistoryAccountExport.readOwnerUID(from: carrier, scope: scope).utf8), Data(uid.utf8))
        XCTAssertEqual(try Exact.canonical(OwnerHistoryAccountExport.localArchive(from: carrier, scope: scope)),
                       try Exact.canonical(bytes))
    }

    func testCarrierRejectsMissingMalformedAndWrongScopeSelector() throws {
        let original = try Exact.Object(OwnerHistoryAccountExport.sourceCarrier(local: local(), scope: scope, readOwnerUID: "owner-uid"))
        var absent = original; absent.remove("readOwnerUID")
        XCTAssertThrowsError(try OwnerHistoryAccountExport.readOwnerUID(from: absent.encoded(), scope: scope))
        var malformed = original; malformed.set("readOwnerUID", Data("7".utf8))
        XCTAssertThrowsError(try OwnerHistoryAccountExport.readOwnerUID(from: malformed.encoded(), scope: scope))
        XCTAssertThrowsError(try OwnerHistoryAccountExport.readOwnerUID(from: original.encoded(),
            scope: .init(account: "another-account", ownerProfileID: owner.uuidString)))
        for uid in ["", "has\ncontrol", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try OwnerHistoryAccountExport.sourceCarrier(local: local(), scope: scope, readOwnerUID: uid))
        }
    }

    func testColdRosterIsExactAuthenticatedNativeProjection() throws {
        let raw = try native()
        let snapshot = try Exact.Object(OwnerHistorySessionCoordinator.coldSnapshot(nativeDocument: raw,
            scope: scope, target: target(), preservedOwnerUID: "owner-uid"))
        XCTAssertEqual(try snapshot.required("nativeSync"), raw)
        let source = try Exact.Object(Exact.Object(Exact.Object(raw).required("profiles")).required(owner.uuidString))
        let roster = try Exact.Object(Exact.Object(snapshot.required("roster")).required("profiles"))
        XCTAssertEqual(try roster.required(owner.uuidString), try source.required("profile"))
        XCTAssertEqual(try snapshot.text("activeProfileId"), owner.uuidString)
        XCTAssertTrue(String(decoding: try snapshot.encoded(), as: UTF8.self).contains("9007199254740993"))
        XCTAssertTrue(String(decoding: try snapshot.encoded(), as: UTF8.self).contains("-0"))
    }

    func testColdRejectsNonownerAndDifferentOpaqueSelector() throws {
        XCTAssertThrowsError(try OwnerHistorySessionCoordinator.coldSnapshot(nativeDocument: native(),
            scope: scope, target: .init(profileID: child, verifiedUID: "owner-uid"), preservedOwnerUID: "owner-uid"))
        XCTAssertThrowsError(try OwnerHistorySessionCoordinator.coldSnapshot(nativeDocument: native(),
            scope: scope, target: target("e\u{301}"), preservedOwnerUID: "\u{e9}"))
    }

    func testColdRejectsMissingDeletedAndMismatchedOwner() throws {
        var raw = try Exact.Object(native())
        raw.set("profiles", Data("{}".utf8))
        XCTAssertThrowsError(try OwnerHistorySessionCoordinator.coldSnapshot(nativeDocument: raw.encoded(),
            scope: scope, target: target(), preservedOwnerUID: "owner-uid"))
        for change in ["deleted", "id"] {
            var raw = try Exact.Object(native())
            var profiles = try Exact.Object(raw.required("profiles"))
            var record = try Exact.Object(profiles.required(owner.uuidString))
            var profile = try Exact.Object(record.required("profile"))
            if change == "deleted" { profile.set("deleted", Data("true".utf8)) }
            else { profile.set("id", try Exact.string(child.uuidString)) }
            record.set("profile", try profile.encoded()); profiles.set(owner.uuidString, try record.encoded())
            raw.set("profiles", try profiles.encoded())
            XCTAssertThrowsError(try OwnerHistorySessionCoordinator.coldSnapshot(nativeDocument: raw.encoded(),
                scope: scope, target: target(), preservedOwnerUID: "owner-uid"))
        }
    }

    func testColdDoesNotPromoteLegacySchemaOrInventHistory() throws {
        var raw = try Exact.Object(native()); raw.set("schemaVersion", Data("5".utf8))
        XCTAssertThrowsError(try OwnerHistorySessionCoordinator.coldSnapshot(nativeDocument: raw.encoded(),
            scope: scope, target: target(), preservedOwnerUID: "owner-uid"))
        raw.set("schemaVersion", Data("6".utf8)); raw.remove("ownerHistory")
        XCTAssertThrowsError(try OwnerHistorySessionCoordinator.coldSnapshot(nativeDocument: raw.encoded(),
            scope: scope, target: target(), preservedOwnerUID: "owner-uid"))
    }

    func testStoredOwnerSelectorSurvivesChildOwnSelection() throws {
        let selected = OwnerHistorySessionCoordinator.Target(profileID: child, verifiedUID: "child-own-uid")
        XCTAssertEqual(try OwnerHistorySessionCoordinator.initialReadOwnerUID(stored: "owner-uid",
            supplied: nil, target: selected, scope: scope), "owner-uid")
        XCTAssertEqual(try OwnerHistorySessionCoordinator.initialReadOwnerUID(stored: nil,
            supplied: "owner-uid", target: selected, scope: scope), "owner-uid")
        XCTAssertThrowsError(try OwnerHistorySessionCoordinator.initialReadOwnerUID(stored: nil,
            supplied: nil, target: selected, scope: scope))
    }

    func testWarmOwnerFallbackAndOpaqueMismatch() throws {
        XCTAssertEqual(try OwnerHistorySessionCoordinator.initialReadOwnerUID(stored: nil,
            supplied: nil, target: target(), scope: scope), "owner-uid")
        XCTAssertThrowsError(try OwnerHistorySessionCoordinator.initialReadOwnerUID(stored: "e\u{301}",
            supplied: "\u{e9}", target: target(), scope: scope))
    }

    func testFullAccountUnknownNumbersStayRaw() throws {
        let account = try OwnerHistoryAccountExport(completeAccountPlaintext:
            Data(#"{"nativeSync":{"schemaVersion":6,"ownerHistory":{}},"nativeOwnerHistorySources":{},"future":{"negativeZero":-0,"wide":9007199254740993}}"#.utf8))
        let raw = try Exact.Object(account.cloudPlaintext(writeV2: false))
        XCTAssertEqual(try raw.required("future"), Data(#"{"negativeZero":-0,"wide":9007199254740993}"#.utf8))
    }

    func testPendingLegacyCarrierRemainsLocalWithoutSchemaPromotion() throws {
        let carrier = try OwnerHistoryAccountExport.sourceCarrier(local: local(), scope: scope, readOwnerUID: "owner-uid")
        var raw = try Exact.Object(Data(#"{"nativeSync":{"schemaVersion":5},"future":-0}"#.utf8))
        raw.set(OwnerHistoryAccountExport.archiveKey, carrier)
        let account = try OwnerHistoryAccountExport(completeAccountPlaintext: raw.encoded())
        let cloud = try Exact.Object(account.cloudPlaintext(writeV2: false))
        XCTAssertNil(cloud[OwnerHistoryAccountExport.archiveKey])
        XCTAssertEqual(try cloud.required("nativeSync"), Data(#"{"schemaVersion":5}"#.utf8))
        XCTAssertEqual(try cloud.required("future"), Data("-0".utf8))
        XCTAssertEqual(try Exact.Object(account.encoded()).required(OwnerHistoryAccountExport.archiveKey), carrier)
    }
}
