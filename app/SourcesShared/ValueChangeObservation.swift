import SwiftUI

extension View {
    /// Observe a changed value without an initial callback, including the supported iOS 16 floor.
    /// Keep the single new-value action at call sites; no Task, queue or extra observation is added.
    @MainActor
    @ViewBuilder
    func onValueChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            onChange(of: value, initial: false) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }

    /// For effects that must retire the previous observed value (for example a replaced lease).
    /// The modern overload supplies that old value; iOS 16 retains its equivalent capture-list form.
    @MainActor
    @ViewBuilder
    func onValueChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            onChange(of: value, initial: false, action)
        } else {
            onChange(of: value) { [value] newValue in action(value, newValue) }
        }
    }
}
