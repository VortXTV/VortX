import SwiftUI

/// One score as the rating service's mark beside its value ("[IMDb] 8.6", "[tomato] 96%"). Metacritic is its
/// own colour-coded square with the number inside, the way Metacritic prints it. Shared by the card plate,
/// the detail row and the episode cards so every surface draws a score the same way.
struct RatingScore: View {
    let token: RatingsFormat.Token
    /// Point size of the value; the mark is sized from it so the pair reads as one unit.
    var textSize: CGFloat = 10

    private var markHeight: CGFloat { (textSize * 1.15).rounded() }

    var body: some View {
        if token.kind == .metacritic {
            MetascoreSquare(value: token.value, score: token.score, height: markHeight)
        } else {
            HStack(spacing: (textSize * 0.32).rounded()) {
                RatingLogo(kind: token.kind, score: token.score, height: markHeight)
                Text(token.value)
                    .font(.system(size: (textSize * 1.08).rounded(), weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize()
            }
        }
    }
}

/// The rating services' marks, drawn in code from their shapes and colours: crisp at any size with no image
/// assets, from a phone tile to a 4K TV. Rotten Tomatoes and the Popcornmeter turn green below 60, as the
/// services show them.
struct RatingLogo: View {
    let kind: RatingsFormat.Token.Kind
    var score: Double = 100
    let height: CGFloat

    var body: some View {
        switch kind {
        case .imdb:
            wordmark("IMDb", fill: RatingMarkColors.imdbYellow, ink: .black, aspect: 2.0, corner: 0.2, scale: 0.66)
        case .tmdb:
            wordmark("TMDB", fill: LinearGradient(colors: [RatingMarkColors.tmdbGreen, RatingMarkColors.tmdbBlue],
                                                  startPoint: .leading, endPoint: .trailing),
                     ink: RatingMarkColors.tmdbNavy, aspect: 2.3, corner: 0.5, scale: 0.58)
        case .myAnimeList:
            wordmark("MAL", fill: RatingMarkColors.malBlue, ink: .white, aspect: 1.9, corner: 0.2, scale: 0.62)
        case .kitsu:
            wordmark("KITSU", fill: RatingMarkColors.kitsuCoral, ink: .white, aspect: 2.5, corner: 0.2, scale: 0.52)
        case .simkl:
            wordmark("SIMKL", fill: RatingMarkColors.simklInk, ink: .white, aspect: 2.5, corner: 0.2, scale: 0.52)
                .overlay {
                    RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: max(1, height * 0.06))
                }
        case .metacritic:
            MetascoreSquare(value: "", score: score, height: height)
        case .rottenTomatoes:
            Canvas { context, size in
                if score >= 60 { RatingMarkPaths.tomato(in: context, size: size) }
                else { RatingMarkPaths.splat(in: context, size: size) }
            }
            .frame(width: height, height: height)
        case .popcorn:
            Canvas { context, size in RatingMarkPaths.popcorn(in: context, size: size, fresh: score >= 60) }
                .frame(width: height, height: height)
        case .letterboxd:
            Canvas { context, size in RatingMarkPaths.letterboxd(in: context, size: size) }
                .frame(width: height * 1.55, height: height)
        case .trakt:
            Canvas { context, size in RatingMarkPaths.trakt(in: context, size: size) }
                .frame(width: height, height: height)
        }
    }

    private func wordmark(_ text: String, fill: some ShapeStyle, ink: Color, aspect: CGFloat, corner: CGFloat,
                          scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height * corner, style: .continuous)
            .fill(fill)
            .frame(width: height * aspect, height: height)
            .overlay {
                Text(text)
                    .font(.system(size: height * scale, weight: .black))
                    .tracking(-height * 0.02)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, height * 0.12)
            }
    }
}

/// Metacritic's score square: green from 61, yellow from 40, red below, with the number inside.
struct MetascoreSquare: View {
    let value: String
    let score: Double
    let height: CGFloat

