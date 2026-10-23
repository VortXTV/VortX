import Foundation

/// Observed active media, not a filename, engine preference or display-capability promise.
struct PlaybackMetadataFacts: Equatable, Sendable {
    enum DynamicRange: String, Sendable { case unknown, sdr, pq, hlg, dolbyVision }
    var width = 0
    var height = 0
    var dynamicRange: DynamicRange = .unknown
    var audioSelected = false
    var audioLanguage = ""
    var audioCodec = ""
    var audioChannels = 0

    var pills: [PlaybackMetadataPill] {
        var result: [PlaybackMetadataPill] = []
        if width > 0, height > 0 {
            let quality: String
            switch width {
            case 7000...: quality = "8K"
            case 3000...: quality = "4K"
            case 2200...: quality = "1440p"
            case 1500...: quality = "1080p"
            case 1000...: quality = "720p"
            default: quality = "\(height)p"
            }
            result.append(.init(id: "quality", text: quality, systemImage: "tv", accessibilityLabel: "Video resolution: \(width) by \(height), \(quality)"))
        }
        let range: String?
        switch dynamicRange {
        case .unknown, .sdr: range = nil
        case .pq: range = "HDR"
        case .hlg: range = "HLG"
        case .dolbyVision: range = "Dolby Vision"
        }
        if let range {
            result.append(.init(id: "range", text: range, systemImage: "sun.max", accessibilityLabel: "Active video dynamic range: \(range)"))
        }
        if audioSelected {
            var parts: [String] = []
            let language = audioLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if language.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil,
               !["und", "unknown", "zxx"].contains(language.lowercased()) {
                let code = String(language.split(separator: "-").first ?? Substring(language))
                parts.append(Locale.current.localizedString(forLanguageCode: code) ?? language.uppercased())
            }
            if let codec = Self.codecLabel(audioCodec) { parts.append(codec) }
            if (1...64).contains(audioChannels) { parts.append("\(audioChannels)ch") }
            let text = parts.isEmpty ? "Audio" : parts.joined(separator: " · ")
            result.append(.init(id: "audio", text: text, systemImage: "waveform", accessibilityLabel: "Selected audio: \(text)"))
        }
        return result
    }
    /// Consistency sampling only, not an atomic native snapshot or proof against an unobserved A-B-A.
    static func audioSelectionMatches(selectedRowID: Int?, beforeID: Int?, afterID: Int?) -> Bool {
        guard let selectedRowID, selectedRowID >= 0, let beforeID, let afterID else { return false }
        return selectedRowID == beforeID && beforeID == afterID
    }
    static func codecLabel(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "eac3", "ec-3", "eac3-joc", "audio/eac3", "audio/eac3-joc": return "EAC3"
        case "ac3", "ac-3", "audio/ac3": return "AC3"
        case "truehd", "audio/true-hd": return "TrueHD"
        case "dts", "dts-hd", "dca", "audio/vnd.dts", "audio/vnd.dts.hd": return "DTS"
        case "aac", "mp4a", "audio/mp4a-latm": return "AAC"
        case "flac", "audio/flac": return "FLAC"
        case "opus", "audio/opus": return "Opus"
        case "mp3", "audio/mpeg": return "MP3"
        case "alac", "audio/alac": return "ALAC"
        case "pcm", "audio/raw": return "PCM"
        default: return nil // Unknown codec is neutral; never infer Atmos from a title/channel count.
        }
    }
    static func mpvRange(_ gamma: String) -> DynamicRange {
        switch gamma.lowercased() {
        case "pq", "smpte2084": return .pq
        case "hlg", "arib-std-b67": return .hlg
        case "bt.1886", "srgb", "gamma2.2", "gamma2.4", "bt.709": return .sdr
        default: return .unknown
        }
    }
}
struct PlaybackMetadataPill: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let systemImage: String
    let accessibilityLabel: String
}
