import Foundation
import Darwin

private final class KeyRace: @unchecked Sendable {
    let ready = DispatchGroup(), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values: [Data] = []
    init() { ready.enter(); ready.enter() }
    func random(_ byte: UInt8) -> Data { ready.leave(); release.wait(); return Data(repeating: byte, count: 32) }
    func append(_ value: Data) { lock.lock(); values.append(value); lock.unlock() }
    var results: [Data] { lock.lock(); defer { lock.unlock() }; return values }
}

@main enum NativeInstallationKeyFileTests {
    enum Refused: Error { case read, boundary }
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func refused(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected fail-closed refusal") } catch {}
    }
    static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = Data(repeating: 0x51, count: 32)
        func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
        func final(_ url: URL) -> URL { url.appendingPathComponent("native-installation-v2.key") }
        func store(_ url: URL, old: Data? = legacy) -> VortxNativeInstallationKeyFileStore {
            VortxNativeInstallationKeyFileStore(directory: url, legacyRead: { old }, randomBytes: { Data(repeating: 0x32, count: 32) })
        }
        let migrated = directory("migration")
        check(try store(migrated).loadOrCreateBytes() == legacy, "legacy bytes must be unchanged")
        check(try permissions(migrated) == 0o700 && permissions(final(migrated)) == 0o600, "owner-only modes")
        let reopened = VortxNativeInstallationKeyFileStore(directory: migrated,
            legacyRead: { fatalError("cold reopen read Keychain") }, randomBytes: { fatalError("cold reopen rotated identity") })
        check(try reopened.loadOrCreateBytes() == legacy, "cold reopen preserves migrated identity")
        for size in [0, 31, 33] {
            let url = directory("bad-size-\(size)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: final(url))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: final(url).path)
            refused { _ = try store(url).loadOrCreateBytes() }
            check(try Data(contentsOf: final(url)).count == size, "bad final must not be replaced")
        }
        for kind in ["symlink", "directory", "fifo", "mode"] {
            let url = directory(kind)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: final(url), withDestinationURL: final(migrated))
            case "directory": try FileManager.default.createDirectory(at: final(url), withIntermediateDirectories: false)
            case "fifo": check(Darwin.mkfifo(final(url).path, mode_t(0o600)) == 0, "fixture FIFO")
            default:
                try legacy.write(to: final(url)); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: final(url).path)
            }
            let invalid = VortxNativeInstallationKeyFileStore(directory: url,
                legacyRead: { fatalError("invalid final became missing") }, randomBytes: { fatalError("invalid final regenerated") })
            refused { _ = try invalid.loadOrCreateBytes() }
        }
        let denied = directory("denied")
        refused { _ = try VortxNativeInstallationKeyFileStore(directory: denied, legacyRead: { throw Refused.read },
            randomBytes: { fatalError("denial generated replacement") }).loadOrCreateBytes() }
        check(!FileManager.default.fileExists(atPath: final(denied).path), "denial must not publish")
        let interrupted = directory("interrupted")
        refused { _ = try VortxNativeInstallationKeyFileStore(directory: interrupted, legacyRead: { legacy },
            randomBytes: { fatalError() }, boundary: { if $0 == .beforePublish { throw Refused.boundary } }).loadOrCreateBytes() }
        check(!FileManager.default.fileExists(atPath: final(interrupted).path), "prepublication failure leaves no final")
        let uncertain = directory("uncertain")
        refused { _ = try VortxNativeInstallationKeyFileStore(directory: uncertain, legacyRead: { legacy },
            randomBytes: { fatalError() }, boundary: { if $0 == .afterPublish { throw Refused.boundary } }).loadOrCreateBytes() }
        check(try reopened.loadOrCreateBytes() == legacy, "unrelated cache retains key")
        check(try store(uncertain, old: nil).loadOrCreateBytes() == legacy, "uncertain publication heals without rotation")
        let race = KeyRace(), raceDirectory = directory("race"), done = DispatchGroup()
        for byte: UInt8 in [0x11, 0x22] {
            done.enter()
            DispatchQueue.global().async {
                defer { done.leave() }
                let instance = VortxNativeInstallationKeyFileStore(directory: raceDirectory, legacyRead: { nil }, randomBytes: { race.random(byte) })
                do { race.append(try instance.loadOrCreateBytes()) } catch { fatalError("random race failed: \(error)") }
            }
        }
        check(race.ready.wait(timeout: .now() + 5) == .success, "both creators reached certified absence")
        race.release.signal(); race.release.signal()
        check(done.wait(timeout: .now() + 5) == .success, "race completed")
        check(race.results.count == 2 && race.results[0] == race.results[1], "independent creators adopt one immutable winner")
        check([Data(repeating: 0x11, count: 32), Data(repeating: 0x22, count: 32)].contains(race.results[0]), "winner is an actual proposed key")
        check(try Data(contentsOf: final(raceDirectory)) == race.results[0], "returned key equals durable file")
        check(try VortxNativeInstallationKeyFileStore(directory: raceDirectory,
            legacyRead: { fatalError("race reopen read legacy") }, randomBytes: { fatalError("race reopen regenerated") }).loadOrCreateBytes() == race.results[0], "cold race winner retained")
        let collision = directory("collision")
        let conflicting = VortxNativeInstallationKeyFileStore(directory: collision, legacyRead: { legacy }, randomBytes: { fatalError() }, boundary: {
            if $0 == .beforePublish { _ = try store(collision, old: Data(repeating: 0x77, count: 32)).loadOrCreateBytes() }
        })
        refused { _ = try conflicting.loadOrCreateBytes() }
        check(try Data(contentsOf: final(collision)) == Data(repeating: 0x77, count: 32), "conflicting legacy migration preserves winner")
        print("PASS actual extracted immutable-key helper: migration, cold reuse, malformed files, denied access, interruption, races, collision")
    }
}
