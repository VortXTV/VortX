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
    static let trackList = "track-list"
    static let aid = "aid"
    static let sid = "sid"
    static let speed = "speed"
    /// Synthetic signal (not a real mpv property): emitted when a file fails to load
    /// (MPV_EVENT_END_FILE with reason=error). Data is the mpv error string.
    static let endFileError = "stremiox-end-file-error"
    /// Synthetic signal: emitted when a file reaches its natural end (EOF), drives auto-play-next.
    static let endFileEof = "stremiox-end-file-eof"
}
