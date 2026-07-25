import Foundation

/// PAIRING: how a client earns the right to ask an engine host to do work for it.
///
/// The threat this exists for is specific and worth naming, because it decides the shape. The dangerous
/// surface is not the media: it is `POST /engine/v1/session`, which accepts a URL PLUS HEADERS and makes the
/// host fetch it. Unauthenticated, that is a request-forgery proxy sitting on the household network, and the
/// headers a VortX client sends carry the owner's debrid token. So the control surface requires a bearer
/// token, and a bearer token can only be obtained by completing a pairing the owner physically approved.
///
/// The media surface is protected differently, by an unguessable capability in the URL path
/// (`VortXEngineHostPolicy`), because AVFoundation's propagation of custom headers to HLS CHILD requests is not
/// something to bet a Dolby Vision lane on, while a path prefix authenticates every child fetch for free.
///
/// WHY A SIX-DIGIT CODE IS ENOUGH, stated honestly rather than assumed. Six digits is a million possibilities,
/// which is not much entropy. It is defended by three things that matter more than length here:
///   1. The window only exists while the owner has deliberately opened it (five minutes, `pairingWindowSeconds`).
///   2. Five wrong attempts close it (`pairingAttemptLimit`). An attacker gets five guesses out of a million,
///      once, while a human is watching a screen that says pairing is open.
///   3. The attacker must already be on the household LAN.
/// A longer code would trade real usability on a TV remote for a defence the attempt cap already provides.
///
/// This type is PURE and platform-agnostic on purpose: no Keychain, no sockets, no clock of its own. Time is an
/// argument. That makes every rule above provable by a standalone test instead of by inspection, which is the
/// same reason `VXDiagExportPolicy` was split out of `VXDiagExport`.
struct VortXEnginePairingState: Equatable {

    /// The live code, or nil when pairing is closed. Never persisted: a code does not survive a restart, so a
    /// forgotten open window closes itself when the host process does.
    private(set) var code: String?
    /// Monotonic instant the window closes. Meaningless while `code` is nil.
    private(set) var expiresAt: TimeInterval = 0
    /// Wrong attempts inside the current window.
    private(set) var failedAttempts = 0

    init() {}

    /// Open a pairing window and return the code to display. Opening again REPLACES the code and resets the
    /// attempt count, so an owner who closes and reopens the screen is not handed a window an attacker already
    /// spent guesses against.
    mutating func open(now: TimeInterval,
                       code: String = VortXEngineProtocol.makePairingCode()) -> String {
        self.code = code
        expiresAt = now + VortXEngineProtocol.pairingWindowSeconds
        failedAttempts = 0
        return code
    }

    mutating func close() {
        code = nil
        expiresAt = 0
        failedAttempts = 0
    }

    func isOpen(now: TimeInterval) -> Bool {
        guard code != nil else { return false }
        return now < expiresAt
    }

    /// Seconds left in the window, 0 when closed. For the countdown the owner sees.
    func remainingSeconds(now: TimeInterval) -> TimeInterval {
        guard isOpen(now: now) else { return 0 }
        return max(0, expiresAt - now)
    }

    enum Outcome: Equatable {
        case paired
        /// The code was wrong and the window is still open. Carries what is left so the UI can warn.
        case wrongCode(attemptsRemaining: Int)
        /// No window is open, or it expired. Deliberately NOT distinguished from "wrong code" in what the host
        /// returns over the wire, so a prober cannot use the difference to detect an open window.
        case closed
    }

    /// Judge one submitted code. A correct code CLOSES the window: pairing is a one-shot act, and leaving the
    /// window open afterwards would let a second device pair off the same displayed code without the owner
    /// doing anything.
    mutating func submit(code typed: String, now: TimeInterval) -> Outcome {
        guard isOpen(now: now), let expected = code else {
            close()
            return .closed
        }
        if VortXEngineProtocol.pairingCodeMatches(typed: typed, expected: expected) {
            close()
            return .paired
        }
        failedAttempts += 1
        let remaining = VortXEngineProtocol.pairingAttemptLimit - failedAttempts
        if remaining <= 0 {
            close()
            return .closed
        }
        return .wrongCode(attemptsRemaining: remaining)
    }
}

