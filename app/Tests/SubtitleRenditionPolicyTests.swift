// Executable harness for the embedded-subtitle rendition decisions.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/subtitle-rendition-policy-test \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Sources/Player/PGSOCRPolicy.swift \
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
        // A cue may carry a stable identifier line before its timing line (cue-…); find the timing line
        // wherever it sits and treat everything after it as the body.
        guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
        cues.append((lines[timeIndex], lines[(timeIndex + 1)...].joined(separator: "\n")))
    }
    return (blocks.first ?? "", cues)
}

/// The largest number of cues that are on screen together at any instant of `cues`. Simultaneity can only rise
/// where a cue starts, so probing every start is a complete answer, and stating it this way means the cap
/// assertions test the PROPERTY rather than a particular array the implementation happened to produce.
func maxSimultaneous(_ cues: [Cue]) -> Int {
    cues.reduce(0) { peak, probe in
        max(peak, cues.filter { $0.start <= probe.start && $0.end > probe.start }.count)
    }
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
      picked.map(\.sourceIndex) == [3, 4, 5, 6, 7])
check("renditions: ids are the serving ordinals",
      picked.map(\.id) == [0, 1, 2, 3, 4])
check("renditions: a second source default is published as NOT default",
      picked.first(where: { $0.sourceIndex == 7 })?.isDefault == false)
check("renditions: indistinguishable source tracks remain independently selectable",
      picked.contains(where: { $0.sourceIndex == 3 })
          && picked.contains(where: { $0.sourceIndex == 5 }))
check("renditions: duplicate labels carry deterministic source identity",
      picked.first(where: { $0.sourceIndex == 5 })?.name.contains("Source 5") == true)
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

var largePGSInventory = (0..<27).map {
    Track(
        index: 10 + $0,
        format: .pgs,
        language: "eng",
        title: "PGS \($0)",
        isDefault: false,
        isForced: false)
}
largePGSInventory[10] = Track(
    index: 20, format: .pgs, language: "spa", title: "Default",
    isDefault: true, isForced: false)
largePGSInventory[11] = Track(
    index: 21, format: .pgs, language: "fra", title: "Forced",
    isDefault: false, isForced: true)
largePGSInventory[12] = Track(
    index: 22, format: .pgs, language: "jpn", title: "Preferred",
    isDefault: false, isForced: false)
let textAlongsidePGS = Track(
    index: 1, format: .subRip, language: "eng", title: "Text",
    isDefault: false, isForced: false)
let admittedLargeInventory = Policy.admittedTracks(
    from: [textAlongsidePGS] + largePGSInventory,
    maximumPGSStreams: 4,
    preferredLanguages: ["ja"])
let admittedPGSIndices = admittedLargeInventory
    .filter { $0.format == .pgs }
    .map(\.index)
check("PGS admission: no more tracks are advertised than the OCR worker can serve",
      admittedPGSIndices.count == 4)
check("PGS admission: default, forced and preferred-language rows win deterministic capacity",
      Set(admittedPGSIndices).isSuperset(of: [20, 21, 22]))
check("PGS admission: the remaining slot goes to the earliest source row",
      admittedPGSIndices.contains(10))
check("PGS admission: admitted rows keep source order and every text row survives",
      admittedLargeInventory.first?.index == textAlongsidePGS.index
          && admittedPGSIndices == admittedPGSIndices.sorted())
check("PGS admission: zero bitmap capacity still preserves ordinary text subtitles",
      Policy.admittedTracks(
        from: [textAlongsidePGS] + largePGSInventory,
        maximumPGSStreams: 0,
        preferredLanguages: ["en"]) == [textAlongsidePGS])

let many = (0..<20).map {
    Track(index: $0, format: .subRip, language: "l\($0)", title: "T\($0)", isDefault: false, isForced: false)
}
check("renditions: twenty text tracks are not capped",
      Policy.renditions(from: many).count == 20)
check("renditions: all immutable source identities survive",
      Policy.renditions(from: many).map(\.sourceIndex) == Array(0..<20))

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

let withdrawn = Policy.survivors([english], withdrawing: [english.id])
let masterAfterFatalBacking = withdrawn.map(Policy.mediaTag) + [
    "#EXT-X-STREAM-INF:BANDWIDTH=1" + Policy.streamInfAttribute(renditionCount: withdrawn.count),
    "media.m3u8",
]
check("master withdrawal: a fatal optional backing fault removes its subtitle URI",
      !masterAfterFatalBacking.joined(separator: "\n").contains("subs"))
