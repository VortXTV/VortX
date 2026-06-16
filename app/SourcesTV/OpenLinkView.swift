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
    @State private var fileChoices: [LinkOpener.TorrentFile]? = nil   // multi-file pack → show the picker
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    var body: some View {
        Group {
            if let choices = fileChoices {
                filePicker(choices)
            } else {
                inputForm
            }
        }
        .padding(Theme.Space.xxl)
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Play a link")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(directLinksOnly
                 ? "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s)."
                 : "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s), or a magnet link.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(directLinksOnly ? "https://..." : "https://...  or  magnet:?xt=...", text: $input)
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
    }

    private func play() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("magnet:") {
            guard !PlaybackSettings.torrentsDisabled else {
                status = "Torrenting is disabled. Use a direct or debrid http(s) link."
                return
            }
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
            status = directLinksOnly
                ? "Not a playable link. Paste a direct http(s) stream link (debrid and usenet links count)."
                : "Not a playable link. Paste a direct http(s) stream link (debrid and usenet links count) or a magnet."
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
            guard let resolution = await LinkOpener.resolveMagnet(magnet) else {
                status = "Could not fetch the torrent. No reachable peers, or a dead magnet."
                return
            }
            switch resolution {
            case .single(let url, let fileName):
                dismiss()
                presenter.request = PlaybackRequest(url: url, title: magnet.name ?? fileName, torrent: true)
            case .choose(let files):
                status = nil
                fileChoices = files   // a multi-file pack: show the picker, the user clicks a file to play
            }
        }
    }

    /// The multi-file magnet picker: each video file in the pack as a focusable row (name + size).
    @ViewBuilder private func filePicker(_ files: [LinkOpener.TorrentFile]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Pick a file")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("This magnet has \(files.count) videos. Choose which one to play.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView {
                VStack(spacing: Theme.Space.md) {
                    ForEach(files) { file in
                        Button {
                            dismiss()
                            presenter.request = PlaybackRequest(url: file.url, title: file.name, torrent: true)
                        } label: {
                            HStack(spacing: Theme.Space.md) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name).lineLimit(2)
                                    if file.sizeBytes > 0 {
                                        Text(LinkOpener.sizeString(file.sizeBytes))
                                            .font(Theme.Typography.label)
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                    }
                                }
                                Spacer(minLength: Theme.Space.md)
                                Image(systemName: "play.fill")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(RowFocusStyle())
                    }
                }
            }
            Button("Back") { fileChoices = nil }
                .buttonStyle(ChipButtonStyle(selected: false))
        }
    }
}

enum LinkOpener {
    struct Magnet {
        let infoHash: String
        let name: String?
        let trackers: [String]
    }

    /// One selectable video file inside a multi-file magnet (a season pack / playlist). `id` is the
    /// torrent file index used to build the `/{infoHash}/{idx}` play URL.
    struct TorrentFile: Identifiable { let id: Int; let name: String; let sizeBytes: Double; let url: URL }

    /// A resolved magnet: either one file to auto-play, or several videos for the user to choose from.
    enum Resolution { case single(url: URL, fileName: String); case choose([TorrentFile]) }

    static func sizeString(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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

    /// Ask the embedded engine for the torrent. The create call returns once the metadata is in (it
    /// needs at least one peer), with the file list. A single-video torrent (a movie plus the usual
    /// junk) auto-plays the one video as before; a multi-video torrent (a season pack / playlist)
    /// returns the list so the user can pick which file to play instead of just getting the biggest (#81).
    static func resolveMagnet(_ magnet: Magnet) async -> Resolution? {
        guard !PlaybackSettings.torrentsDisabled else { return nil }
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
        func playURL(_ idx: Int) -> URL? { URL(string: "\(StremioServer.base)/\(magnet.infoHash)/\(idx)") }
        let indexed = Array(files.enumerated())
        let videos = indexed.filter { entry in
            let ext = (entry.element.name ?? "").split(separator: ".").last.map { String($0).lowercased() } ?? ""
            return videoExtensions.contains(ext)
        }
        // Multiple videos = a pack/playlist: hand back the list in natural name order (so episodes read
        // 1, 2, 3) for the user to choose from.
        if videos.count > 1 {
            let choices = videos
                .sorted { ($0.element.name ?? "").localizedStandardCompare($1.element.name ?? "") == .orderedAscending }
                .compactMap { entry -> TorrentFile? in
                    guard let url = playURL(entry.offset) else { return nil }
                    return TorrentFile(id: entry.offset, name: entry.element.name ?? "File \(entry.offset + 1)",
                                       sizeBytes: entry.element.length ?? 0, url: url)
                }
            if choices.count > 1 { return .choose(choices) }
        }
        // One video (or none): play the biggest file, exactly as before.
        guard let best = (videos.isEmpty ? indexed : videos).max(by: { ($0.element.length ?? 0) < ($1.element.length ?? 0) }),
              let url = playURL(best.offset) else { return nil }
        return .single(url: url, fileName: best.element.name ?? "Torrent")
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
