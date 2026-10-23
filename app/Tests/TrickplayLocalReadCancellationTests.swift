import Foundation

// Complete private production cache compiled against recording disk/image fakes.
// Queue barriers make cancellation deterministic without device or network work.
enum Recorder {
    static var probes = 0
    static var scans = 0
    static var completions = 0
    static var onProbe: (() -> Void)?
    static func reset() { probes = 0; scans = 0; completions = 0; onProbe = nil }
}
final class ScrubImage: NSObject {
    init?(data: Data) { super.init() }
}
struct RecordingDiskStore {
    let directory: URL
    func write(_ data: Data, mediaKey: String, bucket: Int) throws {}
    func data(mediaKey: String, bucket: Int) -> Data? {
        Recorder.probes += 1
        Recorder.onProbe?()
        return nil
    }
    func nearest(mediaKey: String, targetBucket: Int,
                 shouldContinue: () -> Bool = { true }) -> (bucket: Int, data: Data)? {
        guard shouldContinue() else { return nil }
        Recorder.scans += 1
        return nil
    }
}
var checks = 0
var failures = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL: " + message) }
}
let cache = LocalTrickplayFrameCache()
let parked = DispatchSemaphore(value: 0)
let resumed = DispatchSemaphore(value: 0)
cache.ioQueue.async { parked.signal(); _ = resumed.wait(timeout: .now() + 5) }
_ = parked.wait(timeout: .now() + 5)
var previous: TrickplayLocalReadLease?
for index in 0..<100 {
    previous?.cancel()
    let lease = TrickplayLocalReadLease()
    previous = lease
    cache.imageAsync(for: "episode", time: 1000 + Double(index), lease: lease) { _ in Recorder.completions += 1 }
}
resumed.signal()
cache.ioQueue.sync {}
expect(Recorder.probes == 181 && Recorder.scans == 1 && Recorder.completions == 1,
       "100 queued scrub requests execute only the newest 181-probe read")
print("WORKLOAD burst=100 probes=\(Recorder.probes) scans=\(Recorder.scans) completions=\(Recorder.completions)")

Recorder.reset()
let interrupted = TrickplayLocalReadLease()
Recorder.onProbe = { if Recorder.probes == 17 { interrupted.cancel() } }
cache.imageAsync(for: "episode", time: 1000, lease: interrupted) { _ in Recorder.completions += 1 }
cache.ioQueue.sync {}
expect(Recorder.probes == 17 && Recorder.scans == 0 && Recorder.completions == 0,
       "cancellation during a read stops later disk probes, nearest scan and callback")
Recorder.reset()
let ownerOne = TrickplayLocalReadLease()
let ownerTwo = TrickplayLocalReadLease()
let retiredOwnerOne = TrickplayLocalReadLease()
retiredOwnerOne.cancel()
cache.imageAsync(for: "episode-a", time: 1000, lease: retiredOwnerOne) { _ in Recorder.completions += 1 }
cache.imageAsync(for: "episode-a", time: 1000, lease: ownerOne) { _ in Recorder.completions += 1 }
cache.imageAsync(for: "episode-b", time: 1000, lease: ownerTwo) { _ in Recorder.completions += 1 }
cache.ioQueue.sync {}
expect(Recorder.probes == 362 && Recorder.scans == 2 && Recorder.completions == 2,
       "retiring one owner does not suppress independent active owners on the shared cache")
if let directory = ProcessInfo.processInfo.environment["VORTX_SCRUB_TEST_DIRECTORY"] {
    let diskDirectory = URL(fileURLWithPath: directory).appendingPathComponent("disk", isDirectory: true)
    try! FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    let disk = TrickplayFrameDiskStore(directory: diskDirectory)
    for bucket in 0..<8 { try! disk.write(Data([UInt8(bucket)]), mediaKey: "owned", bucket: bucket) }
    var cancelledChecks = 0
    let beforeScan = disk.nearest(mediaKey: "owned", targetBucket: 4, shouldContinue: {
        cancelledChecks += 1; return false
    })
    expect(beforeScan == nil && cancelledChecks == 1, "cancelled disk lookup returns before listing files")
    var duringChecks = 0
    let duringScan = disk.nearest(mediaKey: "owned", targetBucket: 4, shouldContinue: {
        duringChecks += 1; return duringChecks < 3
    })
    expect(duringScan == nil && duringChecks == 3, "real disk nearest observes cancellation during file scan")
    let nearest = disk.nearest(mediaKey: "owned", targetBucket: 4)
    expect(nearest?.bucket == 4 && nearest?.data == Data([4]), "active real disk lookup preserves nearest-frame selection")
}
print("scrub queue cancellation: \(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
