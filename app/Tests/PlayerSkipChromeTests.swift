import Foundation

@main
enum PlayerSkipChromeTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
        }
        for visible in [false, true] {
            check(PlayerSkipChromePolicy.showsPrompt(controlsVisible: visible, sharesChrome: true),
                  "Mac manual Skip survives pointer chrome reveal")
            check(PlayerSkipChromePolicy.showsPrompt(controlsVisible: visible, sharesChrome: false) == !visible,
                  "Touch prompt visibility unchanged")
        }
        for height in [0.0, 160, 280, 420] {
            check(PlayerSkipChromePolicy.bottomPadding(controlsVisible: true, sharesChrome: true,
                                                       chromeHeight: height) == max(40, height + 12),
                  "Mac prompt clears actual timeline, editor and toolbar height")
            check(PlayerSkipChromePolicy.bottomPadding(controlsVisible: false, sharesChrome: true,
                                                       chromeHeight: height) == 40,
                  "Hidden chrome returns Skip to watching position")
            check(PlayerSkipChromePolicy.bottomPadding(controlsVisible: true, sharesChrome: false,
                                                       chromeHeight: height) == 40,
                  "Touch layout unchanged")
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            check(PlayerSkipChromePolicy.bottomPadding(controlsVisible: true, sharesChrome: true,
                                                       chromeHeight: invalid) == 40,
                  "Invalid measurement does not corrupt layout")
        }
        print("PASS PlayerSkipChromePolicy: \(checks) checks")
    }
}
