import Foundation

/// Calls the proposed stateless native evidence canonicalizer. The SDK symbol and build flag
/// remain unshipped. The default ABI implementation returns nil and this adapter fails closed.
/// This adapter is permissible inside a full validation callback: it borrows no stateful handle.
struct VortxNativeOwnerHistoryCanonicalizer: Sendable {
    struct Result: Sendable {
        let evidence: VortxJSON
        let receipt: VortxJSON
        fileprivate let evidenceBytes: Data
        fileprivate let receiptBytes: Data
        fileprivate init(evidence: VortxJSON, receipt: VortxJSON) throws {
            self.evidence = evidence; self.receipt = receipt
            evidenceBytes = try VortxNativeHostFieldEvidence.canonicalData(evidence)
            receiptBytes = try VortxNativeHostFieldEvidence.canonicalData(receipt)
        }
        func equals(_ other: Self) -> Bool {
            evidenceBytes == other.evidenceBytes && receiptBytes == other.receiptBytes
        }
    }
    private let abi: any VortxRuntimeABI
    private static let maximumBytes = 16 * 1024 * 1024
    init(abi: any VortxRuntimeABI) { self.abi = abi }

    func canonicalize(_ bytes: Data) throws -> Result {
        guard bytes.count <= Self.maximumBytes,
              let input = String(data: bytes, encoding: .utf8), !input.utf8.contains(0) else {
            throw VortxNativeError.invalidSnapshot
        }
        guard let response = abi.canonicalizeOwnerHistoryEvidence(input) else {
            throw VortxNativeError.unavailable
        }
        guard response.utf8.count <= Self.maximumBytes else { throw VortxNativeError.invalidResponse }
        let data = Data(response.utf8)
        _ = try VortxProfileOverlayWitness.decodeObject(json: data)
        let value = try JSONDecoder().decode(VortxJSON.self, from: data)
        guard case .object(let fields) = value,
              Set(fields.keys) == ["kind", "evidence", "receipt"],
              fields["kind"] == .string("owner_history_evidence"),
              let evidence = fields["evidence"], case .object = evidence,
              let receipt = fields["receipt"], case .object = receipt else {
            throw VortxNativeError.invalidResponse
        }
        // Rust has decoded, validated, normalized and fingerprinted the actual typed carrier.
        // Canonical Swift bytes below compare those returned objects; they never define a receipt.
        return try Result(evidence: evidence, receipt: receipt)
    }
}
