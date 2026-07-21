import Foundation

/// Pure decision logic for the two Dolby Vision playback fixes, deliberately kept in a file that imports nothing
/// but Foundation.
///
/// Why it is separate: the code that USES these decisions lives in files that pull in AVFoundation, UIKit and the
/// remux stream, so a standalone harness cannot compile them without app-wide stubs. That forced the first version
/// of these gates to assert on SOURCE TEXT, and a substring assertion proves a line exists, not that it runs. A
/// mutant that kept every asserted string and appended `false` to the condition passed that suite while the guard
/// could never fire. Moving the decision here makes both properties executable, so a test calls the real function
/// and a semantic break fails it.
enum DVPlaybackPolicy {

    // MARK: - HLS start position

    /// The media playlist header. `EXT-X-START` is the load-bearing line.
    ///
    /// The playlist carries no `EXT-X-ENDLIST` until the remux finishes, so a client choosing a start point applies
    /// the live-edge rule and begins roughly three target durations from the end. At a target duration of 5 that is
    /// about 15 seconds, which is the "Dolby Vision starts ~14 seconds in" reported from the field. Stating the
    /// start point explicitly removes the guess. `PRECISE=YES` stops the client rounding back to a preceding
    /// segment boundary.
    static func mediaPlaylistHeader(targetDuration: Int, mapURI: String) -> [String] {
        [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"\(mapURI)\"",
        ]
    }

    // MARK: - Display switch de-duplication

    /// One request for a display mode. `range` is carried as its raw string so this file needs no player types.
    struct DisplayRequest: Equatable {
        let range: String
        let rate: Float
        let width: Int
        let height: Int

        init(range: String, rate: Float, width: Int, height: Int) {
            self.range = range
            self.rate = rate
            self.width = width
            self.height = height
        }
    }

    /// True when `next` asks for exactly what `last` already asked for, so the assignment can be skipped.
    ///
    /// Assigning `preferredDisplayCriteria` makes tvOS renegotiate the HDMI link, and a renegotiation is a visible
    /// flick. Several paths can request the same mode during one start, so without this a single start renegotiates
    /// repeatedly for no change: the four to five flickers reported from the field.
    ///
    /// Deliberately compares the REQUEST, not the panel's state: `AVDisplayCriteria` is not equatable and there is
    /// no API to read back what the panel settled on, so what we asked for is the only honest thing to track. A nil
    /// `last` means we are asking for nothing (a reset cleared it), which is never redundant. Any difference in
    /// range, rate or dimensions is a real change and must still switch.
    static func isRedundantDisplayRequest(last: DisplayRequest?, next: DisplayRequest) -> Bool {
        guard let last else { return false }
        return last == next
    }
}
