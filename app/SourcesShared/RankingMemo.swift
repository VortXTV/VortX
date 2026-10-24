import Foundation
import os

/// A bounded, synchronous memo for immutable ranking inputs. Expensive parsing runs outside the lock.
/// An invalidation retires every in-flight miss, so a late computation cannot refill the cleared memo.
/// The lock owns all mutable state; callers never receive a reference to its dictionary.
struct RankingMemo<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct State: Sendable {
        var values: [Key: Value] = [:]
        var generation = UUID()
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())
    private let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func value(for key: Key, compute: () -> Value) -> Value {
        let lookup = storage.withLock { state in
            (value: state.values[key], generation: state.generation)
        }
        if let hit = lookup.value { return hit }
        let value = compute()
        storage.withLock { state in
            guard state.generation == lookup.generation else { return }
            if state.values.count >= capacity { state.values.removeAll(keepingCapacity: true) }
            state.values.updateValue(value, forKey: key)
        }
        return value
    }

    func invalidate() {
        storage.withLock { state in
            state.generation = UUID()
            state.values.removeAll(keepingCapacity: true)
        }
    }
}
