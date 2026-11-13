import Foundation
import XCTest
@testable import WaferCore

final class DocumentSidebarTests: XCTestCase {
    private let parser = MarkdownParser()
    private let assetResolver = AssetResolver()

    func testSidebarEntriesDedupeMarkdownLinksByIdentity() throws {
        let tempDirectory = try CoreTemporaryDirectory()
        defer { tempDirectory.remove() }

        let currentURL = try tempDirectory.createTextFile(
            named: "Current.md",
            contents: """
            # Current Title

            Current preview text.

            [Guide](Guide.md)
            [Guide Again](Guide.md#deep-link)
            [Notes](notes.txt)
            [External](https://example.com)
            [Missing](Missing.md)
            """
        )
        _ = try tempDirectory.createTextFile(
            named: "Guide.md",
            contents: """
            # Guide Title

            First guide paragraph that becomes the preview.
            """
        )

        let document = parser.parse(source: try String(contentsOf: currentURL), baseURL: currentURL)
        let entries = DocumentSidebarDataBuilder.sidebarEntries(from: document, assetResolver: assetResolver)

        XCTAssertEqual(entries.map(\.displayTitle), ["Current Title", "Guide Title", "Missing"])
        XCTAssertEqual(entries.first?.previewText, "Current preview text.")
        XCTAssertEqual(entries[1].previewText, "First guide paragraph that becomes the preview.")
        XCTAssertTrue(entries[0].isCurrent)
        XCTAssertTrue(entries[1].isAvailable)
        XCTAssertFalse(entries[2].isAvailable)
        XCTAssertEqual(entries[0].fileURL, URL(fileURLWithPath: currentURL.standardizedFileURL.path))
    }

    func testSidebarEntriesUseStableDisplayOrderingInsteadOfPromotingCurrentFile() throws {
        let tempDirectory = try CoreTemporaryDirectory()
        defer { tempDirectory.remove() }

        let currentURL = try tempDirectory.createTextFile(
            named: "Current.md",
            contents: """
            # Zeta Current

            Current preview text.

            [Guide](Guide.md)
            """
        )
        _ = try tempDirectory.createTextFile(
            named: "Guide.md",
            contents: """
            # Alpha Guide

            Linked preview text.
            """
        )

        let document = parser.parse(source: try String(contentsOf: currentURL), baseURL: currentURL)
        let entries = DocumentSidebarDataBuilder.sidebarEntries(from: document, assetResolver: assetResolver)

        XCTAssertEqual(entries.map(\.displayTitle), ["Alpha Guide", "Zeta Current"])
        XCTAssertFalse(entries[0].isCurrent)
        XCTAssertTrue(entries[1].isCurrent)
    }

    func testOutlineItemsPreserveHeadingOrderLevelsAndDuplicateSafeAnchors() {
        let document = parser.parse(
            source: """
            # Intro
            ## Details
            ## Details
            ### Deep Dive
            """,
            baseURL: URL(fileURLWithPath: "/tmp/Outline.md")
        )

        let outlineItems = DocumentSidebarDataBuilder.outlineItems(from: document)

        XCTAssertEqual(outlineItems.map(\.title), ["Intro", "Details", "Details", "Deep Dive"])
        XCTAssertEqual(outlineItems.map(\.level), [1, 2, 2, 3])
        XCTAssertEqual(outlineItems.map(\.anchorID), ["intro", "details", "details-2", "deep-dive"])
    }

    func testHeadingAnchorSluggerProducesGitHubAliasesWithoutChangingPrimarySlugs() {
        // GitHub alias expectations mirror github-slugger examples and live README anchor behavior:
        // https://github.com/flet/github-slugger
        // https://gist.github.com/asabaylus/3071099
        let cases: [(title: String, expected: HeadingAnchorSlugs)] = [
            ("What's New?", HeadingAnchorSlugs(primary: "what-s-new", gitHubAlias: "whats-new")),
            ("Héllo Wörld", HeadingAnchorSlugs(primary: "hello-world", gitHubAlias: "héllo-wörld")),
            ("Command-Gen_Instance", HeadingAnchorSlugs(primary: "command-gen-instance", gitHubAlias: "command-gen_instance")),
            ("Ready, set, GO!", HeadingAnchorSlugs(primary: "ready-set-go", gitHubAlias: nil)),
            ("[0.0.2] - 2019-02-24", HeadingAnchorSlugs(primary: "0-0-2-2019-02-24", gitHubAlias: "002---2019-02-24")),
            ("Привет non-latin 你好", HeadingAnchorSlugs(primary: "non-latin", gitHubAlias: "привет-non-latin-你好")),
            ("C# & F#", HeadingAnchorSlugs(primary: "c-f", gitHubAlias: "c--f")),
            ("MY_MACRO_NAME", HeadingAnchorSlugs(primary: "my-macro-name", gitHubAlias: "my_macro_name")),
        ]

        for testCase in cases {
            var slugger = HeadingAnchorSlugger()
            XCTAssertEqual(slugger.slugs(for: testCase.title), testCase.expected, testCase.title)
        }
    }

