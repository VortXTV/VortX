import Foundation

@main
struct SwiftFixture {
    enum FixtureFailure: Error { case invalidArguments, invalidCorpus, unexpectedFailure }

    static func category(_ failure: XperienceCollections.Failure) -> String {
        switch failure {
        case .tooLarge: return "TOO_LARGE"
        case .invalidJSON: return "INVALID_JSON"
        case .duplicateMember: return "DUPLICATE_MEMBER"
        case .unpreservableNumber: return "UNPRESERVABLE_NUMBER"
        case .invalidSchema: return "INVALID_SCHEMA"
        case .duplicateCollection: return "DUPLICATE_COLLECTION"
        case .duplicateFolder: return "DUPLICATE_FOLDER"
        case .duplicateSource: return "DUPLICATE_SOURCE"
        case .emptyImport: return "EMPTY_IMPORT"
        case .staleRegister: return "STALE_REGISTER"
        case .invalidNamespace: return "INVALID_NAMESPACE"
        case .unsafeHostValue: return "UNSAFE_HOST_VALUE"
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw FixtureFailure.invalidArguments }
        let corpusURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let corpus = try Data(contentsOf: corpusURL)
        guard corpus.count <= 128 * 1024, let text = String(data: corpus, encoding: .utf8) else {
            throw FixtureFailure.invalidCorpus
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard (1...64).contains(lines.count) else { throw FixtureFailure.invalidCorpus }
        var seen = Set<String>()
        var results: [String] = []
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw FixtureFailure.invalidCorpus }
            let id = String(fields[0])
            guard !id.isEmpty, id.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) }),
                  seen.insert(id).inserted else { throw FixtureFailure.invalidCorpus }
            let input = Data(fields[2].utf8)
            guard !input.isEmpty, input.count <= 4096 else { throw FixtureFailure.invalidCorpus }
            let inputHash = XperienceCollections.digestBytes(input)
            do {
                let document = try XperienceCollections.parse(input)
                let canonical = try XperienceCollections.canonicalData(document.raw)
                let hash = XperienceCollections.digestBytes(canonical)
                try canonical.write(to: output.appendingPathComponent(id + ".canonical"), options: .withoutOverwriting)
                results.append([id, "ACCEPTED", String(canonical.count), hash, document.fingerprint, inputHash].joined(separator: "\t"))
            } catch let failure as XperienceCollections.Failure {
                results.append([id, category(failure), "0", "-", "-", inputHash].joined(separator: "\t"))
            } catch {
                throw FixtureFailure.unexpectedFailure
            }
        }
        try Data((results.joined(separator: "\n") + "\n").utf8)
            .write(to: output.appendingPathComponent("results.tsv"), options: .withoutOverwriting)
    }
}
