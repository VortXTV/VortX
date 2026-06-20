import Foundation

@MainActor
public protocol MPVPlayerDelegate: AnyObject {
    /// A player property changed (an mpv property name, or a synthetic key like the end-file events).
    /// The engine that changed is the delegate's own `player` reference, so it is not re-passed here;
    /// keeping this engine-agnostic lets an AVFoundation engine drive the same chrome through the same
    /// Coordinator (it just sets `coordinator.player` to itself and calls this).
    func propertyChange(propertyName: String, data: Any?)
}
