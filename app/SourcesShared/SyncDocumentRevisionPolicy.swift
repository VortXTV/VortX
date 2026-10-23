/// A candidate carries its exact authenticated base into the relay's atomic compare-and-swap.
/// It proposes one above that base, or zero for a positively absent row. A larger clock or a
/// different read's revision can never substitute for that candidate's ancestry.
enum SyncDocumentRevisionPolicy {
    static let maximumSafeRevision = 9_007_199_254_740_991

    /// No stored row uses revision zero for its first insert. A real row at zero advances to one.
    static func next(after baseRevision: Int?) -> Int? {
        guard let baseRevision else { return 0 }
        guard baseRevision >= 0, baseRevision < maximumSafeRevision else { return nil }
        return baseRevision + 1
    }
}
