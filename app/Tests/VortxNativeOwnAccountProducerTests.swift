import Foundation

private final class OwnSourceProbe: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable { let lock = NSLock(); var redirect = false; var foreignHits = 0 }
    private static let state = State()
    static func redirects(_ value: Bool) { state.lock.withLock { state.redirect = value; state.foreignHits = 0 } }
    static var foreignHits: Int { state.lock.withLock { state.foreignHits } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.host != "api.strem.io" { Self.state.lock.withLock { Self.state.foreignHits += 1 } }
        if Self.state.lock.withLock({ Self.state.redirect }) {
            let target = URL(string: "https://credential-sink.invalid/collect")!
            var redirected = request; redirected.url = target
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        let body = Data(#"{"result":{"_id":"verified-fixture-uid","email":null}}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor OwnSourceRequests {
    var paths: [String] = []
    func record(_ request: URLRequest) { paths.append(request.url!.lastPathComponent) }
}

@main struct VortxNativeOwnAccountProducerTests {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "own source fixture line \(line)") }
    static func main() async throws {
        let transport = AuthenticatedHTTPTransport(protocolClasses: [OwnSourceProbe.self])
        OwnSourceProbe.redirects(false)
        check(try await LinkAuthService.authenticatedIdentity(authKey: "fixture-only", transport: transport).uid == "verified-fixture-uid")
        OwnSourceProbe.redirects(true)
        do { _ = try await LinkAuthService.authenticatedIdentity(authKey: "fixture-only", transport: transport); fatalError("identity redirected credential") }
        catch LinkAuthService.IdentityVerificationError.transient {}
        check(OwnSourceProbe.foreignHits == 0)
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-00000000B22C")!
        let slot = "fixture.profile." + profileID.uuidString
        let library = Data(" {\n \"result\":[] }\n".utf8), addons = Data(#"{"result":{"addons":[]}}"#.utf8)
        let requests = OwnSourceRequests()
        let send: VortxNativeOwnAccountProducer.Send = { request in
            await requests.record(request)
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            check(object["authKey"] as? String == "fixture-only")
            if request.url!.lastPathComponent == "datastoreGet" {
                check(object["collection"] as? String == "libraryItem" && object["all"] as? Bool == true)
                return .init(data: library, statusCode: 200)
            }
            check(request.url!.lastPathComponent == "addonCollectionGet" && object["update"] as? Bool == false)
            return .init(data: addons, statusCode: 200)
        }
        let authority = VortxNativeOwnAccountProducer.Authority(generations: [.initCapture(slot)], validate: { true })
        let source = try await VortxNativeOwnAccountProducer.fetch(profileID: profileID, authKey: "fixture-only", authority: authority,
            verify: { _ in "verified-fixture-uid" }, send: send)
        let envelope = try JSONSerialization.jsonObject(with: source.sourceDocument) as! [String: Any]
        check(Data(base64Encoded: envelope["libraryResponseBase64"] as! String) == library)
        check(Data(base64Encoded: envelope["addonsResponseBase64"] as! String) == addons)
        check(Data(base64Encoded: envelope["profileOverlayBase64"] as! String) == Data("{}".utf8))
        check(envelope["schemaVersion"] as? Int == 2)
        check(source.profileOverlaySHA256 == (try VortxProfileOverlayWitness.digest(json: Data("{}".utf8))))
        let scopedDocument: VortxJSON = .object(["vortx": .object(["library": .array([.string("must-not-borrow")]), "byProfile": .object([
            profileID.uuidString: .object(["watched": .object(["own-only": .object(["ma": .integer(10)])])]),
            UserProfile.ownerID.uuidString: .object(["watched": .object(["owner-only": .object(["ma": .integer(20)])])])])])])
        let overlay = try JSONDecoder().decode(VortxJSON.self, from: VortxNativeOwnAccountProducer.overlay(document: scopedDocument, profileID: profileID))
        check(overlay["vortx"]?["library"] == nil && overlay["vortx"]?["byProfile"]?[UserProfile.ownerID.uuidString] == nil)
        check(overlay["vortx"]?["byProfile"]?[profileID.uuidString]?["watched"]?["own-only"]?["ma"] == .integer(10))
        let hardRaw = Data(("{\"vortx\":{\"byProfile\":{\"" + profileID.uuidString + "\":{\"progress\":{\"own-only\":{\"t\":0.039304369631583587}}}}}}").utf8)
        let ingress = try VortxProfileOverlayWitness.decodeObject(json: hardRaw)
        let projected = try JSONDecoder().decode(VortxJSON.self, from: JSONSerialization.data(withJSONObject: ingress))
        let rawSlice = try VortxNativeOwnAccountProducer.overlay(document: projected, profileID: profileID)
        check(try VortxProfileOverlayWitness.digest(json: rawSlice) == VortxProfileOverlayWitness.digest(json: hardRaw))
        check(source.profileID == profileID && source.verifiedStreamingUID == "verified-fixture-uid")
        check(await requests.paths == ["datastoreGet", "addonCollectionGet"])
        // A new UID's independently fetched rows do not certify a historical UUID-only
        // cloud overlay. Version 1 deliberately carries no current-overlay witness.
        let independent = try await VortxNativeOwnAccountProducer.fetch(profileID: profileID, authKey: "fixture-only", authority: authority,
            framing: .independentNetworkOnly, verify: { _ in "independent-uid" }, send: { request in
                .init(data: request.url!.lastPathComponent == "datastoreGet" ? library : addons, statusCode: 200)
            })
        let independentEnvelope = try JSONSerialization.jsonObject(with: independent.sourceDocument) as! [String: Any]
        check(independentEnvelope["schemaVersion"] as? Int == 1 && independent.profileOverlaySHA256 == nil)
        do {
            _ = try await VortxNativeOwnAccountProducer.fetch(profileID: profileID, authKey: "fixture-only", authority: authority,
                profileOverlay: VortxNativeOwnAccountProducer.overlay(document: scopedDocument, profileID: profileID),
                framing: .independentNetworkOnly, verify: { _ in "independent-uid" }, send: send)
            fatalError("historical overlay attributed to new UID")
        } catch VortxNativeError.invalidSnapshot {}
        check(await requests.paths.count == 2)
        // Same-slot replacement A→B→A still retires the original capture even if the final token
        // bytes equal the first token. A source never becomes valid again by value equality alone.
        let old = VortxNativeOwnAccountProducer.Authority(generations: [.initCapture(slot)], validate: { true })
        do {
            _ = try await VortxNativeOwnAccountProducer.fetch(profileID: profileID, authKey: "fixture-only", authority: old,
                verify: { _ in VortxNativeOwnAccountProducer.invalidate(slot: slot); VortxNativeOwnAccountProducer.invalidate(slot: slot); return "verified-fixture-uid" }, send: send)
            fatalError("ABA source admitted")
        } catch VortxNativeError.superseded {}
        check(await requests.paths.count == 2)
        let changedContext = VortxNativeOwnAccountProducer.Authority(generations: [.initCapture(slot)], validate: { true })
        do {
            _ = try await VortxNativeOwnAccountProducer.fetch(profileID: profileID, authKey: "fixture-only", authority: changedContext,
                verify: { _ in "verified-fixture-uid" }, send: { request in
                    await requests.record(request); VortxNativeOwnAccountProducer.invalidateContext()
                    return .init(data: library, statusCode: 200)
                })
            fatalError("changed profile source admitted")
        } catch VortxNativeError.superseded {}
        check(await requests.paths.count == 3)
        let fresh = VortxNativeOwnAccountProducer.Authority(generations: [.initCapture(slot)], validate: { true })
        for response in [AuthenticatedHTTPResponse(data: Data(#"{"error":{"code":1}}"#.utf8), statusCode: 200),
                         .init(data: Data(#"{}"#.utf8), statusCode: 200), .init(data: library, statusCode: 503)] {
            do {
                _ = try await VortxNativeOwnAccountProducer.fetch(profileID: profileID, authKey: "fixture-only", authority: fresh,
                    verify: { _ in "verified-fixture-uid" }, send: { _ in response })
                fatalError("failed source interpreted as empty")
            } catch VortxNativeError.invalidResponse {}
        }
        VortxNativeOwnAccountProducer.invalidate(slot: slot)
        var committed = false
        do { try fresh.withActive { committed = true }; fatalError("stale final commit admitted") }
        catch VortxNativeError.superseded {}
        check(!committed)
        let betweenStartAndWrite = VortxNativeOwnAccountProducer.Authority(generations: [.initCapture(slot)], validate: { true })
        VortxNativeOwnAccountProducer.withCredentialMutation(slot: slot) { /* Same-value token replacement still retires the capture. */ }
        do { try betweenStartAndWrite.withActive {}; fatalError("same-value credential replacement revived source") }
        catch VortxNativeError.superseded {}
        // Secure candidates are immutable and inactive until the durable native binding names
        // their transaction. No mutable current-token pointer can race a failed native CAS.
        let journalAuthority = VortxNativeOwnAccountProducer.Authority(generations: [.initCapture(slot)], validate: { true })
        let credentiallessAuthority = VortxNativeOwnAccountProducer.Authority(generations: [], validate: { true })
        var secure: [String: String] = [:]
        func stage(_ token: String, _ scope: String, _ id: UUID, _ uid: String, _ transaction: String?) throws -> String {
            try VortxNativeAccountCredentials.stage(token: token, scope: scope, profileID: id, uid: uid,
                transactionID: transaction, authority: journalAuthority, read: { secure[$0] }, write: { secure[$0] = $1; return true })
        }
        func binding(_ uid: String, _ revision: Int64, _ transaction: String?) -> VortxJSON {
            .object(["account": .object(["kind": .string("own"), "value": .string(uid)]),
                     "revision": .integer(revision), "transactionId": transaction.map(VortxJSON.string) ?? .null])
        }
        let initial = try stage("token-A0", "account-A", profileID, "uid-A", nil)
        let stagedB = try stage("token-B", "account-A", profileID, "uid-B", "transaction-B")
        var active = binding("uid-A", 0, nil)
        check(try VortxNativeAccountCredentials.selectedSlot(scope: "account-A", profileID: profileID, binding: active) == initial)
        // A failed/unknown CAS does not select the newly staged candidate.
        check(secure[initial] == "token-A0" && stagedB != initial)
        active = binding("uid-B", 1, "transaction-B")
        check(try VortxNativeAccountCredentials.selectedSlot(scope: "account-A", profileID: profileID, binding: active) == stagedB)
        let relinkA = try stage("token-A2", "account-A", profileID, "uid-A", "transaction-A2")
        active = binding("uid-A", 2, "transaction-A2")
        check(try VortxNativeAccountCredentials.selectedSlot(scope: "account-A", profileID: profileID, binding: active) == relinkA)
        check(relinkA != initial && secure[initial] == "token-A0" && secure[stagedB] == "token-B")
        let foreignAccount = try stage("token-foreign-account", "account-B", profileID, "uid-A", "transaction-A2")
        let foreignProfile = try stage("token-foreign-profile", "account-A", UUID(), "uid-A", "transaction-A2")
        check(foreignAccount != relinkA && foreignProfile != relinkA)
        do { _ = try stage("replacement", "account-A", profileID, "uid-A", "transaction-A2"); fatalError("immutable credential revision overwritten") }
        catch VortxNativeError.invalidSnapshot {}
        check(secure[relinkA] == "token-A2")
        let missing = try VortxNativeAccountCredentials.selectedSlot(scope: "account-A", profileID: profileID, binding: binding("uid-A", 3, "missing"))!
        check(secure[missing] == nil) // Never borrow an earlier same-UID token.
        check(try VortxNativeAccountCredentials.selectedSlot(scope: "account-A", profileID: profileID,
            binding: .object(["account": .object(["kind": .string("pending_own")])])) == nil)
        VortxNativeOwnAccountProducer.invalidateContext()
        do { try credentiallessAuthority.withActive {}; fatalError("empty credential list ignored context retirement") }
        catch VortxNativeError.superseded {}
        let beforeRetired = secure
        do { _ = try stage("retired", "account-A", profileID, "uid-A", "retired"); fatalError("retired credential candidate staged") }
        catch VortxNativeError.superseded {}
        check(secure == beforeRetired)
        print("Own-account authenticated producer: hardened identity redirect rejection, exact raw source bytes, independent read-only requests, token ABA/profile retirement and failed-source nonempty semantics passed")
    }
}
private extension VortxNativeOwnAccountProducer.Generation {
    static func initCapture(_ slot: String) -> Self { VortxNativeOwnAccountProducer.capture(slot: slot) }
}
