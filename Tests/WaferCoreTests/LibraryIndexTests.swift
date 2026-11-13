import Foundation
import XCTest
@testable import WaferCore

final class LibraryIndexTests: XCTestCase {
    private let parser = MarkdownParser()

    func testScanFindsMarkdownFilesAndSkipsUnsupportedHiddenAndJunkPaths() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }

        _ = try tempDirectory.createTextFile(named: "README.md", contents: "# Read Me")
        _ = try tempDirectory.createTextFile(named: "guides/Guide.markdown", contents: "# Guide")
        _ = try tempDirectory.createTextFile(named: "guides/Deep.mdown", contents: "# Deep")
        _ = try tempDirectory.createTextFile(named: "guides/Nested.mkd", contents: "# Nested")
        _ = try tempDirectory.createTextFile(named: "notes.txt", contents: "# Plain Text")
        _ = try tempDirectory.createTextFile(named: ".hidden.md", contents: "# Hidden")
        _ = try tempDirectory.createTextFile(named: "node_modules/Package.md", contents: "# Package")
        _ = try tempDirectory.createTextFile(named: ".git/Commit.md", contents: "# Commit")
        _ = try tempDirectory.createTextFile(named: ".build/Build.md", contents: "# Build")
        _ = try tempDirectory.createTextFile(named: "dist/Dist.md", contents: "# Dist")
        _ = try tempDirectory.createTextFile(named: "build/App.md", contents: "# App")

        let result = LibraryScanner.scan(rootURL: tempDirectory.url)

        XCTAssertFalse(result.truncated)
        XCTAssertEqual(
            result.files.map { $0.relativePathComponents.joined(separator: "/") },
            ["guides/Deep.mdown", "guides/Guide.markdown", "guides/Nested.mkd", "README.md"]
        )
        XCTAssertEqual(result.files.map(\.displayTitle), ["Deep", "Guide", "Nested", "Read Me"])
    }

    func testScanSkipsSymlinkedDirectoryCycles() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }

        _ = try tempDirectory.createTextFile(named: "docs/Guide.md", contents: "# Guide")
        let loopURL = tempDirectory.url.appendingPathComponent("docs/loop", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: loopURL, withDestinationURL: tempDirectory.url)

        let result = LibraryScanner.scan(rootURL: tempDirectory.url)

        XCTAssertEqual(result.files.map { $0.relativePathComponents.joined(separator: "/") }, ["docs/Guide.md"])
    }

    func testScanReusesFirstHeadingAndOutlineSlugLogic() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }
        let source = """
        # Café Intro

        Body.

        ## Details
        ## Details
        """
        let fileURL = try tempDirectory.createTextFile(named: "Guide.md", contents: source)
        let document = parser.parse(source: source, baseURL: fileURL)

        let result = LibraryScanner.scan(rootURL: tempDirectory.url)
        let file = try XCTUnwrap(result.files.first)

        XCTAssertEqual(file.displayTitle, "Café Intro")
        XCTAssertEqual(file.outlineItems, DocumentSidebarDataBuilder.outlineItems(from: document))
        XCTAssertEqual(file.outlineItems.map(\.anchorID), ["cafe-intro", "details", "details-2"])
    }

    func testScanFallsBackToFilenameWithoutExtensionWhenNoH1Exists() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }

        _ = try tempDirectory.createTextFile(named: "NoHeading.md", contents: "Body only.")

        let result = LibraryScanner.scan(rootURL: tempDirectory.url)

        XCTAssertEqual(result.files.first?.displayTitle, "NoHeading")
    }

    func testScanDecodesUTF16FallbackLikeSidebarBuilder() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }
        let fileURL = tempDirectory.url.appendingPathComponent("Encoded.md")
        try Data("# UTF16\n\nBody".utf16Bytes).write(to: fileURL)

        let result = LibraryScanner.scan(rootURL: tempDirectory.url)

        XCTAssertEqual(result.files.first?.displayTitle, "UTF16")
    }

    func testScanAppliesFileLimitAndReportsTruncation() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }
        for index in 1...5 {
            _ = try tempDirectory.createTextFile(named: "0\(index).md", contents: "# File \(index)")
        }

        let result = LibraryScanner.scan(rootURL: tempDirectory.url, fileLimit: 3)

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.files.count, 3)
        XCTAssertEqual(
            result.files.map { $0.relativePathComponents.joined(separator: "/") },
            ["01.md", "02.md", "03.md"]
        )
    }

    func testZeroFileLimitReportsTruncationUsingLibraryTraversalRules() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }

        _ = try tempDirectory.createTextFile(named: ".git/Ignored.md", contents: "# Ignored")
        _ = try tempDirectory.createTextFile(named: "Notes.txt", contents: "Nope")
        _ = try tempDirectory.createTextFile(named: "A.md", contents: "# A")

        XCTAssertTrue(LibraryScanner.scan(rootURL: tempDirectory.url, fileLimit: 0).truncated)
    }

    func testZeroFileLimitIsNotTruncatedWhenRootHasNoMarkdownFiles() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }

        _ = try tempDirectory.createTextFile(named: ".git/Ignored.md", contents: "# Ignored")
        _ = try tempDirectory.createTextFile(named: "Notes.txt", contents: "Nope")

        XCTAssertFalse(LibraryScanner.scan(rootURL: tempDirectory.url, fileLimit: 0).truncated)
    }

    func testSearchableTextIsFoldedLowercasedAndCollapsed() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }

        _ = try tempDirectory.createTextFile(named: "Cafe.md", contents: "# Café\n\nMulti\nline   body.")

        let result = LibraryScanner.scan(rootURL: tempDirectory.url)

        XCTAssertEqual(result.files.first?.plainText, "Café Multi line body.")
        XCTAssertEqual(result.files.first?.searchableText, "cafe multi line body.")
    }

    func testScanIndexesRenderedFootnoteDefinitionsWithoutReferenceMarkers() throws {
        let tempDirectory = try CoreLibraryTemporaryDirectory()
        defer { tempDirectory.remove() }

        _ = try tempDirectory.createTextFile(
            named: "Footnotes.md",
            contents: """
            # Footnotes

            Body with note.[^one]

            [^one]: Searchable footnote body.
            [^unused]: Hidden footnote body.
            """
        )

        let result = LibraryScanner.scan(rootURL: tempDirectory.url)
        let file = try XCTUnwrap(result.files.first)

        XCTAssertEqual(file.plainText, "Footnotes Body with note. Searchable footnote body.")
        XCTAssertEqual(file.searchableText, "footnotes body with note. searchable footnote body.")
        XCTAssertFalse(file.plainText.contains("[^one]"))
        XCTAssertFalse(file.plainText.contains("Hidden footnote body"))
    }
}

private struct CoreLibraryTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createTextFile(named name: String, contents: String) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private extension String {
    var utf16Bytes: [UInt8] {
        Array(data(using: .unicode)!)
    }
}
