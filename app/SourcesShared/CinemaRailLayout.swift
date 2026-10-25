import Foundation

/// Pure viewport geometry shared by the title/collection and episode rails, never playback state.
enum CinemaRailLayout {
    /// A desktop/tablet preview floats inside its window; narrow phones use all available height.
    /// Keep these limits independent of content so long text scrolls rather than expanding past the window.
    static func quickViewFrame(viewport: CGSize) -> CGSize {
        let width = max(1, viewport.width)
        let height = max(1, viewport.height)
        let inset: CGFloat = width >= 700 ? 32 : (width >= 600 ? 16 : 0)
        return CGSize(width: max(1, min(1180, width - 2 * inset)),
                      height: width < 600 ? height : max(1, min(820, height - 2 * inset)))
    }

    static func quickViewContentInset(width: CGFloat) -> CGFloat { width >= 700 ? 40 : 20 }

    static func titleWidth(viewport: CGFloat, compact: Bool, inset: CGFloat, spacing: CGFloat) -> CGFloat {
        let available = max(1, viewport - 2 * inset)
        if compact { return max(1, (available - spacing) / 2) }
        return min(300, max(224, (available - 3 * spacing) / 4))
    }

    static func episodeWidth(viewport: CGFloat, inset: CGFloat, spacing: CGFloat) -> CGFloat {
        let available = max(1, viewport - 2 * inset)
        let columns = max(1, Int((available + spacing) / (280 + spacing)))
        return min(340, (available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    /// Wide-window episode grid (Mac / iPad): as many columns as fit at a readable minimum card width, with
    /// the cards widened to fill the row exactly, so every row is a clean edge-to-edge band of whole cards.
    static func episodeGrid(viewport: CGFloat, inset: CGFloat, spacing: CGFloat,
                            minimumCard: CGFloat = 260) -> (columns: Int, cardWidth: CGFloat) {
        let available = max(1, viewport - 2 * inset)
        let columns = max(1, Int((available + spacing) / (minimumCard + spacing)))
        return (columns, max(1, (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)))
    }

    static func visibleEpisodes(viewport: CGFloat, cardWidth: CGFloat, inset: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((max(1, viewport - 2 * inset) + spacing) / (cardWidth + spacing)))
    }

    static func pageStart(current: Int, direction: Int, visible: Int, count: Int) -> Int {
        min(max(0, count - max(1, visible)), max(0, current + direction * max(1, visible)))
    }
}
