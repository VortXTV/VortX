import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MetricKit)
import MetricKit
#endif

/// Runtime I/O half of the termination-evidence lane. Owns the receipt file, heartbeats, memory
/// warnings, and the launch-time fold into the exportable probe log. All classification lives in
/// TerminationReceiptPolicy (pure); this type only reads/writes and reports.
enum TerminationReceipt {

    private static let fileURL: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("termination-receipt.json")

    /// Call once from each app's `@main` right after VortXCrashReporter.install(). Folds the prior
    /// run's outcome into the probe log, then starts this run's receipt + a 60 s heartbeat.
    static func install() {
        foldPreviousRun()
        note(phase: TerminationReceiptPolicy.phaseActive)
        startHeartbeat()
        observeMemoryWarnings()
    }

    /// Record a phase transition (scenePhase onChange). Cheap: one bounded atomic JSON write.
    static func note(phase: String) {
        var receipt = load() ?? TerminationReceiptPolicy.Receipt.initial(now: Date().timeIntervalSince1970)
        receipt.lastPhase = phase
        receipt.lastHeartbeatEpoch = Date().timeIntervalSince1970
        save(receipt)
    }

    /// Explicit clean-exit will (Mac terminate path). Next launch classifies as cleanExit.
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
    private static func foldPreviousRun() {
        let receipt = load()
        let crashPending = VortXCrashReporter.pendingCrashMarkerExists
        let decision = TerminationReceiptPolicy.classify(
            receipt: receipt, crashMarkerExists: crashPending,
            now: Date().timeIntervalSince1970)
        guard VXProbe.enabled, decision != .firstRun else { return }
        VXProbeFileLog.shared.record(
            category: "termination",
            message: TerminationReceiptPolicy.summaryLine(decision, receipt: receipt))
    }

    private static var heartbeatTimer: Timer?
    private static var currentPhase: String = TerminationReceiptPolicy.phaseActive

    private static func startHeartbeat() {
        #if canImport(UIKit)
        heartbeatTimer?.invalidate()
        // Main-runloop timer; 60 s granularity is plenty to separate "died while running" from
        // "device was off" (the policy's stale window is 24 h).
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            currentPhase = TerminationReceiptPolicy.phaseActive
            note(phase: currentPhase)
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        #endif
    }

    private static var memoryWarningObserver: NSObjectProtocol?

    private static func observeMemoryWarnings() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            var receipt = load() ?? TerminationReceiptPolicy.Receipt.initial(now: Date().timeIntervalSince1970)
            receipt.lastMemoryWarningEpoch = Date().timeIntervalSince1970
            receipt.lastMemoryWarningFootprintMB = currentFootprintMB()
            save(receipt)
        }
        #endif
        #if canImport(MetricKit)
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

    #if canImport(MetricKit)
    @available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *)
    private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
        static let shared = MetricSubscriber()
        private var registered = false

        func registerOnce() {
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

