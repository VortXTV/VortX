import SwiftUI

/// User-selectable look for the player seek bar. The GEOMETRY is identical across styles (the played
/// fraction, the knob position, and the chapter ticks all live in the player and never change); only the
/// TRACK rendering swaps, so choosing a style can never affect scrubbing or focus. Device-wide setting,
/// written by the Settings picker and read by the player at render time.
///
/// Every animated style derives its motion from a CONTINUOUS clock (`TimelineView`'s date), not a
/// repeating `.animation`, so a "Wave" actually travels and never seams. Static styles ignore the clock.
/// All motion stays inside the `Canvas` redraw (and `transform`/`opacity`/`clip`), so it is compositor
/// cheap and never animates layout.
enum SeekBarStyle: String, CaseIterable, Identifiable {
    case classic, gradient, glow, wave, heartbeat, pulse, dots, equalizer
    case minimal, neon, ribbon, comet, segments, ladder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:   return "Classic"
        case .gradient:  return "Gradient Sweep"
        case .glow:      return "Breathing Glow"
        case .wave:      return "Wave"
        case .heartbeat: return "Heartbeat"
        case .pulse:     return "Ripple"
        case .dots:      return "Beads"
        case .equalizer: return "Equalizer"
        case .minimal:   return "Minimal"
        case .neon:      return "Neon Comet"
        case .ribbon:    return "Liquid"
        case .comet:     return "Comet"
        case .segments:  return "Runner"
        case .ladder:    return "Spectrum"
        }
    }

    static let storageKey = "stremiox.player.seekBarStyle"

    /// The active style, read straight from UserDefaults so the player can pick it up off the main actor /
    /// per render without an observable. Defaults to `.classic` for older installs.
    static var current: SeekBarStyle {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SeekBarStyle.init(rawValue:)) ?? .classic
    }

    /// Static styles ignore the clock, so the player/preview can pause the per-frame redraw for them.
    var isAnimated: Bool {
        switch self {
        case .classic, .minimal: return false
        default:                 return true
        }
    }
}

/// Draws the seek-bar TRACK plus the filled (played) portion in the chosen style, filling its frame.
/// Pure visual: `progress` is the played fraction (0...1). The caller overlays the knob and chapter ticks,
/// so this view owns no interaction. The animated styles redraw every frame from a continuous clock, so the
/// motion is genuinely smooth; `animated` lets the player freeze motion while paused to save power.
struct SeekBarTrack: View {
    let style: SeekBarStyle
    let progress: Double
    var accent: Color
    var track: Color = Color.white.opacity(0.22)
    /// YouTube-style buffered-ahead fraction (0...1): how far the demuxer/AVPlayer has loaded past the
    /// playhead. Rendered as a faint grey band from the playhead to the buffered edge, above the track and
    /// below the knob. Defaults to 0 (fail-soft: no buffered info → nothing extra draws, the bar is unchanged).
    var buffered: Double = 0
    /// When false (e.g. playback paused), motion freezes; the bar still shows the played fraction.
    var animated: Bool = true

    var body: some View {
        TimelineView(.animation(paused: !(animated && style.isAnimated))) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                SeekBarRenderer.draw(style, ctx, size, t,
                                     CGFloat(min(1, max(0, progress))), accent, track,
                                     CGFloat(min(1, max(0, buffered))))
            }
        }
    }
}

// MARK: - Renderer

