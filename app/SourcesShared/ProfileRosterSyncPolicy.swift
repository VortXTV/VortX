import Foundation
import CoreFoundation

/// Roster clocks are epoch seconds, not the account document's unrelated updatedAt milliseconds.
enum ProfileRosterSyncPolicy {
    static func validClock(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }

    static func nextLocalClock(now: Double, prior: Double) -> Double {
        let floor = validClock(prior) ?? 0
        let successor = floor.nextUp
        return max(validClock(now) ?? 0, successor.isFinite ? successor : floor)
    }

    static func clockDecision(local: Double, incoming: Double?) -> (preferIncoming: Bool, watermark: Double) {
        let floor = validClock(local) ?? 0
        let peer = validClock(incoming)
        return (peer.map { $0 > floor } ?? false, max(floor, peer ?? 0))
    }

    static func union<Record: Identifiable>(local: [Record], incoming: [Record], preferIncoming: Bool,
        preferHydratedIncoming: (Record, Record) -> Bool = { _, _ in false }) -> [Record] {
        let remote = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(local.map(\.id))
        return local.map { existing in
            guard let peer = remote[existing.id] else { return existing }
            return preferIncoming || preferHydratedIncoming(existing, peer) ? peer : existing
        } + incoming.filter { !localIDs.contains($0.id) }
    }
}

struct ProfileRosterSnapshot {
    let profiles: [UserProfile]
    let modified: Double?

    private static func decode(_ rows: Any?, lossless: Bool = true) -> [UserProfile]? {
        guard let rows = rows as? [[String: Any]], !rows.isEmpty,
              rows.allSatisfy({ row in
                  guard (row["id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
                        (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
                  guard lossless else { return true }
                  // A partial summary must never masquerade as a full record and clear a PIN or own-account binding.
                  let bools = ["oled", "usesOwnAccount", "isOwner", "familyEdit", "isKids"]
                  return (row["avatar"] as? String)?.isEmpty == false
                      && (row["accentID"] as? String)?.isEmpty == false
                      && ProfileRosterSyncPolicy.validClock(row["textScale"]) != nil
                      && bools.allSatisfy { key in
                          guard let number = row[key] as? NSNumber else { return false }
                          return CFGetTypeID(number) == CFBooleanGetTypeID()
                      }
              }), let data = try? JSONSerialization.data(withJSONObject: rows),
              let profiles = try? JSONDecoder().decode([UserProfile].self, from: data) else { return nil }
        return profiles
    }

    static func wire(_ profiles: [UserProfile]) -> [[String: Any]]? {
        guard !profiles.isEmpty, let data = try? JSONEncoder().encode(profiles) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Full roster carriers may compete by their own clocks. The dashboard summary is lossy:
    /// it may supply missing ids, but must not overwrite full same-id account bindings or donate updatedAt.
    static func resolve(settingsDomain: [String: Any]?, vortx: [String: Any]?) -> ProfileRosterSnapshot? {
        let settings = (settingsDomain?["stremiox.profiles"] as? Data)
            .flatMap { try? JSONDecoder().decode([UserProfile].self, from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let settingsClock = ProfileRosterSyncPolicy.validClock(settingsDomain?["stremiox.profiles.modified"])
        let full = decode(vortx?["roster"])
        let fullClock = ProfileRosterSyncPolicy.validClock(vortx?["rosterModified"])
        let summary: [UserProfile]? = (vortx?["profiles"] as? [[String: Any]]).flatMap { rows in
            let translated = rows.map { row -> [String: Any] in
                let settings = row["settings"] as? [String: Any] ?? [:]
                var result = settings
                result["id"] = row["id"]
                result["name"] = row["name"]
                result["isOwner"] = row["main"] as? Bool ?? false
                result["accentID"] = settings["accent"]
                result["pin"] = row["pinHash"]
                result["familyEdit"] = row["familyEdit"]
                result["disabledAddons"] = row["disabledAddons"]
                // A summary's partial playback object is not a Codable PlaybackPrefs record.
                result.removeValue(forKey: "playback")
                return result
            }
            return decode(translated, lossless: false)
        }
        guard let fallback = full ?? summary else {
            return settings.map { ProfileRosterSnapshot(profiles: $0, modified: settingsClock) }
        }
        guard let settings else { return ProfileRosterSnapshot(profiles: fallback, modified: full == nil ? nil : fullClock) }
        let preferFull = full != nil && (fullClock ?? -.infinity) > (settingsClock ?? -.infinity)
        let combined = ProfileRosterSyncPolicy.union(local: settings, incoming: fallback, preferIncoming: preferFull)
        let watermark = full == nil ? settingsClock : [settingsClock, fullClock].compactMap { $0 }.max()
        return ProfileRosterSnapshot(profiles: combined, modified: watermark)
    }
}
