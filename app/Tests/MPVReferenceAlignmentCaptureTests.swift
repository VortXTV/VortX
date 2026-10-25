/*
 * Controlled C-boundary acceptance for MPVReferenceAlignmentCapture.
 *
 * Root must compile this entry together with the complete current production
 * MPVReferenceAlignmentCapture.swift, the runner's generated non-framework Libmpv module map, and MPVCaptureFixture.c.  The C fixture emulates property
 * replies only; it is not live-player, real-libmpv, native-capability, media
 * container, or extractor proof.
 */
import Foundation
import Darwin
import Libmpv

// The runner extracts the two actual production declarations into a separate input.
@main
private enum MPVReferenceAlignmentCaptureTests {
    private enum Failure: Error, CustomStringConvertible {
        case check(String)

        var description: String {
            switch self {
            case .check(let name): return name
            }
        }
    }

    // These raw values are the deliberately finite cases in MPVCaptureFixture.c.
    private enum FixtureCase: Int32, CaseIterable, Sendable {
        case valid = 0
        case oldMissingProperty = 1
        case wrongSchema4 = 2
        case wrongSchema6 = 3
        case duplicateKey = 4
        case unknownKey = 5
        case numericBoolean = 6
        case oscFalse = 7
        case malformedIdentity = 8
        case nanosecondBounds = 9
        case sourceGenerationChanged = 10
        case entryChanged = 11
        case sidChanged = 12
        case invalidTiming = 13
        case customInput = 14
        case remoteInput = 15
        case builtinMKV = 16
        case externalTrack = 17
        case duplicateSelected = 18
        case ffIndexRange = 19
        case nilProperty = 20

        var label: String {
            switch self {
            case .valid: return "valid-5-map-per-type-id-collision-actual-ff-index"
            case .oldMissingProperty: return "old-missing-property"
            case .wrongSchema4: return "wrong-4-key-schema"
            case .wrongSchema6: return "wrong-6-key-schema"
            case .duplicateKey: return "duplicate-key"
            case .unknownKey: return "unknown-key"
            case .numericBoolean: return "numeric-boolean-type"
            case .oscFalse: return "osc-disabled-false"
            case .malformedIdentity: return "malformed-identity"
            case .nanosecondBounds: return "nanosecond-bounds"
            case .sourceGenerationChanged: return "source-generation-changed-final-reread"
            case .entryChanged: return "entry-changed-final-reread"
            case .sidChanged: return "sid-changed-final-reread"
            case .invalidTiming: return "invalid-timing"
            case .customInput: return "custom-input"
            case .remoteInput: return "remote-input"
            case .builtinMKV: return "builtin-mkv"
            case .externalTrack: return "external-track"
            case .duplicateSelected: return "duplicate-selected"
            case .ffIndexRange: return "ff-index-range"
            case .nilProperty: return "nil-property"
            }
        }
    }

    private static let expectedIdentity =
        "12:987654:123456:1700000000:123456789:1700000001:987654321"

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw Failure.check(name) }
    }

    private static func checkFixtureOwnership(_ handle: OpaquePointer, _ label: String) throws {
        try require(
            vortx_capture_fixture_node_allocations(handle) == vortx_capture_fixture_node_frees(handle),
            "\(label): node allocations were not all freed"
        )
        try require(
            vortx_capture_fixture_string_allocations(handle) == vortx_capture_fixture_string_frees(handle),
            "\(label): returned strings were not all freed"
        )
        try require(
            vortx_capture_fixture_allocations_balanced(handle) != 0,
            "\(label): fixture ownership counters are not balanced"
        )
    }

    private static func run(_ fixtureCase: FixtureCase) throws {
        try require(!Thread.isMainThread, "\(fixtureCase.label): capture ran on the main thread")
        guard let handle = vortx_capture_fixture_create(fixtureCase.rawValue) else {
            throw Failure.check("\(fixtureCase.label): fixture allocation failed")
        }
        defer { vortx_capture_fixture_destroy(handle) }

        let capture = MPVReferenceAlignmentCapture.read(handle, expectedEntryID: 41)
        if fixtureCase == .valid {
            guard let capture else {
                throw Failure.check("valid capture unexpectedly refused")
            }
            try require(capture.localFile.entryID == 41, "valid entry ID mismatch")
            try require(capture.localFile.generation == 7, "valid source generation mismatch")
            try require(capture.localFile.identity == expectedIdentity, "valid identity mismatch")
            try require(capture.input == "/private/var/tmp/vortx-capture-local.mkv", "valid input mismatch")
            try require(capture.trackID == 1, "valid per-type subtitle ID mismatch")
            try require(capture.streamIndex == 37, "valid AVStream index was replaced by row ordinal")
            try require(capture.timestampOrigin == 100.0, "valid timestamp origin mismatch")
        } else {
            try require(capture == nil, "\(fixtureCase.label): malformed capture was accepted")
        }
        try checkFixtureOwnership(handle, fixtureCase.label)
    }

    private static func runAll() throws {
        for fixtureCase in FixtureCase.allCases {
            try run(fixtureCase)
        }
    }

    static func main() async {
        do {
            // A real detached utility task owns every check.  This avoids a
            // synchronous queue wrapper that could execute on the caller.
            let worker = Task.detached(priority: .utility) {
                try Self.runAll()
            }
            try await worker.value
            print("PASS 21 capture source cases; controlled C replies and balanced API allocations")
        } catch {
            FileHandle.standardError.write(
                Data("FAIL MPVReferenceAlignmentCapture recovery acceptance: \(error)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
