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

        if failures > 0 {
            print("FAILED: \(failures)")
            exit(1)
        }

        print("ALL PASS")
    }
}
