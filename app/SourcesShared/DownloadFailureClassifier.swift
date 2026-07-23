import Foundation

/// Pure decision logic for a byte-download `NSURLErrorCannotCreateFile` (-3000) save failure, factored out
/// of `DownloadManager` so it is UNIT-TESTABLE in isolation (no AVFoundation / UIKit / actor dependencies).
///
/// A -3000 on a background download is "the finished file could not be created", which is NOT the same as
/// out-of-space. It has two very different real causes, and the app must react differently to each:
///
///  * **Device LOCKED**: `nsurlsessiond` finalized the download while the device was locked and could not
///    create the file under its data-protection class. This is fully recoverable: the app parks the record
///    and re-tries when the device unlocks. Waiting for unlock is UNBOUNDED and free; an overnight download
///    saves the moment the user unlocks in the morning.
///  * **Device UNLOCKED**: a -3000 with the device unlocked is usually a transient background-daemon staging
///    hiccup (a fresh restart clears it), but it CAN be terminal (a real container/path fault, a genuinely
///    unwritable destination). So the unlocked path self-heals then parks, but under a BOUNDED number of
///    attempts, because a terminal -3000 must not re-download gigabytes forever on every foreground (the
///    unbounded "waiting to finish saving" loop). After the cap it hard-fails with the full diagnostic so the
///    real cause is legible. Genuine out-of-space (ENOSPC) hard-fails immediately, since parking it would only
///    re-download and fail again at file-create.
enum DownloadFailureClassifier {

    /// How many UNLOCKED, non-ENOSPC -3000 save failures to absorb (self-heal + park) before giving up and
    /// hard-failing. The LOCKED case is never capped by this (waiting for unlock is correct and costs
    /// nothing). Small on purpose: a transient staging failure clears within one or two restarts, so a value
    /// past that only delays surfacing a genuinely terminal fault.
    static let maxUnlockedSaveFailures = 3

    /// What to do with a -3000 save failure.
    enum SaveRetryDecision: Equatable {
        /// Hold the record `.paused` and auto-resume on the next device unlock / app foreground.
        case parkForUnlock
        /// Drop stale resume data and restart the transfer once from scratch (fresh daemon staging).
        case selfHealRestart
        /// Stop retrying and surface the real error (out of space, or the unlocked-retry cap is exhausted).
        case hardFail
    }

    /// Decide how to handle a -3000, given whether protected data is available (device unlocked-since-boot and
    /// not currently locked), whether the underlying cause is out-of-space, and how many UNLOCKED non-ENOSPC
    /// -3000 failures this download has already accrued (see `unlockedSaveFailures` in `DownloadManager`, which
    /// is deliberately NOT reset across the restart/park cycle so this cap actually accrues).
    ///
    /// Ordering matters:
    ///  1. LOCKED wins first: park regardless of anything else; we cannot even reliably read the volume while
    ///     locked, and unlock is the correct next event.
    ///  2. Out-of-space next: a full volume is terminal, so hard-fail immediately rather than park-loop.
    ///  3. First unlocked failure: self-heal restart once.
    ///  4. Within the cap: park for the next unlock/foreground.
    ///  5. Past the cap: hard-fail with diagnostics.
    static func classifyCannotCreateFile(protectedDataAvailable: Bool,
                                         outOfSpace: Bool,
                                         unlockedSaveFailures: Int,
                                         maxUnlockedSaveFailures: Int) -> SaveRetryDecision {
        if !protectedDataAvailable { return .parkForUnlock }
        if outOfSpace { return .hardFail }
        if unlockedSaveFailures <= 1 { return .selfHealRestart }
        if unlockedSaveFailures <= maxUnlockedSaveFailures { return .parkForUnlock }
        return .hardFail
    }

    /// True when a failure is ultimately an out-of-space condition (POSIX ENOSPC, at the top level or as the
    /// underlying error). A -3000 create failure backed by ENOSPC really is a full volume, so it must stay a
    /// hard failure (the user has to free space) instead of being parked for retry: parking would re-download
    /// gigabytes and fail again at file-create on every foreground, never succeeding. Every OTHER -3000 is
    /// transient and park-recoverable up to the cap.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           under.domain == NSPOSIXErrorDomain, under.code == Int(ENOSPC) { return true }
        return false
    }
}
