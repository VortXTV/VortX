import Foundation
import CoreFoundation
import CryptoKit

/// Authenticated, immutable source capture only. This value is NOT a kernel receipt, a completed
/// import, or permission to publish. No keychain, journal, baseline, membership or watch write.
/// Intended production path: app/SourcesShared/VortxNativeOwnerHistorySource.swift.
enum VortxNativeOwnerHistorySource {
    enum Failure: Error, Equatable {
        case invalidCapture, wrongIdentity, invalidResponse, credentialCarrier, unsupportedURL
        case invalidArchive
    }
    static let maximumBytes = AuthenticatedHTTPTransport.snapshotResponseLimit
    static let maximumRows = 100_000

    /// Created from an acknowledged state before any network await. The caller must additionally
    /// hold the original install/account/profile/registry/credential generations through its
    /// VortxMutationAuthority; these bytes do not substitute for those ABA-sensitive leases.
    struct Capture: Sendable {
        let scope: String
        let ownerProfileID: UUID
        let profileID: UUID
        let verifiedUID: String
        let nativeDocumentBytes: Data
        let accountBindingBytes: Data

        init(scope: VortxAccountScope, profileID: UUID, verifiedUID: String, state: VortxJSON) throws {
            guard validLabel(scope.account), validUID(verifiedUID),
                  let ownerID = UUID(uuidString: scope.ownerProfileID),
                  ownerID.uuidString == scope.ownerProfileID,
                  state["activeProfileId"] == .string(profileID.uuidString),
                  let native = state["nativeSync"],
                  VortxNativeHostFieldEvidence.json(native["scope"], .string(scope.account)),
                  native["ownerProfileId"] == .string(scope.ownerProfileID),
                  let owner = state["roster"]?["profiles"]?[scope.ownerProfileID],
                  owner["owner"] == .bool(true), owner["deleted"] == .bool(false),
                  let profile = state["roster"]?["profiles"]?[profileID.uuidString],
                  profile["deleted"] == .bool(false) else { throw Failure.invalidCapture }
            let binding = try VortxNativeProfiles.expectedBinding(state: state, profileID: profileID)
            let kind = binding.account["kind"]
            // The owner remains local_only; another initiating profile must share this owner.
            // pending_own, own, local secondary profiles and an arbitrary owner never qualify.
            guard (profileID == ownerID && profile["owner"] == .bool(true)
                    && kind == .string("local_only"))
                || (profileID != ownerID && profile["owner"] == .bool(false)
                    && kind == .string("shared")
                    && binding.account["value"] == .string(ownerID.uuidString))
            else { throw Failure.invalidCapture }
            self.scope = scope.account; ownerProfileID = ownerID; self.profileID = profileID
            self.verifiedUID = verifiedUID
            nativeDocumentBytes = try VortxNativeHostFieldEvidence.canonicalData(native)
            accountBindingBytes = try VortxNativeHostFieldEvidence.canonicalData(binding.document)
        }

