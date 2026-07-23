import Foundation

/// The pure, testable decision core of the tvOS "Install by QR - pair once, add many" flow
/// (`AddonPairingView`). It owns ONLY the state machine: how a phone-relayed manifest URL becomes a row,
/// when that row AUTO-INSTALLS, how a duplicate delivery collapses to one install, and how a failed install
/// surfaces a manual recovery. It performs no I/O - every fetch / validate / install is an `Effect` the view
/// executes against `CoreBridge` and reports back as an `Event`, so the whole decision surface runs (and is
/// tested) without SwiftUI, the network, or the engine.
///
/// WHY A REAL REDUCER (not a view-local `@State` tangle): the prior attempt welded the auto-install logic to
/// the SwiftUI view + `CoreBridge.shared`, and its "test" re-implemented that logic in a separate mirror, so
/// nothing verified the SHIPPED path - the auto-install could silently regress to "still needs a manual tap"
/// and the mirror would still pass. This type IS the shipped path; `AddonPairingReducerTests` compiles THIS
/// file directly, so add-then-auto-install-then-Done is proven against the real code, never a copy.
///
/// THE CONTRACT this encodes:
///  - AUTO-INSTALL: when a delivery resolves `.ready`, the reducer itself emits `.install` - no user tap.
///  - IDEMPOTENT per delivery id: rows are keyed by `session + normalized identity`, so a re-poll re-delivering
///    the same URL adds no second row and dispatches no second install (two guards: the merge dedup and the
///    `autoInstalled` once-set).
///  - HONEST failure: an engine install failure lands `.failed`, which is manual-actionable, so the view shows
///    a focusable Retry; `.invalid` (malformed / bad manifest) is NEVER counted as success.
///  - WRONG-SESSION refusal: a submission not bound to the live session token is dropped with no state change.
enum AddonPairingReducer {

    // MARK: - State

    /// One incoming manifest URL and where it is in the install lifecycle on THIS device. Identified by
    /// `sessionToken + identity` (never the URL alone) so a resubmission under a NEW pairing session is a
    /// distinct row while a duplicate delivery inside the SAME session collapses to one.
    struct Row: Identifiable, Equatable {
        let sessionToken: String        // the pairing session this submission is bound to
        let url: String                 // the raw URL the phone added (relay-provided)
        let identity: String            // normalized manifest URL: the dedup + install-once key
        var name: String?               // resolved add-on name once the manifest validates
        var state: RowState

        static func makeId(sessionToken: String, identity: String) -> String {
            sessionToken + "\u{1}" + identity
        }
        var id: String { Self.makeId(sessionToken: sessionToken, identity: identity) }
    }

    enum RowState: Equatable {
        case resolving     // fetching + validating the manifest
        case ready         // valid manifest, awaiting (or racing) auto-install; manual Install as recovery
        case invalid       // manifest failed validation (not installable) - NEVER a success
        case installing
        case installed
        case failed(String)

        /// Non-terminal: work is still outstanding for this row. Drives the "working" batch state and keeps
        /// Done from silently exiting a still-pending submission.
        var isInFlight: Bool {
            switch self {
            case .resolving, .ready, .installing: return true
            case .invalid, .installed, .failed:   return false
            }
        }
        /// A row the user can act on by hand: auto-install skipped it (`.ready`) or it failed (`.failed`). These
        /// are the states that render a FOCUSABLE Install / Retry control (the manual-recovery contract).
        var isManualActionable: Bool {
            switch self {
            case .ready, .failed: return true
            default:              return false
            }
        }
    }

    /// The full pairing state: the live rows plus the set of row ids an install has already been DISPATCHED
    /// for (the install-exactly-once guard). Value type, so a test drives it with plain `inout` calls.
    struct State: Equatable {
        var rows: [Row] = []
        var autoInstalled: Set<String> = []
    }

    // MARK: - Events (inputs) and Effects (outputs the host performs)

    /// The outcome the host reports after performing a `.resolve` effect (fetch + validate via CoreBridge).
    enum ResolveOutcome: Equatable {
        case invalid                       // no valid normalized URL, or the manifest failed validation
        case ready(name: String)           // valid, installable, not yet present
        case alreadyInstalled(name: String) // valid and already present → idempotent success, no install
    }

    /// The outcome the host reports after performing an `.install` effect (CoreBridge.installAddon).
    enum InstallOutcome: Equatable {
        case installed                     // success, or an idempotent duplicate that ended up present
        case failed(String)                // engine install failed → manual Retry
    }

    enum Event {
        /// The relay poll delivered `urls` for `sessionToken`; `liveToken` is the view's CURRENT session token.
        /// A delivery whose token is not the live one is refused (wrong / rotated session).
        case delivered(urls: [String], sessionToken: String, liveToken: String?)
        case resolved(rowId: String, outcome: ResolveOutcome)
        case installFinished(rowId: String, outcome: InstallOutcome)
        /// The user tapped Install / Retry - deliberate manual recovery, NOT gated by the auto-install-once set.
        case manualInstall(rowId: String)
        /// The session rotated to `liveToken`; drop any non-terminal row bound to a now-dead session so Done is
        /// never pinned "working" forever by a submission whose phone page is gone.
        case sessionRotated(liveToken: String)
    }

