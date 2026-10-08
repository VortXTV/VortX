import Foundation

/// Runs only in the explicit ABI integration harness, against a caller-supplied private artifact.
/// No app process, real account, media decoder or external provider is involved.
@main enum VortxNativeLiveABITests {
    static func check(_ condition: Bool, line: Int = #line) { precondition(condition, "live ABI assertion at line \(line)") }
    static func main() async throws {
        let runtime = try VortxNativeRuntime(abi: VortxCABI(), ownerID: "fixture-owner", ownerName: "Fixture")
        let add = try runtime.dispatch(#"{"type":"add_profile","id":"fixture-kid","name":"Kid"}"#, now: 1000)
        check(add.contains("\"ok\":true"))
        let progress = try runtime.dispatch(#"{"type":"report_progress","metaId":"tt-fixture","videoId":"tt-fixture:1:2","name":"Fixture","positionMs":120000,"durationMs":1200000}"#, now: 1001)
        check(progress.contains("\"ok\":true"))
        let captured = try runtime.stateJSON()
        check(try runtime.takeDeltaJSON() != "{}")
        check(try runtime.takeDeltaJSON() == "{}")
        runtime.close()
        let cold = try VortxNativeRuntime(abi: VortxCABI(), snapshot: captured)
        check(try cold.stateJSON() == captured)
        check(try cold.takeDeltaJSON() == "{}")
        cold.close()

        let fixture = try JSONDecoder().decode([String: VortxJSON].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let port = CommandLine.arguments[2]
        let addon = VortxResourceAddon(id: "source-identity", transportUrl: "http://127.0.0.1:\(port)/manifest.json", manifest: fixture["manifest"])
        let bridge = VortxResourceBridge(transport: try VortxCResourceTransport())
        for resource in [VortxResourceRequest.Resource.catalog, .meta, .stream, .subtitles] {
            let id = resource == .catalog ? "popular" : "tt-fixture"
            let snapshot = try await bridge.load(ownerID: "fixture-owner", request: .init(resource: resource, type: "series", id: id), addons: [addon])
            check(snapshot.groups.count == 1 && snapshot.groups[0].addonId == "source-identity")
            check(snapshot.groups[0].status == .ready)
            check(snapshot.groups[0].content == fixture[resource.rawValue])
        }
        let empty = try await bridge.load(ownerID: "fixture-owner", request: .init(resource: .stream, type: "series", id: "tt-fixture"), addons: [])
        check(empty.groups.isEmpty)
        bridge.invalidate()
        print("Live native Swift C ABI: cold hydration, deltas and localhost catalog/meta/stream/subtitle payloads passed")
    }
}
