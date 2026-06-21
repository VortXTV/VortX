import SwiftUI

/// User-selectable look for the player seek bar. The GEOMETRY is identical across styles (the played
/// fraction, the knob position, the chapter ticks all live in the player and never change); only the
/// TRACK rendering swaps, so choosing a style can never affect scrubbing or focus. Device-wide setting,
/// written by the Settings picker and read by the player at render time.
enum SeekBarStyle: String, CaseIterable, Identifiable {
    case classic, gradient, glow, wave, heartbeat, pulse, dots, equalizer
    case minimal, neon, ribbon, comet, segments, ladder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:   return "Classic"
        case .gradient:  return "Gradient"
        case .glow:      return "Glow"
        case .wave:      return "Wave"
        case .heartbeat: return "Heartbeat"
        case .pulse:     return "Pulse"
        case .dots:      return "Dots"
        case .equalizer: return "Equalizer"
        case .minimal:   return "Minimal"
        case .neon:      return "Neon"
        case .ribbon:    return "Ribbon"
        case .comet:     return "Comet"
        case .segments:  return "Segments"
        case .ladder:    return "Ladder"
        }
    }

    static let storageKey = "stremiox.player.seekBarStyle"

    /// The active style, read straight from UserDefaults so the player can pick it up off the main
    /// actor / per render without an observable. Defaults to `.classic` for older installs.
    static var current: SeekBarStyle {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SeekBarStyle.init(rawValue:)) ?? .classic
    }
}

