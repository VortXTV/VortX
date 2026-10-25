import Foundation
import XCTest

/// AUTHORED / UNRUN. These are actual byte restoration/parser tests, not fake native receipt,
/// checkpoint, 7 MiB budget, SDK, peer or platform-parity tests. Add to the real host test target.
final class OwnerHistoryExactJSONAuthoredTests: XCTestCase {
    private typealias Exact = OwnerHistoryExactJSON
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private let parent = #"{"instanceId":"1","mutationGeneration":"2","sourceSetWitnessId":"3","scope":"account","ownerProfileId":"owner","profileId":"owner","verifiedStreamingUid":"uid","binding":{"account":"LocalOnly","revision":0,"transactionId":null}}"#
    private let child = #"{"instanceId":"4","mutationGeneration":"3","sourceSetWitnessId":"3","scope":"account","ownerProfileId":"owner","profileId":"owner","verifiedStreamingUid":"uid","binding":{"account":"LocalOnly","revision":0,"transactionId":null}}"#

    func testSignedZeroAndLargeIntegerTokensNeverBecomeFoundationNumbers() throws {
        let input = bytes(#"{"minus":-0.0,"plus":0.0,"big":9007199254740993,"exp":1e+99,"nested":[-0.0,{"n":-0.0}]}"#)
        let object = try Exact.Object(input)
        XCTAssertEqual(object["minus"], bytes("-0.0"))
        XCTAssertEqual(object["plus"], bytes("0.0"))
        XCTAssertEqual(object["big"], bytes("9007199254740993"))
        XCTAssertEqual(object["exp"], bytes("1e+99"))
        XCTAssertNotEqual(try Exact.canonical(bytes(#"{"x":-0.0}"#)),
                          try Exact.canonical(bytes(#"{"x":0.0}"#)))
        XCTAssertEqual(try Exact.Object(object.encoded())["nested"], object["nested"])
    }
    func testStructuralCanonicalComparisonKeepsNumbersButIgnoresKeyOrdering() throws {
        XCTAssertEqual(try Exact.canonical(bytes(#"{"a":{"second":-0.0,"first":1},"b":2}"#)),
                       try Exact.canonical(bytes(#"{"b":2,"a":{"first":1,"second":-0.0}}"#)))
    }
    func testMalformedAndDuplicateKeysFailClosed() {
        for source in [#"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, #"{"a":01}"#,
                       #"{"a":1.}"#, #"{"a":1e}"#, #"{"a":[1,]}"#, #"{"a":1} trailing"#] {
            XCTAssertThrowsError(try Exact.Object(bytes(source)), source)
        }
    }
    private func snapshot() throws -> Exact.Snapshot {
        try .init(bytes: bytes(#"{"roster":{"profiles":{"owner":{"id":"owner","name":"Before"}}},"libraries":{"owner":{"saved":true}},"activeProfileId":"owner","nativeSync":{"schemaVersion":6,"ownerHistory":{"raw":[-0.0,9007199254740993,1e99]},"other":1},"unknownHost":{"sibling":"preserve"}}"#),
            witnessID: "3", fence: bytes(parent))
    }
    private func delta(native: String? = nil, witness: String = "3", prepared: String? = nil) -> Data {
        let nativeField = native.map { #","nativeSync":\#($0)"# } ?? ""
        return bytes(#"{"kind":"checkpoint_delta","fence":\#(child),"preparedAgainst":\#(prepared ?? parent),"delta":{"profiles":[{"id":"owner","name":"After"}],"libraries":{}\#(nativeField)},"reuseExactOwnerHistoryFromWitness":"\#(witness)","requiresCompleteArchiveEnvelope":true,"durableAck":false}"#)
    }
    func testDeltaRestoresExactSourceAndPreservesUnknownHostSibling() throws {
        let base = try snapshot()
        let next = try base.applying(checkpoint: delta(native: #"{"schemaVersion":6,"other":2}"#))
        let before = try Exact.Object(Exact.Object(base.bytes).required("nativeSync"))
        let after = try Exact.Object(Exact.Object(next.bytes).required("nativeSync"))
        XCTAssertEqual(before["ownerHistory"], after["ownerHistory"])
        XCTAssertEqual(after["other"], bytes("2"))
        XCTAssertEqual(try Exact.Object(next.bytes)["unknownHost"], try Exact.Object(base.bytes)["unknownHost"])
        let profiles = try Exact.Object(Exact.Object(Exact.Object(next.bytes).required("roster")).required("profiles"))
        XCTAssertEqual(try Exact.Object(profiles.required("owner")).text("name"), "After")
    }
    func testAbsentNativeDeltaPreservesCompleteNativeDocument() throws {
        let base = try snapshot(), next = try base.applying(checkpoint: delta())
        XCTAssertEqual(try Exact.Object(base.bytes)["nativeSync"], try Exact.Object(next.bytes)["nativeSync"])
    }
    func testForeignWitnessParentAndInjectedOwnerHistoryReject() throws {
        let base = try snapshot()
        XCTAssertThrowsError(try base.applying(checkpoint: delta(witness: "different")))
        XCTAssertThrowsError(try base.applying(checkpoint: delta(prepared: child)))
        XCTAssertThrowsError(try base.applying(checkpoint: delta(native: #"{"schemaVersion":6,"ownerHistory":{}}"#)))
    }
    func testColdNativeCheckpointCannotEraseUnrelatedHostFields() throws {
        let base = try snapshot()
        let newState = bytes(#"{"roster":{"profiles":{"owner":{"id":"owner"}}},"libraries":{},"nativeSync":{"schemaVersion":6,"ownerHistory":{"n":-0.0}},"activeProfileId":"owner"}"#)
        let result = try base.replacingNativeState(newState, witnessID: "new", fence: bytes(child))
        XCTAssertEqual(try Exact.Object(result.bytes)["unknownHost"], try Exact.Object(base.bytes)["unknownHost"])
        XCTAssertEqual(try Exact.Object(Exact.Object(result.bytes).required("nativeSync"))["ownerHistory"],
                       bytes(#"{"n":-0.0}"#))
    }

    // Additional raw Snapshot conservation cases. These remain serializer tests, not
    // native-schema validation, peer merge, encrypted-store or source-ACK authority tests.
    private func conservationNative(source: Data?, optionalFields: Bool = false) throws -> Exact.Object {
        var value = try Exact.Object(bytes(#"{"schemaVersion":6,"scope":"account","ownerProfileId":"owner","profiles":{},"addons":{},"libraries":{},"watches":{}}"#))
        if let source { value.set("ownerHistory", source) }
        if optionalFields {
            value.set("websiteAddonReceipts", bytes(#"{"retainedReceipt":{"n":-0.0}}"#))
            value.set("accountSlots", bytes(#"{"retainedSlot":{"n":9007199254740993}}"#))
            value.set("legacyProfileEditReceipts", bytes(#"{"retainedEdit":{"n":1e999}}"#))
            value.set("legacyImport", bytes(#"{"retainedLegacy":{"deleted":null}}"#))
        }
        return value
    }
    private func conservationSnapshot(_ native: Exact.Object) throws -> Exact.Snapshot {
        var root = try Exact.Object(snapshot().bytes)
        root.set("nativeSync", try native.encoded())
        return try .init(bytes: root.encoded(), witnessID: "3", fence: bytes(parent))
    }
    private func conservationDelta(_ native: Exact.Object?, prepared: String? = nil) throws -> Data {
        try delta(native: native.map { String(decoding: try $0.encoded(), as: UTF8.self) }, prepared: prepared)
    }
    private func conservationCold(_ native: Exact.Object) throws -> Data {
        var root = try Exact.Object(bytes(#"{"roster":{"profiles":{"owner":{"id":"owner"}}},"libraries":{},"activeProfileId":"owner"}"#))
        root.set("nativeSync", try native.encoded())
        return try root.encoded()
    }

    func testColdPeerNormalizationRetainsOmittedUnknownNativeBytes() throws {
        let source = bytes(#"{ "proof" : [-0.0,18446744073709551615] }"#)
        let unknown = bytes(#"{ "future" : [18446744073709551615,-0.0] }"#)
        var original = try conservationNative(source: source)
        original.set("futureNative", unknown)
        let normalized = try conservationNative(source: source)
        let state = try Exact.Snapshot.conservingColdNativeState(originalNative: original.encoded(),
            normalizedState: conservationCold(normalized), witnessID: "3", fence: bytes(parent))
        let retained = try Exact.Object(state.nativeSyncBytes)
        XCTAssertEqual(retained["futureNative"], unknown)
        XCTAssertEqual(retained["ownerHistory"], source)
        XCTAssertEqual(retained["schemaVersion"], normalized["schemaVersion"])
    }

    func testColdPeerNormalizationRejectsKnownSourceAndReturnedUnknownChanges() throws {
        var original = try conservationNative(source: bytes(#"{"proof":-0.0}"#))
        original.set("futureNative", bytes(#"{"wide":18446744073709551615}"#))
        for key in ["schemaVersion", "ownerHistory", "futureNative"] {
            var changed = original
            changed.set(key, key == "schemaVersion" ? bytes("5") : bytes("{}"))
            XCTAssertThrowsError(try Exact.Snapshot.conservingColdNativeState(originalNative: original.encoded(),
                normalizedState: conservationCold(changed), witnessID: "3", fence: bytes(parent)), key)
        }
        var missing = original; missing.remove("ownerHistory")
        XCTAssertThrowsError(try Exact.Snapshot.requireColdNativeConservation(original: original.encoded(), candidate: missing.encoded()))
        var added = original; added.set("inventedNative", bytes("true"))
        XCTAssertThrowsError(try Exact.Snapshot.requireColdNativeConservation(original: original.encoded(), candidate: added.encoded()))
    }

    func testOmittedUnknownNativeSiblingsRetainOriginalRawTokensAndSource() throws {
        let source = bytes(#"{ "sources" : [-0.0,9007199254740993,1e999], "unknown" : {"deleted":null} }"#)
        let unknown = bytes(#"{ "raw" : [-0.0,0.0,9007199254740993,1e+999], "order" : [3,1,2] }"#)
        var native = try conservationNative(source: source)
        native.set("futureNative", unknown)
        native.set("futureTombstone", bytes("null"))
        let base = try conservationSnapshot(native)
        let next = try base.applying(checkpoint: conservationDelta(conservationNative(source: nil)))
        let after = try Exact.Object(next.nativeSyncBytes)
        XCTAssertEqual(after["futureNative"], unknown)
        XCTAssertEqual(after["futureTombstone"], bytes("null"))
        XCTAssertEqual(after["ownerHistory"], source)
        XCTAssertEqual(try Exact.Object(base.nativeSyncBytes)["futureNative"], unknown)
        XCTAssertEqual(try Exact.Object(base.bytes)["unknownHost"], try Exact.Object(next.bytes)["unknownHost"])
    }

    func testKnownSerdeOptionalsClearOnOmissionAndDoNotResurrect() throws {
        let source = bytes(#"{"n":-0.0}"#)
        let unknown = bytes(#"{"legacyImportLookalike":1e999}"#)
        var native = try conservationNative(source: source, optionalFields: true)
        native.set("futureNative", unknown)
        let base = try conservationSnapshot(native)
        let next = try base.applying(checkpoint: conservationDelta(conservationNative(source: nil)))
        let after = try Exact.Object(next.nativeSyncBytes)
        for key in ["websiteAddonReceipts", "accountSlots", "legacyProfileEditReceipts", "legacyImport"] {
            XCTAssertNil(after[key], key)
            XCTAssertNotNil(try Exact.Object(base.nativeSyncBytes)[key], key)
        }
        XCTAssertEqual(after["futureNative"], unknown)
        XCTAssertEqual(after["ownerHistory"], source)
        let unchanged = try next.applying(checkpoint: conservationDelta(nil, prepared: child))
        XCTAssertEqual(try unchanged.nativeSyncBytes, try next.nativeSyncBytes)
        XCTAssertEqual(after["profiles"], bytes("{}"))
    }

    func testExplicitRawUnknownNativeUpsertRetainsOtherUnknownFields() throws {
        var native = try conservationNative(source: bytes(#"{"raw":-0.0}"#))
        native.set("futureChanged", bytes(#"{"oldNested":1,"keep":2}"#))
        let retained = bytes(#"{"opaque":[-0.0,9007199254740993,1e999]}"#)
        native.set("futureUnmentioned", retained)
        let base = try conservationSnapshot(native)
        var incoming = try conservationNative(source: nil)
        let replacement = bytes(#"{ "newNested" : 3 }"#)
        incoming.set("futureChanged", replacement)
        incoming.set("futureNewTombstone", bytes("null"))
        let after = try Exact.Object(base.applying(checkpoint: conservationDelta(incoming)).nativeSyncBytes)
        XCTAssertEqual(after["futureChanged"], replacement)
        XCTAssertEqual(after["futureUnmentioned"], retained)
        XCTAssertEqual(after["futureNewTombstone"], bytes("null"))
        // Explicit whole-field upsert is NOT a recursive preservation/peer merge.
        XCTAssertNil(try Exact.Object(after.required("futureChanged"))["oldNested"])
    }

    func testColdReplacementPreservesUnknownNativeAndHostButReplacesExactSource() throws {
        let oldSource = bytes(#"{"old":-0.0}"#)
        let newSource = bytes(#"{ "new" : [9007199254740993,-0.0,1e999] }"#)
        let unknown = bytes(#"{ "untouched" : [-0.0,1e999] }"#)
        var native = try conservationNative(source: oldSource, optionalFields: true)
        native.set("futureNative", unknown)
        let base = try conservationSnapshot(native)
        let result = try base.replacingNativeState(conservationCold(conservationNative(source: newSource)),
            witnessID: "3", fence: bytes(child))
        let after = try Exact.Object(result.nativeSyncBytes)
        XCTAssertEqual(after["futureNative"], unknown)
        XCTAssertEqual(after["ownerHistory"], newSource)
        XCTAssertNotEqual(after["ownerHistory"], oldSource)
        XCTAssertNil(after["accountSlots"])
        XCTAssertEqual(try Exact.Object(result.bytes)["unknownHost"], try Exact.Object(base.bytes)["unknownHost"])
        XCTAssertEqual(try Exact.Object(base.nativeSyncBytes)["ownerHistory"], oldSource)
    }

    func testColdReplacementMayRemoveKnownSourceWithoutErasingUnknownNative() throws {
        var native = try conservationNative(source: bytes(#"{"mustNotResurrect":true}"#))
        let unknown = bytes(#"[-0.0,9007199254740993,1e999]"#)
        native.set("futureNative", unknown)
        let base = try conservationSnapshot(native)
        var replacement = try conservationNative(source: nil)
        replacement.set("schemaVersion", bytes("5"))
        let result = try base.replacingNativeState(conservationCold(replacement), witnessID: "3", fence: bytes(child))
        let after = try Exact.Object(result.nativeSyncBytes)
        XCTAssertNil(after["ownerHistory"])
        XCTAssertEqual(after["schemaVersion"], bytes("5"))
        XCTAssertEqual(after["futureNative"], unknown)
        let deltaAfterCold = try result.applying(checkpoint: conservationDelta(nil, prepared: child))
        XCTAssertNil(try Exact.Object(deltaAfterCold.nativeSyncBytes)["ownerHistory"])
        XCTAssertEqual(try deltaAfterCold.nativeSyncBytes, try result.nativeSyncBytes)
    }

    func testRepeatedRawReadsDoNotRewriteSnapshotNativeOrSourceBytes() throws {
        let source = bytes(#"{ "signed" : -0.0, "big" : 9007199254740993, "exp" : 1e999 }"#)
        var native = try conservationNative(source: source)
        native.set("futureNative", bytes(#"{"a":-0.0}"#))
        let base = try conservationSnapshot(native)
        let original = base.bytes
        let nativeBytes = try base.nativeSyncBytes
        for _ in 0..<3 {
            XCTAssertEqual(base.bytes, original)
            XCTAssertEqual(try base.nativeSyncBytes, nativeBytes)
            XCTAssertEqual(try Exact.Object(base.nativeSyncBytes)["ownerHistory"], source)
        }
        let next = try base.applying(checkpoint: conservationDelta(nil))
        XCTAssertEqual(base.bytes, original)
        XCTAssertEqual(try next.nativeSyncBytes, nativeBytes)
    }

    func testExistingProfileAndLibraryUpsertsRetainUnmentionedRows() throws {
        var root = try Exact.Object(snapshot().bytes)
        var roster = try Exact.Object(root.required("roster"))
        var profiles = try Exact.Object(roster.required("profiles"))
        let untouched = bytes(#"{"id":"second","future":[-0.0,1e999]}"#)
        profiles.set("second", untouched); roster.set("profiles", try profiles.encoded())
        root.set("roster", try roster.encoded())
        root.set("libraries", bytes(#"{"owner":{"old":true},"second":{"raw":9007199254740993}}"#))
        let base = try Exact.Snapshot(bytes: root.encoded(), witnessID: "3", fence: bytes(parent))
        var reply = try Exact.Object(delta())
        var actualDelta = try Exact.Object(reply.required("delta"))
        let changedBucket = bytes(#"{"new":-0.0}"#)
        actualDelta.set("libraries", bytes(#"{"owner":\#(String(decoding: changedBucket, as: UTF8.self))}"#))
        reply.set("delta", try actualDelta.encoded())
        let after = try Exact.Object(base.applying(checkpoint: reply.encoded()).bytes)
        let afterProfiles = try Exact.Object(Exact.Object(after.required("roster")).required("profiles"))
        XCTAssertEqual(afterProfiles["second"], untouched)
        XCTAssertEqual(try Exact.Object(afterProfiles.required("owner")).text("name"), "After")
        let afterLibraries = try Exact.Object(after.required("libraries"))
        XCTAssertEqual(afterLibraries["owner"], changedBucket)
        XCTAssertEqual(afterLibraries["second"], bytes(#"{"raw":9007199254740993}"#))
    }

    func testUnsupportedRootChangesMalformedNativeAndSourceInjectionStillReject() throws {
        let base = try snapshot()
        var reply = try Exact.Object(delta())
        var actualDelta = try Exact.Object(reply.required("delta"))
        actualDelta.set("unsupportedRootMutation", bytes("true"))
        reply.set("delta", try actualDelta.encoded())
        XCTAssertThrowsError(try base.applying(checkpoint: reply.encoded()))
        XCTAssertThrowsError(try base.applying(checkpoint: delta(native: "null")))
        XCTAssertThrowsError(try base.applying(checkpoint: delta(native: #"{"ownerHistory":null}"#)))
        var cold = try Exact.Object(conservationCold(conservationNative(source: nil)))
        cold.set("unsupportedRootMutation", bytes("true"))
        XCTAssertThrowsError(try base.replacingNativeState(cold.encoded(), witnessID: "3", fence: bytes(child)))
        XCTAssertThrowsError(try base.replacingNativeState(bytes(#"{"roster":{"profiles":{}},"libraries":{}}"#),
            witnessID: "3", fence: bytes(child)))
    }
    // Exercise the production raw consumer, not a numeric decoder/model substitute.
    // These checks do not substitute for native-schema, encryption or live-ABI validation.
    private func keyedEnvelope(_ edits: Data, revision: String = "3", finalFence: String? = nil) throws -> Data {
        var step = try Exact.Object(bytes("{}"))
        step.set("baseGeneration", try Exact.string("2")); step.set("revision", try Exact.string(revision))
        step.set("edits", edits)
        return bytes(#"{"kind":"checkpoint_delta","fence":\#(finalFence ?? child),"preparedAgainst":\#(parent),"deltaEncoding":"keyed_rows/1","keyedStateSteps":[\#(String(decoding: try step.encoded(), as: UTF8.self))],"reuseExactOwnerHistoryFromWitness":"3","requiresCompleteArchiveEnvelope":true,"durableAck":false}"#)
    }
    private func keyedFixture(rows: Int = 2) throws -> Exact.Snapshot {
        var log = try Exact.Object(bytes("{}"))
        for i in 0..<rows { log.set("raw:\(i)", bytes(#"{"offsetMs":0,"resumeAt":1,"finishedAt":1,"resetAt":0,"cwDismissedAt":0,"timesWatched":1}"#)) }
        let library = bytes(#"{"items":[],"history":[],"continueWatching":[],"resume":{},"watched":{},"searchHistory":["dup","old","dup"],"watchLog":\#(String(decoding: try log.encoded(), as: UTF8.self)),"resumeVault":{"aliases":{"raw":"canonical"},"entries":{"canonical":{"offsetMs":1,"durationMs":0,"updatedAt":1}}},"cwBoard":[{"id":"raw","name":"Raw","progress":1,"lastPlayedAt":1}]}"#)
        let watch = bytes(#"{"log":\#(String(decoding: try log.encoded(), as: UTF8.self)),"contexts":{},"identityLinks":[["raw","alias"]]}"#)
        let slot = bytes(#"{"watch":\#(String(decoding: watch, as: UTF8.self)),"sourceHistory":{"original":{"raw":[-0.0,18446744073709551615,1e999]}}}"#)
        return try .init(bytes: bytes(#"{"roster":{"profiles":{"owner":{"id":"owner"}}},"libraries":{"owner":\#(String(decoding: library, as: UTF8.self)),"inactive":\#(String(decoding: library, as: UTF8.self))},"activeProfileId":"owner","nativeSync":{"schemaVersion":6,"watches":{"owner":\#(String(decoding: watch, as: UTF8.self))},"accountSlots":{"inactive":{"slots":{"a":\#(String(decoding: slot, as: UTF8.self)),"b":\#(String(decoding: slot, as: UTF8.self))}}},"ownerHistory":{"raw":[-0.0,18446744073709551615,1e999]},"futureNative":{"keep":-0.0}},"unknownHost":{"keep":1e999}}"#), witnessID: "3", fence: bytes(parent))
    }
    func testKeyedLargeHistoryMatchesCompleteDeltaAndRetainsInactiveRawSources() throws {
        let base = try keyedFixture(rows: 5000), original = base.bytes
        let edits = bytes(#"{"libraries":{"owner":{"watchLog":{"raw:0":{"op":"remove"}},"searchHistory":{"at":1,"remove":1,"insert":["new","dup"]},"aliases":{"raw":{"op":"remove"}},"entries":{"canonical":{"op":"remove"}},"cwBoard":{"at":0,"remove":1,"insert":[]}}},"nativeWatches":{"owner":{"log":{"raw:0":{"op":"remove"}},"identityLinks":{"at":0,"remove":1,"insert":[]}}},"slotWatches":{"inactive":{"b":{"log":{"raw:0":{"op":"remove"}}}}}}"#)
        let delta = try keyedEnvelope(edits)
        let next = try base.applying(checkpoint: delta, allowKeyed: true, expectedFence: bytes(child))
        var expectedRoot = try Exact.Object(base.bytes), libraries = try Exact.Object(expectedRoot.required("libraries"))
        var library = try Exact.Object(libraries.required("owner")), log = try Exact.Object(library.required("watchLog"))
        log.remove("raw:0"); library.set("watchLog", try log.encoded())
        library.set("searchHistory", bytes(#"["dup","new","dup","dup"]"#)); library.remove("resumeVault"); library.remove("cwBoard")
        libraries.set("owner", try library.encoded()); expectedRoot.set("libraries", try libraries.encoded())
        var native = try Exact.Object(expectedRoot.required("nativeSync")), watches = try Exact.Object(native.required("watches"))
        var watch = try Exact.Object(watches.required("owner")); watch.set("log", try log.encoded()); watch.remove("identityLinks")
        watches.set("owner", try watch.encoded()); native.set("watches", try watches.encoded())
        var states = try Exact.Object(native.required("accountSlots")), state = try Exact.Object(states.required("inactive"))
        var slots = try Exact.Object(state.required("slots")), slot = try Exact.Object(slots.required("b"))
        var slotWatch = try Exact.Object(slot.required("watch")); slotWatch.set("log", try log.encoded()); slot.set("watch", try slotWatch.encoded())
        slots.set("b", try slot.encoded()); state.set("slots", try slots.encoded()); states.set("inactive", try state.encoded())
        native.set("accountSlots", try states.encoded()); expectedRoot.set("nativeSync", try native.encoded())
        XCTAssertEqual(try Exact.canonical(next.bytes), try Exact.canonical(expectedRoot.encoded()))
        // Compare against the existing complete-delta application, not only handwritten output.
        var nativePatch = native; nativePatch.remove("ownerHistory")
        let coarse = bytes(#"{"kind":"checkpoint_delta","fence":\#(child),"preparedAgainst":\#(parent),"delta":{"libraries":{"owner":\#(String(decoding: try library.encoded(), as: UTF8.self))},"nativeSync":\#(String(decoding: try nativePatch.encoded(), as: UTF8.self))},"reuseExactOwnerHistoryFromWitness":"3","requiresCompleteArchiveEnvelope":true,"durableAck":false}"#)
        XCTAssertEqual(try Exact.canonical(next.bytes), try Exact.canonical(base.applying(checkpoint: coarse, expectedFence: bytes(child)).bytes))
        XCTAssertEqual(base.bytes, original)
        XCTAssertLessThan(delta.count, base.bytes.count / 4)
        XCTAssertEqual(try Exact.Object(next.nativeSyncBytes)["ownerHistory"], try Exact.Object(base.nativeSyncBytes)["ownerHistory"])
    }
    func testKeyedAbsentOptionalsCreatedAndRemovedWithoutLosingDuplicateOrder() throws {
        let base = try keyedFixture()
        let create = bytes(#"{"libraries":{"owner":{"watchContexts":{"new":{"op":"put","value":{"metaId":"new","name":"New","updatedAt":1}}}}},"nativeWatches":{},"slotWatches":{}}"#)
        let next = try base.applying(checkpoint: keyedEnvelope(create), allowKeyed: true, expectedFence: bytes(child))
        let library = try Exact.Object(Exact.Object(Exact.Object(next.bytes).required("libraries")).required("owner"))
        XCTAssertNotNil(library["watchContexts"])
        let remove = bytes(#"{"libraries":{"owner":{"watchContexts":{"new":{"op":"remove"}}}},"nativeWatches":{},"slotWatches":{}}"#)
        var envelope = try Exact.Object(keyedEnvelope(remove, revision: "4"))
        var currentFence = try Exact.Object(bytes(child)); currentFence.set("mutationGeneration", try Exact.string("4"))
        envelope.set("fence", try currentFence.encoded()); envelope.set("preparedAgainst", bytes(child))
        var step = try Exact.Object(Exact.array(envelope.required("keyedStateSteps"))[0]); step.set("baseGeneration", try Exact.string("3"))
        envelope.set("keyedStateSteps", bytes("[") + (try step.encoded()) + bytes("]"))
        let final = try next.applying(checkpoint: envelope.encoded(), allowKeyed: true, expectedFence: currentFence.encoded())
        XCTAssertEqual(try Exact.canonical(final.bytes), try Exact.canonical(base.bytes))
    }
    func testKeyedWrongCurrentFenceRevisionAndMalformedSpliceRejectBeforePublication() throws {
        let base = try keyedFixture(), original = base.bytes
        let empty = bytes(#"{"libraries":{},"nativeWatches":{},"slotWatches":{}}"#)
        XCTAssertThrowsError(try base.applying(checkpoint: keyedEnvelope(empty), expectedFence: bytes(child)))
        var foreign = try Exact.Object(bytes(child)); foreign.set("instanceId", try Exact.string("wrong-instance"))
        XCTAssertThrowsError(try base.applying(checkpoint: keyedEnvelope(empty, finalFence: String(decoding: try foreign.encoded(), as: UTF8.self)), allowKeyed: true, expectedFence: bytes(child)))
        XCTAssertThrowsError(try base.applying(checkpoint: keyedEnvelope(empty, revision: "4"), allowKeyed: true, expectedFence: bytes(child)))
        for bad in [#"{"at":18446744073709551615,"remove":1,"insert":[]}"#, #"{"at":1.0,"remove":0,"insert":[]}"#, #"{"at":0,"remove":99,"insert":[]}"#] {
            let edit = bytes(#"{"libraries":{"owner":{"history":\#(bad)}},"nativeWatches":{},"slotWatches":{}}"#)
            XCTAssertThrowsError(try base.applying(checkpoint: keyedEnvelope(edit), allowKeyed: true, expectedFence: bytes(child)))
        }
        XCTAssertEqual(base.bytes, original)
    }
    func testKeyedCrossObjectUnicodeAliasesAndUnknownMutationFieldsReject() throws {
        let base = try keyedFixture()
        var root = try Exact.Object(base.bytes), libraries = try Exact.Object(root.required("libraries"))
        var owner = try Exact.Object(libraries.required("owner")); owner.set("watchContexts", bytes(#"{"é":{"metaId":"é"}}"#))
        libraries.set("owner", try owner.encoded()); root.set("libraries", try libraries.encoded())
        let unicode = try Exact.Snapshot(bytes: root.encoded(), witnessID: "3", fence: bytes(parent))
        for operation in [#"{"op":"remove"}"#, #"{"op":"put","value":{}}"#] {
            let edits = bytes(#"{"libraries":{"owner":{"watchContexts":{"e\u0301":\#(operation)}}},"nativeWatches":{},"slotWatches":{}}"#)
            XCTAssertThrowsError(try unicode.applying(checkpoint: keyedEnvelope(edits), allowKeyed: true, expectedFence: bytes(child)))
        }
        let injected = bytes(#"{"libraries":{},"nativeWatches":{},"slotWatches":{},"ownerHistory":{}}"#)
        XCTAssertThrowsError(try base.applying(checkpoint: keyedEnvelope(injected), allowKeyed: true, expectedFence: bytes(child)))
    }
}
