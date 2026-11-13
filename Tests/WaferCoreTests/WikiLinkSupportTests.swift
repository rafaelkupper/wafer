import Foundation
import XCTest
@testable import WaferCore

final class WikiLinkSupportTests: XCTestCase {
    // MARK: - Syntax

    func testSpanParsingTable() {
        let text = "See [[Note]] and [[Other Note|alias]] plus [[Guide#Setup]] and ![[logo.png]] here"
        let spans = WikiLinkSyntax.spans(in: text)

        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans[0].target, "Note")
        XCTAssertNil(spans[0].alias)
        XCTAssertNil(spans[0].heading)
        XCTAssertFalse(spans[0].isEmbed)
        XCTAssertEqual(spans[0].displayText, "Note")

        XCTAssertEqual(spans[1].target, "Other Note")
        XCTAssertEqual(spans[1].alias, "alias")
        XCTAssertEqual(spans[1].displayText, "alias")

        XCTAssertEqual(spans[2].target, "Guide")
        XCTAssertEqual(spans[2].heading, "Setup")
        XCTAssertEqual(spans[2].displayText, "Guide › Setup")

        XCTAssertTrue(spans[3].isEmbed)
        XCTAssertEqual(spans[3].target, "logo.png")
        XCTAssertTrue(spans[3].targetIsImage)
    }

    func testSpanParsingRejectsMalformedForms() {
        XCTAssertTrue(WikiLinkSyntax.spans(in: "no links here").isEmpty)
        XCTAssertTrue(WikiLinkSyntax.spans(in: "[[unterminated").isEmpty)
        XCTAssertTrue(WikiLinkSyntax.spans(in: "[[]]").isEmpty)
        XCTAssertTrue(WikiLinkSyntax.spans(in: "[[ | ]]").isEmpty)
        XCTAssertTrue(WikiLinkSyntax.spans(in: "[[a [[nested]] b]]").count == 1)

        // Same-document heading-only form is valid.
        let headingOnly = WikiLinkSyntax.spans(in: "[[#Setup]]")
        XCTAssertEqual(headingOnly.count, 1)
        XCTAssertEqual(headingOnly[0].target, "")
        XCTAssertEqual(headingOnly[0].heading, "Setup")
    }

    // MARK: - Index

    func testIndexResolvesByFilenameAndTitleWithFolding() {
        let index = WikiLinkIndex(entries: [
            (URL(fileURLWithPath: "/vault/Notes/Café Guide.md"), "The Café Guide"),
            (URL(fileURLWithPath: "/vault/Other.md"), "Other"),
        ])

        XCTAssertEqual(index.resolve("café guide")?.lastPathComponent, "Café Guide.md")
        XCTAssertEqual(index.resolve("CAFE GUIDE")?.lastPathComponent, "Café Guide.md")
        XCTAssertEqual(index.resolve("the cafe guide")?.lastPathComponent, "Café Guide.md")
        XCTAssertNil(index.resolve("missing"))
    }

    func testIndexAmbiguityResolvesToShortestPathThenLexicographic() {
        let index = WikiLinkIndex(entries: [
            (URL(fileURLWithPath: "/vault/deeply/nested/Guide.md"), "Guide"),
            (URL(fileURLWithPath: "/vault/Guide.md"), "Guide"),
            (URL(fileURLWithPath: "/vault/b/Guide.md"), "Guide"),
            (URL(fileURLWithPath: "/vault/a/Guide.md"), "Guide"),
        ])

        XCTAssertEqual(index.resolve("guide")?.path, "/vault/Guide.md")

        let tieIndex = WikiLinkIndex(entries: [
            (URL(fileURLWithPath: "/vault/b/Note.md"), "Note"),
            (URL(fileURLWithPath: "/vault/a/Note.md"), "Note"),
        ])
        XCTAssertEqual(tieIndex.resolve("note")?.path, "/vault/a/Note.md")
    }

    // MARK: - Wiki URL round trip

    func testWikiURLRoundTripsPathAndAnchor() throws {
        let fileURL = URL(fileURLWithPath: "/vault/My Notes/Café.md")
        let url = try XCTUnwrap(WikiLinkURL.url(for: fileURL, anchorID: "setup-2"))
        XCTAssertEqual(url.scheme, "wafer-wiki")

        let destination = try XCTUnwrap(WikiLinkURL.destination(from: url))
        XCTAssertEqual(destination.fileURL.path, "/vault/My Notes/Café.md")
        XCTAssertEqual(destination.anchorID, "setup-2")

        let noAnchor = try XCTUnwrap(WikiLinkURL.url(for: fileURL, anchorID: nil))
        XCTAssertNil(try XCTUnwrap(WikiLinkURL.destination(from: noAnchor)).anchorID)
        XCTAssertNil(WikiLinkURL.destination(from: URL(string: "https://example.com")!))
    }

    // MARK: - Rendering

    private func render(
        _ source: String,
        index: WikiLinkIndex? = nil,
        target: RenderTarget = .reader,
        baseURL: URL? = nil
    ) -> WebKitRenderOutput {
        let document = MarkdownParser().parse(source: source, baseURL: baseURL)
        return WebKitHTMLRenderer(palette: .dark, target: target, wikiLinkIndex: index)
            .render(document: document)
    }

    func testResolvedWikiLinksEmitInTabHrefsAndUnresolvedStyledSpans() {
        let index = WikiLinkIndex(entries: [
            (URL(fileURLWithPath: "/vault/Guide.md"), "Guide"),
        ])
        let output = render("See [[Guide#Setup|the guide]] and [[Missing]].", index: index)

        XCTAssertTrue(output.hasWikiLinks)
        XCTAssertTrue(output.html.contains(#"<a class="md-wikilink" href="wafer-wiki://open?path=/vault/Guide.md&amp;anchor=setup">the guide</a>"#))
        XCTAssertTrue(output.html.contains(#"<span class="md-wikilink-unresolved">Missing</span>"#))
    }

    func testPreviewTargetAlwaysRendersUnresolvedStyling() {
        let index = WikiLinkIndex(entries: [
            (URL(fileURLWithPath: "/vault/Guide.md"), "Guide"),
        ])
        let output = render("See [[Guide]].", index: index, target: .preview)

        XCTAssertTrue(output.html.contains(#"<span class="md-wikilink-unresolved">Guide</span>"#))
        XCTAssertFalse(output.html.contains("wafer-wiki"))
    }

    func testNilIndexRendersEverythingUnresolved() {
        let output = render("See [[Guide]].")
        XCTAssertTrue(output.html.contains(#"<span class="md-wikilink-unresolved">Guide</span>"#))
        XCTAssertTrue(output.hasWikiLinks)
    }

    func testSameDocumentHeadingFormLinksToSlugAgainstDocument() throws {
        let tempDirectory = try TemporaryCoreTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Note.md", contents: "x")

        let output = render("Jump to [[#My Heading]].", baseURL: fileURL)
        XCTAssertTrue(output.html.contains(#"<a class="md-wikilink" href="Note.md#my-heading">My Heading</a>"#))
    }

    func testImageEmbedUsesImagePipelineAndNoteEmbedStaysUnresolvedStyled() throws {
        let tempDirectory = try TemporaryCoreTestDirectory()
        defer { tempDirectory.remove() }
        let fileURL = try tempDirectory.createTextFile(named: "Note.md", contents: "x")
        _ = try tempDirectory.createTextFile(named: "logo.png", contents: "fake image bytes")

        let index = WikiLinkIndex(entries: [
            (URL(fileURLWithPath: tempDirectory.url.appendingPathComponent("Other.md").path), "Other"),
        ])
        let output = render(
            "Look ![[logo.png]] and ![[Other]].",
            index: index,
            baseURL: fileURL
        )

        XCTAssertTrue(output.html.contains(#"<img src="wafer-local"#))
        XCTAssertTrue(output.html.contains("logo.png"))
        // Note transclusion is deferred: renders as the unresolved styling.
        XCTAssertTrue(output.html.contains(#"<span class="md-wikilink-unresolved">Other</span>"#))
    }

    func testWikiLinksComposeWithAutolinksEmojiHighlightsAndFootnotes() {
        let index = WikiLinkIndex(entries: [
            (URL(fileURLWithPath: "/vault/Guide.md"), "Guide"),
        ])
        let source = """
        Visit https://example.com then [[Guide]] with :rocket: and ==marked== text[^n].

        [^n]: A note.
        """
        let output = render(source, index: index)

        XCTAssertTrue(output.html.contains(#"href="https://example.com""#))
        XCTAssertTrue(output.html.contains(#"class="md-wikilink""#))
        XCTAssertTrue(output.html.contains("🚀"))
        XCTAssertTrue(output.html.contains("<mark>marked</mark>"))
        XCTAssertTrue(output.html.contains(#"class="md-footnote-ref""#))
    }

    func testWikiSyntaxInsideCodeStaysLiteral() {
        let output = render("Code `[[Guide]]` and fence:\n\n```\n[[Guide]]\n```\n")
        XCTAssertFalse(output.hasWikiLinks)
        XCTAssertFalse(output.html.contains(#"class="md-wikilink"#))
        XCTAssertTrue(output.html.contains("[[Guide]]"))
    }
}

private struct TemporaryCoreTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createTextFile(named name: String, contents: String) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
