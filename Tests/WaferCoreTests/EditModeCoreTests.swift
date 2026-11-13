import Foundation
import XCTest
@testable import WaferCore

final class MarkdownTextFormatTests: XCTestCase {
    private func assertRoundTrip(_ data: Data, expectedText: String, expectedFormat: MarkdownTextFormat, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = try XCTUnwrap(MarkdownTextFormat.decode(data), file: file, line: line)
        XCTAssertEqual(decoded.format, expectedFormat, file: file, line: line)
        let normalized = MarkdownTextFormat.normalizingLineEndings(decoded.text)
        XCTAssertEqual(normalized, expectedText, file: file, line: line)
        XCTAssertEqual(decoded.format.encode(normalized), data, "unchanged text must write identical bytes", file: file, line: line)
    }

    func testUTF8WithoutAndWithByteOrderMarkRoundTrips() throws {
        try assertRoundTrip(Data("# Hi\nthere\n".utf8), expectedText: "# Hi\nthere\n",
                            expectedFormat: .init(encoding: .utf8, hasByteOrderMark: false, lineEnding: .lf))
        try assertRoundTrip(Data([0xEF, 0xBB, 0xBF]) + Data("# Hi\n".utf8), expectedText: "# Hi\n",
                            expectedFormat: .init(encoding: .utf8, hasByteOrderMark: true, lineEnding: .lf))
    }

    func testCRLFAndCRFilesRoundTripThroughLFText() throws {
        try assertRoundTrip(Data("a\r\nb\r\n".utf8), expectedText: "a\nb\n",
                            expectedFormat: .init(encoding: .utf8, hasByteOrderMark: false, lineEnding: .crlf))
        try assertRoundTrip(Data("a\rb\r".utf8), expectedText: "a\nb\n",
                            expectedFormat: .init(encoding: .utf8, hasByteOrderMark: false, lineEnding: .cr))
    }

    func testUTF16VariantsRoundTrip() throws {
        let littleEndian = Data([0xFF, 0xFE]) + "é\r\nx".data(using: .utf16LittleEndian)!
        try assertRoundTrip(littleEndian, expectedText: "é\nx",
                            expectedFormat: .init(encoding: .utf16LittleEndian, hasByteOrderMark: true, lineEnding: .crlf))
        let bigEndian = "ab\ncd".data(using: .utf16BigEndian)!
        try assertRoundTrip(bigEndian, expectedText: "ab\ncd",
                            expectedFormat: .init(encoding: .utf16BigEndian, hasByteOrderMark: false, lineEnding: .lf))
    }

    func testMixedLineEndingsUseDominantEndingForEditedText() throws {
        let decoded = try XCTUnwrap(MarkdownTextFormat.decode(Data("a\r\nb\r\nc\nd".utf8)))
        XCTAssertEqual(decoded.format.lineEnding, .crlf)
        XCTAssertEqual(decoded.format.encode("a\nb\nc\nd!"), Data("a\r\nb\r\nc\r\nd!".utf8))
    }

    func testUndecodableBytesReturnNil() {
        XCTAssertNil(MarkdownTextFormat.decode(Data([0xC3])))
    }
}

final class MarkdownSourceLineMapTests: XCTestCase {
    func testLineMapAccountsForFrontMatterAndMultiLineFootnotes() {
        let source = """
        ---
        title: Notes
        ---
        # Heading
        Text with note[^a].

        [^a]: First line
            continued line

        After footnote
        """
        let document = MarkdownParser().parse(source: source, baseURL: nil)
        let headingLine = document.ast.child(at: 0)?.range?.lowerBound.line
        XCTAssertEqual(headingLine.flatMap(document.sourceLine(forASTLine:)), 4)
        let afterFootnote = document.ast.children.compactMap { $0.range?.lowerBound.line }.last
        XCTAssertEqual(afterFootnote.flatMap(document.sourceLine(forASTLine:)), 10)
    }

    func testAnnotatedRenderMarksBlocksWithSourceLinesAndKeepsFootnotesUnannotated() {
        let source = """
        ---
        title: Notes
        ---
        # Heading

        - one
        - two

        | A | B |
        | - | - |
        | 1 | 2 |

        Note[^a].

        [^a]: Footnote body
        """
        let document = MarkdownParser().parse(source: source, baseURL: nil)
        let output = WebKitHTMLRenderer(annotatesSourceLines: true).render(document: document)
        let body = try? XCTUnwrap(output.bodyHTML)
        XCTAssertTrue(body?.contains("<details data-source-line=\"1\" class=\"md-front-matter\">") == true)
        XCTAssertTrue(body?.contains("<h1 data-source-line=\"4\"") == true)
        XCTAssertTrue(body?.contains("<li data-source-line=\"6\">") == true)
        XCTAssertTrue(body?.contains("<li data-source-line=\"7\">") == true)
        XCTAssertTrue(body?.contains("<tr data-source-line=\"11\">") == true)
        XCTAssertTrue(body?.contains("<p data-source-line=\"13\">") == true)
        XCTAssertNotNil(body?.range(of: "md-footnotes"))
        if let body, let start = body.range(of: "md-footnotes") {
            XCTAssertFalse(body[start.lowerBound...].contains("data-source-line"))
        }
    }

