import Foundation

struct MPVProperty {
    static let videoParamsColormatrix = "video-params/colormatrix"
    static let videoParamsColorlevels = "video-params/colorlevels"
    static let videoParamsPrimaries = "video-params/primaries"
    static let videoParamsGamma = "video-params/gamma"
    static let videoParamsSigPeak = "video-params/sig-peak"
    static let videoParamsSceneMaxR = "video-params/scene-max-r"
    static let videoParamsSceneMaxG = "video-params/scene-max-g"
    static let videoParamsSceneMaxB = "video-params/scene-max-b"
    static let pause = "pause"
    static let pausedForCache = "paused-for-cache"
    static let timePos = "time-pos"
    static let duration = "duration"
    /// Whether the current stream can be seeked within. A VOD becomes seekable once playback starts;
    /// a true live feed stays non-seekable. PlayerScreen uses this for runtime live-detection so a live
    /// stream whose meta type isn't in `LiveTypes` still gets live treatment (no resume/progress/mark-watched).
    static let seekable = "seekable"
    /// Absolute timestamp (seconds from the start) the demuxer cache has loaded up to, i.e. the
    /// buffered-ahead edge. Maps directly onto the scrubber for the YouTube-style grey buffered track.
    /// On the AVPlayer path the engine emits the same key computed from `loadedTimeRanges`.
    static let demuxerCacheTime = "demuxer-cache-time"
    static let trackList = "track-list"
    static let aid = "aid"
    static let sid = "sid"
    /// Secondary subtitle stream id (dual-subtitle / language-study feature). libmpv renders this track
    /// simultaneously with the primary `sid`, pinned to the top of the frame via `secondarySubPos` so the
    /// two languages never overlap. "no" = no secondary track.
    static let secondarySid = "secondary-sid"
    /// On-screen position of the secondary subtitle line, 0 (top) ... 100 (bottom). Set to 0 so the
    /// secondary language sits at the top while the primary stays at its normal bottom position.
    static let secondarySubPos = "secondary-sub-pos"
    static let speed = "speed"
    /// Synthetic signal (not a real mpv property): emitted when a file fails to load
    /// (MPV_EVENT_END_FILE with reason=error). Data is the mpv error string.
    static let endFileError = "stremiox-end-file-error"
    /// Synthetic signal: emitted when a file reaches its natural end (EOF), drives auto-play-next.
    static let endFileEof = "stremiox-end-file-eof"
}
