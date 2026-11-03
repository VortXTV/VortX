import Darwin
import Network
import os

/// Chooses the IPv4 address to advertise for the existing wildcard listeners.
enum VXLocalLANAddress {
    struct Identity: Hashable, Sendable {
        let name: String
        let index: Int
    }

    struct Interface: Sendable {
        let name: String
        let index: Int
        let type: NWInterface.InterfaceType
    }

    struct Address {
        let name: String
        let index: Int
        let flags: UInt32
        let host: String
        var isBridge = false
    }

    struct Candidate: Hashable {
        let identity: Identity
        let host: String
    }

    private static let pathOrder = OSAllocatedUnfairLock<[Interface]>(initialState: [])

    /// The app's existing path monitor supplies interface preference on its callback queue.
    static func update(from path: NWPath) {
        let interfaces = path.availableInterfaces.map {
            Interface(name: $0.name, index: $0.index, type: $0.type)
        }
        pathOrder.withLock { $0 = interfaces }
    }

    static func currentIPv4() -> String? {
        let interfaces = pathOrder.withLock { $0 }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }

        let rows = sequence(first: first, next: { $0.pointee.ifa_next })
        var links: [String: (index: Int, row: UnsafeMutablePointer<ifaddrs>)] = [:]
        for pointer in rows {
            let index = Int(VortXLocalLANLinkIndex(pointer))
            guard index > 0, let name = pointer.pointee.ifa_name else { continue }
            let key = String(cString: name)
            guard links[key] == nil else { return nil }
            links[key] = (index, pointer)
        }

        var addresses: [Address] = []
        for pointer in rows {
            let row = pointer.pointee
            guard let name = row.ifa_name, let socketAddress = row.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  Int(socketAddress.pointee.sa_len) >= MemoryLayout<sockaddr_in>.size else { continue }
            let key = String(cString: name)
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                  let end = host.firstIndex(of: 0) else { continue }
            let value = String(decoding: host[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let link = links[key]
            addresses.append(Address(name: key, index: link?.index ?? 0, flags: row.ifa_flags, host: value,
                                     isBridge: link.map { VortXLocalLANIsBridge($0.row) != 0 } ?? false))
        }

        let candidate = select(interfaces: interfaces, addresses: addresses) { identities in
            var classified = Set<Identity>()
            for identity in identities {
                guard let link = links[identity.name], link.index == identity.index else { return nil }
                switch VortXLocalLANClassifyLink(link.row) {
                case 1: classified.insert(identity)
                case 0: continue
                default: return nil
                }
            }
            return classified
        }
        guard let candidate,
              candidate.identity.name.withCString({ Int(if_nametoindex($0)) }) == candidate.identity.index else {
            return nil
        }
        return candidate.host
    }

    /// A generic path ranks eligible interfaces. It has no destination on the phone's subnet.
    /// Without a matching rank, use one unambiguous identity and host from fresh local media evidence.
    static func select(interfaces: [Interface], addresses: [Address],
                       classifyLocal: (Set<Identity>) -> Set<Identity>? = { _ in [] }) -> Candidate? {
        let usableAddresses = addresses.filter(isUsable)
        let usable = Set(usableAddresses.lazy.filter { $0.index > 0 }.map {
            Candidate(identity: Identity(name: $0.name, index: $0.index), host: $0.host)
        })
        for interface in interfaces {
            guard interface.index > 0,
                  interface.type == .wifi || interface.type == .wiredEthernet else { continue }
            let identity = Identity(name: interface.name, index: interface.index)
            let matches = usable.filter { $0.identity == identity }
            if !matches.isEmpty {
                // A rank for the interface cannot resolve distinct aliases on that interface.
                return matches.count == 1 ? matches.first : nil
            }
        }

        let identities = Set(usable.map(\.identity))
        guard usableAddresses.allSatisfy({ $0.index > 0 }), !identities.isEmpty,
              let classified = classifyLocal(identities),
              classified.isSubset(of: identities) else { return nil }
        let matches = usable.filter { classified.contains($0.identity) }
        return matches.count == 1 ? matches.first : nil
    }

    private static func isUsable(_ address: Address) -> Bool {
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let excluded = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard !address.isBridge, address.flags & required == required, address.flags & excluded == 0,
              address.host.utf8.count <= 15 else { return false }

        let parts = address.host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> UInt8? in
            guard let value = UInt8(part), String(value) == String(part) else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        let first = octets[0]
        return first > 0 && first < 224 && first != 127 && (first != 169 || octets[1] != 254)
    }
}
