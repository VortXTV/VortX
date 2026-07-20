import SwiftUI
import Combine

/// Pre-download quality / language / size picker (#30 follow-up). Before a download starts, the user sees
/// the SAME ranked candidate sources the play path would choose from - each with its resolution, advertised
/// audio language(s), and estimated file size - and taps the exact one to save. Tapping a source starts its
/// download with AUTOMATIC fallback to the next-best source if the chosen one cannot be downloaded.
///
/// iOS + macOS only (this file lives in SourcesiOS); Apple TV uses its own detail-page "Download best" path.
/// Self-contained: it takes a `DownloadPickerRequest` (the same ranking inputs the manual download path
/// already computes) and reuses the shared machinery end to end - `StreamRanking` for ranking + the
/// resolution / size / language readouts, `DebridCoordinator` + `prepareTorrentStream` to resolve a link,
/// and `DownloadManager` for the transfer. It never re-implements the transfer layer and writes nothing to
/// the account / `libraryItem` documents (a download is device-local).
///
/// WIRING (a later pass owns the entry point; this sheet is presentation-only): hold an optional
/// `@State var downloadPicker: DownloadPickerRequest?`, attach `.downloadQualityPicker($downloadPicker)` to
/// the detail / episode source list, and set it from a "Download..." action, building the request from the
/// SAME values the manual download path passes to `StreamRanking.best`: the display groups, the remembered
/// quality (continuity), the source pin, the confirmed cached-debrid hashes, the `PlaybackMeta`, and (for a
/// series) the `DebridEpisode`.
struct DownloadQualityPickerView: View {
    let request: DownloadPickerRequest
    @Environment(\.dismiss) private var dismiss

