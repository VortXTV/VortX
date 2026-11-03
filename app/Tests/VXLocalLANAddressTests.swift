import Darwin
import Network

/// Exercises the shared selector with synthetic path and address snapshots.
enum VXLocalLANAddressTests {
    private typealias Interface = VXLocalLANAddress.Interface
    private typealias Address = VXLocalLANAddress.Address
    private typealias Identity = VXLocalLANAddress.Identity

    private static let active = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)

    static func run() {
        let ethernet = Interface(name: "en12", index: 12, type: .wiredEthernet)
        let wifi = Interface(name: "en7", index: 7, type: .wifi)
        let bridge = Interface(name: "bridge0", index: 30, type: .other)
        let tunnel = Interface(name: "utun4", index: 34, type: .other)
        let cellular = Interface(name: "pdp_ip0", index: 40, type: .cellular)

        let ethernetAddress = address(ethernet, "10.42.0.24")
        let wifiAddress = address(wifi, "192.168.42.25")
        let virtualAddresses = [
            address(bridge, "192.168.64.1"),
            address(tunnel, "10.8.0.7"),
            address(cellular, "10.80.0.6"),
        ]

        var checks = 0
        func expect(_ expected: String?, interfaces: [Interface], addresses: [Address], _ label: String) {
            let selected = VXLocalLANAddress.select(interfaces: interfaces, addresses: addresses)
            precondition(selected?.host == expected, "LAN address selector: \(label)")
            checks += 1
        }

        expect("10.42.0.24", interfaces: [ethernet, wifi], addresses: [wifiAddress, ethernetAddress],
               "Ethernet wins when first in path order, regardless of address row order")
        expect("192.168.42.25", interfaces: [wifi, ethernet], addresses: [ethernetAddress, wifiAddress],
               "Wi-Fi wins when first in path order, regardless of address row order")

        let namedLink = Interface(name: "physical-link", index: 48, type: .wiredEthernet)
        expect("10.42.0.51", interfaces: [namedLink], addresses: [address(namedLink, "10.42.0.51")],
               "a typed physical link needs no conventional interface name")

        expect("192.168.42.25", interfaces: [bridge, tunnel, cellular, wifi],
               addresses: virtualAddresses + [wifiAddress],
               "earlier virtual and cellular entries cannot outrank Wi-Fi")
        expect(nil, interfaces: [bridge, tunnel, cellular], addresses: virtualAddresses,
               "a private-looking address cannot make an ineligible interface a LAN path")
        let wiredBridge = Interface(name: bridge.name, index: bridge.index, type: .wiredEthernet)
        let bridgeLink = Address(name: bridge.name, index: bridge.index, flags: active,
                                 host: "192.168.64.1", isBridge: true)
        expect("192.168.42.25", interfaces: [wiredBridge, wifi], addresses: [bridgeLink, wifiAddress],
               "AF_LINK bridge classification excludes a bridge even when its path type is wired")

        let oldIndex = Address(name: wifi.name, index: 99, flags: active, host: "192.168.42.25")
        expect(nil, interfaces: [wifi], addresses: [oldIndex],
               "a reused interface name cannot match an address at another index")
        let oldName = Address(name: "en8", index: wifi.index, flags: active, host: "192.168.42.25")
        expect(nil, interfaces: [wifi], addresses: [oldName],
               "a matching index cannot substitute for the correct interface name")
        expect("10.42.0.24", interfaces: [wifi, ethernet], addresses: [oldIndex, ethernetAddress],
               "a stale row does not prevent the next eligible interface from being selected")

        expect("192.168.42.25", interfaces: [ethernet, wifi], addresses: [wifiAddress],
               "the next physical interface is eligible when the preferred one has no IPv4 row")
        let down = address(ethernet, "10.42.0.24", flags: active & ~UInt32(IFF_UP))
        expect("192.168.42.25", interfaces: [ethernet, wifi], addresses: [down, wifiAddress],
               "the next physical interface is eligible when the preferred one is down")

        let badFlags: [(UInt32, String)] = [
            (active & ~UInt32(IFF_RUNNING), "interface is not running"),
            (active & ~UInt32(IFF_BROADCAST), "interface lacks broadcast capability"),
            (active | UInt32(IFF_LOOPBACK), "loopback flag"),
            (active | UInt32(IFF_POINTOPOINT), "point-to-point flag"),
        ]
        for (flags, reason) in badFlags {
            expect(nil, interfaces: [wifi], addresses: [address(wifi, "192.168.42.25", flags: flags)],
                   "rejects \(reason) even when the interface is typed as Wi-Fi")
        }

        let badHosts: [(String, String)] = [
            ("192.168.042.25", "leading zero"),
            ("192.168.42", "missing octet"),
            ("192.168.42.256", "octet overflow"),
            ("192.168.42.25 ", "trailing whitespace"),
            ("::ffff:192.168.42.25", "IPv6-mapped address"),
            ("0.0.0.0", "unspecified address"),
            ("127.0.0.1", "loopback address"),
            ("169.254.42.25", "link-local address"),
            ("224.1.2.3", "multicast address"),
            ("255.255.255.255", "limited broadcast address"),
        ]
        for (host, reason) in badHosts {
            expect(nil, interfaces: [wifi], addresses: [address(wifi, host)],
                   "rejects \(reason) on an otherwise eligible link")
        }

        expect(nil, interfaces: [], addresses: [wifiAddress], "an empty path without positive classification yields no host")
        expect(nil, interfaces: [wifi], addresses: [], "no address rows means no advertised host")
        expect("192.168.42.25", interfaces: [wifi], addresses: [wifiAddress, wifiAddress],
               "identical duplicate rows still identify one host")
        expect("192.168.42.25", interfaces: [wifi],
               addresses: [address(wifi, "169.254.42.25"), wifiAddress],
               "an ineligible alias does not obscure the valid host")
        let wifiAlias = address(wifi, "192.168.50.25")
        expect(nil, interfaces: [wifi, ethernet], addresses: [wifiAlias, ethernetAddress, wifiAddress],
               "distinct IPv4 aliases on the preferred interface leave host selection ambiguous")

        let ethernetID = Identity(name: ethernet.name, index: ethernet.index)
        let wifiID = Identity(name: wifi.name, index: wifi.index)

        func expectFallback(_ expected: (host: String, identity: Identity)?,
                            interfaces: [Interface], addresses: [Address],
                            classified: Set<Identity>?, requested: Set<Identity>? = nil, _ label: String) {
            var requests: [Set<Identity>] = []
            let selected = VXLocalLANAddress.select(interfaces: interfaces, addresses: addresses) { identities in
                requests.append(identities)
                return classified
            }
            if let requested {
                precondition(requests == [requested], "LAN address selector classification input: \(label)")
            }
            precondition(selected?.host == expected?.host && selected?.identity == expected?.identity,
                         "LAN address selector: \(label)")
            checks += 1
        }

        expectFallback((ethernetAddress.host, ethernetID), interfaces: [], addresses: [ethernetAddress],
                       classified: [ethernetID], requested: [ethernetID],
                       "a cold path can select a positively classified Ethernet candidate")
        expectFallback((wifiAddress.host, wifiID), interfaces: [], addresses: [wifiAddress],
                       classified: [wifiID], requested: [wifiID],
                       "a cold path can select a positively classified Wi-Fi candidate")

        let pointToPointTunnel = address(tunnel, "10.8.0.7", flags: active | UInt32(IFF_POINTOPOINT))
        expectFallback((wifiAddress.host, wifiID), interfaces: [tunnel], addresses: [pointToPointTunnel, wifiAddress],
                       classified: [wifiID], requested: [wifiID],
                       "a VPN-only path can recover a physical candidate without classifying the point-to-point row")

        let staleWifi = Interface(name: wifi.name, index: 99, type: .wifi)
        expectFallback((wifiAddress.host, wifiID), interfaces: [staleWifi], addresses: [wifiAddress],
                       classified: [wifiID], requested: [wifiID],
                       "a stale ranked identity can fall back to a positively classified fresh identity")

        expectFallback(nil, interfaces: [], addresses: [wifiAddress, ethernetAddress],
                       classified: [wifiID, ethernetID], requested: [wifiID, ethernetID],
                       "multiple positively classified links with distinct hosts are ambiguous")
        let ethernetAtSameHost = address(ethernet, wifiAddress.host)
        expectFallback(nil, interfaces: [], addresses: [wifiAddress, ethernetAtSameHost],
                       classified: [wifiID, ethernetID], requested: [wifiID, ethernetID],
                       "two positively classified links sharing one host still have distinct identities")
        expectFallback(nil, interfaces: [], addresses: [wifiAddress, wifiAlias], classified: [wifiID],
                       "distinct IPv4 aliases leave a positively classified link ambiguous")
        expectFallback((wifiAddress.host, wifiID), interfaces: [], addresses: [wifiAddress, wifiAddress],
                       classified: [wifiID], requested: [wifiID],
                       "identical fallback rows still identify one host on one link")
        expectFallback(nil, interfaces: [], addresses: [wifiAddress], classified: nil, requested: [wifiID],
                       "unknown or unavailable classification refuses a sole otherwise eligible address")

        let wrongIndex = Identity(name: wifi.name, index: 99)
        expectFallback(nil, interfaces: [], addresses: [wifiAddress],
                       classified: [wrongIndex], requested: [wifiID],
                       "classification of a stale index cannot authorize the current same-name row")
        let wrongName = Identity(name: "en8", index: wifi.index)
        expectFallback(nil, interfaces: [], addresses: [wifiAddress],
                       classified: [wrongName], requested: [wifiID],
                       "classification of a stale name cannot authorize the current same-index row")

        var fallbackCalls = 0
        let ranked = VXLocalLANAddress.select(interfaces: [wifi], addresses: [ethernetAddress, wifiAddress]) { _ in
            fallbackCalls += 1
            return [ethernetID]
        }
        precondition(ranked?.host == wifiAddress.host && ranked?.identity == wifiID && fallbackCalls == 0,
                     "LAN address selector: an exact ranked match wins without fallback classification")
        checks += 1

        let ambiguousRanked = VXLocalLANAddress.select(interfaces: [wifi],
                                                        addresses: [wifiAlias, ethernetAddress, wifiAddress]) { _ in
            fallbackCalls += 1
            return [ethernetID]
        }
        precondition(ambiguousRanked == nil && fallbackCalls == 0,
                     "LAN address selector: an ambiguous ranked link refuses without fallback classification")
        checks += 1

        let missingLink = Address(name: "en21", index: 0, flags: active, host: "10.42.0.52")
        let incompleteRows = [missingLink, wifiAddress]
        let incompleteFallback = VXLocalLANAddress.select(interfaces: [], addresses: incompleteRows) { _ in
            fallbackCalls += 1
            return [wifiID]
        }
        precondition(incompleteFallback == nil && fallbackCalls == 0,
                     "LAN address selector: a usable row missing its link identity blocks fallback before classification")
        checks += 1

        let rankedWithMissingLink = VXLocalLANAddress.select(interfaces: [wifi], addresses: incompleteRows) { _ in
            fallbackCalls += 1
            return [wifiID]
        }
        precondition(rankedWithMissingLink?.host == wifiAddress.host
                     && rankedWithMissingLink?.identity == wifiID && fallbackCalls == 0,
                     "LAN address selector: an exact ranked match survives an unrelated row missing its link identity")
        checks += 1

        print("PASS  shared LAN address selection (\(checks) checks)")
    }

    private static func address(_ interface: Interface, _ host: String, flags: UInt32 = active) -> Address {
        Address(name: interface.name, index: interface.index, flags: flags, host: host)
    }
}
