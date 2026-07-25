import Foundation
import Network
import Combine

/// FINDING THE ENGINE HOST WITHOUT MAKING THE OWNER TYPE AN IP.
///
/// `VortXEngineHostPolicy.normalizeHost` already accepts a hand-typed `192.168.1.33:11471`, and that stays the
/// ground truth: a stored host string is what `mountPlan` gates on, and it is the only thing that survives a
/// relaunch. This file exists purely so the owner does not have to READ that string off a Mac and re-enter it
/// on a TV remote. It advertises the host on the LAN, and it browses for hosts on the client, and it stops
/// there. Nothing here writes a setting, and nothing here starts a session.
///
/// THE ONE RULE THAT IS NOT NEGOTIABLE: **discovery never adopts.** `VortXEngineHostPolicy.mountPlan` says it
/// in its own words ("silently rerouting a user's playback to another machine is not acceptable behaviour, so
/// adoption is always an explicit act that ends in a stored host"), and this file is the half that could most
/// easily violate it. `VortXEngineBrowser` therefore publishes a list and owns no setting, no default, and no
/// "if there is exactly one host, use it" shortcut. A discovered host becomes a configured host only when a
/// human taps it in a UI that lives somewhere else.
///
/// TRANSPORT HONESTY, again. mDNS is unauthenticated and unencrypted broadcast. Everything in the TXT record
/// below is readable by anyone on the Wi-Fi, which is exactly why the TXT record carries only what
/// `VortXEngineProtocol.TXTKey` sanctions (a version, a display name, a capability list) plus the control
/// port. It carries no token, no session id, and no capability material. Discovery is a phone book, not a
/// credential: pairing still happens over HTTP against `/engine/v1/pair`, gated by a code the owner reads off
/// the host's own screen.
///
/// WHAT NETWORK.FRAMEWORK ACTUALLY GIVES US, and the two places it forced the design:
///
/// 1. There is **no advertise-only listener**. `NWListener` always binds a socket (`nw_listener_create_with_port`
///    is the only creation path that takes a port at all, and `nw_listener_set_advertise_descriptor` decorates
///    an already-bound listener). `NWListener.Service` has `name`, `type`, `domain`, `txtRecord` and
///    `noAutoRename`, and deliberately no port field: the SRV port is always the listener's own bound port.
///    See `VortXEngineAdvertisement` for what we do about that.
/// 2. `NWBrowser` yields `NWEndpoint.service(name:type:domain:interface:)`, never an address. There is no
///    resolve-only call (the old `NetService.resolve(withTimeout:)` had one; `NWBrowser` does not). The only
///    supported way to turn a service endpoint into an address is to open an `NWConnection` to it and read
///    `currentPath?.remoteEndpoint` once it is `.ready`. See `VortXEngineBrowser.probe`.
enum VortXEngineDiscovery {

    /// TXT key carrying the REAL control port.
    ///
    /// This is NOT in `VortXEngineProtocol.TXTKey` because the wire contract was written before it was known
    /// that Network.framework cannot advertise a port it does not own, and that file is the shared
    /// specification the Android and desktop clients implement against. It belongs there, and should be moved
    /// into `TXTKey` the next time that file is opened; it lives here so the mechanism is honest today rather
    /// than being faked with a wrong SRV port.
    ///
    /// A client that finds no `port` entry falls back to the SRV port it resolved, and then to
    /// `VortXEngineHostPolicy.defaultControlPort`. That ordering is what lets this key be added, moved or
    /// dropped later without breaking a host that never publishes it.
    static let controlPortTXTKey = "port"

    /// Separator for the capability list. A comma, because `VortXEngineProtocol.Capability` raw values are
    /// lowerCamelCase identifiers and can never contain one, so the encoding is unambiguous without escaping.
    static let capabilitySeparator = ","

