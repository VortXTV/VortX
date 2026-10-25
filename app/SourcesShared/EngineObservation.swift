import Combine
import SwiftUI
import os

/// Only scalar visibility crosses DynamicProperty.update's nonisolated requirement.
/// No publisher, external callback or actor hop occurs under this checked lock.
fileprivate final class EngineObservationVisibility: Sendable {
    private struct State: Sendable {
        var isOpen = true
        var missed = false
    }
    private let storage = OSAllocatedUnfairLock(initialState: State())
    var isOpen: Bool { storage.withLock { $0.isOpen } }
    func acceptsChange() -> Bool {
        storage.withLock { value in
            if value.isOpen { return true }
            value.missed = true
            return false
        }
    }
    @discardableResult
    func setOpen(_ open: Bool, announce: Bool) -> Bool {
        storage.withLock { value in
            guard open != value.isOpen else { return false }
            value.isOpen = open
            guard open, value.missed else { return false }
            value.missed = false
            return announce
        }
    }
}

/// Broad bridge updates still include every legacy @Published field. Their source
/// remains mixed, so an actual serial main-queue scheduler, not a lexical actor
/// annotation on sink, establishes the executor before touching UI-owned state.
final class EngineChangeGate: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let visibility: EngineObservationVisibility
    @MainActor private var subscription: AnyCancellable?
    var isOpen: Bool { visibility.isOpen }

    @MainActor convenience init() { self.init(core: CoreBridge.shared) }
    @MainActor convenience init(core: CoreBridge) {
        self.init(core: core, visibility: EngineObservationVisibility())
    }
    @MainActor fileprivate init(core: CoreBridge, visibility: EngineObservationVisibility) {
        self.visibility = visibility
        subscription = core.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // receive(on: main) is the actual executor boundary. The checked
                // assertion cannot substitute for, or precede, that scheduler.
                MainActor.assumeIsolated { self?.receiveCoreChange() }
            }
    }
    @MainActor private func receiveCoreChange() {
        if visibility.acceptsChange() { objectWillChange.send() }
    }
    @MainActor func setOpen(_ open: Bool, announce: Bool) {
        if visibility.setOpen(open, announce: announce) { objectWillChange.send() }
    }
}

/// The drawn stream is emitted/replayed only by the real MainActor-owned
/// MetadataPresentation. The broad panel-open stream remains the scheduled
/// mixed legacy bridge source; no legacy nonmetadata update is dropped.
final class PlayerEngineChanges: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    @MainActor private var subscriptions: [AnyCancellable] = []
    @MainActor private(set) var followsAll = false

    @MainActor convenience init() { self.init(core: CoreBridge.shared) }
    @MainActor init(core: CoreBridge) {
        let drawn = Publishers.Merge(core.streamsEpochPublisher.dropFirst().map { _ in () },
                                     core.metaDetailsPublisher.dropFirst().map { _ in () })
        subscriptions = [
            drawn.sink { [weak self] in
                // This subscription/replay is constructed here on MainActor;
                // the real owner also performs every accepted send on MainActor.
                MainActor.assumeIsolated { self?.receiveDrawnChange() }
            },
            core.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.receiveCoreChange() }
                },
        ]
    }
    @MainActor private func receiveDrawnChange() { objectWillChange.send() }
    @MainActor private func receiveCoreChange() {
        if followsAll { objectWillChange.send() }
    }
    @MainActor func followAll(_ on: Bool) {
        guard on != followsAll else { return }
        followsAll = on
        if on { objectWillChange.send() }
    }
}

private struct EngineObservationActiveKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var engineObservationActive: Bool {
        get { self[EngineObservationActiveKey.self] }
        set { self[EngineObservationActiveKey.self] = newValue }
    }
}

/// The State/StateObject pair is made by a MainActor View initializer and retained
/// at one DynamicProperty identity. update reads only the checked scalar mirror:
/// no actor-owned gate reference, Task, assumeIsolated or main.sync is needed.
@propertyWrapper
struct VisibleCore: DynamicProperty {
    @State private var visibility: EngineObservationVisibility
    @StateObject private var gate: EngineChangeGate
    @Environment(\.engineObservationActive) private var active

    @MainActor init() {
        let visibility = EngineObservationVisibility()
        _visibility = State(initialValue: visibility)
        _gate = StateObject(wrappedValue: EngineChangeGate(core: CoreBridge.shared, visibility: visibility))
    }
    @MainActor var wrappedValue: CoreBridge {
        _ = gate
        return CoreBridge.shared
    }
    func update() { visibility.setOpen(active, announce: false) }
}
