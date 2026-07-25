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

    typealias Send = (Data, @escaping (Bool) -> Void) -> Void

    private let lease: VortXHLSSessionSpool.ResourceLease
    private let chunkSize: Int
    private var remaining: Int
    private var started = false
    private var terminated = false

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
    }

    /// Send `header` then exactly `range.count` bytes. Mirrors `VortXSpoolResponsePump.start` so the two behave
    /// identically on every terminal edge, including releasing the lease exactly once.
    func start(header: Data,
               cancelled: @escaping () -> Bool,
               send: @escaping Send,
               terminal: @escaping (Terminal) -> Void) {
        guard !started, !terminated else { return }
        started = true
        guard !cancelled() else { finish(.cancelled, terminal: terminal); return }
        send(header) { [self] succeeded in
            guard succeeded else { finish(.sendError, terminal: terminal); return }
            sendNext(cancelled: cancelled, send: send, terminal: terminal)
        }
    }

    private func sendNext(cancelled: @escaping () -> Bool,
                          send: @escaping Send,
                          terminal: @escaping (Terminal) -> Void) {
        guard !terminated else { return }
        guard !cancelled() else { finish(.cancelled, terminal: terminal); return }
        guard remaining > 0 else { finish(.complete, terminal: terminal); return }
        let data: Data
        do {
            data = try lease.read(maxLength: min(chunkSize, remaining))
        } catch {
            finish(.readError, terminal: terminal)
            return
        }
        guard !data.isEmpty else { finish(.readError, terminal: terminal); return }
        remaining -= data.count
        send(data) { [self] succeeded in
            guard succeeded else { finish(.sendError, terminal: terminal); return }
            sendNext(cancelled: cancelled, send: send, terminal: terminal)
        }
    }

    private func finish(_ outcome: Terminal, terminal: (Terminal) -> Void) {
        guard !terminated else { return }
        terminated = true
        lease.close()
        terminal(outcome)
    }
}
#endif