    /// Longest Bonjour service INSTANCE name, in UTF-8 bytes. This is a hard mDNS limit (one length-prefixed
    /// label), and exceeding it makes mDNSResponder refuse the registration outright. Enforced here rather
    /// than discovered in the field, because a Mac called "Daksh's 16-inch MacBook Pro (Work)" is normal and a
    /// silent non-registration reads to the owner as "discovery is broken".
    static let maximumInstanceNameBytes = 63

    /// Longest value we will put in any single TXT entry. A TXT key/value pair is length-prefixed with one
    /// byte, so 255 is the absolute ceiling; 200 leaves room for the key and the `=` without arithmetic.
    static let maximumTXTValueBytes = 200

    /// Encode a capability list for the `caps` TXT entry. Sorted by raw value so the record is STABLE: an
    /// unsorted encoding would make a re-advertisement with the same capabilities in a different array order
    /// look like a metadata change to every browser on the LAN, and churn the client's list for nothing.
    static func encodeCapabilities(_ capabilities: [VortXEngineProtocol.Capability]) -> String {
        let unique = Set(capabilities.map(\.rawValue)).sorted()
        return unique.joined(separator: capabilitySeparator)
    }

    /// Decode the `caps` TXT entry. Unknown strings are DROPPED, not rejected: `VortXEngineProtocol.Capability`
    /// documents that "a client MUST treat an unknown capability string as ignore, so a newer host can
    /// advertise more to an older client without breaking it". Rejecting the whole record on one unknown token
    /// would turn every future capability addition into a hard incompatibility.
    static func decodeCapabilities(_ raw: String?) -> [VortXEngineProtocol.Capability] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen = Set<VortXEngineProtocol.Capability>()
        var ordered: [VortXEngineProtocol.Capability] = []
        for token in raw.components(separatedBy: capabilitySeparator) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard let capability = VortXEngineProtocol.Capability(rawValue: trimmed) else { continue }
            guard seen.insert(capability).inserted else { continue }
            ordered.append(capability)
        }
        return ordered
    }

    /// Clamp a string to a UTF-8 byte budget without splitting a character. Bonjour limits are counted in
    /// BYTES, and a name full of emoji or CJK hits them at a quarter of its character count, so truncating by
    /// `String.count` would still produce a registration mDNSResponder refuses.
    static func clamp(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            guard used + width <= limit else { break }
            result.append(character)
            used += width
        }
        return result
    }

    /// The instance name we hand mDNS. Control characters are stripped (a name comes from a text field and a
    /// stray newline would corrupt the record), the result is clamped, and an empty result falls back to a
    /// constant rather than registering a nameless service that no owner could recognise in a list.
    static func sanitizedInstanceName(_ raw: String) -> String {
        let stripped = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let clamped = clamp(trimmed, toUTF8Bytes: maximumInstanceNameBytes)
        return clamped.isEmpty ? "VortX Engine" : clamped
    }

    /// Render an `NWEndpoint.Host` as the bare host text a URL authority needs.
    ///
    /// `IPv4Address` and `IPv6Address` present themselves through `CustomDebugStringConvertible`, which is what
    /// `String(describing:)` resolves to, and which is the standard presentation form (dotted quad, or the
    /// RFC 5952 IPv6 form with a trailing `%zone` on a link-local address).
    static func hostText(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address): return String(describing: address)
        case .ipv6(let address): return String(describing: address)
        case .name(let name, _): return name.isEmpty ? nil : name
        @unknown default: return nil
        }
    }

    /// Compose the authority string that `VortXEngineHostPolicy.normalizeHost` parses back.
    ///
    /// Two things this has to get right, both of which `normalizeHost` cares about:
    ///
    /// - An IPv6 literal is BRACKETED. `normalizeHost` only accepts an IPv6 host with a port in bracketed form,
    ///   because that is "the only form that is unambiguous once a port is appended"; handing it a bare
    ///   `fe80::1:11471` would make it parse the last group as the port.
    /// - A link-local IPv6 zone is percent-encoded to `%25` per RFC 6874. `Foundation.URL` rejects a bare `%`
    ///   in a host, so the verbatim `fe80::1%en0` that the resolver produces would build a nil URL at the exact
    ///   moment the client tries to dial it. The zone is kept rather than dropped because without it a
    ///   link-local address is not routable at all.
    static func authority(host: String, port: Int) -> String {
        guard host.contains(":") else { return "\(host):\(port)" }
        let escaped = host.replacingOccurrences(of: "%", with: "%25")
        return "[\(escaped)]:\(port)"
    }
}

