// Settings > Effects and performance: Auto follows Performance, explicit choices win.
// Run: scripts/test-visual-effects.sh

import Foundation

@MainActor private var failures = 0
@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@main
@MainActor
enum VisualEffectsTests {
    static func main() {
        check("auto backdrop animates on a capable device and stays still on a reduced one",
              VisualEffects.backdrop(stored: "auto", reduced: false) == .animated
                  && VisualEffects.backdrop(stored: nil, reduced: true) == .still)
        check("an explicit backdrop wins over Performance",
              VisualEffects.backdrop(stored: "off", reduced: false) == .off
                  && VisualEffects.backdrop(stored: "animated", reduced: true) == .animated)
        check("an unknown backdrop value reads as auto", VisualEffects.backdrop(stored: "sparkly", reduced: true) == .still)
        check("auto glass and motion follow Performance",
              VisualEffects.glass(stored: nil, reduced: false) && !VisualEffects.glass(stored: "auto", reduced: true)
                  && VisualEffects.motion(stored: nil, reduced: false) && !VisualEffects.motion(stored: nil, reduced: true))
        check("explicit glass and motion win",
              VisualEffects.glass(stored: "on", reduced: true) && !VisualEffects.glass(stored: "off", reduced: false)
                  && VisualEffects.motion(stored: "on", reduced: true) && !VisualEffects.motion(stored: "off", reduced: false))
        check("artwork caps at HD only when asked or reduced",
              !VisualEffects.hdArtworkOnly(stored: nil, reduced: false) && VisualEffects.hdArtworkOnly(stored: "auto", reduced: true)
                  && VisualEffects.hdArtworkOnly(stored: "hd", reduced: false) && !VisualEffects.hdArtworkOnly(stored: "full", reduced: true))
        check("auto never lightens a phone or Mac", !VisualEffects.reducedForAuto)
        if failures > 0 { print("\n\(failures) check(s) failed"); exit(1) }
        print("\nAll effects checks passed")
    }
}
