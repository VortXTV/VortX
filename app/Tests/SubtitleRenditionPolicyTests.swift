// Executable harness for the embedded-subtitle rendition decisions.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/subtitle-rendition-policy-test \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Sources/Player/SubtitleRenditionPolicy.swift \
//     app/Tests/SubtitleRenditionPolicyTests.swift && /tmp/subtitle-rendition-policy-test
//
// This suite CALLS the production decisions. The code that uses them is split between VortXMKVRemuxStream
// (which pulls in the whole FFmpeg vendor tree) and VortXRemuxHLSServer (Network.framework), so a suite
// written against either could only have asserted on source text. That shape was already proven inadequate on
// this codebase: a mutant that preserved every asserted string while appending `false` to a guard passed a
// whole suite while the guard could never fire.
//
// The bar is mutation survival, not a pass count. Every assertion below must turn RED when its property
// breaks, including SEMANTIC breaks that leave the source text intact. In particular:
//   - the overlap window is asserted at both open boundaries, so `>` flipped to `>=` (or the two comparisons
//     swapped) fails;
//   - the document-corrupting cases (blank lines, a literal arrow, a stray ampersand) assert the OUTPUT
//     document parses as one cue, not merely that a substring is present;
//   - the qualification rules are asserted BOTH ways, so deleting a filter fails as loudly as inverting one.

import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

/// Standalone-compilation stub for the buffer's failure-reason funnel (same pattern as the RemoteConfig stub).
enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) { print("[\(tag)] \(message)") }
}

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

typealias Policy = SubtitleRenditionPolicy
typealias Track = SubtitleRenditionPolicy.SourceTrack
typealias Cue = SubtitleRenditionPolicy.Cue

func data(_ text: String) -> Data { Data(text.utf8) }

