import Foundation

enum PlaybackPreparationStateTests {
    static func run() {
        var preparation = PlaybackPreparationState()
        precondition(!preparation.isActive)
        let automatic = preparation.begin()
        precondition(preparation.owner == automatic && preparation.isActive)
        preparation.cancel()
        let manual = preparation.begin()
        precondition(manual != automatic)
        preparation.finish(automatic)
        precondition(preparation.owner == manual && preparation.isActive,
                     "Canceled automatic cleanup must not release newer manual preparation")
        preparation.finish(UUID())
        precondition(preparation.owner == manual)
        preparation.finish(manual)
        precondition(!preparation.isActive)
        preparation.finish(automatic)
        precondition(!preparation.isActive)
        let replacement = preparation.begin()
        preparation.finish(manual)
        precondition(preparation.owner == replacement)
        preparation.cancel()
        precondition(!preparation.isActive)
        print("PlaybackPreparationStateTests PASS (actual attempt-owned preparation)")
    }
}
