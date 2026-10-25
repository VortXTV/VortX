// Shared trailer range-proxy facade. Network.framework and URLSession objects
// remain owned by the Objective-C transport; this Swift type coordinates
// lease, port, preparation, and value-only readiness state for the player.

import Foundation

struct VXTrailerPreparedURLs: Sendable {
    let video: URL?
    let audio: URL?
}

@MainActor
final class VXTrailerProxy {
    static let shared = VXTrailerProxy()

    private var nextLeaseID: UInt64 = 1
    private var nextOwnerID: UInt64 = 1
    private var nextPreparationID: UInt64 = 1
    private var activeLeaseID: UInt64?
    private var activePort: UInt16 = 0
    private var activeOwners = Set<UInt64>()
    /// Controller identities are admitted only while registered. Removing an
    /// identity on release prevents a queued/cancelled preparation from
    /// re-admitting it, without retaining an ever-growing tombstone set.
    /// Scene-wide invalidate() intentionally keeps registrations because the
    /// controller survives backgrounding and may rebind a fresh lease.
    private var registeredOwners = Set<UInt64>()
    /// A controller can replace one trailer preparation while another caller
    /// still awaits the shared listener. Track those waits separately so the
    /// canceled older preparation cannot release the newer one.
    private var pendingPreparations: [UInt64: UInt64] = [:]
    private var readinessGeneration: UInt64 = 0
    /// All callers for one lease await the same readiness operation. Starting
    /// a second native listener for the same lease would cancel the first
    /// listener and leave its continuation without a result.
    private var readinessTask: Task<UInt16, Never>?

    private init() {}

    func registerOwner() -> UInt64? {
        guard nextOwnerID != UInt64.max else { return nil }
        let owner = nextOwnerID
        nextOwnerID += 1
        registeredOwners.insert(owner)
        return owner
    }

    /// Start or reuse one native listener and return both trailer legs as a
    /// single value. A failed/cancelled readiness path returns both original
    /// URLs, never a partial pair.
    func prepare(video: URL?, audio: URL?, owner: UInt64) async -> VXTrailerPreparedURLs {
        let videoNeedsProxy = video?.host?.contains("googlevideo") ?? false
        let audioNeedsProxy = audio?.host?.contains("googlevideo") ?? false
        guard videoNeedsProxy || audioNeedsProxy else {
            return VXTrailerPreparedURLs(video: video, audio: audio)
        }
        // A queued caller can be cancelled before this async method begins.
        // Refuse that call before it mutates preparation or ownership state;
        // otherwise the ready-port fast path could leave a ghost owner behind.
        guard !Task.isCancelled,
              registeredOwners.contains(owner) else {
            return VXTrailerPreparedURLs(video: video, audio: audio)
        }
        guard nextPreparationID != UInt64.max else {
            return VXTrailerPreparedURLs(video: video, audio: audio)
        }
        let preparationID = nextPreparationID
        nextPreparationID += 1
        pendingPreparations[preparationID] = owner
        activeOwners.insert(owner)

        let lease: UInt64
        if let activeLeaseID {
            lease = activeLeaseID
        } else {
            guard nextLeaseID != UInt64.max else {
                pendingPreparations.removeValue(forKey: preparationID)
                activeOwners.remove(owner)
                return VXTrailerPreparedURLs(video: video, audio: audio)
            }
            lease = nextLeaseID
            nextLeaseID += 1
            activeLeaseID = lease
        }

        var callerCancelled = false
        if activePort == 0 {
            // The lease's upstream client identity must come from the leg
            // that actually needs proxying. A normal video plus a googlevideo
            // audio sidecar must not derive its UA from the normal video.
            let source = videoNeedsProxy ? video : audio
            let userAgent = source.map { YouTubeDirectResolver.requiredUserAgent(for: $0) } ?? ""
            let task: Task<UInt16, Never>
            let operationGeneration: UInt64
            if let readinessTask {
                task = readinessTask
                operationGeneration = readinessGeneration
            } else {
                readinessGeneration &+= 1
                operationGeneration = readinessGeneration
                let newTask = Task { @MainActor [self] in
                    await withTaskCancellationHandler(operation: {
                        await withCheckedContinuation { continuation in
                            VXTrailerNetworkOwner.shared().startLease(
                                lease,
                                userAgent: userAgent,
                                completion: { returnedLease, returnedPort, success in
                                    guard returnedLease == lease else { return }
                                    continuation.resume(returning: success ? returnedPort : 0)
                                },
                                failure: { returnedLease in
                                    // A ready lease can fail after its
                                    // continuation was consumed. This is a
                                    // state notification, never a second
                                    // continuation result.
                                    guard returnedLease == lease else { return }
                                    Task { @MainActor [weak self] in
                                        guard let self, self.activeLeaseID == lease else { return }
                                        self.activeLeaseID = nil
                                        self.activePort = 0
                                        self.readinessTask = nil
                                        self.readinessGeneration &+= 1
                                        self.activeOwners.removeAll()
                                        self.pendingPreparations.removeAll()
                                    }
                                }
                            )
                        }
                    }, onCancel: {
                        // The caller-level cancellation fence below owns the
                        // preparation identity. This handler runs only when
                        // the shared readiness task itself is canceled after
                        // every owner has been removed.
                        Task { @MainActor in
                            VXTrailerNetworkOwner.shared().stopLease(lease)
                        }
                    })
                }
                readinessTask = newTask
                task = newTask
            }
            let port = await withTaskCancellationHandler(operation: {
                await task.value
            }, onCancel: {
                Task { @MainActor in
                    VXTrailerProxy.shared.cancelPreparation(preparationID, owner: owner)
                }
            })
            callerCancelled = Task.isCancelled
            if activeLeaseID == lease, readinessGeneration == operationGeneration {
                readinessTask = nil
            }
            guard activeLeaseID == lease, port != 0 else {
                pendingPreparations.removeValue(forKey: preparationID)
                // A failed native readiness path has already removed its
                // lease. A cancelled caller must not tear down a readiness
                // task shared by another caller; the listener is reusable by
                // the next prepare call through the same lease ID.
                if port == 0, activeLeaseID == lease {
                    activeLeaseID = nil
                    activePort = 0
                    if !pendingPreparations.values.contains(owner) {
                        activeOwners.remove(owner)
                    }
                    if activeOwners.isEmpty {
                        VXTrailerNetworkOwner.shared().stopLease(lease)
                    }
                }
                return VXTrailerPreparedURLs(video: video, audio: audio)
            }
            guard !Task.isCancelled, !callerCancelled else {
                // Keep the successful lease alive. The next caller can reuse
                // it without starting a second listener.
                pendingPreparations.removeValue(forKey: preparationID)
                return VXTrailerPreparedURLs(video: video, audio: audio)
            }
            activePort = port
        }

        guard !Task.isCancelled,
              !callerCancelled,
              pendingPreparations[preparationID] == owner,
              registeredOwners.contains(owner),
              activeOwners.contains(owner) else {
            pendingPreparations.removeValue(forKey: preparationID)
            return VXTrailerPreparedURLs(video: video, audio: audio)
        }
        pendingPreparations.removeValue(forKey: preparationID)
        let port = activePort
        guard port != 0 else {
            return VXTrailerPreparedURLs(video: video, audio: audio)
        }
        if videoNeedsProxy, let video {
            register(video, lease: lease)
        }
        if audioNeedsProxy, let audio {
            register(audio, lease: lease)
        }
        return VXTrailerPreparedURLs(
            video: videoNeedsProxy ? localURL(for: video!, port: port, mime: "video/mp4") : video,
            audio: audioNeedsProxy ? localURL(for: audio!, port: port, mime: "audio/mp4") : audio
        )
    }