/// Procedural drawing for every style. Each takes the `GraphicsContext` by value (drawing is live; local
/// `var` copies carry per-style clips/filters), the size, a continuous time `t` (seconds, never resets),
/// the played fraction `p`, and the accent / track colors. Played portion = accent (bright/tall), remaining
/// = track (faint/short), so the playhead boundary always reads as progress.
private enum SeekBarRenderer {
    static func draw(_ style: SeekBarStyle, _ ctx: GraphicsContext, _ size: CGSize,
                     _ t: Double, _ p: CGFloat, _ accent: Color, _ track: Color, _ buffered: CGFloat = 0) {
        switch style {
        case .classic:   capsule(ctx, size, p, accent, track, thicknessScale: 1.0, glow: 0)
        case .minimal:   capsule(ctx, size, p, accent, track, thicknessScale: 0.4, glow: 0)
        case .glow:      breathingGlow(ctx, size, t, p, accent, track)
        case .gradient:  gradientSweep(ctx, size, t, p, accent, track)
        case .wave:      wave(ctx, size, t, p, accent, track)
        case .heartbeat: heartbeat(ctx, size, t, p, accent, track)
        case .pulse:     ripple(ctx, size, t, p, accent, track)
        case .dots:      beads(ctx, size, t, p, accent, track)
        case .equalizer: equalizer(ctx, size, t, p, accent, track)
        case .neon:      comet(ctx, size, t, p, accent, track, neon: true)
        case .comet:     comet(ctx, size, t, p, accent, track, neon: false)
        case .ribbon:    liquid(ctx, size, t, p, accent, track)
        case .segments:  runner(ctx, size, t, p, accent, track)
        case .ladder:    spectrum(ctx, size, t, p, accent, track)
        }
        // YouTube-style buffered-ahead band: a faint grey capsule from the playhead to the buffered edge.
        // Drawn LAST so it reads over every style's own track, and only the segment AHEAD of the playhead
        // (never over the played fill or knob). Fail-soft: buffered <= p (or 0) draws nothing.
        bufferedBand(ctx, size, p, buffered, track)
    }

    /// The grey loaded-but-not-yet-played hint. A thin capsule spanning (playhead → buffered edge), lighter
    /// than the unplayed track so it reads as "ready ahead" without competing with the accent played fill.
    private static func bufferedBand(_ ctx: GraphicsContext, _ size: CGSize, _ p: CGFloat,
                                     _ buffered: CGFloat, _ track: Color) {
        guard buffered > p else { return }
        let w = size.width, h = size.height
        let th = max(3, h * 0.30)
        let y = (h - th) / 2
        let startX = w * p
        let endX = w * min(1, buffered)
        let bw = max(0, endX - startX)
        guard bw > 0.5 else { return }
        ctx.fill(Path(roundedRect: CGRect(x: startX, y: y, width: bw, height: th), cornerRadius: th / 2),
                 with: .color(.white.opacity(0.42)))
    }

    // MARK: shared bits

    /// A small white playhead capsule with an accent glow, at `p`. The unambiguous progress marker that
    /// every fancy style keeps so the played/remaining split is never in doubt.
    private static func playhead(_ ctx: GraphicsContext, _ size: CGSize, _ p: CGFloat, _ accent: Color) {
        let x = size.width * p
        let r: CGFloat = 2.2
        let rect = CGRect(x: x - r, y: 2, width: r * 2, height: max(2, size.height - 4))
        var g = ctx
        g.addFilter(.blur(radius: 3))
        g.fill(Path(roundedRect: rect, cornerRadius: r), with: .color(accent.opacity(0.8)))
        ctx.fill(Path(roundedRect: rect, cornerRadius: r), with: .color(.white))
    }