    /// The ranked candidate sources, best-first + de-duplicated by playable URL, computed EXACTLY as the
    /// play path's `StreamRanking.best` picks its winner (score + continuity + pin), so row 0 is the source
    /// "Download best" would pick and the list order is the fallback order.
    private var candidates: [CoreStream] {
        StreamRanking.rankedCandidates(request.groups, continuity: request.continuity,
                                       pin: request.pin, debridCachedHashes: request.cachedHashes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Palette.hairline)
            if candidates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, stream in
                            sourceRow(stream, isRecommended: index == 0)
                        }
                        footnote
                    }
                    .padding(Theme.Space.md)
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a download")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(request.subtitle ?? request.meta.name)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.md)
            Button("Done") { dismiss() }
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.accent)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.md)
    }

    // MARK: Source row

    /// One tappable candidate: source name, its quality tags, and a meta line with the advertised audio
    /// language(s) and the estimated file size. Tapping it starts THAT download and arms the ranked tail as
    /// automatic next-best swaps, then dismisses. The first (best) row is badged "Recommended".
    private func sourceRow(_ stream: CoreStream, isRecommended: Bool) -> some View {
        Button {
            DownloadPickCoordinator.shared.startDownload(chosen: stream, rankedCandidates: candidates,
                                                         meta: request.meta, episode: request.episode)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(stream.name ?? String(localized: "Source"))
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                        if isRecommended { recommendedBadge }
                    }
                    let tags = StreamRanking.sourceDetail(stream).tags
                    if !tags.isEmpty {
                        Text(tags)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Text(metaLine(stream))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.sm)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Shared list-row glass (flat shadow, card-weight fill) instead of a hand-rolled surface1 +
            // hairline plate; the preset's own 1px top highlight replaces the stroke. Matches the stream
            // rows on the detail screen. The accent "Recommended" badge keeps its solid fill: meaning surface.
            .vortxGlassListRow(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var recommendedBadge: some View {
        Text("Recommended")
            .font(Theme.Typography.eyebrow)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(Theme.Palette.accent))
    }

    /// The audio-language + estimated-size line. Languages are the codes the source text advertises (via the
    /// ranker's own detector, so no duplicate parsing), localized to display names; size is the add-on's
    /// advertised figure, or "Size unknown" when none was given (so the row never looks empty).
    private func metaLine(_ stream: CoreStream) -> String {
        var parts: [String] = []
        if let languages = languageText(stream) { parts.append(languages) }
        parts.append(StreamRanking.sizeText(stream) ?? String(localized: "Size unknown"))
        return parts.joined(separator: "  ·  ")
    }

    /// Advertised audio language(s) as display names (at most three), or nil when the source names none.
    private func languageText(_ stream: CoreStream) -> String? {
        let codes = StreamRanking.languageCodesAdvertised(in: StreamRanking.signature(stream))
        let names = codes.compactMap { Locale.current.localizedString(forLanguageCode: $0) }.prefix(3)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: Empty + footnote

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("No downloadable sources for this title yet.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }

    private var footnote: some View {
        Text("If a source can't be downloaded, VortX automatically tries the next best one.")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.top, Theme.Space.xs)
            .padding(.horizontal, Theme.Space.xs)
    }
}

/// The presentation payload for `DownloadQualityPickerView`, carrying the same ranking inputs the manual
/// download path already has in hand. Identifiable so it drives a `.sheet(item:)`.
struct DownloadPickerRequest: Identifiable {
    let id = UUID()
    /// The engine playback identity for the title being downloaded (movie, or a specific series episode).
    let meta: PlaybackMeta
    /// The season/episode for a series download (used to resolve a season-pack debrid link); nil for a movie.
    let episode: DebridEpisode?
    /// The loaded, display-filtered source groups for this title (the same set the source list shows).
    let groups: [CoreStreamSourceGroup]
    /// Remembered-quality continuity hint, applied to ranking exactly as the play path does.
    let continuity: String?
    /// An applicable source pin, applied to ranking exactly as the play path does.
    let pin: ResolvedPin?
    /// Account-confirmed cached-debrid infohashes, so cached sources rank ahead of uncached peers.
    let cachedHashes: Set<String>
    /// Optional heading subtitle (e.g. an "S1E5" episode label); defaults to the title name.
    var subtitle: String?

    init(meta: PlaybackMeta, episode: DebridEpisode?, groups: [CoreStreamSourceGroup],
         continuity: String?, pin: ResolvedPin?, cachedHashes: Set<String>, subtitle: String? = nil) {
        self.meta = meta
        self.episode = episode
        self.groups = groups
        self.continuity = continuity
        self.pin = pin
        self.cachedHashes = cachedHashes
        self.subtitle = subtitle
    }
}

extension View {
    /// Present the download quality/language/size picker for a bound request. One-line wiring for the entry
    /// point a later pass adds (this file owns the sheet; it does not touch the detail / root views).
    func downloadQualityPicker(_ request: Binding<DownloadPickerRequest?>) -> some View {
        sheet(item: request) { DownloadQualityPickerView(request: $0) }
    }
}

/// Drives a picked download's start + its automatic next-best fallback chain. Persistent (@MainActor
/// singleton) because the fallback must outlive the ephemeral picker sheet: the chosen source's byte
/// transfer can fail long after the sheet is dismissed, and the swap to the next-best source has to happen
/// then. It reuses the proven pattern from `BatchDownloadCoordinator` (observe `DownloadStore`, swap once
/// per failure, queue-before-cancel) but generalized to a single title's ranked candidate chain.
///
/// LAYERING: resolution (`DebridCoordinator` + `prepareTorrentStream`) and orchestration stay OUT of
/// `DownloadManager` (which is transfer-only and shared with tvOS, where `prepareTorrentStream` does not
/// exist); this coordinator lives in SourcesiOS beside the picker, exactly where those helpers are visible.
@MainActor
final class DownloadPickCoordinator: ObservableObject {
    static let shared = DownloadPickCoordinator()

    /// The remaining ranked fallbacks for an in-flight download, keyed by its record id, plus the context to
    /// re-queue one. Present only while a chain has untried alternates; consumed as it drains.
    private struct Chain {
        let remaining: [CoreStream]
        let meta: PlaybackMeta
        let episode: DebridEpisode?
    }
    private var chains: [UUID: Chain] = [:]
    private var observer: AnyCancellable?

    private init() {
        // Watch the store for a tracked download flipping to `.failed` (the byte transfer failing, which can
        // happen well after the picker is gone) so the swap can fire independently. Cheap: a no-op whenever no
        // chain is armed. Same main-actor hop idiom the batch coordinator uses.
        observer = DownloadStore.shared.$records
            .sink { [weak self] _ in Task { @MainActor in self?.handleFailures() } }
    }

    // MARK: Public API

    /// Start downloading `chosen`, arming the ranked tail (the candidates AFTER the chosen one, best-first) as
    /// automatic next-best swaps if the transfer fails. `rankedCandidates` is the full best-first list from
    /// the picker; the chosen source is filtered out of the fallback tail by playable URL so it is never
    /// retried against itself.
    func startDownload(chosen: CoreStream, rankedCandidates: [CoreStream],
                       meta: PlaybackMeta, episode: DebridEpisode?) {
        let chosenURL = chosen.playableURL?.absoluteString
        let fallbacks = rankedCandidates.filter { $0.playableURL?.absoluteString != chosenURL }
        Task { @MainActor [weak self] in
            await self?.launch([chosen] + fallbacks, meta: meta, episode: episode, replacing: nil)
        }
    }

    // MARK: Launch + fallback

    /// Launch the head of `candidates`; register the tail as automatic next-best swaps. `replacing`, when set,
    /// is a `.failed` record to drop AFTER a live replacement is queued (queue-before-cancel, so an app kill in
    /// the window leaves the failed row to retry from rather than orphaning the title). Fully fail-soft: an
    /// unplayable head, a synchronous refusal (an HLS source a device can't save, a storage shortfall), or a
    /// later byte-transfer failure all advance to the next candidate; if nothing can be queued the original
    /// `.failed` row (if any) stands as the honest outcome.
    private func launch(_ candidates: [CoreStream], meta: PlaybackMeta,
                        episode: DebridEpisode?, replacing failedID: UUID?) async {
        var queue = candidates
        while let head = queue.first {
            queue.removeFirst()
            guard let url = head.playableURL else { continue }   // unplayable candidate: skip to the next
            // Resolve a cached-debrid direct link when possible; a raw torrent must have its loopback stream
            // /created first, exactly as the manual + batch download paths do (#21).
            let resolved = await DebridCoordinator.shared.resolvedPlaybackURL(for: head, episode: episode)
            if resolved == nil, head.isTorrent { _ = prepareTorrentStream(head) }
            let record = DownloadManager.shared.download(stream: head, meta: meta, resolvedURL: resolved ?? url,
                                                         sourceName: head.name,
                                                         qualityText: StreamRanking.signature(head))
            // download() can refuse synchronously (an HLS source on a device that can't save HLS, or a storage
            // shortfall): that record is born `.failed`. Discard it and try the next candidate.
            if DownloadStore.shared.record(id: record.id)?.state == .failed {
                DownloadManager.shared.cancel(id: record.id)
                continue
            }
            // A live replacement is queued: NOW drop the prior failed original and note the swap on the new row.
            if let failedID {
                DownloadManager.shared.cancel(id: failedID)
                DownloadStore.shared.update(id: record.id) {
                    $0.retryNote = String(localized: "Switched to next-best source (previous source failed)")
                }
            }
            // Arm whatever ranked candidates remain as this download's automatic next-best swaps.
            if !queue.isEmpty { chains[record.id] = Chain(remaining: queue, meta: meta, episode: episode) }
            return
        }
        // Nothing in the list could be queued. A prior `.failed` row (`failedID`) is left in place as the
        // honest failure, never cancelled, so the user sees it rather than a vanished download.
    }

    /// React to store changes for the downloads we armed a chain for: a tracked record that flipped to
    /// `.failed` gets ONE swap to its next-best source; one that completed drops its chain. Cheap - a no-op
    /// unless a chain is armed - and each chain fires at most once per record (consumed before swapping), so a
    /// still-failing series of alternates drains the chain and stops rather than looping.
    private func handleFailures() {
        guard !chains.isEmpty else { return }
        let records = DownloadStore.shared.records
        for (id, chain) in chains {
            guard let record = records.first(where: { $0.id == id }) else { chains[id] = nil; continue }
            switch record.state {
            case .failed:
                chains[id] = nil   // consume BEFORE swapping so a still-failing alternate can never re-arm
                let remaining = chain.remaining, meta = chain.meta, episode = chain.episode
                Task { @MainActor [weak self] in
                    await self?.launch(remaining, meta: meta, episode: episode, replacing: id)
                }
            case .completed:
                chains[id] = nil   // succeeded: the armed swaps are no longer needed
            default:
                break
            }
        }
    }
}
