import Foundation

/// Proactive read-liveness rules for the remux INPUT (Beta 26 workstream B5, phase 1).
///
/// The input reads through ffmpeg's own HTTP client, whose `rw_timeout` is ten seconds: a debrid CDN
/// that goes quiet mid-stream parks `av_read_frame` for that long before the reconnect machinery even
/// notices, and the diag F2 cascade (producer quiet 14s -> AVPlayer retire -> mpv reopens the same
/// frozen URL) starts in exactly that dead air. The producer thread cannot fire anything while it is
/// blocked inside libav, so a one-second watchdog samples the interrupt cell's monotonic
/// `inputBytesRead` high-water mark and, once delivery has been FLAT for the fire threshold while the
/// read loop is live, raises the cell's `softInterrupt`. The F1 interrupt callback returns it, libav
/// aborts the parked read within milliseconds, and the existing reconnect flags plus bounded retry
/// ladder re-establish the connection: the same recovery path a natural rw_timeout expiry takes,
/// reached in five seconds instead of ten-plus.
///
/// Deliberately conservative on every axis:
///  - Only the read loop arms the watchdog (`readLoopActive`). The cold/warm OPEN phase legitimately
///    sits silent far longer (the documented cold-debrid shape is "first open times out at 10s, the
///    warm retry connects"), and the `openInFlight` receipt already protects it.
///  - Flat BYTES are required, not merely a slow read: a healthy high-bitrate source moves the counter
///    every sample even when individual packets arrive slowly, so it is never kicked.
///  - One soft kick per flat episode. If the upstream stays dead through the resulting reconnect
///    attempt, bytes stay flat, the episode re-arms after another window, and the producer's existing
///    four-retry bound still terminates a genuinely dead link exactly as before.
enum VortXRemuxReadLivenessPolicy {
    static let pollIntervalSeconds: Double = 1
    /// Flat-delivery duration that fires one soft interrupt. Below ffmpeg's 10s rw_timeout with margin
    /// for the reconnect handshake; above any plausible inter-packet gap on a live CDN.
    static let flatDeliveryFireSeconds: Double = 5

    /// Whether the watchdog should raise the soft-interrupt flag NOW. `bytesRead` is the cell's
    /// high-water mark sampled this tick; `watchedBytes` / `blockedSinceUptime` are the caller's
    /// running observation. Returns the updated observation so the caller stays stateless.
    static func sample(
        bytesRead: Int64,
        readLoopActive: Bool,
        cancelled: Bool,
        watchedBytes: Int64,
        blockedSinceUptime: Double?,
        nowUptime: Double
    ) -> (fire: Bool, watchedBytes: Int64, blockedSinceUptime: Double?) {
        guard readLoopActive, !cancelled else {
            return (false, bytesRead, nil)
        }
        var since = blockedSinceUptime
        var watched = watchedBytes
        if bytesRead != watched {
            // Delivery moved (or the counter was reset by a fresh mount): the line is alive again.
            watched = bytesRead
            since = nowUptime
            return (false, watched, since)
        }
        guard let start = since else {
            // First flat sample of an episode: start the clock instead of firing on it.
            return (false, watched, nowUptime)
        }
        let flatSeconds = nowUptime - start
        let fire = flatSeconds >= flatDeliveryFireSeconds
        return (fire, watched, since)
    }
}