check("master withdrawal: primary video remains advertised after the last subtitle is removed",
      masterAfterFatalBacking.last == "media.m3u8"
          && !masterAfterFatalBacking[masterAfterFatalBacking.count - 2].contains("SUBTITLES="))
let withdrawalPair = Policy.renditions(from: [
    Track(index: 1, format: .subRip, language: "eng", title: "", isDefault: true, isForced: false),
    Track(index: 2, format: .subRip, language: "spa", title: "", isDefault: false, isForced: true),
])
check("master withdrawal: only the named fatal rendition is removed",
      Policy.survivors(withdrawalPair, withdrawing: [withdrawalPair[0].id]) == [withdrawalPair[1]])

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
let openPGSTiming = PGSOCRPolicy.cueTiming(
    packetStartSeconds: 10,
    packetDurationSeconds: 2,
    displayStartMilliseconds: 0,
    displayEndMilliseconds: UInt32.max)!
let openPGSCue = Policy.cue(
    payload: data("PGS"), format: .pgs,
    startSeconds: openPGSTiming.start, durationSeconds: openPGSTiming.duration)!
check("cue: PGS open-end sentinel never becomes the generic 30-second cap",
      openPGSCue == Cue(start: 10, end: 12, text: "PGS"))
let openPGSSegmentHits = (10..<50).filter { second in
    !Policy.cues(
        [openPGSCue], overlapping: Double(second), end: Double(second + 1)
    ).isEmpty
}
check("cue: a two-second open PGS packet reaches two one-second WebVTT segments, not thirty",
      openPGSSegmentHits == [10, 11])
let clearPGSTiming = PGSOCRPolicy.cueTiming(
    packetStartSeconds: 20,
    packetDurationSeconds: 0,
    displayStartMilliseconds: 0,
    displayEndMilliseconds: UInt32.max)!
check("cue: a PGS display awaiting its clear uses the bounded missing-duration fallback",
      Policy.cue(
        payload: data("CLEAR"), format: .pgs,
        startSeconds: clearPGSTiming.start, durationSeconds: clearPGSTiming.duration)
        == Cue(start: 20, end: 20 + Policy.fallbackCueDuration, text: "CLEAR"))
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

// MARK: - Cue normalization

// The shape that produced the report: an ASS animation run re-authored as short steps with IDENTICAL text,
// every one of which overlaps its neighbour once the override blocks are stripped.
let animationRun = (0..<10).map { Cue(start: Double($0) * 0.5, end: Double($0) * 0.5 + 2, text: "SIGN") }
check("normalize: a run of identical overlapping cues becomes ONE cue spanning the run",
      Policy.normalizedCues(animationRun) == [Cue(start: 0, end: 6.5, text: "SIGN")])
check("normalize: identical text that only TOUCHES is still coalesced",
      Policy.normalizedCues([Cue(start: 0, end: 2, text: "A"), Cue(start: 2, end: 4, text: "A")])
        == [Cue(start: 0, end: 4, text: "A")])
check("normalize: identical text with a real gap between it stays two cues",
      Policy.normalizedCues([Cue(start: 0, end: 2, text: "A"), Cue(start: 2.5, end: 4, text: "A")])
        == [Cue(start: 0, end: 2, text: "A"), Cue(start: 2.5, end: 4, text: "A")])
let intentionalNearCoincidentCues = [
    Cue(start: 10, end: 12, text: "<i>Listen</i> now"),
    Cue(start: 10.04, end: 12.03, text: "Listen now"),
    Cue(start: 10.08, end: 12.07, text: "<c.yellow>Listen now</c>"),
]
check("normalize: near-coincident italic sign, plain dialogue, and styled lyric remain distinct",
      Policy.normalizedCues(intentionalNearCoincidentCues).count == 3)
check("normalize: language and ruby markup remain distinct cue bodies",
      Policy.normalizedCues([
          Cue(start: 10, end: 12, text: "<lang en>Hello</lang>"),
          Cue(start: 10.04, end: 12.03, text: "<ruby>Hello<rt>Bonjour</rt></ruby>"),
      ]).count == 2)
