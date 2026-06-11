import SwiftUI

/// Stremio's "paste a link" feature: play a direct video URL or a magnet.
/// Magnets ride the embedded torrent engine; the create call blocks until the
/// torrent's metadata arrives, then the largest video file plays.
struct OpenLinkView: View {
    @EnvironmentObject private var presenter: PlayerPresenter
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var working = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Play a link")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s), or a magnet link.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField("https://…   magnet:?xt=…   or paste any direct stream link", text: $input)
                .font(Theme.Typography.body)
                .disableAutocorrection(true)
            HStack(spacing: Theme.Space.md) {
                Button(working ? "Working…" : "Play") { play() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(working || input.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { dismiss() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
            if let status {
                Text(status)
                    .font(Theme.Typography.label)
                    .foregroundStyle(working ? Theme.Palette.textSecondary : Theme.Palette.danger)
            }
            Spacer()
        }
        .padding(Theme.Space.xxl)
    }

    private func play() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("magnet:") {
            guard let magnet = LinkOpener.parseMagnet(text) else {
                status = "That magnet link has no usable info hash."
                return
            }
            playMagnet(magnet)
            return
        }
        // A bare host or path with no scheme is almost always meant as https.
        if !text.contains("://"), text.contains(".") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            status = "Not a playable link. Paste a direct http(s) stream link (debrid and usenet links count) or a magnet."
            return
        }
        let title = url.lastPathComponent.isEmpty ? (url.host ?? "Stream") : url.lastPathComponent
        dismiss()
        presenter.request = PlaybackRequest(url: url, title: title)
    }

    private func playMagnet(_ magnet: LinkOpener.Magnet) {
        working = true
        status = "Fetching torrent info… this can take up to a minute"
        Task { @MainActor in
            defer { working = false }
            guard let pick = await LinkOpener.resolveMagnet(magnet) else {
                status = "Could not fetch the torrent. No reachable peers, or a dead magnet."
                return
            }
            dismiss()
            presenter.request = PlaybackRequest(
                url: pick.url,
                title: magnet.name ?? pick.fileName,
                torrent: true)
        }
    }
}

enum LinkOpener {
    struct Magnet {
        let infoHash: String
        let name: String?
        let trackers: [String]
    }

    static func parseMagnet(_ text: String) -> Magnet? {
        guard let comps = URLComponents(string: text), comps.scheme?.lowercased() == "magnet" else { return nil }
        var hash: String?
        var name: String?
        var trackers: [String] = []
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "xt":
                guard let value = item.value, value.lowercased().hasPrefix("urn:btih:") else { break }
                let raw = String(value.dropFirst("urn:btih:".count))
                if raw.count == 40, raw.allSatisfy(\.isHexDigit) {
                    hash = raw.lowercased()
                } else if raw.count == 32 {
                    hash = base32ToHex(raw)
                }
            case "dn": name = item.value
            case "tr": if let t = item.value, !t.isEmpty { trackers.append("tracker:\(t)") }
            default: break
            }
        }
        guard let hash else { return nil }
        return Magnet(infoHash: hash, name: name, trackers: trackers)
    }

    /// Ask the embedded engine for the torrent. The create call returns once the
    /// metadata is in (it needs at least one peer), with the file list; pick the
    /// biggest video file.
    static func resolveMagnet(_ magnet: Magnet) async -> (url: URL, fileName: String)? {
        let sources = TorrentTrackers.sources(forHash: magnet.infoHash,
                                              streamSources: nil,
                                              addonTrackers: magnet.trackers)
        guard let createURL = URL(string: "\(StremioServer.base)/\(magnet.infoHash)/create") else { return nil }
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 75
        let payload: [String: Any] = [
            "torrent": ["infoHash": magnet.infoHash],
            "peerSearch": ["sources": sources, "min": 40, "max": 150],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        struct CreateResponse: Decodable {
            struct File: Decodable { let name: String?; let length: Double? }
            let files: [File]?
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(CreateResponse.self, from: data),
              let files = response.files, !files.isEmpty else { return nil }
        let videoExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "ts", "webm", "wmv", "mpg", "mpeg"]
        let indexed = Array(files.enumerated())
        let videos = indexed.filter { entry in
            let ext = (entry.element.name ?? "").split(separator: ".").last.map { String($0).lowercased() } ?? ""
            return videoExtensions.contains(ext)
        }
        guard let best = (videos.isEmpty ? indexed : videos).max(by: { ($0.element.length ?? 0) < ($1.element.length ?? 0) }),
              let url = URL(string: "\(StremioServer.base)/\(magnet.infoHash)/\(best.offset)") else { return nil }
        return (url, best.element.name ?? "Torrent")
    }

    /// RFC 4648 base32 (the older magnet info-hash encoding) to lowercase hex.
    static func base32ToHex(_ raw: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var bytes: [UInt8] = []
        for ch in raw.uppercased() {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        guard bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
