import Foundation

/// Client for the "Install by QR / pair once, add many" add-on pairing relay at `add.vortx.tv`.
///
/// THE FLOW: the TV creates a pairing SESSION (`POST /pair/new`) and renders the returned `pageUrl`
/// as a QR. The user's phone opens that page and pastes one or more add-on manifest URLs, which the
/// relay appends to the session's list. The TV POLLS the session (`POST /pair/poll`) to see the live
/// incoming list, claims each delivery under a server-fenced authority, then installs it through the
/// app's OWN hardened install path. The relay is a DUMB PIPE: it only carries URL strings; the TV validates
/// and installs.
///
/// SIGNING: every TV request uses the centralized protocol builder. Its final canonical JSON body is assigned
/// before `VortXEdgeAuth.signIncludingBody(&req)`, and the bearer token is never placed in the URL path/query.
enum AddonPairingClient {
    typealias Authority = AddonPairingProtocol.Authority

    /// A freshly created pairing session: the QR target (`pageUrl`), the poll `token`, and the
    /// session expiry (unix ms). The TV renders `pageUrl` as the QR and polls with `token`.
    struct Session: Equatable {
        let token: String
        let pageUrl: String
        let expiresAtMs: Double
        let generation: Int
        /// Stable client authority for this in-memory resume. Keeping it with the session lets a sheet reopen
        /// continue an existing server claim; a process restart has no persisted bearer session to resume.
        let authoritySession: String

        init(token: String, pageUrl: String, expiresAtMs: Double, generation: Int,
             authoritySession: String = "") {
            self.token = token
            self.pageUrl = pageUrl
            self.expiresAtMs = expiresAtMs
            self.generation = generation
            self.authoritySession = authoritySession
        }

        /// Wall-clock expiry as a `Date`, so the view can decide when to rotate the session.
        var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// One manifest URL the phone has added to the session, with when it landed (unix ms).
    struct IncomingManifest: Equatable, Identifiable {
        let deliveryId: String
        let url: String
        let addedAtMs: Double
        let status: String
        let attempt: Int
        let deliveryRevision: Int
        let retryable: Bool
        let claimed: Bool
        /// Stable identity so SwiftUI rows keep their per-row install state as the list grows.
        var id: String { deliveryId }

        /// Compatibility initializer for the beta relay shape, which had no durable delivery id/status.
        init(url: String, addedAtMs: Double) {
            self.init(deliveryId: url, url: url, addedAtMs: addedAtMs, status: "pending", attempt: 0,
                      deliveryRevision: 0, retryable: false, claimed: false)
        }

        init(deliveryId: String, url: String, addedAtMs: Double, status: String,
             attempt: Int = 0, deliveryRevision: Int = 0, retryable: Bool = false,
             claimed: Bool = false) {
            self.deliveryId = deliveryId
            self.url = url
            self.addedAtMs = addedAtMs
            self.status = status
            self.attempt = max(0, attempt)
            self.deliveryRevision = max(0, deliveryRevision)
            self.retryable = retryable
            self.claimed = claimed
        }
    }

    /// The current state of a polled session: the live list plus whether it expired or was closed.
    struct Poll: Equatable {
        let manifests: [IncomingManifest]
        let expiresAtMs: Double
        let closed: Bool
        let rev: Int
        let generation: Int
        let terminal: Bool
        let released: Bool

        init(manifests: [IncomingManifest], expiresAtMs: Double, closed: Bool, rev: Int = 0,
             generation: Int = 1, terminal: Bool = false, released: Bool = false) {
            self.manifests = manifests
            self.expiresAtMs = expiresAtMs
            self.closed = closed
            self.rev = max(0, rev)
            self.generation = max(1, generation)
            self.terminal = terminal
            self.released = released
        }

