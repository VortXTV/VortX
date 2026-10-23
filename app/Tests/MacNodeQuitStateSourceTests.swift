import Foundation

@main
struct MacNodeQuitStateSourceUnit {
    @MainActor
    static func main() async throws {
        precondition(CommandLine.arguments.count == 3)
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        precondition(parent.path == CommandLine.arguments[1])
        let allowedBuildRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        precondition(allowedBuildRoot.path == CommandLine.arguments[2])
        let result = try await NodeServer.runQuitStateFixture(disposableParent: parent, allowedBuildRoot: allowedBuildRoot)
        precondition(Set(result.keys) == Set([
            "scope", "cases", "callbackDeliveries", "realProcessOrAppKitEvidence", "disposableDirectory"
        ]))
        precondition(result["scope"] ==
            "actual V2 admission/completion/launch-fence methods; identity-only Process tokens")
        precondition(result["cases"] == "10")
        precondition(result["callbackDeliveries"] == "12")
        precondition(result["realProcessOrAppKitEvidence"] == "none")
        guard let disposable = result["disposableDirectory"] else { preconditionFailure("missing fixture directory") }
        precondition(disposable.hasPrefix(parent.path + "/quit-state-"))
        print("PASS Mac quit-state source unit: 10 cases, 12 callbacks; no real Process or AppKit evidence")
    }
}
