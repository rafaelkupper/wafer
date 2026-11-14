import Foundation
import XCTest
@testable import WaferCore

final class CoreReviewFixTests: XCTestCase {
    func testDisallowedSchemesAreInertInBothMarkdownAndHTMLAndExport() throws {
        for destination in ["javascript:alert", "data:text/html,evil", "shortcuts://run", "ssh:host", "custom-wafer:test"] {
            let document = MarkdownParser().parse(source: "[Markdown](\(destination))\n\n<a href=\"\(destination)\">HTML</a>", baseURL: URL(fileURLWithPath: "/tmp/Note.md"))
            for target in [RenderTarget.reader, .preview] {
                let output = WebKitHTMLRenderer(target: target).render(document: document)
                XCTAssertFalse(output.html.contains("href=\"\(destination)"), destination)
                XCTAssertTrue(output.html.contains("Markdown"))
                XCTAssertTrue(output.html.contains("HTML"))
            }
            XCTAssertEqual(AssetResolver().classify(try XCTUnwrap(URL(string: destination))), .unresolved(destination))
            let exported = try export("<a href=\"\(destination)\">HTML</a>")
            XCTAssertFalse(exported.contains("href="), exported)
        }
    }

    func testFragmentsAreDecodedForDOMAndEncodedOnceForLinks() throws {
        let base = URL(fileURLWithPath: "/tmp/Note.md")
        for anchor in ["café", "日本語", "100%25"] {
            let encoded = anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
            for fragment in [anchor, encoded] {
                let source = "[jump](#\(fragment))\n\n<a href=\"#\(fragment)\">raw</a>"
                let document = MarkdownParser().parse(source: source, baseURL: base)
                let html = WebKitHTMLRenderer().render(document: document).html
                // Percent escapes supplied in Markdown are decoded before resolution.
                let decoded = fragment.removingPercentEncoding ?? fragment
                let expected = decoded.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
                XCTAssertTrue(html.contains("href=\"Note.md#\(expected)\""), html.suffix(600).description)
            }
            var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            parts.fragment = anchor
            XCTAssertEqual(parts.url!.decodedFragment, anchor)
            XCTAssertEqual(parts.url!.standardizedFileURLPreservingFragment().decodedFragment, anchor)
        }
    }

    func testReaderBalancesRawHTMLAcrossNodesAndDropsStrayCloses() {
        let source = "</div>\n\n<div><b>first</div></b>\n\nText <em>inline</em>.\n\n<details>\n\nlast"
        let document = MarkdownParser().parse(source: source, baseURL: nil)
        let body = WebKitHTMLRenderer().render(document: document).bodyHTML!
        XCTAssertFalse(body.hasPrefix("</div>"))
        XCTAssertTrue(body.contains("<div><b>first</b></div>"), body)
        XCTAssertTrue(body.contains("Text <em>inline</em>."), body)
        XCTAssertTrue(body.hasSuffix("</details>"), body)
    }

    func testSharedTokenizerAdversarialInputsAreSafeInBothSanitizers() throws {
        let sanitizer = HTMLSanitizer(policy: HTMLSanitizerPolicy(resolveImageSource: { _ in nil }, resolveLinkHref: {
            LinkURLPolicy.allows($0) ? $0 : nil
        }))
        for value in ["jav&#x61;script:alert(1)", "javascript&colon;alert(1)", "java&#9;script:alert(1)", "&#106;avascript:alert(1)", "data&colon;text/html,bad"] {
            let source = "<a href=\"\(value)\" onclick=\"bad()\">safe</a>"
            for output in [sanitizer.sanitize(source), try export(source)] {
                XCTAssertFalse(output.contains("href="), output)
                XCTAssertFalse(output.contains("onclick="), output)
                XCTAssertTrue(output.contains("safe"))
            }
        }
        for source in ["<script data-x='>'>evil</script><b>safe</b>", "<!-- <img src=x onerror=evil> --><b>safe</b>", "<b title='unterminated", "<img src=\"x\" onerror=\"bad\"><b>safe</b>"] {
            for output in [sanitizer.sanitize(source), try export(source)] {
                XCTAssertFalse(output.contains("<script"), output)
                let activeHTML = output.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
                XCTAssertFalse(activeHTML.contains("onerror="), output)
            }
        }
        let entity = "<a href=\"https://example.com/?x=1&amp;y=2\">safe</a>"
        XCTAssertTrue(sanitizer.sanitize(entity).contains("?x=1&amp;y=2"))
        XCTAssertTrue(try export(entity).contains("?x=1&amp;y=2"))
    }

    func testExportStripsActiveUnknownMarkupAndKeepsSafeAttributes() throws {
        let output = try export("<custom onclick='evil' title='safe' href='javascript:bad'>text</custom><iframe srcdoc='evil'>evil</iframe><object>evil</object><embed src='evil'><svg><set attributeName='onload' to='evil'/></svg>")
        XCTAssertFalse(output.contains("onclick"))
        XCTAssertFalse(output.contains("javascript:"))
        XCTAssertFalse(output.contains("srcdoc"))
        XCTAssertFalse(output.contains("<object"))
        XCTAssertFalse(output.contains("<embed"))
        XCTAssertFalse(output.contains("<set"))
        XCTAssertTrue(output.contains("<custom title=\"safe\">text</custom>"))
    }

