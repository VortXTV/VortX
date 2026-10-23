// TV guide: schedules from channel metas, the time window and the cell layout.
// Run: scripts/test-live-guide.sh

import Foundation

enum VortXEdgeAuth { static func sign(_ request: inout URLRequest) {} }

@MainActor private var failures = 0
@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
@MainActor
enum LiveGuideTests {
    static func main() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
        func iso(_ offsetMinutes: Double) -> String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: base.addingTimeInterval(offsetMinutes * 60))
        }
        let videos: [LiveGuidePolicy.VideoInput] = [
            .init(id: "ev2", title: "Evening News", name: nil, released: iso(90), overview: "Headlines"),
            .init(id: "ev0", title: "Morning Show", name: nil, released: iso(0), overview: nil),
            .init(id: "ev1", title: "  ", name: nil, released: iso(60), overview: nil),
            .init(id: "bad", title: "No time", name: nil, released: "not a date", overview: nil),
            .init(id: "plain", title: "Late Film", name: nil, released: "2027-01-15T11:00:00Z", overview: nil),
        ]
        let programmes = LiveGuidePolicy.programmes(from: videos)
        check("programmes sort by start and undated entries are dropped", programmes.map(\.id) == ["ev0", "ev1", "ev2", "plain"])
        check("each programme ends where the next begins",
              programmes[0].end == base.addingTimeInterval(3600) && programmes[1].end == base.addingTimeInterval(5400))
        check("the last programme runs an hour", programmes[3].end == programmes[3].start.addingTimeInterval(3600))
        check("a blank title reads as Programme", programmes[1].title == "Programme")
        check("timestamps without fractions parse", programmes[3].start == base.addingTimeInterval(3 * 3600))
        check("on-air is start-inclusive, end-exclusive",
              programmes[0].isOn(at: base) && !programmes[0].isOn(at: base.addingTimeInterval(3600)))

        let window = LiveGuidePolicy.window(now: base.addingTimeInterval(17 * 60), hours: 3)
        check("the window starts at the current half hour", window.lowerBound == base && window.upperBound == base.addingTimeInterval(3 * 3600))
        let later = LiveGuidePolicy.shifted(window, halfHours: 3)
        check("paging moves by half hours", later.lowerBound == base.addingTimeInterval(5400))
        check("the ruler marks every half hour", LiveGuidePolicy.marks(window).count == 6)

        let cells = LiveGuidePolicy.cells(programmes, window: later.lowerBound...base.addingTimeInterval(12600), pointsPerMinute: 10)
        check("programmes before the window are left out, overlapping ones clipped",
              cells.map(\.id) == ["ev2", "plain"] && cells[0].x == 0 && cells[0].width == 900)
        check("a programme past the window's end is clipped to it", cells[1].x == 900 && cells[1].width == 300)
        let sliver = LiveGuidePolicy.cells(programmes, window: base.addingTimeInterval(3599)...base.addingTimeInterval(7200), pointsPerMinute: 1)
        check("slivers too narrow to show are dropped", !sliver.contains { $0.id == "ev0" })

        let laid = LiveGuidePolicy.segments([
            LiveGuideCell(programme: programmes[2], x: 100, width: 200),
            LiveGuideCell(programme: programmes[0], x: 0, width: 50),
            LiveGuideCell(programme: programmes[1], x: 250, width: 100),
        ])
        check("segments run left to right with gaps as spacers and overlaps trimmed",
              laid == [.cell(LiveGuideCell(programme: programmes[0], x: 0, width: 50)), .gap(50),
                       .cell(LiveGuideCell(programme: programmes[2], x: 100, width: 200)),
                       .cell(LiveGuideCell(programme: programmes[1], x: 300, width: 50))])

        let channel = LiveGuideChannel(id: "vortx-iptv:ab/c d", type: "tv", name: "One", logo: nil,
                                       addonBase: "https://iptv.vortx.tv/c/slug/manifest.json")
        check("the meta URL sits beside the manifest with the id escaped",
              LiveGuidePolicy.metaURL(for: channel)?.absoluteString == "https://iptv.vortx.tv/c/slug/meta/tv/vortx-iptv:ab%2Fc%20d.json")
        check("a non-manifest add-on address has no guide",
              LiveGuidePolicy.metaURL(for: LiveGuideChannel(id: "x", type: "tv", name: "x", logo: nil, addonBase: "https://a.example/")) == nil)
        let channels = LiveGuidePolicy.channels(from: [
            (base: "https://a/manifest.json", items: [(id: "1", type: "tv", name: "One", logo: nil), (id: "2", type: "tv", name: "Two", logo: nil)]),
            (base: "https://b/manifest.json", items: [(id: "1", type: "tv", name: "One again", logo: nil), (id: "1", type: "channel", name: "Other type", logo: nil)]),
        ])
        check("channels are unique by type and id, first row wins",
              channels.map(\.name) == ["One", "Two", "Other type"] && channels[0].addonBase == "https://a/manifest.json")

        if failures > 0 { print("\n\(failures) check(s) failed"); exit(1) }
        print("\nAll TV guide checks passed")
    }
}
