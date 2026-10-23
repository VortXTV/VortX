import Foundation

/// A missing signed-out document may start empty. An unreadable existing document must never
/// become the baseline for a replacement write, which would discard other profiles' saved data.
enum ForYouLocalStorageDocument {
    enum Failure: Error, LocalizedError {
        case unreadable

        var errorDescription: String? {
            "Your saved preferences on this device couldn't be read. They have not been replaced. Please export diagnostics before trying to repair them."
        }
    }

    static func decodeForMutation<Value: Decodable>(
        _ storedObject: Any?, as type: Value.Type, empty: @autoclosure () -> Value
    ) throws -> Value {
        guard let storedObject else { return empty() }
        guard let data = storedObject as? Data else { throw Failure.unreadable }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw Failure.unreadable }
    }
}
