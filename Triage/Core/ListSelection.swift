import Foundation

/// Selection rules shared by every list, so keys, menus, and bulk actions agree.
enum ListSelection {
    /// The row `offset` away from the selection, as a new single selection:
    /// moving down starts from the last selected row, moving up from the first.
    static func moved<ID: Hashable>(_ selection: Set<ID>, in order: [ID], by offset: Int) -> ID? {
        guard !order.isEmpty else { return nil }
        let indices = order.indices.filter { selection.contains(order[$0]) }
        guard let anchor = offset >= 0 ? indices.last : indices.first else {
            return offset >= 0 ? order.first : order.last
        }
        return order[min(max(anchor + offset, 0), order.count - 1)]
    }

    /// After `removed` leave the list: the row after the last removed one,
    /// else the last remaining row. Unchanged if the selection wasn't affected.
    static func afterRemoving<ID: Hashable>(_ removed: Set<ID>, from selection: Set<ID>, in order: [ID]) -> Set<ID> {
        guard !selection.isDisjoint(with: removed) else { return selection }
        let after = order.lastIndex(where: removed.contains).flatMap { last in
            order[(last + 1)...].first { !removed.contains($0) }
        }
        return (after ?? order.last { !removed.contains($0) }).map { [$0] } ?? []
    }
}
