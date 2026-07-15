import SwiftUI

/// Smart Source Selection (Lane A). One shared, self-contained panel that presents each source criterion as
/// a VISIBLE per-criterion chip (Prefer / Only / Avoid), the Avoid-behavior picker, the auto-pick toggle, and
/// a live preview of what the current chips would surface. Mounted in BOTH the iOS/Mac and tvOS Settings
/// "Streams" blocks; it binds DIRECTLY to the `SourcePreferences` singleton (the same direct-singleton
/// pattern both Settings files document), writing the EXISTING keys, so there is no migration and no new
/// per-criterion state.
///
/// Chip -> existing key mapping:
///   - Keywords: Prefer (new `preferKeywords`) / Only (`includeKeywords`) / Avoid (`excludeKeywords`).
///   - HDR = Only (`hdrOnly`), Cached = Only (`instantOnly`), My audio = Only (`preferredAudioOnly`).
///   - Dead swarms = Avoid (`hideDeadTorrents`), AV1 = Avoid (`excludeAV1`), Unknown quality = Avoid
///     (`hideUnknownResolution`).
/// CAM / TS and other fake-quality junk stay HARD-hidden by the Safety filter regardless of any chip, which
/// the footnote states plainly.
struct SourceFilterChipsView: View {
    @ObservedObject var prefs: SourcePreferences
    @StateObject private var preview = SourcePreviewModel()

    /// Which state a boolean criterion chip represents, for its overline badge and accent.
    enum ChipKind {
        case prefer, only, avoid
        var label: String {
            switch self {
            case .prefer: return String(localized: "PREFER")
            case .only:   return String(localized: "ONLY")
            case .avoid:  return String(localized: "AVOID")
            }
        }
        var tint: Color {
            switch self {
            case .prefer: return Theme.Palette.accent
            case .only:   return Theme.Palette.accent
            case .avoid:  return Theme.Palette.warn
            }
        }
    }

