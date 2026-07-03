import Foundation

/// Curated per-version highlights. These are the concise "what changed" bullets for the current marketing
/// version; a release cut updates `highlights` and `version` (HARD rule, kept in sync with CHANGELOG.md).
/// The in-app "What's New" screen (Settings > What's New) renders the full bundled CHANGELOG.md and only falls
/// back to these highlights when that resource is absent. Pure logic so it compiles on every target.
enum WhatsNew {
    static let version = "0.3.9"
    static let highlights: [String] = [
        "A cleaner, more cinematic look: full-bleed artwork, a bold new Play button, and a more spacious, premium layout across the app. On Mac the design now uses the full width of the window, with a larger hero and a roomier reading column instead of a stretched phone layout.",
        "Dolby Vision now plays from Dolby Vision MKV files, with true DV passthrough (turn it on in Settings). When a file can't do true DV (unsupported profile or audio), playback now falls back to HDR10 automatically instead of erroring, and the engine never switches mid-movie.",
        "Community subtitles that load fast and stay in sync, plus an \"also available in\" language row on every title.",
        "Add-on subtitles reliably appear in the player's subtitle panel again, including on streams that never report a duration.",
        "Continue Watching resumes faster and more reliably, straight from your debrid account.",
        "Install add-ons by scanning a QR code with your phone, no typing on the TV.",
        "Titles, posters, and logos now show in your language across every catalog, with a region picker and per-category Discover controls in Settings.",
        "Resume timestamps, poster style options, a working subtitle-sync control, and cached-source lightning.",
        "Detail-page polish: a tap-to-expand Cast & Crew section, a \"More Like This\" row that follows your poster style, a poster-labels toggle right in Settings, and an option to combine Discover and Search into one tab.",
        "The player scrubber now shows how much has buffered ahead, with a light grey track behind the playhead, just like YouTube.",
        "Trending, genre and streaming-service tiles now open straight to full details, ratings, artwork and playable sources on iPhone, iPad and Mac, and catalogs keep showing posters and art even when the source is busy.",
        "More reliable downloads, and on Apple TV the \"also available in\" row now shows full language names instead of codes.",
        "The full-trailer button now works on every Apple TV, including the no-server Lite build, and a new Trailer language option in Settings picks trailers in your preferred language.",
        "Offline HLS downloads on iPhone and iPad: adaptive streams now download properly for watching offline, and switching between catalog categories no longer sticks on a loading spinner.",
        "The muted trailer that plays behind the hero on Home and detail pages is now the real full trailer, played quietly and looping, the same source as the Trailer button. When a title has no trailer, the still artwork stays as before.",
        "The Streaming Services tiles now show each service's real brand logo, built into the app, so Netflix, Prime Video, Disney+, Max, Apple TV+ and more appear instantly and cleanly instead of a stretched icon or a single letter.",
        "Scrub-preview thumbnails now build and share from every title you watch, including everything opened from the Streaming Services, Trending and genre collections. Previously those plays were skipped, so timeline previews stayed empty; now every watch makes scrubbing better for everyone.",
        "Trailers now play straight from your own device at up to 1080p, resolved on the spot instead of routed through a server, so they start faster and look sharper. The ambient trailer behind the hero uses the same path.",
        "Cached sources start faster: when a source that looks cached is not actually ready on your account, the player now moves on in a couple of seconds instead of waiting out a long timeout, so you reach a source that plays much sooner.",
        "Pause and cancel now keep working on a download even after you fully quit and reopen the app: an in-progress download that kept running in the background is picked back up on launch, so its Pause and Cancel controls act on the real transfer again instead of doing nothing.",
        "Watch Now reaches a playable cached source much faster: it now checks the top few cached sources at once and plays the first one that is really ready on your account, instead of trying them one at a time. Picking a specific source yourself still plays exactly that one.",
    ]
}
