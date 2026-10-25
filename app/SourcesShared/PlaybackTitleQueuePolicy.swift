import Foundation

/// An in-memory queue of content identities. Resolved URLs, headers and leases never enter this model.
struct PlaybackTitleQueuePolicy {
    static let capacity = 100

    struct Candidate: Equatable, Sendable {
        let contentID: String
        let type: String
        let title: String
        let videoIDHint: String?
        let episodeLabel: String?

        init?(contentID: String, type: String, title: String,
              videoIDHint: String? = nil, episodeLabel: String? = nil) {
            guard Self.valid(contentID, limit: 1_024), ["movie", "series"].contains(type),
                  Self.valid(title, limit: 512),
                  videoIDHint.map({ Self.valid($0, limit: 1_024) }) ?? true,
                  episodeLabel.map({ Self.valid($0, limit: 512) }) ?? true,
                  type == "series" || videoIDHint == nil || videoIDHint == contentID else { return nil }
            self.contentID = contentID
            self.type = type
            self.title = title
            self.videoIDHint = videoIDHint
            self.episodeLabel = episodeLabel
        }

        private static func valid(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.utf8.count <= limit
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let candidate: Candidate
    }

    struct Ticket: Equatable, Sendable {
        let id: UUID
        let entryID: UUID
        let revision: UUID
    }

    struct Active: Equatable, Sendable {
        let ticket: Ticket
        let entry: Entry
    }

    enum Placement { case next, last }

    private(set) var upcoming: [Entry] = []
    private(set) var active: Active?
    private(set) var revision = UUID()
    var count: Int { upcoming.count + (active == nil ? 0 : 1) }

    @discardableResult
    mutating func enqueue(_ candidate: Candidate, placement: Placement, id: UUID = UUID()) -> Bool {
        guard count < Self.capacity, active?.entry.id != id,
              !upcoming.contains(where: { $0.id == id }) else { return false }
        let entry = Entry(id: id, candidate: candidate)
        switch placement {
        case .next: upcoming.insert(entry, at: 0)
        case .last: upcoming.append(entry)
        }
        revision = UUID()
        return true
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard let index = upcoming.firstIndex(where: { $0.id == id }) else { return false }
        upcoming.remove(at: index)
        revision = UUID()
        return true
    }

    @discardableResult
    mutating func move(_ id: UUID, by delta: Int) -> Bool {
        guard delta == -1 || delta == 1,
              let index = upcoming.firstIndex(where: { $0.id == id }) else { return false }
        let destination = index + delta
        guard upcoming.indices.contains(destination) else { return false }
        upcoming.swapAt(index, destination)
        revision = UUID()
        return true
    }

    func nextTicket(id: UUID = UUID()) -> Ticket? {
        guard active == nil, let first = upcoming.first else { return nil }
        return Ticket(id: id, entryID: first.id, revision: revision)
    }

    func accepts(_ ticket: Ticket) -> Bool {
        active == nil && ticket.revision == revision && upcoming.first?.id == ticket.entryID
    }

    /// Call only after the ordinary player has accepted the actual first frame and asset identity.
    /// Source-resolution failures and presenter refusal therefore leave the head available to retry.
    @discardableResult
    mutating func acceptStarted(_ ticket: Ticket) -> Bool {
        guard accepts(ticket) else { return false }
        active = Active(ticket: ticket, entry: upcoming.removeFirst())
        revision = UUID()
        return true
    }

    /// This is not an EOF detector. Its caller must provide the existing player's proven completion.
    @discardableResult
    mutating func finish(_ ticketID: UUID) -> Bool {
        guard active?.ticket.id == ticketID else { return false }
        active = nil
        revision = UUID()
        return true
    }

    /// A failed/closed active item remains explicit work. Retry never changes its stable entry ID.
    @discardableResult
    mutating func retryActive() -> Bool {
        guard let active else { return false }
        upcoming.insert(active.entry, at: 0)
        self.active = nil
        revision = UUID()
        return true
    }

    mutating func clearUpcoming() {
        guard !upcoming.isEmpty else { return }
        upcoming.removeAll()
        revision = UUID()
    }
}
