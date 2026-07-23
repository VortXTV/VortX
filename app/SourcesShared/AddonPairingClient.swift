import Foundation

/// Client for the "Install by QR / pair once, add many" add-on pairing relay at `add.vortx.tv`.
///
/// THE FLOW: the TV creates a pairing SESSION (`POST /pair/new`) and renders the returned `pageUrl`
/// as a QR. The user's phone opens that page and pastes one or more add-on manifest URLs, which the
/// relay appends to the session's list. The TV POLLS the session (`GET /pair/<token>`) to see the
/// live incoming list, then installs each manifest through the app's OWN hardened install path
/// (`CoreBridge.installAddon`) after a TV-side confirm. The relay is a DUMB PIPE: it only carries
/// URL strings; the TV validates and installs.
///
/// SIGNING: `add.vortx.tv` is a gated VortX host (see `VortXEdgeAuth.gatedHosts`), so both routes are
/// HMAC-signed with `VortXEdgeAuth.sign(&req)`. Signing is a no-op without a provisioned secret, which
/// the worker's observe mode lets through, so the flow works in every build.
enum AddonPairingClient {
    /// The relay base. HTTPS only; the host must stay in `VortXEdgeAuth.gatedHosts` for signing.
    private static let baseURL = URL(string: "https://add.vortx.tv")!

    /// A freshly created pairing session: the QR target (`pageUrl`), the poll `token`, and the
    /// session expiry (unix ms). The TV renders `pageUrl` as the QR and polls with `token`.
    struct Session: Equatable {
        let token: String
        let pageUrl: String
        let expiresAtMs: Double

        /// Wall-clock expiry as a `Date`, so the view can decide when to rotate the session.
        var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// One manifest URL the phone has added to the session, with when it landed (unix ms).
    struct IncomingManifest: Equatable, Identifiable {
        let url: String
        let addedAtMs: Double
        /// Stable identity so SwiftUI rows keep their per-row install state as the list grows.
        var id: String { url }
    }

    /// The current state of a polled session: the live list plus whether it expired or was closed.
    struct Poll: Equatable {
        let manifests: [IncomingManifest]
        let expiresAtMs: Double
        let closed: Bool

        var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// A poll outcome. `.gone` maps the relay's 404 (expired / unknown token) so the view can rotate
    /// to a fresh session instead of spinning on a dead one.
    enum PollResult: Equatable {
        case ok(Poll)
        case gone
        case failed
    }

    // MARK: - POST /pair/new