let sameASSEvent = [
    Policy.cue(payload: data("42,0,Default,,0,0,0,,{\\pos(10,20)}Listen  now"), format: .ass,
               startSeconds: 10, durationSeconds: 2)!,
    Policy.cue(payload: data("42,0,Default,,0,0,0,,{\\pos(20,30)}Listen now"), format: .ass,
               startSeconds: 10.04, durationSeconds: 2)!,
]
check("normalize: visual records from one explicit ASS event collapse after flattening",
      Policy.normalizedCues(sameASSEvent).count == 1)
check("normalize: explicit ASS event identity is retained without changing visible cue text",
      sameASSEvent.first?.provenance != nil && sameASSEvent.first?.text == "Listen  now")
let separateASSEvents = [
    Policy.cue(payload: data("42,0,Default,,0,0,0,,{\\pos(10,20)}Listen now"), format: .ass,
               startSeconds: 10, durationSeconds: 2)!,
    Policy.cue(payload: data("43,1,Other,,20,30,40,scroll up,{\\pos(20,30)}Listen now"), format: .ass,
               startSeconds: 10.04, durationSeconds: 2)!,
]
check("normalize: distinct proven ASS events with identical post-strip text stay distinct",
      Policy.normalizedCues(separateASSEvents).count == 2
        && Policy.normalizedCues(separateASSEvents).allSatisfy { $0.provenance != nil })
check("normalize: distinct proven ASS events stay distinct and stable in every overlapping segment",
      Policy.cues(separateASSEvents, overlapping: 9, end: 11).count == 2
        && Policy.cues(separateASSEvents, overlapping: 10.5, end: 12).count == 2
        && Policy.normalizedCues(Policy.normalizedCues(separateASSEvents))
            == Policy.normalizedCues(separateASSEvents))
let separateASSCueIDs = Policy.normalizedCues(separateASSEvents).map {
    Policy.cueIdentifier(startSeconds: $0.start, endSeconds: $0.end, text: $0.text)
}
check("normalize: distinct ASS events retain stable distinct cue IDs across segment copies",
      Set(separateASSCueIDs).count == 2
        && Policy.webVTTDocument(cues: Policy.cues(separateASSEvents, overlapping: 9, end: 11),
                                 segmentStart: 9).contains(separateASSCueIDs[0])
        && Policy.webVTTDocument(cues: Policy.cues(separateASSEvents, overlapping: 10.5, end: 12),
                                 segmentStart: 10.5).contains(separateASSCueIDs[0]))
let anonymousASSEvents = [
    Policy.cue(payload: data("0,0,Default,,0,0,0,,Listen  now"), format: .ass,
               startSeconds: 10, durationSeconds: 2)!,
    Policy.cue(payload: data("0,0,Default,,0,0,0,,Listen now"), format: .ass,
               startSeconds: 10.04, durationSeconds: 2)!,
]
check("normalize: anonymous ASS ReadOrder zero never authorizes semantic dedupe",
      Policy.normalizedCues(anonymousASSEvents).count == 2
        && anonymousASSEvents.allSatisfy { $0.provenance == nil })
check("normalize: zero ASS ReadOrder retains legacy exact-text coalescing",
      Policy.normalizedCues([
          Policy.cue(payload: data("0,0,Default,,0,0,0,,Listen now"), format: .ass,
                     startSeconds: 10, durationSeconds: 2)!,
          Policy.cue(payload: data("0,1,Other,,20,30,40,scroll up,Listen now"), format: .ass,
                     startSeconds: 10.04, durationSeconds: 2)!,
      ]).count == 1)
let malformedASSEvents = [
    Policy.cue(payload: data("not-an-id,0,Default,,0,0,0,,Listen now"), format: .ass,
               startSeconds: 10, durationSeconds: 2)!,
    Policy.cue(payload: data("not-an-id,1,Other,,20,30,40,scroll up,Listen now"), format: .ass,
               startSeconds: 10.04, durationSeconds: 2)!,
]
check("normalize: malformed ASS ReadOrder retains legacy exact-text coalescing",
      Policy.normalizedCues(malformedASSEvents).count == 1
        && malformedASSEvents.allSatisfy { $0.provenance == nil })
check("normalize: same ASS event exactly at the 150ms timing boundary coalesces",
      Policy.normalizedCues([
          Policy.cue(payload: data("42,0,Default,,0,0,0,,Listen  now"), format: .ass,
                     startSeconds: 10, durationSeconds: 2)!,
          Policy.cue(payload: data("42,0,Default,,0,0,0,,Listen now"), format: .ass,
                     startSeconds: 10.15, durationSeconds: 2)!,
      ]).count == 1)
