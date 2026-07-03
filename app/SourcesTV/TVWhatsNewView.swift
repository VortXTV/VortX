import SwiftUI

/// The full release changelog on Apple TV, reached from Settings > About > What's New. Renders the
/// bundled CHANGELOG.md (via the shared ChangelogParser) as one focusable card per release, so the
/// Siri Remote scrolls the read-only page by moving focus between cards; falls back to the curated
/// WhatsNew.highlights for the current version when the changelog resource is missing. tvOS twin of
/// SourcesiOS/WhatsNewView.
struct TVWhatsNewView: View {
    @EnvironmentObject private var theme: ThemeManager   // observe so accent / text-size changes repaint
    private let sections: [ChangelogSection] = TVWhatsNewView.loadSections()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("What's New").screenTitleStyle()
                Text("You're on VortX \(WhatsNew.version)")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                ForEach(sections) { section in
                    ChangelogSectionCard(section: section)
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    /// Group the flat parsed blocks into one section per `## ` version header, so each release renders
    /// as its own focusable card. loadBlocks always leads with a version block (parse skips everything
    /// before the first header; the fallback starts with one), so the seed title never shows.
    private static func loadSections() -> [ChangelogSection] {
        var sections: [ChangelogSection] = []
        var title = "VortX \(WhatsNew.version)"
        var blocks: [ChangelogParser.Block] = []
        func flush() {
            guard !blocks.isEmpty else { return }
            sections.append(ChangelogSection(id: sections.count, title: title, blocks: blocks))
            blocks = []
        }
        for block in ChangelogParser.loadBlocks() {
            if block.kind == .version {
                flush()
                title = block.text
            } else {
                blocks.append(block)
            }
        }
        flush()
        return sections
    }
}

/// One release's worth of changelog blocks, keyed for ForEach by document order.
private struct ChangelogSection: Identifiable {
    let id: Int
    let title: String
    let blocks: [ChangelogParser.Block]
}

/// A focusable surface card for one release: version title in the accent, then the release's subheads,
/// bullets, and paragraphs. Focus brightens the fill and draws the accent ring (the RowFocusStyle look),
/// and moving focus card-to-card is what drives the ScrollView on tvOS.
private struct ChangelogSectionCard: View {
    let section: ChangelogSection
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(section.title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.accent)
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .version:
                    EmptyView()   // versions start a new card; none appear inside a section
                case .subhead:
                    Text(block.text)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Space.xs)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Image(systemName: "sparkle")
                            .font(Theme.Typography.eyebrow)
                            .foregroundStyle(Theme.Palette.accent)
                        Text(ChangelogParser.inlineMarkdown(block.text))
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph:
                    Text(ChangelogParser.inlineMarkdown(block.text))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Theme.Palette.surface2 : Theme.Palette.surface1,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Palette.accent, lineWidth: focused ? 3 : 0)
        )
        .focusable()
        .focused($focused)
        .animation(Theme.Motion.state, value: focused)
    }
}