    /// Global scene lifecycle teardown. tvOS/iOS backgrounding can invalidate
    /// the loopback listener even while a player controller remains mounted;
    /// stop admitting new connections so the next prepare rebinds, while an
    /// already accepted stream is allowed to finish on the old native lease.
    /// This is distinct from release(owner:), which releases one controller's
    /// ownership and hard-stops the lease only after every owner is gone.
    func invalidate() {
        pendingPreparations.removeAll()
        activeOwners.removeAll()
        readinessGeneration &+= 1
        readinessTask?.cancel()
        readinessTask = nil
        let lease = activeLeaseID
        let hadReadyLease = activePort != 0
        activeLeaseID = nil
        activePort = 0
        guard let lease else { return }
        // A ready listener may still have accepted streams. Scene teardown
        // drains those streams; a listener that never became ready has no
        // accepted work and is hard-stopped so its pending continuation closes.
        if hadReadyLease {
            VXTrailerNetworkOwner.shared().drainLease(lease)
        } else {
            VXTrailerNetworkOwner.shared().stopLease(lease)
        }
    }

    /// Retained for source compatibility. New trailer loads use `prepare` so
    /// listener readiness is cancellable rather than hidden in a sync wait.
    func proxied(_ upstream: URL, mime: String = "video/mp4") -> URL? {
        guard upstream.host?.contains("googlevideo") ?? false,
              activeLeaseID != nil,
              activePort != 0 else { return nil }
        if let lease = activeLeaseID {
            register(upstream, lease: lease)
        }
        return localURL(for: upstream, port: activePort, mime: mime)
    }

    func release(owner: UInt64) {
        registeredOwners.remove(owner)
        pendingPreparations = pendingPreparations.filter { $0.value != owner }
        activeOwners.remove(owner)
        guard activeOwners.isEmpty else { return }
        readinessGeneration &+= 1
        readinessTask?.cancel()
        readinessTask = nil
        let lease = activeLeaseID
        activeLeaseID = nil
        activePort = 0
        guard let lease else { return }
        VXTrailerNetworkOwner.shared().stopLease(lease)
    }

    private func cancelPreparation(_ preparationID: UInt64, owner: UInt64) {
        guard pendingPreparations[preparationID] == owner else { return }
        pendingPreparations.removeValue(forKey: preparationID)
        guard activePort == 0,
              !pendingPreparations.values.contains(owner) else { return }
        activeOwners.remove(owner)
        guard activeOwners.isEmpty else { return }
        readinessGeneration &+= 1
        readinessTask?.cancel()
        readinessTask = nil
        let lease = activeLeaseID
        activeLeaseID = nil
        activePort = 0
        guard let lease else { return }
        VXTrailerNetworkOwner.shared().stopLease(lease)
    }

    private func register(_ upstream: URL, lease: UInt64) {
        VXTrailerNetworkOwner.shared().registerUpstreamURL(
            upstream.absoluteString,
            userAgent: YouTubeDirectResolver.requiredUserAgent(for: upstream),
            leaseID: lease
        )
    }

    private func localURL(for upstream: URL, port: UInt16, mime: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/yt"
        components.queryItems = [
            URLQueryItem(name: "u", value: Self.base64url(upstream.absoluteString)),
            URLQueryItem(name: "mime", value: mime),
        ]
        return components.url ?? upstream
    }

    private static func base64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
