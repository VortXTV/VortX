import Foundation
import Darwin

// Explicit RAM-only UIKit seam. This does not establish real UIKit availability,
// executor annotations, background execution, or an actual OS grant duration.
struct UIBackgroundTaskIdentifier: RawRepresentable, Hashable, Sendable {
    let rawValue: Int
    static let invalid = Self(rawValue: 0)
}

@MainActor private func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@MainActor final class UIApplication {
    typealias Expiration = @MainActor @Sendable () -> Void
    static let shared = UIApplication()

    private(set) var began: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var active: Set<UIBackgroundTaskIdentifier> = []
    private(set) var names: [String?] = []
    private var expirations: [UIBackgroundTaskIdentifier: Expiration] = [:]
    private var nextIdentifier = 1
    var nextResult: UIBackgroundTaskIdentifier?
    var duringAcquire: (@MainActor (UIBackgroundTaskIdentifier) -> Void)?
    var duringEnd: (@MainActor (UIBackgroundTaskIdentifier) -> Void)?

    func reset() {
        require(active.isEmpty, "previous case leaked an acquired RAM grant")
        began = []; ended = []; names = []; expirations = [:]
        nextIdentifier = 1; nextResult = nil
        duringAcquire = nil; duringEnd = nil
    }

    func beginBackgroundTask(
        withName name: String?,
        expirationHandler handler: Expiration?
    ) -> UIBackgroundTaskIdentifier {
        let identifier = nextResult ?? UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
        nextResult = nil
        nextIdentifier += 1
        began.append(identifier); names.append(name)
        if let handler { expirations[identifier] = handler }
        if identifier != .invalid {
            require(active.insert(identifier).inserted, "RAM grant identifier reused while active")
        }
        // A one-shot synchronous hook can expire or reenter before the ID is returned.
        let hook = duringAcquire
        duringAcquire = nil
        hook?(identifier)
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        require(identifier != .invalid, "invalid RAM grant was ended")
        require(active.remove(identifier) != nil, "RAM grant ended more than once")
        ended.append(identifier)
        let hook = duringEnd
        duringEnd = nil
        hook?(identifier)
    }

    func expire(_ identifier: UIBackgroundTaskIdentifier) {
        guard let expiration = expirations[identifier] else {
            require(false, "no original expiration callback for RAM grant")
            return
        }
        // Intentionally retained after end so stale/repeated OS delivery is testable.
        expiration()
    }

    var beginIDs: [Int] { began.map(\.rawValue) }
    var endIDs: [Int] { ended.map(\.rawValue) }
}

@main @MainActor enum LoopbackPlaybackAssertionTests {
    private static let loopback = URL(string: "http://127.0.0.1:49170/stream")!
    private static let app = UIApplication.shared
    private static var groups = 0

    private static func finishGroup(_ name: String) {
        require(app.active.isEmpty, "\(name): acquired RAM grant leaked")
        require(app.names.allSatisfy { $0 == "vortx.playback.loopback" }, "\(name): assertion name changed")
        groups += 1
        print("PASS group \(groups): \(name)")
    }

    static func main() {
        directNoOp()
        realFoundationLoopbackHosts()
        overlapUnderflowAndBalance()
        invalidGrant()
        expirationAtOverlappingDepth()
        staleExpirationCannotRetireNewGrant()
        synchronousExpirationDuringAcquire()
        reentrantEndAndBeginDuringAcquire()
        stateClearedBeforeEndCallback()
        require(groups == 9, "exactly nine maintained behavior groups must execute")
        print("PASS loopback assertion: 9 groups, 4 host spellings; whole actual state with RAM UIKit only")
    }

    private static func directNoOp() {
        app.reset()
        LoopbackPlaybackAssertion.begin(for: URL(string: "https://cdn.example.invalid/video.mp4")!)
        LoopbackPlaybackAssertion.begin(for: URL(fileURLWithPath: "/not-read/direct.mp4"))
        LoopbackPlaybackAssertion.end(); LoopbackPlaybackAssertion.end()
        require(app.began.isEmpty && app.ended.isEmpty, "direct/file URLs must not acquire or end grants")
        finishGroup("direct URL no-op")
    }

    private static func realFoundationLoopbackHosts() {
        // These are REAL Foundation URL values, never a stubbed/normalized host getter.
        for spelling in ["127.0.0.1", "localhost", "LOCALHOST", "[::1]"] {
            app.reset()
            let url = URL(string: "http://\(spelling):49170/stream")!
            LoopbackPlaybackAssertion.begin(for: url)
            require(app.beginIDs == [1], "real Foundation loopback host \(spelling), host=\(String(describing: url.host))")
            LoopbackPlaybackAssertion.end()
            require(app.endIDs == [1], "loopback host grant must be balanced")
        }
        finishGroup("three loopback forms and case-insensitive localhost")
    }

