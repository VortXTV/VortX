import Foundation
import Darwin

// Authored source-unit fixtures only. Not run in the preparation lane. No ABI, disk, or timing claim.
@main enum VortxNativeDeltaApplierTests {
    typealias Applier = VortxNativeDeltaApplier
    static let scope = VortxAccountScope(account: "delta.fixture", ownerProfileID: "owner")
    static let binding = Applier.Binding(scope: scope,
        ownerGeneration: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        handleGeneration: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!)
    static let session = "fixture-v2-session"
    enum FixtureFailure: Error { case beforeInstall, afterInstallUncertain, nativeCommit }
    static func diagnostic(_ message: String) {
        // All messages are authored labels/counts, never dumps of state or caught error data.
        let bounded = Array(message.utf8.prefix(1_000)) + [10]
        try? FileHandle.standardError.write(contentsOf: Data(bounded))
    }
    static func fail(_ kind: String, label: String, line: Int) -> Never {
        diagnostic("failure kind=\(kind) line=\(line) label=\(label)")
        Darwin.exit(1)
    }
    static func check(_ value: Bool, label: String = "assertion", line: Int = #line) {
        if !value { fail("assertion", label: label, line: line) }
    }
    static func rejects(_ label: String, line: Int = #line, _ operation: () throws -> Void) {
        do { try operation(); fail("accepted_rejection", label: label, line: line) } catch {}
    }
    // Independent oracle: serialize a tagged tree after sorting raw UTF-8 keys. Production
    // compares dictionary indices recursively without sorting; this oracle calls none of it.
    static func byteImage(_ value: VortxJSON) -> [UInt8] {
        func framed(_ text: String) -> [UInt8] { Array("\(text.utf8.count):".utf8) + Array(text.utf8) }
        switch value {
        case .object(let fields):
            var bytes = Array("o\(fields.count):".utf8)
            for key in fields.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                bytes += framed(key)
                bytes += byteImage(fields[key]!) // key comes directly from this same map.
            }
            return bytes
        case .array(let values): return Array("a\(values.count):".utf8) + values.flatMap(byteImage)
        case .string(let text): return [115] + framed(text)
        case .integer(let integer): return Array("i\(integer);".utf8)
        case .unsigned(let integer): return Array("u\(integer);".utf8)
        case .number(let number): return Array("d\(number.bitPattern);".utf8)
        case .bool(let value): return Array((value ? "true;" : "false;").utf8)
        case .null: return Array("null;".utf8)
        }
    }
    static func same(_ lhs: VortxJSON?, _ rhs: VortxJSON?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let left), .some(let right)): return byteImage(left) == byteImage(right)
        default: return false
        }
    }
    static func replacing(_ value: VortxJSON, _ path: [String], with replacement: VortxJSON?) -> VortxJSON {
        precondition(!path.isEmpty)
        guard case .object(var object) = value else { preconditionFailure("fixture path is not an object") }
        let key = path[0]
        if path.count == 1 { object[key] = replacement }
        else { object[key] = replacing(object[key]!, Array(path.dropFirst()), with: replacement) }
        return .object(object)
    }
    static func watch(_ position: UInt64) -> VortxJSON {
        .object([
            "log": .object([
                "episode": .object(["resume_ms": .unsigned(position), "resume_at": .integer(10),
                    "watched_at": .integer(0), "reset_at": .integer(0), "times_watched": .integer(0),
                    "removed_at": .integer(11), "futureRecord": .array([.null, .string("retain")])]),
                "retained-history": .object(["watched_at": .integer(9), "removed_at": .integer(12)])]),
            "contexts": .object(["episode": .object(["metaId": .string("title"), "name": .string("History"),
                "futureContext": .object(["keep": .bool(true)])])]),
            "identityLinks": .array([.array([.string("title"), .string("imdb:title")])]),
            "futureWatch": .object(["opaque": .unsigned(UInt64.max)])])
    }
    static func fixture() -> VortxJSON {
        let shared: VortxJSON = .object(["kind": .string("shared"), "value": .string("owner")])
        let own: VortxJSON = .object(["kind": .string("own"), "value": .string("retained-account")])
        return .object([
            "roster": .object(["profiles": .object([
                "owner": .object(["id": .string("owner"), "owner": .bool(true), "deleted": .bool(false),
                    "futureProfile": .string("keep-owner")]),
                "inactive": .object(["id": .string("inactive"), "owner": .bool(false), "deleted": .bool(false),
                    "futureProfile": .string("keep-inactive")])]),
                "tombstones": .array([.string("retired-profile")]), "futureRoster": .bool(true)]),
            "activeProfileId": .string("owner"),
            "libraries": .object([
                "owner": .object(["watchContexts": .object(["retained": .object(["name": .string("Owner history")])]),
                    "futureLibrary": .string("owner-value")]),
                "inactive": .object(["watchContexts": .object(["old": .object(["name": .string("Inactive history")])]),
                    "futureLibrary": .string("inactive-value")])]),
            "nativeSync": .object([
                "schemaVersion": .integer(5), "scope": .string(scope.account), "ownerProfileId": .string("owner"),
                "profiles": .object(["owner": .object([:]), "inactive": .object([:])]),
                "watches": .object(["owner": watch(100), "inactive": watch(900)]),
                "accountSlots": .object(["owner": .object([
                    "activeBinding": .object(["account": shared, "revision": .integer(3), "transactionId": .string("retained-binding")]),
                    "slots": .object([
                        "shared": .object(["account": shared, "watch": watch(100),
                            "library": .object(["tombstones": .array([.string("removed")])]),
                            "sourceHistory": .object(["digest": .string("retained-proof")]), "futureSlot": .null]),
                        "own:retained": .object(["account": own, "watch": watch(800),
                            "futureSlot": .array([.string("inactive-slot"), .integer(4)])])]),
                    "receipts": .object(["earlier": .object(["fingerprint": .string("proof")])]),
                    "futureAccount": .string("keep-account")])]),
                "legacyImport": .object(["archive": .string("retained")]),
                "websiteAddonReceipts": .object(["event": .object(["futureReceipt": .bool(true)])]),
                "futureSync": .array([.string("opaque"), .null])]),
            "accountLibraryArchives": .object(["owner": .object(["own:retained": .object(["items": .array([.string("archived-item")])])])]),
            "projectedAccountSlots": .object(["owner": .string("shared")]),
            "futureHost": .object(["all": .array([.null, .bool(false), .unsigned(UInt64.max), .string("opaque")])])])
    }
    static func base(_ snapshot: VortxJSON) -> VortxJSON {
        .object(["deltaVersion": .integer(2), "session": .string(session), "baseRevision": .null,
                 "revision": .integer(0), "snapshot": snapshot])
    }
    static func envelope(base: UInt64, revision: UInt64, delta: VortxJSON = .object([:]),
                         position: UInt64? = nil) -> VortxJSON {
        var result: [String: VortxJSON] = ["deltaVersion": .integer(2), "session": .string(session),
            "baseRevision": .unsigned(base), "revision": .unsigned(revision), "delta": delta]
        if let position {
            result["nativeWatchPatches"] = .object(["owner": watch(position)])
            result["accountSlotWatchPatches"] = .object(["owner": .object(["shared": watch(position)])])
        }
        return .object(result)
    }
    static func prepared(_ snapshot: VortxJSON = fixture()) throws -> Applier {
        try Applier(binding: binding, session: session, expectedSnapshot: snapshot,
                    negotiationResponse: .object(["ok": .bool(true), "events": .array([])]), initialEnvelope: base(snapshot))
    }

    static func negotiationAndBaseTests() throws {
        let state = fixture()
        for response in [VortxJSON.object(["ok": .bool(false)]), .object([:]), .object(["ok": .integer(1)])] {
            rejects("old or unacknowledged engine") {
                _ = try Applier(binding: binding, session: session, expectedSnapshot: state,
                                negotiationResponse: response, initialEnvelope: base(state))
            }
        }
        for invalid in [VortxJSON.object([:]), .object(["profiles": .array([])]),
                        replacing(base(state), ["deltaVersion"], with: .integer(1)),
                        replacing(base(state), ["baseRevision"], with: .integer(0)),
                        replacing(base(state), ["revision"], with: .integer(1)),
                        replacing(base(state), ["delta"], with: .object([:])),
                        replacing(base(state), ["nativeWatchPatches"], with: .object([:])),
                        replacing(base(state), ["accountSlotWatchPatches"], with: .object([:])),
                        replacing(base(state), ["snapshot", "futureHost"], with: nil)] {
            rejects("invalid or lossy initial base") {
                _ = try Applier(binding: binding, session: session, expectedSnapshot: state,
                                negotiationResponse: .object(["ok": .bool(true)]), initialEnvelope: invalid)
            }
        }
        for invalid in ["", String(repeating: "x", count: 129), "session\u{0}", String(repeating: "é", count: 65)] {
            rejects("invalid session") {
                _ = try Applier(binding: binding, session: invalid, expectedSnapshot: state,
                                negotiationResponse: .object(["ok": .bool(true)]), initialEnvelope: base(state))
            }
        }
        let accepted = try prepared()
        check(same(accepted.snapshot, state) && accepted.cursor.revision == 0)
    }

    static func preservationAndCompletionTests() throws {
        var applier = try prepared()
        let original = applier.snapshot, cursor = applier.cursor
        let wire = envelope(base: 0, revision: 1, position: 120)
        let candidate = try applier.prepare(wire, currentBinding: binding)
        check(same(applier.snapshot, original) && applier.cursor == cursor)
        check(same(candidate.envelope, wire))
        var expected = replacing(original, ["nativeSync", "watches", "owner"], with: watch(120))
        expected = replacing(expected, ["nativeSync", "accountSlots", "owner", "slots", "shared", "watch"], with: watch(120))
        check(same(candidate.snapshot, expected)) // Includes every untouched key byte and nested value.
        check(same(candidate.snapshot["futureHost"], original["futureHost"]))
        check(same(candidate.snapshot["nativeSync"]?["watches"]?["inactive"], original["nativeSync"]?["watches"]?["inactive"]))
        check(same(candidate.snapshot["nativeSync"]?["accountSlots"]?["owner"]?["slots"]?["own:retained"],
            original["nativeSync"]?["accountSlots"]?["owner"]?["slots"]?["own:retained"]))
        _ = try scope.validateSnapshot(candidate.snapshotJSON)

        // These model callback failures, not actual disk/native failures. No completion is reported.
        for failure in [FixtureFailure.beforeInstall, .afterInstallUncertain, .nativeCommit] {
            var failedApplier = try prepared()
            let failedCandidate = try failedApplier.prepare(wire, currentBinding: binding)
            rejects("incomplete acceptance") {
                try failedApplier.complete(failedCandidate, currentBinding: { binding }) { _ in throw failure }
            }
            check(same(failedApplier.snapshot, original) && failedApplier.cursor == cursor)
            // Do not retry an uncertain owner. A real session must latch and reopen it.
        }
        var acceptedSnapshot: VortxJSON?
        try applier.complete(candidate, currentBinding: { binding }) { acceptedSnapshot = $0.snapshot }
        check(same(acceptedSnapshot, expected) && same(applier.snapshot, expected) && applier.cursor.revision == 1)
        var duplicateAccepts = 0
        rejects("completed candidate replay") {
            try applier.complete(candidate, currentBinding: { binding }) { _ in duplicateAccepts += 1 }
        }
        check(duplicateAccepts == 0)

        // Discard follows an externally acknowledged rollback and retires the candidate token.
        let rollback = try applier.prepare(envelope(base: 1, revision: 2, position: 130), currentBinding: binding)
        let acceptedBeforeRollback = applier.snapshot
        try applier.discard(rollback, currentBinding: binding)
        check(same(applier.snapshot, acceptedBeforeRollback) && applier.cursor.revision == 1)
        rejects("discarded candidate") {
            try applier.complete(rollback, currentBinding: { binding }) { _ in preconditionFailure("stale acceptance") }
        }
    }

    static func cursorAndIdentityTests() throws {
        var applier = try prepared()
        let original = applier.snapshot
        for invalid in [envelope(base: 1, revision: 2, position: 200),
                        envelope(base: 0, revision: 0, position: 200),
                        replacing(envelope(base: 0, revision: 1), ["session"], with: .string("foreign")),
                        replacing(envelope(base: 0, revision: 1), ["baseRevision"], with: nil),
                        replacing(envelope(base: 0, revision: 1), ["baseRevision"], with: .null), base(original)] {
            rejects("dropped/foreign/reset cursor") { _ = try applier.prepare(invalid, currentBinding: binding) }
            check(same(applier.snapshot, original) && applier.cursor.revision == 0)
        }
        let idle = try applier.prepare(envelope(base: 0, revision: 0), currentBinding: binding)
        try applier.complete(idle, currentBinding: { binding }) { _ in }
        check(same(applier.snapshot, original) && applier.cursor.revision == 0)
        rejects("idle candidate replay") { try applier.complete(idle, currentBinding: { binding }) { _ in } }
        let first = envelope(base: 0, revision: 1, position: 200)
        let candidate = try applier.prepare(first, currentBinding: binding)
        try applier.complete(candidate, currentBinding: { binding }) { _ in }
        rejects("duplicate mutating drain") { _ = try applier.prepare(first, currentBinding: binding) }
        rejects("out-of-order drain") { _ = try applier.prepare(envelope(base: 2, revision: 3), currentBinding: binding) }

        let foreignBindings = [
            Applier.Binding(scope: .init(account: "other", ownerProfileID: "owner"), ownerGeneration: binding.ownerGeneration, handleGeneration: binding.handleGeneration),
            Applier.Binding(scope: .init(account: scope.account, ownerProfileID: "inactive"), ownerGeneration: binding.ownerGeneration, handleGeneration: binding.handleGeneration),
            Applier.Binding(scope: scope, ownerGeneration: UUID(), handleGeneration: binding.handleGeneration),
            Applier.Binding(scope: scope, ownerGeneration: binding.ownerGeneration, handleGeneration: UUID())]
        let pending = try applier.prepare(envelope(base: 1, revision: 2, position: 300), currentBinding: binding)
        let otherApplier = try prepared()
        let otherCandidate = try otherApplier.prepare(envelope(base: 0, revision: 1), currentBinding: binding)
        rejects("candidate from another publication") {
            try applier.complete(otherCandidate, currentBinding: { binding }) { _ in preconditionFailure("foreign publication") }
        }
        for foreign in foreignBindings {
            rejects("foreign preparation") { _ = try applier.prepare(envelope(base: 1, revision: 2), currentBinding: foreign) }
            rejects("foreign completion") { try applier.complete(pending, currentBinding: { foreign }) { _ in } }
            rejects("foreign discard") { try applier.discard(pending, currentBinding: foreign) }
        }
        var identity = binding
        let before = applier.snapshot
        rejects("identity retired during acceptance") {
            try applier.complete(pending, currentBinding: { identity }) { _ in identity = foreignBindings[2] }
        }
        check(same(applier.snapshot, before) && applier.cursor.revision == 1)
    }

    static func malformedEnvelopeAndRollbackTests() throws {
        let applier = try prepared()
        let good = envelope(base: 0, revision: 1, position: 200)
        var invalid = [VortxJSON.object([:]), .array([]),
            replacing(good, ["futureEnvelope"], with: .bool(true)),
            replacing(good, ["delta"], with: nil), replacing(good, ["delta"], with: .null),
            replacing(good, ["delta", "futureDelta"], with: .bool(true)),
            replacing(good, ["delta", "nativeSync"], with: fixture()["nativeSync"]),
            replacing(good, ["nativeWatchPatches"], with: .array([])),
            replacing(good, ["nativeWatchPatches", "unknown"], with: watch(1)),
            replacing(good, ["nativeWatchPatches", "Owner"], with: watch(1)),
            replacing(good, ["nativeWatchPatches", "owner"], with: .object([:])),
            replacing(good, ["nativeWatchPatches", "owner", "log"], with: .array([])),
            replacing(good, ["nativeWatchPatches", "owner", "log", "episode"], with: .null),
            replacing(good, ["nativeWatchPatches", "owner", "identityLinks"], with: .array([.integer(2)])),
            replacing(good, ["accountSlotWatchPatches", "owner"], with: .object(["missing": watch(1)])),
            replacing(good, ["accountSlotWatchPatches", "owner"], with: .object(["own:retained": watch(1)])),
            replacing(good, ["accountSlotWatchPatches", "owner"], with: .object([:])),
            replacing(good, ["accountSlotWatchPatches", "owner"], with: .object(["shared": watch(1), "own:retained": watch(1)])),
            replacing(good, ["accountSlotWatchPatches", "unknown"], with: .object(["shared": watch(1)])),
            replacing(good, ["snapshot"], with: fixture())]
        for number in [VortxJSON.integer(-1), .unsigned(9_007_199_254_740_992), .unsigned(UInt64.max),
                                 .number(1), .number(1.5), .bool(true), .string("1"), .null] {
            invalid.append(replacing(good, ["revision"], with: number))
            invalid.append(replacing(good, ["baseRevision"], with: number))
        }
        for wire in invalid {
            rejects("malformed envelope or target") { _ = try applier.prepare(wire, currentBinding: binding) }
            check(same(applier.snapshot, fixture()) && applier.cursor.revision == 0)
        }
        // A valid first patch followed by an invalid slot path must not publish a partial change.
        let partial = replacing(good, ["accountSlotWatchPatches", "owner", "shared", "contexts"], with: .null)
        rejects("atomic rejection after valid native patch") { _ = try applier.prepare(partial, currentBinding: binding) }
        check(same(applier.snapshot, fixture()) && applier.cursor.revision == 0)
        for path in [["nativeSync", "watches", "owner"], ["nativeSync", "accountSlots", "owner", "slots", "shared", "watch"]] {
            let missing = try prepared(replacing(fixture(), path, with: nil))
            rejects("missing incumbent patch path") { _ = try missing.prepare(good, currentBinding: binding) }
        }
        let duplicateAccount = replacing(fixture(), ["nativeSync", "accountSlots", "owner", "slots", "own:retained", "account"],
            with: fixture()["nativeSync"]?["accountSlots"]?["owner"]?["activeBinding"]?["account"])
        rejects("two slots claim the selected account") {
            let ambiguous = try prepared(duplicateAccount)
            _ = try ambiguous.prepare(good, currentBinding: binding)
        }
        rejects("missing selected account") {
            let unbound = try prepared(replacing(fixture(), ["nativeSync", "accountSlots", "owner", "activeBinding", "account"], with: nil))
            _ = try unbound.prepare(good, currentBinding: binding)
        }
        let boundary = try applier.prepare(envelope(base: 0, revision: 9_007_199_254_740_991), currentBinding: binding)
        check(boundary.cursor.revision == 9_007_199_254_740_991)
    }

    static func replacementAndUpsertTests() throws {
        let applier = try prepared()
        let newProfile: VortxJSON = .object(["id": .string("new"), "owner": .bool(false), "deleted": .bool(false),
                                            "opaqueProfile": .array([.null, .string("exact")])])
        let newLibrary: VortxJSON = .object(["opaqueLibrary": .integer(44)])
        let delta: VortxJSON = .object(["profiles": .array([newProfile]), "libraries": .object(["new": newLibrary]),
                                      "activeProfileId": .string("new")])
        let candidate = try applier.prepare(envelope(base: 0, revision: 1, delta: delta), currentBinding: binding)
        var expected = replacing(fixture(), ["roster", "profiles", "new"], with: newProfile)
        expected = replacing(expected, ["libraries", "new"], with: newLibrary)
        expected = replacing(expected, ["activeProfileId"], with: .string("new"))
        check(same(candidate.snapshot, expected))
        for bad in [
            VortxJSON.object(["profiles": .array([newProfile, newProfile])]),
            .object(["profiles": .array([.object(["id": .string("owner"), "owner": .bool(false)])])]),
            .object(["libraries": .object(["unknown": .object([:])])]),
            .object(["activeProfileId": .string("unknown")]),
            .object(["nativeSync": .null]),
            .object(["accountLibraryArchives": .array([])]),
            .object(["projectedAccountSlots": .object(["owner": .integer(1)])])
        ] {
            rejects("invalid upsert/replacement") { _ = try applier.prepare(envelope(base: 0, revision: 1, delta: bad), currentBinding: binding) }
        }
        let replacementSync = replacing(fixture()["nativeSync"]!, ["futureSync"], with: .string("new-opaque-value"))
        let replacementArchives: VortxJSON = .object(["owner": .object(["archive-2": .object(["opaque": .bool(true)])])])
        let replacementProjection: VortxJSON = .object(["owner": .string("shared")])
        let replacements: VortxJSON = .object(["nativeSync": replacementSync,
            "accountLibraryArchives": replacementArchives, "projectedAccountSlots": replacementProjection])
        let replaced = try applier.prepare(envelope(base: 0, revision: 1, delta: replacements), currentBinding: binding)
        check(same(replaced.snapshot["nativeSync"], replacementSync))
        check(same(replaced.snapshot["accountLibraryArchives"], replacementArchives))
        check(same(replaced.snapshot["futureHost"], fixture()["futureHost"]))
        check(same(applier.snapshot, fixture()) && applier.cursor.revision == 0)
    }

    static let nfc = "caf\u{00e9}"
    static let nfd = "cafe\u{0301}"
    static func at(_ value: VortxJSON, _ path: [String]) -> VortxJSON {
        path.reduce(value) { $0[$1]! }
    }
    static func rekey(_ value: VortxJSON, _ path: [String], from old: String, to new: String) -> VortxJSON {
        guard case .object(var fields) = at(value, path), let index = fields.index(forKey: old) else {
            preconditionFailure("missing authored key")
        }
        check(Array(fields[index].key.utf8) == Array(old.utf8))
        let entry = fields.remove(at: index).value // Remove first so Dictionary cannot retain an alias spelling.
        fields[new] = entry
        return replacing(value, path, with: .object(fields))
    }
    static func unicodeFixture() -> VortxJSON {
        var result = fixture()
        for path in [["roster", "profiles"], ["libraries"], ["nativeSync", "profiles"],
                     ["nativeSync", "watches"], ["nativeSync", "accountSlots"],
                     ["accountLibraryArchives"], ["projectedAccountSlots"]] {
            result = rekey(result, path, from: "owner", to: nfc)
        }
        result = replacing(result, ["roster", "profiles", nfc, "id"], with: .string(nfc))
        result = replacing(result, ["activeProfileId"], with: .string(nfc))
        result = replacing(result, ["nativeSync", "scope"], with: .string("account-" + nfc))
        result = replacing(result, ["nativeSync", "ownerProfileId"], with: .string(nfc))
        result = replacing(result, ["nativeSync", "accountSlots", nfc, "activeBinding", "account", "value"], with: .string(nfc))
        result = replacing(result, ["nativeSync", "accountSlots", nfc, "slots", "shared", "account", "value"], with: .string(nfc))
        result = rekey(result, ["nativeSync", "accountSlots", nfc, "slots"], from: "shared", to: nfc)
        result = replacing(result, ["projectedAccountSlots", nfc], with: .string(nfc))
        result = rekey(result, ["accountLibraryArchives", nfc], from: "own:retained", to: nfc)
        return result
    }
    static var unicodeBinding: Applier.Binding {
        .init(scope: .init(account: "account-" + nfc, ownerProfileID: nfc),
              ownerGeneration: binding.ownerGeneration, handleGeneration: binding.handleGeneration)
    }
    static func bound(_ state: VortxJSON, binding: Applier.Binding, session: String,
                      initial: VortxJSON? = nil) throws -> Applier {
        try Applier(binding: binding, session: session, expectedSnapshot: state,
            negotiationResponse: .object(["ok": .bool(true)]),
            initialEnvelope: initial ?? replacing(base(state), ["session"], with: .string(session)))
    }
    static func rejectUnchanged(_ label: String, applier: Applier, wire: VortxJSON, binding: Applier.Binding) {
        let before = byteImage(applier.snapshot), oldSession = Array(applier.cursor.session.utf8)
        let revision = applier.cursor.revision
        rejects(label) { _ = try applier.prepare(wire, currentBinding: binding) }
        check(byteImage(applier.snapshot) == before)
        check(Array(applier.cursor.session.utf8) == oldSession && applier.cursor.revision == revision)
    }

    static func unicodeSessionAndBindingTests() throws {
        // This independent check proves the fixture is byte-distinct without relying on String ==.
        check(Array(nfc.utf8) != Array(nfd.utf8))
        let state = unicodeFixture(), owner = unicodeBinding, session = "session-" + nfc
        let wrongSession = "session-" + nfd
        var applier = try bound(state, binding: owner, session: session)
        check(same(applier.snapshot, state) && Array(applier.cursor.session.utf8) == Array(session.utf8))
        check(Applier.Cursor(session: session, revision: 0) != Applier.Cursor(session: wrongSession, revision: 0),
              label: "unicode_cursor_session_bytes", line: #line)
        let wrongBase = replacing(base(state), ["session"], with: .string(wrongSession))
        rejects("NFD initial session") { _ = try bound(state, binding: owner, session: session, initial: wrongBase) }
        let idle = replacing(envelope(base: 0, revision: 0), ["session"], with: .string(session))
        rejectUnchanged("NFD later session", applier: applier,
                        wire: replacing(idle, ["session"], with: .string(wrongSession)), binding: owner)
        let candidate = try applier.prepare(idle, currentBinding: owner)
        let foreignScopes = [VortxAccountScope(account: "account-" + nfd, ownerProfileID: nfc),
                             .init(account: owner.scope.account, ownerProfileID: nfd)]
        var callbacks = 0
        for scope in foreignScopes {
            let foreign = Applier.Binding(scope: scope, ownerGeneration: owner.ownerGeneration, handleGeneration: owner.handleGeneration)
            check(Array(foreign.scope.account.utf8) != Array(owner.scope.account.utf8)
                || Array(foreign.scope.ownerProfileID.utf8) != Array(owner.scope.ownerProfileID.utf8))
            check(foreign != owner)
            rejectUnchanged("same-generation Unicode scope prepare", applier: applier, wire: idle, binding: foreign)
            rejects("same-generation Unicode scope complete") {
                try applier.complete(candidate, currentBinding: { foreign }) { _ in callbacks += 1 }
            }
            rejects("same-generation Unicode scope discard") { try applier.discard(candidate, currentBinding: foreign) }
            check(callbacks == 0 && same(applier.snapshot, state) && applier.cursor.revision == 0)
        }
        try applier.complete(candidate, currentBinding: { owner }) { _ in callbacks += 1 }
        check(callbacks == 1 && same(applier.snapshot, state))
        rejects("Unicode idle completion replay") { try applier.complete(candidate, currentBinding: { owner }) { _ in callbacks += 1 } }
        let discard = try applier.prepare(idle, currentBinding: owner)
        try applier.discard(discard, currentBinding: owner)
        rejects("Unicode idle discarded completion") { try applier.complete(discard, currentBinding: { owner }) { _ in callbacks += 1 } }
        check(callbacks == 1 && same(applier.snapshot, state) && applier.cursor.revision == 0)
    }

    static func exactBaseAndIdleValueTests() throws {
        let opaque: VortxJSON = .object(["nested": .array([.object([nfc: .string(nfc)])])])
        let state = replacing(fixture(), ["nativeSync", "futureSync"], with: opaque)
        let applier = try prepared(state)
        let changedValue: VortxJSON = .object(["nested": .array([.object([nfc: .string(nfd)])])])
        let changedKey: VortxJSON = .object(["nested": .array([.object([nfd: .string(nfc)])])])
        for changed in [changedValue, changedKey] {
            check(byteImage(opaque) != byteImage(changed))
            let changedState = replacing(state, ["nativeSync", "futureSync"], with: changed)
            rejects("byte-only changed initial base") {
                _ = try bound(state, binding: binding, session: session, initial: base(changedState))
            }
            let delta: VortxJSON = .object(["nativeSync": changedState["nativeSync"]!])
            rejectUnchanged("byte-only equal-revision mutation", applier: applier,
                            wire: envelope(base: 0, revision: 0, delta: delta), binding: binding)
        }
        let sameState = try prepared(state)
        check(byteImage(sameState.snapshot) == byteImage(state))
        _ = try applier.prepare(envelope(base: 0, revision: 0), currentBinding: binding)
        // Case tags, array order/cardinality and signed zero are conservation data too.
        let pairs: [(VortxJSON, VortxJSON)] = [(.integer(1), .unsigned(1)), (.integer(1), .number(1)),
            (.number(0.0), .number(-0.0)), (.array([.integer(1), .integer(2)]), .array([.integer(2), .integer(1)])),
            (.array([.null]), .array([.null, .null])), (.object([nfc: .null]), .object([nfc: .null, "extra": .null]))]
        for (before, after) in pairs {
            check(byteImage(before) != byteImage(after))
            let expected = replacing(fixture(), ["nativeSync", "futureSync"], with: before)
            let changed = replacing(expected, ["nativeSync", "futureSync"], with: after)
            rejects("case/order/bit-pattern changed base") {
                _ = try bound(expected, binding: binding, session: session, initial: base(changed))
            }
            let exact = try prepared(expected)
            rejectUnchanged("case/order/bit-pattern changed idle", applier: exact,
                wire: envelope(base: 0, revision: 0, delta: .object(["nativeSync": changed["nativeSync"]!])), binding: binding)
        }
    }

    static func unicodeReferenceTests() throws {
        let state = unicodeFixture(), owner = unicodeBinding
        let applier = try bound(state, binding: owner, session: session)
        // Bad references must reject even if expected and base are the same malformed value.
        var badBases = [
            replacing(state, ["nativeSync", "scope"], with: .string("account-" + nfd)),
            replacing(state, ["nativeSync", "ownerProfileId"], with: .string(nfd)),
            replacing(state, ["roster", "profiles", nfc, "id"], with: .string(nfd)),
            replacing(state, ["activeProfileId"], with: .string(nfd)),
            replacing(state, ["projectedAccountSlots", nfc], with: .string(nfd))]
        for path in [["roster", "profiles"], ["libraries"], ["nativeSync", "profiles"], ["nativeSync", "watches"],
                     ["nativeSync", "accountSlots"], ["accountLibraryArchives"], ["projectedAccountSlots"]] {
            badBases.append(rekey(state, path, from: nfc, to: nfd))
        }
        for bad in badBases {
            check(byteImage(bad) != byteImage(state))
            rejects("Unicode base scope/reference") { _ = try bound(bad, binding: owner, session: session) }
        }
        let aliasProfile: VortxJSON = .object(["id": .string(nfd), "owner": .bool(true), "deleted": .bool(false)])
        let newNFC: VortxJSON = .object(["id": .string("new-" + nfc), "owner": .bool(false)])
        let newNFD: VortxJSON = .object(["id": .string("new-" + nfd), "owner": .bool(false)])
        let deltas: [VortxJSON] = [
            .object(["profiles": .array([aliasProfile])]),
            .object(["profiles": .array([newNFC, newNFD])]),
            .object(["libraries": .object([nfd: .object([:])])]),
            .object(["activeProfileId": .string(nfd)]),
            .object(["accountLibraryArchives": .object([nfd: .object([:])])]),
            .object(["accountLibraryArchives": .object([nfc: .object([nfd: .object([:])])])]),
            .object(["projectedAccountSlots": .object([nfd: .string(nfc)])]),
            .object(["projectedAccountSlots": .object([nfc: .string(nfd)])])]
        for delta in deltas {
            rejectUnchanged("Unicode upsert/reference", applier: applier,
                            wire: envelope(base: 0, revision: 1, delta: delta), binding: owner)
        }
        let watchAlias = replacing(envelope(base: 0, revision: 1), ["nativeWatchPatches"], with: .object([nfd: watch(200)]))
        rejectUnchanged("Unicode native watch key", applier: applier, wire: watchAlias, binding: owner)
        for patches in [VortxJSON.object([nfd: .object([nfc: watch(200)])]), .object([nfc: .object([nfd: watch(200)])])] {
            rejectUnchanged("Unicode selected-slot path", applier: applier,
                wire: replacing(envelope(base: 0, revision: 1), ["accountSlotWatchPatches"], with: patches), binding: owner)
        }
        var badSyncs = [
            replacing(state["nativeSync"]!, ["scope"], with: .string("account-" + nfd)),
            replacing(state["nativeSync"]!, ["ownerProfileId"], with: .string(nfd)),
            replacing(state["nativeSync"]!, ["profiles", nfc, "profile"], with: .object(["id": .string(nfd)]))]
        for path in [["profiles"], ["watches"], ["accountSlots"], ["accountSlots", nfc, "slots"]] {
            badSyncs.append(rekey(state["nativeSync"]!, path, from: nfc, to: nfd))
        }
        for sync in badSyncs {
            rejectUnchanged("Unicode reconstructed scope/reference", applier: applier,
                wire: envelope(base: 0, revision: 1, delta: .object(["nativeSync": sync])), binding: owner)
        }
        // A valid exact Unicode target changes only its complete named watch documents.
        var exactWire = replacing(envelope(base: 0, revision: 1), ["nativeWatchPatches"], with: .object([nfc: watch(200)]))
        exactWire = replacing(exactWire, ["accountSlotWatchPatches"], with: .object([nfc: .object([nfc: watch(200)])]))
        let good = try applier.prepare(exactWire, currentBinding: owner)
        var expected = replacing(state, ["nativeSync", "watches", nfc], with: watch(200))
        expected = replacing(expected, ["nativeSync", "accountSlots", nfc, "slots", nfc, "watch"], with: watch(200))
        check(byteImage(good.snapshot) == byteImage(expected))
    }

    static func unicodeSelectedAccountTests() throws {
        let state = unicodeFixture(), owner = unicodeBinding
        let applier = try bound(state, binding: owner, session: session)
        let accountPath = ["nativeSync", "accountSlots", nfc, "activeBinding", "account"]
        let selectedPath = ["nativeSync", "accountSlots", nfc, "slots", nfc, "account"]
        let foreign = replacing(state, accountPath + ["value"], with: .string(nfd))
        check(byteImage(at(foreign, accountPath)) != byteImage(at(state, selectedPath)))
        let ambiguous = replacing(state, ["nativeSync", "accountSlots", nfc, "slots", "own:retained", "account"],
                                  with: at(state, selectedPath))
        for bad in [foreign, ambiguous] {
            rejects("canonical-only or ambiguous selected account base") { _ = try bound(bad, binding: owner, session: session) }
            rejectUnchanged("canonical-only or ambiguous selected account replacement", applier: applier,
                wire: envelope(base: 0, revision: 1, delta: .object(["nativeSync": bad["nativeSync"]!])), binding: owner)
        }
        // Recursive selected-account keys are exact, not just its visible account string value.
        let identity: VortxJSON = .object(["kind": .string("own"), "value": .string(nfc), "future": .object([nfc: .null])])
        var withExtension = replacing(state, accountPath, with: identity)
        withExtension = replacing(withExtension, selectedPath, with: identity)
        let exact = try bound(withExtension, binding: owner, session: session)
        let aliasIdentity: VortxJSON = .object(["kind": .string("own"), "value": .string(nfc), "future": .object([nfd: .null])])
        let mismatch = replacing(withExtension, selectedPath, with: aliasIdentity)
        check(byteImage(identity) != byteImage(aliasIdentity))
        rejectUnchanged("selected-account nested key spelling", applier: exact,
            wire: envelope(base: 0, revision: 1, delta: .object(["nativeSync": mismatch["nativeSync"]!])), binding: owner)
    }

    static var retainedID: String { "retired-" + nfc }
    static var retainedLibrary: VortxJSON {
        // Plausible library/default field shapes plus intentional opaque seam extensions.
        .object(["items": .array([]), "history": .array([]), "continueWatching": .array([]),
                 "resume": .object([:]), "watched": .object([:]), "searchHistory": .array([.string(nfc), .string(nfd)]),
                 "watchLog": watch(870)["log"]!, "watchContexts": watch(870)["contexts"]!,
                 "futureArchive": .object([nfc: .array([.unsigned(UInt64.max), .null])])])
    }
    static func retainedMetadataFixture() -> VortxJSON {
        var state = replacing(fixture(), ["accountLibraryArchives", retainedID],
                              with: .object([nfc: retainedLibrary]))
        state = replacing(state, ["projectedAccountSlots", retainedID], with: .string("shared"))
        state = replacing(state, ["futureHost", "pending"], with: .array([.object([
            "id": .string(nfd), "intent": .string("retain"), "history": .array([.integer(4), .integer(3)])])]))
        return state
    }

    static func retainedMetadataTests() throws {
        // Synthetic decoded snapshots model producer-retained topology, not native SDK fixtures.
        // Schema 1 omits accountSlots; schema 2 has an empty map. Neither has a current owner slot.
        for schema in [Int64(1), Int64(2)] {
            var state = replacing(fixture(), ["nativeSync", "schemaVersion"], with: .integer(schema))
            state = replacing(state, ["nativeSync", "accountSlots"], with: schema == 1 ? nil : .object([:]))
            state = replacing(state, ["nativeSync", "legacyImport"], with: nil)
            state = replacing(state, ["nativeSync", "websiteAddonReceipts"], with: nil)
            var applier: Applier
            do { applier = try prepared(state) }
            catch { fail("unexpected_error", label: "retained_no_collection_base_schema_\(schema)", line: #line) }
            check(byteImage(applier.snapshot) == byteImage(state) && applier.cursor.revision == 0)
            let idle = try applier.prepare(envelope(base: 0, revision: 0), currentBinding: binding)
            check(byteImage(idle.snapshot) == byteImage(state))
            try applier.complete(idle, currentBinding: { binding }) { _ in }
            check(byteImage(applier.snapshot) == byteImage(state) && applier.cursor.revision == 0)
            // Metadata is not authority to manufacture an actual selected-slot patch target.
            rejectUnchanged("retained projection without a slot collection", applier: applier,
                            wire: envelope(base: 0, revision: 1, position: 150), binding: binding)
            let wire = replacing(envelope(base: 0, revision: 1), ["nativeWatchPatches"],
                                 with: .object(["owner": watch(150)]))
            let candidate = try applier.prepare(wire, currentBinding: binding)
            let expected = replacing(state, ["nativeSync", "watches", "owner"], with: watch(150))
            check(byteImage(candidate.snapshot) == byteImage(expected))
            check(byteImage(applier.snapshot) == byteImage(state) && applier.cursor.revision == 0)
            try applier.complete(candidate, currentBinding: { binding }) { _ in }
            check(byteImage(applier.snapshot) == byteImage(expected) && applier.cursor.revision == 1)
        }

        // Both independent maps may retain a non-alias ID absent from roster/native accounts.
        let state = retainedMetadataFixture()
        check(state["roster"]?["profiles"]?[retainedID] == nil)
        check(state["nativeSync"]?["accountSlots"]?[retainedID] == nil)
        var applier = try prepared(state)
        check(byteImage(applier.snapshot) == byteImage(state))
        let idle = try applier.prepare(envelope(base: 0, revision: 0), currentBinding: binding)
        check(byteImage(idle.snapshot) == byteImage(state))
        try applier.complete(idle, currentBinding: { binding }) { _ in }
        check(byteImage(applier.snapshot) == byteImage(state) && applier.cursor.revision == 0)
        // An unrelated valid selected-slot mutation must retain archives/history/pending/opaque data.
        let mutation = try applier.prepare(envelope(base: 0, revision: 1, position: 160), currentBinding: binding)
        var expected = replacing(state, ["nativeSync", "watches", "owner"], with: watch(160))
        expected = replacing(expected, ["nativeSync", "accountSlots", "owner", "slots", "shared", "watch"], with: watch(160))
        check(byteImage(mutation.snapshot) == byteImage(expected))
        check(byteImage(applier.snapshot) == byteImage(state) && applier.cursor.revision == 0)
        try applier.complete(mutation, currentBinding: { binding }) { _ in }
        check(byteImage(applier.snapshot) == byteImage(expected) && applier.cursor.revision == 1)

        // Full metadata replacements can contain retained absent IDs, and intentionally omit old keys.
        let archives: VortxJSON = .object([retainedID: .object([nfc: retainedLibrary])])
        let projected: VortxJSON = .object([retainedID: .string("shared")])
        let delta: VortxJSON = .object(["accountLibraryArchives": archives, "projectedAccountSlots": projected])
        let replacement = try applier.prepare(envelope(base: 1, revision: 2, delta: delta), currentBinding: binding)
        expected = replacing(expected, ["accountLibraryArchives"], with: archives)
        expected = replacing(expected, ["projectedAccountSlots"], with: projected)
        check(byteImage(replacement.snapshot) == byteImage(expected))
        check(replacement.snapshot["accountLibraryArchives"]?["owner"] == nil)
        check(replacement.snapshot["projectedAccountSlots"]?["owner"] == nil)
        try applier.complete(replacement, currentBinding: { binding }) { _ in }
        check(byteImage(applier.snapshot) == byteImage(expected) && applier.cursor.revision == 2)

        // Missing and explicitly null nativeSync are admitted by the existing outer validator.
        let legacyDocuments: [VortxJSON?] = [nil, .null]
        for sync in legacyDocuments {
            let legacy = replacing(state, ["nativeSync"], with: sync)
            var local = try prepared(legacy)
            let idle = try local.prepare(envelope(base: 0, revision: 0), currentBinding: binding)
            check(byteImage(idle.snapshot) == byteImage(legacy))
            try local.complete(idle, currentBinding: { binding }) { _ in }
            check(byteImage(local.snapshot) == byteImage(legacy) && local.cursor.revision == 0)
            rejectUnchanged("retained metadata without native document", applier: local,
                            wire: envelope(base: 0, revision: 1, position: 170), binding: binding)
            let library = replacing(legacy["libraries"]!["owner"]!, ["futureLibrary"], with: .string("changed"))
            let change: VortxJSON = .object(["libraries": .object(["owner": library])])
            let candidate = try local.prepare(envelope(base: 0, revision: 1, delta: change), currentBinding: binding)
            let expected = replacing(legacy, ["libraries", "owner"], with: library)
            check(byteImage(candidate.snapshot) == byteImage(expected))
            try local.complete(candidate, currentBinding: { binding }) { _ in }
            check(byteImage(local.snapshot) == byteImage(expected) && local.cursor.revision == 1)
        }

        // Truly absent targets above are distinct from canonical-only retained key hits.
        let incumbent = try prepared(state), aliasID = "retired-" + nfd
        check(Array(retainedID.utf8) != Array(aliasID.utf8))
        let aliases: [VortxJSON] = [
            .object(["accountLibraryArchives": .object([aliasID: .object([nfc: retainedLibrary])])]),
            .object(["projectedAccountSlots": .object([aliasID: .string("shared")])]),
            .object(["accountLibraryArchives": .object([retainedID: .object([nfd: retainedLibrary])])])]
        for alias in aliases {
            rejectUnchanged("canonical-only retained metadata key", applier: incumbent,
                            wire: envelope(base: 0, revision: 1, delta: alias), binding: binding)
        }
        // Earlier unicodeReferenceTests pair actual roster/collection/slot alias failures with
        // exact non-ASCII success. No positive claim is made for a normalized populated current
        // collection whose projected slot is missing; the producer refreshes that relationship.
    }

    static func main() {
        let groups: [(String, () throws -> Void)] = [
            ("negotiationAndBaseTests", negotiationAndBaseTests),
            ("preservationAndCompletionTests", preservationAndCompletionTests),
            ("cursorAndIdentityTests", cursorAndIdentityTests),
            ("malformedEnvelopeAndRollbackTests", malformedEnvelopeAndRollbackTests),
            ("replacementAndUpsertTests", replacementAndUpsertTests),
            ("unicodeSessionAndBindingTests", unicodeSessionAndBindingTests),
            ("exactBaseAndIdleValueTests", exactBaseAndIdleValueTests),
            ("unicodeReferenceTests", unicodeReferenceTests),
            ("unicodeSelectedAccountTests", unicodeSelectedAccountTests),
            ("retainedMetadataTests", retainedMetadataTests)]
        for (index, group) in groups.enumerated() {
            diagnostic("group start \(index + 1)/\(groups.count) \(group.0)")
            do { try group.1() }
            catch { fail("unexpected_error", label: group.0, line: #line) }
            diagnostic("group pass \(index + 1)/\(groups.count) \(group.0)")
        }
        diagnostic("groups passed=\(groups.count) total=\(groups.count)")
        diagnostic("Unwired decoded-value delta applier source-unit fixtures passed")
    }
}
