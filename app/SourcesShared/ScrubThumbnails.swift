import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import os

struct ScrubThumbnailCue: Hashable {
    let start: Double
    let end: Double
    let imageURL: URL
    let rect: CGRect?

    func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }
}

enum ScrubThumbnailManifestParser {
    static func parse(data: Data, manifestURL: URL) -> [ScrubThumbnailCue] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseWebVTT(text, manifestURL: manifestURL)
    }

    private static func parseWebVTT(_ text: String, manifestURL: URL) -> [ScrubThumbnailCue] {
        let lines = text.components(separatedBy: .newlines)
        var cues: [ScrubThumbnailCue] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            guard line.contains("-->") else { continue }

            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else { continue }

            while index < lines.count {
                let payload = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                if payload.isEmpty { break }
                guard let cue = parseCuePayload(payload, start: start, end: end, manifestURL: manifestURL) else {
                    continue
                }
                cues.append(cue)
                break
            }
        }

        return cues.sorted { $0.start < $1.start }
    }

    private static func parseCuePayload(_ payload: String, start: Double, end: Double, manifestURL: URL) -> ScrubThumbnailCue? {
        let pieces = payload.components(separatedBy: "#xywh=")
        guard let imageURL = URL(string: pieces[0], relativeTo: manifestURL)?.absoluteURL else { return nil }
        let rect = pieces.count > 1 ? parseRect(pieces[1]) : nil
        return ScrubThumbnailCue(start: start, end: end, imageURL: imageURL, rect: rect)
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let time = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).first ?? raw
        let fields = time.components(separatedBy: ":")
        guard fields.count == 2 || fields.count == 3 else { return nil }

        let secondsField = fields.last ?? ""
        let secondsParts = secondsField.components(separatedBy: ".")
        guard let seconds = Double(secondsParts[0]) else { return nil }
        let fraction = secondsParts.count > 1 ? Double("0." + secondsParts[1]) ?? 0 : 0

        if fields.count == 2 {
            guard let minutes = Double(fields[0]) else { return nil }
            return minutes * 60 + seconds + fraction
        } else {
            guard let hours = Double(fields[0]), let minutes = Double(fields[1]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds + fraction
        }
    }

    private static func parseRect(_ raw: String) -> CGRect? {
        let values = raw
            .components(separatedBy: CharacterSet(charactersIn: ", \t"))
            .compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}

@MainActor
final class ScrubThumbnailsStore: ObservableObject {
    @Published private(set) var image: PlatformImage?
    @Published private(set) var available = false

    private var trickplayManifestURL: URL?
    private var headers: [String: String]?
    private var cues: [ScrubThumbnailCue] = []
    private var loadTask: Task<Void, Never>?
    private var currentCue: ScrubThumbnailCue?
    private static let log = Logger(subsystem: "com.stremiox.app", category: "trickplay")

    private static let imageCache: NSCache<NSURL, PlatformImage> = {
        let c = NSCache<NSURL, PlatformImage>()
        c.countLimit = 48
        return c
    }()

