import Foundation

/// Uses the current native host credential policy, without sanitizing or wrapping foreign JSON.
/// Call after preparation and again at final native admission; the host pipeline validates too.
enum XperienceImportPrivacy {
    static func validate(_ edit: XperienceImportNamespace.Edit) throws {
        guard edit.field == XperienceImportNamespace.field(edit.namespace),
              try XperienceCollections.canonicalData(edit.value).count <= XperienceCollections.maximumBytes else {
            throw XperienceCollections.Failure.tooLarge
        }
        let source = VortxJSON.object([edit.field: edit.value])
        do {
            let archive = try VortxNativeBootstrapArchive.encode(document: XperienceCollections.canonicalData(source))
            let inspected = try JSONDecoder().decode(VortxJSON.self, from: archive)
            guard inspected["excludedCredentialPaths"] == .array([]),
                  inspected["hostDocument"] == source else { throw XperienceCollections.Failure.unsafeHostValue }
        } catch {
            // The original parser/transport error may contain input. Only a controlled error escapes.
            throw XperienceCollections.Failure.unsafeHostValue
        }
    }
}
