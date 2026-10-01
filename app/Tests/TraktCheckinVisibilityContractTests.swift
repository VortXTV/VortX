import Foundation

@main
enum TraktCheckinVisibilityContractTests {
    static func main() throws {
        let chip = try String(contentsOfFile: "app/SourcesShared/TraktCheckinChip.swift", encoding: .utf8)
        let model = try String(contentsOfFile: "app/SourcesShared/TraktCheckinModel.swift", encoding: .utf8)
        precondition(chip.contains("if enabled, TraktAuth.storedSessionID != nil, let meta = core.metaDetails?.meta"))
        // A task inside a hidden disconnected branch cannot establish the connection that mounts it.
        precondition(!chip.contains("@State private var connected = false"))
        precondition(!chip.contains("connected = await TraktAuth.shared.isSignedIn"))
        precondition(chip.contains("@ObservedObject private var model = TraktCheckinModel.shared"))
        precondition(model.contains("TraktAuthBoundary.observe(key: \"trakt-checkin-model\")"))
        precondition(model.contains("self?.active = nil"))
        precondition(chip.contains("TraktCheckinModel.canOffer(isSeries: isSeries, season: season, episode: episode)"))
        precondition(chip.contains("private var enabled = false"))
        print("PASS Trakt check-in initial connection visibility and retained opt-in/session eligibility")
    }
}
