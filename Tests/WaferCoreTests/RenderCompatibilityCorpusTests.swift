import Foundation
import XCTest
@testable import WaferCore

final class RenderCompatibilityCorpusTests: XCTestCase {
    private let parser = MarkdownParser()

    func testTierOneCorpusReaderAndPreviewGoldensAreStable() throws {
        for fixture in ["github-readme", "obsidian-note", "commonmark-edges", "kitchen-sink"] {
            let sourceURL = fixtureURL(named: fixture)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let document = parser.parse(source: source, baseURL: sourceURL)
            let reader = WebKitHTMLRenderer(palette: .dark, target: .reader).render(document: document)
            let preview = WebKitHTMLRenderer(palette: .dark, target: .preview).render(document: document)
            let secondReader = WebKitHTMLRenderer(palette: .dark, target: .reader).render(document: document)
            let secondPreview = WebKitHTMLRenderer(palette: .dark, target: .preview).render(document: document)

            XCTAssertEqual(normalizedCorpusHTML(reader.html), normalizedCorpusHTML(secondReader.html), fixture)
            XCTAssertEqual(normalizedCorpusHTML(preview.html), normalizedCorpusHTML(secondPreview.html), fixture)
            try assertGolden(reader.html, named: fixture + ".reader.html")
            try assertGolden(preview.html, named: fixture + ".preview.html")
            assertStructuralExpectations(fixture: fixture, reader: reader, preview: preview)
        }
    }

