import Foundation

/// Read-only display facts. Only accepted metadata for the exact type and title may provide
/// genres. Missing, malformed and empty facts remain unknown; this never writes membership,
/// makes a request or reinterprets an id/title as a genre.
enum LibraryGenreFacts {
    static func normalized(_ values: [String]?) -> [String]? {
        var seen = Set<String>()
        let result = (values ?? []).compactMap { raw -> String? in
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            let key = label.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return seen.insert(key).inserted ? label : nil
        }
        return result.isEmpty ? nil : result
    }

    /// Matches CoreMeta/CoreMetaItem's existing Genre/Genres link categories. Callers retain their
    /// accepted account/profile/registry fences; matching a title alone grants no mutation authority.
    static func acceptedMetadata(_ meta: VortxJSON, id: String, type: String) -> [String]? {
        guard meta["id"] == .string(id), meta["type"] == .string(type) else { return nil }
        let labels = (meta["links"]?.array ?? []).compactMap { link -> String? in
            guard case .string(let category) = link["category"],
                  ["genre", "genres"].contains(category.lowercased()),
                  case .string(let label) = link["name"] else { return nil }
            return label
        }
        return normalized(labels)
    }

    static func acceptedMetadata(data: Data?, id: String, type: String) -> [String]? {
        guard let data, let meta = try? JSONDecoder().decode(VortxJSON.self, from: data) else { return nil }
        return acceptedMetadata(meta, id: id, type: type)
    }

    /// The native optional field is deliberately permissive for forward compatibility. Only a
    /// complete string array is UI evidence; an opaque future shape is kept by native persistence.
    static func projected(_ value: VortxJSON?) -> [String]? {
        guard case .array(let values) = value else { return nil }
        var labels: [String] = []
        for value in values {
            guard case .string(let label) = value else { return nil }
            labels.append(label)
        }
        return normalized(labels)
    }

    static func wire(_ values: [String]?) -> VortxJSON? {
        normalized(values).map { .array($0.map(VortxJSON.string)) }
    }
}
