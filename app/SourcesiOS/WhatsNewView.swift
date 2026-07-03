import SwiftUI

/// The full release changelog, reached from Settings > What's New (it is no longer shown automatically on
/// launch). Renders the bundled CHANGELOG.md as styled sections via the shared ChangelogParser; falls back
/// to the curated WhatsNew.highlights for the current version if the changelog resource is missing.
/// iOS/Mac only (SourcesiOS); the Apple TV twin is SourcesTV/TVWhatsNewView.
struct WhatsNewView: View {
    private let blocks: [ChangelogParser.Block] = ChangelogParser.loadBlocks()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("What's New")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.bottom, Theme.Space.xs)

                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block.kind {
                    case .version:
                        Text(block.text)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.Palette.accent)
                            .padding(.top, Theme.Space.lg)
                    case .subhead:
                        Text(block.text)
                            .font(.headline)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .padding(.top, Theme.Space.xs)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                            Image(systemName: "sparkle")
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.accent)
                            Text(ChangelogParser.inlineMarkdown(block.text))
                                .font(.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .paragraph:
                        Text(ChangelogParser.inlineMarkdown(block.text))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.canvas)
        #if os(iOS)
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
