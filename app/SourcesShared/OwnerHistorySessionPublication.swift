import Foundation

/// Two explicitly separate surfaces: exact persistence/export bytes and disposable UI values.
/// Presentation has no encoder or conversion back to Checkpoint. Unknown source fields, number
/// tokens (including negative zero), tombstones and journal histories remain in raw checkpoint.
struct OwnerHistorySessionPublication: Sendable {
    let checkpoint: OwnerHistorySessionCoordinator.Checkpoint
    private let source: any VortxMutationAuthority
    init(checkpoint: OwnerHistorySessionCoordinator.Checkpoint, source: any VortxMutationAuthority) {
        self.checkpoint = checkpoint; self.source = source
    }

    func completeAccount(using transaction: OwnerHistoryPreparedExport) throws -> Data {
        var bytes: Data?
        try transaction.withActive {
            try source.withActive {
                bytes = try transaction.projected(checkpoint).validatedPlaintext(writeV2: transaction.writeV2)
            }
        }
        guard let bytes else { throw VortxNativeError.invalidSnapshot }
        return bytes
    }

    /// Only the native composed VIEW response is decoded for UI. Never decode the full state,
    /// nativeSync, ownerHistory, source archives or unknown account siblings into VortxJSON.
    struct Presentation: Sendable {
        let fence: Data
        let items: [VortxJSON]
        let watchedOnlyLibrary: [VortxJSON]
        let playback: VortxJSON
        let holds: [String]
        init(view: Data, expectedFence: Data) throws {
            let object = try OwnerHistoryExactJSON.Object(view)
            guard Set(object.fields.keys) == ["kind", "fence", "items", "watchedOnlyLibrary", "playback", "holds"],
                  try object.text("kind") == "view",
                  try OwnerHistoryExactJSON.canonical(object.required("fence")) == OwnerHistoryExactJSON.canonical(expectedFence) else {
                throw VortxNativeError.invalidResponse
            }
            let decoder = JSONDecoder()
            fence = try object.required("fence")
            items = try decoder.decode([VortxJSON].self, from: object.required("items"))
            watchedOnlyLibrary = try decoder.decode([VortxJSON].self, from: object.required("watchedOnlyLibrary"))
            playback = try decoder.decode(VortxJSON.self, from: object.required("playback"))
            guard case .object = playback else { throw VortxNativeError.invalidResponse }
            holds = try decoder.decode([String].self, from: object.required("holds"))
        }
    }
}
