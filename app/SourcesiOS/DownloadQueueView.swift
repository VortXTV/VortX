import SwiftUI

/// The download queue manager: ONE screen to see, reorder, pause / resume, and cap the concurrency of
/// offline downloads. It is a pure control surface over the existing `DownloadManager` + `DownloadStore`
/// (no transfer logic of its own): rows are driven by the manager's published state, and every action
/// routes back through the manager, which owns the URLSession machinery and the reorderable drain order.
///
/// Grouped by lifecycle - Downloading, Up next (`.queued`), Paused, and Failed - so the user reads the
/// pipeline top to bottom. Only queued rows carry the up / down reorder controls (the running, paused,
/// and failed states have no queue position to move). Completed downloads are intentionally absent: they
/// are finished library items, surfaced for playback by `DownloadsView`, not part of the pending queue.
///
/// Self-contained (no required inputs, no environment dependency), so a later pass can mount it from any
/// entry point - a NavigationLink in the Downloads screen, or a Settings row - without wiring.
///
/// iOS + macOS only (this file lives in SourcesiOS); Apple TV has its own downloads surface (TVDownloadsView).
struct DownloadQueueView: View {
    @ObservedObject private var store = DownloadStore.shared
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        // Snapshot the groups once per render so the drainer order and the disabled-arrow edges agree.
        let downloading = store.records.filter { $0.state == .downloading }
        let queued = manager.orderedQueuedRecords()
        let paused = store.records.filter { $0.state == .paused }
        let failed = store.records.filter { $0.state == .failed }
        let isEmpty = downloading.isEmpty && queued.isEmpty && paused.isEmpty && failed.isEmpty

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                concurrencyCard(active: downloading.count, queued: queued.count)

                if isEmpty {
                    emptyState
                } else {
                    section("Downloading", systemImage: "arrow.down.circle", tint: Theme.Palette.accent,
                            records: downloading) { row($0) }
                    queuedSection(queued)
                    section("Paused", systemImage: "pause.circle", tint: Theme.Palette.warn,
                            records: paused) { row($0) }
                    section("Failed", systemImage: "exclamationmark.triangle", tint: Theme.Palette.danger,
                            records: failed) { row($0) }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Download Queue")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .macBackAffordance()   // macOS in-content Back + Esc / Cmd-[ (no toolbar back exists)
    }

    // MARK: Concurrency cap

