import Foundation

/// The TV guide: channels down the side, a few hours of programmes across, built from the schedule each live
/// channel's add-on already publishes in its meta (`videos`, one per programme, `released` = start time; the
/// VortX IPTV converter fills it from the playlist's XMLTV). Schedules load lazily, only for the rows on screen.
/// Android implements the same rules in `LiveGuide.kt`.
struct LiveGuideChannel: Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let name: String
    let logo: String?
    /// The add-on transport URL (`.../manifest.json`) whose catalog listed this channel.
    let addonBase: String
}

struct LiveGuideProgramme: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let overview: String?

    func isOn(at now: Date) -> Bool { start <= now && now < end }
}

/// One programme placed on the guide's time axis: offset and width in points from the window's start.
struct LiveGuideCell: Identifiable, Equatable, Sendable {
    let programme: LiveGuideProgramme
    let x: Double
    let width: Double
    var id: String { programme.id }
}

enum LiveGuidePolicy {
    /// A programme without a following one is assumed to run this long.
    static let defaultLength: TimeInterval = 3600
    /// Cells narrower than this are dropped from the strip; they cannot hold a title or take focus usefully.
    static let minimumCellWidth: Double = 24

    struct VideoInput: Decodable, Sendable {
        let id: String
        let title: String?
        let name: String?
        let released: String?
        let overview: String?
    }

    /// Programmes from a channel's `videos`, in start order. Each ends where the next begins (the converter
    /// does not send stop times); the last runs `defaultLength`. Entries without a valid start are dropped.
    static func programmes(from videos: [VideoInput]) -> [LiveGuideProgramme] {
        let dated = videos.compactMap { video -> (VideoInput, Date)? in
            guard let raw = video.released, let start = parseDate(raw) else { return nil }
            return (video, start)
        }.sorted { $0.1 < $1.1 }
        return dated.enumerated().compactMap { index, pair in
            let (video, start) = pair
            let next = dated.dropFirst(index + 1).first { $0.1 > start }?.1
            let end = next ?? start.addingTimeInterval(defaultLength)
            let title = (video.title ?? video.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return LiveGuideProgramme(id: video.id, title: title.isEmpty ? String(localized: "Programme") : title,
                                      start: start, end: end, overview: video.overview)
        }
    }

    /// The window the guide opens on: from the current half hour, `hours` long.
    static func window(now: Date, hours: Double) -> ClosedRange<Date> {
        let halfHour: TimeInterval = 1800
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / halfHour).rounded(.down) * halfHour)
        return start...start.addingTimeInterval(hours * 3600)
    }

    /// The window moved by `halfHours` half hours (negative = earlier).
    static func shifted(_ window: ClosedRange<Date>, halfHours: Int) -> ClosedRange<Date> {
        let delta = TimeInterval(halfHours) * 1800
        return window.lowerBound.addingTimeInterval(delta)...window.upperBound.addingTimeInterval(delta)
    }

    /// The programmes overlapping `window`, clipped to it and laid out at `pointsPerMinute`.
    static func cells(_ programmes: [LiveGuideProgramme], window: ClosedRange<Date>, pointsPerMinute: Double) -> [LiveGuideCell] {
        programmes.compactMap { programme in
            let start = max(programme.start, window.lowerBound)
            let end = min(programme.end, window.upperBound)
            guard end > start else { return nil }
            let x = start.timeIntervalSince(window.lowerBound) / 60 * pointsPerMinute
            let width = end.timeIntervalSince(start) / 60 * pointsPerMinute
            guard width >= minimumCellWidth else { return nil }
            return LiveGuideCell(programme: programme, x: x, width: width)
        }
    }

    /// A row's layout left to right: empty time as spacer widths, programmes as cells, so a focus engine sees
    /// real frames rather than offsets.
    enum Segment: Equatable, Sendable {
        case gap(Double)
        case cell(LiveGuideCell)
    }

    static func segments(_ cells: [LiveGuideCell]) -> [Segment] {
        var result: [Segment] = []
        var cursor = 0.0
        for cell in cells.sorted(by: { $0.x < $1.x }) where cell.x + cell.width > cursor {
            let start = max(cell.x, cursor)
            if start - cursor > 0.5 { result.append(.gap(start - cursor)) }
            result.append(.cell(LiveGuideCell(programme: cell.programme, x: start, width: cell.x + cell.width - start)))
            cursor = cell.x + cell.width
        }
        return result
    }

    /// Half-hour marks inside `window`, for the time ruler.
    static func marks(_ window: ClosedRange<Date>) -> [Date] {
        stride(from: window.lowerBound.timeIntervalSince1970, to: window.upperBound.timeIntervalSince1970, by: 1800)
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// `<add-on>/meta/<type>/<id>.json` for a channel, or nil when the add-on address is not a manifest URL.
    static func metaURL(for channel: LiveGuideChannel) -> URL? {
        guard channel.addonBase.hasSuffix("/manifest.json"),
              let type = channel.type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])),
              let id = channel.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) else { return nil }
        let base = String(channel.addonBase.dropLast("manifest.json".count))
        return URL(string: "\(base)meta/\(type)/\(id).json")
    }

    /// Unique channels from the live catalog rows, in row order.
    static func channels(from rows: [(base: String, items: [(id: String, type: String, name: String, logo: String?)])]) -> [LiveGuideChannel] {
        var seen = Set<String>()
        var result: [LiveGuideChannel] = []
        for row in rows {
            for item in row.items where seen.insert("\(item.type)|\(item.id)").inserted {
                result.append(LiveGuideChannel(id: item.id, type: item.type, name: item.name, logo: item.logo, addonBase: row.base))
            }
        }
        return result
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// Loads channel schedules on demand, a few at a time, and keeps them for a while.
@MainActor
final class LiveGuideModel: ObservableObject {
    enum Schedule: Equatable {
        case loading
        case loaded([LiveGuideProgramme])
        case unavailable
    }

    @Published private(set) var schedules: [String: Schedule] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var queue: [LiveGuideChannel] = []
    private var running = 0
    private static let maxConcurrent = 4
    private static let freshFor: TimeInterval = 15 * 60

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// Asks for `channel`'s schedule; a fresh copy is reused and a request already queued is not repeated.
    func request(_ channel: LiveGuideChannel, now: Date = Date()) {
        if let at = fetchedAt[channel.id], now.timeIntervalSince(at) < Self.freshFor, schedules[channel.id] != nil { return }
        if schedules[channel.id] == .loading { return }
        schedules[channel.id] = .loading
        queue.append(channel)
        pump()
    }

    private func pump() {
        while running < Self.maxConcurrent, !queue.isEmpty {
            let channel = queue.removeFirst()
            running += 1
            Task { [weak self] in
                let schedule = await self?.fetch(channel) ?? .unavailable
                guard let self else { return }
                self.schedules[channel.id] = schedule
                self.fetchedAt[channel.id] = Date()
                self.running -= 1
                self.pump()
            }
        }
    }

    private func fetch(_ channel: LiveGuideChannel) async -> Schedule {
        guard let url = LiveGuidePolicy.metaURL(for: channel) else { return .unavailable }
        var request = URLRequest(url: url)
        VortXEdgeAuth.sign(&request)   // no-op except for VortX's own services (the IPTV converter)
        struct Envelope: Decodable { struct Meta: Decodable { let videos: [LiveGuidePolicy.VideoInput]? }; let meta: Meta? }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return .unavailable }
        let programmes = LiveGuidePolicy.programmes(from: envelope.meta?.videos ?? [])
        return programmes.isEmpty ? .unavailable : .loaded(programmes)
    }
}