    func testKitchenSinkExportPreservesTierOneCompatibilityMarkup() throws {
        let sourceURL = fixtureURL(named: "kitchen-sink")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let document = parser.parse(source: source, baseURL: sourceURL)
        let reader = WebKitHTMLRenderer(palette: .dark, target: .reader).render(document: document)
        let exported = try ExportSanitizer.sanitize(
            domHTML: reader.html,
            policy: ExportSanitizer.ExportPolicy { rawSource in
                rawSource.contains("logo") ? "data:image/svg+xml;base64,PHN2Zy8+" : nil
            }
        )

        XCTAssertTrue(exported.contains(#"class="md-callout md-callout-tip""#))
        XCTAssertTrue(exported.contains(#"href="mailto:support@example.com""#))
        XCTAssertTrue(exported.contains(#"<figure>"#))
        XCTAssertTrue(exported.contains(#"<figcaption>Figure caption</figcaption>"#))
        XCTAssertTrue(exported.contains(#"<source media="(prefers-color-scheme: dark)" type="image/svg+xml" srcset="data:image/svg+xml;base64,PHN2Zy8+ 1x">"#))
        XCTAssertTrue(exported.contains(#"<a id="whats-new" class="md-anchor-alias" aria-hidden="true"></a>"#))
        XCTAssertFalse(exported.contains("wafer-local:"))
        XCTAssertFalse(exported.contains("wafer-remote:"))
    }

    private func assertStructuralExpectations(
        fixture: String,
        reader: WebKitRenderOutput,
        preview: WebKitRenderOutput,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(reader.html.contains(#"<div id="write">"#), file: file, line: line)
        XCTAssertTrue(preview.html.contains(#"<div id="write">"#), file: file, line: line)

        switch fixture {
        case "github-readme":
            XCTAssertTrue(reader.html.contains(#"class="md-callout md-callout-note""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"class="md-callout md-callout-warning""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"href="https://example.com/releases""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains("<picture>"), file: file, line: line)
            XCTAssertTrue(reader.html.contains("<source"), file: file, line: line)
            XCTAssertFalse(preview.html.contains("<source"), file: file, line: line)
            XCTAssertEqual(preview.previewAttachments.count, 1, file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<a id="whats-new" class="md-anchor-alias" aria-hidden="true"></a>"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<section class="md-footnotes" aria-label="Footnotes">"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains("This definition renders as a Tier 2 footnote."), file: file, line: line)
            XCTAssertFalse(reader.html.contains("[^demo]"), file: file, line: line)
        case "obsidian-note":
            XCTAssertTrue(reader.html.contains(#"<details class="md-front-matter">"#), file: file, line: line)
            XCTAssertEqual(reader.outlineItems.map(\.title), ["Vault Links"], file: file, line: line)
            XCTAssertTrue(reader.html.contains("known emoji 🚀"), file: file, line: line)
            XCTAssertTrue(reader.html.contains("<mark>highlight syntax</mark>"), file: file, line: line)
            XCTAssertTrue(reader.html.contains("<blockquote>"), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"href="https://example.com/vault""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<span class="md-wikilink-unresolved">Another Note</span>"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<span class="md-wikilink-unresolved">an alias</span>"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<span class="md-wikilink-unresolved">Guide › Setup</span>"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<a class="md-wikilink" href="obsidian-note.md#vault-links">Vault Links</a>"#), file: file, line: line)
            XCTAssertTrue(preview.html.contains(#"<span class="md-wikilink-unresolved">Another Note</span>"#), file: file, line: line)
        case "commonmark-edges":
            XCTAssertTrue(reader.html.contains(#"<h1 id="setext-title">Setext Title</h1>"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<h2 id="subheading">Subheading</h2>"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"href="https://example.com/reference""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<br />"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains("<hr />"), file: file, line: line)
            XCTAssertTrue(preview.html.contains("[Remote image omitted: Remote reference]"), file: file, line: line)
        case "kitchen-sink":
            XCTAssertTrue(reader.html.contains(#"href="mailto:support@example.com""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"class="md-callout md-callout-tip""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"class="md-callout md-callout-important""#), file: file, line: line)
            XCTAssertTrue(reader.html.contains("<figure>"), file: file, line: line)
            XCTAssertTrue(reader.html.contains("<dl>"), file: file, line: line)
            XCTAssertTrue(reader.html.contains(#"<ol start="4">"#), file: file, line: line)
            XCTAssertTrue(reader.html.contains("language-sql"), file: file, line: line)
            XCTAssertTrue(reader.html.contains("language-kotlin"), file: file, line: line)
            XCTAssertTrue(reader.html.contains("language-makefile"), file: file, line: line)
            XCTAssertEqual(preview.previewAttachments.count, 1, file: file, line: line)
            XCTAssertTrue(preview.html.contains("cid:preview-asset-1"), file: file, line: line)
        default:
            XCTFail("Unexpected fixture \(fixture)", file: file, line: line)
        }
    }

    private func fixtureURL(named name: String) -> URL {
        fixtureDirectory.appendingPathComponent("\(name).md")
    }

    private var fixtureDirectory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WaferCore")
    }

    private func assertGolden(_ html: String, named name: String) throws {
        let actual = normalizedCorpusHTML(html)
        if ProcessInfo.processInfo.environment["WAFER_UPDATE_GOLDENS"] == "1" {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/Fixtures/WaferCore/Goldens")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try actual.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } else {
            let expected = try String(contentsOf: fixtureDirectory.appendingPathComponent("Goldens/" + name), encoding: .utf8)
            let expectedLines = expected.components(separatedBy: "\n")
            let actualLines = actual.components(separatedBy: "\n")
            if expectedLines != actualLines {
                let first = (0..<min(expectedLines.count, actualLines.count)).first { expectedLines[$0] != actualLines[$0] } ?? min(expectedLines.count, actualLines.count)
                XCTFail("\(name), line \(first + 1):\nexpected: \(expectedLines.dropFirst(first).prefix(3).joined(separator: "\n"))\nactual: \(actualLines.dropFirst(first).prefix(3).joined(separator: "\n"))\nRegenerate with WAFER_UPDATE_GOLDENS=1 swift test --filter RenderCompatibilityCorpusTests")
            }
        }
    }

    private func normalizedCorpusHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: fixtureDirectory.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fixtureDirectory.path, with: "$FIXTURE_DIR")
            .replacingOccurrences(of: fixtureDirectory.path, with: "$FIXTURE_DIR")
    }
}
