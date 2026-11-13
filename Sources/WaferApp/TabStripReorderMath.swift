import Foundation

/// Pure geometry for drag-reorder: fully unit-tested, no AppKit.
enum TabStripReorderMath {
    /// Returns the index the dragged tab should occupy, given the midX
    /// positions of ALL tabs in their current visual order (dragged tab's
    /// original slot included) and the dragged tab's current midX.
    ///
    /// The insertion index equals the count of OTHER tabs whose midX sits
    /// left of the dragged midX, clamped to the valid range.
    static func projectedInsertionIndex(
        draggedIndex: Int,
        draggedMidX: CGFloat,
        tabMidXs: [CGFloat]
    ) -> Int {
        guard tabMidXs.indices.contains(draggedIndex) else {
            return 0
        }

        var leftCount = 0
        for (index, midX) in tabMidXs.enumerated() where index != draggedIndex {
            if midX < draggedMidX {
                leftCount += 1
            }
        }

        return min(max(leftCount, 0), tabMidXs.count - 1)
    }

    /// Clamps a dragged tab's proposed midX so the floating tab stays inside
    /// the strip's usable bounds.
    static func clampedDragMidX(
        proposed: CGFloat,
        tabWidth: CGFloat,
        stripWidth: CGFloat
    ) -> CGFloat {
        let halfWidth = tabWidth / 2
        guard stripWidth >= tabWidth else {
            return stripWidth / 2
        }

        return min(max(proposed, halfWidth), stripWidth - halfWidth)
    }
}
