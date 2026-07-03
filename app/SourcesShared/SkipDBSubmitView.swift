import SwiftUI

/// Sheet for submitting or correcting skip segments to the keyless skip.vortx.tv worker. Opened from
/// the player while an episode is playing; pre-fills times from the current playhead so users can
/// scrub to the right point and tap Submit. The inline `skipDBEditBar` in PlayerScreen is the primary
/// editor on iOS/Mac; this sheet shares the `SegmentType` enum and stays available as a form-based path.
struct SkipDBSubmitView: View {
    let imdbId: String
    let season: Int?
    let episode: Int?
    let episodeTitle: String
    let currentTimeSec: Double
    let durationSec: Double
    /// Already-resolved segments from the player (all sources). Shown so the user can tap one
    /// to correct it rather than re-entering times from scratch.
    let existingSegments: [SkipDBSegmentItem]
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: SegmentType = .intro
    @State private var startSec: Double
    @State private var endSec: Double
    @State private var submitting = false
    @State private var submitResult: SubmitResult?

    enum SegmentType: String, CaseIterable, Identifiable {
        case intro, recap, outro, preview
        var id: String { rawValue }
        var label: String {
            switch self {
            case .intro: "Intro"
            case .recap: "Recap"
            case .outro: "Outro / Credits"
            case .preview: "Preview"
            }
        }
    }

    enum SubmitResult {
        case success
        case failure(String)
    }

    init(imdbId: String, season: Int?, episode: Int?, episodeTitle: String,
         currentTimeSec: Double, durationSec: Double,
         existingSegments: [SkipDBSegmentItem], onSubmitted: @escaping () -> Void) {
        self.imdbId = imdbId
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.currentTimeSec = currentTimeSec
        self.durationSec = durationSec
        self.existingSegments = existingSegments
        self.onSubmitted = onSubmitted
        // Pre-fill start to current playhead; end to start + 30s as a sane default.
        _startSec = State(initialValue: max(0, currentTimeSec))
        _endSec   = State(initialValue: max(currentTimeSec + 30, currentTimeSec + 1))
    }

    var body: some View {
        NavigationStack {
            Form {
                // macOS has no title/cancel toolbar items (the shared-window NSToolbar bridge is the
                // Beta 7 crash, so both are compiled out below); carry an in-content header so the
                // sheet stays labeled and dismissable on Mac.
                #if os(macOS)
                Section {
                    HStack {
                        Text("Submit skip segment").font(.headline)
                        Spacer()
                        Button("Cancel") { dismiss() }
                    }
                }
                #endif
                episodeSection
                if !existingSegments.isEmpty { existingSection }
                inputSection
                submitSection
            }
            .formStyle(.grouped)
            // navigationTitle + the cancellation ToolbarItem bridge into the single shared window
            // NSToolbar on macOS and crash in _insertNewItemWithItemIdentifier; iOS/tvOS only.
            #if !os(macOS)
            .navigationTitle("Submit skip segment")
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if !os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #endif
        }
    }

    // MARK: - Sections

    private var episodeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(episodeTitle).font(.headline)
                if let season, let episode {
                    Text("Season \(season) · Episode \(episode)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(imdbId).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }

    private var existingSection: some View {
        Section("Existing segments (tap to correct)") {
            ForEach(existingSegments) { seg in
                Button {
                    selectedType = seg.skipDBType
                    startSec = seg.startSec
                    endSec = seg.endSec
                    submitResult = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(seg.label).foregroundStyle(.primary)
                            Text("\(formatTime(seg.startSec)) → \(formatTime(seg.endSec))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var inputSection: some View {
        Section {
            Picker("Type", selection: $selectedType) {
                ForEach(SegmentType.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            timeRow("Start", seconds: $startSec)
            timeRow("End", seconds: $endSec)
            if durationSec > 0 {
                LabeledContent("Stream duration") {
                    Text(formatTime(durationSec))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Segment times (seconds)")
        } footer: {
            Text("Scrub to the right position in the player before opening this sheet to pre-fill the start time.")
        }
    }

    private var submitSection: some View {
        Section {
            Button {
                Task { await doSubmit() }
            } label: {
                HStack {
                    Spacer()
                    if submitting {
                        ProgressView().controlSize(.small)
                        Text("Submitting…")
                    } else {
                        Text("Submit segment")
                    }
                    Spacer()
                }
            }
            .disabled(submitting || startSec >= endSec)

            if let result = submitResult {
                switch result {
                case .success:
                    Label("Submitted, thank you!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        } footer: {
            Text("Submissions feed VortX's own skip database and help everyone on the title.")
        }
    }

    // MARK: - Time field

    @ViewBuilder private func timeRow(_ label: String, seconds: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField("sec", value: seconds, format: .number.precision(.fractionLength(1)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(formatTime(seconds.wrappedValue))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: - Submit

    private func doSubmit() async {
        submitting = true
        submitResult = nil
        let req = SkipDBClient.SubmitRequest(
            imdb_id: imdbId,
            season: season,
            episode: episode,
            segment_type: selectedType.rawValue,
            start_ms: Int(startSec * 1000),
            end_ms: Int(endSec * 1000),
            duration_ms: durationSec > 0 ? Int(durationSec * 1000) : nil
        )
        do {
            try await SkipDBClient.submit(req)
            await SkipDBClient.invalidateCache(imdbId: imdbId, season: season,
                                               episode: episode, durationSeconds: durationSec)
            submitResult = .success
            onSubmitted()
        } catch {
            submitResult = .failure(error.localizedDescription)
        }
        submitting = false
    }

    // MARK: - Helpers

    private func formatTime(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A resolved segment surfaced to the submit view so the user can tap to correct it.
struct SkipDBSegmentItem: Identifiable {
    let id: String
    let label: String
    let skipDBType: SkipDBSubmitView.SegmentType
    let startSec: Double
    let endSec: Double
}