/// Build a tx3g sample: 2-byte big-endian length + UTF-8 bytes, plus a trailing style box that must be ignored.
func tx3g(_ text: String, trailing: [UInt8] = []) -> Data {
    let body = [UInt8](text.utf8)
    var out: [UInt8] = [UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
    out += body
    out += trailing
    return Data(out)
}

/// Parse a WebVTT document back into cues, so assertions can be made about the DOCUMENT rather than about a
/// substring of it. A body line that accidentally reads as timing, or a blank line inside a body, changes the
/// parse and therefore fails a test even though every asserted substring is still present.
func parseVTT(_ document: String) -> (header: String, cues: [(time: String, body: String)]) {
    let blocks = document.components(separatedBy: "\n\n")
    var cues: [(String, String)] = []
    for block in blocks.dropFirst() {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.contains("-->") else { continue }
        cues.append((first, lines.dropFirst().joined(separator: "\n")))
    }
    return (blocks.first ?? "", cues)
}

// Compiling several files together means only a `main.swift` may carry top-level expressions, so the run body
// is a function invoked from `@main`, matching the other standalone suites in this directory.
@main
enum SubtitleRenditionPolicyTests {
    @MainActor static func main() { run() }
}

@MainActor func run() {

// MARK: - Language + naming

check("lang: a tag is normalised for comparison", Policy.languageKey("  ENG \n") == "eng")
check("lang: und is unknown", Policy.isUnknownLanguage("und"))
check("lang: zxx is unknown", Policy.isUnknownLanguage("zxx"))
check("lang: an empty tag is unknown", Policy.isUnknownLanguage(""))
check("lang: a real tag is not unknown", !Policy.isUnknownLanguage("eng"))

check("name: a known tag becomes its English name",
      Policy.displayName(language: "jpn", title: "", isForced: false) == "Japanese")
check("name: a tag is matched case-insensitively",
      Policy.displayName(language: "JPN", title: "", isForced: false) == "Japanese")
check("name: an unlisted tag falls back to the uppercased tag",
      Policy.displayName(language: "kaz", title: "", isForced: false) == "KAZ")
check("name: an unknown tag becomes Unknown",
      Policy.displayName(language: "und", title: "", isForced: false) == "Unknown")
check("name: the source title wins over the language name",
      Policy.displayName(language: "eng", title: "English SDH", isForced: false) == "English SDH")
check("name: a forced track is marked",
      Policy.displayName(language: "eng", title: "", isForced: true) == "English (Forced)")
check("name: a title that already says forced is not marked twice",
      Policy.displayName(language: "eng", title: "Forced English", isForced: true) == "Forced English")

// MARK: - Rendition qualification

let mixed = [
    Track(index: 3, format: .subRip, language: "eng", title: "", isDefault: false, isForced: false),
    Track(index: 4, format: .ass, language: "jpn", title: "", isDefault: true, isForced: false),
    Track(index: 5, format: .subRip, language: "eng", title: "", isDefault: true, isForced: false),
    Track(index: 6, format: .subRip, language: "eng", title: "Forced", isDefault: false, isForced: true),
    // A SECOND track the source also marked default, distinguishable from every earlier one so the dedupe
    // cannot be what removes it. HLS allows one DEFAULT per group, so this one must be published DEFAULT=NO.
    Track(index: 7, format: .subRip, language: "fre", title: "", isDefault: true, isForced: false),
]
let picked = Policy.renditions(from: mixed)
check("renditions: source order is kept",
      picked.map(\.sourceIndex) == [3, 4, 6, 7])
check("renditions: ids are the serving ordinals",
      picked.map(\.id) == [0, 1, 2, 3])
check("renditions: a second source default is published as NOT default",
      picked.first(where: { $0.sourceIndex == 7 })?.isDefault == false)
check("renditions: an indistinguishable duplicate is dropped",
      picked.filter { $0.name == "English" }.count == 1)
check("renditions: a track differing only by forced is NOT a duplicate",
      picked.contains { $0.isForced && $0.language == "eng" })
check("renditions: exactly one DEFAULT survives",
      picked.filter(\.isDefault).count == 1)
check("renditions: the default is the source's own default track",
      picked.first(where: \.isDefault)?.sourceIndex == 4)
check("renditions: a source with no default track gets no default",
      Policy.renditions(from: [
        Track(index: 1, format: .subRip, language: "eng", title: "", isDefault: false, isForced: false),
      ]).allSatisfy { !$0.isDefault })
check("renditions: an unknown language is published explicitly as und",
      Policy.renditions(from: [
        Track(index: 1, format: .subRip, language: "und", title: "Commentary", isDefault: false, isForced: false),
      ]).first?.language == "und")
check("renditions: a known language is published normalised",
      Policy.renditions(from: [
        Track(index: 1, format: .subRip, language: "ENG", title: "", isDefault: false, isForced: false),
      ]).first?.language == "eng")
check("renditions: no tracks yields no renditions", Policy.renditions(from: []).isEmpty)

let many = (0..<20).map {
    Track(index: $0, format: .subRip, language: "l\($0)", title: "T\($0)", isDefault: false, isForced: false)
}
check("renditions: the cap holds", Policy.renditions(from: many).count == Policy.maxRenditions)
check("renditions: one under the cap is not capped",
      Policy.renditions(from: Array(many.prefix(Policy.maxRenditions - 1))).count == Policy.maxRenditions - 1)
check("renditions: exactly the cap is not truncated further",
      Policy.renditions(from: Array(many.prefix(Policy.maxRenditions))).count == Policy.maxRenditions)

let collidingMetadata = Policy.renditions(from: [
    Track(index: 10, format: .subRip, language: "eng", title: "Main", isDefault: false, isForced: false),
    Track(index: 11, format: .subRip, language: "spa", title: "Main", isDefault: false, isForced: false),
    Track(index: 12, format: .subRip, language: "eng", title: "Commentary", isDefault: true, isForced: false),
    Track(index: 13, format: .subRip, language: "eng", title: "Forced", isDefault: false, isForced: true),
])
check("renditions: colliding source titles become unique advertised names",
      Set(collidingMetadata.map { $0.name.lowercased() }).count == collidingMetadata.count)
let chainedNameCollision = Policy.renditions(from: [
    Track(index: 1, format: .subRip, language: "eng", title: "Main", isDefault: false, isForced: false),
    Track(index: 2, format: .subRip, language: "spa", title: "Main (SPA)", isDefault: false, isForced: false),
    Track(index: 3, format: .subRip, language: "fre", title: "Main (SPA) 12", isDefault: false, isForced: false),
    Track(index: 12, format: .subRip, language: "spa", title: "Main", isDefault: false, isForced: false),
])
check("renditions: hostile chained source titles cannot occupy every fixed disambiguation suffix",
      chainedNameCollision.count == 4
          && Set(chainedNameCollision.map { $0.name.lowercased() }).count == 4)
let autoSelected = collidingMetadata.filter(\.isAutoSelect)
let autoSelectTuples = autoSelected.map { "\($0.language)|\($0.isForced)" }
check("renditions: every AUTOSELECT=YES tuple is unique within the group",
      Set(autoSelectTuples).count == autoSelectTuples.count)
check("renditions: the one default is also auto-selectable",
      collidingMetadata.filter(\.isDefault).count == 1
        && collidingMetadata.first(where: \.isDefault)?.isAutoSelect == true)

// MARK: - Master advertising

let english = Policy.renditions(from: [
    Track(index: 2, format: .subRip, language: "eng", title: "", isDefault: true, isForced: false),
])[0]
let forced = Policy.renditions(from: [
    Track(index: 2, format: .subRip, language: "spa", title: "", isDefault: false, isForced: true),
])[0]
let untagged = Policy.renditions(from: [
    Track(index: 2, format: .subRip, language: "und", title: "Signs", isDefault: false, isForced: false),
])[0]

let englishTag = Policy.mediaTag(english)
check("master: the tag names the subtitles type and group",
      englishTag.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\""))
check("master: the tag carries the rendition's own playlist URI",
      englishTag.contains("URI=\"subs0.m3u8\""))
check("master: a default track is advertised DEFAULT=YES",
      englishTag.contains(",DEFAULT=YES"))
check("master: a non-default track is advertised DEFAULT=NO",
      Policy.mediaTag(forced).contains(",DEFAULT=NO"))
check("master: a normal track is auto-selectable",
      englishTag.contains(",AUTOSELECT=YES") && englishTag.contains(",FORCED=NO"))
check("master: a forced track carries its distinct FORCED tuple",
      Policy.mediaTag(forced).contains(",AUTOSELECT=YES") && Policy.mediaTag(forced).contains(",FORCED=YES"))
check("master: a language is advertised when the source proved one",
      englishTag.contains("LANGUAGE=\"eng\""))
check("master: an untagged track is advertised with explicit und language",
      Policy.mediaTag(untagged).contains("LANGUAGE=\"und\""))
check("master: every subtitle row has a non-empty LANGUAGE attribute",
      [english, forced, untagged].allSatisfy {
          let tag = Policy.mediaTag($0)
          return tag.contains("LANGUAGE=") && !tag.contains("LANGUAGE=\"\"")
      })
check("master: a quote is removed from a source title",
      Policy.quoteSafe("He said \"hi\"") == "He said 'hi'")
check("master: a quote in a source title cannot close the NAME attribute early",
      !Policy.mediaTag(Policy.renditions(from: [
        Track(index: 1, format: .subRip, language: "eng", title: "He said \"hi\"", isDefault: false, isForced: false),
      ])[0]).contains("\"hi\""))
check("master: a newline in a source title cannot break the tag",
      !Policy.mediaTag(Policy.renditions(from: [
        Track(index: 1, format: .subRip, language: "eng", title: "two\nlines", isDefault: false, isForced: false),
      ])[0]).contains("\n"))
check("master: variants reference the group when renditions exist",
      Policy.streamInfAttribute(renditionCount: 1) == ",SUBTITLES=\"subs\"")
check("master: variants are untouched when there are no renditions",
      Policy.streamInfAttribute(renditionCount: 0) == "")

// MARK: - Request routing (the generator and the parser held against each other)

let routedRendition = Policy.renditions(from: [
    Track(index: 1, format: .subRip, language: "eng", title: "", isDefault: false, isForced: false),
])[0]
check("route: the URI the master advertises parses back to that rendition",
      Policy.parseRequest(path: "/" + Policy.playlistURI(routedRendition)) == .playlist(renditionID: 0))
check("route: the URI a playlist advertises parses back to that segment",
      Policy.parseRequest(path: "/" + Policy.segmentURI(renditionID: 2, segmentID: 37))
        == .segment(renditionID: 2, segmentID: 37))
check("route: every generated segment URI of a real playlist is routable",
      Policy.mediaPlaylist(renditionID: 3, window: VortXHLSWindow(segments: [
          VortXHLSSegment(id: 8, byteOffset: 0, byteLength: 1, start: 0, duration: 6),
          VortXHLSSegment(id: 9, byteOffset: 1, byteLength: 1, start: 6, duration: 6),
          VortXHLSSegment(id: 10, byteOffset: 2, byteLength: 1, start: 12, duration: 6),
      ]), ended: true, targetDuration: 6)
        .filter { $0.hasSuffix(".vtt") }
        .allSatisfy { Policy.parseRequest(path: "/\($0)") != nil })
check("route: a video resource is not a subtitle resource",
      Policy.parseRequest(path: "/media.m3u8") == nil && Policy.parseRequest(path: "/seg3.m4s") == nil)
check("route: the master is not a subtitle resource",
      Policy.parseRequest(path: "/master.m3u8") == nil)
// The paths here are the same LENGTH as ours, so dropping a fixed prefix leaves a well-formed remainder: they
// route iff the prefix is not actually checked. A shorter or longer foreign path would fail the number parse
// by accident and prove nothing.
check("route: only our own prefix routes here, whatever the rest looks like",
      Policy.parseRequest(path: "/abcd7.m3u8") == nil
        && Policy.parseRequest(path: "/abcd7-1.vtt") == nil)
check("route: a malformed subtitle path is not routed",
      Policy.parseRequest(path: "/subs.m3u8") == nil
        && Policy.parseRequest(path: "/subsx.m3u8") == nil
        && Policy.parseRequest(path: "/subs0.vtt") == nil
        && Policy.parseRequest(path: "/subs0-1-2.vtt") == nil
        && Policy.parseRequest(path: "/subs-1-0.vtt") == nil)

// MARK: - Media playlist

let playlistWindow = VortXHLSWindow(segments: [
    VortXHLSSegment(id: 8, byteOffset: 0, byteLength: 100, start: 48, duration: 6.0),
    VortXHLSSegment(id: 9, byteOffset: 100, byteLength: 100, start: 54, duration: 5.5),
])
let playlist = Policy.mediaPlaylist(
    renditionID: 1, window: playlistWindow, ended: false, targetDuration: 6)
check("playlist: it is a playlist", playlist.first == "#EXTM3U")
check("playlist: media sequence is the resident window's first absolute id",
      playlist.contains("#EXT-X-MEDIA-SEQUENCE:8"))
check("playlist: a nonzero window never claims the session-zero start",
      !playlist.contains { $0.hasPrefix("#EXT-X-START:") })
check("playlist: a sliding subtitle rendition is not falsely EVENT",
      !playlist.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
check("playlist: WebVTT segments carry no init map",
      !playlist.contains { $0.hasPrefix("#EXT-X-MAP") })
check("playlist: one EXTINF and one URI per video segment",
      playlist.filter { $0.hasPrefix("#EXTINF") }.count == 2
        && playlist.filter { $0.hasSuffix(".vtt") }.count == 2)
check("playlist: durations mirror the video segments exactly",
      playlist.contains("#EXTINF:6.000,") && playlist.contains("#EXTINF:5.500,"))
check("playlist: segment URIs preserve rendition and absolute video ids",
      playlist.contains("subs1-8.vtt") && playlist.contains("subs1-9.vtt")
        && !playlist.contains("subs1-0.vtt"))
check("playlist: an unfinished remux gets NO endlist",
      !playlist.contains("#EXT-X-ENDLIST"))
check("playlist: a finished remux gets an endlist",
      Policy.mediaPlaylist(renditionID: 0, window: playlistWindow, ended: true, targetDuration: 6)
        .last == "#EXT-X-ENDLIST")
let zeroWindowPlaylist = Policy.mediaPlaylist(
    renditionID: 0,
    window: VortXHLSWindow(segments: [
        VortXHLSSegment(id: 0, byteOffset: 0, byteLength: 1, start: 0, duration: 6),
    ]),
    ended: false,
    targetDuration: 6)
check("playlist: only the session-zero window carries the explicit start",
      zeroWindowPlaylist.contains("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES"))

// MARK: - Preallocation bounds

check("bounds: a packet exactly at the decode cap is accepted before allocation",
      Policy.canDecodePayload(byteCount: Policy.maxPacketBytes))
check("bounds: an oversized packet is rejected before allocation",
      !Policy.canDecodePayload(byteCount: Policy.maxPacketBytes + 1)
        && !Policy.canDecodePayload(byteCount: -1))
check("bounds: stored plus incoming bytes may exactly reach the cap",
      Policy.canStore(existingBytes: Policy.maxStoredBytes - 1, incomingBytes: 1))
check("bounds: stored plus incoming bytes are checked together before append",
      !Policy.canStore(existingBytes: Policy.maxStoredBytes - 1, incomingBytes: 2))
check("bounds: checked subtraction makes pathological counts reject without overflow",
      !Policy.canStore(existingBytes: Int.max, incomingBytes: Int.max))

// MARK: - Payload decoding

check("srt: the payload is the cue text",
      Policy.plainText(payload: data("Hello there"), format: .subRip) == "Hello there")
check("srt: WebVTT-compatible markup survives",
      Policy.plainText(payload: data("<i>Hello</i>"), format: .subRip) == "<i>Hello</i>")
check("ass: the text field is taken from the dialogue fields",
      Policy.plainText(payload: data("0,0,Default,,0,0,0,,Hello there"), format: .ass) == "Hello there")
check("ass: commas inside the text survive the field split",
      Policy.plainText(payload: data("0,0,Default,,0,0,0,,Yes, of course"), format: .ass) == "Yes, of course")
check("ass: override blocks are removed",
      Policy.plainText(payload: data("0,0,Default,,0,0,0,,{\\an8}{\\i1}Up top"), format: .ass) == "Up top")
check("ass: the line break escape becomes a real line break",
      Policy.plainText(payload: data("0,0,Default,,0,0,0,,One\\NTwo"), format: .ass) == "One\nTwo")
check("ass: the hard-space escape becomes a space",
      Policy.plainText(payload: data("0,0,Default,,0,0,0,,A\\hB"), format: .ass) == "A B")
check("ass: a Dialogue keyword is not printed",
      Policy.plainText(payload: data("Dialogue:0,0,Default,,0,0,0,,Hi"), format: .ass) == "Hi")
check("ass: angle brackets are escaped for a format with no markup convention",
      Policy.plainText(payload: data("0,0,Default,,0,0,0,,a<b"), format: .ass) == "a&lt;b")
check("ass: a payload with too few fields is shown rather than dropped",
      Policy.plainText(payload: data("just text"), format: .ass) == "just text")
check("ass: an override-only payload yields nothing",
      Policy.plainText(payload: data("0,0,Default,,0,0,0,,{\\pos(1,2)}"), format: .ass) == nil)

check("tx3g: the length prefix is honoured",
      Policy.plainText(payload: tx3g("Hi"), format: .movText) == "Hi")
check("tx3g: trailing style bytes are ignored",
      Policy.plainText(payload: tx3g("Hi", trailing: [0, 0, 0, 12, 115, 116, 121, 108]), format: .movText) == "Hi")
check("tx3g: an empty sample yields nothing",
      Policy.plainText(payload: tx3g(""), format: .movText) == nil)
check("tx3g: a sample too short to hold its own length yields nothing",
      Policy.plainText(payload: Data([0x00]), format: .movText) == nil)
check("tx3g: a length that overruns the sample yields nothing",
      Policy.plainText(payload: Data([0x00, 0x40, 0x41]), format: .movText) == nil)
check("tx3g: the length prefix is big-endian, not little-endian",
      Policy.plainText(payload: Data([0x00, 0x02, 0x41, 0x42]), format: .movText) == "AB")

check("text: an empty payload yields nothing",
      Policy.plainText(payload: Data(), format: .subRip) == nil)
check("text: a whitespace-only payload yields nothing",
      Policy.plainText(payload: data("   \n  "), format: .subRip) == nil)
check("text: invalid UTF-8 does not lose the whole cue",
      Policy.plainText(payload: Data([0x41, 0xFF, 0x42]), format: .subRip)?.contains("A") == true)

// MARK: - Document safety

check("safety: a blank line inside a body would split the cue, so runs collapse",
      Policy.sanitizeCueText("One\n\n\nTwo", escapeAngleBrackets: false) == "One\nTwo")
check("safety: carriage returns are normalised",
      Policy.sanitizeCueText("One\r\nTwo", escapeAngleBrackets: false) == "One\nTwo")
check("safety: a literal arrow in a body is neutralised",
      Policy.sanitizeCueText("A --> B", escapeAngleBrackets: false)?.contains("-->") == false)
check("safety: a bare ampersand is escaped",
      Policy.sanitizeCueText("Tom & Jerry", escapeAngleBrackets: false) == "Tom &amp; Jerry")
check("safety: an existing entity is not double-escaped",
      Policy.sanitizeCueText("Tom &amp; Jerry", escapeAngleBrackets: false) == "Tom &amp; Jerry")
check("safety: angle brackets are kept for SRT so its markup still applies",
      Policy.sanitizeCueText("<i>x</i>", escapeAngleBrackets: false) == "<i>x</i>")
check("safety: angle brackets are escaped when asked",
      Policy.sanitizeCueText("<i>x</i>", escapeAngleBrackets: true) == "&lt;i&gt;x&lt;/i&gt;")

let arrowDoc = Policy.webVTTDocument(cues: [Cue(start: 0, end: 1, text:
    Policy.sanitizeCueText("A --> B", escapeAngleBrackets: false)!)])
check("safety: a body carrying an arrow still parses as exactly ONE cue",
      parseVTT(arrowDoc).cues.count == 1)

// MARK: - Cue construction

check("cue: a normal packet becomes a cue",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: 10, durationSeconds: 2)
        == Cue(start: 10, end: 12, text: "Hi"))
check("cue: a packet with no timestamp is dropped",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: -1, durationSeconds: 2) == nil)
check("cue: a zero start is a valid timestamp, not a missing one",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: 0, durationSeconds: 2)?.start == 0)
check("cue: a missing duration falls back rather than dropping the cue",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: 1, durationSeconds: 0)?.end
        == 1 + Policy.fallbackCueDuration)
