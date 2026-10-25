import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MetricKit)
import MetricKit
#endif
#if os(macOS)
import AppKit
#endif

/// Runtime I/O half of the termination-evidence lane. Owns the receipt file, heartbeats, memory
/// warnings, and the launch-time fold into the exportable probe log. All classification lives in
/// TerminationReceiptPolicy (pure); this type only reads/writes and reports.
enum TerminationReceipt {

    private static let fileURL: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("termination-receipt.json")

    // Checked, value-owned storage. The lock owns the session; no unprotected static mutable slot.
    // Runtime callbacks never reload a previous process's receipt.
    private static let receiptStore = OSAllocatedUnfairLock<TerminationReceiptPolicy.Session?>(initialState: nil)
    @MainActor private static var installed = false

    /// Call from each app's `@main` right after VortXCrashReporter.install(). Inspect the prior
    /// run once, then replace it with this process's fresh receipt before registering callbacks.
    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        let previousReceipt = load()
        foldPreviousRun(receipt: previousReceipt)
        receiptStore.withLock { session in
            let fresh = TerminationReceiptPolicy.Session(now: Date().timeIntervalSince1970)
            session = fresh
            save(fresh.receipt)
        }
        startHeartbeat()
        observeMemoryWarnings()
        observeOrdinaryQuit()
    }

    #if os(macOS)
    @MainActor private static var quitObserver: NSObjectProtocol?
    #endif

    /// macOS has no scene phase for quitting: an ordinary Quit (after the streaming server has stopped)
    /// posts willTerminate, so record it as an intentional exit. Every Mac quit was otherwise folded on the
    /// next launch as "terminated while foregrounded". Force Quit and crashes never post it.
    @MainActor private static func observeOrdinaryQuit() {
        #if os(macOS)
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { @Sendable _ in
            markTerminating()
        }
        #endif
    }

    /// Record a phase transition (scenePhase onChange). Cheap: one bounded atomic JSON write.
    static func note(phase: String) {
        updateSession { $0.note(phase: phase, now: Date().timeIntervalSince1970) }
    }

    private static func heartbeat() {
        updateSession { $0.heartbeat(now: Date().timeIntervalSince1970) }
    }

    private static func memoryWarning(footprintMB: Int64) {
        updateSession { $0.memoryWarning(now: Date().timeIntervalSince1970, footprintMB: footprintMB) }
    }

    /// Serialize state plus its atomic file replacement. No logging, observer delivery or actor
    /// hops occur under this lock. Late callbacks cannot overwrite an intentional termination.
    private static func updateSession(_ update: @Sendable (inout TerminationReceiptPolicy.Session) -> Void) {
        receiptStore.withLock { session in
            guard var current = session else { return }
            let before = current.receipt
            update(&current)
            guard current.receipt != before else { return }
            session = current
            save(current.receipt)
        }
    }

    /// Explicit intentional exit. A later captured crash still takes precedence on next launch.
    static func markTerminating() {
        note(phase: TerminationReceiptPolicy.phaseTerminating)
    }

    private static func load() -> TerminationReceiptPolicy.Receipt? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(TerminationReceiptPolicy.Receipt.self, from: data)
    }

    private static func save(_ receipt: TerminationReceiptPolicy.Receipt) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Fold the PRIOR run's outcome into the exportable probe log. Mirrors
    /// VortXCrashReporter.foldPreviousCrash: the diagnostics toggle gates the FOLD only; the
    /// receipt is kept either way because this run immediately overwrites it.
    private static func foldPreviousRun(receipt: TerminationReceiptPolicy.Receipt?) {
        let crashPending = VortXCrashReporter.pendingCrashMarkerExists
        let decision = TerminationReceiptPolicy.classify(
            receipt: receipt, crashMarkerExists: crashPending,
            now: Date().timeIntervalSince1970)
        guard VXProbe.enabled, decision != .firstRun else { return }
        VXProbeFileLog.shared.record(
            category: "termination",
            message: TerminationReceiptPolicy.summaryLine(decision, receipt: receipt))
    }

    @MainActor private static var heartbeatTimer: Timer?

    @MainActor private static func startHeartbeat() {
        // Every platform: on macOS the receipt otherwise kept its start time, so each fold reported
        // "session ran 0s" however long the app had run.
        heartbeatTimer?.invalidate()
        // Main-runloop timer; 60 s granularity is plenty to separate "died while running" from
        // "device was off" (the policy's stale window is 24 h).
        let timer = Timer(timeInterval: 60, repeats: true) { @Sendable _ in
            heartbeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    @MainActor private static var memoryWarningObserver: NSObjectProtocol?

    @MainActor private static func observeMemoryWarnings() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { @Sendable _ in
            memoryWarning(footprintMB: currentFootprintMB())
        }
        #endif
        #if canImport(MetricKit) && !os(tvOS)
        if #available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *) {
            MetricSubscriber.shared.registerOnce()
        }
        #endif
    }

    /// Physical footprint of this process in MiB (task_vm_info.phys_footprint), the same number
    /// jetsam uses against the limit. Best effort; zero means unavailable.
    private static func currentFootprintMB() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint / (1024 * 1024))
    }

    // tvOS exclusion: the tvOS 26.5 SDK marks the subscriber protocol and the diagnostic payload types
    // unavailable, so this class cannot compile there even though the module still imports.
    #if canImport(MetricKit) && !os(tvOS)
    @available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *)
    private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
        @MainActor static let shared = MetricSubscriber()
        @MainActor private var registered = false

        @MainActor func registerOnce() {
            guard !registered else { return }
            registered = true
            MXMetricManager.shared.add(self)
        }

        /// MetricKit delivers daily metrics and crash/hang diagnostics here on later launches.
        /// Record abnormal-exit counters so "closed by itself" reports gain OS-side corroboration.
        func didReceive(_ payloads: [MXMetricPayload]) {
            for payload in payloads {
                guard let exit = payload.applicationExitMetrics else { continue }
                let abnormal = exit.foregroundExitData.cumulativeAbnormalExitCount
                    + exit.backgroundExitData.cumulativeAbnormalExitCount
                guard abnormal > 0, VXProbe.enabled else { continue }
                VXProbeFileLog.shared.record(
                    category: "termination",
                    message: String(format: "metrickit daily abnormal exits %d (ended %@)",
                                    abnormal, payload.timeStampEnd.description))
            }
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                guard VXProbe.enabled else { continue }
                var kinds: [String] = []
                if !(payload.crashDiagnostics ?? []).isEmpty { kinds.append("crash") }
                if !(payload.hangDiagnostics ?? []).isEmpty { kinds.append("hang") }
                if !(payload.cpuExceptionDiagnostics ?? []).isEmpty { kinds.append("cpu") }
                if !(payload.diskWriteExceptionDiagnostics ?? []).isEmpty { kinds.append("disk") }
                guard !kinds.isEmpty else { continue }
                VXProbeFileLog.shared.record(
                    category: "termination",
                    message: "metrickit diagnostics: \(kinds.joined(separator: ",")) ended \(payload.timeStampEnd.description)")
            }
        }
    }
    #endif
}