        var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// A poll outcome. `.gone` maps the relay's 404 (expired / unknown token) so the view can rotate
    /// to a fresh session instead of spinning on a dead one. A structured stale-generation response exposes the
    /// relay's current authority generation so the view can rebase and poll again instead of sleeping forever.
    enum PollResult: Equatable {
        case ok(Poll)
        case gone
        case staleGeneration(Int)
        case failed
    }

    /// The authenticated poll loop's state transition. Keeping stale-generation adoption and normal poll
    /// generation checks together prevents the closed-session path from treating a structured 409 as a generic
    /// failure and sleeping forever on an obsolete authority.
    enum PollTransition: Equatable {
        case current(Poll, Authority)
        case stale(Authority)
    }

    /// One confirmed TV outcome sent back to the relay. `attempt` and `deliveryRevision` let the relay
    /// reject stale results after a retry or replacement; `retryable` tells it to clear the claim while
    /// retaining pending work. The outer `mutationId` and `nonce` are emitted by the canonical builder.
    struct DeliveryAck: Equatable {
        let deliveryId: String
        let status: String
        let attempt: Int
        let deliveryRevision: Int
        let retryable: Bool
        /// Retained for source compatibility with the beta hardening surface. The v2 relay carries the
        /// monotonic poll revision separately; each acknowledgement carries its delivery revision.
        let rev: Int
        let mutationId: String

        init(deliveryId: String, status: String, attempt: Int, rev: Int = 0, mutationId: String = "",
             deliveryRevision: Int = 0, retryable: Bool = false) {
            self.deliveryId = deliveryId
            self.status = status
            self.attempt = attempt
            self.rev = max(0, rev)
            self.mutationId = mutationId
            self.deliveryRevision = max(0, deliveryRevision)
            self.retryable = retryable
        }
    }

    struct ClaimResult: Equatable {
        let attempt: Int
        let deliveryRevision: Int
    }

    // MARK: - POST /pair/new

