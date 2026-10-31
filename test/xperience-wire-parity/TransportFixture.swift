import Foundation

/// Observes only the pinned public synthetic corpus through the actual installed-source Candidate.
/// No expected admission, canonical value, relation or parity assertion is evaluated here.
enum TransportFixture {
    enum CollectorFailure: Error { case invalidCorpus, invalidObservation, unexpectedCandidateFailure }

    private struct Corpus: Decodable {
        struct Descriptor: Decodable {
            struct Catalog: Decodable {
                let type: String
                let id: String
                let acceptsGenre: Bool
                let requiresGenre: Bool
                let supportsSkip: Bool
            }
            let manifestID: String
            let catalog: Catalog
        }
        struct Case: Decodable {
            let id: String
            let input: String
            let inputUTF8SHA256: String
        }
        let schema: Int
        let fixtureDescriptor: Descriptor
        let cases: [Case]
    }

    private static let corpusSHA256 = "de132e69bd605de930fdbc552534b31216232463e4900de93e4646ec74c1e296"
    private static let manifestID = "fixture.xperience.synthetic"

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func collect(corpusPath: String, outputPath: String) throws {
        let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: corpusPath))
        defer { try? source.close() }
        let bytes = try source.read(upToCount: 128 * 1024 + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= 128 * 1024,
              XperienceCollections.digestBytes(bytes) == corpusSHA256 else { throw CollectorFailure.invalidCorpus }
        let corpus: Corpus
        do { corpus = try JSONDecoder().decode(Corpus.self, from: bytes) }
        catch { throw CollectorFailure.invalidCorpus }
        let descriptor = corpus.fixtureDescriptor
        let catalog = descriptor.catalog
        guard corpus.schema == 1, corpus.cases.count == 52, corpus.cases.count <= 64,
              descriptor.manifestID == manifestID,
              catalog.type == "movie", catalog.id == "fixture-popular",
              catalog.acceptsGenre, !catalog.requiresGenre, catalog.supportsSkip else {
            throw CollectorFailure.invalidCorpus
        }
        var seen = Set<String>()
        for item in corpus.cases {
            let input = Data(item.input.utf8)
            guard !item.id.isEmpty, item.id.utf8.count <= 128,
                  item.id.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) }),
                  seen.insert(item.id).inserted,
                  !input.isEmpty, input.count <= 4096,
                  isSHA256(item.inputUTF8SHA256),
                  XperienceCollections.digestBytes(input) == item.inputUTF8SHA256 else {
                throw CollectorFailure.invalidCorpus
            }
        }

        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let resultsURL = output.appendingPathComponent("results.tsv")
        try Data().write(to: resultsURL, options: .withoutOverwriting)
        let results = try FileHandle(forWritingTo: resultsURL)
        defer { try? results.close() }
        var metadataBytes = 0
        for item in corpus.cases {
            // Only a validated fixed-corpus ASCII ID is emitted; never emit the configured transport.
            try FileHandle.standardError.write(contentsOf: Data(("transport-case-start\t" + item.id + "\n").utf8))
            let candidate: XperienceAddonBinding.Candidate?
            do {
                candidate = try XperienceAddonBinding.Candidate(
                    manifestID: manifestID, transport: item.input,
                    catalogs: [.init(type: "movie", id: "fixture-popular", acceptsGenre: true,
                                     requiresGenre: false, supportsSkip: true)])
            } catch let failure as XperienceAddonBinding.Failure {
                guard failure == .invalidRegistry else { throw CollectorFailure.unexpectedCandidateFailure }
                candidate = nil
            } catch {
                throw CollectorFailure.unexpectedCandidateFailure
            }
            let fields: [String]
            if let candidate {
                let canonical = Data(candidate.canonicalTransport.utf8)
                guard !canonical.isEmpty, canonical.count <= 16 * 1024,
                      isSHA256(candidate.transportDigest) else { throw CollectorFailure.invalidObservation }
                try canonical.write(to: output.appendingPathComponent(item.id + ".canonical"), options: .withoutOverwriting)
                fields = [item.id, "ACCEPTED", String(canonical.count),
                          XperienceCollections.digestBytes(canonical), candidate.transportDigest, item.inputUTF8SHA256]
            } else {
                fields = [item.id, "INVALID_REGISTRY", "0", "-", "-", item.inputUTF8SHA256]
            }
            let row = Data((fields.joined(separator: "\t") + "\n").utf8)
            metadataBytes += row.count
            guard metadataBytes <= 32 * 1024 else { throw CollectorFailure.invalidObservation }
            try results.write(contentsOf: row)
            try results.synchronize()
        }
    }
}
