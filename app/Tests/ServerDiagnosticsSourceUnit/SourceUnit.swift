import Foundation
import os

private struct SourceUnitFailure: Error {
    let message: String
}

private final class ReleaseProbe: Sendable {
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

@main
private struct ServerDiagnosticsSourceUnit {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SourceUnitFailure(message: message) }
    }

    private static func installReleaseProbe(_ releases: OSAllocatedUnfairLock<Int>) {
        let probe = ReleaseProbe {
            let replacementVisible = ServerDiagnostics.status() == "replacement"
            releases.withLock { $0 += replacementVisible ? 1 : 100 }
        }
        ServerDiagnostics.register(
            status: { withExtendedLifetime(probe) { "retained-old-provider" } },
            logTail: { _ in [] }
        )
    }

    static func main() async throws {
        print("start group=empty")
        try require(ServerDiagnostics.status() == nil, "unregistered status must be nil")
        try require(ServerDiagnostics.logTail(4).isEmpty, "unregistered tail must be empty")
        print("pass group=empty")

        print("start group=registration")
        ServerDiagnostics.register(status: { "first" }, logTail: { ["first:\($0)"] })
        try require(ServerDiagnostics.status() == "first", "first status")
        try require(ServerDiagnostics.logTail(-3) == ["first:-3"], "tail argument must be forwarded unchanged")
        ServerDiagnostics.register(status: { "second" }, logTail: { ["second:\($0)"] })
        try require(ServerDiagnostics.status() == "second", "registration must replace status")
        try require(ServerDiagnostics.logTail(7) == ["second:7"], "registration must replace tail")
        print("pass group=registration")

        print("start group=reentrant-providers")
        ServerDiagnostics.register(status: {
            ServerDiagnostics.register(status: { "after-status" }, logTail: { ["after-status:\($0)"] })
            return "before-status"
        }, logTail: { _ in [] })
        try require(ServerDiagnostics.status() == "before-status", "current invocation retains its copied provider")
        try require(ServerDiagnostics.status() == "after-status", "status callback may register without a held registry lock")
        ServerDiagnostics.register(status: { "before-tail" }, logTail: { lines in
            ServerDiagnostics.register(status: { "after-tail" }, logTail: { ["after-tail:\($0)"] })
            return ["before-tail:\(lines)"]
        })
        try require(ServerDiagnostics.logTail(2) == ["before-tail:2"], "current tail invocation retains its provider")
        try require(ServerDiagnostics.status() == "after-tail", "tail callback may register without a held registry lock")
        try require(ServerDiagnostics.logTail(5) == ["after-tail:5"], "replacement tail remains live")
        print("pass group=reentrant-providers")

        print("start group=retired-captures")
        let releases = OSAllocatedUnfairLock(initialState: 0)
        installReleaseProbe(releases)
        ServerDiagnostics.register(status: { "replacement" }, logTail: { _ in [] })
        try require(releases.withLock { $0 } == 1, "retired capture must release outside the lock after replacement is visible")
        print("pass group=retired-captures")

        print("start group=concurrent-registry")
        let valid = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for lane in 0..<8 {
                group.addTask {
                    for iteration in 0..<64 {
                        let tag = "lane:\(lane):\(iteration)"
                        ServerDiagnostics.register(status: { tag }, logTail: { ["\(tag):tail:\($0)"] })
                        guard let status = ServerDiagnostics.status(), status.hasPrefix("lane:"),
                              let tail = ServerDiagnostics.logTail(3).first,
                              tail.hasPrefix("lane:"), tail.hasSuffix(":tail:3") else { return false }
                    }
                    return true
                }
            }
            var valid = true
            for await lanePassed in group { valid = lanePassed && valid }
            return valid
        }
        try require(valid, "concurrent values must come from registered providers")
        print("pass group=concurrent-registry")
        print("ServerDiagnostics Swift6 production source unit: 5/5 passed")
    }
}
