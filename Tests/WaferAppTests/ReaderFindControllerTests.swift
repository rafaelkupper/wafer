import AppKit
import WebKit
import XCTest
@testable import WaferApp

@MainActor
final class ReaderFindControllerTests: XCTestCase {
    func testFindNormalizesQueryAndUsesWrappedCaseInsensitiveDirection() {
        var queries: [String] = []
        var backwards: [Bool] = []
        var completions: [@MainActor (Bool) -> Void] = []
        let find = ReaderFindController(find: { query, config, complete in
            queries.append(query)
            backwards.append(config.backwards)
            XCTAssertTrue(config.wraps)
            XCTAssertFalse(config.caseSensitive)
            completions.append(complete)
        }, clearSelection: { _ in XCTFail("Unexpected clear") }, focusContent: {})
        find.bar.searchField.stringValue = "  Heading\n"
        find.findPreviousMatch(nil)
        XCTAssertFalse(find.bar.isHidden)
        completions[0](false)
        XCTAssertEqual(find.bar.statusLabel.stringValue, "No matches")
        find.findNextMatch(nil)
        completions[1](true)
        XCTAssertTrue(find.bar.statusLabel.isHidden)
        XCTAssertEqual(queries, ["Heading", "Heading"])
        XCTAssertEqual(backwards, [true, false])
    }

    func testEmptyQueryAndHideClearSelectionWithoutSearching() {
        var clears: [String] = []
        var focusCount = 0
        let find = ReaderFindController(find: { _, _, _ in XCTFail("Empty query must not search") },
                                        clearSelection: { clears.append($0) }, focusContent: { focusCount += 1 })
        find.bar.searchField.stringValue = " \n"
        find.findNextMatch(nil)
        XCTAssertFalse(find.bar.isHidden)
        find.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: find.bar.searchField))
        XCTAssertTrue(find.bar.statusLabel.isHidden)
        XCTAssertEqual(clears.count, 1)
        XCTAssertTrue(clears[0].contains("removeAllRanges"))
        find.hideFindInterface(nil)
        XCTAssertTrue(find.bar.isHidden)
        XCTAssertEqual(clears.count, 2)
        XCTAssertEqual(focusCount, 1)
    }

    func testOnlyOwnSearchFieldTriggersFindAndCommands() {
        var queries: [String] = []
        let find = ReaderFindController(find: { query, _, complete in queries.append(query); complete(true) },
                                        clearSelection: { _ in }, focusContent: {})
        let unrelated = NSSearchField()
        find.bar.searchField.stringValue = "term"
        find.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: unrelated))
        XCTAssertTrue(queries.isEmpty)
        find.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: find.bar.searchField))
        let text = NSTextView()
        XCTAssertFalse(find.control(unrelated, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(find.control(find.bar.searchField, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(queries, ["term", "term"])
        XCTAssertTrue(find.control(find.bar.searchField, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(find.bar.isHidden)
    }
}