    /// Create a new pairing session. Returns nil on any failure so the view can show a retry.
    static func createSession() async -> Session? {
        var req = URLRequest(url: baseURL.appendingPathComponent("pair/new"), timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)   // gated host (add.vortx.tv /pair/new POST): stamp X-VX-Ts / X-VX-Sig

        guard let data = await performData(req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty,
              let pageUrl = obj["pageUrl"] as? String, !pageUrl.isEmpty,
              let expiresAt = numeric(obj["expiresAt"]) else { return nil }
        return Session(token: token, pageUrl: pageUrl, expiresAtMs: expiresAt)
    }

    // MARK: - GET /pair/<token>

    /// Poll a session's live manifest list. A 404 becomes `.gone` (expired / unknown token).
    static func poll(token: String) async -> PollResult {
        // Percent-encode the token into the path so a stray character can't break the URL.
        let safeToken = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        var req = URLRequest(url: baseURL.appendingPathComponent("pair").appendingPathComponent(safeToken),
                             timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)   // gated host (add.vortx.tv /pair/<token> GET): stamp X-VX-Ts / X-VX-Sig

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .gone }
            guard (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
            let rawManifests = (obj["manifests"] as? [[String: Any]]) ?? []
            let manifests: [IncomingManifest] = rawManifests.compactMap { entry in
                guard let url = entry["url"] as? String, !url.isEmpty else { return nil }
                return IncomingManifest(url: url, addedAtMs: numeric(entry["addedAt"]) ?? 0)
            }
            let expiresAt = numeric(obj["expiresAt"]) ?? 0
            let closed = (obj["closed"] as? Bool) ?? false
            return .ok(Poll(manifests: manifests, expiresAtMs: expiresAt, closed: closed))
        } catch {
            return .failed
        }
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

    /// Signed request → `Data?` (nil on transport error or non-2xx), matching the other edge clients.
    private static func performData(_ req: URLRequest) async -> Data? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

/// The per-device INSTALL LEDGER for one TV QR pairing session: the small, pure decision core that binds
/// each phone submission to the CURRENT one-time session, admits it EXACTLY ONCE, and tracks its install
/// lifecycle. It performs NO network and NO engine work — `AddonPairingView` does the fetch + validate +
/// install through `CoreBridge` (the one canonical installer) and feeds the outcomes back here. Extracted
/// out of the view precisely so the session-binding, idempotency, and rejection rules are unit-testable
/// without the engine or SwiftUI (Foundation only; see `app/Tests/AddonPairingInstallLedgerTests.swift`).
///
/// THE CONTRACT the view relies on, and the tests pin:
///  - a submission is admitted only if it belongs to the current session token (else `.wrongSession`),
///    the session has not expired (`.expired`), the URL normalizes to an http(s) manifest (`.malformed`),
///    and that normalized identity has not already been admitted this session (`.duplicate`);
///  - a rejection is a pure no-op: it never appends a row and never records the URL, so a replayed /
///    stale / malformed delivery leaves NO partial state and can never trigger a second install;
///  - `admitted` is keyed by the SAME normalized identity `CoreBridge.installAddon` installs under, so a
///    duplicate relay delivery (or two URL spellings of one add-on) can never install the add-on twice.
struct AddonPairingLedger: Equatable {
    /// One admitted submission and where it sits in the install lifecycle ON THIS device. `url` is the
    /// NORMALIZED identity (what the installer keys on, and what dedup compares); `displayURL` is the raw
    /// string the phone sent, shown until the manifest name resolves.
    struct Row: Identifiable, Equatable {
        let url: String
        let displayURL: String
        var name: String?
        var state: State = .resolving
        var id: String { url }

        enum State: Equatable {
            case resolving           // fetching + validating the manifest
            case ready               // valid manifest, install about to fire (or a manual-recovery tap)
            case invalid             // manifest failed validation (not installable)
            case installing
            case installed
            case failed(String)

            /// Whether a manual tap on this row can do anything — the SINGLE source of truth for whether the
            /// row's recovery control is actionable, and therefore (on tvOS) whether it takes focus. The view
            /// disables the row button on `!isManuallyActionable`, so a disabled (installed / in-flight /
            /// invalid) row is correctly skipped by the focus engine while a `.ready` / `.failed` row stays
            /// reachable. Pinned by test so a change that makes a recoverable row non-actionable turns RED.
            var isManuallyActionable: Bool {
                switch self {
                case .ready:   return true
                case .failed:  return true
                default:       return false
                }
            }
        }
    }

    /// Why a submission was NOT admitted. Every case is a pure no-op (no row, no `admitted` entry).
    enum Rejection: Equatable { case malformed, expired, wrongSession, duplicate }

    /// The outcome of offering one raw URL to the ledger.
    enum Admit: Equatable {
        case accepted(url: String)      // normalized identity; a `.resolving` row now exists for it
        case rejected(Rejection)
    }

    /// A coarse roll-up the view uses for the `Done` button label and the summary line, so `Done` can
    /// never silently mean "leave without installing": while anything is in flight it reads as working.
    enum Overall: Equatable { case empty, working, allInstalled, someFailed }

    private(set) var sessionToken: String?
    private(set) var sessionExpiresAtMs: Double = 0
    private(set) var rows: [Row] = []
    /// Normalized URLs already admitted THIS session: the idempotency + replay guard. Cleared only when the
    /// bound session token actually changes (a genuinely new one-time session), never on an expiry refresh.
    private var admitted: Set<String> = []

    // MARK: - Session binding

    /// Bind (or refresh) the current one-time session. A DIFFERENT token is a brand-new session: the rows
    /// and the dedup ledger reset, so nothing from a previous QR bleeds in. The SAME token only slides the
    /// expiry forward (the relay extends a live session on each poll), preserving in-progress installs.
    mutating func bind(token: String, expiresAtMs: Double) {
        if sessionToken != token {
            rows = []
            admitted = []
        }
        sessionToken = token
        sessionExpiresAtMs = expiresAtMs
    }

    // MARK: - Admission (the one gate every phone submission passes through)

    /// Offer one raw URL, delivered by the relay for `sessionToken`, to the current session. Returns
    /// `.accepted` (a fresh `.resolving` row now exists) or `.rejected` with the reason. `normalize` MUST be
    /// the installer's own normalization (`CoreBridge.normalizedAddonURL`) so the admitted identity matches
    /// what will be installed. `now` is injected so expiry is testable.
    mutating func admit(rawURL: String,
                        sessionToken: String,
                        now: Date,
                        normalize: (String) -> String?) -> Admit {
        // Wrong session first: a late poll response from a rotated-away token must never land in the new
        // session. `bind` has already reset for the new token, so this is what stops cross-session bleed.
        guard let current = self.sessionToken, current == sessionToken else {
            return .rejected(.wrongSession)
        }
        // Expired: the view keeps `sessionExpiresAtMs` fresh from each poll, so this fires only for a truly
        // dead session (belt-and-braces behind the view's own rotation).
        guard now.timeIntervalSince1970 * 1000 < sessionExpiresAtMs else {
            return .rejected(.expired)
        }
        // Malformed: not an http(s) URL that can carry a manifest. Same gate the installer applies.
        guard let normalized = normalize(rawURL), !normalized.isEmpty else {
            return .rejected(.malformed)
        }
        // Duplicate / replay: this identity was already admitted this session. No second row, no second
        // install — the relay re-delivers the whole list every poll, so this is the common path, not a rare one.
        guard !admitted.contains(normalized) else {
            return .rejected(.duplicate)
        }
        admitted.insert(normalized)
        rows.append(Row(url: normalized, displayURL: rawURL, name: nil, state: .resolving))
        return .accepted(url: normalized)
    }

    // MARK: - Lifecycle transitions (the view calls these as its async work completes)

    mutating func markResolvedInstallable(url: String, name: String) { setState(url, .ready) { $0.name = name } }
    mutating func markResolvedAlreadyInstalled(url: String, name: String) { setState(url, .installed) { $0.name = name } }
    mutating func markInvalid(url: String) { setState(url, .invalid) }
    mutating func markInstalling(url: String) { setState(url, .installing) }
    mutating func markInstalled(url: String) { setState(url, .installed) }
    mutating func markFailed(url: String, message: String) { setState(url, .failed(message)) }

    private mutating func setState(_ url: String, _ state: Row.State, _ extra: (inout Row) -> Void = { _ in }) {
        guard let idx = rows.firstIndex(where: { $0.url == url }) else { return }
        var row = rows[idx]
        row.state = state
        extra(&row)
        rows[idx] = row
    }

    // MARK: - Roll-ups for the view chrome

    /// Rows that are installable-now and should auto-install (or accept a manual Install tap).
    var readyURLs: [String] { rows.filter { $0.state == .ready }.map(\.url) }
    var inFlightCount: Int { rows.filter { $0.state == .resolving || $0.state == .installing }.count }
    var installedCount: Int { rows.filter { $0.state == .installed }.count }
    var failedCount: Int { rows.filter { if case .failed = $0.state { return true } else { return false } }.count }
    /// True while any row is still resolving, waiting to install, or installing — the window in which
    /// `Done` must NOT read as a clean exit.
    var hasUnsettled: Bool { rows.contains { $0.state == .resolving || $0.state == .ready || $0.state == .installing } }

    var overall: Overall {
        if rows.isEmpty { return .empty }
        if hasUnsettled { return .working }
        if failedCount > 0 { return .someFailed }
        return .allInstalled
    }
}