/// One device the owner has paired, as the host remembers it.
///
/// The TOKEN IS NOT HERE. This is the index the owner sees and manages; the secret lives in the Keychain keyed
/// by `clientID`. Keeping them apart means the list can be read, rendered and persisted in the clear without
/// the credential ever being in a plist or a settings backup.
struct VortXPairedDevice: Codable, Equatable, Sendable {
    /// Stable per-install identifier supplied by the client. Re-pairing the same device REPLACES its entry
    /// rather than adding one, so a client that pairs repeatedly does not accumulate live tokens.
    let clientID: String
    /// What the client called itself. Shown to the owner so a revoke targets the right device.
    var clientName: String
    /// Unix seconds. Informational, for the owner's list.
    var pairedAt: Double
    var lastSeenAt: Double
}

/// The paired-device index and its token side-table.
///
/// Split into a protocol so the pure logic (add, replace, revoke, authorise) can be tested against an in-memory
/// store, and so the real Keychain is only ever touched by the app.
protocol VortXEngineTokenStore: AnyObject {
    func token(forClientID clientID: String) -> String?
    func setToken(_ token: String?, forClientID clientID: String)
}

/// In-memory token store. Used by tests, and as the fallback when no Keychain is available.
final class VortXEngineMemoryTokenStore: VortXEngineTokenStore {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()

    init() {}

    func token(forClientID clientID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens[clientID]
    }

    func setToken(_ token: String?, forClientID clientID: String) {
        lock.lock(); defer { lock.unlock() }
        if let token { tokens[clientID] = token } else { tokens.removeValue(forKey: clientID) }
    }
}

/// The host's registry of who may call it. Thread-safe; every method may be called from a connection queue.
final class VortXEnginePairingRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var devices: [VortXPairedDevice]
    private let tokens: VortXEngineTokenStore
    private let persist: ([VortXPairedDevice]) -> Void

    /// A host will not hold more paired devices than this. Not a security bound (each one was individually
    /// approved by the owner); it is a bound on an index a human has to be able to read and manage.
    static let maximumDevices = 32

    init(devices: [VortXPairedDevice] = [],
         tokens: VortXEngineTokenStore,
         persist: @escaping ([VortXPairedDevice]) -> Void = { _ in }) {
        self.devices = devices
        self.tokens = tokens
        self.persist = persist
    }

    var pairedDevices: [VortXPairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return devices.isEmpty
    }

    /// Mint and record a token for a client that just completed pairing. Replaces any existing entry for the
    /// same `clientID`, which also RETIRES that client's previous token: a device that re-pairs gets exactly
    /// one live credential, never two.
    @discardableResult
    func register(clientID: String, clientName: String, now: Double,
                  token: String = VortXEngineProtocol.makeToken()) -> String? {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.count <= 128 else { return nil }
        let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if let index = devices.firstIndex(where: { $0.clientID == trimmedID }) {
            devices[index].clientName = name.isEmpty ? devices[index].clientName : name
            devices[index].pairedAt = now
            devices[index].lastSeenAt = now
        } else {
            guard devices.count < Self.maximumDevices else { lock.unlock(); return nil }
            devices.append(VortXPairedDevice(
                clientID: trimmedID,
                clientName: name.isEmpty ? "VortX client" : name,
                pairedAt: now,
                lastSeenAt: now))
        }
        let snapshot = devices
        lock.unlock()
        tokens.setToken(token, forClientID: trimmedID)
        persist(snapshot)
        return token
    }

    /// Is this bearer token one of ours? Returns the owning device, and stamps its last-seen time so the
    /// owner's list shows which devices are actually in use.
    ///
    /// The scan is linear over at most `maximumDevices` entries and compares full 256-bit tokens for equality.
    /// A timing side channel on a comparison of high-entropy random tokens over a LAN is not a practical
    /// concern, and pretending otherwise with a constant-time compare here would be security theatre while the
    /// same bytes travel in cleartext.
    func authorize(token: String, now: Double) -> VortXPairedDevice? {
        guard !token.isEmpty else { return nil }
        lock.lock()
        let candidates = devices
        lock.unlock()
        for device in candidates where tokens.token(forClientID: device.clientID) == token {
            lock.lock()
            if let index = devices.firstIndex(where: { $0.clientID == device.clientID }) {
                devices[index].lastSeenAt = now
            }
            lock.unlock()
            return device
        }
        return nil
    }

    func revoke(clientID: String) {
        lock.lock()
        devices.removeAll { $0.clientID == clientID }
        let snapshot = devices
        lock.unlock()
        tokens.setToken(nil, forClientID: clientID)
        persist(snapshot)
    }

    func revokeAll() {
        lock.lock()
        let doomed = devices
        devices = []
        lock.unlock()
        for device in doomed { tokens.setToken(nil, forClientID: device.clientID) }
        persist([])
    }
}
