import Foundation

private final class OwnerSourceAuthority: VortxMutationAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func invalidate() { lock.withLock { active = false } }
    func withActive(_ operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw VortxNativeError.superseded }
            try operation()
        }
    }
}
private final class OwnerSourceCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Source-unit regressions using real production capture, archive inspector,
/// account binding reader and HTTP request builder. Injected transport never reaches a network.
@main enum VortxNativeOwnerHistorySourceTests {
    typealias Source = VortxNativeOwnerHistorySource
    static let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let child = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let scope = VortxAccountScope(account: "synthetic.owner-history", ownerProfileID: owner.uuidString)
    static let uid = "synthetic-owner"
    static let token = "synthetic-private-token"
    static let raw = Data(#" { "result" : [{"_id":"tt1","type":"movie","name":"Café","future":{"clock":1e3},"state":{"timeOffset":1234,"lastWatched":"2024-01-01T00:00:00.000Z","watched":"opaque-retained"}}], "futureTop": [3,2,1] } "#.utf8)
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "owner source fixture line \(line)") }
    static func state(profile: UUID = owner, own: Bool = false, marker: String = "é") -> VortxJSON {
        let ownerAccount: VortxJSON = .object(["kind": .string("local_only")])
        let childAccount: VortxJSON = own ? .object(["kind": .string("own"), "value": .string("different-user")])
            : .object(["kind": .string("shared"), "value": .string(owner.uuidString)])
        return .object([
            "activeProfileId": .string(profile.uuidString),
            "nativeSync": .object(["scope": .string(scope.account), "ownerProfileId": .string(owner.uuidString),
                                   "opaqueNative": .string(marker)]),
            "roster": .object(["profiles": .object([
                owner.uuidString: .object(["owner": .bool(true), "deleted": .bool(false), "account": ownerAccount]),
                child.uuidString: .object(["owner": .bool(false), "deleted": .bool(false), "account": childAccount])
            ])])
        ])
    }
    static func capture(profile: UUID = owner) throws -> Source.Capture {
        try .init(scope: scope, profileID: profile, verifiedUID: uid, state: state(profile: profile))
    }
    private static func fetch(_ bytes: Data = raw, capture: Source.Capture? = nil,
                      authority: OwnerSourceAuthority = OwnerSourceAuthority()) async throws -> Source.Source {
        try await Source.fetch(capture: capture ?? self.capture(), authKey: token, authority: authority,
            verify: { candidate in check(candidate == token); return uid },
            send: { request in
                check(request.url?.absoluteString == "https://api.strem.io/api/datastoreGet")
                check(request.httpMethod == "POST" && request.timeoutInterval == 20)
                let body = try JSONDecoder().decode(VortxJSON.self, from: request.httpBody!)
                check(body["authKey"] == .string(token) && body["collection"] == .string("libraryItem") && body["all"] == .bool(true))
                return .init(data: bytes, statusCode: 200)
            })
    }
    private static func rawCaptureChecks() throws {
        typealias Exact = OwnerHistoryExactJSON
        var root = try Exact.Object(JSONEncoder().encode(state()))
        var native = try Exact.Object(root.required("nativeSync"))
        let history = Data(#"{"futureNumbers":[-0.0,9007199254740993,1e999],"unknown":{"order":[3,1,2]}}"#.utf8)
        native.set("ownerHistory", history)
        root.set("nativeSync", try native.encoded())
        // Deliberately not decodable through the generic Double-backed DTO. This is valid
        // raw JSON, not a reason to drop its evidence or rebuild it from the presentation.
        let bytes = try root.encoded()
        let captured = try Source.Capture(scope: scope, profileID: owner, verifiedUID: uid, snapshotData: bytes)
        check(captured.matches(snapshotData: bytes))
        check(try Exact.Object(captured.nativeDocumentBytes).required("ownerHistory") == Exact.canonical(history))
        check(captured.nativeDocumentBytes.range(of: Data("-0.0".utf8)) != nil)
        check(captured.nativeDocumentBytes.range(of: Data("9007199254740993".utf8)) != nil)
        check(captured.nativeDocumentBytes.range(of: Data("1e999".utf8)) != nil)
        check(captured.accountBindingBytes == (try capture()).accountBindingBytes)

        var changed = native
        changed.set("ownerHistory", Data(#"{"futureNumbers":[0.0,9007199254740993,1e999],"unknown":{"order":[3,1,2]}}"#.utf8))
        var changedRoot = root; changedRoot.set("nativeSync", try changed.encoded())
        check(!captured.matches(snapshotData: try changedRoot.encoded()))
        changed = native; changed.set("pendingUnknown", Data("true".utf8))
        changedRoot = root; changedRoot.set("nativeSync", try changed.encoded())
        check(!captured.matches(snapshotData: try changedRoot.encoded()))
        changedRoot = root; changedRoot.set("activeProfileId", try Exact.string(child.uuidString))
        check(!captured.matches(snapshotData: try changedRoot.encoded()))

        let sharedBytes = try JSONEncoder().encode(state(profile: child))
        let shared = try Source.Capture(scope: scope, profileID: child, verifiedUID: uid, snapshotData: sharedBytes)
        check(shared.profileID == child && shared.ownerProfileID == owner)
        check(shared.matches(snapshotData: sharedBytes))
        for invalid in [try JSONEncoder().encode(state(profile: child, own: true)),
                        Data(#"{"nativeSync":{},"nativeSync":{}}"#.utf8),
                        Data(#"{"nativeSync":{"hidden":1,"\u0068idden":2}}"#.utf8)] {
            do {
                _ = try Source.Capture(scope: scope, profileID: child, verifiedUID: uid, snapshotData: invalid)
                fatalError("invalid raw owner capture admitted")
            } catch {}
        }

        // Native active-binding receipts, not roster appearance, determine the account role.
        var bindingNative = native
        bindingNative.set("accountSlots", Data(#"{"\#(owner.uuidString)":{"activeBinding":{"account":{"kind":"own","value":"foreign"},"revision":1,"transactionId":"synthetic-rebind"}}}"#.utf8))
        var reboundRoot = root; reboundRoot.set("nativeSync", try bindingNative.encoded())
        check(!captured.matches(snapshotData: try reboundRoot.encoded()))

        let canonical = try Exact.canonical(Data(#"{"z":-0.0,"a":[9007199254740993,1e999]}"#.utf8))
        check(canonical == Data(#"{"a":[9007199254740993,1e999],"z":-0.0}"#.utf8))
        for bad in [#"{"x":1,"x":2}"#, #"{"x":01}"#, #"{"x":1.}"#,
                    #"{"x":1e}"#, #"{"x":[1,]}"#, #"{"x":1} trailing"#] {
            do { _ = try Exact.Object(Data(bad.utf8)); fatalError("malformed exact JSON admitted") } catch {}
        }
        print("PASS raw capture keeps original numeric/unknown evidence, binding roles and malformed rejection")
    }

    static func main() async throws {
        let original = try capture()
        check(original.matches(state: state()))
        try rawCaptureChecks()
        check(!original.matches(state: state(marker: "e\u{301}"))) // Swift String equality would miss this change.
        let unicodeScope = VortxAccountScope(account: "synthetic.é", ownerProfileID: owner.uuidString)
        let equivalentButDistinct: VortxJSON = .object([
            "activeProfileId": .string(owner.uuidString),
            "nativeSync": .object(["scope": .string("synthetic.e\u{301}"), "ownerProfileId": .string(owner.uuidString)]),
            "roster": state()["roster"]!
        ])
        do {
            _ = try Source.Capture(scope: unicodeScope, profileID: owner, verifiedUID: uid, state: equivalentButDistinct)
            fatalError("canonically equivalent but byte-distinct account scope admitted")
        } catch Source.Failure.invalidCapture {}
        check(!original.matches(state: state(profile: child)))
        do {
            _ = try Source.Capture(scope: scope, profileID: child, verifiedUID: uid, state: state(profile: child, own: true))
            fatalError("secondary Own account accepted as owner source")
        } catch Source.Failure.invalidCapture {}
        let source = try await fetch()
        check(source.response == raw && source.rowCount == 1)
        check(source.archive.range(of: Data(token.utf8)) == nil)
        let reopened = try Source.decodeArchive(source.archive, scope: scope.account, ownerProfileID: owner, profileID: owner, verifiedUID: uid)
        check(reopened.response == raw && reopened.archive == source.archive)
        check(reopened.sourceDocumentSHA256 == source.sourceDocumentSHA256 && reopened.sourceArchiveSHA256 == source.sourceArchiveSHA256)
        let repeatSource = try await fetch()
        check(repeatSource.archive == source.archive) // No timestamps, random IDs or current clocks.
        let shared = try await fetch(capture: capture(profile: child))
        check(shared.profileID == child && shared.ownerProfileID == owner && shared.response == raw)
        check(shared.archive != source.archive) // Original initiating profile stays in the archive.
        do {
            _ = try Source.decodeArchive(source.archive, scope: scope.account, ownerProfileID: owner, profileID: child, verifiedUID: uid)
            fatalError("retargeted archive accepted")
        } catch Source.Failure.invalidArchive {}

        let calls = OwnerSourceCalls()
        do {
            _ = try await Source.fetch(capture: original, authKey: token, authority: OwnerSourceAuthority(),
                verify: { _ in "another-user" }, send: { _ in calls.increment(); return .init(data: raw, statusCode: 200) })
            fatalError("wrong verified UID accepted")
        } catch Source.Failure.wrongIdentity {}
        check(calls.value == 0)
        let before = OwnerSourceAuthority(); before.invalidate()
        do {
            _ = try await Source.fetch(capture: original, authKey: token, authority: before,
                verify: { _ in calls.increment(); return uid }, send: { _ in calls.increment(); return .init(data: raw, statusCode: 200) })
            fatalError("retired capture reached authentication")
        } catch VortxNativeError.superseded {}
        check(calls.value == 0)
        let duringVerify = OwnerSourceAuthority()
        do {
            _ = try await Source.fetch(capture: original, authKey: token, authority: duringVerify,
                verify: { _ in duringVerify.invalidate(); return uid },
                send: { _ in calls.increment(); return .init(data: raw, statusCode: 200) })
            fatalError("reconnect during authentication reached datastore")
        } catch VortxNativeError.superseded {}
        check(calls.value == 0)
        let duringGet = OwnerSourceAuthority()
        do {
            _ = try await Source.fetch(capture: original, authKey: token, authority: duringGet,
                verify: { _ in uid }, send: { _ in duringGet.invalidate(); return .init(data: raw, statusCode: 200) })
            fatalError("retired datastore response escaped")
        } catch VortxNativeError.superseded {}
        let cancelled = Task {
            try await Source.fetch(capture: original, authKey: token, authority: OwnerSourceAuthority(),
                verify: { _ in withUnsafeCurrentTask { $0?.cancel() }; return uid },
                send: { _ in calls.increment(); return .init(data: raw, statusCode: 200) })
        }
        do { _ = try await cancelled.value; fatalError("cancelled source returned") } catch is CancellationError {}
        check(calls.value == 0)

        for text in [
            #"{"result":[],"result":[{"_id":"hidden"}]}"#,
            #"{"result":[],"authKey":"never-archive"}"#,
            #"{"result":[],"unknown":"synthetic-private-token"}"#,
            #"{"result":[],"unknown":"eyJhdXRoS2V5Ijoic2VjcmV0In0="}"#,
            #"{"result":[],"unknown":"https://user:secret@example.invalid/image"}"#,
            #"{"result":[],"unknown":"https://example.invalid/image?token=secret"}"#,
            #"{"result":[],"unknown":"https://127.0.0.1/image"}"#,
            #"{"result":[],"error":{"message":"remote-error"}}"#,
            #"{"result":[false]}"#
        ] {
            do { _ = try await fetch(Data(text.utf8)); fatalError("hostile source accepted") } catch {}
        }
        let safeUnknown = Data(#"{"result":[],"unknown":{"future":17,"poster":"https://example.invalid/public.jpg"}}"#.utf8)
        check(try await fetch(safeUnknown).response == safeUnknown)
        let exactNumbers = Data(#"{"result":[],"unknown":{"exponent":1e3,"negativeZero":-0.0,"wide":9007199254740993}}"#.utf8)
        let exactSource = try await fetch(exactNumbers)
        check(exactSource.response == exactNumbers)
        check(try Source.decodeArchive(exactSource.archive, scope: scope.account,
            ownerProfileID: owner, profileID: owner, verifiedUID: uid).response == exactNumbers)
        let numericCredential = Data(#"{"result":[],"unknown":{"negativeZero":-0.0,"authKey":"never-archive"}}"#.utf8)
        do { _ = try await fetch(numericCredential); fatalError("numeric carrier hid a credential") } catch {}
        let scalar = try JSONSerialization.data(withJSONObject: token, options: [.fragmentsAllowed])
        let plist = try PropertyListSerialization.data(fromPropertyList: ["innocuousKey": token], format: .binary, options: 0)
        let nestedData = try PropertyListSerialization.data(fromPropertyList: ["innocuousData": scalar], format: .binary, options: 0)
        let privateURL = try JSONSerialization.data(withJSONObject: "https://user:secret@example.invalid/image", options: [.fragmentsAllowed])
        for bytes in [scalar, plist, nestedData, privateURL] {
            let encoded = try JSONSerialization.data(withJSONObject: ["result": [], "unknown": bytes.base64EncodedString()])
            do { _ = try await fetch(encoded); fatalError("encoded scalar/plist private carrier accepted") } catch {}
        }
        let safeScalar = try JSONSerialization.data(withJSONObject: "ordinary-label", options: [.fragmentsAllowed])
        let safePlist = try PropertyListSerialization.data(fromPropertyList: ["ordinary": ["value": "safe"]], format: .binary, options: 0)
        for bytes in [safeScalar, safePlist] {
            let encoded = try JSONSerialization.data(withJSONObject: ["result": [], "unknown": bytes.base64EncodedString()])
            check(try await fetch(encoded).response == encoded)
        }
        do {
            _ = try await fetch(Data(repeating: 0x20, count: Source.maximumBytes + 1))
            fatalError("injected transport bypassed byte cap")
        } catch Source.Failure.invalidResponse {}
        print("Owner history authenticated capture/exact-source archive tests passed; no import or durability claim")
    }
}
