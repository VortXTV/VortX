import Foundation
import CryptoKit

/// Same synthetic JSON vectors as Android. Runs the actual accepted Apple material projector,
/// never a reimplemented oracle. Authored UNRUN; this file makes no native/JNI or account claim.
@main
struct AccountFileProfileMaterialParityTests {
    private struct Failure: Error { let description: String }
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    static func main() throws {
        try require(CommandLine.arguments.count == 4, "Pass profile vectors, URL vectors, and a new oracle output path")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let fixture = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let ownerText = fixture["owner"] as? String, let owner = UUID(uuidString: ownerText),
              let child = fixture["child"] as? String,
              let cases = fixture["cases"] as? [[String: Any]] else { throw Failure(description: "Fixture shape") }
        var positives = 0, negatives = 0
        for row in cases {
            guard let name = row["name"] as? String, let source = row["source"] as? [String: Any],
                  let shouldReject = row["expectReject"] as? Bool,
                  let vortx = source["vortx"] as? [String: Any], let rawRoster = vortx["roster"] as? [[String: Any]],
                  let modified = vortx["rosterModified"] as? Double else { throw Failure(description: "Case shape") }
            // These are authored, well-typed synthetic fixtures. Strict raw admission is exercised
            // by Android; this independent oracle uses the actual Apple Codable and projector.
            let rosterBytes = try JSONSerialization.data(withJSONObject: rawRoster, options: [.sortedKeys, .withoutEscapingSlashes])
            let roster = try JSONDecoder().decode([UserProfile].self, from: rosterBytes)
            let document = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys, .withoutEscapingSlashes])
            let attempt = Result {
                try VortxLegacyBootstrapMaterial.prepare(document: document, roster: roster,
                    ownerProfileID: owner, rosterModifiedSeconds: modified, deferProfileEdits: false,
                    accountID: "account.file-profile-parity")
            }
            if shouldReject {
                switch attempt {
                case .failure: break
                case .success(let result): try require(!result.held.isEmpty, "Expected held preference: \(name)")
                }
                negatives += 1
                continue
            }
            let result: VortxLegacyBootstrapMaterial.Preparation
            switch attempt {
            case .success(let prepared): result = prepared
            case .failure(let error): throw Failure(description: "Apple preparation failed for \(name): \(error)")
            }
            try require(result.held.isEmpty, "Unexpected held preference: \(name)")
            guard let material = try JSONSerialization.jsonObject(with: result.material) as? [String: Any],
                  let profiles = material["roster"] as? [[String: Any]],
                  let kid = profiles.first(where: { ($0["id"] as? String) == child }),
                  let settings = kid["settings"] as? [String: Any],
                  let expected = row["expectedChildSettings"] as? [String: Any] else { throw Failure(description: "Material shape") }
            for key in ["disabledAddons", "languages", "ranking"] {
                if let expectedValue = expected[key] {
                    guard let actualValue = settings[key] else { throw Failure(description: "Missing setting: \(name)/\(key)") }
                    let left = try JSONSerialization.data(withJSONObject: expectedValue, options: [.sortedKeys, .fragmentsAllowed])
                    let right = try JSONSerialization.data(withJSONObject: actualValue, options: [.sortedKeys, .fragmentsAllowed])
                    try require(left == right, "Apple fixture difference: \(name)/\(key)")
                } else { try require(settings[key] == nil, "Unexpected setting: \(name)/\(key)") }
            }
            let account = kid["account"] as? [String: String]
            let parental = kid["parental"] as? [String: Bool]
            try require(account?["kind"] == "shared" && account?["value"] == ownerText, "Shared membership")
            try require(parental?["kids"] == true && parental?["familyEdit"] == true, "Parental policy")
            try require(kid["pin"] as? String == "sha256:" + String(repeating: "a", count: 64), "PIN")
            positives += 1
        }
        try require(positives >= 15 && negatives >= 6, "Incomplete parity matrix")
        print("Actual Apple profile material parity: \(positives) positives, \(negatives) held-preference negatives")
        try writeURLOracle(profileFixture: fixture,
            vectorsURL: URL(fileURLWithPath: CommandLine.arguments[2]),
            outputURL: URL(fileURLWithPath: CommandLine.arguments[3]))
    }

    /// These outcomes are produced by the ACTUAL Apple projector after the fixed preference
    /// matrix passes. No Foundation URL behavior is reimplemented or guessed in this oracle.
    /// The Kotlin consumer requires the exact output hash and exact input-vector hash.
    private static func writeURLOracle(profileFixture: [String: Any], vectorsURL: URL, outputURL: URL) throws {
        let bytes = try Data(contentsOf: vectorsURL)
        guard let vectors = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let rows = vectors["cases"] as? [[String: String]],
              let ownerText = profileFixture["owner"] as? String, let owner = UUID(uuidString: ownerText),
              let child = profileFixture["child"] as? String,
              let profileCases = profileFixture["cases"] as? [[String: Any]],
              let original = profileCases.first?["source"] as? [String: Any],
              let originalVortx = original["vortx"] as? [String: Any],
              let originalRoster = originalVortx["roster"] as? [[String: Any]],
              let modified = originalVortx["rosterModified"] as? Double else { throw Failure(description: "URL vector shape") }
        try require(Set(rows.compactMap { $0["name"] }).count == rows.count, "Unique URL vector names")
        var results: [[String: Any]] = []
        for row in rows {
            guard let name = row["name"], let url = row["url"] else { throw Failure(description: "URL vector fields") }
            let rosterValues = originalRoster.map { input -> [String: Any] in
                var profile = input
                if profile["id"] as? String == child {
                    profile["addonPreferences"] = ["disabledAddonURLsOverride": [url]]
                }
                return profile
            }
            let rosterBytes = try JSONSerialization.data(withJSONObject: rosterValues, options: [.sortedKeys, .withoutEscapingSlashes])
            let roster = try JSONDecoder().decode([UserProfile].self, from: rosterBytes)
            var vortx = originalVortx; vortx["roster"] = rosterValues
            var source = original; source["vortx"] = vortx
            let document = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys, .withoutEscapingSlashes])
            let attempt = Result {
                try VortxLegacyBootstrapMaterial.prepare(document: document, roster: roster,
                    ownerProfileID: owner, rosterModifiedSeconds: modified, deferProfileEdits: false,
                    accountID: "account.file-url-parity")
            }
            switch attempt {
            case .failure: results.append(["name": name, "rejected": true])
            case .success(let prepared):
                if !prepared.held.isEmpty { results.append(["name": name, "rejected": true]); continue }
                guard let material = try JSONSerialization.jsonObject(with: prepared.material) as? [String: Any],
                      let profiles = material["roster"] as? [[String: Any]],
                      let kid = profiles.first(where: { ($0["id"] as? String) == child }),
                      let settings = kid["settings"] as? [String: Any],
                      let disabled = settings["disabledAddons"] as? [String], disabled.count == 1 else {
                    throw Failure(description: "Unexpected successful URL material shape")
                }
                results.append(["name": name, "rejected": false, "normalized": disabled[0]])
            }
        }
        let receipt: [String: Any] = ["format": 1,
            "vectorsSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "results": results]
        let output = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes])
        try output.write(to: outputURL, options: .withoutOverwriting)
        print("Actual Apple URL oracle produced: \(results.count) cases; SHA256 \(SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined())")
    }
}
