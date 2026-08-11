import Foundation

/// The TV-side QR pairing wire contract. Keep every route and JSON key here so the app and the canonical
/// relay can be reconciled at one boundary. Protocol v2 uses only fixed TV routes: the bearer session token is
/// carried in the body, never in a request path, query, redirect target, or diagnostic label.
enum AddonPairingProtocol {
    static let version = 2
    static let minTokenLength = 22
    static let maxTokenLength = 64
    static let maxManifests = 30
    static let maxManifestURLBytes = 2048
    static let maxResponseBytes = 128 * 1024

    static let relayBaseURL = URL(string: "https://add.vortx.tv")!

    static func canAcceptResponse(currentBytes: Int, incomingBytes: Int) -> Bool {
        guard currentBytes >= 0, incomingBytes >= 0, currentBytes <= maxResponseBytes else { return false }
        return incomingBytes <= maxResponseBytes - currentBytes
    }

    static func canAcceptManifestCount(_ count: Int) -> Bool {
        (0...maxManifests).contains(count)
    }

    enum Route: String {
        case new
        case poll
        case claim
        case ack
        case reopen
        case release
        case revoke

        var path: String { "/pair/\(rawValue)" }
    }

    /// Wire keys are intentionally centralized. `nonce` is the per-mutation id; the relay burns it durably.
    /// A new mutation gets a fresh value, while an ambiguous retry reuses the same pair for idempotency.
    enum Field {
        static let ok = "ok"
        static let duplicate = "duplicate"
        static let protocolVersion = "proto"
        static let token = "token"
        static let pageURL = "pageUrl"
        static let nonce = "nonce"
        static let mutationID = "mutationId"
        static let authoritySession = "session"
        static let authorityGeneration = "generation"
        static let deliveryIDs = "deliveries"
        static let acknowledgements = "acks"
        static let deliveryID = "id"
        static let deliveryRevision = "deliveryRev"
        static let url = "url"
        static let addedAt = "addedAt"
        static let status = "status"
        static let retryable = "retryable"
        static let attempt = "attempt"
        static let manifests = "manifests"
        static let revision = "rev"
        static let expiresAt = "expiresAt"
        static let closed = "closed"
        static let terminal = "terminal"
        static let released = "released"
        static let sessionGeneration = "sessionGeneration"
        static let report = "report"
        static let claimed = "claimed"
        static let accepted = "accepted"
        static let stale = "stale"
        static let replayed = "replayed"
        static let error = "error"
    }

    struct Authority: Equatable {
        let id: String
        let generation: Int

        init(id: String, generation: Int) {
            self.id = id
            self.generation = max(0, generation)
        }
    }

    struct WireAcknowledgement: Equatable {
        let deliveryID: String
        let status: String
        let attempt: Int
        let deliveryRevision: Int
        let retryable: Bool
    }

    struct DeliveryReference: Equatable {
        let deliveryID: String
        let deliveryRevision: Int
    }

    static func isStrictToken(_ token: String) -> Bool {
        guard (minTokenLength...maxTokenLength).contains(token.count) else { return false }
        return token.allSatisfy { character in
            character.isASCII &&
                (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    static func isOpaqueIdentifier(_ value: String, maxLength: Int = 512) -> Bool {
        guard (1...maxLength).contains(value.count) else { return false }
        return value.allSatisfy { character in
            character.isASCII &&
                (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    static func isMutationID(_ value: String) -> Bool {
        isOpaqueIdentifier(value, maxLength: 128)
    }

    /// The relay accepts only its canonical HTTPS manifest syntax. DNS/private-address checks and redirect
    /// revalidation happen in `AddonURLGuard`; this lighter gate rejects malformed or oversized poll entries
    /// before they can enter the reducer or be displayed as actionable work.
    static func isStrictManifestURL(_ value: String) -> Bool {
        guard !value.isEmpty,
              Data(value.utf8).count <= maxManifestURLBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.url != nil else { return false }
        return true
    }

    static func canonicalJSON(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func bodyForNew() -> [String: Any] {
        [Field.protocolVersion: version]
    }

    static func bodyForPoll(token: String, authority: Authority? = nil) -> [String: Any] {
        var body: [String: Any] = [Field.protocolVersion: version, Field.token: token]
        if let authority {
            body[Field.authoritySession] = authority.id
            body[Field.authorityGeneration] = authority.generation
        }
        return body
    }

    static func bodyForClaim(token: String, authority: Authority,
                             deliveries: [DeliveryReference], mutationID: String) -> [String: Any] {
        [
            Field.protocolVersion: version,
            Field.token: token,
            Field.nonce: mutationID,
            Field.mutationID: mutationID,
            Field.authoritySession: authority.id,
            Field.authorityGeneration: authority.generation,
            Field.deliveryIDs: deliveries.map {
                [Field.deliveryID: $0.deliveryID, Field.deliveryRevision: $0.deliveryRevision]
            },
        ]
    }

    static func bodyForAck(token: String, authority: Authority,
                           acknowledgements: [WireAcknowledgement], mutationID: String) -> [String: Any] {
        [
            Field.protocolVersion: version,
            Field.token: token,
            Field.nonce: mutationID,
            Field.mutationID: mutationID,
            Field.authoritySession: authority.id,
            Field.authorityGeneration: authority.generation,
            Field.acknowledgements: acknowledgements.map {
                [
                    Field.deliveryID: $0.deliveryID,
                    Field.status: $0.status,
                    Field.attempt: $0.attempt,
                    Field.deliveryRevision: $0.deliveryRevision,
                    Field.retryable: $0.retryable,
                ]
            },
        ]
    }

    static func bodyForReopen(token: String, authority: Authority, mutationID: String) -> [String: Any] {
        [
            Field.protocolVersion: version,
            Field.token: token,
            Field.authoritySession: authority.id,
            Field.authorityGeneration: authority.generation,
            Field.nonce: mutationID,
            Field.mutationID: mutationID,
        ]
    }

    static func bodyForRelease(token: String, authority: Authority, mutationID: String) -> [String: Any] {
        [
            Field.protocolVersion: version,
            Field.token: token,
            Field.authoritySession: authority.id,
            Field.authorityGeneration: authority.generation,
            Field.nonce: mutationID,
            Field.mutationID: mutationID,
        ]
    }

    /// Build and sign the request only after its final body bytes are assigned. The request has a fixed path;
    /// all token-bearing material is in the body covered by `X-VX-Body` and `X-VX-Sig`.
    static func makeSignedRequest(route: Route, body: [String: Any]) -> URLRequest? {
        guard let encoded = canonicalJSON(body) else { return nil }
        guard let url = URL(string: route.path, relativeTo: relayBaseURL)?.absoluteURL else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = encoded
        VortXEdgeAuth.signIncludingBody(&request)
        return request
    }
}
