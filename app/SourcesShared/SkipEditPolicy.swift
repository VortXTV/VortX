import Foundation

/// Pure, engine-agnostic decisions for the in-player skip-segment editor (the "contribute a skip time"
/// affordance). Kept Foundation-only, exactly like `RemuxResumePolicy`, so a standalone harness can call
/// the REAL functions rather than asserting on source text.
///
/// # Why this exists (the AVPlayer / Dolby-Vision lane)
///
/// The skip editor must be offered on EVERY playback engine (libmpv AND the AVFoundation / Dolby-Vision
/// remux lane): contribution is never gated to one engine. The single property that decides visibility is
/// CONTENT liveness (a live-TV / IPTV feed has no fixed episode timeline to submit a skip against), NOT the
/// player's reported duration or seekability.
///
/// A Dolby-Vision remux presents to AVPlayer as a growing HLS: the item duration can read INDEFINITE and the
/// item can report non-seekable for a while, even though it is a VOD file with a known runtime. Deciding
/// visibility on the player's duration/seekability would therefore WRONGLY hide the editor across the whole
/// AVPlayer/DV lane. Deciding it on content liveness keeps the editor correct on both engines. This type is
/// the one place both chromes ask, so the property is explicit, permanent, and unit-tested.
enum SkipEditPolicy {

    /// IMDb `tt#######` shape. The skip worker keys off `imdb:S:E`, so only an IMDb id has something to
    /// submit against; add-on / Kitsu / tmdb ids are excluded (there is nothing to key on).
    static func isSubmittableContentId(_ contentId: String) -> Bool {
        contentId.range(of: #"^tt\d{7,8}$"#, options: .regularExpression) != nil
    }

    /// Whether to OFFER the skip editor for the current title.
    ///
    /// - Parameter isLiveContent: the app's CONTENT-liveness flag (the meta type is live-TV / IPTV / events),
    ///   the same flag that drives resume/progress suppression. Deliberately NOT the player's
    ///   duration/seekability: a DV-remux VOD reports indefinite/non-seekable yet must show the editor.
    /// - Parameter contentId: the playing title's library id; must be an IMDb `tt` id to have a submit key.
    static func canEdit(isLiveContent: Bool, contentId: String) -> Bool {
        guard !isLiveContent else { return false }
        return isSubmittableContentId(contentId)
    }

    /// The `duration_ms` to attach to a submission.
    ///
    /// The chrome's `duration` (SOURCE seconds, already mapped through the remux timeline origin by
    /// `RemuxResumePolicy.reportedDuration`) is authoritative when finite and positive. In the INDEFINITE
    /// edge (a remux whose demuxer never yielded a source duration, so the chrome sits at 0), fall back to
    /// the title's SYNTHESIZED runtime, the meta / Cinemeta runtime the chrome already resolves for
    /// provisional trickplay, so the worker can still range-validate the segment. When neither is known,
    /// return `nil` (the worker accepts a null duration and bounds the span itself).
    static func submissionDurationMs(playerDurationSeconds: Double,
                                     fallbackRuntimeSeconds: Double?) -> Int? {
        if playerDurationSeconds.isFinite, playerDurationSeconds > 0 {
            return Int((playerDurationSeconds * 1000).rounded())
        }
        if let runtime = fallbackRuntimeSeconds, runtime.isFinite, runtime > 0 {
            return Int((runtime * 1000).rounded())
        }
        return nil
    }

    /// A values-free, typed diagnostic line for the editor-visibility decision. Carries only booleans plus
    /// the engine tag, never a content id or a time, so it is safe for the always-on diagnostics sink.
    static func visibilityDiagnostic(canEdit: Bool, isLiveContent: Bool,
                                     hasSubmittableId: Bool, engine: String) -> String {
        "editor visibility: canEdit=\(canEdit) liveContent=\(isLiveContent) hasTT=\(hasSubmittableId) engine=\(engine)"
    }
}
