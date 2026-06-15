import SwiftUI

/// One curved ribbon of the VortX vortex-X. Two of these crossed (one mirrored) make the
/// swirl that ties the mark to the name. Coordinates are the exact curve from the brand
/// banner (docs/vortx-banner.svg), normalised to the view's rect so it scales cleanly and
/// supports `.trim` for a draw-in animation.
struct VortexRibbon: Shape {
    var mirrored: Bool
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: fx * w, y: fy * h) }
        var p = Path()
        if mirrored {
            p.move(to: pt(0.900, 0.057))
            p.addCurve(to: pt(0.114, 0.943), control1: pt(0.571, 0.300), control2: pt(0.443, 0.700))
        } else {
            p.move(to: pt(0.114, 0.057))
            p.addCurve(to: pt(0.900, 0.943), control1: pt(0.443, 0.300), control2: pt(0.571, 0.700))
        }
        return p
    }
}

/// The VortX mark: two gold vortex ribbons + a cream center "eye". `trim` draws the ribbons
/// in (0...1) for the launch animation; `dotScale` pops the eye.
struct VortexMark: View {
    var size: CGFloat
    var trim: CGFloat = 1
    var dotScale: CGFloat = 1

    static let gold = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x06 / 255)
    static let goldBright = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
    static let goldDeep = Color(red: 0x92 / 255, green: 0x40 / 255, blue: 0x0E / 255)
    static let cream = Color(red: 0xFD / 255, green: 0xF6 / 255, blue: 0xE3 / 255)

    // Colors default to the fixed VortX brand gold (splash + icon = the brand moment). The in-app
    // wordmark overrides these with the live Theme.Palette accent, so the mark follows the chosen
    // theme exactly like the old letter "X" did.
    var primary: Color = VortexMark.gold
    var bright: Color = VortexMark.goldBright
    var deep: Color = VortexMark.goldDeep
    var dot: Color = VortexMark.cream

    var body: some View {
        ZStack {
            VortexRibbon(mirrored: false)
                .trim(from: 0, to: trim)
                .stroke(LinearGradient(colors: [bright, primary, deep],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: size * 0.214, lineCap: .round))
            VortexRibbon(mirrored: true)
                .trim(from: 0, to: trim)
                .stroke(bright,
                        style: StrokeStyle(lineWidth: size * 0.214, lineCap: .round))
            Circle()
                .fill(dot)
                .frame(width: size * 0.16, height: size * 0.16)
                .scaleEffect(dotScale)
        }
        .frame(width: size, height: size)
    }
}

/// The in-app brand lockup: the word "Vort" in the serif wordmark face followed by the gold
/// vortex mark as the "X", so the brand reads the same inside the app as on the splash and icon.
/// `fontSize` drives both the text and the mark so it scales together at every call site.
struct VortXWordmark: View {
    var fontSize: CGFloat = 38
    var body: some View {
        HStack(spacing: fontSize * 0.03) {
            Text("Vort")
                .font(.system(size: fontSize, weight: .bold, design: .serif))
                .foregroundStyle(Theme.Palette.textPrimary)
            // The in-app mark follows the live theme accent (flat, like the old letter "X"),
            // so it recolors with the chosen theme. Splash + icon keep the fixed brand gold.
            VortexMark(size: fontSize * 0.88,
                       primary: Theme.Palette.accent, bright: Theme.Palette.accent,
                       deep: Theme.Palette.accent, dot: Theme.Palette.textPrimary)
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("VortX")
    }
}

/// Animated launch splash: the VortX vortex mark draws in with a wind-up spin and an ember
/// shockwave, the eye pops, and the "Everything. VortXed." line rises. It covers the engine and
/// embedded-server boot moment, and honors Reduce Motion with a static beat instead of movement.
///
/// Colors are the fixed VortX brand palette (gold on obsidian), NOT Theme.Palette: this is the
/// brand moment, so it reads as VortX regardless of the accent the viewer has chosen.
struct SplashView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowIn = false
    @State private var ribbonTrim: CGFloat = 0
    @State private var dotIn = false
    @State private var ringOut = false
    @State private var markIn = false
    @State private var taglineIn = false
    @State private var fadingOut = false

    private static let canvas = Color(red: 0x0F / 255, green: 0x0D / 255, blue: 0x0A / 255)
    private static let ember = Color(red: 0xC2 / 255, green: 0x44 / 255, blue: 0x0F / 255)
    private static let cream = VortexMark.cream
    private static let gold = VortexMark.goldBright

    /// "Everything. VortXed." with VortX in gold, the rest cream. AttributedString (not Text `+`,
    /// which is deprecated on macOS 26) so it colors inline and still wraps.
    private static var tagline: AttributedString {
        var everything = AttributedString("Everything. "); everything.foregroundColor = cream
        var vortx = AttributedString("VortX"); vortx.foregroundColor = gold
        var ed = AttributedString("ed."); ed.foregroundColor = cream
        return everything + vortx + ed
    }

    var body: some View {
        ZStack {
            Self.canvas.ignoresSafeArea()

            VStack(spacing: 40) {
                mark
                Text(Self.tagline)
                    .font(.system(size: 46, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                    .opacity(taglineIn ? 1 : 0)
                    .offset(y: taglineIn || reduceMotion ? 0 : 16)
            }
        }
        .opacity(fadingOut ? 0 : 1)
        .onAppear(perform: run)
    }

    private var mark: some View {
        ZStack {
            RadialGradient(colors: [Self.ember.opacity(0.55), Self.ember.opacity(0)],
                           center: .center, startRadius: 4, endRadius: 150)
                .frame(width: 320, height: 320)
                .scaleEffect(glowIn ? 1 : 0.6)
                .opacity(glowIn ? 1 : 0)

            Circle()
                .stroke(VortexMark.gold.opacity(0.7), lineWidth: 3)
                .frame(width: 150, height: 150)
                .scaleEffect(ringOut ? 1.7 : 0.4)
                .opacity(ringOut ? 0 : 0.7)

            VortexMark(size: 200, trim: ribbonTrim, dotScale: dotIn ? 1 : 0.01)
        }
        .frame(width: 220, height: 220)
        // Premium focus-in, no spin: the mark resolves from a soft blur and settles in scale
        // (ease-out-expo) while the ribbons draw themselves along the curve, reading as the vortex
        // forming and coming into focus rather than two bars whirling in.
        .blur(radius: markIn || reduceMotion ? 0 : 16)
        .scaleEffect(markIn ? 1 : (reduceMotion ? 1 : 0.86))
        .opacity(markIn ? 1 : 0)
    }

    private func run() {
        if reduceMotion {
            glowIn = true; ribbonTrim = 1; dotIn = true; ringOut = true; markIn = true; taglineIn = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { finish() }
            return
        }
        // Ease-out-expo: a fast, confident start that glides to a long, graceful rest, the premium feel.
        let expo = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 1.1)
        withAnimation(.easeOut(duration: 0.9)) { glowIn = true }              // ember bloom
        withAnimation(expo) { markIn = true }                                 // blur -> sharp + scale settle + fade
        withAnimation(.easeInOut(duration: 1.05)) { ribbonTrim = 1 }          // ribbons draw along the curve
        withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.85)) { dotIn = true }  // eye pops
        withAnimation(.easeOut(duration: 0.85).delay(0.9)) { ringOut = true } // single shockwave bloom
        withAnimation(.easeOut(duration: 0.55).delay(1.3)) { taglineIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { finish() }
    }

    private func finish() {
        withAnimation(.easeIn(duration: 0.35)) { fadingOut = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.37) { onFinished() }
    }
}
