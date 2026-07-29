// Standalone contract tests for ordered Trakt lifecycle delivery and refresh throttling.
//
// Run with:
//   swiftc -o /tmp/trakt-lifecycle-policy \
//     app/SourcesShared/TraktScrobbleProgressPolicy.swift \
//     app/Tests/TraktScrobbleProgressPolicyTests.swift && /tmp/trakt-lifecycle-policy

import Foundation

@MainActor var failures: [String] = []
@MainActor var checks = 0

@MainActor
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

actor LifecycleRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@main
struct TraktScrobbleProgressPolicyTestRunner {
    @MainActor
    static func main() async {
        let queue = TraktScrobbleLifecycleQueue()
        let recorder = LifecycleRecorder()

        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(80))
            await recorder.append("start")
        }
        queue.enqueue {
            await recorder.append("pause")
        }
        queue.enqueue {
            await recorder.append("stop")
        }
        await queue.drain()
        expect(await recorder.snapshot() == ["start", "pause", "stop"],
               "a slow start must still finish before later pause and stop operations")

        expect(!TraktPlaybackRefreshThrottlePolicy.shouldArm(
            signedIn: false, generationMatches: true),
               "a signed-out refresh must not arm the five-minute throttle")
        expect(!TraktPlaybackRefreshThrottlePolicy.shouldArm(
            signedIn: true, generationMatches: false),
               "a superseded account generation must not arm the throttle")
        expect(TraktPlaybackRefreshThrottlePolicy.shouldArm(
            signedIn: true, generationMatches: true),
               "a current signed-in refresh may arm the throttle")

        if failures.isEmpty {
            print("PASS: \(checks) Trakt lifecycle and refresh-throttle checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
