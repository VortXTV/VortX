import XCTest

/// Pure model assertions, not AVFoundation/mpv rendering or device proof.
final class PlaybackMetadataFactsTests: XCTestCase {
    func testWideCinemaUsesEncodedWidthAndNeverFilename() {
        let facts = PlaybackMetadataFacts(width: 3840, height: 1600)
        XCTAssertEqual(facts.pills.first?.text, "4K")
        XCTAssertTrue(PlaybackMetadataFacts(height: 2160).pills.isEmpty)
    }
    func testOnlyObservedTransferProducesHDRPill() {
        XCTAssertEqual(PlaybackMetadataFacts.mpvRange("pq"), .pq)
        XCTAssertEqual(PlaybackMetadataFacts.mpvRange("hlg"), .hlg)
        XCTAssertEqual(PlaybackMetadataFacts.mpvRange("Dolby Vision filename"), .unknown)
        XCTAssertTrue(PlaybackMetadataFacts(dynamicRange: .unknown).pills.isEmpty)
        XCTAssertEqual(PlaybackMetadataFacts(dynamicRange: .pq).pills.first?.text, "HDR")
    }
    func testSelectedAudioLanguageCodecAndCountAreOneHonestPill() {
        let facts = PlaybackMetadataFacts(audioSelected: true, audioLanguage: "en",
            audioCodec: "ec-3", audioChannels: 6)
        let language = Locale.current.localizedString(forLanguageCode: "en") ?? "EN"
        XCTAssertEqual(facts.pills.first?.text, "\(language) · EAC3 · 6ch")
        XCTAssertFalse(facts.pills.contains { $0.text.contains("Atmos") || $0.text.contains("5.1") })
        XCTAssertTrue(PlaybackMetadataFacts(audioLanguage: "fr", audioCodec: "aac", audioChannels: 8).pills.isEmpty)
    }
    func testUnknownAudioStaysNeutralWithoutInventedLanguageOrLayout() {
        XCTAssertEqual(PlaybackMetadataFacts(audioSelected: true, audioLanguage: "und",
            audioCodec: "Dolby Atmos filename", audioChannels: -1).pills.first?.text, "Audio")
        XCTAssertEqual(PlaybackMetadataFacts.codecLabel("audio/eac3-joc"), "EAC3")
    }
    func testAudioSelectionRequiresTheSamePresentRowAndBothSamples() {
        XCTAssertTrue(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: 0, beforeID: 0, afterID: 0))
        XCTAssertTrue(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: 8, beforeID: 8, afterID: 8))
        XCTAssertFalse(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: nil, beforeID: 1, afterID: 1))
        XCTAssertFalse(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: 1, beforeID: nil, afterID: 1))
        XCTAssertFalse(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: 1, beforeID: 1, afterID: nil))
        XCTAssertFalse(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: -1, beforeID: -1, afterID: -1))
        XCTAssertFalse(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: 1, beforeID: 2, afterID: 2))
        XCTAssertFalse(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: 2, beforeID: 1, afterID: 2))
        XCTAssertFalse(PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: 1, beforeID: 1, afterID: 2))
    }
    func testFreshPhysicalLoadHasNoPriorFacts() {
        var facts = PlaybackMetadataFacts(width: 3840, height: 2160,
            dynamicRange: .dolbyVision, audioSelected: true, audioLanguage: "ja", audioCodec: "aac", audioChannels: 2)
        XCTAssertEqual(facts.pills.count, 3)
        facts = PlaybackMetadataFacts()
        XCTAssertTrue(facts.pills.isEmpty)
    }
}