check("cue: a too-short duration is raised to the floor",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: 1, durationSeconds: 0.01)?.end
        == 1 + Policy.minCueDuration)
check("cue: a runaway duration is capped",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: 1, durationSeconds: 9000)?.end
        == 1 + Policy.maxCueDuration)
check("cue: a duration just under the cap is NOT capped",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: 0,
                 durationSeconds: Policy.maxCueDuration - 0.5)?.end == Policy.maxCueDuration - 0.5)
check("cue: an empty payload yields no cue",
      Policy.cue(payload: Data(), format: .subRip, startSeconds: 1, durationSeconds: 2) == nil)
check("cue: a non-finite start is dropped",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: .infinity, durationSeconds: 2) == nil)
check("cue: a non-finite duration falls back",
      Policy.cue(payload: data("Hi"), format: .subRip, startSeconds: 1, durationSeconds: .nan)?.end
        == 1 + Policy.fallbackCueDuration)
check("cue: a timestamp beyond the supported timeline is rejected",
      Policy.cue(payload: data("Hi"), format: .subRip,
                 startSeconds: Policy.maximumTimelineSeconds + 1, durationSeconds: 2) == nil)
check("cue: an end beyond the supported timeline is rejected without overflow",
      Policy.cue(payload: data("Hi"), format: .subRip,
                 startSeconds: Policy.maximumTimelineSeconds, durationSeconds: 2) == nil)

