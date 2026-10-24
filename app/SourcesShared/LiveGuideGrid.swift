import SwiftUI
import Combine

extension LiveGuideChannel {
    /// The guide's channels: every live catalog row's items, unique, in row order. A row id is
    /// `<add-on manifest URL>|<type>|<catalog>`, which names the add-on that serves each channel's schedule.
    static func channels(from rows: [CoreBoardRow]) -> [LiveGuideChannel] {
        LiveGuidePolicy.channels(from: rows.map { row in
            (base: String(row.id.split(separator: "|", maxSplits: 1).first ?? ""),
             items: row.items.map { (id: $0.id, type: $0.type, name: $0.name, logo: $0.logo ?? $0.poster) })
        })
    }
}

/// The TV guide grid shared by Apple TV, iPhone, iPad and Mac: channels down the side, a paged window of
/// programmes across (Earlier / Now / Later), a line at the current time. Each row asks for its channel's
/// schedule only when it scrolls into view. Selecting any programme opens that channel.
struct LiveGuideGrid: View {
    let channels: [LiveGuideChannel]
    let onOpen: (LiveGuideChannel) -> Void

    @StateObject private var model = LiveGuideModel()
    @State private var window = LiveGuidePolicy.window(now: Date(), hours: LiveGuideMetrics.hours)
    @State private var now = Date()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            controls
            GeometryReader { geometry in
                let trackWidth = max(geometry.size.width - LiveGuideMetrics.channelWidth, 1)
                let pointsPerMinute = trackWidth / (LiveGuideMetrics.hours * 60)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ruler(pointsPerMinute: pointsPerMinute)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: LiveGuideMetrics.rowSpacing) {
                            ForEach(channels) { channel in
                                LiveGuideRow(channel: channel, schedule: model.schedules[channel.id], window: window,
                                             pointsPerMinute: pointsPerMinute, trackWidth: trackWidth, now: now, onOpen: onOpen)
                                    .onAppear { model.request(channel) }
                            }
                        }
                        .overlay(alignment: .topLeading) { nowLine(pointsPerMinute: pointsPerMinute) }
                    }
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.sm) {
            Button { window = LiveGuidePolicy.shifted(window, halfHours: -LiveGuideMetrics.pageHalfHours) } label: {
                Label("Earlier", systemImage: "chevron.left")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Button { window = LiveGuidePolicy.window(now: Date(), hours: LiveGuideMetrics.hours) } label: { Text("Now") }
                .buttonStyle(ChipButtonStyle(selected: window.contains(now)))
            Button { window = LiveGuidePolicy.shifted(window, halfHours: LiveGuideMetrics.pageHalfHours) } label: {
                Label("Later", systemImage: "chevron.right")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Text(window.lowerBound.formatted(.dateTime.weekday(.wide).day().month()))
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func ruler(pointsPerMinute: Double) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: LiveGuideMetrics.channelWidth, height: 1)
            ForEach(LiveGuidePolicy.marks(window), id: \.self) { mark in
                Text(mark.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 30 * pointsPerMinute, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func nowLine(pointsPerMinute: Double) -> some View {
        if window.contains(now) {
            Rectangle().fill(Theme.Palette.accent).frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: LiveGuideMetrics.channelWidth + now.timeIntervalSince(window.lowerBound) / 60 * pointsPerMinute)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

enum LiveGuideMetrics {
#if os(tvOS)
    static let hours = 3.0
    static let channelWidth: CGFloat = 300
    static let rowHeight: CGFloat = 104
#else
    static let hours = 2.0
    static let channelWidth: CGFloat = 132
    static let rowHeight: CGFloat = 72
#endif
    static let rowSpacing: CGFloat = 8
    static let pageHalfHours = 3
}

/// One channel: its logo and name, then its programmes laid along the window.
private struct LiveGuideRow: View {
    let channel: LiveGuideChannel
    let schedule: LiveGuideModel.Schedule?
    let window: ClosedRange<Date>
    let pointsPerMinute: Double
    let trackWidth: Double
    let now: Date
    let onOpen: (LiveGuideChannel) -> Void

    var body: some View {
        HStack(spacing: 0) {
            channelLabel
            track.frame(width: trackWidth, height: LiveGuideMetrics.rowHeight, alignment: .leading)
        }
    }

    private var channelLabel: some View {
        HStack(spacing: Theme.Space.xs) {
            AsyncImage(url: channel.logo.flatMap(URL.init(string:))) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .frame(width: LiveGuideMetrics.rowHeight * 0.5, height: LiveGuideMetrics.rowHeight * 0.5)
            Text(channel.name).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
        }
        .frame(width: LiveGuideMetrics.channelWidth - Theme.Space.xs, alignment: .leading)
        .padding(.trailing, Theme.Space.xs)
    }

    @ViewBuilder private var track: some View {
        switch schedule {
        case .loaded(let programmes):
            let segments = LiveGuidePolicy.segments(LiveGuidePolicy.cells(programmes, window: window, pointsPerMinute: pointsPerMinute))
            if segments.isEmpty {
                watchLive(String(localized: "Nothing scheduled in this window · Watch live"))
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .gap(let width): Color.clear.frame(width: width)
                        case .cell(let cell): programmeButton(cell)
                        }
                    }
                }
            }
        case .unavailable:
            watchLive(String(localized: "No guide for this channel · Watch live"))
        case .loading, .none:
            Text("Loading guide…").font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, Theme.Space.sm)
        }
    }

    private func programmeButton(_ cell: LiveGuideCell) -> some View {
        let onAir = cell.programme.isOn(at: now)
        return Button { onOpen(channel) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(cell.programme.title).font(Theme.Typography.label.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                Text(timeRange(cell.programme)).font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.xs)
            .frame(width: max(cell.width - 4, 0), height: LiveGuideMetrics.rowHeight - 6, alignment: .leading)
            .background(onAir ? Theme.Palette.accent.opacity(0.24) : Theme.Palette.surface1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .padding(.horizontal, 2)
        }
        .guideCellStyle()
        .accessibilityLabel(Text("\(cell.programme.title), \(timeRange(cell.programme))\(onAir ? ", on now" : "")"))
    }

    private func watchLive(_ title: String) -> some View {
        Button { onOpen(channel) } label: {
            Text(title).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                .padding(.horizontal, Theme.Space.sm)
                .frame(width: max(trackWidth - 4, 0), height: LiveGuideMetrics.rowHeight - 6, alignment: .leading)
                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .padding(.horizontal, 2)
        }
        .guideCellStyle()
    }

    private func timeRange(_ programme: LiveGuideProgramme) -> String {
        "\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))"
    }
}

private extension View {
    @ViewBuilder func guideCellStyle() -> some View {
#if os(tvOS)
        vortxCardButton(radius: Theme.Radius.control)
#else
        buttonStyle(.plain)
#endif
    }
}
