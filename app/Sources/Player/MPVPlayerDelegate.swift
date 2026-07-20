import Foundation

@MainActor
protocol MPVPlayerDelegate: AnyObject {
    /// A player property changed (an mpv property name, or a synthetic key like the end-file events).
    /// Every callback carries the opaque logical load that produced it. The shared Coordinator compares
    /// that token with its currently mounted engine, so callbacks from a replaced or dismantled engine
    /// fail closed even after the Coordinator's weak player reference points at another controller.
    func propertyChange(propertyName: String, data: Any?, loadToken: PlayerLoadToken)
}