check("normalize: same ASS event just beyond the 150ms timing boundary stays distinct",
      Policy.normalizedCues([
          Policy.cue(payload: data("42,0,Default,,0,0,0,,Listen  now"), format: .ass,
                     startSeconds: 10, durationSeconds: 2)!,
          Policy.cue(payload: data("42,0,Default,,0,0,0,,Listen now"), format: .ass,
                     startSeconds: 10.150_001, durationSeconds: 2)!,
      ]).count == 2)
check("normalize: same ASS event outside the duplicate timing boundary stays distinct",
      Policy.normalizedCues([
          Policy.cue(payload: data("42,0,Default,,0,0,0,,Listen  now"), format: .ass,
                     startSeconds: 10, durationSeconds: 2)!,
          Policy.cue(payload: data("42,0,Default,,0,0,0,,Listen now"), format: .ass,
                     startSeconds: 10.2, durationSeconds: 2)!,
      ]).count == 2)
check("normalize: coalescing bridges a run through an interleaved different line",
      Policy.normalizedCues([Cue(start: 0, end: 2, text: "A"),
                             Cue(start: 0.5, end: 1.5, text: "B"),
                             Cue(start: 1, end: 3, text: "A")])
        == [Cue(start: 0, end: 3, text: "A"), Cue(start: 0.5, end: 1.5, text: "B")])
check("normalize: a lone cue is returned untouched",
      Policy.normalizedCues([Cue(start: 4, end: 9, text: "only")]) == [Cue(start: 4, end: 9, text: "only")])
check("normalize: an empty track normalizes to nothing rather than trapping",
      Policy.normalizedCues([]).isEmpty)

check("normalize: the simultaneity cap is above one, so overlap is allowed at all",
      Policy.maxSimultaneousCues >= 2)
let twoSpeakers = [Cue(start: 0, end: 3, text: "A"), Cue(start: 1, end: 4, text: "B")]
check("normalize: two overlapping speakers are preserved exactly",
      Policy.normalizedCues(twoSpeakers) == twoSpeakers)
let threeUpCap = twoSpeakers + [Cue(start: 2, end: 5, text: "C")]
check("normalize: a third simultaneous line is still under the cap and survives whole",
      Policy.normalizedCues(threeUpCap) == threeUpCap)

let stack = [
    Cue(start: 0, end: 20, text: "one"),
    Cue(start: 1, end: 20, text: "two"),
    Cue(start: 2, end: 20, text: "three"),
    Cue(start: 3, end: 20, text: "four"),
]
let capped = Policy.normalizedCues(stack)
check("normalize: a fourth simultaneous cue TRUNCATES the oldest instead of deleting it",
      capped.count == 4 && capped[0] == Cue(start: 0, end: 3, text: "one"))
check("normalize: the newest cue is never the one clipped",
      capped.last == Cue(start: 3, end: 20, text: "four"))
check("normalize: no instant of the capped result exceeds the cap",
      maxSimultaneous(capped) == Policy.maxSimultaneousCues)
check("normalize: the same fixture really was over the cap before normalization",
      maxSimultaneous(stack) > Policy.maxSimultaneousCues)
check("normalize: each further overlap clips the next oldest in turn",
      Policy.normalizedCues(stack + [Cue(start: 4, end: 20, text: "five")]).map(\.end)
        == [3, 4, 20, 20, 20])
let provenanceBeforeCap = Policy.cue(payload: data("42,0,Default,,0,0,0,,Provenance"), format: .ass,
                                     startSeconds: 0, durationSeconds: 20)!
let provenanceAfterCap = Policy.normalizedCues([
    provenanceBeforeCap,
    Cue(start: 1, end: 20, text: "two"),
    Cue(start: 2, end: 20, text: "three"),
    Cue(start: 3, end: 20, text: "four"),
]).first
check("normalize: pass-two truncation preserves ASS provenance",
      provenanceAfterCap?.end == 3 && provenanceAfterCap?.provenance == provenanceBeforeCap.provenance)

let simultaneous = (0..<4).map { Cue(start: 0, end: 5, text: "layer\($0)") }
let survivors = Policy.normalizedCues(simultaneous)
check("normalize: a cue with no room left to truncate is dropped, not emitted zero-length",
      survivors.count == 3 && !survivors.contains(where: { $0.text == "layer0" }))
