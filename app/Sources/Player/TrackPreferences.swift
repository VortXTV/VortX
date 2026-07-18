import Foundation

enum PlaybackSettings {
    enum Key {
        static let directLinksOnly = "stremiox.directLinksOnly"
        static let keepPlayingInBackground = "stremiox.keepPlayingInBackground"
        static let customMpvOptions = "stremiox.customMpvOptions"
        static let videoUpscaling = "stremiox.videoUpscaling"
    }

    /// Video upscaling / quality preset. Picks the libmpv (gpu-next / libplacebo) scaler and debanding
    /// baseline applied during player setup. Default is hardware-aware: the memory-constrained Apple TV HD
    /// (A8) gets `.performance` so a 4K stream doesn't stutter, every other device gets `.standard` (today's
    /// sharp libplacebo default). A change takes effect on the next played file — the player is recreated
    /// per session, the same lifetime as `customMpvOptions`.
    static var videoUpscaling: VideoUpscaling {
        get {
            if let raw = UserDefaults.standard.string(forKey: Key.videoUpscaling),
               let mode = VideoUpscaling(rawValue: raw) {
                // Anime4K's CNN chain is far too heavy for the memory/GPU-constrained Apple TV HD (A8):
                // it would stutter badly even if the user (or a synced profile from a Mac) had selected
                // it. Fall back to the safe per-device default there, so the constrained device never
                // actually runs Anime4K regardless of what is stored.
                if mode == .anime4k && PerformanceMode.isConstrainedDevice { return .performance }
                return mode
            }
            return PerformanceMode.isConstrainedDevice ? .performance : .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.videoUpscaling) }
    }

    /// Power-user libmpv options, supplied as a free-form "key=value per line" snippet (an mpv.conf
    /// fragment, e.g. "profile=gpu-hq", "scale=ewa_lanczossharp", "video-sync=display-resample").
    /// Applied verbatim during player setup after VortX's own baseline options, so an advanced viewer
    /// can override the defaults. Default empty (no options). A malformed line is logged and skipped;
    /// it never blocks the baseline config or crashes playback.
    static var customMpvOptions: String {
        get { UserDefaults.standard.string(forKey: Key.customMpvOptions) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.customMpvOptions) }
    }

    /// Parsed `customMpvOptions`: one (key, value) pair per non-blank, non-comment line, split on the
    /// FIRST '=' (values may themselves contain '='), with both sides trimmed. Lines without an '=' or
    /// with an empty key are dropped.
    static var parsedCustomMpvOptions: [(key: String, value: String)] {
        customMpvOptions.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, value)
        }
    }

    /// Keep audio playing (and the in-process streaming server thread alive) when the app backgrounds
    /// or the screen locks, so a stream survives a lock instead of iOS suspending the process and
    /// freezing the embedded node server (#74). Defaults to ON; turn it off to let playback pause and
    /// the app suspend, saving battery and data.
    static var keepPlayingInBackground: Bool {
        UserDefaults.standard.object(forKey: Key.keepPlayingInBackground) as? Bool ?? true
    }

    static var directLinksOnlyForced: Bool {
        #if VORTX_NO_EMBEDDED_SERVER
        true
        #else
        false
        #endif
    }

    static var directLinksOnly: Bool {
        #if VORTX_NO_EMBEDDED_SERVER
        true
        #else
        UserDefaults.standard.bool(forKey: Key.directLinksOnly)
        #endif
    }

    static var torrentsDisabled: Bool { directLinksOnly }
}

/// Video upscaling / quality preset, mapped to libmpv (gpu-next / libplacebo) scaler + debanding options.
/// Applied as a BASELINE during player setup, before the power-user `customMpvOptions` (so a custom snippet
/// still wins). `.standard` is intentionally a no-op: it keeps VortX's existing default, which is already
/// libplacebo's sharp lanczos + debanding (the app deliberately avoids mpv's `profile=fast` for that reason).
enum VideoUpscaling: String, CaseIterable {
    case performance   // weak GPU / battery: cheap bilinear scalers, debanding + dither off
    case standard      // VortX default: libplacebo's sharp lanczos + debanding (current behavior)
    case highQuality   // capable GPU (M-series Mac): ewa_lanczossharp scalers + stronger debanding
    case anime4k       // anime-tuned CNN upscale via bundled Anime4K glsl shaders (GPU-heavy)