    func testLatin1DoesNotMasqueradeAsUTF16() {
        for bytes: [UInt8] in [[0x63, 0x61, 0x66, 0xE9], [0x63, 0x61, 0x66, 0xE9, 0x21]] {
            XCTAssertNil(MarkdownSourceDecoding.decode(Data(bytes)))
            XCTAssertNil(MarkdownTextFormat.decode(Data(bytes)))
        }
        XCTAssertEqual(MarkdownSourceDecoding.decode(Data([0x61, 0, 0x62, 0])), "ab")
        XCTAssertEqual(MarkdownSourceDecoding.decode(Data([0xFF, 0xFE, 0xE9, 0])), "é")
    }

    func testCRLFInputNormalizesBeforeEncoding() {
        let format = MarkdownTextFormat(encoding: .utf8, hasByteOrderMark: false, lineEnding: .crlf)
        XCTAssertEqual(String(decoding: format.encode("a\r\nb"), as: UTF8.self), "a\r\nb")
        XCTAssertEqual(String(decoding: MarkdownTextFormat.default.encode("a\r\nb\rc"), as: UTF8.self), "a\nb\nc")
    }

    func testIdentifiersUseLocaleIndependentFolding() {
        let title = "Installation"
        let turkish = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
        XCTAssertNotEqual(turkish, "installation")
        XCTAssertEqual(WikiLinkIndex.fold(title), "installation")
        var slugger = HeadingAnchorSlugger()
        XCTAssertEqual(slugger.slug(for: title), "installation")
        XCTAssertEqual(title.libraryFoldedSearchText, "installation")
    }

    func testScrollVersionsReplaceOneEntryAndLegacyKeysArePruned() throws {
        let defaults = makeTestUserDefaults()
        defaults.set(try JSONEncoder().encode(ScrollState(fraction: 0.5)), forKey: "scroll-state:legacy")
        let store = ScrollStateStore(defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: "scroll-state:legacy"))
        store.pruneLegacyEntries()
        store.pruneLegacyEntries()
        let file = URL(fileURLWithPath: "/tmp/Note.md")
        for version in 0..<100 { store.save(fraction: 0.4, for: file, fingerprint: String(version)) }
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("scroll-state") }.count, 1)
        XCTAssertNil(store.load(for: file, fingerprint: "98"))
        XCTAssertEqual(store.load(for: file, fingerprint: "99")?.fraction, 0.4)
    }

    func testLibraryBudgetsSkipOversizedFilesAndRetainPreviousEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B", "C"] { try Data("# \(name)\nbody".utf8).write(to: root.appendingPathComponent(name + ".md")) }
        let result = LibraryScanner.scan(rootURL: root, maximumFileByteCount: 10, maximumLibraryByteCount: 16)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.skippedItemCount, 1)
        let previous = LibraryScanner.scan(rootURL: root)
        try Data(repeating: 65, count: 30).write(to: root.appendingPathComponent("B.md"))
        let refreshed = LibraryScanner.scan(rootURL: root, existingFiles: previous.files, changedPaths: nil, maximumFileByteCount: 10)
        XCTAssertEqual(refreshed.files, previous.files)
        XCTAssertEqual(refreshed.skippedItemCount, 1)
    }

    func testSandboxedPreviewDeterministicallyOmitsLocalImagesAndScripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try Data("![local](image.png)\n\n<img src=\"image.png\">\n\n```mermaid\ngraph TD; A-->B\n```\n\n```math\nx^2\n```".utf8).write(to: file)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("image.png"))
        let result = try PreviewComposer(allowsLocalImages: false).compose(fileURL: file, isDark: false)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertFalse(result.html.contains("cid:"))
        XCTAssertFalse(result.html.contains("<script"))
        XCTAssertFalse(result.html.contains("wafer-local:"))
        XCTAssertFalse(result.html.contains("lang=\"en\""))
    }

    func testThemeColorConversionPreservesHexAlphaAndKaTeXUsesOnlyWOFF2() throws {
        let color = try XCTUnwrap(ReaderTheme.color(fromHex: "#12345680").usingColorSpace(.sRGB))
        XCTAssertEqual(color.alphaComponent, 128.0 / 255.0, accuracy: 0.0001)
        let url = try XCTUnwrap(ReaderTheme.resourceURL(named: "katex/katex.min.css"))
        let css = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(css.contains(".woff2"))
        XCTAssertNil(css.range(of: #"\.(ttf|woff)[)\"']"#, options: .regularExpression))
    }

    private func export(_ html: String) throws -> String {
        try ExportSanitizer.sanitize(domHTML: html, policy: .init(inlineImage: { _ in nil }))
    }
}
