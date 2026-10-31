/*
 * Controlled C-boundary acceptance for the v2 hidden-reference capture.
 * Compile this entry with the complete maintained MPVReferenceAlignmentCapture
 * afterimage, the runner's real Libmpv module map and MPVCaptureFixture.v2.c.
 * It is not live-player, native-producer, media-container or device proof.
 */
import Foundation
import Darwin
import Libmpv

@main private enum MPVReferenceAlignmentCaptureTestsV2 {
    private enum Failure: Error, CustomStringConvertible {
        case check(String)
        var description: String { if case .check(let name) = self { return name }; return "fixture failure" }
    }
    private enum FixtureCase: Int32, CaseIterable, Sendable {
        case valid = 0, oldMissingProperty = 1, wrongSchema4 = 2, wrongSchema6 = 3,
             duplicateKey = 4, unknownKey = 5, numericBoolean = 6, oscFalse = 7,
             malformedIdentity = 8, nanosecondBounds = 9, sourceGenerationChanged = 10,
             entryChanged = 11, sidChanged = 12, invalidTiming = 13, customInput = 14,
             remoteInput = 15, builtinMKV = 16, externalTrack = 17, duplicateSelected = 18,
             ffIndexRange = 19, nilProperty = 20, snapshotWrongVersion = 21,
             snapshotMissingField = 22, hiddenExternalPrimary = 23,
             trackListCommandMismatch = 24, snapshotStreamMismatch = 25,
             snapshotOffExternal = 26
        var label: String { String(describing: self) }
    }
    private static let expectedIdentity = "12:987654:123456:1700000000:123456789:1700000001:987654321"
    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw Failure.check(name) }
    }
    private static func ownership(_ handle: OpaquePointer, _ label: String) throws {
        try require(vortx_capture_fixture_v2_node_allocations(handle) == vortx_capture_fixture_v2_node_frees(handle), "\(label): node ownership")
        try require(vortx_capture_fixture_v2_string_allocations(handle) == vortx_capture_fixture_v2_string_frees(handle), "\(label): string ownership")
        try require(vortx_capture_fixture_v2_allocations_balanced(handle) != 0, "\(label): allocation balance")
    }
    private static func run(_ fixtureCase: FixtureCase) throws {
        try require(!Thread.isMainThread, "\(fixtureCase.label): capture ran on main")
        guard let handle = vortx_capture_fixture_v2_create(fixtureCase.rawValue) else { throw Failure.check("\(fixtureCase.label): allocation") }
        defer { vortx_capture_fixture_v2_destroy(handle) }
        let capture = MPVReferenceAlignmentCapture.read(handle, expectedEntryID: 41)
        let valid = fixtureCase == .valid || fixtureCase == .hiddenExternalPrimary
        if valid {
            guard let capture else { throw Failure.check("\(fixtureCase.label): v2 capture refused") }
            try require(capture.localFile.entryID == 41, "\(fixtureCase.label): entry")
            try require(capture.localFile.generation == 7, "\(fixtureCase.label): source generation")
            try require(capture.localFile.identity == expectedIdentity, "\(fixtureCase.label): identity")
            try require(capture.input == "/private/var/tmp/vortx-capture-local.mkv", "\(fixtureCase.label): local input")
            try require(capture.trackID == 12 && capture.streamIndex == 17, "\(fixtureCase.label): actual command index")
            try require(capture.timestampOrigin == 100.0, "\(fixtureCase.label): origin")
            guard let snapshot = MPVOwnedSubtitleTransport.snapshot(handle) else { throw Failure.check("\(fixtureCase.label): v2 snapshot") }
            try require(snapshot.referenceSID == 12 && snapshot.referenceCommandIndex == 17 && snapshot.referenceStreamIndex == 37,
                        "\(fixtureCase.label): separated reference identity")
            try require(snapshot.primaryVisible == false, "\(fixtureCase.label): hidden primary visibility")
            if fixtureCase == .hiddenExternalPrimary {
                try require(snapshot.primarySID == 77 && snapshot.primaryExternal, "hidden external primary witness")
            } else {
                try require(snapshot.primarySID == 0 && !snapshot.primaryExternal, "Off primary witness")
            }
        } else if fixtureCase == .trackListCommandMismatch {
            // The raw MPV sh_stream.index (37) is allowed to differ from the
            // lavf/AVStream command index (17).  The negative is specifically
            // a track-list ff-index that no longer agrees with the independent
            // reference-command-index, not raw-vs-command inequality.
            try require(capture == nil, "(trackListCommandMismatch): mismatched actual ff-index accepted")
        } else if fixtureCase == .snapshotWrongVersion || fixtureCase == .snapshotMissingField || fixtureCase == .snapshotOffExternal {
            // Snapshot-only negatives exercise the hidden-reference decoder directly;
            // capture admission may reject them earlier or may remain independently valid.
            try require(MPVOwnedSubtitleTransport.snapshot(handle) == nil,
                        "\(fixtureCase.label): malformed snapshot accepted")
        } else if fixtureCase == .snapshotStreamMismatch {
            try require(capture == nil, "(snapshotStreamMismatch): stale raw stream accepted")
            guard let witnessHandle = vortx_capture_fixture_v2_create(fixtureCase.rawValue) else {
                throw Failure.check("(snapshotStreamMismatch): witness allocation")
            }
            defer { vortx_capture_fixture_v2_destroy(witnessHandle) }
            guard let first = MPVOwnedSubtitleTransport.snapshot(witnessHandle),
                  let second = MPVOwnedSubtitleTransport.snapshot(witnessHandle) else {
                throw Failure.check("(snapshotStreamMismatch): snapshot unavailable")
            }
            try require(first.referenceCommandIndex == 17 && first.referenceStreamIndex == 37,
                        "(snapshotStreamMismatch): initial independent indexes")
            try require(second.referenceCommandIndex == 17 && second.referenceStreamIndex == 36,
                        "(snapshotStreamMismatch): stale raw stream witness")
            try require(first.referenceStreamIndex != second.referenceStreamIndex,
                        "(snapshotStreamMismatch): double-read mismatch accepted")
            try ownership(witnessHandle, fixtureCase.label + " witness")
        } else {
            try require(capture == nil, "\(fixtureCase.label): malformed v2 capture accepted")
        }
        try ownership(handle, fixtureCase.label)
    }
    private static func runAll() throws { for fixtureCase in FixtureCase.allCases { try run(fixtureCase) } }
    static func main() async {
        do {
            try await Task.detached(priority: .utility) { try Self.runAll() }.value
            print("PASS 27 v2 hidden-reference capture cases, Off/external separation and balanced C ownership")
        } catch {
            FileHandle.standardError.write(Data("FAIL v2 MPVReferenceAlignmentCapture: \(error)\n".utf8)); exit(EXIT_FAILURE)
        }
    }
}