    func testHeadingAnchorSluggerDedupesAliasesAndSkipsPageWideIDCollisions() {
        var duplicateSlugger = HeadingAnchorSlugger()
        XCTAssertEqual(
            duplicateSlugger.slugs(for: "What's New?"),
            HeadingAnchorSlugs(primary: "what-s-new", gitHubAlias: "whats-new")
        )
        XCTAssertEqual(
            duplicateSlugger.slugs(for: "What's New?"),
            HeadingAnchorSlugs(primary: "what-s-new-2", gitHubAlias: "whats-new-1")
        )

        var collisionSlugger = HeadingAnchorSlugger()
        XCTAssertEqual(
            collisionSlugger.slugs(for: "a_b"),
            HeadingAnchorSlugs(primary: "a-b", gitHubAlias: "a_b")
        )
        XCTAssertEqual(
            collisionSlugger.slugs(for: "a b"),
            HeadingAnchorSlugs(primary: "a-b-2", gitHubAlias: nil)
        )

        var futurePrimaryCollisionSlugger = HeadingAnchorSlugger(reservedPrimaryIDs: ["ab"])
        XCTAssertEqual(
            futurePrimaryCollisionSlugger.slugs(for: "a.b"),
            HeadingAnchorSlugs(primary: "a-b", gitHubAlias: nil)
        )
        XCTAssertEqual(
            futurePrimaryCollisionSlugger.slugs(for: "ab"),
            HeadingAnchorSlugs(primary: "ab", gitHubAlias: "ab-1")
        )
    }

    func testSidebarPreviewUnderstandsCalloutsSymbolLinksAndInlineAttributes() throws {
        let tempDirectory = try CoreTemporaryDirectory()
        defer { tempDirectory.remove() }

        let currentURL = try tempDirectory.createTextFile(
            named: "Current.md",
            contents: """
            # Current

            [Guide](Guide.md)
            """
        )
        _ = try tempDirectory.createTextFile(
            named: "Guide.md",
            contents: """
            # Guide

            @Tip(title: "Quick hint") {
            Use ``ReaderTheme.styleSheet`` with ^[chip text](class: "md-inline-chip").
            }
            """
        )

        let document = parser.parse(source: try String(contentsOf: currentURL), baseURL: currentURL)
        let entries = DocumentSidebarDataBuilder.sidebarEntries(from: document, assetResolver: assetResolver)

        XCTAssertEqual(entries.map(\.displayTitle), ["Current", "Guide"])
        XCTAssertEqual(entries.last?.previewText, "Quick hint Use ReaderTheme.styleSheet with chip text.")
    }

    func testGitHubAlertMarkersAreStrippedFromPreviewAndPlainText() throws {
        let tempDirectory = try CoreTemporaryDirectory()
        defer { tempDirectory.remove() }

        let currentURL = try tempDirectory.createTextFile(
            named: "Current.md",
            contents: """
            # Current

            > [!CAUTION]
            > Keep the marker out of previews and search text.
            """
        )

        let document = parser.parse(source: try String(contentsOf: currentURL), baseURL: currentURL)
        let entries = DocumentSidebarDataBuilder.sidebarEntries(from: document, assetResolver: assetResolver)
        let plainTextDocument = parser.parse(
            source: """
            > [!TIP]
            > Searchable alert body.
            """,
            baseURL: nil
        )

        XCTAssertEqual(entries.first?.previewText, "Caution Keep the marker out of previews and search text.")
        XCTAssertFalse(entries.first?.previewText.contains("[!CAUTION]") == true)
        XCTAssertEqual(plainTextDocument.ast.plainText.collapsingWhitespace, "Tip Searchable alert body.")
        XCTAssertFalse(plainTextDocument.ast.plainText.contains("[!TIP]"))
    }

    func testFootnoteReferencesAreStrippedFromSidebarTitlesOutlinesAndPreviews() throws {
        let tempDirectory = try CoreTemporaryDirectory()
        defer { tempDirectory.remove() }

        let currentURL = try tempDirectory.createTextFile(
            named: "Current.md",
            contents: """
            # Current [^title]

            Preview text with a note.[^title]

            ## Details [^title]

            [^title]: Footnote body.
            """
        )

        let document = parser.parse(source: try String(contentsOf: currentURL), baseURL: currentURL)
        let entries = DocumentSidebarDataBuilder.sidebarEntries(from: document, assetResolver: assetResolver)
        let outlineItems = DocumentSidebarDataBuilder.outlineItems(from: document)

        XCTAssertEqual(entries.first?.displayTitle, "Current")
        XCTAssertEqual(entries.first?.previewText, "Preview text with a note.")
        XCTAssertEqual(outlineItems.map(\.title), ["Current", "Details"])
        XCTAssertEqual(outlineItems.map(\.anchorID), ["current", "details"])
    }
}

private struct CoreTemporaryDirectory {
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