    var body: some View {
        Text(value)
            .font(.system(size: (height * 0.66).rounded(), weight: .heavy).monospacedDigit())
            .foregroundStyle(Color(white: 0.06))
            .padding(.horizontal, height * 0.2)
            .frame(minWidth: height * 1.2, minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: height * 0.22, style: .continuous).fill(color))
            .fixedSize()
    }

    private var color: Color {
        if score >= 61 { return RatingMarkColors.metacriticGreen }
        if score >= 40 { return RatingMarkColors.metacriticYellow }
        return RatingMarkColors.metacriticRed
    }
}

enum RatingMarkColors {
    static let imdbYellow = Color(.sRGB, red: 0.961, green: 0.773, blue: 0.094)
    static let tmdbGreen = Color(.sRGB, red: 0.565, green: 0.808, blue: 0.631)
    static let tmdbBlue = Color(.sRGB, red: 0.004, green: 0.706, blue: 0.894)
    static let tmdbNavy = Color(.sRGB, red: 0.051, green: 0.145, blue: 0.247)
    static let malBlue = Color(.sRGB, red: 0.180, green: 0.318, blue: 0.635)
    static let kitsuCoral = Color(.sRGB, red: 0.969, green: 0.322, blue: 0.224)
    static let simklInk = Color(.sRGB, red: 0.043, green: 0.059, blue: 0.063)
    static let tomatoRed = Color(.sRGB, red: 0.980, green: 0.196, blue: 0.039)
    static let tomatoLeaf = Color(.sRGB, red: 0.0, green: 0.569, blue: 0.176)
    static let rottenGreen = Color(.sRGB, red: 0.039, green: 0.784, blue: 0.333)
    static let popcornCream = Color(.sRGB, red: 1.0, green: 0.953, blue: 0.82)
    static let letterboxdOrange = Color(.sRGB, red: 1.0, green: 0.502, blue: 0.0)
    static let letterboxdGreen = Color(.sRGB, red: 0.0, green: 0.878, blue: 0.329)
    static let letterboxdBlue = Color(.sRGB, red: 0.251, green: 0.737, blue: 0.957)
    static let traktRed = Color(.sRGB, red: 0.929, green: 0.110, blue: 0.141)
    static let metacriticGreen = Color(.sRGB, red: 0.0, green: 0.808, blue: 0.478)
    static let metacriticYellow = Color(.sRGB, red: 1.0, green: 0.741, blue: 0.247)
    static let metacriticRed = Color(.sRGB, red: 1.0, green: 0.408, blue: 0.455)
}

/// The drawn marks, in unit coordinates scaled to the canvas so one path serves every size.
enum RatingMarkPaths {
    static func tomato(in context: GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        context.fill(Path(ellipseIn: CGRect(x: w * 0.04, y: h * 0.2, width: w * 0.92, height: h * 0.78)),
                     with: .color(RatingMarkColors.tomatoRed))
        context.fill(Path(ellipseIn: CGRect(x: w * 0.2, y: h * 0.32, width: w * 0.22, height: h * 0.16)),
                     with: .color(.white.opacity(0.28)))
        context.fill(star(center: CGPoint(x: w * 0.5, y: h * 0.22), outer: w * 0.26, inner: w * 0.1, points: 5),
                     with: .color(RatingMarkColors.tomatoLeaf))
    }

    static func splat(in context: GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        // Uneven lobes with deep notches between them, then two flung droplets: a splat, not a star.
        let radii: [CGFloat] = [0.47, 0.25, 0.41, 0.23, 0.45, 0.27, 0.37, 0.22, 0.43, 0.24, 0.39, 0.23, 0.46, 0.26]
        func point(_ index: Int, scale: CGFloat = 1) -> CGPoint {
            let angle = Double(index) / Double(radii.count) * 2 * .pi - .pi / 2 + 0.2
            let radius = radii[index % radii.count] * scale
            return CGPoint(x: w * 0.5 + cos(angle) * w * radius, y: h * 0.52 + sin(angle) * w * radius)
        }
        // Even indices are lobe tips, odd ones the notches: each lobe bulges from notch to notch past its tip.
        var path = Path()
        path.move(to: point(radii.count - 1))
        for tip in stride(from: 0, to: radii.count, by: 2) {
            path.addQuadCurve(to: point(tip + 1), control: point(tip, scale: 1.25))
        }
        path.closeSubpath()
        context.fill(path, with: .color(RatingMarkColors.rottenGreen))
        for (x, y, d) in [(0.9, 0.18, 0.12), (0.1, 0.86, 0.1)] as [(CGFloat, CGFloat, CGFloat)] {
            context.fill(Path(ellipseIn: CGRect(x: w * (x - d / 2), y: h * (y - d / 2), width: w * d, height: h * d)),
                         with: .color(RatingMarkColors.rottenGreen))
        }
    }

