import AppKit
import CryptoKit
import XCTest
@testable import WaferCore

@MainActor
final class ReaderThemeTests: XCTestCase {
    func testScreenStyleSheetBodyMatchesPrePrintGoldenHash() throws {
        let screenBody = try screenStyleSheetBody()

        XCTAssertEqual(
            sha256Hex(screenBody),
            "a1f886a4ff385ec914412d42c776d21967ff1ce87004a3946dea94f26938b321"
        )
    }

    func testInlineStyleSheetOmitsCharsetDirective() {
        XCTAssertFalse(ReaderTheme.styleSheet(for: .dark).contains("@charset"))
    }

    func testPrintStyleSheetBlockPreservesThemedPaginationAndHidesExportChrome() throws {
        let printBlock = try printStyleSheetBlock()

        XCTAssertTrue(printBlock.contains("print-color-adjust: exact;"))
        XCTAssertTrue(printBlock.contains("-webkit-print-color-adjust: exact;"))
        XCTAssertTrue(printBlock.contains("break-inside: avoid;"))
        XCTAssertTrue(printBlock.contains("page-break-inside: avoid;"))

        for selector in ExportSanitizer.strippedChromeSelectors {
            XCTAssertTrue(printBlock.contains(selector), "Missing export chrome selector \(selector)")
        }
        XCTAssertTrue(printBlock.contains(".md-mermaid-open"))
        XCTAssertTrue(printBlock.contains(".md-diagram-inspector"))
    }

    func testSidebarThemeUsesFixedDarkerSurfaceTokens() {
        XCTAssertEqual(ReaderTheme.sidebarBackgroundHex, "#212427")
        XCTAssertEqual(ReaderTheme.sidebarSelectionHex, "#1C2023")
        XCTAssertEqual(ReaderTheme.sidebarHoverAlpha, 0.028, accuracy: 0.0001)
        XCTAssertLessThan(
            luminance(of: ReaderTheme.sidebarBackgroundColor),
            luminance(of: ReaderTheme.backgroundColor)
        )
        XCTAssertTrue(ReaderTheme.styleSheet.contains("overflow-x: hidden;"))
    }

    func testSettingCurrentThemeUpdatesDerivedNativeAndCSSValues() {
        defer { ReaderTheme.resetToDefaultForTesting() }

        ReaderTheme.setCurrent(.light)

        XCTAssertEqual(ReaderTheme.current, .light)
        XCTAssertEqual(ReaderTheme.backgroundHex, ReaderThemePalette.light.backgroundHex)
        XCTAssertEqual(ReaderTheme.secondaryTextHex, ReaderThemePalette.light.secondaryTextHex)
        XCTAssertTrue(ReaderTheme.styleSheet.contains("--bg-color: #FFFFFF;"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("--link-color: #0969DA;"))
    }

    func testMermaidEntityRelationshipRowsUseDarkReaderOverrides() {
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-mermaid-output svg.erDiagram .row-rect-odd > path:first-child"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-mermaid-output svg.erDiagram .row-rect-even > path:first-child"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-mermaid-output svg.erDiagram foreignObject div"))
    }

    func testMermaidDiagramInspectorStylesAreBundled() {
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-mermaid-open"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-diagram-inspector-viewport"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("body.md-diagram-inspector-open"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("overscroll-behavior: contain;"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("touch-action: none;"))
    }

    func testFrontMatterMetadataStylesAreBundled() {
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-front-matter"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-front-matter summary"))
        XCTAssertFalse(ReaderTheme.styleSheet.contains("Document metadata"))
    }

    func testExpandedRawHTMLStylesAreBundled() {
        XCTAssertTrue(ReaderTheme.styleSheet.contains("figcaption,"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("caption-side: bottom;"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("dl {"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("picture img"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("small {"))
    }

    func testFootnoteStylesAreBundled() {
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-footnote-ref"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-footnotes"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-footnote-backref"))
    }

    func testHighlightStylesAreBundled() {
        XCTAssertTrue(ReaderTheme.styleSheet.contains("mark {"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("background: var(--selection-bg-color);"))
    }

    func testMathDisplayStylesAreBundled() {
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-math-display"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains(".md-math-output .katex"))
        XCTAssertTrue(ReaderTheme.styleSheet.contains("color: var(--text-color);"))
    }

    func testFallbackStyleSheetKeepsEmergencyReaderStyles() {
        XCTAssertTrue(fallbackStyleSheet.contains("--bg-color"))
        XCTAssertTrue(fallbackStyleSheet.contains("#write"))
    }

    func testMermaidResourceURLResolvesBundledResource() {
        XCTAssertNotNil(ReaderTheme.resourceURL(named: "mermaid.min.js"))
    }

    func testGemojiResourcesResolveFromBundle() {
        XCTAssertNotNil(ReaderTheme.resourceURL(named: "gemoji-shortcodes.json"))
        XCTAssertNotNil(ReaderTheme.resourceURL(named: "gemoji-LICENSE.txt"))
        XCTAssertEqual(EmojiShortcodes.all["rocket"], "🚀")
    }

    func testKaTeXResourcesResolveFromBundle() {
        XCTAssertNotNil(ReaderTheme.resourceURL(named: "katex/katex.min.js"))
        XCTAssertNotNil(ReaderTheme.resourceURL(named: "katex/katex.min.css"))
        XCTAssertNotNil(ReaderTheme.resourceURL(named: "katex/katex-LICENSE.txt"))
        XCTAssertNotNil(ReaderTheme.resourceURL(named: "katex/fonts/KaTeX_Main-Regular.woff2"))
    }

    private func luminance(of color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
    }

    private func screenStyleSheetBody() throws -> String {
        let body = try styleSheetBody()
        guard let printRange = body.range(of: "\n@media print") else {
            return body
        }
        return String(body[..<printRange.lowerBound])
    }

    private func printStyleSheetBlock() throws -> String {
        let body = try styleSheetBody()
        let printRange = try XCTUnwrap(body.range(of: "\n@media print"))
        return String(body[printRange.lowerBound...])
    }

    private func styleSheetBody() throws -> String {
        let styleSheet = ReaderTheme.styleSheet(for: .dark)
        let bodyStart = try XCTUnwrap(styleSheet.range(of: "html {")?.lowerBound)
        return String(styleSheet[bodyStart...])
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", Int($0)) }
            .joined()
    }
}