// MARK: - Timestamps

check("time: zero formats as a full timestamp", Policy.timestamp(0) == "00:00:00.000")
check("time: milliseconds are carried", Policy.timestamp(1.5) == "00:00:01.500")
check("time: minutes roll over", Policy.timestamp(61.25) == "00:01:01.250")
check("time: hours roll over", Policy.timestamp(3661.001) == "01:01:01.001")
check("time: past an hour the hour field is not truncated", Policy.timestamp(7200) == "02:00:00.000")
check("time: a negative time clamps rather than formatting garbage", Policy.timestamp(-5) == "00:00:00.000")
check("time: a huge finite value clamps safely instead of trapping Int conversion",
      Policy.timestamp(Double.greatestFiniteMagnitude)
        == Policy.timestamp(Policy.maximumTimelineSeconds))

// MARK: - Segment windows

let window = [
    Cue(start: 0, end: 4, text: "before"),
    Cue(start: 5, end: 7, text: "straddles the start"),
    Cue(start: 8, end: 9, text: "inside"),
    Cue(start: 11, end: 14, text: "straddles the end"),
    Cue(start: 20, end: 22, text: "after"),
]
let inWindow = Policy.cues(window, overlapping: 6, end: 12).map(\.text)
check("window: a cue wholly inside is included", inWindow.contains("inside"))
check("window: a cue straddling the start is included", inWindow.contains("straddles the start"))
check("window: a cue straddling the end is included", inWindow.contains("straddles the end"))
check("window: a cue that ended before the window is excluded", !inWindow.contains("before"))
check("window: a cue that starts after the window is excluded", !inWindow.contains("after"))
check("window: a cue ending exactly at the window start is excluded",
      Policy.cues([Cue(start: 0, end: 6, text: "x")], overlapping: 6, end: 12).isEmpty)