    func configure(trickplayManifestURL: URL?, headers: [String: String]? = nil) {
        guard self.trickplayManifestURL != trickplayManifestURL || self.headers != headers else { return }
        loadTask?.cancel()
        self.trickplayManifestURL = trickplayManifestURL
        self.headers = headers
        cues = []
        image = nil
        available = false
        currentCue = nil

        Self.log.debug("trickplay configure manifest=\(trickplayManifestURL?.absoluteString ?? "nil", privacy: .public) headers=\(headers?.count ?? 0, privacy: .public)")

        guard let trickplayManifestURL else {
            Self.log.debug("trickplay disabled: no manifest URL")
            return
        }
        loadTask = Task { [weak self] in
            do {
                var request = URLRequest(url: trickplayManifestURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                Self.log.debug("trickplay manifest GET \(trickplayManifestURL.absoluteString, privacy: .public)")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let responseURL = (response as? HTTPURLResponse)?.url?.absoluteString ?? "nil"
                    let server = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Server") ?? ""
                    Self.log.debug("trickplay manifest non-2xx status=\(status, privacy: .public) url=\(trickplayManifestURL.absoluteString, privacy: .public) responseURL=\(responseURL, privacy: .public) server=\(server, privacy: .public)")
                    await MainActor.run {
                        guard self?.trickplayManifestURL == trickplayManifestURL else { return }
                        self?.available = false
                    }
                    return
                }
                let parsed = ScrubThumbnailManifestParser.parse(data: data, manifestURL: trickplayManifestURL)
                let responseURL = http.url?.absoluteString ?? "nil"
                let server = http.value(forHTTPHeaderField: "Server") ?? ""
                Self.log.debug("trickplay manifest loaded status=\(http.statusCode, privacy: .public) cues=\(parsed.count, privacy: .public) url=\(trickplayManifestURL.absoluteString, privacy: .public) responseURL=\(responseURL, privacy: .public) server=\(server, privacy: .public)")
                await MainActor.run {
                    guard self?.trickplayManifestURL == trickplayManifestURL else { return }
                    self?.cues = parsed
                    self?.available = !parsed.isEmpty
                }
            } catch {
                Self.log.error("trickplay manifest request failed url=\(trickplayManifestURL.absoluteString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                await MainActor.run {
                    guard self?.trickplayManifestURL == trickplayManifestURL else { return }
                    self?.available = false
                }
            }
        }
    }

    func show(time: Double) {
        guard let cue = cue(for: time) else {
            currentCue = nil
            image = nil
            return
        }
        guard cue != currentCue else { return }
        currentCue = cue

        let cacheKey = cacheKey(for: cue)
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            image = cached
            prefetchAround(cue)
            return
        }

        image = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let headers = self?.headers
            guard let loaded = await Self.loadImage(for: cue, headers: headers) else { return }
            Self.imageCache.setObject(loaded, forKey: cacheKey)
            await MainActor.run {
                guard self?.currentCue == cue else { return }
                self?.image = loaded
                self?.prefetchAround(cue)
            }
        }
    }

    func clear() {
        currentCue = nil
        image = nil
    }

    private func cue(for time: Double) -> ScrubThumbnailCue? {
        guard !cues.isEmpty else { return nil }
        if let currentCue, currentCue.contains(time) { return currentCue }
        return cues.last { $0.start <= time && time < $0.end } ?? cues.last { $0.start <= time }
    }

    private func prefetchAround(_ cue: ScrubThumbnailCue) {
        guard let idx = cues.firstIndex(of: cue) else { return }
        for next in [idx - 1, idx + 1] where cues.indices.contains(next) {
            let candidate = cues[next]
            let key = cacheKey(for: candidate)
            guard Self.imageCache.object(forKey: key) == nil else { continue }
            let headers = self.headers
            Task {
                guard let image = await Self.loadImage(for: candidate, headers: headers) else { return }
                Self.imageCache.setObject(image, forKey: key)
            }
        }
    }

    private func cacheKey(for cue: ScrubThumbnailCue) -> NSURL {
        let rect = cue.rect.map { "#xywh=\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? ""
        return NSURL(string: cue.imageURL.absoluteString + rect) ?? cue.imageURL as NSURL
    }

    private nonisolated static func loadImage(for cue: ScrubThumbnailCue, headers: [String: String]?) async -> PlatformImage? {
        do {
            var request = URLRequest(url: cue.imageURL)
            request.cachePolicy = .returnCacheDataElseLoad
            headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let image = PlatformImage(data: data) else { return nil }
            guard let rect = cue.rect else { return image }
#if canImport(AppKit)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let cropped = cgImage.cropping(to: rect.integral) else { return image }
            return NSImage(cgImage: cropped, size: rect.size)
#else
            guard let cg = image.cgImage?.cropping(to: rect.integral) else { return image }
            return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
#endif
        } catch {
            return nil
        }
    }
}
