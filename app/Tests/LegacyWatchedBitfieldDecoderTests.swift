import Foundation

@main
enum LegacyWatchedBitfieldDecoderTests {
    private struct Fixture: Decodable { let schemaVersion: Int; let cases: [Case] }
    private struct Case: Decodable {
        let name: String
        let serialized: String?
        let serializedPrefix: String?
        let payloadCharacter: String?
        let payloadCount: Int?
        let inventory: [LegacyWatchedBitfieldEpisode]
        let watched: [String]?
        let error: Bool?
    }

    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? "test/fixtures/legacy-watched-bitfield.json"
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        precondition(fixture.schemaVersion == 1, "Unexpected watched-bitfield fixture version")
        for test in fixture.cases {
            do {
                let serialized = test.serialized ?? ((test.serializedPrefix ?? "") + String(repeating: test.payloadCharacter ?? "", count: test.payloadCount ?? 0))
                precondition(!serialized.isEmpty, "Fixture has no serialized field for \(test.name)")
                let actual = try LegacyWatchedBitfieldDecoder.decode(serialized: serialized, inventory: test.inventory)
                precondition(test.error != true, "Expected decoder failure for \(test.name)")
                let expected = test.watched ?? []
                precondition(actual.map { Data($0.utf8) } == expected.map { Data($0.utf8) }, "Wrong watched IDs for \(test.name): \(actual)")
            } catch {
                precondition(test.error == true, "Unexpected decoder failure for \(test.name): \(error)")
            }
        }
    }
}