check("normalize: every surviving cue still clears the minimum displayable duration",
      survivors.allSatisfy { $0.end - $0.start >= Policy.minCueDuration })
check("normalize: a remnant that still clears the minimum is kept rather than dropped",
      Policy.normalizedCues([Cue(start: 0, end: 5, text: "a"), Cue(start: 0, end: 5, text: "b"),
                             Cue(start: 0, end: 5, text: "c"),
                             Cue(start: Policy.minCueDuration, end: 5, text: "d")])
        .count == 4)

let messy = animationRun + stack + simultaneous + twoSpeakers
let normalizedOnce = Policy.normalizedCues(messy)
check("normalize: normalizing twice equals normalizing once",
      Policy.normalizedCues(normalizedOnce) == normalizedOnce)
check("normalize: a mixed track ends up inside the cap everywhere",
      maxSimultaneous(normalizedOnce) <= Policy.maxSimultaneousCues)
check("normalize: normalization never empties a track that had cues",
      !normalizedOnce.isEmpty)
check("normalize: input order does not change the result",
      Policy.normalizedCues(Array(messy.reversed())) == normalizedOnce)

// MARK: - Normalization memo (the served-path integration)

// The served path renders one document per (rendition, segment) off ONE cue array, so the normalization must
// run once per distinct array, not once per segment. These assert the memo's two obligations - never serve a
// stale result, never recompute a result it already holds - and that its output is the pure function's, so a
// memo that silently diverged (or one that never actually caches) fails here rather than in the field.
var memo = Policy.NormalizedCueCache()
let memoFirst = memo.normalized(messy)
check("memo: the first call runs the pure normalization and returns exactly its result",
      memo.recomputeCount == 1 && memoFirst == normalizedOnce)
let memoSegments = (0..<8).map { _ in memo.cues(messy, overlapping: 0, end: 3) }
check("memo: eight served segments off the same array recompute nothing",
      memo.recomputeCount == 1)
check("memo: a served window through the memo equals the un-memoized funnel",
      memoSegments.allSatisfy { $0 == Policy.cues(messy, overlapping: 0, end: 3) })
let appended = messy + [Cue(start: 900, end: 902, text: "late line")]
check("memo: an APPEND recomputes rather than serving the stale array",
      memo.normalized(appended) == Policy.normalizedCues(appended) && memo.recomputeCount == 2)
check("memo: the recomputed result is then itself cached",
      memo.normalized(appended) == Policy.normalizedCues(appended) && memo.recomputeCount == 2)
// Same COUNT, different content: the fingerprint carries the last cue's interval precisely so a same-length
// array from another rendition (or a re-created collector) misses instead of serving the wrong timeline.
let sameCountDifferentTail = messy + [Cue(start: 900, end: 903, text: "late line")]
check("memo: a same-count array with a different last cue is not treated as a hit",
      memo.normalized(sameCountDifferentTail) == Policy.normalizedCues(sameCountDifferentTail)
        && memo.recomputeCount == 3)
var emptyMemo = Policy.NormalizedCueCache()
check("memo: an empty track is memoized like any other, without trapping on the missing last cue",
      emptyMemo.normalized([]).isEmpty && emptyMemo.normalized([]).isEmpty && emptyMemo.recomputeCount == 1)

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

var pendingSettlement = Policy.SettlementState()
check("settlement: async work registers before the global watermark advances",
      pendingSettlement.registerPending(token: 101, timestamp: 3))
check("settlement: pending OCR caps the publishable frontier",
      pendingSettlement.observeGlobalTimestamp(20)
        && pendingSettlement.pendingCount == 1
        && pendingSettlement.settledBefore == 3
        && pendingSettlement.settledWindow(videoWindow: absoluteVideoWindow) == nil)
check("settlement: resolving after cue append opens the advanced frontier",
      pendingSettlement.resolvePending(token: 101)
        && !pendingSettlement.containsPending(token: 101)
        && pendingSettlement.settledWindow(videoWindow: absoluteVideoWindow)?.segments.map(\.id)
            == [40, 41, 42])
check("settlement: a token resolves once", !pendingSettlement.resolvePending(token: 101))

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
check("settlement: EOF without pending work finishes",
      eofSettlement.finish())
check("settlement: EOF settles the complete resident video window",
      eofSettlement.settledWindow(videoWindow: absoluteVideoWindow) == absoluteVideoWindow)