    static func popcorn(in context: GraphicsContext, size: CGSize, fresh: Bool) {
        let w = size.width, h = size.height
        let kernels: [(CGFloat, CGFloat)] = fresh ? [(0.3, 0.34), (0.5, 0.26), (0.7, 0.34), (0.4, 0.18), (0.6, 0.18)]
                                                  : [(0.36, 0.34), (0.62, 0.32)]
        for (x, y) in kernels {
            context.fill(Path(ellipseIn: CGRect(x: w * (x - 0.15), y: h * (y - 0.13), width: w * 0.3, height: h * 0.27)),
                         with: .color(RatingMarkColors.popcornCream))
        }
        var bucket = Path()
        bucket.move(to: CGPoint(x: w * 0.14, y: h * 0.4))
        bucket.addLine(to: CGPoint(x: w * 0.86, y: h * 0.4))
        bucket.addLine(to: CGPoint(x: w * 0.72, y: h * 0.98))
        bucket.addLine(to: CGPoint(x: w * 0.28, y: h * 0.98))
        bucket.closeSubpath()
        context.fill(bucket, with: .color(fresh ? RatingMarkColors.tomatoRed : RatingMarkColors.rottenGreen))
        var stripes = context
        stripes.clip(to: bucket)
        // Two white stripes that taper with the bucket (0.72 wide at the rim, 0.44 at the base).
        for top in [0.38, 0.62] as [CGFloat] {
            let bottom = 0.5 + (top - 0.5) * 0.44 / 0.72
            var stripe = Path()
            stripe.move(to: CGPoint(x: w * (top - 0.05), y: h * 0.4))
            stripe.addLine(to: CGPoint(x: w * (top + 0.05), y: h * 0.4))
            stripe.addLine(to: CGPoint(x: w * (bottom + 0.035), y: h))
            stripe.addLine(to: CGPoint(x: w * (bottom - 0.035), y: h))
            stripe.closeSubpath()
            stripes.fill(stripe, with: .color(.white))
        }
    }

    static func letterboxd(in context: GraphicsContext, size: CGSize) {
        let h = size.height, d = h * 0.66
        let colors = [RatingMarkColors.letterboxdOrange, RatingMarkColors.letterboxdBlue, RatingMarkColors.letterboxdGreen]
        let centers: [CGFloat] = [h * 0.34, h * 1.21, h * 0.775]
        for (center, color) in zip(centers, colors) {
            context.fill(Path(ellipseIn: CGRect(x: center - d / 2, y: (h - d) / 2, width: d, height: d)), with: .color(color))
        }
    }

    static func trakt(in context: GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(RatingMarkColors.traktRed))
        context.stroke(Path(ellipseIn: CGRect(x: w * 0.17, y: h * 0.17, width: w * 0.66, height: h * 0.66)),
                       with: .color(.white), lineWidth: w * 0.08)
        var check = Path()
        check.move(to: CGPoint(x: w * 0.36, y: h * 0.5))
        check.addLine(to: CGPoint(x: w * 0.47, y: h * 0.61))
        check.addLine(to: CGPoint(x: w * 0.67, y: h * 0.38))
        context.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: w * 0.09, lineCap: .round, lineJoin: .round))
    }

    private static func star(center: CGPoint, outer: CGFloat, inner: CGFloat, points: Int) -> Path {
        var path = Path()
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = Double(index) / Double(points * 2) * 2 * .pi - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
