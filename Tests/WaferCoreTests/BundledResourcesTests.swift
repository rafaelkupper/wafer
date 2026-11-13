import Foundation
import XCTest
@testable import WaferCore

final class BundledResourcesTests: XCTestCase {
    func testMissingBundleAndMissingResourceReturnNil() {
        XCTAssertNil(BundledResources.resourceURL(named: "missing.js", bundleName: "Missing", searchDirectories: []))
        XCTAssertNil(ReaderTheme.resourceURL(named: "missing-test-resource.js"))
        XCTAssertNil(WebKitHTMLRenderer.bundledScript(named: "missing-test-resource.js"))
    }

    func testThemeAndEmojiHaveDefinedFallbacksForMissingOrCorruptResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.css")
        for url in [nil, missing] as [URL?] {
            XCTAssertTrue(ReaderTheme.loadStyleSheetBody(from: url).contains("#write"))
            XCTAssertEqual(EmojiShortcodes.load(from: url), [:])
        }
        let invalid = root.appendingPathComponent("invalid.json")
        try Data("invalid JSON".utf8).write(to: invalid)
        XCTAssertEqual(EmojiShortcodes.load(from: invalid), [:])
        XCTAssertEqual(MarkdownInlineCompatibility.htmlByRenderingTextDecorations(
            in: ":smile:", emojiShortcodes: EmojiShortcodes.load(from: nil)), ":smile:")
    }

    func testCoreResourcesResolveIncludingFlattenedSwiftPMNames() {
        for name in ["reader-theme.css", "gemoji-shortcodes.json", "async-renderer.js",
                     "mermaid.min.js", "mermaid-bootstrap.js", "katex-bootstrap.js",
                     "katex/katex.min.css", "katex/katex.min.js", "katex/fonts/KaTeX_Main-Regular.woff2"] {
            XCTAssertNotNil(BundledResources.resourceURL(named: name, bundleName: "Wafer_WaferCore"), name)
        }
        XCTAssertTrue(WebKitHTMLRenderer.canRenderMath)
        XCTAssertTrue(WebKitHTMLRenderer.canRenderMermaid)
        XCTAssertNotNil(WebKitHTMLRenderer.katexStyleSheet)
    }
}
