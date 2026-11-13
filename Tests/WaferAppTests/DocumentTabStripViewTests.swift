import AppKit
import Foundation
import XCTest
@testable import WaferApp
@testable import WaferCore

final class TabStripReorderMathTests: XCTestCase {
    func testProjectedInsertionIndexCountsTabsLeftOfDraggedMidX() {
        let midXs: [CGFloat] = [50, 150, 250, 350]

        // Dragged tab 0 moved just past tab 1's midpoint -> index 1.
        XCTAssertEqual(
            TabStripReorderMath.projectedInsertionIndex(draggedIndex: 0, draggedMidX: 160, tabMidXs: midXs),
            1
        )
        // Far right -> last index.
        XCTAssertEqual(
            TabStripReorderMath.projectedInsertionIndex(draggedIndex: 0, draggedMidX: 999, tabMidXs: midXs),
            3
        )
        // Dragged tab 3 moved left of everything -> index 0.
        XCTAssertEqual(
            TabStripReorderMath.projectedInsertionIndex(draggedIndex: 3, draggedMidX: 10, tabMidXs: midXs),
            0
        )
        // Not past any midpoint -> stays.
        XCTAssertEqual(
            TabStripReorderMath.projectedInsertionIndex(draggedIndex: 1, draggedMidX: 149, tabMidXs: midXs),
            1
        )
        // Between tabs 1 and 2 for a dragged tab 3 -> two tabs to the left.
        XCTAssertEqual(
            TabStripReorderMath.projectedInsertionIndex(draggedIndex: 3, draggedMidX: 200, tabMidXs: midXs),
            2
        )
        // Invalid dragged index clamps safely.
        XCTAssertEqual(
            TabStripReorderMath.projectedInsertionIndex(draggedIndex: 9, draggedMidX: 200, tabMidXs: midXs),
            0
        )
    }

    func testClampedDragMidXKeepsTabInsideStrip() {
        XCTAssertEqual(TabStripReorderMath.clampedDragMidX(proposed: -50, tabWidth: 100, stripWidth: 600), 50)
        XCTAssertEqual(TabStripReorderMath.clampedDragMidX(proposed: 999, tabWidth: 100, stripWidth: 600), 550)
        XCTAssertEqual(TabStripReorderMath.clampedDragMidX(proposed: 300, tabWidth: 100, stripWidth: 600), 300)
        // Degenerate: strip narrower than the tab centers it.
        XCTAssertEqual(TabStripReorderMath.clampedDragMidX(proposed: 10, tabWidth: 300, stripWidth: 200), 100)
    }
}

@MainActor
final class DocumentTabStripViewTests: XCTestCase {
    private func makeStrip(titles: [String], selectedIndex: Int = 0) -> DocumentTabStripView {
        let strip = DocumentTabStripView(frame: NSRect(x: 0, y: 0, width: 800, height: 30))
        strip.reload(
            items: titles.map { DocumentTabStripView.TabItem(title: $0) },
            selectedIndex: selectedIndex
        )
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    func testCloseButtonDoesNotTriggerSelection() throws {
        let strip = makeStrip(titles: ["A.md", "B.md"], selectedIndex: 0)
        var selected: [Int] = []
        var closed: [Int] = []
        strip.onSelectTab = { selected.append($0) }
        strip.onCloseTab = { closed.append($0) }

        let secondTab = try XCTUnwrap(strip.tabViewsForTesting[1] as? TabItemView)
        secondTab.closeButtonForTesting.performClick(nil)

        XCTAssertEqual(closed, [1])
        XCTAssertTrue(selected.isEmpty)
    }

    func testContextMenuOffersCloseAndCloseOthers() throws {
        let strip = makeStrip(titles: ["A.md", "B.md", "C.md"], selectedIndex: 0)
        var closed: [Int] = []
        var closedOthers: [Int] = []
        strip.onCloseTab = { closed.append($0) }
        strip.onCloseOtherTabs = { closedOthers.append($0) }

        let secondTab = try XCTUnwrap(strip.tabViewsForTesting[1] as? TabItemView)
        let menu = try XCTUnwrap(secondTab.menu)
        XCTAssertEqual(menu.items.map(\.title), ["Close Tab", "Close Other Tabs"])

        _ = menu.items[0].target?.perform(menu.items[0].action, with: menu.items[0])
        _ = menu.items[1].target?.perform(menu.items[1].action, with: menu.items[1])
        XCTAssertEqual(closed, [1])
        XCTAssertEqual(closedOthers, [1])
    }

    func testAccessibilityExposesTabGroupWithSelectedRadioButtons() throws {
        let strip = makeStrip(titles: ["A.md", "B.md"], selectedIndex: 1)

        XCTAssertEqual(strip.accessibilityRole(), .tabGroup)

        let firstTab = try XCTUnwrap(strip.tabViewsForTesting[0] as? TabItemView)
        let secondTab = try XCTUnwrap(strip.tabViewsForTesting[1] as? TabItemView)
        XCTAssertEqual(firstTab.accessibilityRole(), .radioButton)
        XCTAssertEqual(firstTab.accessibilityLabel(), "A.md")
        XCTAssertEqual(firstTab.accessibilityValue() as? Int, 0)
        XCTAssertEqual(secondTab.accessibilityValue() as? Int, 1)
        XCTAssertEqual(secondTab.closeButtonForTesting.accessibilityLabel(), "Close B.md")

        var selected: [Int] = []
        strip.onSelectTab = { selected.append($0) }
        XCTAssertTrue(firstTab.accessibilityPerformPress())
        XCTAssertEqual(selected, [0])
    }

    func testStripReThemesThroughTabTokens() throws {
        defer { ReaderTheme.resetToDefaultForTesting() }
        let strip = makeStrip(titles: ["A.md", "B.md"], selectedIndex: 0)

        ReaderTheme.setCurrent(.dark)
        strip.applyCurrentTheme()
        let darkBar = strip.layer?.backgroundColor

        ReaderTheme.setCurrent(.light)
        strip.applyCurrentTheme()
        let lightBar = strip.layer?.backgroundColor

        XCTAssertNotEqual(darkBar, lightBar)
        XCTAssertEqual(
            lightBar,
            ReaderThemePalette.light.resolvedTab.barBackground.readerColor.cgColor
        )

        let selectedTab = try XCTUnwrap(strip.tabViewsForTesting[0] as? TabItemView)
        XCTAssertEqual(
            selectedTab.layer?.backgroundColor,
            ReaderThemePalette.light.resolvedTab.selectedFill.readerColor.cgColor
        )
    }

    func testReloadClampsInvalidSelectionAndPreservesTitles() {
        let strip = makeStrip(titles: ["One.md", "Two.md", "Three.md"], selectedIndex: 99)

        XCTAssertEqual(strip.selectedIndex, 0)
        XCTAssertEqual(
            strip.tabViewsForTesting.compactMap { ($0 as? TabItemView)?.titleForTesting },
            ["One.md", "Two.md", "Three.md"]
        )
    }
}
