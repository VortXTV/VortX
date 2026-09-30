import Foundation

/// Exact-file hints from the selected stream. A torrent's infoHash is not a subtitle videoHash.
struct SubtitleRequestMetadata: Equatable, Sendable {
    var filename: String? = nil
    var videoHash: String? = nil
    var videoSize: Int64? = nil

    static func effectiveVideoID(libraryID: String, videoID: String, cachedIMDbID: String?) -> String {
        guard libraryID.lowercased().hasPrefix("tmdb:"), let cachedIMDbID,
              videoID == libraryID || videoID.hasPrefix(libraryID + ":") else { return videoID }
        return cachedIMDbID + videoID.dropFirst(libraryID.count)
    }

    func resourcePath(type: String, videoID: String) -> String {
        var extras: [(String, String)] = []
        if let hash = videoHash, !hash.isEmpty { extras.append(("videoHash", hash)) }
        if let size = videoSize, size > 0 { extras.append(("videoSize", String(size))) }
        if let name = filename, !name.isEmpty { extras.append(("filename", name)) }
        let suffix = extras.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        return "subtitles/\(Self.encode(type))/\(Self.encode(videoID, keepColon: true))"
            + (suffix.isEmpty ? "" : "/\(suffix)") + ".json"
    }

    private static func encode(_ value: String, keepColon: Bool = false) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~" + (keepColon ? ":" : ""))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
