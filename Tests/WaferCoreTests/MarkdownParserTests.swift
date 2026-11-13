import Markdown
import XCTest
@testable import WaferCore

final class MarkdownParserTests: XCTestCase {
    private let parser = MarkdownParser()

    func testParserProducesStableFingerprint() {
        let markdown = "# Hello\n\n- one\n- two"

        let document = parser.parse(source: markdown, baseURL: nil)

        XCTAssertEqual(document.fingerprint, FileFingerprint.sha256Hex(for: markdown))
    }

    func testParserPreservesSourceAndBaseURL() {
        let baseURL = URL(fileURLWithPath: "/tmp/readme.md")

        let document = parser.parse(source: "body", baseURL: baseURL)

        XCTAssertEqual(document.source, "body")
        XCTAssertEqual(document.baseURL, baseURL)
    }

    func testParserEnablesBlockDirectivesAndSymbolLinks() {
        let document = parser.parse(
            source: """
            @Note(title: "Heads up") {
            Symbol link: ``ReaderTheme.styleSheet``
            }
            """,
            baseURL: nil
        )

        let blockDirective = firstNode(of: BlockDirective.self, in: document.ast)
        let symbolLink = firstNode(of: SymbolLink.self, in: document.ast)

        XCTAssertEqual(blockDirective?.name, "Note")
        XCTAssertEqual(symbolLink?.destination, "ReaderTheme.styleSheet")
    }

    func testParserStripsClosedYAMLFrontMatterBeforeParsingBody() {
        let source = """
        ---
        title: Metadata Title
        tags:
          - swift
        ---
        # Body Title

        Body text.
        """

        let document = parser.parse(source: source, baseURL: nil)

        XCTAssertEqual(document.frontMatter, "title: Metadata Title\ntags:\n  - swift")
        XCTAssertEqual(document.fingerprint, FileFingerprint.sha256Hex(for: source))
        XCTAssertEqual(firstNode(of: Heading.self, in: document.ast)?.plainText, "Body Title")
        XCTAssertFalse(document.ast.format().contains("Metadata Title"))
    }

    func testParserAcceptsEllipsisCloserAndCRLFLineEndings() {
        let source = "---\r\ntitle: CRLF Title\r\n...\r\nBody text."
        let document = parser.parse(source: source, baseURL: nil)

        XCTAssertEqual(document.frontMatter, "title: CRLF Title")
        XCTAssertEqual(document.ast.plainText.collapsingWhitespace, "Body text.")
    }

    func testParserTreatsUnclosedOrNonInitialDashesAsMarkdown() {
        let unclosed = parser.parse(
            source: """
            ---
            title: Missing closer

            Body
            """,
            baseURL: nil
        )
        let nonInitial = parser.parse(
            source: """

            ---
            title: Not metadata
            ---
            """,
            baseURL: nil
        )

        XCTAssertNil(unclosed.frontMatter)
        XCTAssertTrue(unclosed.ast.plainText.contains("Missing closer"))
        XCTAssertNil(nonInitial.frontMatter)
        XCTAssertTrue(nonInitial.ast.plainText.contains("Not metadata"))
    }

    func testParserExtractsFootnoteDefinitionsAfterFrontMatter() {
        let source = """
        ---
        title: Footnote Source
        ---
        Body with a reference.[^one]

        [^one]: First line with **markdown**.
            Continued line.

        [^unused]: Dropped unless referenced.
        """

        let document = parser.parse(source: source, baseURL: nil)

        XCTAssertEqual(document.frontMatter, "title: Footnote Source")
        XCTAssertEqual(document.footnotes, [
            FootnoteDefinition(label: "one", content: "First line with **markdown**.\nContinued line."),
            FootnoteDefinition(label: "unused", content: "Dropped unless referenced."),
        ])
        XCTAssertTrue(document.ast.plainText.contains("Body with a reference.[^one]"))
        XCTAssertFalse(document.ast.plainText.contains("First line with"))
        XCTAssertFalse(document.ast.plainText.contains("Dropped unless referenced"))
    }

    func testParserExtractsTabbedFootnoteContinuation() {
        let source = "Body.[^one]\n\n[^one]: First line\n\tTabbed continuation.\n"

        let document = parser.parse(source: source, baseURL: nil)

        XCTAssertEqual(document.footnotes, [
            FootnoteDefinition(label: "one", content: "First line\nTabbed continuation."),
        ])
        XCTAssertFalse(document.ast.plainText.contains("Tabbed continuation."))
    }

    func testParserDoesNotExtractFootnotesInsideFencedCode() {
        let source = """
        ```swift
        [^code]: not a footnote
        ```

           ~~~
           [^tilde]: also code
           ~~~

        Body.[^real]

        [^real]: Real definition.
        """

        let document = parser.parse(source: source, baseURL: nil)

        XCTAssertEqual(document.footnotes, [FootnoteDefinition(label: "real", content: "Real definition.")])
        XCTAssertTrue(document.ast.format().contains("[^code]: not a footnote"))
        XCTAssertTrue(document.ast.format().contains("[^tilde]: also code"))
        XCTAssertFalse(document.ast.plainText.contains("[^real]: Real definition."))
    }

    private func firstNode<T: Markup>(of type: T.Type, in markup: Markup) -> T? {
        if let node = markup as? T {
            return node
        }

        for child in markup.children {
            if let node = firstNode(of: type, in: child) {
                return node
            }
        }

        return nil
    }
}
