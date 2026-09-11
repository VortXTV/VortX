/// An unavailable native engine still owes the current load a controlled failure receipt.
/// It must not fabricate a native playlist entry or deliver that receipt after close/replacement.
struct MPVInitializationFailureState<Token: Equatable> {
    private(set) var message: String?
    private(set) var activeToken: Token?

    mutating func fail(_ message: String) {
        self.message = message
        activeToken = nil
    }

    mutating func admit(_ token: Token) -> String? {
        guard let message else { return nil }
        activeToken = token
        return message
    }

    func accepts(_ token: Token) -> Bool { message != nil && activeToken == token }

    mutating func invalidateLoad() { activeToken = nil }

    mutating func stop() { message = nil; activeToken = nil }
}