    /// Create a new pairing session. Returns nil on any failure so the view can show a retry.
    static func createSession() async -> Session? {
        guard let req = AddonPairingProtocol.makeSignedRequest(
            route: .new,
            body: AddonPairingProtocol.bodyForNew()
        ) else { return nil }

        guard let data = await performData(req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj[AddonPairingProtocol.Field.ok] as? Bool == true,
              exactInt(obj[AddonPairingProtocol.Field.protocolVersion]) == AddonPairingProtocol.version,
              let token = obj[AddonPairingProtocol.Field.token] as? String, isStrictToken(token),
              let pageUrl = obj[AddonPairingProtocol.Field.pageURL] as? String, isTrustedPageURL(pageUrl),
              let expiresAt = finiteNumeric(obj[AddonPairingProtocol.Field.expiresAt]), expiresAt > 0,
              let generation = exactInt(obj[AddonPairingProtocol.Field.authorityGeneration]), generation >= 1,
              let sessionGeneration = exactInt(obj[AddonPairingProtocol.Field.sessionGeneration]),
              sessionGeneration == generation else { return nil }
        return Session(token: token, pageUrl: pageUrl, expiresAtMs: expiresAt,
                       generation: generation)
    }

    /// Tokens are opaque path components, not arbitrary URL strings. Restricting their alphabet prevents
    /// traversal/extra-segment tricks before either URL construction or request signing.
    static func isStrictToken(_ token: String) -> Bool {
        AddonPairingProtocol.isStrictToken(token)
    }

    /// Only the relay's HTTPS origin may be rendered as the QR fallback/page URL. The token intentionally lives
    /// in the fragment (`/p#TOKEN`), which is read by the phone shell and never sent to the relay in a URL.
    static func isTrustedPageURL(_ pageUrl: String) -> Bool {
        guard let components = URLComponents(string: pageUrl),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "add.vortx.tv",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.path == "/p",
              let fragment = components.fragment,
              AddonPairingProtocol.isStrictToken(fragment) else { return false }
        return true
    }

    // MARK: - Pathless, body-bound TV requests

    static func makePollRequest(token: String, authority: Authority? = nil) -> URLRequest? {
        guard isStrictToken(token) else { return nil }
        if let authority {
            guard AddonPairingProtocol.isMutationID(authority.id), authority.generation >= 1 else { return nil }
        }
        return AddonPairingProtocol.makeSignedRequest(route: .poll,
                                                       body: AddonPairingProtocol.bodyForPoll(token: token, authority: authority))
    }

    static func makeClaimRequest(token: String, authority: Authority,
                                 deliveryIDs: [String], deliveryRevision: Int = 0,
                                 mutationID: String) -> URLRequest? {
        guard isStrictToken(token), !deliveryIDs.isEmpty,
              deliveryIDs.allSatisfy({ AddonPairingProtocol.isOpaqueIdentifier($0, maxLength: 128) }),
              deliveryRevision >= 0,
              AddonPairingProtocol.isMutationID(mutationID),
              AddonPairingProtocol.isMutationID(authority.id), authority.generation >= 1 else { return nil }
        let deliveries = deliveryIDs.map {
            AddonPairingProtocol.DeliveryReference(deliveryID: $0, deliveryRevision: deliveryRevision)
        }
        return AddonPairingProtocol.makeSignedRequest(
            route: .claim,
            body: AddonPairingProtocol.bodyForClaim(token: token, authority: authority,
                                                    deliveries: deliveries, mutationID: mutationID)
        )
    }

    static func makeAckRequest(token: String, authority: Authority,
                               deliveries: [DeliveryAck], mutationID: String) -> URLRequest? {
        guard isStrictToken(token), !deliveries.isEmpty,
              deliveries.allSatisfy({ AddonPairingProtocol.isOpaqueIdentifier($0.deliveryId) &&
                  ($0.status == "installed" || $0.status == "failed") && $0.attempt >= 1 &&
                  $0.deliveryRevision >= 0 && !($0.status == "installed" && $0.retryable) }),
              AddonPairingProtocol.isMutationID(mutationID),
              AddonPairingProtocol.isMutationID(authority.id), authority.generation >= 1 else { return nil }
        let acks = deliveries.map {
            AddonPairingProtocol.WireAcknowledgement(deliveryID: $0.deliveryId,
                                                     status: $0.status,
                                                     attempt: $0.attempt,
                                                     deliveryRevision: $0.deliveryRevision,
                                                     retryable: $0.retryable)
        }
        return AddonPairingProtocol.makeSignedRequest(
            route: .ack,
            body: AddonPairingProtocol.bodyForAck(token: token, authority: authority,
                                                  acknowledgements: acks, mutationID: mutationID)
        )
    }

    static func makeReopenRequest(token: String, authority: Authority,
                                  mutationID: String) -> URLRequest? {
        guard isStrictToken(token),
              AddonPairingProtocol.isMutationID(mutationID),
              AddonPairingProtocol.isMutationID(authority.id), authority.generation >= 1 else { return nil }
        return AddonPairingProtocol.makeSignedRequest(
            route: .reopen,
            body: AddonPairingProtocol.bodyForReopen(token: token, authority: authority, mutationID: mutationID)
        )
    }

    static func makeReleaseRequest(token: String, authority: Authority,
                                   mutationID: String) -> URLRequest? {
        guard isStrictToken(token),
              AddonPairingProtocol.isMutationID(mutationID),
              AddonPairingProtocol.isMutationID(authority.id), authority.generation >= 1 else { return nil }
        return AddonPairingProtocol.makeSignedRequest(
            route: .release,
            body: AddonPairingProtocol.bodyForRelease(token: token, authority: authority, mutationID: mutationID)
        )
    }

    // MARK: - Poll / claim / acknowledgement

    /// Poll a session's live manifest list. A 404 becomes `.gone` (expired / unknown token). Response bytes are
    /// capped before JSON parsing so a hostile relay response cannot grow an unbounded in-memory buffer.
    static func poll(token: String, authority: Authority? = nil) async -> PollResult {
        guard let req = makePollRequest(token: token, authority: authority) else { return .failed }

        guard let (data, http) = await performResponse(req) else { return .failed }
        if http.statusCode == 404 { return .gone }
        if let generation = parseStaleGenerationResponse(data, statusCode: http.statusCode) {
            return .staleGeneration(generation)
        }
        guard (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
        guard exactInt(obj[AddonPairingProtocol.Field.protocolVersion]) == AddonPairingProtocol.version,
              let rawManifests = obj[AddonPairingProtocol.Field.manifests] as? [[String: Any]],
              AddonPairingProtocol.canAcceptManifestCount(rawManifests.count),
              let expiresAt = finiteNumeric(obj[AddonPairingProtocol.Field.expiresAt]), expiresAt > 0,
              let generationValue = exactInt(obj[AddonPairingProtocol.Field.authorityGeneration]),
              generationValue >= 1 else {
            return .failed
        }
        var manifests: [IncomingManifest] = []
        manifests.reserveCapacity(rawManifests.count)
        for entry in rawManifests {
            guard let manifest = parseManifest(entry) else { return .failed }
            manifests.append(manifest)
        }
        guard let closed = obj[AddonPairingProtocol.Field.closed] as? Bool,
              let terminal = obj[AddonPairingProtocol.Field.terminal] as? Bool,
              let released = obj[AddonPairingProtocol.Field.released] as? Bool,
              let rev = exactInt(obj[AddonPairingProtocol.Field.revision]), rev >= 0 else { return .failed }
        return .ok(Poll(manifests: manifests, expiresAtMs: expiresAt, closed: closed, rev: rev,
                        generation: generationValue,
                        terminal: terminal,
                        released: released))
    }

    /// Parse only the relay's bounded, exact stale-generation recovery response. This is deliberately separate
    /// from normal poll parsing so a 409 cannot be treated as a weak success or expose arbitrary response fields.
    static func parseStaleGenerationResponse(_ data: Data, statusCode: Int) -> Int? {
        guard statusCode == 409, data.count <= AddonPairingProtocol.maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == [AddonPairingProtocol.Field.ok,
                                   AddonPairingProtocol.Field.error,
                                   AddonPairingProtocol.Field.authorityGeneration,
                                   AddonPairingProtocol.Field.protocolVersion],
              object[AddonPairingProtocol.Field.ok] as? Bool == false,
              object[AddonPairingProtocol.Field.error] as? String == "stale_generation",
              exactInt(object[AddonPairingProtocol.Field.protocolVersion]) == AddonPairingProtocol.version,
              let generation = exactInt(object[AddonPairingProtocol.Field.authorityGeneration]),
              generation >= 1 else { return nil }
        return generation
    }

    /// Adopt the server-reported generation while retaining the same opaque authority id. The response is only
    /// accepted for a valid authority; the next poll then proves convergence against the relay's current state.
    static func authorityForStaleGeneration(_ authority: Authority, currentGeneration: Int) -> Authority? {
        guard AddonPairingProtocol.isMutationID(authority.id), currentGeneration >= 1 else { return nil }
        return Authority(id: authority.id, generation: currentGeneration)
    }

    static func pollTransition(result: PollResult, authority: Authority) -> PollTransition? {
        guard AddonPairingProtocol.isMutationID(authority.id) else { return nil }
        switch result {
        case let .ok(poll):
            guard !poll.released, poll.generation >= max(1, authority.generation) else { return nil }
            return .current(poll, Authority(id: authority.id, generation: poll.generation))
        case let .staleGeneration(currentGeneration):
            guard currentGeneration > authority.generation,
                  let recovered = authorityForStaleGeneration(authority, currentGeneration: currentGeneration) else {
                return nil
            }
            return .stale(recovered)
        case .gone, .failed:
            return nil
        }
    }

    /// Shared lifecycle fence for non-cancellable awaits in the session task. Every result must be applied only
    /// while it belongs to the same view generation and the task is still live.
    static func canApplyLifecycleResult(expectedGeneration: Int,
                                        currentGeneration: Int,
                                        taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled && expectedGeneration == currentGeneration
    }

    static func claim(token: String, authority: Authority, deliveryIDs: [String], deliveryRevision: Int = 0,
                      mutationID: String = newMutationId()) async -> ClaimResult? {
        guard let req = makeClaimRequest(token: token, authority: authority,
                                         deliveryIDs: deliveryIDs, deliveryRevision: deliveryRevision,
                                         mutationID: mutationID),
              let data = await performData(req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isValidMutationResponse(obj, expectedGeneration: authority.generation),
              let report = obj[AddonPairingProtocol.Field.report] as? [String: Any],
              let claimed = report[AddonPairingProtocol.Field.claimed] as? [[String: Any]],
              claimed.count <= AddonPairingProtocol.maxManifests,
              claimed.allSatisfy({ claim in
                  guard let id = claim[AddonPairingProtocol.Field.deliveryID] as? String,
                        validDeliveryID(id),
                        let attempt = exactInt(claim[AddonPairingProtocol.Field.attempt]), attempt >= 1,
                        let deliveryRevision = exactInt(claim[AddonPairingProtocol.Field.deliveryRevision]),
                        deliveryRevision >= 0 else { return false }
                  return true
              }),
              let first = claimed.first,
              let firstID = first[AddonPairingProtocol.Field.deliveryID] as? String,
              deliveryIDs.contains(firstID),
              let attempt = exactInt(first[AddonPairingProtocol.Field.attempt]),
              let claimedRevision = exactInt(first[AddonPairingProtocol.Field.deliveryRevision]),
              attempt >= 1,
              claimedRevision >= deliveryRevision else { return nil }
        return ClaimResult(attempt: attempt, deliveryRevision: claimedRevision)
    }

    /// Reopen a durable session under a fresh client authority. The relay increments its generation and clears
    /// claims left by a prior app process, so resumed rows can be claimed rather than remaining server-busy.
    static func reopen(token: String, authority: Authority,
                       mutationID: String = newMutationId()) async -> Authority? {
        guard let req = makeReopenRequest(token: token, authority: authority, mutationID: mutationID),
              let (data, response) = await performResponse(req),
              (200..<300).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isValidMutationResponse(object),
              exactInt(object[AddonPairingProtocol.Field.protocolVersion]) == AddonPairingProtocol.version,
              let generation = exactInt(object[AddonPairingProtocol.Field.authorityGeneration]),
              generation >= authority.generation else { return nil }
        return Authority(id: authority.id, generation: generation)
    }

    /// Release is a server mutation, not a local UI side effect. The relay only seals a closed, fully drained
    /// session and returns `released:true`; failure leaves the local resume state intact for retry.
    static func release(token: String, authority: Authority,
                        mutationID: String = newMutationId()) async -> Bool {
        guard let req = makeReleaseRequest(token: token, authority: authority, mutationID: mutationID),
              let (data, response) = await performResponse(req),
              (200..<300).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isValidReleaseResponse(object, expectedGeneration: authority.generation),
              object[AddonPairingProtocol.Field.released] as? Bool == true else { return false }
        return true
    }

    /// Acknowledge confirmed terminal outcomes. The canonical sorted-key body is assigned before signing so
    /// `X-VX-Body` and `X-VX-Sig` bind exactly the bytes sent over the wire. New mutations get a fresh outer nonce;
    /// an ambiguous retry reuses the same mutation pair so the relay returns its durable idempotent result.
    @discardableResult
    static func ack(token: String, authority: Authority, deliveries: [DeliveryAck], mutationID: String) async -> Bool {
        guard let req = makeAckRequest(token: token, authority: authority, deliveries: deliveries,
                                       mutationID: mutationID),
              let deliveryID = deliveries.first?.deliveryId,
              let data = await performData(req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isValidMutationResponse(obj, expectedGeneration: authority.generation),
              let report = obj[AddonPairingProtocol.Field.report] as? [String: Any],
              let accepted = report[AddonPairingProtocol.Field.accepted] as? [String],
              accepted.count <= AddonPairingProtocol.maxManifests,
              accepted.allSatisfy({ validDeliveryID($0) }) else { return false }
        return accepted.contains(deliveryID)
    }

    /// Fresh mutation nonce for each new acknowledgement; ambiguous retries reuse the pending mutation id.
    static func newMutationId() -> String { UUID().uuidString }

    static func newAuthority() -> Authority {
        Authority(id: UUID().uuidString, generation: 0)
    }

    // MARK: - Session persistence (resume across sheet opens)

    /// The most recent session, held so a manifest the phone adds AFTER the pairing sheet closes
    /// still arrives: the view resumes this session on the next open instead of minting a fresh one.
    /// The relay keeps a session alive ~10 min from its last activity, and the phone page's own 2s
    /// polling keeps bumping that while it stays open, so the stored expiry is only a lower bound;
    /// liveness is decided by polling the token, never by the stored timestamp.
    ///
    /// This lives IN MEMORY ONLY (not UserDefaults): the token is a bearer credential for the relay
    /// session, and plaintext UserDefaults is captured by Finder/iCloud device backups. Resume is only
    /// needed while the app process is alive (sheet close then reopen), so a static holder is enough,
    /// and it leaves no on-disk trace to back up. `nil` = no session to resume.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedSession: Session?

    static func persist(_ session: Session) {
        lock.lock(); defer { lock.unlock() }
        storedSession = session
    }

    static func persistedSession() -> Session? {
        lock.lock(); defer { lock.unlock() }
        return storedSession
    }

    static func clearPersistedSession() {
        lock.lock(); defer { lock.unlock() }
        storedSession = nil
    }

    // MARK: - Helpers

    /// Coerce a JSON number that may arrive as `Double`, `Int`, or a numeric `String` into a `Double`.
    private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func finiteNumeric(_ value: Any?) -> Double? {
        guard let number = numeric(value), number.isFinite else { return nil }
        return number
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = finiteNumeric(value), number.rounded() == number,
              number > Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func validDeliveryID(_ value: String) -> Bool {
        AddonPairingProtocol.isOpaqueIdentifier(value, maxLength: 128)
    }

    private static func parseManifest(_ entry: [String: Any]) -> IncomingManifest? {
        guard let deliveryId = entry[AddonPairingProtocol.Field.deliveryID] as? String,
              validDeliveryID(deliveryId),
              let url = entry[AddonPairingProtocol.Field.url] as? String,
              AddonPairingProtocol.isStrictManifestURL(url),
              let status = entry[AddonPairingProtocol.Field.status] as? String,
              status == "pending" || status == "installed" || status == "failed",
              let attempt = exactInt(entry[AddonPairingProtocol.Field.attempt]), attempt >= 0,
              let deliveryRevision = exactInt(entry[AddonPairingProtocol.Field.deliveryRevision]), deliveryRevision >= 0,
              let addedAt = finiteNumeric(entry[AddonPairingProtocol.Field.addedAt]), addedAt >= 0,
              let retryable = entry[AddonPairingProtocol.Field.retryable] as? Bool,
              let claimed = entry[AddonPairingProtocol.Field.claimed] as? Bool else { return nil }
        return IncomingManifest(deliveryId: deliveryId,
                                url: url,
                                addedAtMs: addedAt,
                                status: status,
                                attempt: attempt,
                                deliveryRevision: deliveryRevision,
                                retryable: retryable,
                                claimed: claimed)
    }

    /// Mutation routes must prove the full common state response before a report can advance local durable state.
    /// This prevents a forged/weak 2xx body containing only `report.accepted` or `report.claimed` from crossing the
    /// server generation/terminal fence.
    static func isValidMutationResponse(_ object: [String: Any], expectedGeneration: Int? = nil) -> Bool {
        guard object[AddonPairingProtocol.Field.ok] as? Bool == true,
              object[AddonPairingProtocol.Field.duplicate] as? Bool != nil,
              exactInt(object[AddonPairingProtocol.Field.protocolVersion]) == AddonPairingProtocol.version,
              let rawManifests = object[AddonPairingProtocol.Field.manifests] as? [[String: Any]],
              AddonPairingProtocol.canAcceptManifestCount(rawManifests.count),
              rawManifests.allSatisfy({ parseManifest($0) != nil }),
              let generation = exactInt(object[AddonPairingProtocol.Field.authorityGeneration]), generation >= 1,
              expectedGeneration == nil || generation == expectedGeneration,
              let expiresAt = finiteNumeric(object[AddonPairingProtocol.Field.expiresAt]), expiresAt > 0,
              object[AddonPairingProtocol.Field.closed] as? Bool != nil,
              object[AddonPairingProtocol.Field.terminal] as? Bool != nil,
              object[AddonPairingProtocol.Field.released] as? Bool != nil,
              let rev = exactInt(object[AddonPairingProtocol.Field.revision]), rev >= 0,
              object[AddonPairingProtocol.Field.report] as? [String: Any] != nil else { return false }
        return true
    }

    /// A committed release may outlive the live session row after a response-loss retry. The relay's bounded
    /// tombstone is deliberately smaller than a normal mutation response and never echoes manifests or expiry
    /// data; the request's signed body still proves the authority and generation.
    static func isValidReleaseResponse(_ object: [String: Any], expectedGeneration: Int? = nil) -> Bool {
        let tombstoneKeys: Set<String> = [
            AddonPairingProtocol.Field.ok,
            AddonPairingProtocol.Field.duplicate,
            AddonPairingProtocol.Field.protocolVersion,
            AddonPairingProtocol.Field.released,
        ]
        if Set(object.keys) == tombstoneKeys {
            return object[AddonPairingProtocol.Field.ok] as? Bool == true &&
                object[AddonPairingProtocol.Field.duplicate] as? Bool == true &&
                exactInt(object[AddonPairingProtocol.Field.protocolVersion]) == AddonPairingProtocol.version &&
                object[AddonPairingProtocol.Field.released] as? Bool == true
        }
        return isValidMutationResponse(object, expectedGeneration: expectedGeneration)
    }

    /// Signed request → bounded `Data?` (nil on transport error, redirect, oversized body, or non-2xx).
    private static func performData(_ req: URLRequest) async -> Data? {
        guard let (data, response) = await performResponse(req), (200..<300).contains(response.statusCode) else {
            return nil
        }
        return data
    }

    private static func performResponse(_ req: URLRequest) async -> (Data, HTTPURLResponse)? {
        let delegate = AddonPairingNoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse,
                  http.expectedContentLength <= Int64(AddonPairingProtocol.maxResponseBytes) else { return nil }
            var data = Data()
            data.reserveCapacity(min(AddonPairingProtocol.maxResponseBytes, 64 * 1024))
            for try await byte in bytes {
                guard AddonPairingProtocol.canAcceptResponse(currentBytes: data.count, incomingBytes: 1) else { return nil }
                data.append(byte)
            }
            return (data, http)
        } catch {
            return nil
        }
    }
}

/// QR relay API calls must not follow redirects: a fixed same-origin path is part of the authenticated protocol,
/// and following a redirect could expose a signed body or bearer-bearing response handling to another host.
private final class AddonPairingNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
