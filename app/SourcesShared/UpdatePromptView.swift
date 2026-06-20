import SwiftUI

/// The modal "an update is available" popup, shared by every Apple platform. Bound via `.sheet(item:)` to
/// `UpdateChecker.shared.prompt`, so it appears automatically once per launch (and again when the hourly
/// re-check finds a still-newer build) instead of hiding in Settings. "Get the update" opens the install
/// channel (AltStore source -> direct IPA -> releases page); "Later" dismisses for this build this launch.
///
/// Uses the system bordered button styles on purpose: on tvOS they carry the focus engine's scale/highlight
/// for free, so the dialog is navigable with the Siri Remote without any custom focus wiring.
struct UpdatePromptView: View {
    let release: UpdateChecker.Release
    /// Called for both "Later" and after "Get the update" so the checker can clear `prompt` and remember the
    /// build. The view also calls `dismiss()` to tear down the sheet.
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var versionLine: String {
        let v = release.version.isEmpty ? "" : "Version \(release.version)"
        let b = "build \(release.build)"
        return v.isEmpty ? b.capitalizedFirst : "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .padding(.top, Theme.Space.lg)

            VStack(spacing: Theme.Space.xs) {
                Text("Update available")
                    .font(titleFont).fontWeight(.bold)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(release.name.isEmpty ? versionLine : "\(release.name) · \(versionLine)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.md)
                }
                .frame(maxHeight: notesMaxHeight)
                .background(Theme.Palette.surface1)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }

            VStack(spacing: Theme.Space.sm) {
                Button {
                    if let url = release.installURL { openURL(url) }
                    finish()
                } label: {
                    Label("Get the update", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)

                Button("Later") { finish() }
                    .buttonStyle(.bordered)
                    .tint(Theme.Palette.textSecondary)
            }
            .padding(.bottom, Theme.Space.lg)
        }
        .padding(.horizontal, Theme.Space.lg)
        // macOS sheets size to their content, so a concrete width keeps the panel laid out (forcing an
        // infinite frame here makes AppKit's constraint solver crash). iOS/tvOS sheets fill, so cap the
        // width and let the content background bleed to the sheet edges.
        #if os(macOS)
        .frame(width: 460)
        .background(Theme.Palette.canvas)
        #else
        .frame(maxWidth: maxCardWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #endif
        .tint(Theme.Palette.accent)
    }

    private func finish() {
        onDismiss()
        dismiss()
    }

    // Platform sizing: a roomy 10-foot dialog on tvOS, a compact centered card on phone/iPad/Mac.
    #if os(tvOS)
    private let iconSize: CGFloat = 64
    private var titleFont: Font { .title }
    private let notesMaxHeight: CGFloat = 360
    private let maxCardWidth: CGFloat = 820
    #else
    private let iconSize: CGFloat = 44
    private var titleFont: Font { .title2 }
    private let notesMaxHeight: CGFloat = 240
    private let maxCardWidth: CGFloat = 460
    #endif
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
