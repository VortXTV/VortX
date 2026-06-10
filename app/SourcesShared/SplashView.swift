import SwiftUI

/// Animated launch splash: the brand pinwheel X swings in over indigo, the dot
/// pops, the wordmark fades up, then the whole thing clears. It covers the
/// engine and embedded-server boot moment, and honors Reduce Motion with a
/// static beat instead of movement.
struct SplashView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var barsIn = false
    @State private var dotIn = false
    @State private var nameIn = false
    @State private var fadingOut = false

    // The brand palette (docs/brand, reconstructed in scripts/make-logo.py).
    private static let indigo = Color(red: 26 / 255, green: 15 / 255, blue: 58 / 255)
    private static let violetLight = Color(red: 109 / 255, green: 54 / 255, blue: 243 / 255)
    private static let violetDark = Color(red: 83 / 255, green: 39 / 255, blue: 188 / 255)

    var body: some View {
        ZStack {
            Self.indigo.ignoresSafeArea()

            VStack(spacing: 48) {
                mark
                HStack(spacing: 0) {
                    Text("Stremio")
                        .foregroundStyle(Color(red: 236 / 255, green: 234 / 255, blue: 244 / 255))
                    Text("X")
                        .foregroundStyle(Self.violetLight)
                }
                .font(.system(size: 64, weight: .bold))
                .opacity(nameIn ? 1 : 0)
                .offset(y: nameIn || reduceMotion ? 0 : 14)
            }
        }
        .opacity(fadingOut ? 0 : 1)
        .onAppear(perform: run)
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.violetDark)
                .frame(width: 250, height: 56)
                .rotationEffect(.degrees(45))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.violetLight)
                .frame(width: 250, height: 56)
                .rotationEffect(.degrees(-45))
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .scaleEffect(dotIn ? 1 : 0.01)
        }
        .frame(width: 220, height: 220)
        .scaleEffect(barsIn ? 1 : (reduceMotion ? 1 : 0.6))
        .opacity(barsIn ? 1 : 0)
        .rotationEffect(.degrees(barsIn || reduceMotion ? 0 : -30))
    }

    private func run() {
        if reduceMotion {
            barsIn = true; dotIn = true; nameIn = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { finish() }
            return
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { barsIn = true }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.35)) { dotIn = true }
        withAnimation(.easeOut(duration: 0.4).delay(0.5)) { nameIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { finish() }
    }

    private func finish() {
        withAnimation(.easeIn(duration: 0.3)) { fadingOut = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { onFinished() }
    }
}
