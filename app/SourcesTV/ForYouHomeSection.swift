import SwiftUI

/// Which way the interests picker opens: the first-time offer (Done / Skip for now) or Tune (Save / Cancel).
struct ForYouInterestsPresentation: Identifiable, Equatable {
    let firstRun: Bool
    /// Captured with the presentation so the draft can only ever save for the profile it opened for.
    let session: ForYouInterestsEditSession
    var id: UUID { session.id }
}

/// The For You section on tvOS Home: a "For you" header with Tune, then each interest row in the same
/// `ExternalWatchlistRow` every other recommendation rail uses, so cards (landscape or poster, per the
/// user's card setting), focus and the long-press menu match the rest of Home exactly.
struct ForYouHomeSectionTV: View {
    let rows: [ForYouRowsModel.Row]
    /// True once the profile has no interests (skipped, or cleared every choice): show the invite instead.
    let showInvite: Bool
    var focusModel: FocusedItemModel? = nil
    let onTune: () -> Void

    var body: some View {
        if !rows.isEmpty {
            HStack(alignment: .lastTextBaseline) {
                Text("For you").sectionTitleStyle()
                Spacer()
                Button(action: onTune) { Label("Tune", systemImage: "slider.horizontal.3") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .accessibilityHint(Text("Choose the genres, scenes and people For You is built from"))
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            ForEach(rows) { row in
                ExternalWatchlistRow(eyebrow: row.eyebrow, title: row.title, items: row.items, focusModel: focusModel)
            }
        } else if showInvite {
            Button(action: onTune) {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "heart.text.square").font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tell VortX what you like").font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("Pick genres, scenes and people, and For You builds rows around them.")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.md)
                .vortxSettingsCard()
            }
            .vortxCardButton()
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenEdge)
        }
    }
}
