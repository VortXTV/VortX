import Foundation

/// The pool download may suspend across Off, a source replacement, or an A-B-A episode round trip.
/// Equality of a content URL is never sufficient authority to begin a new engine transaction.
enum PooledSubtitleSelectionPolicy {
    struct Admission<Load: Equatable & Sendable>: Sendable {
        let engine: ObjectIdentifier
        let load: Load
        let revision: UInt64
        let presentation: UUID

        func permits(engine: ObjectIdentifier, load: Load?, revision: UInt64?, presentation: UUID) -> Bool {
            self.engine == engine && self.load == load && self.revision == revision
                && self.presentation == presentation
        }
    }
}

/// Immutable bytes from the already-authorized pool response. The URL is selection identity only:
/// engines must never fetch it or reopen a shared pool-cache file to consume this source.
/// Permission is rechecked on the actual engine mount/preparation path, after every async boundary.
struct PlayerLocalSubtitleSource: Sendable {
    let data: Data
    let format: String
    let identityURL: URL
    let permitsUse: @Sendable () -> Bool
    private let guardedAddon: AddonSubtitleFileClient.GuardedFile?

    init?(data: Data, format: String, identityURL: URL,
          permitsUse: @escaping @Sendable () -> Bool) {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024,
              ["srt", "vtt", "ass"].contains(format),
              identityURL.scheme?.lowercased() == "https", identityURL.host != nil,
              identityURL.user == nil, identityURL.password == nil, permitsUse() else { return nil }
        self.data = data; self.format = format; self.identityURL = identityURL
        self.permitsUse = permitsUse
        self.guardedAddon = nil
    }

    /// Only the real installed-add-on response receipt can create this HTTP-capable local value.
    /// Its URL is immutable identity, never an instruction for an engine to fetch again.
    static func installedAddon(_ file: AddonSubtitleFileClient.GuardedFile) -> Self? {
        guard let snapshot = file.snapshotIfCurrent(), snapshot.selectionIsCurrent,
              !snapshot.bytes.isEmpty, snapshot.bytes.count <= SubtitleFileBudget.maximumBytes else { return nil }
        return Self(guardedAddon: file, snapshot: snapshot)
    }

    private init(guardedAddon file: AddonSubtitleFileClient.GuardedFile,
                 snapshot: AddonSubtitleFileClient.Snapshot) {
        data = snapshot.bytes
        switch snapshot.format {
        case .srt: format = "srt"
        case .vtt: format = "vtt"
        case .ass: format = "ass"
        }
        identityURL = file.selectionIdentityURL
        permitsUse = { file.selectionIsCurrent && snapshot.selectionIsCurrent }
        guardedAddon = file
    }

    /// Guarded add-on bytes are parsed by the real bounded renderer before native input. Re-emit
    /// plain cue text as SRT so native format probing cannot reopen M3U/HTML/ASS auxiliary resources.
    /// ASS timing/text is retained, with the renderer's existing flattened styling behavior.
    /// Existing pool bytes retain their original path and format.
    func preparedNativeSubtitle() -> (data: Data, format: String)? {
        guard permitsUse() else { return nil }
        guard guardedAddon != nil else { return (data, format) }
        let cues = SubtitleCueRenderer.parse(data: data)
        guard !cues.isEmpty, permitsUse() else { return nil }
        var output = Data()
        func timestamp(_ milliseconds: Int64) -> String {
            String(format: "%02lld:%02lld:%02lld,%03lld", milliseconds / 3_600_000,
                (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60, milliseconds % 1_000)
        }
        for (index, cue) in cues.enumerated() {
            guard permitsUse(), cue.start.isFinite, cue.end.isFinite, cue.start >= 0,
                  cue.end > cue.start, cue.end <= SubtitleCueRenderer.maximumTimelineSeconds else { return nil }
            let start = Int64((cue.start * 1_000).rounded(.down))
            let end = Int64((cue.end * 1_000).rounded(.up))
            let part = Data("\(index + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(cue.text)\n\n".utf8)
            guard part.count <= SubtitleFileBudget.maximumBytes - output.count else { return nil }
            output.append(part)
        }
        guard !output.isEmpty, permitsUse() else { return nil }
        return (output, "srt")
    }
}