// MARK: - Discovered host

/// One engine host seen on the LAN. A row in a list, and nothing more: holding one of these has no effect on
/// anything, which is the point (see the never-adopts rule at the top of this file).
struct VortXDiscoveredHost: Identifiable, Equatable, Sendable {

    /// Stable across TXT changes and across INTERFACES. `NWBrowser` reports the same host once per interface it
    /// is visible on (Wi-Fi and Ethernet on a Mac with both), and `NWEndpoint.service` carries that interface,
    /// so keying on the endpoint itself would put the same Mac in the list twice. The identity is the Bonjour
    /// instance triple, which is what actually names a service.
    let id: String

    /// What the owner sees. Prefers the `name` TXT entry (the host's own idea of what it is called) over the
    /// Bonjour instance name, because mDNSResponder auto-renames a colliding instance to "Name (2)" and that
    /// suffix is an artefact of the network, not a thing the owner named their Mac.
    let displayName: String

    /// The authoritative dial target, ALWAYS present, even when `resolvedHost` is nil.
    ///
    /// This is handed through deliberately. A `.service` endpoint is the only identifier that survives the host
    /// changing address (DHCP lease, Wi-Fi to Ethernet handover), and it is the thing `NWConnection` can dial
    /// directly. A caller that speaks Network.framework should prefer this; a caller that speaks `URLSession`
    /// cannot use it and needs `address`, which is why both exist rather than one.
    let endpoint: NWEndpoint

    /// `VortXEngineProtocol.version` as the host advertises it, nil when the host published no `v` entry.
    let protocolVersion: Int?

    let capabilities: [VortXEngineProtocol.Capability]

    /// Resolved host text, nil until the resolve probe lands (and permanently nil if it never does). See
    /// `VortXEngineBrowser.probe` for why an address costs a TCP connection.
    let resolvedHost: String?

    /// The port from the `port` TXT entry, nil when the host did not publish one.
    let txtControlPort: Int?

    /// The SRV port the resolve probe actually connected to, nil until resolved.
    let advertisedPort: Int?

    /// THE PORT TO DIAL, resolved through the three-tier fallback the advertiser's design forces:
    ///
    /// 1. the `port` TXT entry, which is the truth when the host advertises through its own throwaway listener
    ///    (the normal case, and the reason the entry exists at all);
    /// 2. the SRV port, which is the truth when a host attaches the service to its real control listener;
    /// 3. `VortXEngineHostPolicy.defaultControlPort`, so a half-broken record still produces a dialable guess
    ///    rather than nothing.
    var controlPort: Int {
        txtControlPort ?? advertisedPort ?? VortXEngineHostPolicy.defaultControlPort
    }

    /// The string to store in the engine-host setting, or nil while unresolved. Round-trips through
    /// `VortXEngineHostPolicy.normalizeHost` by construction.
    var address: String? {
        guard let resolvedHost else { return nil }
        return VortXEngineDiscovery.authority(host: resolvedHost, port: controlPort)
    }

    /// Whether this client knows the host's protocol. `VortXEngineProtocol` says a client "refuses a host whose
    /// major version it does not know rather than guessing at a shape", so a UI should show an incompatible
    /// host greyed out with a reason rather than hiding it: a hidden host looks like a discovery bug to the
    /// owner, and a visible-but-explained one looks like the upgrade prompt it is. A host that published no
    /// version at all is treated as unknown, not as compatible.
    var isProtocolCompatible: Bool { protocolVersion == VortXEngineProtocol.version }
}

