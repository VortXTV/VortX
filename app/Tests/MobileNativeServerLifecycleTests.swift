import Foundation

/// Fake only the ABI. The lifecycle, queue, publication and guards come from the production file.
private final class ServerFixture: @unchecked Sendable {
    static let shared = ServerFixture()
    let lock = NSLock()
    var nextHandle = 1
    var active = Set<Int>()
    var events: [String] = []

    func start(_ raw: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
        let config = try! JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as! [String: Any]
        precondition(config["bind"] as? String == "127.0.0.1" && config["port"] as? Int == 0)
        precondition((config["serverHome"] as! String).hasPrefix(ProcessInfo.processInfo.environment["VORTX_TEST_NATIVE_CACHES"]!))
        return lock.withLock {
            let id = nextHandle
            nextHandle += 1
            precondition(active.insert(id).inserted)
            events.append("start:\(id)")
            return UnsafeMutableRawPointer(bitPattern: id)!
        }
    }

    func stop(_ raw: UnsafeMutableRawPointer) {
        lock.withLock {
            let id = Int(bitPattern: raw)
            precondition(active.remove(id) != nil, "Server handle was freed twice")
            events.append("stop:\(id)")
        }
    }
}

func vortx_server_start(_ raw: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? { ServerFixture.shared.start(raw) }
func vortx_server_port(_ handle: UnsafeMutableRawPointer) -> UInt16 { 49170 }
func vortx_server_base_url(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? { nil }
func vortx_server_stop(_ handle: UnsafeMutableRawPointer) { ServerFixture.shared.stop(handle) }
func vortx_string_free(_ value: UnsafeMutablePointer<CChar>) {}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }

@main enum MobileNativeServerLifecycleTests {
    static func main() {
        precondition(VortxNativeServerFlag.isOn && VortxNativeServerFlag.isSupported)
        for cycle in 0..<64 {
            VortxNativeServer.startIfNeeded()
            VortxNativeServer.startIfNeeded() // duplicate foreground startup is idempotent
            VortxNativeServer.stopOnBackground()
            VortxNativeServer.startIfNeeded() // quick foreground must follow the background stop
            VortxNativeServer.stop() // queue barrier plus final disposal
            let first = cycle * 2 + 1
            let events = ServerFixture.shared.lock.withLock { ServerFixture.shared.events }
            precondition(Array(events.suffix(4)) == ["start:\(first)", "stop:\(first)", "start:\(first + 1)", "stop:\(first + 1)"],
                         "Rapid background/foreground lost FIFO lifecycle order")
            precondition(VortxNativeServer.publishedPort == nil && VortxNativeServer.publishedBaseURL == nil)
        }
        VortxNativeServer.stop() // no duplicate free after terminal stop
        precondition(ServerFixture.shared.lock.withLock { ServerFixture.shared.active.isEmpty })
        print("PASS actual mobile lifecycle: 64 rapid background/foreground cycles, idempotent start, FIFO restart, single free")
    }
}