check("window: a cue starting exactly at the window end is excluded",
      Policy.cues([Cue(start: 12, end: 14, text: "x")], overlapping: 6, end: 12).isEmpty)
check("window: a cue starting exactly at the window start is included",
      Policy.cues([Cue(start: 6, end: 8, text: "x")], overlapping: 6, end: 12).count == 1)
check("window: an empty window yields nothing",
      Policy.cues(window, overlapping: 6, end: 6).isEmpty)
check("window: results are start-ordered",
      Policy.cues([Cue(start: 9, end: 10, text: "b"), Cue(start: 7, end: 8, text: "a")],
                  overlapping: 0, end: 20).map(\.text) == ["a", "b"])

// MARK: - Global demux settlement

let absoluteVideoWindow = VortXHLSWindow(segments: [
    VortXHLSSegment(id: 40, byteOffset: 0, byteLength: 10, start: 0, duration: 4),
    VortXHLSSegment(id: 41, byteOffset: 10, byteLength: 10, start: 4, duration: 4),
    VortXHLSSegment(id: 42, byteOffset: 20, byteLength: 10, start: 8, duration: 4),
])
check("settlement: the interleave margin is positive and hard bounded",
      Policy.interleaveMarginSeconds > 0 && Policy.interleaveMarginSeconds <= 2)