#if os(macOS)

/// Builds the Bonjour advertisement for an engine host.
///
/// WHY THIS IS A BUILDER AND NOT A SERVICE. There is no advertise-only API in Network.framework:
/// `nw_listener_create_with_port` is the only creation path that takes a port, `NWListener.Service` has no port
/// field of its own, and `set_advertise_descriptor` only decorates a listener that is already bound. So an
/// "advertiser" object would have to bind its OWN socket on a throwaway port, and the SRV record every other
/// mDNS tool on the network reads would then point at that decoy rather than at the control port. Clients would
/// be fine, because ours read the port from TXT, but `dns-sd` and every third-party browser would be lied to,
/// and a second listener would exist for no reason.
///
/// The host already owns a listener bound to exactly the port we want to advertise. Attaching the service to
/// THAT listener makes the SRV record true, deletes the extra socket, and ties the advertisement's lifetime to
/// the thing it advertises: when the host stops, the advert goes with it, with no second lifecycle to keep in
/// sync. `VortXEngineHost.start` sets `listener.service = VortXEngineAdvertisement.service(...)`.
enum VortXEngineAdvertisement {

    /// `noAutoRename` is left at its default (false) on purpose: two Macs in a household can legitimately be
    /// called the same thing, and mDNSResponder appending " (2)" is the correct outcome. Turning it on would
    /// make the SECOND Mac silently fail to register, which is the worse failure by a distance. The client
    /// shows the `name` TXT entry rather than the instance name precisely so the owner never sees the suffix.
    ///
    /// The control port still goes in TXT even though the SRV port is now correct. It costs a few bytes and it
    /// keeps the client's resolution order (TXT, then SRV, then the default) working unchanged, which means a
    /// client can talk to a host that advertises either way.
    static func service(hostName: String,
                        controlPort: Int,
                        capabilities: [VortXEngineProtocol.Capability]) -> NWListener.Service {
        var txt = NWTXTRecord()
        txt[VortXEngineProtocol.TXTKey.protocolVersion] = String(VortXEngineProtocol.version)
        txt[VortXEngineProtocol.TXTKey.hostName] = VortXEngineDiscovery.clamp(
            hostName, toUTF8Bytes: VortXEngineDiscovery.maximumTXTValueBytes)
        txt[VortXEngineProtocol.TXTKey.capabilities] = VortXEngineDiscovery.clamp(
            VortXEngineDiscovery.encodeCapabilities(capabilities),
            toUTF8Bytes: VortXEngineDiscovery.maximumTXTValueBytes)
        txt[VortXEngineDiscovery.controlPortTXTKey] = String(controlPort)
        return NWListener.Service(
            name: VortXEngineDiscovery.sanitizedInstanceName(hostName),
            type: VortXEngineProtocol.bonjourServiceType,
            domain: nil,   // nil means the default register domains, which on a LAN is `local.`
            txtRecord: txt)
    }
}

#endif

// MARK: - Browsing (client side, every platform)

/// Watches the LAN for engine hosts and publishes what it sees.
///
/// **IT ONLY REPORTS.** Nothing in this type writes a setting, picks a default, or starts a session, and no
/// future edit may add that. `VortXEngineHostPolicy.mountPlan` requires "the user turned it on" plus a stored
/// host, and the stored host must arrive from a human tapping a row. If discovery ever adopts, a household
/// with two Macs silently reroutes a user's playback to whichever one answered mDNS first.
///
/// **ISOLATION.** `@Published` is written on the main queue only, exactly as `ConnectivityMonitor` does, so a
/// SwiftUI list can bind to `hosts` directly with no dispatch of its own. The discovery state behind it lives
/// under `lock` because `NWBrowser` and every resolve `NWConnection` call back on `queue`.
///
/// **NOT A SINGLETON**, unlike the advertiser. A browse is a screen-scoped activity: mDNS traffic while nobody
/// is looking at a host list is waste, and on tvOS it is waste on a device with a small radio budget. Own one
/// as `@StateObject` on the picker screen and let its lifetime end with the screen.
final class VortXEngineBrowser: ObservableObject, @unchecked Sendable {

