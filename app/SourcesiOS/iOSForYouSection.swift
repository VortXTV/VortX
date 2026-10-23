import SwiftUI

/// Which way the interests picker opens: the first-time offer (Done / Skip for now) or Tune (Save / Cancel).
struct iOSForYouInterestsPresentation: Identifiable, Equatable {
    let firstRun: Bool
    /// Captured with the presentation so the draft can only ever save for the profile it opened for.
    let session: ForYouInterestsEditSession
    var id: UUID { session.id }
}

/// "For you" heading with Tune, above the interest rows on iPhone, iPad and Mac Home. The rows
/// themselves are the Home `PosterRail`, so cards match every other rail.
struct iOSForYouHeader: View {
    let onTune: () -> Void

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("For you").sectionTitleStyle()
            Spacer()
            Button(action: onTune) { Label("Tune", systemImage: "slider.horizontal.3") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .accessibilityHint(Text("Choose the genres, scenes and people For You is built from"))
        }
        .padding(.horizontal, Theme.Space.md)
    }
}

/// Shown in place of the rows when the profile skipped the picker or cleared every choice.
struct iOSForYouInvite: View {
    let onTune: () -> Void

    var body: some View {
        Button(action: onTune) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "heart.text.square").font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tell VortX what you like").font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Pick genres, scenes and people, and For You builds rows around them.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(Theme.Space.sm)
            .vortxSettingsCard()
        }
        .vortxCardButton()
        .padding(.horizontal, Theme.Space.md)
    }
}
