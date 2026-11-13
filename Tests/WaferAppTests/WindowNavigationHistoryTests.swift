import Foundation
import XCTest
@testable import WaferApp

final class WindowNavigationHistoryTests: XCTestCase {
    private func entry(_ name: String, anchorID: String? = nil) -> WindowNavigationHistoryEntry {
        WindowNavigationHistoryEntry(
            fileURL: URL(fileURLWithPath: "/docs/\(name).md"),
            anchorID: anchorID
        )
    }

    func testScriptedBrowserSessionInvariantsHold() {
        var history = WindowNavigationHistory()
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        // A -> B -> C
        history.push(departing: entry("A"))
        history.push(departing: entry("B"))
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        // back from C shows B, records C forward
        XCTAssertEqual(history.goBack(from: entry("C")), entry("B"))
        XCTAssertEqual(history.forwardEntries, [entry("C")])

        // back from B shows A, records B forward
        XCTAssertEqual(history.goBack(from: entry("B")), entry("A"))
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.forwardEntries, [entry("C"), entry("B")])

        // forward from A shows B, records A back
        XCTAssertEqual(history.goForward(from: entry("A")), entry("B"))
        XCTAssertEqual(history.backEntries, [entry("A")])
        XCTAssertEqual(history.forwardEntries, [entry("C")])

        // organic push of D clears the forward stack
        history.push(departing: entry("B"))
        XCTAssertEqual(history.backEntries, [entry("A"), entry("B")])
        XCTAssertFalse(history.canGoForward)
    }

    func testTraversalOnEmptyStacksReturnsNilWithoutMutation() {
        var history = WindowNavigationHistory()
        XCTAssertNil(history.goBack(from: entry("A")))
        XCTAssertNil(history.goForward(from: entry("A")))
        XCTAssertEqual(history, WindowNavigationHistory())

        history.push(departing: entry("A"))
        let snapshot = history
        XCTAssertNil(history.goForward(from: entry("B")))
        XCTAssertEqual(history, snapshot)
    }

    func testCapDropsOldestEntries() {
        var history = WindowNavigationHistory()
        for index in 1...60 {
            history.push(departing: entry("doc-\(index)"))
        }

        XCTAssertEqual(history.backEntries.count, WindowNavigationHistory.maximumEntryCount)
        XCTAssertEqual(history.backEntries.first, entry("doc-11"))
        XCTAssertEqual(history.backEntries.last, entry("doc-60"))
    }

    func testEntriesNormalizeFileURLsAtInsertion() {
        let aliased = WindowNavigationHistoryEntry(
            fileURL: URL(fileURLWithPath: "/docs/sub/../Note.md")
        )
        XCTAssertEqual(aliased.fileURL, URL(fileURLWithPath: "/docs/Note.md"))

        var history = WindowNavigationHistory()
        history.push(departing: aliased)
        XCTAssertEqual(
            history.goBack(from: entry("Other")),
            WindowNavigationHistoryEntry(fileURL: URL(fileURLWithPath: "/docs/Note.md"))
        )
    }

    func testAnchorIDTravelsWithEntries() {
        var history = WindowNavigationHistory()
        history.push(departing: entry("A", anchorID: "section-2"))

        let target = history.goBack(from: entry("B"))
        XCTAssertEqual(target?.anchorID, "section-2")
    }
}
