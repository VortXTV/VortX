import Foundation

/// A viewport-sized avatar grid, not fixed-width cards that overflow a phone or Mac window.
struct ProfilePickerLayout {
    let width: CGFloat
    let largeText: Bool
    let isPhone: Bool
    let isTV: Bool

    init(width: CGFloat, largeText: Bool, isPhone: Bool = false, isTV: Bool = false) {
        self.width = width
        self.largeText = largeText
        self.isPhone = isPhone
        self.isTV = isTV
    }

    var isWide: Bool { width >= 700 }
    var contentMaxWidth: CGFloat { isTV ? 1440 : 1100 }
    var horizontalInset: CGFloat { isTV && isWide ? 64 : (isWide ? 48 : 24) }
    var spacing: CGFloat { isTV && isWide ? 40 : (isWide ? 28 : 18) }
    var nameTextSize: CGFloat { isTV ? 28 : 18 }
    var movieTextSize: CGFloat { isTV ? 34 : 26 }
    var headingTextSize: CGFloat { isTV ? 50 : (isWide ? 40 : 25) }
    var columns: Int {
        if isTV && isWide {
            if width < 1000 { return largeText ? 2 : 3 }
            if width < 1280 { return largeText ? 3 : 4 }
            return largeText ? 4 : 5
        }
        if largeText { return isWide ? 4 : 2 }
        if width < 350 { return 2 }
        if width < 700 { return 3 }
        return width < 1000 ? 4 : 6
    }
    var avatarSide: CGFloat {
        let available = min(width, contentMaxWidth) - horizontalInset * 2 - 16 - spacing * CGFloat(columns - 1)
        return max(32, min(isTV && isWide ? 216 : (isWide ? 160 : 110), available / CGFloat(columns)))
    }

    /// Center each populated row, including the last row; empty grid tracks must not shift avatars.
    func rows(itemCount: Int) -> [Range<Int>] {
        guard itemCount > 0 else { return [] }
        return stride(from: 0, to: itemCount, by: columns).map {
            $0..<min($0 + columns, itemCount)
        }
    }
}
