import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
private enum EpisodeReturnIdentityPolicyTests {
    static func main() {
        let available: Set<String> = ["series:2:1", "series:2:2", "series:2:3"]

        check(
            "committed first-frame episode outranks delayed engine history",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: "series",
                committedVideoID: "series:2:1",
                engineVideoID: "series:2:2"
            ) == "series:2:1"
        )

        check(
            "failed-before-first-frame returns to the attempted episode before stale engine history",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: nil,
                committedVideoID: nil,
                engineVideoID: "series:4:4",
                attemptedLibraryID: "series",
                attemptedVideoID: "series:2:1"
            ) == "series:2:1"
        )

        check(
            "a committed first-frame episode outranks the attempted request target",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: "series",
                committedVideoID: "series:2:2",
                engineVideoID: "series:2:3",
                attemptedLibraryID: "series",
                attemptedVideoID: "series:2:1"
            ) == "series:2:2"
        )

        check(
            "identity from another series cannot move this detail page",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: "other-series",
                committedVideoID: "series:2:1",
                engineVideoID: "series:2:2"
            ) == "series:2:2"
        )

        check(
            "committed episode absent from inventory falls back to known engine episode",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: "series",
                committedVideoID: "series:9:9",
                engineVideoID: "series:2:3"
            ) == "series:2:3"
        )

        check(
            "foreign or inventory-missing attempted targets fall back to known engine history",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: nil,
                committedVideoID: nil,
                engineVideoID: "series:2:3",
                attemptedLibraryID: "other-series",
                attemptedVideoID: "series:2:1"
            ) == "series:2:3"
                && EpisodeReturnIdentityPolicy.resolve(
                    libraryID: "series",
                    isVideoAvailable: available.contains,
                    committedLibraryID: nil,
                    committedVideoID: nil,
                    engineVideoID: "series:2:3",
                    attemptedLibraryID: "series",
                    attemptedVideoID: "series:9:9"
                ) == "series:2:3"
        )

        check(
            "missing attempted target falls back to known engine history",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: nil,
                committedVideoID: nil,
                engineVideoID: "series:2:3",
                attemptedLibraryID: nil,
                attemptedVideoID: nil
            ) == "series:2:3"
        )

        check(
            "unknown identities do not invent a return target",
            EpisodeReturnIdentityPolicy.resolve(
                libraryID: "series",
                isVideoAvailable: available.contains,
                committedLibraryID: "series",
                committedVideoID: "series:9:9",
                engineVideoID: "series:8:8"
            ) == nil
        )

        var receipt = EpisodeReturnReceiptState<Int, String>()
        receipt.begin(requestID: 1)
        check(
            "receipt lifecycle rejects a stale callback from another request",
            !receipt.record("series:2:2", requestID: 0)
                && receipt.close(requestID: 1) == nil
        )

        receipt.begin(requestID: 2)
        check(
            "receipt lifecycle publishes the exact committed identity only when its request closes",
            receipt.record("series:2:1", requestID: 2)
                && receipt.close(requestID: 2) == "series:2:1"
                && receipt.closedReceipt?.requestID == 2
        )

        receipt.begin(requestID: 6)
        check(
            "receipt lifecycle publishes an attempted target even without a first frame",
            receipt.recordAttempt("series:2:1", requestID: 6)
                && receipt.close(requestID: 6) == nil
                && receipt.closedAttempt?.requestID == 6
                && receipt.closedAttempt?.meta == "series:2:1"
        )

        receipt.begin(requestID: 7)
        check(
            "a trailer or metadata-less request has no attempted target",
            receipt.recordAttempt(nil, requestID: 7)
                && receipt.close(requestID: 7) == nil
                && receipt.closedAttempt?.requestID == 7
                && receipt.closedAttempt?.meta == nil
        )

        receipt.begin(requestID: 3)
        check(
            "receipt lifecycle clears an older close receipt when a newer request begins",
            receipt.closedReceipt == nil
                && receipt.close(requestID: 3) == nil
        )

        receipt.begin(requestID: 4)
        _ = receipt.record("series:2:3", requestID: 4)
        receipt.begin(requestID: 5)
        check(
            "receipt lifecycle cannot close a superseded request into the newer session",
            receipt.close(requestID: 4) == nil
                && receipt.activeRequestID == 5
                && receipt.closedReceipt == nil
        )

        receipt.begin(requestID: 8)
        _ = receipt.recordAttempt("series:2:2", requestID: 8)
        receipt.begin(requestID: 9)
        check(
            "a newer request clears the older attempted target and fences its close",
            receipt.close(requestID: 8) == nil
                && receipt.activeRequestID == 9
                && receipt.closedAttempt == nil
        )

        check(
            "nil request close cannot publish an attempted target",
            receipt.close(requestID: 9) == nil
                && receipt.closedAttempt == nil
        )

        if failures > 0 {
            print("FAILED: \(failures)")
            exit(1)
        }

        print("ALL PASS")
    }
}
