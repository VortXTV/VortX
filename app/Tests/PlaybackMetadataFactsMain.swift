import Foundation
import XCTest
import Darwin

/// The existing supervised source-unit lane executes real XCTest discovery, not copied assertions.
@main enum PlaybackMetadataFactsMain {
    @MainActor static func main() {
        let names = [
            "testWideCinemaUsesEncodedWidthAndNeverFilename",
            "testOnlyObservedTransferProducesHDRPill",
            "testSelectedAudioLanguageCodecAndCountAreOneHonestPill",
            "testUnknownAudioStaysNeutralWithoutInventedLanguageOrLayout",
            "testFreshPhysicalLoadHasNoPriorFacts",
            "testAudioSelectionRequiresTheSamePresentRowAndBothSamples"
        ]
        let suite = XCTestSuite(forTestCaseClass: PlaybackMetadataFactsTests.self)
        guard suite.testCaseCount == names.count,
              names.allSatisfy({ name in suite.tests.filter { $0.name.contains(name) }.count == 1 }) else {
            print("FAIL metadata XCTest discovery mismatch"); exit(91)
        }
        suite.run()
        guard let run = suite.testRun, run.hasSucceeded, run.executionCount == names.count,
              run.skipCount == 0, run.totalFailureCount == 0 else {
            print("FAIL metadata XCTest execution"); exit(1)
        }
        print("PASS actual metadata model: \(names.count) XCTest cases; not player adapter or device proof")
    }
}
