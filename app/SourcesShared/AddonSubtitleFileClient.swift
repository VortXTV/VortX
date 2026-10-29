import Foundation

/// A bounded fetch for raw subtitle text returned by an installed add-on. This is only a transport
/// capability: it does not prove player ownership, parse cues, mount a track, or authorize sharing.
enum AddonSubtitleFileClient {
    private static let timeout: TimeInterval = 15
    private static let maximumBytes = SubtitleFileBudget.maximumBytes

    enum Format: Sendable, Equatable { case srt, vtt, ass }
    enum TextEncoding: Sendable, Equatable { case utf8, utf16, isoLatin1 }
    enum Failure: Error, Sendable, Equatable {
        case staleSelection, invalidSource, unsupportedFormat, invalidText, tooLarge, unavailable
    }

    /// Cooperative freshness only. The caller captures this closure from the original selection before
    /// async work. It must not look up a later/current selection. This is not a player/load authorization
    /// token; eventual integration must carry the engine's real owner/load revision to the final mount.
    struct FreshnessPermit: Sendable {
        private let subtitleID: String
        private let subtitleURL: String
        private let installedBaseURL: URL
        private let isOriginalSelectionCurrent: @Sendable () -> Bool

        init(for subtitle: AddonSubtitle, isCurrent: @escaping @Sendable () -> Bool) {
            subtitleID = subtitle.id
            subtitleURL = subtitle.url
            installedBaseURL = subtitle.installedBaseURL
            isOriginalSelectionCurrent = isCurrent
        }

        fileprivate func matches(_ subtitle: AddonSubtitle) -> Bool {
            subtitleID == subtitle.id && subtitleURL == subtitle.url
                && installedBaseURL == subtitle.installedBaseURL
        }
        fileprivate var isCurrent: Bool { isOriginalSelectionCurrent() }
    }

    /// Immutable byte snapshot. Freshness describes the captured selection when queried; it does not
    /// revoke Data already copied by the caller, and cannot undo parsing or other side effects. Callers
    /// must recheck this value and their actual engine/load owner immediately before any final mount.
    struct Snapshot: Sendable {
        let bytes: Data
        let format: Format
        let textEncoding: TextEncoding
        private let permit: FreshnessPermit
        var selectionIsCurrent: Bool { permit.isCurrent }
        fileprivate init(bytes: Data, format: Format, textEncoding: TextEncoding, permit: FreshnessPermit) {
            self.bytes = bytes
            self.format = format
            self.textEncoding = textEncoding
            self.permit = permit
        }
    }

    /// Download receipt with private request/origin identity. A snapshot is available only while the
    /// cooperative selection permit is current at copy time; later revocation cannot erase copied bytes.
    struct GuardedFile: Sendable {
        private let requestURL: URL
        private let installedOrigin: URL
        private let bytes: Data
        private let permit: FreshnessPermit
        let format: Format
        let textEncoding: TextEncoding

        fileprivate init(format: Format, textEncoding: TextEncoding, requestURL: URL, installedOrigin: URL,
                         bytes: Data, permit: FreshnessPermit) {
            self.format = format
            self.textEncoding = textEncoding
            self.requestURL = requestURL
            self.installedOrigin = installedOrigin
            self.bytes = bytes
            self.permit = permit
        }

        var selectionIsCurrent: Bool { permit.isCurrent }
        /// Original request identity only. This does not grant a fetch or player mount.
        var selectionIdentityURL: URL { requestURL }
        func snapshotIfCurrent() -> Snapshot? {
            guard permit.isCurrent else { return nil }
            return Snapshot(bytes: bytes, format: format, textEncoding: textEncoding, permit: permit)
        }
    }