var settlement = Policy.SettlementState()
check("settlement: global video progress is accepted without a subtitle packet",
      settlement.observeGlobalTimestamp(10))
check("settlement: the monotonic watermark settles through max minus margin",
      settlement.settledBefore == 10 - Policy.interleaveMarginSeconds)
check("settlement: a long subtitle gap still publishes every fully settled absolute segment",
      settlement.settledWindow(videoWindow: absoluteVideoWindow)?.segments.map(\.id) == [40, 41])
check("settlement: modest interleave reordering above the settled frontier is accepted",
      settlement.observeGlobalTimestamp(9))
check("settlement: later global progress settles the remaining empty subtitle segment",
      settlement.observeGlobalTimestamp(14)
        && settlement.settledWindow(videoWindow: absoluteVideoWindow)?.segments.map(\.id) == [40, 41, 42])

var readiness = Policy.SettlementState()
let futureWindow = VortXHLSWindow(segments: [
    VortXHLSSegment(id: 70, byteOffset: 0, byteLength: 10, start: 8, duration: 4),
])
check("settlement: a premature empty prefix is not publishable or cacheable",
      readiness.settledWindow(videoWindow: futureWindow) == nil)
_ = readiness.observeGlobalTimestamp(14)
check("settlement: the same shared window becomes visible after its boundary settles",
      readiness.settledWindow(videoWindow: futureWindow)?.segments.map(\.id) == [70])

