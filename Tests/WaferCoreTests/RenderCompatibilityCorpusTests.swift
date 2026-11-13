import Foundation
import XCTest
@testable import WaferCore

final class RenderCompatibilityCorpusTests: XCTestCase {
    private let parser = MarkdownParser()

    func testTierOneCorpusReaderAndPreviewGoldensAreStable() throws {
        let fixtures: [CorpusFixture] = [
            CorpusFixture(name: "github-readme", readerHash: "eb041923d1f78eac214b77c193e768ac8b065a4d79d5c6906a64b89aa95567c3", previewHash: "743c74e92494122144db01a39bf9dc3ac1591e11c366743e7b53d67078700b79"),
            CorpusFixture(name: "obsidian-note", readerHash: "6b5ac24d78dc2f4d9ca3340db9d6ee7b1e1314fe592480297641f30675b76f30", previewHash: "95b6285370c2b22b19c19c3c27011b588c1b756d95bbeba0519ec7cff413d406"),
            CorpusFixture(name: "commonmark-edges", readerHash: "b133a746400c4cf47b5bcc3bdae29e486831c9e6d88e79244a830ab4f63739e2", previewHash: "7fe7e428da13d39e9ec222a45454b15bfc19782a2e86bf3717c266230744a760"),
            CorpusFixture(name: "kitchen-sink", readerHash: "6f3fa5a7479ca5a498bac49efb6467fd5289e539fc956275f23c6078d451bae3", previewHash: "cbd235eae7c44421d295a624b52d490ac765ffaf0c2fb8997fdc92b83f6581b4"),
        ]

        for fixture in fixtures {
            let sourceURL = fixtureURL(named: fixture.name)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let document = parser.parse(source: source, baseURL: sourceURL)
            let reader = WebKitHTMLRenderer(palette: .dark, target: .reader).render(document: document)
            let preview = WebKitHTMLRenderer(palette: .dark, target: .preview).render(document: document)
            let secondReader = WebKitHTMLRenderer(palette: .dark, target: .reader).render(document: document)
            let secondPreview = WebKitHTMLRenderer(palette: .dark, target: .preview).render(document: document)

            XCTAssertEqual(normalizedCorpusHTML(reader.html), normalizedCorpusHTML(secondReader.html), fixture.name)
            XCTAssertEqual(normalizedCorpusHTML(preview.html), normalizedCorpusHTML(secondPreview.html), fixture.name)
            XCTAssertEqual(FileFingerprint.sha256Hex(for: normalizedCorpusHTML(reader.html)), fixture.readerHash, fixture.name)
            XCTAssertEqual(FileFingerprint.sha256Hex(for: normalizedCorpusHTML(preview.html)), fixture.previewHash, fixture.name)
            assertStructuralExpectations(fixture: fixture.name, reader: reader, preview: preview)
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
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WaferCore")
    }

    private func normalizedCorpusHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: fixtureDirectory.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fixtureDirectory.path, with: "$FIXTURE_DIR")
            .replacingOccurrences(of: fixtureDirectory.path, with: "$FIXTURE_DIR")
    }
}

private struct CorpusFixture {
    let name: String
    let readerHash: String
    let previewHash: String
}
