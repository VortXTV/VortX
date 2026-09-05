import Foundation

/// Pure geometry policy for the touch detail hero. The portrait fraction is intentionally shared by the
/// movie/show and per-episode paths so a pushed episode does not collapse back to the old 320pt strip.
/// Landscape and unusually short windows retain a smaller usable band for the controls below it.
enum IOSDetailHeroLayout {
    static let portraitFraction = 0.78
    static let landscapeFraction = 0.58
    static let invalidViewportFallback: CGFloat = 320

    static func heroHeight(viewport: CGFloat, width: CGFloat) -> CGFloat {
        guard viewport.isFinite, viewport > 0 else { return invalidViewportFallback }

        let portrait = !width.isFinite || width <= 0 || viewport >= width
        let fraction = portrait ? portraitFraction : landscapeFraction
        let minimum = portrait ? CGFloat(240) : CGFloat(220)
        let reserved = portrait ? CGFloat(80) : CGFloat(48)
        let target = viewport * fraction
        let maximum = max(1, viewport - reserved)
        // The max-before-min ordering keeps very short windows inside the viewport while normal iPhones
        // remain exactly 78% portrait / 58% landscape for deterministic screenshot geometry.
        return min(max(minimum, target), maximum)
    }

    /// Keep an intrinsic control inside a wrapping row. Ordinary controls retain their natural width; only a
    /// translation/Dynamic-Type label wider than the available row is proposed the row width and can tail
    /// truncate through its own one-line label policy.
    static func constrainedControlWidth(intrinsicWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard intrinsicWidth.isFinite, intrinsicWidth > 0,
              availableWidth.isFinite, availableWidth > 0 else { return 0 }
        return min(intrinsicWidth, availableWidth)
    }
}

/// The default source-card presentation is deliberately literal: add-ons own the wording, whitespace,
/// line breaks, emoji, and ordering. Filename is only a last-resort identity when both configured fields are
/// empty. Compact labels remain a separate opt-in parsed presentation in `iOSStreamLabel`.
struct IOSStreamPresentationData: Equatable {
    let title: String?
    let detail: String?

    static func make(name: String?, description: String?, filename: String?) -> Self {
        let usableName = usable(name)
        let usableDescription = usable(description)
        let usableFilename = usable(filename)
        let title = usableName ?? usableDescription ?? usableFilename
        let detail: String?
        if usableName != nil, usableDescription != usableName {
            detail = usableDescription
        } else {
            detail = nil
        }
        return Self(title: title, detail: detail)
    }

    private static func usable(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
