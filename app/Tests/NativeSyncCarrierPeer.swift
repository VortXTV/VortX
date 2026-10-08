import Foundation
import CryptoKit

/// A fixture-only OS-process peer. Uses the production native session/checkpoint and account
/// crypto, but deliberately injects loopback HTTP rather than touching an installed app/account.
@main enum NativeSyncCarrierPeer {
    struct Edit: Decodable { let profileID: String?; let fields: [String: VortxJSON] }
    struct Command: Decodable {
        let mode: String
        let directory: String
        let baseURL: String
        let actor: String
        let wireVersion: Int?
        let now: UInt64?
        let actions: [VortxJSON]?
        let hostEdits: [Edit]?
    }
    struct NoResources: VortxResourceTransport {
        func makeCancellation() throws -> any VortxResourceCancellation { throw VortxNativeError.unavailable }
        func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String { throw VortxNativeError.unavailable }
    }
    static let account = "account.sync-fixture"
    static let owner = "10000000-0000-0000-0000-000000000001"
    static let key = Data(repeating: 1, count: 32) // Public synthetic fixture key, never a user key.

    static func http(_ command: Command, method: String, body: Data? = nil) async throws -> (Int, Data) {
        guard let base = URL(string: command.baseURL), base.scheme == "http", base.host == "127.0.0.1",
              let url = URL(string: "/v1/backup", relativeTo: base) else { throw VortxNativeError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, data.count < 8 * 1_024 * 1_024 else { throw VortxNativeError.invalidResponse }
        return (status, data)
    }
    static func pull(_ command: Command) async throws -> (VortxJSON, Int) {
        let (status, bytes) = try await http(command, method: "GET")
        if status == 404 { return (.object(["format": .integer(1), "fixtureSibling": .string("retain-me")]), 0) }
        guard status == 200 else { throw VortxNativeError.invalidResponse }
        let envelope = try JSONDecoder().decode(VortxJSON.self, from: bytes)
        guard case .string(let sealed) = envelope["document"], let version = try envelope["version"]?.decode(Int.self),
              let plaintext = VortXSyncCrypto.openDocument(dataKey: key, stored: sealed, accountId: account, version: version)
        else { throw VortxNativeError.invalidResponse }
        return (try JSONDecoder().decode(VortxJSON.self, from: plaintext), version)
    }
    static func main() async throws {
        let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let directory = URL(fileURLWithPath: command.directory)
        let scope = VortxAccountScope(account: account, ownerProfileID: owner)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: key))
        let session = try VortxNativeSession(scope: scope, ownerName: "Fixture Owner", abi: VortxCABI(), store: store,
                                            transport: NoResources(), allowNewAccount: true, hostActor: command.actor)
        var result: [String: VortxJSON] = [:]
        if command.mode == "edit" {
            let actions = try (command.actions ?? []).map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            _ = try await session.dispatch(actions.isEmpty ? [#"{"type":"get_state"}"#] : actions, now: command.now ?? UInt64(Date().timeIntervalSince1970),
                                          hostEdits: (command.hostEdits ?? []).map { .init(profileID: $0.profileID, fields: $0.fields) })
        } else if ["pull", "prepare"].contains(command.mode) {
            let (document, version) = try await pull(command)
            let action = document["nativeSync"].map { VortxJSON.object(["type": .string("merge_native_sync"), "document": $0]) }
                ?? .object(["type": .string("get_state")])
            _ = try await session.dispatch([String(decoding: try JSONEncoder().encode(action), as: UTF8.self)], now: command.now ?? UInt64(Date().timeIntervalSince1970),
                                          hostRemote: document["nativeHostPreferences"])
            result["baseVersion"] = .integer(Int64(version))
            if command.mode == "prepare" {
                guard case .object(var fields) = document, let wireVersion = command.wireVersion else { throw VortxNativeError.invalidResponse }
                let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
                fields["nativeSync"] = state["nativeSync"]!
                fields["nativeHostPreferences"] = try await session.hostPreferencesDocument()
                let plaintext = try JSONEncoder().encode(VortxJSON.object(fields))
                guard let sealed = VortXSyncCrypto.sealDocument(dataKey: key, plaintext: plaintext, accountId: account, version: wireVersion, writeV2: true)
                else { throw VortxNativeError.invalidResponse }
                let outgoing = VortxJSON.object(["document": .string(sealed), "version": .integer(Int64(wireVersion))])
                try JSONEncoder().encode(outgoing).write(to: directory.appendingPathComponent("prepared.json"), options: .atomic)
                result["document"] = .object(fields)
            } else { result["document"] = document }
        } else if command.mode == "push" {
            let body = try Data(contentsOf: directory.appendingPathComponent("prepared.json"))
            let (status, bytes) = try await http(command, method: "PUT", body: body)
            guard status == 200, case .object(let fields) = try JSONDecoder().decode(VortxJSON.self, from: bytes) else { throw VortxNativeError.invalidResponse }
            for (key, value) in fields { result[key] = value }
        } else if command.mode != "inspect" { throw VortxNativeError.invalidResponse }
        result["state"] = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        result["nativeHostPreferences"] = try await session.hostPreferencesDocument()
        result["playback"] = try await session.playbackProjection()
        result["installedAddons"] = .array(try await session.resourceRegistry().map { .string($0.transportUrl) })
        await session.close()
        print(String(decoding: try JSONEncoder().encode(VortxJSON.object(result)), as: UTF8.self))
    }
}