/// Draws the seek-bar TRACK plus the filled (played) portion in the chosen style, filling its frame.
/// Pure visual: `progress` is the played fraction (0...1). The caller overlays the knob and chapter
/// ticks, so this view owns no interaction. Fancy line styles want a little vertical room; thin capsule
/// styles center themselves, so the same frame height works for all of them.
struct SeekBarTrack: View {
    let style: SeekBarStyle
    let progress: Double
    var accent: Color
    var track: Color = Color.white.opacity(0.22)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let p = CGFloat(min(1, max(0, progress)))
            switch style {
            case .classic:   capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(accent), glow: false, knob: false)
            case .gradient:  capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.65), accent], startPoint: .leading, endPoint: .trailing)), glow: false, knob: false)
            case .glow:      capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(accent), glow: true, knob: false)
            case .pulse:     capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(accent), glow: true, knob: true)
            case .wave:      lineStyle(w: w, h: h, p: p, path: wavePath)
            case .heartbeat: lineStyle(w: w, h: h, p: p, path: heartbeatPath)
            case .dots:      dots(w: w, h: h, p: p)
            case .equalizer: equalizer(w: w, h: h, p: p)
            // A thin hairline track — the most restrained look (no glow, no knob).
            case .minimal:   capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(accent), glow: false, knob: false, thicknessScale: 0.45)
            // Gradient fill with a strong double-glow and a bright head — the loudest look.
            case .neon:      capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.5), accent], startPoint: .leading, endPoint: .trailing)), glow: true, knob: true, thicknessScale: 1.0)
            // A thick rounded ribbon, gradient-filled, no knob.
            case .ribbon:    capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.7), accent], startPoint: .leading, endPoint: .trailing)), glow: false, knob: false, thicknessScale: 1.6)
            // Accent fill with a glowing comet head riding the playhead.
            case .comet:     capsuleBar(w: w, h: h, p: p, fill: AnyShapeStyle(accent), glow: true, knob: true, thicknessScale: 0.7)
            // Filled rounded blocks across the bar, lit up to the playhead.
            case .segments:  segments(w: w, h: h, p: p)
            // Vertical tick marks, like a ruler, lit up to the playhead.
            case .ladder:    ladder(w: w, h: h, p: p)
            }
        }
    }

    private func thickness(_ h: CGFloat) -> CGFloat { max(6, h * 0.42) }

    /// Classic / gradient / glow / pulse: a centered capsule track + filled capsule, optional glow and
    /// a soft pulse dot at the playhead.
    @ViewBuilder
    private func capsuleBar(w: CGFloat, h: CGFloat, p: CGFloat, fill: AnyShapeStyle, glow: Bool, knob: Bool, thicknessScale: CGFloat = 1) -> some View {
        let t = thickness(h) * thicknessScale * (knob ? 1.15 : 1)
        ZStack(alignment: .leading) {
            Capsule().fill(track).frame(height: t)
            Capsule().fill(fill).frame(width: max(0, w * p), height: t)
                .shadow(color: glow ? accent.opacity(0.85) : .clear, radius: glow ? 8 : 0)
                .shadow(color: glow ? accent.opacity(0.45) : .clear, radius: glow ? 16 : 0)
            if knob {
                Circle().fill(accent).frame(width: t * 1.9, height: t * 1.9)
                    .shadow(color: accent.opacity(0.7), radius: 8)
                    .offset(x: max(0, w * p - t * 0.95))
            }
        }
        .frame(width: w, height: h, alignment: .leading)
    }

    /// Wave / heartbeat: stroke the full line faint, then re-stroke only the played portion in the accent
    /// by clipping to the filled rect.
    private func lineStyle(w: CGFloat, h: CGFloat, p: CGFloat, path: @escaping (CGSize) -> Path) -> some View {
        Canvas { ctx, size in
            let line = path(size)
            let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            ctx.stroke(line, with: .color(track), style: stroke)
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * p, height: size.height)))
            ctx.stroke(line, with: .color(accent), style: stroke)
        }
    }

    private func wavePath(_ size: CGSize) -> Path {
        var path = Path()
        let mid = size.height / 2
        let amp = size.height * 0.32
        let wavelength = max(22, size.width / 14)
        path.move(to: CGPoint(x: 0, y: mid))
        var x: CGFloat = 0
        while x <= size.width {
            let y = mid - sin(x / wavelength * 2 * .pi) * amp
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        return path
    }

    private func heartbeatPath(_ size: CGSize) -> Path {
        var path = Path()
        let mid = size.height / 2
        let amp = size.height * 0.42
        let period = max(46, size.width / 7)
        path.move(to: CGPoint(x: 0, y: mid))
        var x: CGFloat = 0
        while x <= size.width {
            let local = x.truncatingRemainder(dividingBy: period)
            let spikeStart = period * 0.6
            let y: CGFloat
            if local < spikeStart {
                y = mid                                  // flat baseline
            } else {
                let t = (local - spikeStart) / (period - spikeStart)
                switch t {
                case ..<0.2: y = mid + amp * 0.25        // small dip
                case ..<0.4: y = mid - amp               // tall peak (R)
                case ..<0.6: y = mid + amp * 0.55        // trough (S)
                default:     y = mid                     // recovery
                }
            }
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        return path
    }

    private func dots(w: CGFloat, h: CGFloat, p: CGFloat) -> some View {
        let count = max(8, Int(w / 16))
        let spacing = w / CGFloat(count)
        let r = min(h, spacing) * 0.26
        return Canvas { ctx, size in
            for i in 0..<count {
                let cx = spacing * (CGFloat(i) + 0.5)
                let filled = cx <= size.width * p
                let rect = CGRect(x: cx - r, y: size.height / 2 - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(filled ? accent : track))
            }
        }
    }

    /// Segments: contiguous rounded blocks across the bar, lit accent up to the playhead.
    private func segments(w: CGFloat, h: CGFloat, p: CGFloat) -> some View {
        let count = max(12, Int(w / 20))
        let spacing = w / CGFloat(count)
        let bw = spacing * 0.72
        let bh = thickness(h)
        return Canvas { ctx, size in
            for i in 0..<count {
                let cx = spacing * (CGFloat(i) + 0.5)
                let filled = cx <= size.width * p
                let rect = CGRect(x: cx - bw / 2, y: (size.height - bh) / 2, width: bw, height: bh)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bh / 2), with: .color(filled ? accent : track))
            }
        }
    }

    /// Ladder: thin vertical tick marks like a ruler, lit accent up to the playhead.
    private func ladder(w: CGFloat, h: CGFloat, p: CGFloat) -> some View {
        let count = max(16, Int(w / 10))
        let spacing = w / CGFloat(count)
        let tw = max(1.5, spacing * 0.22)
        return Canvas { ctx, size in
            for i in 0..<count {
                let cx = spacing * (CGFloat(i) + 0.5)
                let filled = cx <= size.width * p
                let th = size.height * (i % 4 == 0 ? 0.95 : 0.55)   // taller every 4th tick
                let rect = CGRect(x: cx - tw / 2, y: (size.height - th) / 2, width: tw, height: th)
                ctx.fill(Path(roundedRect: rect, cornerRadius: tw / 2), with: .color(filled ? accent : track))
            }
        }
    }

    private func equalizer(w: CGFloat, h: CGFloat, p: CGFloat) -> some View {
        let count = max(10, Int(w / 12))
        let spacing = w / CGFloat(count)
        let bw = spacing * 0.5
        return Canvas { ctx, size in
            for i in 0..<count {
                let cx = spacing * (CGFloat(i) + 0.5)
                let frac = 0.35 + 0.6 * abs(sin(Double(i) * 1.3))   // deterministic varied heights
                let bh = size.height * CGFloat(frac)
                let filled = cx <= size.width * p
                let rect = CGRect(x: cx - bw / 2, y: (size.height - bh) / 2, width: bw, height: bh)
                ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: .color(filled ? accent : track))
            }
        }
    }
}

/// Settings list of the eight seek-bar styles, each with a live preview at a fixed fraction and a
/// selection check. Shared by the tvOS and iOS Settings screens. Writes the device-wide choice the
/// player reads via `SeekBarStyle.current`.
struct SeekBarStylePicker: View {
    @AppStorage(SeekBarStyle.storageKey) private var raw = SeekBarStyle.classic.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Seek bar style")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Pick how the scrubber looks during playback. The preview shows each design.")
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
                    .frame(height: 22)
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
