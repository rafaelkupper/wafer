import XCTest
@testable import WaferCore

final class DocumentStatisticsTests: XCTestCase {
    private let parser = MarkdownParser()

    func testRenderedTextExtractionFollowsVisibleReaderContent() {
        let document = parser.parse(
            source: """
            # Title

            Paragraph with [visible link](https://example.com/docs) and <kbd>Cmd</kbd>.

            - [x] Completed item
            - Plain item

            > Quoted line

            ```swift
            let title = "Wafer"
            ```

            | Name | Value |
            | --- | --- |
            | One | 1 |

            ![Screenshot](Preview.png)

            <aside>raw html</aside>

            @Note(title: "Heads up") {
            Important with ``ReaderTheme.styleSheet`` and ^[chip](class: "md-inline-chip").
            }
            """,
            baseURL: nil
        )

        let renderedText = RenderedTextDocumentStatistics.renderedText(from: document)

        XCTAssertTrue(renderedText.contains("Title"))
        XCTAssertTrue(renderedText.contains("visible link"))
        XCTAssertTrue(renderedText.contains("Cmd"))
        XCTAssertTrue(renderedText.contains("Completed item"))
        XCTAssertTrue(renderedText.contains("Quoted line"))
        XCTAssertTrue(renderedText.contains("let title = \"Wafer\""))
        XCTAssertTrue(renderedText.contains("Name"))
        XCTAssertTrue(renderedText.contains("Value"))
        XCTAssertTrue(renderedText.contains("raw html"))
        XCTAssertTrue(renderedText.contains("Heads up"))
        XCTAssertTrue(renderedText.contains("Important"))
        XCTAssertTrue(renderedText.contains("ReaderTheme.styleSheet"))
        XCTAssertTrue(renderedText.contains("chip"))
        XCTAssertFalse(renderedText.contains("https://example.com/docs"))
        XCTAssertFalse(renderedText.contains("Preview.png"))
        XCTAssertFalse(renderedText.contains("Screenshot"))
    }

    func testStatisticsUseEditorialDefaultsAndLogicalNonEmptyLines() {
        let statistics = RenderedTextDocumentStatistics.statistics(fromRenderedText: "One two\nThree")

        XCTAssertEqual(statistics.words, 3)
        XCTAssertEqual(statistics.minutes, 1)
        XCTAssertEqual(statistics.lines, 2)
        XCTAssertEqual(statistics.characters, 13)
    }

    func testStatisticsExcludeFrontMatterMetadata() {
        let document = parser.parse(
            source: """
            ---
            title: Hidden Metadata
            tags: swift markdown
            ---
            Visible body only.
            """,
            baseURL: nil
        )

        let renderedText = RenderedTextDocumentStatistics.renderedText(from: document)
        let statistics = RenderedTextDocumentStatistics.statistics(from: document)

        XCTAssertEqual(renderedText, "Visible body only.")
        XCTAssertEqual(statistics.words, 3)
        XCTAssertFalse(renderedText.contains("Hidden Metadata"))
        XCTAssertFalse(renderedText.contains("swift markdown"))
    }

    func testRenderedTextIncludesReferencedFootnotesOnce() {
        let document = parser.parse(
            source: """
            Body[^one] and again[^one] plus missing[^missing].

            `Code [^one] stays literal.`

            [^one]: Footnote **body** with [link](https://example.com).
            [^unused]: Hidden.
            """,
            baseURL: nil
        )

        let renderedText = RenderedTextDocumentStatistics.renderedText(from: document)

        XCTAssertTrue(renderedText.contains("Body and again plus missing[^missing]."))
        XCTAssertTrue(renderedText.contains("Code [^one] stays literal."))
        XCTAssertEqual(renderedText.numberOfMatches(of: "Footnote body with link."), 1)
        XCTAssertFalse(renderedText.contains("Hidden."))
        XCTAssertFalse(renderedText.contains("https://example.com"))
    }

    func testEmptyAndSingleWordStatisticsHandleMinuteFloorCorrectly() {
        let empty = RenderedTextDocumentStatistics.statistics(fromRenderedText: "")
        let singleWord = RenderedTextDocumentStatistics.statistics(fromRenderedText: "Wafer")

        XCTAssertEqual(empty, .zero)
        XCTAssertEqual(singleWord.words, 1)
        XCTAssertEqual(singleWord.minutes, 1)
        XCTAssertEqual(singleWord.lines, 1)
        XCTAssertEqual(singleWord.characters, 5)
    }
}

private extension String {
    func numberOfMatches(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