    var label: String {
        switch self {
        case .performance: return "Performance"
        case .standard:    return "Standard"
        case .highQuality: return "High Quality"
        case .anime4k:     return "Anime4K"
        }
    }

    var detail: String {
        switch self {
        case .performance: return "Fastest. Best for Apple TV HD or to save battery."
        case .standard:    return "Sharp default with debanding. Recommended for most devices."
        case .highQuality: return "Sharper upscaling for capable GPUs (Mac). Heavier; not for weak hardware."
        case .anime4k:     return "Anime-tuned neural upscaling. Very GPU-heavy; best on Mac or a newer Apple TV. Use on animation only."
        }
    }

    /// mpv option (key, value) pairs for this preset, applied during `setupMpv`. `.standard` returns an
    /// empty list so VortX's existing baseline is left untouched. `.anime4k` returns ONLY the scaler
    /// prerequisites the Anime4K chain needs; the `glsl-shaders` paths themselves are resolved at runtime
    /// from `Bundle.main` (see MPVMetalViewController.anime4kShaderPaths), since a bundle path is not
    /// knowable at compile time.
    var mpvOptions: [(key: String, value: String)] {
        switch self {
        case .standard:
            return []
        case .performance:
            // The cheap-scaler knobs mpv's `fast` profile sets, applied explicitly so they layer onto
            // gpu-next without dragging in the rest of the legacy profile. Stops 4K stutter on the A8.
            return [
                ("scale", "bilinear"),
                ("cscale", "bilinear"),
                ("dscale", "bilinear"),
                ("deband", "no"),
                ("dither-depth", "no"),
            ]
        case .highQuality:
            // libplacebo high-quality scalers. ewa_lanczossharp is the sharp anti-ringing upscaler;
            // mitchell downscales cleanly. Heavier than the default, so it is opt-in only.
            return [
                ("scale", "ewa_lanczossharp"),
                ("cscale", "ewa_lanczossharp"),
                ("dscale", "mitchell"),
                ("deband", "yes"),
                ("deband-iterations", "2"),
                ("dither-depth", "auto"),
            ]
        case .anime4k:
            // The Anime4K CNN shaders do the upscaling themselves, so mpv's own scalers must be cheap
            // bilinear to avoid double-scaling and wasting GPU; debanding off too, the restore pass
            // handles ringing. The shader chain is added separately via glsl-shaders at runtime.
            return [
                ("scale", "bilinear"),
                ("cscale", "bilinear"),
                ("dscale", "bilinear"),
                ("deband", "no"),
            ]
        }
    }

    /// Ordered file names of the bundled Anime4K shader chain (Mode A: restore + upscale, Medium CNN
    /// variants), resolved from the app bundle's `shaders/` folder at runtime. Order is significant and
    /// must match Anime4K's published Mode A preset. Empty for every other preset. See
    /// `app/Resources/shaders/LICENSE.md` for provenance.
    var glslShaderFileNames: [String] {
        switch self {
        case .anime4k:
            // This is Anime4K's canonical "Mode A (Fast)" chain from the official low-end Mac/Linux
            // template (the Medium-variant CNN path tuned for modest GPUs), in the exact order mpv
            // requires: highlight clamp, restore, 2x upscale, the two auto-downscale guards, then a
            // final small 2x upscale to reach the target size.
            return [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        default:
            return []
        }
    }
}

/// What audio and subtitle track the player should pick automatically. Persisted in UserDefaults and
/// shared by the iOS and tvOS players; configured from tvOS Settings, with sensible defaults until then.
struct TrackPreferences: Equatable {
    /// Preferred languages in priority order, as ISO codes (e.g. ["en", "ja"]).
    var audioLanguages: [String]
    var subtitleLanguages: [String]
    /// What subtitles to show when you DID get your preferred audio language.
    var forcedPolicy: ForcedPolicy
    /// Track titles containing any of these (case-insensitive) are never auto-picked (e.g. "commentary").
    var rejectTerms: [String]

    enum ForcedPolicy: String, CaseIterable, Equatable {
        case off       // never auto-show subtitles once you have your audio language
        case forced    // only forced subtitles (foreign-dialogue captions)
        case always    // always show full subtitles in your language