    static func fetch(
        _ subtitle: AddonSubtitle,
        permit: FreshnessPermit,
        testURLProtocolClasses: AddonURLGuard.TestURLProtocolClasses? = nil
    ) async throws -> GuardedFile {
        try Task.checkCancellation()
        guard permit.matches(subtitle), permit.isCurrent else { throw Failure.staleSelection }
        guard validInstalledOrigin(subtitle.installedBaseURL),
              let requestURL = URL(string: subtitle.url) else { throw Failure.invalidSource }

        // Unknown extensions such as download.php or file.json remain eligible for response
        // classification. A known subtitle extension remains the first format hint, as in the MPV path.
        guard permit.matches(subtitle), permit.isCurrent else { throw Failure.staleSelection }
        let response: AddonURLGuard.Response
        do {
            response = try await AddonURLGuard.fetch(
                requestURL, context: .subtitleFile,
                access: .addon(origin: subtitle.installedBaseURL), timeout: timeout,
                testURLProtocolClasses: testURLProtocolClasses)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard permit.isCurrent else { throw Failure.staleSelection }
            throw Failure.unavailable
        }
        try Task.checkCancellation()
        guard permit.matches(subtitle), permit.isCurrent else { throw Failure.staleSelection }
        guard response.data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let encoding = rawTextEncoding(response.data) else { throw Failure.invalidText }
        guard let format = format(for: requestURL, mimeType: response.mimeType, data: response.data) else {
            throw Failure.unsupportedFormat
        }
        guard permit.matches(subtitle), permit.isCurrent else { throw Failure.staleSelection }
        return GuardedFile(format: format, textEncoding: encoding, requestURL: requestURL,
                           installedOrigin: subtitle.installedBaseURL, bytes: response.data, permit: permit)
    }

    private static func validInstalledOrigin(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return false }
        return Data(url.absoluteString.utf8).count <= AddonURLGuard.ResponseContext.subtitleFile.maximumURLBytes
    }

    /// Mirrors existing player decoder encodings while preserving bytes. This filters empty, known archive,
    /// and control-heavy data only; it does not validate SRT/VTT/ASS grammar or prove all payloads are text.
    private static func rawTextEncoding(_ data: Data) -> TextEncoding? {
        guard !data.isEmpty, !isKnownArchive(data) else { return nil }
        let hasUTF16BOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
        if hasUTF16BOM, let text = String(data: data, encoding: .utf16), containsOnlyTextScalars(text) { return .utf16 }
        if let text = String(data: data, encoding: .utf8), containsOnlyTextScalars(text) { return .utf8 }
        if let text = String(data: data, encoding: .utf16), containsOnlyTextScalars(text) { return .utf16 }
        if let text = String(data: data, encoding: .isoLatin1), containsOnlyTextScalars(text) { return .isoLatin1 }
        return nil
    }

    private static func isKnownArchive(_ data: Data) -> Bool {
        let signatures: [[UInt8]] = [
            [0x50, 0x4b, 0x03, 0x04], [0x50, 0x4b, 0x05, 0x06], [0x50, 0x4b, 0x07, 0x08],
            [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07], [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], [0x1f, 0x8b],
        ]
        return signatures.contains { data.starts(with: $0) }
    }

    private static func containsOnlyTextScalars(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return !((value < 0x20 || (0x7f...0x9f).contains(value))
                && ![0x09, 0x0a, 0x0d].contains(value))
        }
    }

    private static func format(for url: URL, mimeType: String?, data: Data) -> Format? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt": return .srt
        case "vtt": return .vtt
        case "ass": return .ass
        case "zip", "rar", "7z", "gz", "gzip": return nil
        default: break // Opaque provider endpoints are classified from response MIME/content below.
        }
        let mime = mimeType?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mime {
        case "text/vtt": return .vtt
        case "application/x-subrip", "application/srt", "text/srt": return .srt
        case "text/x-ass", "application/x-ass": return .ass
        case "application/zip", "application/x-rar-compressed", "application/vnd.rar",
             "application/x-7z-compressed", "application/gzip": return nil
        default: break
        }
        if let text = decodedText(data) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("WEBVTT") { return .vtt }
            if trimmed.hasPrefix("[Script Info]") { return .ass }
            // Match the bounded SRT fallback used by the existing mpv path. This is only a format
            // hint; the actual cue parser must still accept the bytes before any mount/publication.
            return .srt
        }
        return nil
    }

    private static func decodedText(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
