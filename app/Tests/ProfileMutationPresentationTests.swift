import Foundation

@MainActor
private final class PendingResult {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish(_ accepted: Bool) {
        continuation?.resume(returning: accepted)
        continuation = nil
    }
}

@main
enum ProfileMutationPresentationTests {
    @MainActor static func main() async {
        let presentation = ProfileMutationPresentation()
        var dismissals = 0
        var cancelledOperationStarted = false
        presentation.start(operation: { cancelledOperationStarted = true; return true },
                           failureMessage: { "Cancelled before admission" }, onSuccess: { dismissals += 100 })
        // Still on the same MainActor turn: cancellation precedes the newly scheduled task.
        presentation.cancel()
        for _ in 0..<10 { await Task.yield() }
        precondition(!cancelledOperationStarted && !presentation.isRunning && dismissals == 0)
        let first = PendingResult()
        presentation.start(operation: { await first.value() }, failureMessage: { "Save failed" },
                           onSuccess: { dismissals += 1 })
        precondition(presentation.isRunning && dismissals == 0)
        await first.waitUntilStarted()
        var duplicateStarted = false
        presentation.start(operation: { duplicateStarted = true; return true }, failureMessage: { "Duplicate" })
        first.finish(false)
        await settle { !presentation.isRunning }
        precondition(!duplicateStarted && dismissals == 0 && presentation.errorMessage == "Save failed")
        presentation.cancel()
        precondition(presentation.errorMessage == nil)

        let stale = PendingResult(), replacement = PendingResult()
        presentation.start(operation: { await stale.value() }, failureMessage: { "Stale error" },
                           onSuccess: { dismissals += 100 })
        await stale.waitUntilStarted()
        presentation.cancel()
        presentation.start(operation: { await replacement.value() }, failureMessage: { "Retry failed" },
                           onSuccess: { dismissals += 1 })
        await replacement.waitUntilStarted()
        stale.finish(true)
        for _ in 0..<10 { await Task.yield() }
        precondition(presentation.isRunning && dismissals == 0 && presentation.errorMessage == nil)
        replacement.finish(true)
        await settle { !presentation.isRunning }
        precondition(dismissals == 1 && presentation.errorMessage == nil)

        // Guard the platform UI seam as well as executing the real presentation coordinator above.
        let view = try! String(contentsOfFile: "app/SourcesShared/ProfilesView.swift", encoding: .utf8)
        precondition(view.contains("await store.saveNative(profile, creating: creating, admission: admission)"))
        precondition(view.contains("await store.removeNative(original, admission: admission)"))
        precondition(view.contains("await store.selectNative(original, admission: admission)"))
        precondition(view.contains("await store.selectNative(profile, admission: admission)"))
        // Five admission sites: picker, account editor, removal, selection, and profile save.
        precondition(view.components(separatedBy: "let admission = core.captureNativeProfileActionAdmission()").count == 6)
        precondition(!view.contains("let target = core.captureNativePlaybackTarget()"))
        precondition(view.contains(".interactiveDismissDisabled(profileAction.isRunning)"))
        print("PASS actual profile mutation presentation: acknowledgement, failure, retry, duplicate taps, cancelled late completion, captured native UI targets")
    }

    @MainActor private static func settle(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), "presentation completion did not settle")
    }
}
