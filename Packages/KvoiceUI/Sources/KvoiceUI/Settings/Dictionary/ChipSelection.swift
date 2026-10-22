import Foundation

/// Multi-select over a row of chips, the way a Finder list or the
/// pre-UI-v2 Dictionary table selected: a plain click selects one, ⌘-click
/// adds or removes one, ⇧-click extends from the last plain or ⌘ click (the
/// anchor) to the clicked chip in display order, ⌘A selects every chip.
/// Pure value logic so the rules are tested without a view
/// (`ChipSelectionTests`); the Dictionary's chips (Q3 leftover b, restoring
/// what F3b's chip list dropped) drive it and remove `ids` on Delete.
struct ChipSelection<ID: Hashable>: Equatable {
    enum Click: Equatable {
        /// No modifier: this chip only.
        case plain
        /// ⌘: toggle this chip, keep the rest.
        case toggle
        /// ⇧: the range from the anchor to this chip.
        case extend
    }

    private(set) var ids: Set<ID> = []
    private(set) var anchor: ID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: ID) -> Bool { ids.contains(id) }

    mutating func click(_ id: ID, _ kind: Click, order: [ID]) {
        switch kind {
        case .plain:
            ids = [id]
            anchor = id
        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                click(id, .plain, order: order)
                return
            }
            ids = Set(order[min(from, to)...max(from, to)])
        }
    }

    mutating func selectAll(_ order: [ID]) {
        ids = Set(order)
        anchor = order.first
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    /// Drops ids no longer shown (a removal, an import, another door).
    mutating func keep(only order: [ID]) {
        let present = Set(order)
        ids.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }

    /// What Delete removes with `focused` the keyboard's chip: the whole
    /// selection when the focused chip is part of it (or nothing is
    /// focused), otherwise only the focused chip.
    func removalTargets(focused: ID?) -> Set<ID> {
        guard let focused else { return ids }
        return ids.contains(focused) ? ids : [focused]
    }
}
