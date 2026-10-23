import Foundation

@main enum SIMKLRatingDateTests {
    static func main() {
        let whole = "2026-10-20T10:00:00Z"
        let fractional = "2026-10-20T10:00:00.125Z"
        guard let wholeDate = SIMKLRatedAt.date(from: whole), let fractionalDate = SIMKLRatedAt.date(from: fractional) else {
            preconditionFailure("supported SIMKL timestamps did not parse")
        }
        precondition(SIMKLRatedAt.string(from: wholeDate) == whole)
        precondition(SIMKLRatedAt.string(from: fractionalDate) == whole, "rating writes must remain whole-second UTC")
        precondition(abs(fractionalDate.timeIntervalSince(wholeDate) - 0.125) < 0.00001)
        precondition(SIMKLRatedAt.date(from: "not-a-date") == nil)
        precondition(SIMKLRatedAt.date(from: "") == nil)
        // Cached round trips preserve the exact existing service-specific wire shape.
        for offset in 0..<500 {
            let date = wholeDate.addingTimeInterval(Double(offset))
            let encoded = SIMKLRatedAt.string(from: date)
            precondition(!encoded.contains(".") && encoded.hasSuffix("Z"))
            precondition(SIMKLRatedAt.date(from: encoded) == date)
        }
        print("PASS actual SIMKL rating-date formats, invalid values and 500 cached round trips")
    }
}