var eofSettlement = Policy.SettlementState()
_ = eofSettlement.observeGlobalTimestamp(1)
eofSettlement.finish()
check("settlement: EOF settles the complete resident video window",
      eofSettlement.settledWindow(videoWindow: absoluteVideoWindow) == absoluteVideoWindow)
var emptyEOFSettlement = Policy.SettlementState()
emptyEOFSettlement.finish()
check("settlement: EOF is the only valid empty publication state",
      emptyEOFSettlement.settledWindow(videoWindow: VortXHLSWindow(segments: []))
        == VortXHLSWindow(segments: []))

var capFailure = Policy.SettlementState()
_ = capFailure.observeGlobalTimestamp(20)
capFailure.invalidate(.payloadBound)
check("settlement: a typed cap failure invalidates optional publication atomically",
      !capFailure.isValid
        && capFailure.invalidationReason == .payloadBound
        && capFailure.settledWindow(videoWindow: absoluteVideoWindow) == nil)

var regression = Policy.SettlementState()
_ = regression.observeGlobalTimestamp(20)
check("settlement: a packet behind the already settled frontier invalidates the feature",
      !regression.observeGlobalTimestamp(17)
        && !regression.isValid
        && regression.settledWindow(videoWindow: absoluteVideoWindow) == nil)