        var label: String {
            switch self {
            case .off:    return "Off"
            case .forced: return "Forced only"
            case .always: return "Always on"
            }
        }
    }

    // MARK: Persistence

    enum Key {
        static let audio = "stremiox.tracks.audioLangs"
        static let subtitle = "stremiox.tracks.subLangs"
        static let forced = "stremiox.tracks.forced"
        static let reject = "stremiox.tracks.reject"
        /// Opt-in: list only add-on / community subtitles whose language is in the preferred subtitle chain.
        static let subOnlyPreferred = "stremiox.tracks.subOnlyPreferred"
    }

    /// Opt-in filter: when ON, the player's subtitle panel lists ONLY the add-on and community subtitles whose
    /// language matches the preferred subtitle languages (embedded file tracks are never hidden). Default OFF.
    /// Rides the settings-sync blob like the other `stremiox.tracks.*` keys. Read fresh on each panel build.
    static var subtitlesOnlyPreferred: Bool {
        UserDefaults.standard.bool(forKey: Key.subOnlyPreferred)
    }

    /// Curated language choices for the settings UI (id is the stored ISO code).
    static let commonLanguages: [(id: String, label: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("hi", "Hindi"), ("ja", "Japanese"),
        ("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"), ("ru", "Russian"),
        ("tr", "Turkish"), ("nl", "Dutch"), ("pl", "Polish"), ("sv", "Swedish"),
    ]

    /// The device's preferred languages as ISO codes, deduplicated, used as the default.
    static var deviceLanguages: [String] {
        var seen = Set<String>(); var out: [String] = []
        for id in Locale.preferredLanguages {
            let code = Locale(identifier: id).language.languageCode?.identifier ?? String(id.prefix(2))
            if seen.insert(code).inserted { out.append(code) }
        }
        return out.isEmpty ? ["en"] : out
    }

    /// Preferred trailer AUDIO languages (ISO-639-1 base codes, priority order) for selecting the matching audio
    /// track when a YouTube trailer ships MULTIPLE audio languages. The explicit trailer-language picker
    /// (`stremiox.trailerLanguage`) first when set, then the preferred audio languages, then the device
    /// languages. Deduped, lowercased, never empty (device languages default to ["en"]). Foundation-only so it
    /// is available in EVERY target that compiles the player (the resolver honors the richer
    /// `TMDBClient.preferredTrailerLanguages`; this is the player-side `alang` belt-and-suspenders for a file
    /// that itself exposes more than one embedded audio track).
    static var trailerAudioLanguages: [String] {
        var seen = Set<String>(); var out: [String] = []
        func add(_ raw: String?) {
            guard let raw, !raw.isEmpty else { return }
            let base = Locale(identifier: raw).language.languageCode?.identifier ?? String(raw.prefix(2))
            let code = base.lowercased()
            guard !code.isEmpty, seen.insert(code).inserted else { return }
            out.append(code)
        }
        let override = UserDefaults.standard.string(forKey: "stremiox.trailerLanguage")
        add((override?.isEmpty ?? true) ? nil : override)
        for c in current.audioLanguages { add(c) }
        for c in deviceLanguages { add(c) }
        return out.isEmpty ? ["en"] : out
    }

    /// Current preferences: device languages plus sensible defaults until the user customizes them.
    static var current: TrackPreferences {
        let d = UserDefaults.standard
        return TrackPreferences(
            audioLanguages: list(d.string(forKey: Key.audio)) ?? deviceLanguages,
            subtitleLanguages: list(d.string(forKey: Key.subtitle)) ?? deviceLanguages,
            forcedPolicy: ForcedPolicy(rawValue: d.string(forKey: Key.forced) ?? "") ?? .forced,
            rejectTerms: list(d.string(forKey: Key.reject)) ?? ["commentary", "sdh"]
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(audioLanguages.joined(separator: ","), forKey: Key.audio)
        d.set(subtitleLanguages.joined(separator: ","), forKey: Key.subtitle)
        d.set(forcedPolicy.rawValue, forKey: Key.forced)
        d.set(rejectTerms.joined(separator: ","), forKey: Key.reject)
    }

    private static func list(_ s: String?) -> [String]? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }
}
