/// The encrypted relay accepts only a revision greater than the stored revision. A derived
/// document must therefore propose exactly one above the base it actually read. Using a wall
/// clock lets a later stale writer overwrite a concurrent winner without triggering a retry.
enum SyncDocumentRevisionPolicy {
    static let maximumSafeRevision = 9_007_199_254_740_991

    /// No stored row uses revision zero for its first insert. A real row at zero advances to one.
    static func next(after baseRevision: Int?) -> Int? {
        guard let baseRevision else { return 0 }
        guard baseRevision >= 0, baseRevision < maximumSafeRevision else { return nil }
        return baseRevision + 1
    }
}