var hugeWatermark = Policy.SettlementState()
check("settlement: an impossible global timestamp fails safely",
      !hugeWatermark.observeGlobalTimestamp(Double.greatestFiniteMagnitude)
        && !hugeWatermark.isValid)

// MARK: - Documents

let doc = Policy.webVTTDocument(cues: [
    Cue(start: 1, end: 3, text: "First"),
    Cue(start: 4, end: 5.5, text: "Second\nline"),
])
let parsed = parseVTT(doc)
check("doc: it is a WebVTT document", parsed.header.hasPrefix("WEBVTT"))
check("doc: the timeline map ties cue time to media time",
      parsed.header.contains("X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"))
check("doc: every cue is present", parsed.cues.count == 2)
check("doc: cue timings are formatted as WebVTT ranges",
      parsed.cues[0].time == "00:00:01.000 --> 00:00:03.000")
check("doc: a two-line body stays one cue",
      parsed.cues[1].body == "Second\nline")
check("doc: a cue-less stretch still serves a valid document",
      parseVTT(Policy.webVTTDocument(cues: [])).cues.isEmpty
        && Policy.webVTTDocument(cues: []).hasPrefix("WEBVTT"))
check("doc: a zero-length cue is not written",
      parseVTT(Policy.webVTTDocument(cues: [Cue(start: 2, end: 2, text: "x")])).cues.isEmpty)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
}
