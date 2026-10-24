#if os(iOS) || os(tvOS) || os(macOS)
import Foundation

/// Byte-range response pump over one already-open spool lease, for HOSTED remux sessions only.
///
/// WHY THIS EXISTS. The shipped server answers every request with `200` and a full body and never inspects the
/// HTTP method (`VortXRemuxHLSServer.route`). Over loopback with CoreMedia that has always been fine: AVPlayer
/// fetches whole segments and never sends a `Range`. Over a LAN it is not fine, because a real HTTP client on
/// the other end of a real network can and does issue conditional and partial fetches on a recovery path, and
/// answering a `Range` request with a `200` and the whole object is a correctness bug that surfaces as
/// corrupted media rather than as an error.
///
/// WHY IT IS A SEPARATE TYPE. `VortXSpoolResponsePump` lives in `VortXRemuxBuffer.swift`, a 3900-line file at
/// the centre of the DV lane that took two field regressions to stabilise. This adds the partial-content
/// behaviour without editing a line of it, so the on-device path cannot be affected by a mistake here: nothing
/// constructs this type unless the session has a hosting capability.
///
/// THE SKIP IS A READ. `VortXHLSSessionSpool.ResourceLease` is sequential-only (`read(maxLength:)`, no seek),
/// so this discards the prefix by reading it. That is O(range start) I/O against a warm local file for a
/// request shape that is rare by construction (HLS clients fetch whole segments), so it is the right trade
/// against widening the lease API. If ranged fetches ever become a hot path, the fix is a seek on the lease,
/// not a cache here.
final class VortXRangedSpoolPump: @unchecked Sendable {

    enum Terminal: Equatable, Sendable {
        case complete
        case cancelled
        case sendError
        case readError
    }

    typealias Send = (Data, @escaping @Sendable (Bool) -> Void) -> Void

    private struct Callbacks {
        let cancelled: () -> Bool
        let send: Send
        let terminal: (Terminal) -> Void
    }

    // Existing unchecked conformance is backed by one actual serial response owner.
    // The original non-Sendable transport callbacks never leave this owner.
    private let ownerQueue = DispatchQueue(label: "vortx.spool.response.range", qos: .utility)
    private let ownerKey = DispatchSpecificKey<UUID>()
    private let ownerIdentity = UUID()
    private let lease: VortXHLSSessionSpool.ResourceLease
    private let chunkSize: Int
    private var remaining: Int
    private var started = false
    private var terminated = false
    private var callbacks: Callbacks?
    private var pendingSend: UUID?

    /// `range` is INCLUSIVE and must already have been resolved against `lease.length` by
    /// `VortXEngineHostPolicy.resolve`. Returns nil (having closed the lease) when the range cannot be honoured,
    /// which the caller answers with 416 rather than with the wrong bytes.
    init?(lease: VortXHLSSessionSpool.ResourceLease, chunkSize: Int, range: ClosedRange<Int>) {
        guard chunkSize > 0,
              range.lowerBound >= 0,
              range.upperBound < lease.length else {
            lease.close()
            return nil
        }
        var toSkip = range.lowerBound
        do {
            while toSkip > 0 {
                let chunk = try lease.read(maxLength: min(chunkSize, toSkip))
                guard !chunk.isEmpty else { lease.close(); return nil }
                toSkip -= chunk.count
            }
        } catch {
            lease.close()
            return nil
        }
        self.lease = lease
        self.chunkSize = chunkSize
        self.remaining = range.count
        ownerQueue.setSpecific(key: ownerKey, value: ownerIdentity)
    }

    /// Send `header` then exactly `range.count` bytes. The original lease remains owned
    /// through the first terminal edge; later duplicate or stale ACKs cannot advance it.
    func start(header: Data,
               cancelled: @escaping () -> Bool,
               send: @escaping Send,
               terminal: @escaping (Terminal) -> Void) {
        let register = {
            dispatchPrecondition(condition: .onQueue(self.ownerQueue))
            guard !self.started, !self.terminated else { return }
            self.started = true
            self.callbacks = .init(cancelled: cancelled, send: send, terminal: terminal)
            guard !cancelled() else { self.finish(.cancelled); return }
            self.sendOwned(header)
        }
        if DispatchQueue.getSpecific(key: ownerKey) == ownerIdentity { register() }
        else { ownerQueue.sync(execute: register) }
    }

    private func sendOwned(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !terminated, pendingSend == nil, let callbacks else { return }
        let receipt = UUID()
        pendingSend = receipt
        callbacks.send(data) { [self, receipt] succeeded in
            // Even an inline transport completion is a queued checked-value ingress.
            ownerQueue.async { [self, receipt, succeeded] in
                acknowledge(receipt, succeeded: succeeded)
            }
        }
    }

    private func acknowledge(_ receipt: UUID, succeeded: Bool) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !terminated, pendingSend == receipt else { return }
        pendingSend = nil
        guard succeeded else { finish(.sendError); return }
        sendNext()
    }

    private func sendNext() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !terminated, let callbacks else { return }
        guard !callbacks.cancelled() else { finish(.cancelled); return }
        guard remaining > 0 else { finish(.complete); return }
        let data: Data
        do {
            data = try lease.read(maxLength: min(chunkSize, remaining))
        } catch {
            finish(.readError)
            return
        }
        guard !data.isEmpty else { finish(.readError); return }
        remaining -= data.count
        sendOwned(data)
    }

    private func finish(_ outcome: Terminal) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard !terminated else { return }
        terminated = true
        pendingSend = nil
        let terminal = callbacks?.terminal
        callbacks = nil
        lease.close()
        terminal?(outcome)
    }
}
#endif
