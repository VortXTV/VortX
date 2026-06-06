import SwiftUI

/// A centered empty / not-signed-in / error state: an icon, a title, and a short line.
/// Used instead of an endless spinner when there is genuinely nothing to show.
struct CoreEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }

    /// The standard "you are not signed in" state, shown on the main tabs.
    static var signedOut: CoreEmptyState {
        CoreEmptyState(
            systemImage: "person.crop.circle.badge.questionmark",
            title: "Sign in to get started",
            message: "Open the Settings tab and sign in to your Stremio account to load your library, catalogs, and add-ons."
        )
    }
}
