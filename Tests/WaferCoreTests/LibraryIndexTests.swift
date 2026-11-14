import Foundation
import XCTest
@testable import WaferCore

final class LibraryIndexTests: XCTestCase {
    func testRecoveryScanReusesUnchangedFilesWithoutParsing() throws {
        let directory = try CoreLibraryTemporaryDirectory()
        defer { directory.remove() }
        _ = try directory.createTextFile(named: "Keep.md", contents: "# Keep\n\nUnchanged")
        let changed = try directory.createTextFile(named: "Change.md", contents: "# Before")
        let initial = LibraryScanner.scan(rootURL: directory.url)
        XCTAssertEqual(initial.parsedFileCount, 2)

        let recovery = LibraryScanner.scan(rootURL: directory.url, existingFiles: initial.files, changedPaths: nil)
        XCTAssertEqual(recovery.files, initial.files)
        XCTAssertEqual(recovery.parsedFileCount, 0, "a recovery walk must reuse unchanged parsed entries")

        let explicitChange = LibraryScanner.scan(rootURL: directory.url, existingFiles: initial.files, changedPaths: [FileIdentity.identity(for: changed)])
        XCTAssertEqual(explicitChange.files, initial.files)
        XCTAssertEqual(explicitChange.parsedFileCount, 1, "an explicit file event must force a read even if metadata matches")

        try Data("# After with new text".utf8).write(to: changed)
        let updated = LibraryScanner.scan(rootURL: directory.url, existingFiles: initial.files, changedPaths: nil)
        XCTAssertEqual(updated.parsedFileCount, 1)
        XCTAssertEqual(Set(updated.files.map(\.displayTitle)), ["Keep", "After with new text"])
        XCTAssertNil(updated.failure)
        XCTAssertEqual(updated.skippedItemCount, 0)
    }

    func testRecoveryScanDetectsReplacementWithSameSizeAndModificationDate() throws {
        let directory = try CoreLibraryTemporaryDirectory()
        defer { directory.remove() }
        let file = try directory.createTextFile(named: "Note.md", contents: "# First")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let initial = LibraryScanner.scan(rootURL: directory.url)
        let replacement = try directory.createTextFile(named: "replacement", contents: "# Other")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)

        let recovery = LibraryScanner.scan(rootURL: directory.url, existingFiles: initial.files, changedPaths: nil)
        let previous = try XCTUnwrap(initial.files.first)
        let current = try XCTUnwrap(recovery.files.first)
        XCTAssertEqual(current.contentFingerprint.fileSize, previous.contentFingerprint.fileSize)
        XCTAssertEqual(current.contentFingerprint.modificationDate, previous.contentFingerprint.modificationDate)
        XCTAssertNotEqual(current.contentFingerprint.fileIdentifier, previous.contentFingerprint.fileIdentifier)
        XCTAssertEqual(current.displayTitle, "Other")
        XCTAssertEqual(recovery.parsedFileCount, 1)
    }

    func testMetadataOnlyChangeIsStoredWithoutCountingAsAContentChange() throws {
        let directory = try CoreLibraryTemporaryDirectory()
        defer { directory.remove() }
        let file = try directory.createTextFile(named: "Note.md", contents: "# Note")
        let initial = LibraryScanner.scan(rootURL: directory.url)
        // Like a Finder tag: only the status-change time moves.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let recovery = LibraryScanner.scan(rootURL: directory.url, existingFiles: initial.files, changedPaths: nil)
        XCTAssertEqual(recovery.parsedFileCount, 1)
        let diff = LibraryIndexDiff.apply(scan: recovery, to: initial.files)
        XCTAssertEqual(diff.changed, [], "the text is identical")
        XCTAssertEqual(diff.files.map(\.contentFingerprint), recovery.files.map(\.contentFingerprint),
                       "the fresher metadata is kept")

        let next = LibraryScanner.scan(rootURL: directory.url, existingFiles: diff.files, changedPaths: nil)
        XCTAssertEqual(next.parsedFileCount, 0, "the next recovery scan reuses the entry")
    }

    func testFullRereadParsesFilesWhoseMetadataLooksUnchanged() throws {
        let directory = try CoreLibraryTemporaryDirectory()
        defer { directory.remove() }
        _ = try directory.createTextFile(named: "A.md", contents: "# A")
        _ = try directory.createTextFile(named: "B.md", contents: "# B")
        let initial = LibraryScanner.scan(rootURL: directory.url)

        let reread = LibraryScanner.scan(rootURL: directory.url, existingFiles: initial.files,
                                         changedPaths: nil, reusesUnchangedFiles: false)
        XCTAssertEqual(reread.parsedFileCount, 2)
        XCTAssertEqual(reread.files.map(\.displayTitle), initial.files.map(\.displayTitle))
    }

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
