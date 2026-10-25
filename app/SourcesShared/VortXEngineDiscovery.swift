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

    /// Forward discovery output through the canonical authority renderer used by persistence and every control
    /// or media URL. Network.framework can attach an interface zone to IPv4 as well as IPv6 on a multi-homed
    /// Mac, so zone escaping cannot live only inside the IPv6 branch.
    static func authority(host: String, port: Int) -> String {
        VortXEngineHostPolicy.authority(host: host, port: port)
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

/// Sole ARC lifetime for non-Sendable Network resources on iOS 16. This private object is held
/// only by the main-actor browser below; no callback, Task, executor or public API receives it.
/// Its ordinary exclusive deinit can release its own handles without borrowing actor state.
/// There is intentionally NO Sendable conformance, lock box, unchecked assertion or floor bump.
private final class VortXEngineDiscoveryResources {
    struct Probe {
        let id: UUID
        let connection: NWConnection
    }

    var browser: NWBrowser?
    var probes: [String: Probe] = [:]

    deinit {
        browser?.cancel()
        probes.values.forEach { $0.connection.cancel() }
    }
}

/// Watches the LAN for engine hosts and publishes what it sees.
///
/// **IT ONLY REPORTS.** Nothing in this type writes a setting, picks a default, or starts a session, and no
/// future edit may add that. `VortXEngineHostPolicy.mountPlan` requires "the user turned it on" plus a stored
/// host, and the stored host must arrive from a human tapping a row. If discovery ever adopts, a household
/// with two Macs silently reroutes a user's playback to whichever one answered mDNS first.
///
/// **ISOLATION.** One main-actor reducer owns both the published list and discovery state. Network
/// callbacks may arrive on the utility queue: only checked Sendable values cross to the main queue.
/// Original browse/probe UUIDs veto callbacks and deadlines from stopped or replaced operations.
///
/// **NOT A SINGLETON**, unlike the advertiser. A browse is a screen-scoped activity: mDNS traffic while nobody
/// is looking at a host list is waste, and on tvOS it is waste on a device with a small radio budget. Own one
/// as `@StateObject` on the picker screen and let its lifetime end with the screen.
@MainActor
final class VortXEngineBrowser: ObservableObject {
    @Published private(set) var hosts: [VortXDiscoveredHost] = []
    @Published private(set) var isBrowsing = false

    static let resolveDeadline: TimeInterval = 4
    private let queue = DispatchQueue(label: "tv.vortx.engine.browse", qos: .utility)
    private let resources = VortXEngineDiscoveryResources()
    private var browseGeneration: UUID?
    private var results: [String: NWBrowser.Result] = [:]
    private var resolved: [String: ResolvedAddress] = [:]

    private struct ResolvedAddress: Equatable, Sendable {
        let host: String
        let port: Int
    }

    init() {}

    /// Idempotent start. There is no settings write, pairing, default selection or implicit adoption.
    func start() {
        guard resources.browser == nil else { return }
        let generation = UUID()
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: VortXEngineProtocol.bonjourServiceType, domain: nil
        )
        let newBrowser = NWBrowser(for: descriptor, using: .tcp)
        browseGeneration = generation
        resources.browser = newBrowser

        // Network does not promise main-actor delivery. Its checked Sendable state/result values
        // enter one serial main reducer; no unstructured Task ordering is assumed.
        newBrowser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.browseGeneration == generation else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                    DiagnosticsLog.log("engine", "browse: ready")
                case .failed(let error):
                    DiagnosticsLog.log("engine", "browse: failed: \(String(describing: error))")
                    self.stop()
                case .waiting(let error):
                    DiagnosticsLog.log("engine", "browse: waiting: \(String(describing: error))")
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }
        newBrowser.browseResultsChangedHandler = { [weak self] incoming, _ in
            DispatchQueue.main.async { [weak self] in
                self?.apply(incoming, generation: generation)
            }
        }
        newBrowser.start(queue: queue)
    }

    /// Revoke the original browse BEFORE cancellation; old terminal callbacks cannot stop a new one.
    func stop() {
        browseGeneration = nil
        let live = resources.browser
        resources.browser = nil
        let open = Array(resources.probes.values)
        resources.probes.removeAll()
        results.removeAll()
        resolved.removeAll()
        hosts = []
        isBrowsing = false
        live?.cancel()
        open.forEach { $0.connection.cancel() }
        if live != nil || !open.isEmpty {
            DiagnosticsLog.log("engine", "browse: stopped")
        }
    }

    func reresolve(_ host: VortXDiscoveredHost) {
        guard let generation = browseGeneration else { return }
        resolved[host.id] = nil
        let result = results[host.id]
        let alreadyProbing = resources.probes[host.id] != nil
        publishSnapshot()
        guard let result, !alreadyProbing else { return }
        probe(key: host.id, result: result, generation: generation)
    }

    private func apply(_ incoming: Set<NWBrowser.Result>, generation: UUID) {
        guard browseGeneration == generation else { return }
        var byKey: [String: NWBrowser.Result] = [:]
        for result in incoming {
            guard let key = Self.identity(for: result.endpoint) else { continue }
            byKey[key] = result
        }
        results = byKey
        resolved = resolved.filter { byKey[$0.key] != nil }
        let orphaned = resources.probes.filter { byKey[$0.key] == nil }
        for key in orphaned.keys { resources.probes[key] = nil }
        let pending = byKey.filter { resolved[$0.key] == nil && resources.probes[$0.key] == nil }
        publishSnapshot()
        orphaned.values.forEach { $0.connection.cancel() }
        for (key, result) in pending {
            probe(key: key, result: result, generation: generation)
        }
    }

    private static func identity(for endpoint: NWEndpoint) -> String? {
        guard case let .service(name, type, domain, _) = endpoint else { return nil }
        return "\(name)|\(type)|\(domain)"
    }

    private func publishSnapshot() {
        let snapshot = results.compactMap { key, result -> VortXDiscoveredHost? in
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
                id: key, displayName: displayName, endpoint: result.endpoint,
                protocolVersion: txt[VortXEngineProtocol.TXTKey.protocolVersion].flatMap { Int($0) },
                capabilities: VortXEngineDiscovery.decodeCapabilities(txt[VortXEngineProtocol.TXTKey.capabilities]),
                resolvedHost: address?.host,
                txtControlPort: Self.port(from: txt[VortXEngineDiscovery.controlPortTXTKey]),
                advertisedPort: address?.port
            )
        }.sorted { ($0.displayName.lowercased(), $0.id) < ($1.displayName.lowercased(), $1.id) }
        if hosts != snapshot { hosts = snapshot }
    }

    private static func port(from raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard value > 0, value <= 65535 else { return nil }
        return value
    }

    /// A resolve probe sends no application data; it only learns the ready connection's host/port.
    private func probe(key: String, result: NWBrowser.Result, generation: UUID) {
        guard browseGeneration == generation, results[key] == result, resources.probes[key] == nil else { return }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(to: result.endpoint, using: parameters)
        let probeID = UUID()
        resources.probes[key] = VortXEngineDiscoveryResources.Probe(id: probeID, connection: connection)

        // A value-only deadline needs no non-Sendable work item captured by the Network callback.
        // Early completion removes the original probe; its later deadline becomes an exact-ID no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveDeadline) { [weak self] in
            guard let self, self.browseGeneration == generation, self.resources.probes[key]?.id == probeID else { return }
            DiagnosticsLog.log("engine", "browse: resolve timed out")
            self.finishProbe(key: key, probeID: probeID, generation: generation, address: nil)
        }
        connection.stateUpdateHandler = { [weak self] state in
            // State is Sendable at iOS 12. The raw connection is NOT captured or transferred:
            // its Sendable conformance starts at iOS 17, above this app's iOS 16 floor.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.browseGeneration == generation,
                      let originalProbe = self.resources.probes[key], originalProbe.id == probeID else { return }
                switch state {
                case .ready:
                    // Read only the same original resource AFTER both generation checks, on its owner.
                    let address = Self.address(from: originalProbe.connection.currentPath?.remoteEndpoint)
                    if address == nil {
                        DiagnosticsLog.log("engine", "browse: connection ready but path had no host:port")
                    }
                    self.finishProbe(key: key, probeID: probeID, generation: generation, address: address)
                case .failed(let error):
                    DiagnosticsLog.log("engine", "browse: resolve failed: \(String(describing: error))")
                    self.finishProbe(key: key, probeID: probeID, generation: generation, address: nil)
                case .cancelled:
                    self.finishProbe(key: key, probeID: probeID, generation: generation, address: nil)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func finishProbe(key: String, probeID: UUID, generation: UUID, address: ResolvedAddress?) {
        guard browseGeneration == generation, resources.probes[key]?.id == probeID,
              let probe = resources.probes.removeValue(forKey: key) else { return }
        if let address, results[key] != nil { resolved[key] = address }
        probe.connection.cancel()
        publishSnapshot()
    }

    private nonisolated static func address(from endpoint: NWEndpoint?) -> ResolvedAddress? {
        guard case let .hostPort(host, port)? = endpoint else { return nil }
        guard let text = VortXEngineDiscovery.hostText(host) else { return nil }
        return ResolvedAddress(host: text, port: Int(port.rawValue))
    }
}
