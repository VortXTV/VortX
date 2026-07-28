// Executable harness for reusable Metal capture texture ownership.
//
//   xcrun swiftc -swift-version 5 -strict-concurrency=complete -suppress-warnings \
//     -target arm64-apple-macos14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//     -o /tmp/metal-capture-lease-tests \
//     app/Sources/Player/MetalLayer.swift app/Tests/MetalCaptureLeaseTests.swift \
//     && /tmp/metal-capture-lease-tests

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@MainActor @main
private enum MetalCaptureLeaseTests {
    static func main() {
        let state = MetalCaptureLeaseState()

        let first = state.acquire()
        check("first capture acquires ownership", first != nil)
        check("second capture waits while the texture is leased", state.acquire() == nil)

        state.release(token: UInt64.max)
        check("foreign release cannot unlock the active capture", state.acquire() == nil)

        if let first {
            state.release(token: first)
        }
        let second = state.acquire()
        check("release admits the next pending capture", second != nil)

        if let first {
            state.release(token: first)
        }
        check("stale release cannot unlock a newer capture", state.acquire() == nil)

        if let second {
            state.release(token: second)
        }
        check("current release restores availability", state.acquire() != nil)

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}