var pendingEOFSettlement = Policy.SettlementState()
_ = pendingEOFSettlement.registerPending(token: 202, timestamp: 3)
_ = pendingEOFSettlement.observeGlobalTimestamp(20)
check("settlement: EOF refuses to discard admitted OCR",
      !pendingEOFSettlement.finish()
        && pendingEOFSettlement.pendingCount == 1
        && !pendingEOFSettlement.hasReachedEOF)
check("settlement: unfinished OCR cannot publish ENDLIST",
      !Policy.mediaPlaylist(
          renditionID: 0,
          window: absoluteVideoWindow,
          ended: pendingEOFSettlement.hasReachedEOF,
          targetDuration: 4).contains("#EXT-X-ENDLIST"))
_ = pendingEOFSettlement.resolvePending(token: 202)
check("settlement: EOF publishes only after the admitted tail resolves",
      pendingEOFSettlement.finish()
        && pendingEOFSettlement.pendingCount == 0
        && pendingEOFSettlement.settledWindow(videoWindow: absoluteVideoWindow)
            == absoluteVideoWindow
        && Policy.mediaPlaylist(
            renditionID: 0,
            window: absoluteVideoWindow,
            ended: pendingEOFSettlement.hasReachedEOF,
            targetDuration: 4).contains("#EXT-X-ENDLIST"))
var emptyEOFSettlement = Policy.SettlementState()
_ = emptyEOFSettlement.finish()
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

// MARK: - Per-rendition cue truth

var permanentTextFailure = Policy.CueTruthState()
permanentTextFailure.observeRejectedPacket()
check("cue truth: one rejected packet remains recoverable before EOF",
      permanentTextFailure.status == .waitingForEOF)
permanentTextFailure.observeValidCue()
check("cue truth: a later valid cue proves the track available",
      permanentTextFailure.status == .available
        && permanentTextFailure.validCueCount == 1
        && permanentTextFailure.arrivedPacketCount == 2)
permanentTextFailure.settleAtEOF()
check("cue truth: EOF preserves a rendition that eventually produced a cue",
      permanentTextFailure.status == .available)

var ocrFailure = Policy.CueTruthState()
ocrFailure.observeRejectedPacket()
check("cue truth: an OCR miss remains recoverable for the whole live producer",
      ocrFailure.status == .waitingForEOF)
ocrFailure.settleAtEOF()
check("cue truth: an OCR-only failure becomes unavailable only at EOF",
      ocrFailure.status == .unavailable)

var multipleFailures = Policy.CueTruthState()
multipleFailures.observeRejectedPacket()
multipleFailures.observeRejectedPacket()
check("cue truth: any number of rejected packets remains provisional before EOF",
      multipleFailures.status == .waitingForEOF)
multipleFailures.settleAtEOF()
check("cue truth: EOF permanently settles an all-rejected track",
      multipleFailures.status == .unavailable)

var dialogueFree = Policy.CueTruthState()
check("cue truth: no packet during a dialogue-free interval is not a conversion failure",
      dialogueFree.status == .waitingForPacket)
dialogueFree.settleAtEOF()
check("cue truth: a track proven empty at EOF makes its source row unavailable",
      dialogueFree.status == .unavailable)

var lateRecovery = Policy.CueTruthState()
lateRecovery.observeRejectedPacket()
lateRecovery.settleAtEOF()
check("cue truth: an all-rejected row may publish unavailable at EOF",
      lateRecovery.status == .unavailable)
lateRecovery.observeValidCue()
check("cue truth: an out-of-order valid callback recovers a published unavailable row",
      lateRecovery.status == .available
        && lateRecovery.validCueCount == 1
        && lateRecovery.arrivedPacketCount == 2)
lateRecovery.settleAtEOF()
check("cue truth: EOF preserves a rendition that proved it can produce cues",
      lateRecovery.status == .available)

var untimedFailure = Policy.CueTruthState()
untimedFailure.observeRejectedPacket()
check("cue truth: an untimed rejection also waits for EOF",
      untimedFailure.status == .waitingForEOF)
untimedFailure.settleAtEOF()
check("cue truth: EOF settles an otherwise untimed permanent failure",
      untimedFailure.status == .unavailable)

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
let firstSpoolIdentity = Policy.cueIdentifier(startSeconds: 5, endSeconds: 8, text: "Crosses boundary")
let extendedSpoolIdentity = Policy.cueIdentifier(startSeconds: 5, endSeconds: 12, text: "Crosses boundary")
check("doc: extending an already-spooled cue end retains its native cue identity",
      firstSpoolIdentity == extendedSpoolIdentity)