    /// Every host currently visible, sorted for a stable list. Main queue only.
    @Published private(set) var hosts: [VortXDiscoveredHost] = []

    /// True between the browser reaching `.ready` and being cancelled or failing. Main queue only. Distinct
    /// from `hosts.isEmpty`: "looking and found nothing" and "not looking" are different things to render, and
    /// collapsing them produces a screen that says "no hosts found" when mDNS never started.
    @Published private(set) var isBrowsing = false

    /// How long a resolve probe may take before it is abandoned. Generous enough for a sleeping Mac's radio to
    /// wake, short enough that a stale mDNS record does not hold a row in "resolving" for a visible age. An
    /// abandoned probe is not an error: the row stays, with `address` nil, and the endpoint still usable.
    static let resolveDeadline: TimeInterval = 4

    private let queue = DispatchQueue(label: "tv.vortx.engine.browse", qos: .utility)

    private let lock = NSLock()
    private var browser: NWBrowser?
    /// Live browse results, keyed by `VortXDiscoveredHost.id`.
    private var results: [String: NWBrowser.Result] = [:]
    /// Addresses learned by probing, keyed the same way. Survives a metadata change, because a host that
    /// renames itself has not moved.
    private var resolved: [String: ResolvedAddress] = [:]
    /// Probes in flight, held so `stop()` can cancel them instead of leaking sockets.
    private var probes: [String: NWConnection] = [:]

    private struct ResolvedAddress: Equatable {
        let host: String
        let port: Int
    }

    init() {}

    deinit {
        // A screen-scoped browser that is deallocated without an explicit stop must still release its mDNS
        // registration and any in-flight probe. Touching the fields directly rather than calling `stop()`
        // keeps this free of a main-queue hop that would outlive `self`.
        browser?.cancel()
        probes.values.forEach { $0.cancel() }
    }

    // MARK: Public contract

    /// Begin browsing. Idempotent: a second call while already browsing does nothing at all.
    func start() {
        lock.lock()
        guard browser == nil else {
            lock.unlock()
            return
        }
        // `bonjourWithTXTRecord` rather than plain `bonjour`: the version, name and capability list arrive with
        // the browse result, so a list renders complete without one connection per host. Without it every row
        // would need its own resolve before it could even be labelled.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: VortXEngineProtocol.bonjourServiceType,
            domain: nil
        )
        let parameters = NWParameters.tcp
        // `includePeerToPeer` stays off (its default). An engine host is a Mac on the LAN, and turning it on
        // would light up AWDL to look for hosts that by definition are not there, at a real cost to Wi-Fi.
        let newBrowser = NWBrowser(for: descriptor, using: parameters)
        browser = newBrowser
        lock.unlock()

