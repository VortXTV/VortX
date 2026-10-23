import SwiftUI
import AppKit

// Renders the production GlassEpisodeCard and TitleExtraCard offscreen with stand-in art and checks their
// geometry: the still keeps its own 16:9 at the card width, and every card variant keeps one width.
// Run: scripts/test-glass-episode-card.sh (writes PNGs next to the binary for a visual check).
@main @MainActor enum GlassEpisodeCardRenderTests {
    static func art(_ hue: Double) -> AnyView {
        AnyView(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                        Color(hue: hue + 0.08, saturation: 0.7, brightness: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    static func render<V: View>(_ view: V, _ name: String, into dir: URL) -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            fatalError("render failed: \(name)")
        }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
        return image.size
    }

    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
        var checks = 0
        func check(_ ok: Bool, _ label: String) { precondition(ok, label); checks += 1 }

        let watched = GlassEpisodeCard.Model(number: 2, title: "Goodbye, Mrs. Selvig",
            overview: "Mark and the team scramble to find answers while Cobel tightens her watch over the floor.",
            runtime: "55 min", aired: "Jan 24, 2025", isWatched: true,
            scores: MDBListRatings(imdb: 8.9, rottenTomatoes: nil, metacritic: nil, tmdb: 89, trakt: 88), topRated: true)
        let upNext = GlassEpisodeCard.Model(number: 3, title: "Who Is Alive?",
            overview: "Helly faces the consequences of her escape attempt as the innies learn what happened outside.",
            runtime: "52 min", aired: "Jan 31, 2025", isUpNext: true, progress: 0.38, remaining: "21m left",
            scores: MDBListRatings(imdb: 8.5, rottenTomatoes: nil, metacritic: nil, tmdb: 81, trakt: 79))
        let veiled = GlassEpisodeCard.Model(number: 4, title: "Woe's Hollow", overview: nil, spoilerHint: "Tap to reveal")

        let phone = HStack(alignment: .top, spacing: 14) {
            GlassEpisodeCard(model: watched, width: 300, artwork: art(0.08))
            GlassEpisodeCard(model: upNext, width: 300, artwork: art(0.55))
            GlassEpisodeCard(model: veiled, width: 300, artwork: art(0.75))
        }
        .padding(20).background(Color(white: 0.06))
        let phoneSize = render(phone, "phone-cards", into: dir)
        check(phoneSize.width == 300 * 3 + 14 * 2 + 40, "phone cards keep their width: \(phoneSize)")

        let tv = HStack(alignment: .top, spacing: 32) {
            GlassEpisodeCard(model: watched, width: 426, artwork: art(0.08), tenFoot: true)
            GlassEpisodeCard(model: upNext, width: 426, artwork: art(0.55), tenFoot: true)
        }
        .padding(30).background(Color(white: 0.06))
        let tvSize = render(tv, "tv-cards", into: dir)
        check(tvSize.width == 426 * 2 + 32 + 60, "Apple TV cards keep their width: \(tvSize)")

        let heights = [watched, upNext, veiled].enumerated().map { index, model in
            render(GlassEpisodeCard(model: model, width: 300, artwork: art(0.3)), "height-\(index)", into: dir).height
        }
        check(Set(heights).count == 1, "every card is the same height, synopsis or not: \(heights)")
        let single = render(GlassEpisodeCard(model: upNext, width: 300, artwork: art(0.55)), "single", into: dir)
        check(single.height > 300 * 9 / 16 + 90, "the panel sits below the 16:9 still: \(single)")

        let extra = TitleExtraCard(video: .init(key: "abc", name: "Season 2 Official Trailer", kind: "Trailer",
                                                official: true, language: "en", published: nil),
                                   width: 290, artwork: art(0.6))
        let extraSize = render(extra.padding(20).background(Color(white: 0.06)), "extra", into: dir)
        check(extraSize.width == 290 + 40, "the extras card keeps its width: \(extraSize)")

        // The episode plate (IMDb + TMDB + Trakt) fits beside the Up next chip on a phone card, so no score drops.
        let episodeTokens = RatingsFormat.tokens(upNext.scores!)
        let plate = render(RatingBadgePlate(tokens: episodeTokens, textSize: 11), "episode-plate", into: dir)
        let upNextChip = render(GlassChip(text: "Up next", prominent: true), "up-next-chip", into: dir)
        let compactWatched = render(GlassChip(text: "", systemImage: "checkmark"), "watched-compact", into: dir)
        check(plate.width + compactWatched.width + 8 + 20 <= 300, "episode scores fit beside the Watched check at 300pt")
        check(plate.width + upNextChip.width + 8 + 20 <= 300, "episode scores fit beside Up next at 300pt: \(plate) + \(upNextChip)")

        // Every provider, in priority order, with short marks for badges and full labels for the detail row.
        let all = MDBListRatings(imdb: 8.7, rottenTomatoes: 93, metacritic: 92, tmdb: 85,
                                 rtAudience: 97, letterboxd: 4.5, trakt: 86, mal: 8.6, simkl: 8.4, kitsu: 84)
        let tokens = RatingsFormat.tokens(all)
        check(tokens.map(\.kind) == [.imdb, .rottenTomatoes, .metacritic, .tmdb, .myAnimeList, .kitsu, .popcorn,
                                      .letterboxd, .trakt, .simkl], "service order")
        check(tokens.map(\.label) == ["IMDb", "Rotten Tomatoes", "Metacritic", "TMDB", "MyAnimeList", "Kitsu",
                                       "Popcornmeter", "Letterboxd", "Trakt", "SIMKL"], "spoken names")
        check(tokens.map(\.value) == ["8.7", "93%", "92", "85%", "8.6", "84%", "97%", "4.5", "86%", "8.4"], "values")
        check(RatingsFormat.scaled(88, max: 5) == 4.4 && RatingsFormat.scaled(4.4, max: 5) == 4.4
              && RatingsFormat.scaled(0, max: 10) == nil, "small-scale scores normalize")
        check(RatingsFormat.joined(MDBListRatings(imdb: nil, rottenTomatoes: nil, metacritic: nil, tmdb: nil)) == nil,
              "no scores, no row")
        // How many title scores a landscape card carries at common widths (phone tile, Mac tile, Apple TV card).
        for (width, text) in [(170.0, 10.0), (240.0, 10.0), (420.0, 15.0)] as [(CGFloat, CGFloat)] {
            let widths = (1...tokens.count).map { count in
                render(RatingBadgePlate(tokens: Array(tokens.prefix(count)), textSize: text),
                       "title-plate-\(Int(width))-\(count)", into: dir).width
            }
            let fits = widths.lastIndex { $0 <= width - 12 }.map { $0 + 1 } ?? 0
            check(fits >= 2, "a \(Int(width))pt card shows at least IMDb + one more (\(fits))")
            print("  \(Int(width))pt card fits \(fits) of \(tokens.count) scores")
        }
        // Every service mark, fresh and rotten, on art at the phone, episode and TV sizes (for a visual check).
        let rotten = MDBListRatings(imdb: 5.9, rottenTomatoes: 42, metacritic: 38, tmdb: 61,
                                    rtAudience: 35, letterboxd: 2.6, trakt: 58, mal: 6.1, simkl: 6.0, kitsu: 61)
        let mixed = MDBListRatings(imdb: 7.1, rottenTomatoes: 64, metacritic: 55, tmdb: 70)
        let showcase = VStack(alignment: .leading, spacing: 18) {
            ForEach([10.0, 11.0, 15.0] as [CGFloat], id: \.self) { size in
                RatingBadgePlate(tokens: RatingsFormat.tokens(all), textSize: size)
                RatingBadgePlate(tokens: RatingsFormat.tokens(rotten), textSize: size)
                RatingBadgePlate(tokens: RatingsFormat.tokens(mixed), textSize: size)
            }
        }
        .padding(24)
        .background(art(0.05))
        let showcaseSize = render(showcase, "rating-marks", into: dir)
        check(showcaseSize.width > 300, "the mark showcase renders: \(showcaseSize)")
        check(EpisodeAirDate.short("2025-01-31T08:00:00.000Z") != nil, "ISO air dates format")
        check(EpisodeAirDate.short("soon") == nil && EpisodeAirDate.short(nil) == nil, "unknown air dates are left out")
        print("GlassEpisodeCardRenderTests: \(checks) checks passed; PNGs in \(dir.path)")
    }
}
