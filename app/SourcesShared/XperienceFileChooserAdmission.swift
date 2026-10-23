import Foundation

/// Single-use ownership for one platform file chooser and its resulting read.
/// This type performs no file, native-store, account or transport operation.
struct XperienceFileChooserAdmission {
    struct Ticket: Equatable, Hashable, Sendable {
        let id: UUID
        let generation: UUID
    }

    private enum Phase: Equatable {
        case choosing(Ticket)
        case reading(Ticket)
    }
    private var phase: Phase?

    mutating func begin(generation: UUID) -> Ticket {
        let ticket = Ticket(id: UUID(), generation: generation)
        phase = .choosing(ticket)
        return ticket
    }

    /// A provider result may schedule exactly one read for the exact original presentation.
    mutating func admit(_ ticket: Ticket, currentGeneration: UUID) -> Bool {
        guard ticket.generation == currentGeneration, phase == .choosing(ticket) else { return false }
        phase = .reading(ticket)
        return true
    }

    /// Keep the same ticket alive through read completion, not just at chooser admission.
    func permitsPublication(_ ticket: Ticket, currentGeneration: UUID) -> Bool {
        ticket.generation == currentGeneration && phase == .reading(ticket)
    }

    @discardableResult mutating func finish(_ ticket: Ticket, currentGeneration: UUID) -> Bool {
        guard permitsPublication(ticket, currentGeneration: currentGeneration) else { return false }
        phase = nil
        return true
    }

    /// A late old failure or cancellation must not cancel its successor's chooser/read.
    @discardableResult mutating func cancel(_ ticket: Ticket, currentGeneration: UUID) -> Bool {
        guard ticket.generation == currentGeneration,
              phase == .choosing(ticket) || phase == .reading(ticket) else { return false }
        phase = nil
        return true
    }

    mutating func invalidate() { phase = nil }
}
