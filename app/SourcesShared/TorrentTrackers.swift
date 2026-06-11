import Foundation

/// Builds the peer-search source list for the embedded torrent engine.
///
/// The crux of why torrents stalled on device: an addon hands out almost
/// entirely `udp://` trackers, and DHT is UDP too, but UDP peer discovery is
/// unreliable inside the sandboxed tvOS runtime. The reliable path is trackers
/// that announce over TCP/TLS. The official Stremio engine injects a fixed
/// default tracker set into every torrent for exactly this reason; its HTTPS
/// (port 443) trackers form a swarm with no UDP at all. We do the same: keep the
/// addon's trackers and DHT, add the HTTP twin of every udp tracker (the big
/// trackers answer both on the same host/port), and always append the HTTPS/HTTP
/// defaults so a swarm can form even when UDP is dead.
enum TorrentTrackers {
    /// Public TCP/TLS trackers that work without UDP. The HTTPS ones especially
    /// are what let a sandboxed app reach a swarm.
    static let defaults: [String] = [
        "tracker:https://tracker.alaskantf.com:443/announce",
        "tracker:https://tracker.bt4g.com:443/announce",
        "tracker:https://tracker.moeblog.cn:443/announce",
        "tracker:https://tracker.pmman.tech:443/announce",
        "tracker:https://tracker.zhuqiy.com:443/announce",
        "tracker:http://open.tracker.cl:1337/announce",
        "tracker:http://tracker.opentrackr.org:1337/announce",
        "tracker:http://tracker.files.fm:6969/announce",
    ]

    /// The full source list for a `/create` peerSearch: the stream's own sources,
    /// DHT, the HTTP twin of every udp tracker present, and the TCP/TLS defaults.
    static func sources(forHash hash: String, streamSources: [String]?, addonTrackers: [String] = []) -> [String] {
        var sources = streamSources ?? []
        sources.append(contentsOf: addonTrackers)
        sources.append("dht:\(hash)")
        // The HTTP twin of every udp tracker: the major trackers answer the same
        // announce over HTTP on the same host and port, a UDP-free path to peers.
        let twins = (sources + addonTrackers).compactMap { entry -> String? in
            guard entry.hasPrefix("tracker:udp://") else { return nil }
            let body = entry.dropFirst("tracker:udp://".count)
            guard let hostPort = body.split(separator: "/").first, !hostPort.isEmpty else { return nil }
            return "tracker:http://\(hostPort)/announce"
        }
        sources.append(contentsOf: twins)
        sources.append(contentsOf: defaults)
        // De-dupe, preserving order.
        var seen = Set<String>()
        return sources.filter { seen.insert($0).inserted }
    }
}