    func testDefaultReaderRenderHasNoAnnotations() {
        let document = MarkdownParser().parse(source: "# A\n\n- b\n", baseURL: nil)
        let output = WebKitHTMLRenderer().render(document: document)
        XCTAssertFalse(output.html.contains("data-source-line"))
        // The body is carried so edit mode can annotate the page in place,
        // and differs from an edit-mode body only by the line attributes.
        let annotated = WebKitHTMLRenderer(annotatesSourceLines: true).render(document: document)
        XCTAssertEqual(
            annotated.bodyHTML?.replacingOccurrences(of: #" data-source-line="\d+""#, with: "", options: .regularExpression),
            output.bodyHTML
        )
        XCTAssertNotNil(output.bodyHTML)
        let preview = WebKitHTMLRenderer(target: .preview, annotatesSourceLines: true).render(document: document)
        XCTAssertFalse(preview.html.contains("data-source-line"))
        XCTAssertNil(preview.bodyHTML)
    }

    func testAnnotatedRenderReportsScriptedRenderers() {
        let document = MarkdownParser().parse(source: "```mermaid\ngraph TD; A-->B\n```\n\n```math\nx^2\n```\n", baseURL: nil)
        let output = WebKitHTMLRenderer(annotatesSourceLines: true).render(document: document)
        XCTAssertTrue(output.hasMermaidDiagrams)
        XCTAssertTrue(output.hasMathDisplays)
        XCTAssertTrue(output.bodyHTML?.contains("<figure data-source-line=\"1\" class=\"md-mermaid-diagram\"") == true)
        XCTAssertTrue(output.bodyHTML?.contains("<figure data-source-line=\"5\" class=\"md-math-display\"") == true)
        XCTAssertTrue(output.html.contains("window.waferRenderMermaidFigures"))
        XCTAssertTrue(output.html.contains("window.waferRenderMathBlocks"))
    }
}

final class MarkdownSourceHighlighterTests: XCTestCase {
    private let highlighter = MarkdownSourceHighlighter()

    private func tokens(_ text: String) -> [(String, MarkdownSourceTokenKind)] {
        let string = text as NSString
        let structure = highlighter.structure(of: string)
        return highlighter.tokens(in: string, structure: structure, lines: 0..<structure.lineCount)
            .map { (string.substring(with: $0.range), $0.kind) }
    }

    func testStructureFindsFrontMatterAndFencesIncludingUnclosed() {
        let text = "---\na: 1\n---\n\n```swift\nlet x = 1\n```\ntext\n~~~\nopen" as NSString
        let structure = highlighter.structure(of: text)
        XCTAssertEqual(structure.lineCount, 10)
        XCTAssertEqual(structure.blocks.count, 3)
        XCTAssertEqual(structure.blocks[0].kind, .frontMatter)
        XCTAssertEqual(text.substring(with: structure.blocks[0].contentRange), "a: 1")
        XCTAssertEqual(structure.blocks[1].kind, .fencedCode(language: "swift"))
        XCTAssertEqual(text.substring(with: structure.blocks[1].contentRange), "let x = 1")
        XCTAssertNil(structure.blocks[2].closingLineRange)
        XCTAssertEqual(NSMaxRange(structure.blocks[2].range), text.length)
        XCTAssertEqual(structure.lineIndex(containing: text.range(of: "text").location), 7)
    }

    func testFenceClosingNeedsSameMarkerAndLength() {
        let text = "````\n```\nstill code\n````\nafter" as NSString
        let structure = highlighter.structure(of: text)
        XCTAssertEqual(structure.blocks.count, 1)
        XCTAssertEqual(text.substring(with: structure.blocks[0].contentRange), "```\nstill code")
    }

    func testLineAndInlineTokens() {
        let found = tokens("# Title\n> quote\n- [ ] task\n**bold** *it* ~~gone~~ ==hi== `*code*` [link](u.md) [[Wiki]]")
        func has(_ text: String, _ kind: MarkdownSourceTokenKind) -> Bool {
            found.contains { $0.0 == text && $0.1 == kind }
        }
        XCTAssertTrue(has("#", .headingMarker))
        XCTAssertTrue(has("Title", .headingText))
        XCTAssertTrue(has(">", .quoteMarker))
        XCTAssertTrue(has("-", .listMarker))
        XCTAssertTrue(has("[ ]", .taskMarker))
        XCTAssertTrue(has("**bold**", .strong))
        XCTAssertTrue(has("*it*", .emphasis))
        XCTAssertTrue(has("~~gone~~", .strikethrough))
        XCTAssertTrue(has("==hi==", .highlight))
        XCTAssertTrue(has("[link]", .linkText))
        XCTAssertTrue(has("(u.md)", .linkDestination))
        XCTAssertTrue(has("[[Wiki]]", .wikiLink))
        XCTAssertEqual(found.last?.0, "`*code*`")
        XCTAssertEqual(found.last?.1, .inlineCode, "code spans are applied last so they win")
    }

    func testFencedCodeUsesCodeHighlighterAndNoInlineTokens() {
        let found = tokens("```swift\nlet value = \"*no*\"\n```")
        XCTAssertTrue(found.contains { $0.0 == "```swift" && $0.1 == .fenceDelimiter })
        XCTAssertTrue(found.contains { $0.0 == "let" && $0.1 == .code(.keyword) })
        XCTAssertFalse(found.contains { $0.1 == .emphasis })
    }

    func testRequestedLinesInsideFenceStillColorAgainstWholeBlock() {
        let text = "```swift\n/* a\nb */\n```" as NSString
        let structure = highlighter.structure(of: text)
        let lineTwo = highlighter.tokens(in: text, structure: structure, lines: 2..<3)
        XCTAssertTrue(lineTwo.contains { text.substring(with: $0.range) == "b */" && $0.kind == .code(.comment) })
        XCTAssertTrue(lineTwo.allSatisfy { NSLocationInRange($0.range.location, structure.lineRange(at: 2)) })
    }
}