check("doc: a changed cue start receives a distinct native cue identity",
      firstSpoolIdentity != Policy.cueIdentifier(startSeconds: 6, endSeconds: 12, text: "Crosses boundary"))
check("doc: a changed cue body receives a distinct native cue identity",
      firstSpoolIdentity != Policy.cueIdentifier(startSeconds: 5, endSeconds: 12, text: "Different line"))
let adjacentSegmentCue = Cue(start: 5, end: 8, text: "Crosses boundary")
let localSegment = parseVTT(Policy.webVTTDocument(
    cues: [adjacentSegmentCue], segmentStart: 6, segmentEnd: 12))
check("doc: a later HLS segment maps local zero to its exact 90 kHz media timestamp",
      localSegment.header.contains("X-TIMESTAMP-MAP=MPEGTS:540000,LOCAL:00:00:00.000"))
check("doc: a cue crossing a segment edge retains its full remaining interval",
      localSegment.cues.first?.time == "00:00:00.000 --> 00:00:02.000")
let nextLocalSegment = parseVTT(Policy.webVTTDocument(
    cues: [adjacentSegmentCue], segmentStart: 7, segmentEnd: 12))
check("doc: adjacent segment copies carry different timeline identities instead of duplicate absolute cues",
      nextLocalSegment.header != localSegment.header
        && nextLocalSegment.cues.first?.time == "00:00:00.000 --> 00:00:01.000")
let firstBoundaryFragment = parseVTT(Policy.webVTTDocument(
    cues: [adjacentSegmentCue], segmentStart: 0, segmentEnd: 6))
let secondBoundaryFragment = parseVTT(Policy.webVTTDocument(
    cues: [adjacentSegmentCue], segmentStart: 6, segmentEnd: 12))
check("doc: adjacent HLS fragments retain the full cue interval for fresh joiners",
      firstBoundaryFragment.cues.first?.time == "00:00:05.000 --> 00:00:08.000"
        && secondBoundaryFragment.cues.first?.time == "00:00:00.000 --> 00:00:02.000")
let wrappedSeconds = Double(8_589_934_592) / 90_000
let wrappedTimestamp = Policy.webVTTDocument(
    cues: [Cue(start: wrappedSeconds, end: wrappedSeconds + 1, text: "wrap")],
    segmentStart: wrappedSeconds,
    segmentEnd: wrappedSeconds + 2)
check("doc: MPEGTS timestamp map wraps at the 33-bit presentation timestamp boundary",
      wrappedTimestamp.contains("MPEGTS:0,LOCAL:00:00:00.000"))

// MARK: - Served documents, end to end

// A 14-step animation run straddling the segment boundary at 6s, with one real line of dialogue over it.
let animatedTrack = (0..<14).map { Cue(start: Double($0) * 0.5, end: Double($0) * 0.5 + 2, text: "STOP") }
    + [Cue(start: 5, end: 9, text: "Dialogue")]
check("served: the fixture really is a stack before normalization",
      animatedTrack.filter { $0.end > 0 && $0.start < 6 }.count == 13)
let firstServed = parseVTT(Policy.webVTTDocument(cues: Policy.cues(animatedTrack, overlapping: 0, end: 6)))
check("served: the animation run reaches the document as ONE cue over the dialogue",
      firstServed.cues.map(\.body) == ["STOP", "Dialogue"])
check("served: the coalesced cue carries the whole run's span",
      firstServed.cues.first?.time == "00:00:00.000 --> 00:00:08.500")
let secondServed = parseVTT(Policy.webVTTDocument(cues: Policy.cues(animatedTrack, overlapping: 6, end: 12)))
check("served: straddling cues are still repeated in the next segment (RFC 8216 section 3.5)",
      secondServed.cues.map(\.body) == ["STOP", "Dialogue"])
check("served: a segment served twice serves the same document",
      Policy.webVTTDocument(cues: Policy.cues(animatedTrack, overlapping: 0, end: 6))
        == Policy.webVTTDocument(cues: Policy.cues(animatedTrack, overlapping: 0, end: 6)))
check("served: no served document draws more than the cap at one instant",
      maxSimultaneous(Policy.cues(messy, overlapping: 0, end: 30)) <= Policy.maxSimultaneousCues)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
}
