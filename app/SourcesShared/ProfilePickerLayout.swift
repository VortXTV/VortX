import Foundation

/// A viewport-sized avatar grid, not fixed-width cards that overflow a phone or Mac window.
struct ProfilePickerLayout {
    let width: CGFloat
    let largeText: Bool
    let isPhone: Bool

    init(width: CGFloat, largeText: Bool, isPhone: Bool = false) {
        self.width = width
        self.largeText = largeText
        self.isPhone = isPhone
    }

    var isWide: Bool { width >= 700 }
    var horizontalInset: CGFloat { isWide ? 48 : 24 }
    var spacing: CGFloat { isWide ? 28 : 18 }
    var columns: Int {
        if largeText { return isWide ? 4 : 2 }
        if width < 350 { return 2 }
        if width < 700 { return 3 }
        return width < 1000 ? 4 : 6
    }
    var avatarSide: CGFloat {
        let available = min(width, 1100) - horizontalInset * 2 - 16 - spacing * CGFloat(columns - 1)
        return max(32, min(isWide ? 160 : 110, available / CGFloat(columns)))
    }
}
