import MediaPlayer

/// Drives the system Now Playing surface (iOS Lock Screen + Control Center, the Mac menu bar) and routes
/// its remote controls back into the player. Background audio is already enabled, so when the screen locks
/// the stream keeps playing; this makes it show the title and respond to the play/pause/skip controls.
/// Set the commands once when playback starts, refresh the info each progress tick, clear on close.
enum NowPlayingCenter {
    /// Refresh the title, elapsed time, duration, and play rate shown on the Lock Screen / Control Center.
    static func update(title: String, elapsed: Double, duration: Double, paused: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Wire the hardware / Lock Screen transport buttons to the player. `seek` takes a signed delta.
    static func wireCommands(togglePause: @escaping () -> Void,
                             seek: @escaping (Double) -> Void,
                             stepSeconds: Double) {
        let c = MPRemoteCommandCenter.shared()
        for cmd in [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand] {
            cmd.removeTarget(nil)
            cmd.isEnabled = true
            cmd.addTarget { _ in togglePause(); return .success }
        }
        let step = [NSNumber(value: stepSeconds)]
        c.skipForwardCommand.preferredIntervals = step
        c.skipForwardCommand.removeTarget(nil)
        c.skipForwardCommand.isEnabled = true
        c.skipForwardCommand.addTarget { _ in seek(stepSeconds); return .success }
        c.skipBackwardCommand.preferredIntervals = step
        c.skipBackwardCommand.removeTarget(nil)
        c.skipBackwardCommand.isEnabled = true
        c.skipBackwardCommand.addTarget { _ in seek(-stepSeconds); return .success }
    }

    /// Tear down the Now Playing info and command targets when the player closes.
    static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
         c.skipForwardCommand, c.skipBackwardCommand].forEach { $0.removeTarget(nil) }
    }
}
