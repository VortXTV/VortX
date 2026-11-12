import Foundation

enum NativeWebsiteRosterPublicationReceiptTests {
    typealias Receipt = NativeWebsiteRosterPublicationReceipt

    static func run() throws {
        let account = "account.20000000-0000-4000-8000-000000000041"
        let foreign = "account.20000000-0000-4000-8000-000000000042"
        let key = Data(repeating: 41, count: 32)
        let wrongKey = Data(repeating: 42, count: 32)
        let original = Data(#"{"addons":[],"future":{"integer":9007199254740993,"decimal":1.2300e+2}}"#.utf8)
        let reserialized = Data(#"{"addons":[],"future":{"integer":9007199254740993,"decimal":123}}"#.utf8)
        let candidate = Data(#"{"addons":[],"vortx":{"roster":[{"name":"Fixture"}],"rosterModified":0}}"#.utf8)
        let independent = Data(#"{"addons":[],"vortx":{"roster":[{"name":"Peer"}],"rosterModified":0}}"#.utf8)

        func pending(_ revision: Int = 40, _ source: Data? = nil, _ projected: Data? = nil,
                     owner: String? = nil, key bytes: Data? = nil) throws -> Receipt {
            try Receipt.pending(accountNamespace: owner ?? account, dataKey: bytes ?? key, baseRevision: revision,
                                source: source ?? original, candidate: projected ?? candidate)
        }
        func decode(_ wire: String, owner: String? = nil, key bytes: Data? = nil) throws -> Receipt {
            try Receipt.decode(wire, accountNamespace: owner ?? account, dataKey: bytes ?? key)
        }
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { fatalError(label) }
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body() } catch { return }
            fatalError(label)
        }

        let first = try pending()
        let slot = try Receipt.storageSlot(accountNamespace: account, dataKey: key)
        try check(slot != Receipt.storageSlot(accountNamespace: account, dataKey: wrongKey), "A rekey gets an independent receipt slot")
        try check(slot != Receipt.storageSlot(accountNamespace: foreign, dataKey: key), "Accounts cannot share receipt slots")
        let wire = first.encode()
        let reopened = try decode(wire)
        try check(reopened == first && reopened.state == .pending, "Pending receipt round trip")
        try check(reopened.baseRevision == 40 && reopened.targetRevision == 41, "Exact successor")
        try check(!wire.contains("addons") && !wire.contains(account), "Only fixed record fields")
        try check(try reopened.permitsAttempt(pending(), accountNamespace: account, dataKey: key), "Exact pending retry")
        try check(try !reopened.permitsAttempt(pending(41, original), accountNamespace: account, dataKey: key),
                  "Pending forbids higher revision with same bytes")
        try check(try !reopened.permitsAttempt(pending(40, reserialized), accountNamespace: account, dataKey: key),
                  "Pending forbids rewritten source")
        try check(try !reopened.permitsAttempt(pending(40, original, independent), accountNamespace: account, dataKey: key),
                  "Pending forbids replacement candidate")
        try check(try !reopened.permitsAttempt(pending(41, reserialized), accountNamespace: account, dataKey: key),
                  "Pending forbids higher changed attempt")
        try check(reopened.classifyFullRosterReadback(revision: 41, raw: candidate) == .exactCandidate, "Pending exact target")
        try check(reopened.classifyFullRosterReadback(revision: 41, raw: independent) == .denied, "Pending ambiguous target")
        try check(reopened.classifyFullRosterReadback(revision: 42, raw: independent) == .requiresIndependentAdmission,
                  "Higher full roster needs own admission")
        try check(reopened.classifyFullRosterReadback(revision: 40, raw: candidate) == .denied, "Stale full roster")
        try check(reopened.classifyFullRosterReadback(revision: 42, raw: Data()) == .denied, "Empty full roster bytes")

        let rejected = try decode(reopened.markingDefinitivelyRejected(accountNamespace: account, dataKey: key).encode())
        try check(rejected.state == .definitivelyRejected && rejected.baseRevision == 40 && rejected.targetRevision == 41,
                  "Rejection retains exact attempt")
        try check(rejected.classifyFullRosterReadback(revision: 41, raw: independent) == .requiresIndependentAdmission,
                  "Definitive rejection can observe a different winner at its target")
        try check(rejected.classifyFullRosterReadback(revision: 41, raw: candidate) == .exactCandidate,
                  "Matching target remains detectable")
        try check(try rejected.permitsAttempt(pending(41, original), accountNamespace: account, dataKey: key),
                  "Rejected permits actual newer revision with identical bytes")
        try check(try rejected.permitsAttempt(pending(41, reserialized, independent), accountNamespace: account, dataKey: key),
                  "Rejected permits actual newer revised document")
        try check(try !rejected.permitsAttempt(pending(40, reserialized), accountNamespace: account, dataKey: key),
                  "Rejected cannot relabel changed bytes at original revision")
        try check(try !rejected.permitsAttempt(pending(), accountNamespace: account, dataKey: key),
                  "Definitive rejection cannot be undone by a rolled-back read")
        try check(try !rejected.permitsAttempt(pending(39), accountNamespace: account, dataKey: key), "Rejected cannot go backward")
        try check(try rejected.markingDefinitivelyRejected(accountNamespace: account, dataKey: key) == rejected, "Idempotent rejection")

        let ahead = try decode(reopened.markingDefinitivelyRejected(accountNamespace: account, dataKey: key, storedRevision: 50).encode())
        try check(ahead.minimumReadbackRevision == 50 && ahead.targetRevision == 41, "Rejection bounds readback without moving target")
        try check(ahead.classifyFullRosterReadback(revision: 41, raw: candidate) == .denied, "Known stale exact target cannot mount after restart")
        try check(ahead.classifyFullRosterReadback(revision: 50, raw: independent) == .requiresIndependentAdmission,
                  "First acceptable revision still needs independent admission")
        try check(try !ahead.permitsAttempt(pending(49), accountNamespace: account, dataKey: key), "Stale rosterless read cannot send")
        try check(try ahead.permitsAttempt(pending(50), accountNamespace: account, dataKey: key), "Authenticated head can be readmitted")

        rejects("Account binding") { _ = try decode(wire, owner: foreign) }
        rejects("Data-key binding") { _ = try decode(wire, key: wrongKey) }
        rejects("Transition cannot re-key") { _ = try reopened.markingDefinitivelyRejected(accountNamespace: account, dataKey: wrongKey) }
        rejects("Cross-account next attempt") {
            _ = try reopened.permitsAttempt(pending(owner: foreign), accountNamespace: account, dataKey: key)
        }
        rejects("Cross-key next attempt") {
            _ = try reopened.permitsAttempt(pending(key: wrongKey), accountNamespace: account, dataKey: key)
        }
        let malformed = [
            wire.replacingOccurrences(of: "v1:p:", with: "v1:r:"),
            wire.replacingOccurrences(of: "v1:p:40:", with: "v1:p:040:"),
            wire.replacingOccurrences(of: "v1:p:40:41:", with: "v1:p:40:42:"),
            wire.replacingOccurrences(of: "v1:p:40:41:41:", with: "v1:p:40:41:50:"),
            String(wire.dropLast()) + (wire.last == "0" ? "1" : "0"),
            wire + ":extra", wire.uppercased(), " " + wire, "",
        ]
        for value in malformed { rejects("Noncanonical or modified record") { _ = try decode(value) } }
        rejects("Wrong data key length") { _ = try pending(key: Data(repeating: 0, count: 31)) }
        rejects("Noncanonical account") { _ = try pending(owner: account.uppercased()) }
        rejects("Negative base") { _ = try pending(-1) }
        rejects("Overflowing safe-integer target") { _ = try pending(9_007_199_254_740_991) }
        rejects("Missing source") { _ = try pending(40, Data()) }
        rejects("Missing candidate") { _ = try pending(40, original, Data()) }
        let zero = try pending(0), last = try pending(9_007_199_254_740_990)
        try check(zero.targetRevision == 1 && last.targetRevision == 9_007_199_254_740_991, "Real row at zero and upper bound")
        try check(try decode(last.encode()) == last, "Maximum-size encoding")
        print("Website roster publication receipt: authentic restart, exact retry, definitive rejection and readback passed")
    }
}
