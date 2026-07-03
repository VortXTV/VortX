import SwiftUI

/// Offline downloads, Apple TV edition (#30). A focus-driven list of the device's downloaded titles with
/// per-item state (Downloading %, Paused, Downloaded, Failed + error), a play-from-local action, a delete
/// action, the total storage used, and the storage-eviction caption. It mirrors the iOS `DownloadsView`
/// behaviour and the shared `DownloadManager` / `DownloadStore`, but lays everything out for the TV focus
/// engine (full-width focusable rows with an explicit per-row action bar, no swipe gestures).
///
/// Device-local only: a download is a physical file on ONE device plus a row in the local JSON index. This
/// view never syncs the list and never touches `libraryItem` documents. Play-from-local rebuilds the same
/// engine `PlaybackMeta` a streamed source uses, so progress / Continue Watching record identically.
///
/// Surfaced from `LibraryView` as a section ABOVE the saved-titles grid, shown only when at least one
/// download exists (so a user with no downloads never sees an empty section).
struct TVDownloadsView: View {
    @EnvironmentObject private var presenter: PlayerPresenter   // root-replacement player presentation (play-from-local)
    @ObservedObject private var store = DownloadStore.shared
    private let manager = DownloadManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            // The eviction warning, always visible while the section is shown: tvOS can reclaim app storage
            // under pressure, so a saved download is not guaranteed to persist.
            Text("Apple TV can reclaim app storage when the device runs low, so a saved download may be removed by the system. Re-download it any time it is gone.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, Theme.Space.screenEdge)
            LazyVStack(spacing: Theme.Space.sm) {
                ForEach(store.records) { record in
                    row(record)
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
        }
    }

    /// Section title + the total storage used by completed downloads, right-aligned.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Downloads").sectionTitleStyle()
            Spacer(minLength: Theme.Space.md)
            Text(store.formattedTotalSize())
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, Theme.Space.screenEdge)
    }

    // MARK: Row

    /// One download row: a state glyph, the title + subtitle (quality / progress / error) with a progress
    /// bar while active, then the per-state action bar. The actions are focusable chips (Play for a
    /// completed row, Pause / Resume for an in-flight or failed one) so the TV focus engine always has a
    /// clear target; Delete is always available. No tap-the-whole-row gesture, which is a touch idiom.
    @ViewBuilder private func row(_ record: DownloadRecord) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.lg) {
            content(record)
            Spacer(minLength: Theme.Space.md)
            controls(record)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ record: DownloadRecord) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            leadingGlyph(record)
            VStack(alignment: .leading, spacing: 8) {
                Text(record.displayTitle)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                subtitle(record)
                if record.state == .downloading || record.state == .paused {
                    ProgressView(value: record.fractionComplete)
                        .tint(Theme.Palette.accent)
                        .frame(maxWidth: 460)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func leadingGlyph(_ record: DownloadRecord) -> some View {
        let symbol: String = {
            switch record.state {
            case .completed: return "play.circle.fill"
            case .failed:    return "exclamationmark.triangle.fill"
            case .paused:    return "pause.circle"
            default:         return "arrow.down.circle"
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 34))
            .foregroundStyle(record.state == .failed ? Theme.Palette.textTertiary : Theme.Palette.accent)
    }

    @ViewBuilder private func subtitle(_ record: DownloadRecord) -> some View {
        let parts: [String] = {
            switch record.state {
            case .completed:
                let size = ByteCountFormatter.string(fromByteCount: max(record.bytesDone, record.bytesTotal), countStyle: .file)
                return [record.sourceName, record.qualityText, size].compactMap { $0 }
            case .downloading:
                let pct = Int(record.fractionComplete * 100)
                return [String(localized: "Downloading \(pct)%")]
            case .paused:
                return [String(localized: "Paused")]
            case .failed:
                return [record.errorText ?? String(localized: "Failed")]
            case .queued:
                return [String(localized: "Queued")]
            }
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(2)
        }
    }

    /// The per-state action bar: Play (completed) / Pause (downloading) / Resume (paused or failed), then a
    /// Delete that is always present. Each is a focusable, focus-styled chip so the TV focus engine has a
    /// clear target on every row.
    @ViewBuilder private func controls(_ record: DownloadRecord) -> some View {
        HStack(spacing: Theme.Space.sm) {
            switch record.state {
            case .completed:
                actionChip("Play", "play.fill") { play(record) }
            case .downloading:
                actionChip("Pause", "pause.fill") { manager.pause(id: record.id) }
            case .paused, .failed:
                actionChip("Resume", "arrow.clockwise") { manager.resume(id: record.id) }
            case .queued:
                EmptyView()
            }
            actionChip("Delete", "trash", role: .destructive) { manager.cancel(id: record.id) }
        }
    }

    private func actionChip(_ label: String, _ symbol: String, role: ButtonRole? = nil,
                            _ action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(label, systemImage: symbol)
        }
        .buttonStyle(ChipButtonStyle())
    }

    // MARK: Play-from-local

    /// Play a completed download from its LOCAL file. Rebuilds the engine `PlaybackMeta` so progress /
    /// Continue Watching record exactly as for a streamed source; the request is presented `torrent: false`
    /// because a finished file plays directly (never back through the loopback torrent server). Fail-soft if
    /// the file was purged out from under us: drop the stale row instead of presenting a dead player.
    private func play(_ record: DownloadRecord) {
        guard record.state == .completed, store.fileExists(for: record) else {
            if record.state == .completed { manager.cancel(id: record.id) }   // file gone -> clean up the stale row
            return
        }
        let url = store.fileURL(for: record)
        presenter.request = PlaybackRequest(url: url, title: record.displayTitle, meta: record.playbackMeta,
                                            sourceHint: record.qualityText, torrent: false)
    }
}