    private static func overlapUnderflowAndBalance() {
        app.reset()
        LoopbackPlaybackAssertion.end(); LoopbackPlaybackAssertion.end()
        LoopbackPlaybackAssertion.begin(for: loopback)
        LoopbackPlaybackAssertion.begin(for: loopback)
        LoopbackPlaybackAssertion.begin(for: loopback)
        require(app.beginIDs == [1], "overlapping begins must share one grant")
        LoopbackPlaybackAssertion.end(); LoopbackPlaybackAssertion.end()
        require(app.ended.isEmpty, "positive remaining depth must retain grant")
        LoopbackPlaybackAssertion.end()
        LoopbackPlaybackAssertion.end(); LoopbackPlaybackAssertion.end()
        require(app.endIDs == [1], "last end exactly once; underflow is inert")
        LoopbackPlaybackAssertion.begin(for: loopback); LoopbackPlaybackAssertion.end()
        require(app.beginIDs == [1, 2] && app.endIDs == [1, 2], "balanced next lifetime must acquire a fresh grant")
        finishGroup("depth overlap, underflow and balancing")
    }

    private static func invalidGrant() {
        app.reset()
        app.nextResult = .invalid
        LoopbackPlaybackAssertion.begin(for: loopback)
        LoopbackPlaybackAssertion.begin(for: loopback)
        require(app.beginIDs == [0], "invalid acquisition still belongs to original depth lifetime")
        LoopbackPlaybackAssertion.end(); LoopbackPlaybackAssertion.end(); LoopbackPlaybackAssertion.end()
        require(app.ended.isEmpty, "invalid identifier must never be ended")
        LoopbackPlaybackAssertion.begin(for: loopback); LoopbackPlaybackAssertion.end()
        require(app.beginIDs == [0, 2] && app.endIDs == [2], "balanced invalid lifetime must permit next grant")
        finishGroup("invalid OS grant")
    }

    private static func expirationAtOverlappingDepth() {
        app.reset()
        LoopbackPlaybackAssertion.begin(for: loopback); LoopbackPlaybackAssertion.begin(for: loopback)
        app.expire(UIBackgroundTaskIdentifier(rawValue: 1))
        require(app.endIDs == [1], "OS expiration must end grant at depth greater than one")
        LoopbackPlaybackAssertion.end(); LoopbackPlaybackAssertion.end()
        require(app.endIDs == [1], "expiration must reset all depth, without duplicate end")
        LoopbackPlaybackAssertion.begin(for: loopback); LoopbackPlaybackAssertion.end()
        require(app.beginIDs == [1, 2] && app.endIDs == [1, 2], "expiration must permit a fresh lifetime")
        finishGroup("OS expiration at overlapping depth")
    }

    private static func staleExpirationCannotRetireNewGrant() {
        app.reset()
        LoopbackPlaybackAssertion.begin(for: loopback); LoopbackPlaybackAssertion.end()
        LoopbackPlaybackAssertion.begin(for: loopback)
        app.expire(UIBackgroundTaskIdentifier(rawValue: 1))
        require(app.endIDs == [1] && app.active == [UIBackgroundTaskIdentifier(rawValue: 2)], "old expiration must not retire new grant")
        LoopbackPlaybackAssertion.end()
        require(app.endIDs == [1, 2], "new grant depth must survive stale expiration")
        finishGroup("stale old expiration after new begin")
    }

    private static func synchronousExpirationDuringAcquire() {
        app.reset()
        app.duringAcquire = { identifier in app.expire(identifier) }
        LoopbackPlaybackAssertion.begin(for: loopback)
        require(app.beginIDs == [1] && app.endIDs == [1], "synchronously expired returned ID must be ended exactly once")
        LoopbackPlaybackAssertion.end()
        require(app.endIDs == [1], "end after synchronous expiration is inert")
        LoopbackPlaybackAssertion.begin(for: loopback); LoopbackPlaybackAssertion.end()
        require(app.endIDs == [1, 2], "synchronous expiration must not poison later grant")
        finishGroup("synchronous expiration during acquisition")
    }

    private static func reentrantEndAndBeginDuringAcquire() {
        app.reset()
        app.duringAcquire = { _ in
            LoopbackPlaybackAssertion.end()
            LoopbackPlaybackAssertion.begin(for: loopback)
        }
        LoopbackPlaybackAssertion.begin(for: loopback)
        require(app.beginIDs == [1, 2] && app.endIDs == [1], "retired original acquisition must end only its returned ID")
        require(app.active == [UIBackgroundTaskIdentifier(rawValue: 2)], "reentrant replacement must retain its own grant")
        LoopbackPlaybackAssertion.end()
        require(app.endIDs == [1, 2], "new lifetime must remain separately balanced")
        finishGroup("reentrant end plus new begin during acquisition")
    }

    private static func stateClearedBeforeEndCallback() {
        app.reset()
        LoopbackPlaybackAssertion.begin(for: loopback)
        app.duringEnd = { retiring in
            app.expire(retiring)
            LoopbackPlaybackAssertion.begin(for: loopback)
        }
        LoopbackPlaybackAssertion.end()
        require(app.beginIDs == [1, 2] && app.endIDs == [1], "retiring state must be cleared before UIKit end can reenter")
        require(app.active == [UIBackgroundTaskIdentifier(rawValue: 2)], "old end callback must not overwrite new grant")
        LoopbackPlaybackAssertion.end()
        require(app.endIDs == [1, 2], "replacement from end callback must balance exactly once")
        finishGroup("state cleared before end callback")
    }
}