        /// Raw acknowledged-state entry point for source-bearing snapshots. Decode only the
        /// small admission projection; ownerHistory and unrelated native data never pass through
        /// VortxJSON/Double. The caller still owns the original Session/FIFO/credential authority.
        init(scope: VortxAccountScope, profileID: UUID, verifiedUID: String, snapshotData: Data) throws {
            typealias Exact = OwnerHistoryExactJSON
            let root = try Exact.Object(snapshotData)
            let nativeBytes = try root.required("nativeSync")
            let native = try Exact.Object(nativeBytes)
            let profiles = try Exact.Object(Exact.Object(root.required("roster")).required("profiles"))
            func decoded(_ bytes: Data) throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: bytes) }
            var projectedProfiles: [String: VortxJSON] = [:]
            for id in Set([scope.ownerProfileID, profileID.uuidString]) {
                let profile = try Exact.Object(profiles.required(id))
                var projection: [String: VortxJSON] = [:]
                for key in ["owner", "deleted", "account"] {
                    if let bytes = profile[key] { projection[key] = try decoded(bytes) }
                }
                projectedProfiles[id] = .object(projection)
            }
            var projectedNative: [String: VortxJSON] = [
                "scope": try decoded(native.required("scope")),
                "ownerProfileId": try decoded(native.required("ownerProfileId"))
            ]
            if let slotsBytes = native["accountSlots"] {
                let slots = try Exact.Object(slotsBytes)
                if let slotBytes = slots[profileID.uuidString] {
                    let slot = try Exact.Object(slotBytes)
                    if let binding = slot["activeBinding"] {
                        projectedNative["accountSlots"] = .object([profileID.uuidString:
                            .object(["activeBinding": try decoded(binding)])])
                    }
                }
            }
            let projection: VortxJSON = .object([
                "activeProfileId": try decoded(root.required("activeProfileId")),
                "nativeSync": .object(projectedNative),
                "roster": .object(["profiles": .object(projectedProfiles)])
            ])
            // Reuse the actual existing owner/shared role and causal binding checks, rather
            // than introduce a second interpretation of admission from the raw envelope.
            let checked = try Self(scope: scope, profileID: profileID, verifiedUID: verifiedUID, state: projection)
            self.scope = checked.scope; ownerProfileID = checked.ownerProfileID
            self.profileID = checked.profileID; self.verifiedUID = checked.verifiedUID
            nativeDocumentBytes = try Exact.canonical(nativeBytes)
            accountBindingBytes = checked.accountBindingBytes
        }

        /// Rechecks the same identity and complete raw native document; it never recaptures an
        /// authority or grants a new read. Numeric spellings and unknown source fields remain exact.
        func matches(snapshotData: Data) -> Bool {
            guard let next = try? Self(scope: .init(account: scope, ownerProfileID: ownerProfileID.uuidString),
                                       profileID: profileID, verifiedUID: verifiedUID, snapshotData: snapshotData)
            else { return false }
            return nativeDocumentBytes == next.nativeDocumentBytes && accountBindingBytes == next.accountBindingBytes
        }

        /// A complete native document change, including unrelated pending native work, invalidates
        /// preparation. This is a preflight helper, NOT a substitute for the final kernel CAS.
        func matches(state: VortxJSON) -> Bool {
            guard state["activeProfileId"] == .string(profileID.uuidString),
                  let native = state["nativeSync"],
                  let bytes = try? VortxNativeHostFieldEvidence.canonicalData(native),
                  let binding = try? VortxNativeProfiles.expectedBinding(state: state, profileID: profileID),
                  let bindingBytes = try? VortxNativeHostFieldEvidence.canonicalData(binding.document) else { return false }
            return nativeDocumentBytes == bytes && accountBindingBytes == bindingBytes
        }
    }

    /// No auth token, credential slot, request headers or response diagnostics can be encoded.
    /// The exact source bytes (including unknown JSON fields and original number spellings) remain
    /// the interpretation authority. The archive is proposed data for an atomic encrypted journal;
    /// returning it never claims that such a journal or a source receipt has been committed.
    struct Source: Sendable {
        let scope: String
        let ownerProfileID: UUID
        let profileID: UUID
        let verifiedUID: String
        let response: Data
        let archive: Data
        let rowCount: Int
        var sourceDocumentSHA256: String { digest(response) }
        var sourceArchiveSHA256: String { digest(archive) }
        fileprivate init(scope: String, ownerProfileID: UUID, profileID: UUID, verifiedUID: String,
                         response: Data, archive: Data, rowCount: Int) {
            self.scope = scope; self.ownerProfileID = ownerProfileID; self.profileID = profileID
            self.verifiedUID = verifiedUID; self.response = response; self.archive = archive
            self.rowCount = rowCount
        }
    }

    typealias Verify = @Sendable (String) async throws -> String
    typealias Send = @Sendable (URLRequest) async throws -> AuthenticatedHTTPResponse

    static func fetch(capture: Capture, authKey: String, authority: any VortxMutationAuthority,
                      verify: Verify = { try await LinkAuthService.authenticatedIdentity(authKey: $0).uid },
                      send: Send = { try await AuthenticatedHTTPTransport.shared.send($0,
                          allowedHosts: ["api.strem.io"], maxResponseBytes: maximumBytes) }) async throws -> Source {
        guard !authKey.isEmpty else { throw Failure.invalidCapture }
        try check(authority)
        let uid = try await verify(authKey)
        try check(authority)
        guard validUID(uid), Data(uid.utf8) == Data(capture.verifiedUID.utf8) else { throw Failure.wrongIdentity }
        var request = URLRequest(url: URL(string: "https://api.strem.io/api/datastoreGet")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "authKey": authKey, "collection": "libraryItem", "all": true
        ])
        let result = try await send(request)
        try check(authority)
        guard (200..<300).contains(result.statusCode) else { throw Failure.invalidResponse }
        let count = try validateResponse(result.data, prohibitedCredential: authKey)
        let envelope: [String: Any] = [
            "schemaVersion": 1, "kind": "vortx.owner-history.raw/1", "scope": capture.scope,
            "ownerProfileId": capture.ownerProfileID.uuidString, "profileId": capture.profileID.uuidString,
            "verifiedStreamingUid": uid, "libraryResponseBase64": result.data.base64EncodedString()
        ]
        let archive = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        let source = Source(scope: capture.scope, ownerProfileID: capture.ownerProfileID, profileID: capture.profileID,
                            verifiedUID: uid, response: result.data, archive: archive, rowCount: count)
        try check(authority)
        return source
    }

    /// Strict cold decoding under an already authenticated encrypted journal/peer envelope. The
    /// caller supplies the expected binding; archive assertions are never authentication by themselves.
    /// Revalidates all raw bytes, not merely a supplied source/archive digest.
    static func decodeArchive(_ archive: Data, scope: String, ownerProfileID: UUID,
                              profileID: UUID, verifiedUID: String) throws -> Source {
        guard archive.count <= maximumBytes * 2, validLabel(scope), validUID(verifiedUID) else { throw Failure.invalidArchive }
        try VortxNativeBootstrapArchive.requireUnambiguousJSON(archive)
        guard let object = try AuthenticatedHTTPTransport.jsonObject(from: archive) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "kind", "scope", "ownerProfileId", "profileId",
                                   "verifiedStreamingUid", "libraryResponseBase64"],
              let schema = object["schemaVersion"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
              schema.stringValue == "1", object["kind"] as? String == "vortx.owner-history.raw/1",
              exact(object["scope"], scope), exact(object["ownerProfileId"], ownerProfileID.uuidString),
              exact(object["profileId"], profileID.uuidString), exact(object["verifiedStreamingUid"], verifiedUID),
              let encoded = object["libraryResponseBase64"] as? String,
              let response = Data(base64Encoded: encoded), response.base64EncodedString() == encoded else { throw Failure.invalidArchive }
        let count = try validateResponse(response, prohibitedCredential: nil)
        return Source(scope: scope, ownerProfileID: ownerProfileID, profileID: profileID, verifiedUID: verifiedUID,
                      response: response, archive: archive, rowCount: count)
    }

    private static func check(_ authority: any VortxMutationAuthority) throws {
        try Task.checkCancellation()
        try authority.withActive {}
        try Task.checkCancellation()
    }
    private static func exact(_ value: Any?, _ expected: String) -> Bool {
        guard let value = value as? String else { return false }
        return Data(value.utf8) == Data(expected.utf8)
    }
    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func validUID(_ value: String) -> Bool { validLabel(value) }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }
    private static func validateResponse(_ bytes: Data, prohibitedCredential: String?) throws -> Int {
        let object = try credentialFreeObject(bytes, prohibitedCredential: prohibitedCredential)
        guard object["error"] == nil || object["error"] is NSNull,
              let rows = object["result"] as? [Any], rows.count <= maximumRows,
              rows.allSatisfy({ $0 is [String: Any] }) else { throw Failure.invalidResponse }
        return rows.count
    }
    /// Shared with exact original-addon/metadata framing. Inspection never returns sanitized
    /// source bytes; the caller retains the original Data only when every check succeeds.
    static func credentialFreeObject(_ bytes: Data, prohibitedCredential: String?) throws -> [String: Any] {
        guard bytes.count <= maximumBytes else { throw Failure.invalidResponse }
        try VortxNativeBootstrapArchive.requireUnambiguousJSON(bytes)
        guard let object = try AuthenticatedHTTPTransport.jsonObject(from: bytes) as? [String: Any] else { throw Failure.invalidResponse }
        // Use the real recursive privacy inspector, but NEVER use its rewritten output as source.
        // Any exclusion or rewrite is a whole-source hold; unknown safe fields remain in bytes.
        let inspected = try VortxNativeBootstrapArchive.encode(document: bytes)
        guard let checked = try AuthenticatedHTTPTransport.jsonObject(from: inspected) as? [String: Any],
              let exclusions = checked["excludedCredentialPaths"] as? [String], exclusions.isEmpty else { throw Failure.credentialCarrier }
        // Compare the inspector's complete serialized tree without another NSNumber
        // roundtrip (which can turn -0 into 0). Both sides still traverse the same
        // privacy policy; only the original caller bytes are ever retained as evidence.
        let host = try OwnerHistoryExactJSON.Object(inspected).required("hostDocument")
        guard try OwnerHistoryExactJSON.canonical(host)
            == OwnerHistoryExactJSON.canonical(canonical(object)) else { throw Failure.credentialCarrier }
        try inspectText(object, prohibitedCredential: prohibitedCredential)
        return object
    }
    private static func inspectText(_ value: Any, prohibitedCredential: String?, depth: Int = 0) throws {
        guard depth <= 64 else { throw Failure.credentialCarrier }
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                try inspectText(key, prohibitedCredential: prohibitedCredential, depth: depth + 1)
                try inspectText(nested, prohibitedCredential: prohibitedCredential, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for nested in array { try inspectText(nested, prohibitedCredential: prohibitedCredential, depth: depth + 1) }
        } else if let text = value as? String {
            if let prohibitedCredential, Data(text.utf8).range(of: Data(prohibitedCredential.utf8)) != nil {
                throw Failure.credentialCarrier
            }
            if text.contains("://") {
                guard let url = URLComponents(string: text), url.scheme == "https", let host = url.host,
                      !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      url.port == nil || url.port == 443,
                      host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
                      host != "localhost", !host.allSatisfy({ $0.isNumber || $0 == "." }) else { throw Failure.unsupportedURL }
            }
            // Traverse every structured carrier accepted by the real privacy inspector, including
            // quoted JSON scalars and plist. Checking objects/arrays alone misses encoded secrets
            // under innocuous keys. Unknown binary Data cannot become admitted evidence.
            for (carrierIndex, data) in [Data(text.utf8), Data(base64Encoded: text)].compactMap({ $0 }).enumerated() {
                if let nested = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                   nested is [String: Any] || nested is [Any] || nested is String {
                    try inspectText(nested, prohibitedCredential: prohibitedCredential, depth: depth + 1)
                } else if carrierIndex > 0,
                          let nested = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                    try inspectText(nested, prohibitedCredential: prohibitedCredential, depth: depth + 1)
                }
            }
        } else if let data = value as? Data {
            if let nested = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                try inspectText(nested, prohibitedCredential: prohibitedCredential, depth: depth + 1)
            } else if let nested = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                try inspectText(nested, prohibitedCredential: prohibitedCredential, depth: depth + 1)
            } else { throw Failure.credentialCarrier }
        }
    }
}