    /// Work the host (the SwiftUI view) must perform against CoreBridge, reporting the result back as an Event.
    enum Effect: Equatable {
        case resolve(rowId: String, url: String)
        case install(rowId: String, url: String)
    }

    // MARK: - The single transition

    /// Reduce one event into `state`, returning the effects the host must perform. `normalize` maps a raw URL
    /// to its canonical manifest identity (nil = malformed / non-http(s)); the view passes
    /// `CoreBridge.normalizedAddonURL`, a test passes an equivalent.
    static func reduce(_ state: inout State, _ event: Event, normalize: (String) -> String?) -> [Effect] {
        switch event {
        case let .delivered(urls, sessionToken, liveToken):
            // Only the live session's submissions are acted on; binding the row to `sessionToken` makes a
            // wrong-session URL structurally unable to install.
            guard sessionToken == liveToken else { return [] }
            let known = Set(state.rows.map(\.id))
            var effects: [Effect] = []
            for url in urls {
                let normalized = normalize(url)
                let identity = normalized ?? url
                let rowId = Row.makeId(sessionToken: sessionToken, identity: identity)
                guard !known.contains(rowId) else { continue }   // duplicate delivery → no 2nd row / install
                if normalized == nil {
                    // Malformed: reject in place with NO partial state - never resolves, never installs.
                    state.rows.append(Row(sessionToken: sessionToken, url: url, identity: identity, name: nil, state: .invalid))
                } else {
                    state.rows.append(Row(sessionToken: sessionToken, url: url, identity: identity, name: nil, state: .resolving))
                    effects.append(.resolve(rowId: rowId, url: url))
                }
            }
            return effects

        case let .resolved(rowId, outcome):
            guard let idx = state.rows.firstIndex(where: { $0.id == rowId }) else { return [] }
            switch outcome {
            case .invalid:
                state.rows[idx].state = .invalid
                return []
            case let .alreadyInstalled(name):
                state.rows[idx].name = name
                state.rows[idx].state = .installed     // idempotent: already present is a success, not an install
                return []
            case let .ready(name):
                state.rows[idx].name = name
                state.rows[idx].state = .ready
                return autoInstallIfEligible(&state, rowId: rowId)   // AUTO-INSTALL: no manual tap
            }

        case let .installFinished(rowId, outcome):
            guard let idx = state.rows.firstIndex(where: { $0.id == rowId }) else { return [] }
            switch outcome {
            case .installed:            state.rows[idx].state = .installed
            case let .failed(message):  state.rows[idx].state = .failed(message)
            }
            return []

        case let .manualInstall(rowId):
            guard let idx = state.rows.firstIndex(where: { $0.id == rowId }),
                  state.rows[idx].state.isManualActionable else { return [] }
            state.autoInstalled.insert(rowId)
            let url = state.rows[idx].url
            state.rows[idx].state = .installing
            return [.install(rowId: rowId, url: url)]

        case let .sessionRotated(liveToken):
            state.rows.removeAll { $0.sessionToken != liveToken && $0.state.isInFlight }
            return []
        }
    }

    /// Emit an install for a freshly-resolved row EXACTLY once: only when it is `.ready` and has not already
    /// been dispatched. A second `.resolved(.ready)` for the same row (or a replay) is refused here, so the
    /// once-guard holds even if resolution is delivered twice.
    private static func autoInstallIfEligible(_ state: inout State, rowId: String) -> [Effect] {
        guard let idx = state.rows.firstIndex(where: { $0.id == rowId }),
              state.rows[idx].state == .ready,
              !state.autoInstalled.contains(rowId) else { return [] }
        state.autoInstalled.insert(rowId)
        let url = state.rows[idx].url
        state.rows[idx].state = .installing
        return [.install(rowId: rowId, url: url)]
    }

    // MARK: - Pure aggregate reductions (batch banner + Done)

    /// The aggregate outcome of the current batch. `.invalid` and `.failed` are NON-success, so an
    /// invalid-only or partially-failed batch never reports `.allInstalled`.
    enum BatchStatus: Equatable {
        case empty
        case working
        case allInstalled(Int)
        case partial(installed: Int, failed: Int, invalid: Int)
    }

    static func batchStatus(_ states: [RowState]) -> BatchStatus {
        guard !states.isEmpty else { return .empty }
        if states.contains(where: { $0.isInFlight }) { return .working }
        var installed = 0, failed = 0, invalid = 0
        for s in states {
            switch s {
            case .installed: installed += 1
            case .invalid:   invalid += 1
            case .failed:    failed += 1
            default:         break
            }
        }
        if installed == states.count { return .allInstalled(installed) }
        return .partial(installed: installed, failed: failed, invalid: invalid)
    }

    /// Done's label + enabled state. While any submission is still in flight Done is disabled and reads
    /// "Installing…", so it can never silently drop a pending valid submission; once every row is terminal it
    /// re-enables as "Done".
    static func doneState(_ status: BatchStatus) -> (title: String, enabled: Bool) {
        switch status {
        case .working:                        return ("Installing…", false)
        case .empty, .allInstalled, .partial: return ("Done", true)
        }
    }
}
