import Foundation

/// Navigation only: category changes never write a preference or create another SettingsView.
enum TVSettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case account, playback, downloads, sources, audioSubtitles, appearance, advanced, backupAbout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return String(localized: "Profiles & Account")
        case .playback: return String(localized: "Playback")
        case .downloads: return String(localized: "Downloads & Alerts")
        case .sources: return String(localized: "Sources & Server")
        case .audioSubtitles: return String(localized: "Audio & Subtitles")
        case .appearance: return String(localized: "Appearance & Navigation")
        case .advanced: return String(localized: "Advanced & Diagnostics")
        case .backupAbout: return String(localized: "Backup & About")
        }
    }

    var summary: String {
        switch self {
        case .account: return String(localized: "Profiles, sign-in, integrations and Stremio sync")
        case .playback: return String(localized: "Player, video, skipping and autoplay")
        case .downloads: return String(localized: "Download storage and new-episode alerts")
        case .sources: return String(localized: "Source filters, community and streaming server")
        case .audioSubtitles: return String(localized: "Track languages and subtitle style")
        case .appearance: return String(localized: "Theme, Home, display and visible tabs")
        case .advanced: return String(localized: "mpv options, logging and diagnostic export")
        case .backupAbout: return String(localized: "Backup, restore, version and updates")
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.2"
        case .playback: return "play.rectangle"
        case .downloads: return "tray.and.arrow.down"
        case .sources: return "server.rack"
        case .audioSubtitles: return "captions.bubble"
        case .appearance: return "paintbrush"
        case .advanced: return "slider.horizontal.3"
        case .backupAbout: return "externaldrive"
        }
    }

    /// An ordered partition: every real section belongs to exactly one category.
    var sections: [SettingsSearchSection] {
        switch self {
        case .account: return [.profiles, .account, .stremioMirror]
        case .playback: return [.playback]
        case .downloads: return [.downloads, .notifications]
        case .sources: return [.streams, .community, .server]
        case .audioSubtitles: return [.audioSubtitle, .subtitle]
        case .appearance: return [.tabBar, .appearance]
        case .advanced: return [.advanced]
        case .backupAbout: return [.backup, .about]
        }
    }
}

/// The existing Apple TV Settings inventory and search terms, shared by navigation and global search.
/// Keywords remain lowercased; matching preserves the existing case-insensitive substring behavior.
enum SettingsSearchSection: CaseIterable, Hashable {
    case profiles, account, stremioMirror, playback, downloads, notifications, streams, community,
         server, tabBar, appearance, audioSubtitle, subtitle, advanced, backup, about

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func matchingSections(for query: String) -> [Self] {
        let normalized = normalizedQuery(query)
        guard !normalized.isEmpty else { return allCases }
        return allCases.filter { section in
            section.title.lowercased().contains(normalized) ||
                section.keywords.contains { $0.contains(normalized) }
        }
    }

    var title: String {
        switch self {
        case .profiles: return "Profiles"
        case .account: return "Account"
        case .stremioMirror: return "Stremio mirror"
        case .playback: return "Playback"
        case .downloads: return "Downloads"
        case .notifications: return "Notifications"
        case .streams: return "Streams"
        case .community: return "Community"
        case .server: return "Streaming Server"
        case .tabBar: return "Tab Bar"
        case .appearance: return "Appearance"
        case .audioSubtitle: return "Audio & Subtitles"
        case .subtitle: return "Subtitle Style"
        case .advanced: return "Advanced (mpv options)"
        case .backup: return "Backup & Restore"
        case .about: return "About"
        }
    }

    var keywords: [String] {
        switch self {
        case .profiles: return ["profile", "avatar", "pin", "switch profile", "add profile"]
        case .account: return ["vortx account", "sync", "sign in", "integrations", "stremio", "trakt", "simkl",
                               "import", "metadata", "tmdb", "mdblist", "fanart", "debrid", "real-debrid",
                               "poster artwork", "erdb", "ratings", "iptv", "live tv", "playlist",
                               "media server", "plex", "jellyfin", "emby", "api key",
                               "xperience", "nuvio", "collections.json", "import collections"]
        case .stremioMirror: return ["mirror", "two-way sync", "add-ons", "library", "continue watching"]
        case .playback: return ["direct links only", "audio output", "video upscaling", "streaming cache",
                                "player engine", "dolby vision", "mkv", "skip step", "auto-skip", "intro",
                                "credits", "skip timestamps", "skip database", "seek bar", "community scrub previews",
                                "trickplay", "autoplay trailers", "trailer language", "default volume",
                                "auto-add watched", "play in", "external player", "still watching", "idle"]
        case .downloads: return ["downloads", "auto-delete", "delete watched", "offline", "storage", "reclaim space"]
        case .notifications: return ["new episode alerts", "episode", "notification"]
        case .streams: return ["quality preset", "smart source selection", "add-on ranking", "source type",
                               "safety filter", "regex", "max quality", "minimum quality", "max file size",
                               "compact source rows", "pinned sources", "resolution"]
        case .community: return ["contribute", "anonymized data", "singularity", "privacy"]
        case .server: return ["server", "configure server", "restart", "embedded", "node",
                              "external engine", "use a mac", "mac as engine", "engine host",
                              "seek anywhere", "pair a mac"]
        case .tabBar: return ["tab", "discover tab", "live tv tab", "library tab", "search tab"]
        case .appearance: return ["accent", "background", "oled", "app language", "language",
                                  "cinematic catalog cards", "hide poster labels", "poster style",
                                  "collections on home", "collections on discover", "refresh collections",
                                  "streaming services", "discover & region", "budget & box office", "spoiler",
                                  "blur", "dolby vision", "hdr", "match frame rate", "frame rate", "judder",
                                  "24p", "refresh rate", "text size", "performance",
                                  "top shelf", "tv home screen", "home screen", "continue watching",
                                  // INS-260722-02: the re-homed Home rows editor ("Customize Home"),
                                  // so search reaches it under Appearance.
                                  "customize home", "home rows", "top picks", "collections", "order", "hide"]
        case .audioSubtitle: return ["audio language", "fallback audio", "subtitle language", "fallback subtitle",
                                     "subtitles", "forced", "match audio to subtitle"]
        case .subtitle: return ["font", "size", "fine size", "color", "background", "subtitle style"]
        case .advanced: return ["mpv", "custom options", "diagnostic logging", "diagnostic log", "export log"]
        case .backup: return ["backup", "restore", "export library", "import library"]
        case .about: return ["version", "player", "what's new", "update", "libmpv", "mpvkit"]
        }
    }
}