    /// The max-concurrent-downloads control: a stepper over the manager's cap, plus a live activity line
    /// and a plain-language note on what raising / lowering does. The stepper writes through
    /// `setMaxConcurrentDownloads`, which clamps + persists and fills freed slots on a raise.
    @ViewBuilder private func concurrencyCard(active: Int, queued: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Stepper(value: concurrencyBinding, in: DownloadManager.concurrencyRange) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run up to \(manager.maxConcurrentDownloads) at once")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(activitySummary(active: active, queued: queued))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Text("More at once shares your bandwidth across them. Lowering this never interrupts a download already in progress; it just holds the next ones in the queue.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    private var concurrencyBinding: Binding<Int> {
        Binding(get: { manager.maxConcurrentDownloads },
                set: { manager.setMaxConcurrentDownloads($0) })
    }

    private func activitySummary(active: Int, queued: Int) -> String {
        var parts: [String] = []
        parts.append(active == 1 ? String(localized: "1 downloading") : String(localized: "\(active) downloading"))
        if queued > 0 { parts.append(String(localized: "\(queued) waiting")) }
        let size = store.formattedTotalSize()
        parts.append(String(localized: "\(size) on disk"))
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Sections

    /// A titled group of rows, rendered only when it has content.
    @ViewBuilder private func section<RowContent: View>(_ title: LocalizedStringKey, systemImage: String, tint: Color,
                                                        records: [DownloadRecord],
                                                        @ViewBuilder rowContent: @escaping (DownloadRecord) -> RowContent) -> some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionHeader(title, systemImage: systemImage, tint: tint, count: records.count)
                ForEach(records) { rowContent($0) }
            }
        }
    }

    /// The queued group is special: its rows carry the up / down reorder controls, and the first / last
    /// items disable the arrow that would run off the end. Uses the manager's canonical queued order.
    @ViewBuilder private func queuedSection(_ queued: [DownloadRecord]) -> some View {
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionHeader("Up next", systemImage: "arrow.up.arrow.down.circle",
                              tint: Theme.Palette.textSecondary, count: queued.count)
                ForEach(Array(queued.enumerated()), id: \.element.id) { index, record in
                    row(record, isFirst: index == 0, isLast: index == queued.count - 1)
                }
            }
        }
    }

    @ViewBuilder private func sectionHeader(_ title: LocalizedStringKey, systemImage: String,
                                            tint: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("\(count)")
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .textCase(.uppercase)
    }

    // MARK: Row

    /// One download row. `isFirst` / `isLast` are supplied only for queued rows (they gate the reorder
    /// arrows); every other state passes the defaults and shows no arrows.
    @ViewBuilder private func row(_ record: DownloadRecord, isFirst: Bool = true, isLast: Bool = true) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            leadingGlyph(record)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayTitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                subtitle(record)
                if record.state == .downloading || record.state == .paused {
                    ProgressView(value: record.fractionComplete)
                        .tint(Theme.Palette.accent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            controls(record, isFirst: isFirst, isLast: isLast)
        }
        .padding(Theme.Space.sm)
        .vortxSettingsCard()
    }

    @ViewBuilder private func leadingGlyph(_ record: DownloadRecord) -> some View {
        let symbol: String = {
            switch record.state {
            case .downloading: return "arrow.down.circle"
            case .queued:      return "clock"
            case .paused:      return "pause.circle"
            case .failed:      return "exclamationmark.triangle.fill"
            case .completed:   return "checkmark.circle.fill"
            }
        }()
        let tint: Color = {
            switch record.state {
            case .failed: return Theme.Palette.danger
            case .paused: return Theme.Palette.warn
            case .queued: return Theme.Palette.textTertiary
            default:      return Theme.Palette.accent
            }
        }()
        Image(systemName: symbol)
            .font(.system(size: 24))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
    }

    @ViewBuilder private func subtitle(_ record: DownloadRecord) -> some View {
        let parts: [String] = {
            switch record.state {
            case .downloading:
                let pct = Int(record.fractionComplete * 100)
                return [String(localized: "Downloading \(pct)%"), record.sourceName, record.retryNote].compactMap { $0 }
            case .queued:
                return [String(localized: "Waiting"), record.qualityText, record.retryNote].compactMap { $0 }
            case .paused:
                let pct = Int(record.fractionComplete * 100)
                return [String(localized: "Paused at \(pct)%"), record.retryNote].compactMap { $0 }
            case .failed:
                return [record.errorText ?? String(localized: "Failed"), record.retryNote].compactMap { $0 }
            case .completed:
                return [record.qualityText].compactMap { $0 }
            }
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(2)
        }
    }

    /// Per-state controls. Queued rows get the reorder arrows (disabled at the ends); the terminal states
    /// get the matching primary action; every row gets Delete last. Delete routes through the manager's
    /// `cancel`, which stops any live task, clears its bookkeeping, prunes the queue order, and removes the
    /// on-disk file - never a raw store delete that would strand a running transfer.
    @ViewBuilder private func controls(_ record: DownloadRecord, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            switch record.state {
            case .downloading:
                iconButton("pause.fill", "Pause") { manager.pause(id: record.id) }
            case .queued:
                iconButton("chevron.up", "Move up", disabled: isFirst) { manager.moveQueuedEarlier(id: record.id) }
                iconButton("chevron.down", "Move down", disabled: isLast) { manager.moveQueuedLater(id: record.id) }
                iconButton("pause.fill", "Pause") { manager.pause(id: record.id) }
            case .paused:
                iconButton("arrow.clockwise", "Resume") { manager.resume(id: record.id) }
            case .failed:
                iconButton("arrow.clockwise", "Retry") { manager.resume(id: record.id) }
            case .completed:
                EmptyView()
            }
            iconButton("trash", "Remove") { manager.cancel(id: record.id) }
        }
    }

    private func iconButton(_ symbol: String, _ label: LocalizedStringKey,
                            disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(disabled ? Theme.Palette.textTertiary.opacity(0.4) : Theme.Palette.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())   // hit-test the full box, not the glyph silhouette
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    // MARK: Empty state

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("Nothing downloading")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Downloads you start appear here, where you can reorder, pause, and set how many run at once.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}
