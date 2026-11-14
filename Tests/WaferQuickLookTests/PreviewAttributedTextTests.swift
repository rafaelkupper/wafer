import AppKit
import XCTest
@testable import WaferCore

final class PreviewAttributedTextTests: XCTestCase {
    func testImportsHTMLAsRichTextWithPaletteColors() throws {
        let palette = ReaderThemePalette.dark
        let attributed = PreviewAttributedText.make(
            html: "<html><body><h1>Title</h1><p>Body <strong>bold</strong></p></body></html>",
            palette: palette
        )

        XCTAssertTrue(attributed.string.contains("Title"))
        XCTAssertTrue(attributed.string.contains("Body bold"))
        XCTAssertFalse(attributed.string.contains("<h1>"))
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        let foreground = try XCTUnwrap(attributes[.foregroundColor] as? NSColor)
        let background = try XCTUnwrap(attributes[.backgroundColor] as? NSColor)
        XCTAssertEqual(foreground, ReaderTheme.color(fromHex: palette.textHex))
        XCTAssertEqual(background, ReaderTheme.color(fromHex: palette.backgroundHex))
    }

    func testFallsBackToPlainTextWhenHTMLImportFails() throws {
        let palette = ReaderThemePalette.light
        let attributed = PreviewAttributedText.make(
            html: "<p>a &lt; b &amp;&amp; c &gt; d</p>",
            palette: palette,
            importHTML: { _ in nil }
        )

        XCTAssertEqual(attributed.string, "a < b && c > d")
        let foreground = try XCTUnwrap(attributed.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor)
        XCTAssertEqual(foreground, ReaderTheme.color(fromHex: palette.textHex))
    }

    func testFallbackTextStripsTagsAndTrims() {
        XCTAssertEqual(PreviewAttributedText.fallbackText(from: "\n<div><em>x</em></div>\n"), "x")
    }
}