        newBrowser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.setBrowsing(true)
                DiagnosticsLog.log("engine", "browse: ready")
            case .failed(let error):
                // Terminal for an `NWBrowser`: it does not recover, it has to be recreated. Tearing down here
                // means a caller's later `start()` builds a fresh one instead of no-oping on a dead object.
                DiagnosticsLog.log("engine", "browse: failed: \(String(describing: error))")
                self.stop()
            case .waiting(let error):
                // Typically no network path yet, or the local-network permission prompt. The browser retries on
                // its own, so this stays informational and nothing is torn down.
                DiagnosticsLog.log("engine", "browse: waiting: \(String(describing: error))")
            case .cancelled:
                self.setBrowsing(false)
            default:
                break
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            // The full result set is used and the change set is ignored on purpose. Reconciling adds, removes
            // and metadata changes by hand is where duplicate and ghost rows come from; rebuilding from the
            // authoritative set is the same work and cannot drift from it.
            self?.apply(results)
        }

        newBrowser.start(queue: queue)
    }

    /// Stop browsing, drop everything found, and cancel every probe in flight. Idempotent.
    func stop() {
        lock.lock()
        let live = browser
        browser = nil
        let open = Array(probes.values)
        probes.removeAll()
        results.removeAll()
        resolved.removeAll()
        lock.unlock()

        guard live != nil || !open.isEmpty else { return }
        live?.cancel()
        open.forEach { $0.cancel() }
        publish([])
        setBrowsing(false)
        DiagnosticsLog.log("engine", "browse: stopped")
    }

    /// Re-run the resolve probe for one host. For a UI that offers a retry on a row whose `address` never
    /// arrived; also the right call after a network change, since a host that moved keeps its identity and
    /// would otherwise keep serving a stale address.
    func reresolve(_ host: VortXDiscoveredHost) {
        lock.lock()
        resolved[host.id] = nil
        let result = results[host.id]
        let alreadyProbing = probes[host.id] != nil
        let snapshot = buildLocked()
        lock.unlock()
        publish(snapshot)
        guard let result, !alreadyProbing else { return }
        probe(key: host.id, result: result)
    }

    // MARK: Result reconciliation

    private func apply(_ incoming: Set<NWBrowser.Result>) {
        var byKey: [String: NWBrowser.Result] = [:]
        for result in incoming {
            guard let key = Self.identity(for: result.endpoint) else { continue }
            byKey[key] = result
        }

        lock.lock()
        results = byKey
        // A host that went away takes its address with it: keeping one would resurrect a dead row the moment
        // the host reappeared under a different lease.
        resolved = resolved.filter { byKey[$0.key] != nil }
        let orphaned = probes.filter { byKey[$0.key] == nil }
        for (key, connection) in orphaned {
            probes[key] = nil
            connection.cancel()
        }
        let pending = byKey.filter { resolved[$0.key] == nil && probes[$0.key] == nil }
        let snapshot = buildLocked()
        lock.unlock()

        publish(snapshot)
        // Outside the lock: `probe` takes it, and an mDNS callback is not a place to discover a deadlock.
        for (key, result) in pending {
            probe(key: key, result: result)
        }
    }

    /// Turn a service endpoint into the stable identity used everywhere else. The interface is dropped
    /// deliberately, see `VortXDiscoveredHost.id`.
    private static func identity(for endpoint: NWEndpoint) -> String? {
        guard case let .service(name, type, domain, _) = endpoint else { return nil }
        return "\(name)|\(type)|\(domain)"
    }

    /// Build the published snapshot. Caller must hold `lock`.
    private func buildLocked() -> [VortXDiscoveredHost] {
        results.compactMap { key, result -> VortXDiscoveredHost? in
            guard case let .service(instanceName, _, _, _) = result.endpoint else { return nil }
            var txt = NWTXTRecord()
            if case let .bonjour(record) = result.metadata { txt = record }

            var displayName = instanceName
            if let advertised = txt[VortXEngineProtocol.TXTKey.hostName]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !advertised.isEmpty {
                displayName = advertised
            }
            let address = resolved[key]

            return VortXDiscoveredHost(
                id: key,
                displayName: displayName,
                endpoint: result.endpoint,
                protocolVersion: txt[VortXEngineProtocol.TXTKey.protocolVersion].flatMap { Int($0) },
                capabilities: VortXEngineDiscovery.decodeCapabilities(txt[VortXEngineProtocol.TXTKey.capabilities]),
                resolvedHost: address?.host,
                txtControlPort: Self.port(from: txt[VortXEngineDiscovery.controlPortTXTKey]),
                advertisedPort: address?.port
            )
        }
        // Name first so the list reads the way the owner thinks about their machines; identity second so two
        // Macs with the same name still hold a fixed order instead of shuffling on every update.
        .sorted { ($0.displayName.lowercased(), $0.id) < ($1.displayName.lowercased(), $1.id) }
    }

    /// Parse a TXT port. Anything out of range is treated as absent rather than clamped: a nonsense value is a
    /// broken host, and falling back to the SRV port or the documented default is more likely to be right than
    /// a number invented from a malformed one.
    private static func port(from raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard value > 0, value <= 65535 else { return nil }
        return value
    }

    // MARK: Address resolution

    /// Turn a `.service` endpoint into an actual address.
    ///
    /// **THIS COSTS A TCP CONNECTION, AND THERE IS NO WAY AROUND IT.** `NWBrowser` reports
    /// `NWEndpoint.service(name:type:domain:interface:)` and nothing else; Network.framework exposes no
    /// resolve-only call (the deprecated `NetService.resolve(withTimeout:)` did, and is the only API that ever
    /// did). The supported technique is to open an `NWConnection` to the service endpoint and read
    /// `currentPath?.remoteEndpoint` once it reaches `.ready`, which is what happens below. The connection
    /// sends no bytes and is cancelled the moment the address is in hand.
    ///
    /// The host end of this is the throwaway advertisement listener, which accepts and immediately closes, so
    /// the handshake completes and `.ready` fires before the peer's FIN arrives. If it does not, the probe
    /// simply fails and the row stays unresolved with its endpoint intact, which is why
    /// `VortXDiscoveredHost.endpoint` is always populated and `address` is optional.
    private func probe(key: String, result: NWBrowser.Result) {
        let parameters = NWParameters.tcp
        // An engine host is never across a cellular link. Prohibiting it stops a probe from ever waking an
        // iPhone's radio to chase a LAN service, and makes an unreachable host fail fast instead of waiting.
        parameters.prohibitedInterfaceTypes = [.cellular]

        let connection = NWConnection(to: result.endpoint, using: parameters)
        lock.lock()
        probes[key] = connection
        lock.unlock()

        // `NWConnection` sits in `.waiting` and retries indefinitely when it cannot reach a peer, so it will
        // never report failure on its own for a host that has gone quiet. The deadline is what makes this
        // bounded, and it is the only reason a probe cannot leak a socket for the life of the process.
        let deadline = DispatchWorkItem { [weak self] in
            DiagnosticsLog.log("engine", "browse: resolve timed out")
            self?.finishProbe(key: key, address: nil)
        }
        queue.asyncAfter(deadline: .now() + Self.resolveDeadline, execute: deadline)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                deadline.cancel()
                let address = connection.flatMap { Self.address(from: $0.currentPath?.remoteEndpoint) }
                if address == nil {
                    DiagnosticsLog.log("engine", "browse: connection ready but path had no host:port")
                }
                self.finishProbe(key: key, address: address)
            case .failed(let error):
                deadline.cancel()
                DiagnosticsLog.log("engine", "browse: resolve failed: \(String(describing: error))")
                self.finishProbe(key: key, address: nil)
            case .cancelled:
                deadline.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Retire one probe and publish the result. Safe to call more than once for the same key: the second call
    /// finds no connection and returns, which is what makes the deadline and the state handler racing each
    /// other harmless.
    private func finishProbe(key: String, address: ResolvedAddress?) {
        lock.lock()
        guard let connection = probes.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        // Only record an address for a host that is still being advertised. A probe that lands after the host
        // vanished would otherwise write into a dictionary `apply` has already pruned.
        if let address, results[key] != nil {
            resolved[key] = address
        }
        let snapshot = buildLocked()
        lock.unlock()

        connection.cancel()
        publish(snapshot)
    }

    private static func address(from endpoint: NWEndpoint?) -> ResolvedAddress? {
        guard case let .hostPort(host, port)? = endpoint else { return nil }
        guard let text = VortXEngineDiscovery.hostText(host) else { return nil }
        return ResolvedAddress(host: text, port: Int(port.rawValue))
    }

    // MARK: Publishing

    private func publish(_ snapshot: [VortXDiscoveredHost]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hosts != snapshot else { return }
            self.hosts = snapshot
        }
    }

    private func setBrowsing(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isBrowsing != value else { return }
            self.isBrowsing = value
        }
    }
}
