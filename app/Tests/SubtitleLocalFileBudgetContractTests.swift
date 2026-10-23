import Foundation

private final class CallbackBox: @unchecked Sendable {
private let lock = NSLock(); private var count = 0; private var main = false
func record() { lock.lock(); count += 1; main = main || Thread.isMainThread; lock.unlock() }
var snapshot: (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (count, main) }
}
@main @MainActor private enum FetchBudgetTests {
static func fetch(_ path: String) async -> (Data?, CallbackBox) {
let box = CallbackBox()
let result: Data? = await withCheckedContinuation { continuation in
SubtitleFileFetcher.fetch(URL(fileURLWithPath: path), timeout: 1) { data in box.record(); continuation.resume(returning: data) }
}
return (result, box)
}
static func main() async {
let limit = SubtitleFileBudget.maximumBytes
let directory = CommandLine.arguments[1]
let exact = directory + "/subtitle-local-exact.srt", over = directory + "/subtitle-local-over.srt", empty = directory + "/subtitle-local-empty.srt"
try! Data(count: limit).write(to: URL(fileURLWithPath: exact))
try! Data(count: limit + 1).write(to: URL(fileURLWithPath: over))
try! Data().write(to: URL(fileURLWithPath: empty))
let accepted = await fetch(exact)
precondition(accepted.0?.count == limit && accepted.1.snapshot.0 == 1 && !accepted.1.snapshot.1)
print("PASS exact 8MiB local read accepted once on background thread")
let rejected = await fetch(over)
precondition(rejected.0 == nil && rejected.1.snapshot.0 == 1 && !rejected.1.snapshot.1)
print("PASS 8MiB+1 local read rejects once on background thread")
let noBytes = await fetch(empty)
precondition(noBytes.0 == nil && noBytes.1.snapshot.0 == 1)
print("PASS empty local file fails closed once")
let missing = await fetch("\(directory)/subtitle-local-no-such-file.srt")
precondition(missing.0 == nil && missing.1.snapshot.0 == 1)
print("PASS missing local file fails closed once")
print("SUBTITLE_LOCAL_FETCH_BUDGET_GREEN")
}
}