    /// Centered capsule track + played fill, with an optional animated glow halo. Used by classic / minimal
    /// (glow 0) and as the base of the glow style.
    private static func capsule(_ ctx: GraphicsContext, _ size: CGSize, _ p: CGFloat,
                                _ accent: Color, _ track: Color, thicknessScale: CGFloat, glow: CGFloat) {
        let w = size.width, h = size.height
        let th = max(4, h * 0.42 * thicknessScale)
        let y = (h - th) / 2
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: th), cornerRadius: th / 2),
                 with: .color(track))
        let fw = max(0, w * p)
        let fill = Path(roundedRect: CGRect(x: 0, y: y, width: fw, height: th), cornerRadius: th / 2)
        if glow > 0 {
            var g = ctx
            g.addFilter(.blur(radius: glow))
            g.fill(fill, with: .color(accent.opacity(0.7)))
        }
        ctx.fill(fill, with: .color(accent))
    }

    // MARK: styles

    /// Breathing Glow: a plain fill whose halo swells in and out on a slow ~4s cycle. Calm, premium, alive
    /// without moving spatially.
    private static func breathingGlow(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                                      _ accent: Color, _ track: Color) {
        let breath = CGFloat(0.5 + 0.5 * sin(t * 1.6))
        capsule(ctx, size, p, accent, track, thicknessScale: 1.0, glow: 4 + 11 * breath)
        playhead(ctx, size, p, accent)
    }

    /// Traveling Sine Wave: ONE continuous wave whose phase scrolls with `t`, so it visibly flows. Played
    /// portion is re-stroked bright; remaining stays faint. This is the fix for "wavy but not moving".
    private static func wave(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                             _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height, mid = h / 2
        let phase = t * 3.4
        let wavelength = Double(max(26, w / 12))
        let k = 2 * Double.pi / wavelength
        var curve = Path()
        curve.move(to: CGPoint(x: 0, y: mid))
        var x: CGFloat = 0
        while x <= w {
            let y = mid - CGFloat(sin(Double(x) * k + phase)) * (h * 0.30)
            curve.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        ctx.stroke(curve, with: .color(track), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        var c = ctx
        c.clip(to: Path(CGRect(x: 0, y: 0, width: w * p, height: h)))
        c.stroke(curve, with: .color(accent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        playhead(ctx, size, p, accent)
    }

    /// Heartbeat: a hospital-monitor sweep cursor travels left to right drawing a QRS spike, over a two-tone
    /// baseline. The playhead tick stays separate so progress never gets confused with the sweep.
    private static func heartbeat(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                                  _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height, mid = h / 2, amp = h * 0.40
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: w, y: mid)) },
                   with: .color(track), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        var c = ctx
        c.clip(to: Path(CGRect(x: 0, y: 0, width: w * p, height: h)))
        c.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: w * p, y: mid)) },
                 with: .color(accent.opacity(0.5)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        let sx = CGFloat((t * 0.45).truncatingRemainder(dividingBy: 1)) * w
        var spike = Path()
        spike.move(to: CGPoint(x: max(0, sx - 42), y: mid))
        for (dx, dy): (CGFloat, CGFloat) in [(-18, 0), (-10, amp * 0.2), (-4, -amp), (2, amp * 0.5), (8, 0), (42, 0)] {
            spike.addLine(to: CGPoint(x: sx + dx, y: mid + dy))
        }
        ctx.stroke(spike, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: sx - 3, y: mid - 3, width: 6, height: 6)), with: .color(.white))
        playhead(ctx, size, p, accent)
    }

    /// Ripple: concentric rings emanate from the playhead, like a drop landing at the current position.
    private static func ripple(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                               _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height, mid = h / 2
        let th = max(4, h * 0.34), y = (h - th) / 2
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: th), cornerRadius: th / 2), with: .color(track))
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: max(0, w * p), height: th), cornerRadius: th / 2), with: .color(accent))
        let cx = w * p, maxR = h * 1.7, rings = 3
        for kk in 0..<rings {
            let frac = CGFloat((t * 0.8 + Double(kk) / Double(rings)).truncatingRemainder(dividingBy: 1))
            let r = frac * maxR
            let rect = CGRect(x: cx - r, y: mid - r * 0.5, width: r * 2, height: r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(accent.opacity(Double((1 - frac) * 0.6))), lineWidth: 2)
        }
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 3.5, y: mid - 3.5, width: 7, height: 7)), with: .color(.white))
    }

    /// Beads: a row of dots, played side solid accent, with a brightening "wet edge" of larger beads that
    /// runs through the played region.
    private static func beads(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                              _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height, mid = h / 2
        let count = max(8, Int(w / 16))
        let spacing = w / CGFloat(count)
        let r = min(h, spacing) * 0.24
        let hx = CGFloat((t * 0.5).truncatingRemainder(dividingBy: 1)) * max(1, w * p)
        for i in 0..<count {
            let cx = spacing * (CGFloat(i) + 0.5)
            let played = cx <= w * p
            let boost = played ? max(0, 1 - abs(cx - hx) / 36) : 0
            let rad = r * (played ? (1.0 + 0.5 * boost) : 0.7)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - rad, y: mid - rad, width: rad * 2, height: rad * 2)),
                     with: .color(played ? accent : track))
        }
    }

    /// Equalizer: VU bars that bounce, each with its own frequency/phase so neighbours move out of sync.
    /// Played side lively + accent, remaining short + faint.
    private static func equalizer(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                                  _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height
        let count = max(10, Int(w / 12))
        let spacing = w / CGFloat(count)
        let bw = spacing * 0.5
        for i in 0..<count {
            let cx = spacing * (CGFloat(i) + 0.5)
            let played = cx <= w * p
            let freq = 3.0 + Double(i % 5) * 0.8
            let phase = Double(i) * 0.9
            let base: CGFloat = played ? 0.35 : 0.18
            let amp: CGFloat = played ? 0.55 : 0.12
            let bh = h * (base + amp * CGFloat(0.5 + 0.5 * sin(t * freq + phase)))
            let rect = CGRect(x: cx - bw / 2, y: (h - bh) / 2, width: bw, height: bh)
            ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: .color(played ? accent : track))
        }
    }

    /// Comet (and Neon, a louder variant): a two-tone track with a glowing head at the playhead that leaves
    /// a fading trail of ghost dots and breathes a little, so it feels alive even when paused mid-scrub.
    private static func comet(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                              _ accent: Color, _ track: Color, neon: Bool) {
        let w = size.width, h = size.height, mid = h / 2
        let th = neon ? max(5, h * 0.4) : max(4, h * 0.28), y = (h - th) / 2
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: th), cornerRadius: th / 2), with: .color(track))
        let headX = w * p
        let played = Path(roundedRect: CGRect(x: 0, y: y, width: headX, height: th), cornerRadius: th / 2)
        if neon {
            var g = ctx
            g.addFilter(.blur(radius: 10))
            g.fill(played, with: .color(accent.opacity(0.6)))
        }
        ctx.fill(played, with: .color(accent))
        let n = 6
        for kk in 0..<n {
            let frac = CGFloat(kk) / CGFloat(n)
            let x = headX - frac * 36
            guard x > 0 else { continue }
            let r = (1 - frac) * (h * 0.22)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: mid - r, width: r * 2, height: r * 2)),
                     with: .color(accent.opacity(Double((1 - frac) * 0.5))))
        }
        let pulse = CGFloat(0.85 + 0.15 * sin(t * 4))
        let hr = h * 0.32 * pulse
        var g2 = ctx
        g2.addFilter(.blur(radius: neon ? 8 : 5))
        g2.fill(Path(ellipseIn: CGRect(x: headX - hr, y: mid - hr, width: hr * 2, height: hr * 2)),
                with: .color(accent.opacity(0.85)))
        ctx.fill(Path(ellipseIn: CGRect(x: headX - hr * 0.6, y: mid - hr * 0.6, width: hr * 1.2, height: hr * 1.2)),
                 with: .color(.white.opacity(0.95)))
    }

    /// Gradient Sweep: a gradient fill with a bright sheen of light that sweeps across the played region and
    /// wraps, like a shine passing over glass.
    private static func gradientSweep(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                                      _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height
        let th = max(5, h * 0.42), y = (h - th) / 2
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: th), cornerRadius: th / 2), with: .color(track))
        let fw = max(0.1, w * p)
        var c = ctx
        c.clip(to: Path(roundedRect: CGRect(x: 0, y: y, width: fw, height: th), cornerRadius: th / 2))
        c.fill(Path(CGRect(x: 0, y: y, width: fw, height: th)),
               with: .linearGradient(Gradient(colors: [accent.opacity(0.65), accent]),
                                     startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: fw, y: 0)))
        let band = Double(fw) + 70
        let cx = CGFloat((t * 130).truncatingRemainder(dividingBy: band))
        let sheen = Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                     .init(color: .white.opacity(0.5), location: 0.5),
                                     .init(color: .white.opacity(0), location: 1)])
        c.fill(Path(CGRect(x: cx - 45, y: y, width: 90, height: th)),
               with: .linearGradient(sheen, startPoint: CGPoint(x: cx - 45, y: 0), endPoint: CGPoint(x: cx + 45, y: 0)))
        playhead(ctx, size, p, accent)
    }

    /// Liquid: a thick vessel filled to the playhead, with a wavy, sloshing surface from two summed sines.
    private static func liquid(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                               _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height
        let th = max(8, h * 0.72), top = (h - th) / 2
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: top, width: w, height: th), cornerRadius: th / 2), with: .color(track))
        let fw = max(0.1, w * p)
        var c = ctx
        c.clip(to: Path(roundedRect: CGRect(x: 0, y: top, width: fw, height: th), cornerRadius: th / 2))
        var path = Path()
        let baseY = top + th * 0.2
        path.move(to: CGPoint(x: 0, y: top + th))
        var x: CGFloat = 0
        while x <= fw {
            let y = baseY + CGFloat(sin(Double(x) * 0.05 + t * 2.2)) * 2.6 + CGFloat(sin(Double(x) * 0.12 - t * 1.6)) * 1.8
            path.addLine(to: CGPoint(x: x, y: y))
            x += 3
        }
        path.addLine(to: CGPoint(x: fw, y: top + th))
        path.closeSubpath()
        c.fill(path, with: .linearGradient(Gradient(colors: [accent, accent.opacity(0.7)]),
                                           startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + th)))
        playhead(ctx, size, p, accent)
    }

    /// Runner: contiguous lit segments with a glowing highlight that chases along inside the played region,
    /// like a runway. The lit-vs-unlit count reads as an almost-numeric progress meter.
    private static func runner(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                               _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height
        let count = max(12, Int(w / 20))
        let spacing = w / CGFloat(count)
        let bw = spacing * 0.7, bh = max(5, h * 0.42), y = (h - bh) / 2
        let hx = CGFloat((t * 0.6).truncatingRemainder(dividingBy: 1)) * max(1, w * p)
        for i in 0..<count {
            let cx = spacing * (CGFloat(i) + 0.5)
            let played = cx <= w * p
            let rect = CGRect(x: cx - bw / 2, y: y, width: bw, height: bh)
            let boost = played ? max(0, 1 - abs(cx - hx) / 40) : 0
            if boost > 0 {
                var g = ctx
                g.addFilter(.blur(radius: 6))
                g.fill(Path(roundedRect: rect, cornerRadius: bh / 2), with: .color(accent.opacity(Double(boost))))
            }
            ctx.fill(Path(roundedRect: rect, cornerRadius: bh / 2), with: .color(played ? accent : track))
        }
    }

    /// Spectrum: thin symmetric ticks about the center line, each gently breathing/scrolling, played side
    /// tall + accent. The most "media-native" look.
    private static func spectrum(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ p: CGFloat,
                                 _ accent: Color, _ track: Color) {
        let w = size.width, h = size.height, mid = h / 2
        let count = max(16, Int(w / 10))
        let spacing = w / CGFloat(count)
        let tw = max(1.5, spacing * 0.3)
        for i in 0..<count {
            let cx = spacing * (CGFloat(i) + 0.5)
            let played = cx <= w * p
            let env: CGFloat = played ? 0.92 : 0.4
            let mod = CGFloat(0.7 + 0.3 * sin(t * 4 + Double(i) * 0.5))
            let th = h * env * mod
            let rect = CGRect(x: cx - tw / 2, y: mid - th / 2, width: tw, height: th)
            ctx.fill(Path(roundedRect: rect, cornerRadius: tw / 2), with: .color(played ? accent : track))
        }
    }
}

/// Settings list of the seek-bar styles, each with a LIVE animated preview at a fixed fraction and a
/// selection check. Shared by the tvOS and iOS Settings screens. Writes the device-wide choice the player
/// reads via `SeekBarStyle.current`.
struct SeekBarStylePicker: View {
    @AppStorage(SeekBarStyle.storageKey) private var raw = SeekBarStyle.classic.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Seek bar style")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Pick how the scrubber looks during playback. Each preview animates the real design.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                ForEach(SeekBarStyle.allCases) { style in
                    Button { raw = style.rawValue } label: { row(style) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    @ViewBuilder
    private func row(_ style: SeekBarStyle) -> some View {
        let selected = raw == style.rawValue
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 10) {
                Text(style.displayName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                SeekBarTrack(style: style, progress: 0.45, accent: Theme.Palette.accent)
                    .frame(height: 24)
                    .frame(maxWidth: 420)
            }
            Spacer(minLength: Theme.Space.sm)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24))
                .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