    init(prefs: SourcePreferences = .shared) {
        self.prefs = prefs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Smart source selection")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(prefs.safetyMode == "off"
                 ? String(localized: "Tap a chip to prefer, require, or avoid a kind of source. Type words to prefer or avoid them by name. CAM and fake-quality sources always rank last; turn on the Safety filter below to hide them entirely.")
                 : String(localized: "Tap a chip to prefer, require, or avoid a kind of source. Type words to prefer or avoid them by name. CAM and fake-quality sources stay hidden by the Safety filter."))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)

            criterionChips
            keywordLanes
            avoidBehaviorPicker
            autoPickToggle
            previewPanel
        }
        .onChange(of: prefs.rankingSignature) { _ in preview.refresh() }
    }

    // MARK: Criterion chips (boolean prefs shown as visible Only / Avoid chips)

    private var criterionChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.sm)],
                  alignment: .leading, spacing: Theme.Space.sm) {
            chip(String(localized: "Cached"), kind: .only, isOn: prefs.instantOnly) {
                prefs.instantOnly.toggle()
            }
            chip(String(localized: "HDR / DV"), kind: .only, isOn: prefs.hdrOnly) {
                prefs.hdrOnly.toggle()
            }
            chip(String(localized: "My audio"), kind: .only, isOn: prefs.preferredAudioOnly) {
                prefs.preferredAudioOnly.toggle()
            }
            chip(String(localized: "Stated quality"), kind: .only, isOn: prefs.hideUnknownResolution) {
                prefs.hideUnknownResolution.toggle()
            }
            chip(String(localized: "Dead swarms"), kind: .avoid, isOn: prefs.hideDeadTorrents) {
                prefs.hideDeadTorrents.toggle()
            }
            chip(String(localized: "AV1"), kind: .avoid, isOn: prefs.excludeAV1) {
                prefs.excludeAV1.toggle()
            }
        }
    }

    /// One tappable criterion pill: an overline state badge (ONLY / AVOID) over the criterion name, filled
    /// when engaged. A Button so it is focusable on tvOS and tappable on touch/Mac.
    @ViewBuilder
    private func chip(_ title: String, kind: ChipKind, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.label)
                    .font(Theme.Typography.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(kind.tint)
                Text(title)
                    .font(Theme.Typography.label)
                    .foregroundStyle(isOn ? kind.tint : Theme.Palette.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs)
            // The shared glass chip: neutral idle pill, ember/warn tint composited above the glass when
            // engaged (kind.tint keeps Only=accent and Avoid=warn reading clearly, same as ChipButtonStyle).
            .vortxGlassChip(selected: isOn, tint: kind.tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: Keyword lanes (Prefer / Only / Avoid words)

    private var keywordLanes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            keywordField(String(localized: "Prefer words"), kind: .prefer, text: $prefs.preferKeywords,
                         hint: String(localized: "e.g. remux, atmos"))
            keywordField(String(localized: "Only words"), kind: .only, text: $prefs.includeKeywords,
                         hint: String(localized: "e.g. remux"))
            keywordField(String(localized: "Avoid words"), kind: .avoid, text: $prefs.excludeKeywords,
                         hint: String(localized: "e.g. cam, ts, hindi"))
            Text(prefs.keywordsAreRegex
                 ? String(localized: "Only / Avoid words are treated as regex patterns (Match words as regex is on). Prefer words are always plain comma-separated words.")
                 : String(localized: "Comma-separated words matched in the source name. Prefer boosts, Only requires, Avoid uses the behavior below."))
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
            // Prefer + "Rank it down" are RANKING nudges, so they do nothing while Use add-on ranking order is
            // on (the list keeps the add-on's own order). Only (require) and Avoid = Hide still filter. State
            // it so the Prefer lane is not a silent no-op.
            if prefs.useAddonOrder {
                Text("Prefer and Rank it down don't reorder while Use add-on ranking order is on. Only and Avoid = Hide still apply.")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.warn)
            }
        }
    }

    @ViewBuilder
    private func keywordField(_ title: String, kind: ChipKind, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(kind.label)  \(title)")
                .font(Theme.Typography.eyebrow)
                .tracking(1.0)
                .foregroundStyle(kind.tint)
            TextField(hint, text: text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.xs)
                .vortxGlassField(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: Avoid behavior

    private var avoidBehaviorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("When I avoid a source")
                .font(Theme.Typography.eyebrow)
                .tracking(1.0)
                .foregroundStyle(Theme.Palette.textSecondary)
            // Two chip buttons instead of a segmented Picker: `.pickerStyle(.segmented)` is unavailable on
            // tvOS, and this view is shared across both settings surfaces.
            HStack(spacing: Theme.Space.sm) {
                behaviorChip(String(localized: "Hide it"), value: "hide")
                behaviorChip(String(localized: "Rank it down"), value: "rank")
            }
            Text(avoidBehaviorCaption)
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    /// The Avoid-behavior caption, honest about BOTH the chosen behavior AND whether the Safety filter is
    /// actually on (it defaults to off, so CAM / fake-quality sources are not hidden until the viewer turns
    /// it on; they only rank last). Split out so neither settings surface hits a tvOS type-checker blowup on
    /// a nested ternary.
    private var avoidBehaviorCaption: String {
        let safetyOn = prefs.safetyMode != "off"
        switch (prefs.avoidBehavior == "rank", safetyOn) {
        case (true, true):
            return String(localized: "Avoided sources stay in the list but sink to the bottom. CAM and fake-quality sources are hidden by the Safety filter.")
        case (true, false):
            return String(localized: "Avoided sources stay in the list but sink to the bottom. CAM and fake-quality sources also rank last; turn on the Safety filter to hide them.")
        case (false, true):
            return String(localized: "Avoided sources are hidden from the list. CAM and fake-quality sources are hidden by the Safety filter.")
        case (false, false):
            return String(localized: "Avoided sources are hidden from the list. CAM and fake-quality sources rank last; turn on the Safety filter to hide them too.")
        }
    }

    @ViewBuilder
    private func behaviorChip(_ title: String, value: String) -> some View {
        let selected = prefs.avoidBehavior == value
        Button { prefs.avoidBehavior = value } label: {
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.xs)
                .vortxGlassChip(selected: selected)
        }
        .buttonStyle(.plain)
    }

    // MARK: Auto-pick

    private var autoPickToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $prefs.autoPickBest) {
                Text("Auto-pick my best source")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .tint(Theme.Palette.accent)
            Text("Play the top-ranked source straight away instead of opening the source list. Back out of the player any time to see the full source list.")
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    // MARK: Live preview

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Preview")
                    .font(Theme.Typography.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(preview.hiddenCount > 0
                     ? "\(preview.rows.count) shown · \(preview.hiddenCount) hidden"
                     : "\(preview.rows.count) shown")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if preview.rows.isEmpty {
                Text("No sources would show with these settings.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ForEach(preview.rows) { row in
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: row.isBest ? "star.fill" : "circle.fill")
                            .font(.system(size: row.isBest ? 12 : 6))
                            .foregroundStyle(row.isBest ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.qualityLabel)
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            if let reason = row.reason {
                                Text(reason)
                                    .font(Theme.Typography.eyebrow)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }
            }
            Text("A sample of what the current chips would surface. Your real list uses the sources each title actually returns.")
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.sm)
        .vortxGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    fillAlpha: VortXGlass.cardFillAlpha, shadow: .flat)
    }
}
