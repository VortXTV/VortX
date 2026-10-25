import Foundation

/// The #206 source-column Up boundary. The custom return to the action rows belongs only to
/// the first focusable element in the source column: the filter bar when present, otherwise
/// its first source row. Deeper source rows keep tvOS's native one-row Up navigation.
enum TVDetailSourceColumnFocusPolicy {
    static func filterBarOwnsUpEscape(groupsCount: Int, hasQuickFilters: Bool = false) -> Bool {
        groupsCount > 1 || (groupsCount > 0 && hasQuickFilters)
    }

    static func sourceRowOwnsUpEscape(at index: Int, groupsCount: Int, hasQuickFilters: Bool = false) -> Bool {
        index == 0 && !filterBarOwnsUpEscape(groupsCount: groupsCount, hasQuickFilters: hasQuickFilters)
    }
}
