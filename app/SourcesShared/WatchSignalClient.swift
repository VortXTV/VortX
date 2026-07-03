import Foundation

/// Fleet WATCH SIGNAL (D9): the anonymized "this fleet watched X today" ping that powers VortX's OWN
/// Trending / Popular / Most-Watched rows (a real data moat instead of TMDB-only rankings).
///
/// Contract (matches the `watch.vortx.tv` worker, which is created + deployed separately and is owner-gated,
/// so this client MUST fail soft until it exists):
///   POST https://watch.vortx.tv/ping   body: { "content_id": "tt1234567", "day": "2026-07-02" }
///   - content_id: the title's imdb `tt…` id (never a season/episode/tmdb id, so a series aggregates by show).
///   - day: a UTC day bucket (YYYY-MM-DD), so the worker can dedup one witness per title/day.
/// The worker adds a daily-salted IP-hash witness dedup of its own (like vortx-sources); NO user id / token /
/// PII is ever sent from here.
///
/// PRIVACY + GATING (give-to-get): every send is gated on `MoatConsent.contributeAndConsume` (the one master
/// pool switch) AND edge-auth signed (`VortXEdgeAuth`, observe-safe). One ping per (content_id, day) PER DEVICE
/// is sent at most once: a local UserDefaults set dedups so a long watch / re-open / episode-hop never
/// re-pings. Fully fail-soft: any miss / error / offline / not-yet-deployed worker leaves no trace and never
/// disturbs playback.
///
/// Confidentiality: the user-facing framing is the generic anonymized-playback disclosure (`MoatConsent`);
/// this file's role in the ranking moat is never surfaced in any public artifact.
enum WatchSignalClient {

    /// The watch-signal edge. Baked (not a RemoteConfig dial yet, unlike trickplay/catalogs): the worker is
    /// owner-gated and created separately; keep the host in sync with `VortXEdgeAuth.gatedHosts`.
    private static let baseURL = "https://watch.vortx.tv"

    /// UserDefaults key holding the set of already-pinged "contentId|day" markers, so a device pings a given
    /// title at most once per day. Bounded (pruned to the last ~500 markers) so it can't grow without limit.
    private static let sentKey = "stremiox.watchSignalSent"
    private static let sentCap = 500

    /// UserDefaults key for this install's stable, non-PII dedupe id sent in the `X-VX-Watcher` header. Minted
    /// once (a random UUID) and reused, so the worker's `callerHash` dedupes accurately PER DEVICE instead of
    /// falling back to a coarse IP+UA fingerprint (which over-dedups a household behind one NAT and under-dedups
    /// a single device roaming Wi-Fi to cellular). Not tied to any account, carries no PII, and the worker
    /// hashes it (SHA-256) so the raw value is never persisted server-side.
    private static let watcherIdKey = "stremiox.watchSignalWatcherId"

    /// The stable per-install watcher id, minted lazily on first use and reused forever after. An opaque random
    /// UUID (non-PII); the worker only ever stores its hash.
    private static func watcherId() -> String {
        if let existing = UserDefaults.standard.string(forKey: watcherIdKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: watcherIdKey)
        return fresh
    }

    /// UTC day bucket for `date` as YYYY-MM-DD. UTC (not local) so the whole fleet buckets on the same day
    /// boundary as the worker.
    private static func dayBucket(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Send ONE anonymized watch ping for `contentId` (an imdb `tt…` id) if the pool consent is on and this
    /// title has not already been pinged today from this device. Fire-and-forget + fully fail-soft.
    ///
    /// Call from the same ~60s "the user is really watching this" playback tick that auto-adds to the Library,
    /// so a ping represents a real watch (not a hover / a mistaken open). Series pass the SHOW's tt id so the
    /// ranking aggregates by title, not by episode.
    ///
    /// `type` is the title's kind ("movie" / "series"); it is sent so the worker can group Trending / Popular
    /// by type (its `/popular?type=series` row is empty otherwise, since it defaults a missing type to "movie").
    /// The worker validates + lowercases it, so any non-conforming value is harmless.
    static func ping(contentId: String, type: String) {
        // GIVE-TO-GET: no contribution without pool consent (and no consumption of the Trending rows either).
        guard MoatConsent.contributeAndConsume else { return }
        // Only real imdb ids witness the pool (a tmdb:/kitsu:/synthetic id is never a shareable identity).
        guard contentId.range(of: #"^tt\d{6,}$"#, options: .regularExpression) != nil else { return }

        let day = dayBucket()
        let marker = "\(contentId)|\(day)"
        guard !alreadySent(marker) else { return }   // one ping per title/day/device
        markSent(marker)                              // record BEFORE the request so a retry storm can't double-send

        guard let url = URL(string: "\(baseURL)/ping"),
              let body = try? JSONSerialization.data(withJSONObject: ["content_id": contentId, "day": day, "type": type])
        else { return }

        let watcher = watcherId()   // stable per-install dedupe id (resolve on the caller so the store read is deterministic)

        Task.detached(priority: .background) {
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(watcher, forHTTPHeaderField: "X-VX-Watcher")   // per-device dedupe (hashed worker-side; no PII)
            req.httpBody = body
            VortXEdgeAuth.sign(&req)   // gated host (watch.vortx.tv): stamp X-VX-Ts / X-VX-Kid / X-VX-Sig
            // Fail-soft: the worker may not be deployed yet (owner-gated). Any error / non-200 is swallowed;
            // the local marker already prevents a re-send today, and tomorrow's bucket retries naturally.
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: - Local per-day dedup

    private static func alreadySent(_ marker: String) -> Bool {
        let sent = UserDefaults.standard.stringArray(forKey: sentKey) ?? []
        return sent.contains(marker)
    }

    private static func markSent(_ marker: String) {
        var sent = UserDefaults.standard.stringArray(forKey: sentKey) ?? []
        guard !sent.contains(marker) else { return }
        sent.append(marker)
        if sent.count > sentCap { sent.removeFirst(sent.count - sentCap) }   // keep it bounded (drop oldest)
        UserDefaults.standard.set(sent, forKey: sentKey)
    }
}
