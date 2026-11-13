import Foundation
import XCTest
@testable import WaferCore

final class PreviewComposerTests: XCTestCase {
    private let composer = PreviewComposer()
    private let parser = MarkdownParser()

    func testSmallDocumentRendersHeadingAndTitle() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Note.md")
        try Data("# Preview Title\n\nBody text.".utf8).write(to: documentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)

        XCTAssertTrue(composition.html.contains("<h1 id=\"preview-title\">Preview Title</h1>"))
        XCTAssertEqual(composition.title, "Preview Title")
        XCTAssertFalse(composition.truncated)
        XCTAssertTrue(composition.attachments.isEmpty)
    }

    func testLargeDocumentTruncatesAtPreviewBudgetWithNote() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Large.md")
        let paragraph = "This paragraph is intentionally long enough to build a large markdown preview source.\n"
        let source = "# Large\n\n" + String(repeating: paragraph, count: 40_000)
        try Data(source.utf8).write(to: documentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)

        XCTAssertTrue(composition.truncated)
        XCTAssertTrue(composition.html.contains("Preview truncated — open in Wafer for the full document."))
        XCTAssertTrue(composition.html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(composition.html.contains("</html>"))
    }

    func testLocalImageAttachmentIsIncludedWhenFileExists() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Images.md")
        let imageURL = temporaryDirectory.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        try Data("# Images\n\n![Local image](image.png)".utf8).write(to: documentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)

        XCTAssertEqual(composition.attachments, ["preview-asset-1": imageURL.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertTrue(composition.html.contains("src=\"cid:preview-asset-1\""))
        XCTAssertEqual(composition.html.cidReferences, Set(composition.attachments.keys))
    }

    func testMissingLocalImageDoesNotThrowOrAttach() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Missing.md")
        try Data("# Missing\n\n![Missing](missing.png)".utf8).write(to: documentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)

        XCTAssertTrue(composition.attachments.isEmpty)
        XCTAssertTrue(composition.html.contains("[Missing image]"))
        XCTAssertTrue(composition.html.cidReferences.isEmpty)
    }

    func testAttachmentBudgetSkipsOversizedImages() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("HugeImage.md")
        let imageURL = temporaryDirectory.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: imageURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(PreviewComposer.attachmentByteLimit + 1))
        try handle.close()
        try Data("# Huge\n\n![Huge](huge.png)".utf8).write(to: documentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)

        XCTAssertTrue(composition.attachments.isEmpty)
        XCTAssertTrue(composition.html.contains("[Image omitted]"))
        XCTAssertTrue(composition.html.cidReferences.isEmpty)
    }

    func testUTF16DocumentFallsBackAfterUTF8Decode() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("UTF16.md")
        try XCTUnwrap("# UTF16 Title".data(using: .utf16)).write(to: documentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)

        XCTAssertTrue(composition.html.contains("<h1 id=\"utf16-title\">UTF16 Title</h1>"))
        XCTAssertEqual(composition.title, "UTF16 Title")
    }

    func testBOMLessUTF16LEDecodingMatchesAppAndPreviewEntryPoints() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let encodedURL = temporaryDirectory.appendingPathComponent("Encoded.md")
        let currentURL = temporaryDirectory.appendingPathComponent("Current.md")
        try "# UTF16 Title\n\nBody".utf16LittleEndianWithoutBOMData.write(to: encodedURL)
        try Data("# Current\n\n[Encoded](Encoded.md)".utf8).write(to: currentURL)

        let composition = try composer.compose(fileURL: encodedURL, isDark: true)
        let scannedFile = LibraryScanner.scan(rootURL: temporaryDirectory).files.first {
            $0.fileURL == encodedURL.standardizedFileURL.resolvingSymlinksInPath()
        }
        let currentDocument = parser.parse(
            source: try String(contentsOf: currentURL),
            baseURL: currentURL
        )
        let sidebarEntry = DocumentSidebarDataBuilder
            .sidebarEntries(from: currentDocument, assetResolver: AssetResolver())
            .first { $0.fileURL == encodedURL.standardizedFileURL.resolvingSymlinksInPath() }

        XCTAssertEqual(composition.title, "UTF16 Title")
        XCTAssertTrue(composition.html.contains("<h1 id=\"utf16-title\">UTF16 Title</h1>"))
        XCTAssertEqual(scannedFile?.displayTitle, "UTF16 Title")
        XCTAssertEqual(sidebarEntry?.displayTitle, "UTF16 Title")
    }

    func testFrontMatterTitleFallbackMatchesSidebarLibraryAndPreview() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Metadata.md")
        let currentURL = temporaryDirectory.appendingPathComponent("Current.md")
        try Data(
            """
            ---
            title: "Metadata Title"
            tags: [swift]
            ---
            Body without a heading.
            """.utf8
        ).write(to: documentURL)
        try Data("# Current\n\n[Metadata](Metadata.md)".utf8).write(to: currentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)
        let scannedFile = LibraryScanner.scan(rootURL: temporaryDirectory).files.first {
            $0.fileURL == documentURL.standardizedFileURL.resolvingSymlinksInPath()
        }
        let currentDocument = parser.parse(
            source: try String(contentsOf: currentURL),
            baseURL: currentURL
        )
        let sidebarEntry = DocumentSidebarDataBuilder
            .sidebarEntries(from: currentDocument, assetResolver: AssetResolver())
            .first { $0.fileURL == documentURL.standardizedFileURL.resolvingSymlinksInPath() }

        XCTAssertEqual(composition.title, "Metadata Title")
        XCTAssertTrue(composition.html.contains(#"<details class="md-front-matter">"#))
        XCTAssertEqual(scannedFile?.displayTitle, "Metadata Title")
        XCTAssertEqual(sidebarEntry?.displayTitle, "Metadata Title")
    }

    func testHeadingTitleStillWinsOverFrontMatterTitle() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Titled.md")
        try Data(
            """
            ---
            title: Metadata Title
            ---
            # Heading Title
            """.utf8
        ).write(to: documentURL)

        let composition = try composer.compose(fileURL: documentURL, isDark: true)
        let scannedFile = LibraryScanner.scan(rootURL: temporaryDirectory).files.first

        XCTAssertEqual(composition.title, "Heading Title")
        XCTAssertEqual(scannedFile?.displayTitle, "Heading Title")
    }

    func testDarkAndLightFlagsChangePaletteBackground() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Theme.md")
        try Data("# Theme".utf8).write(to: documentURL)

        let darkComposition = try composer.compose(fileURL: documentURL, isDark: true)
        let lightComposition = try composer.compose(fileURL: documentURL, isDark: false)

        XCTAssertEqual(darkComposition.html.cssVariable("--bg-color"), "#383E44")
        XCTAssertEqual(lightComposition.html.cssVariable("--bg-color"), "#FFFFFF")
    }

    func testUndecodableBytesThrow() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("Broken.md")
        try Data([0xFF]).write(to: documentURL)

        XCTAssertThrowsError(try composer.compose(fileURL: documentURL, isDark: true)) { error in
            XCTAssertEqual(error as? PreviewComposerError, .undecodableFile(documentURL))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        return temporaryDirectory
    }
}

private extension String {
    var utf16LittleEndianWithoutBOMData: Data {
        var data = Data()
        for codeUnit in utf16 {
            data.append(UInt8(codeUnit & 0x00FF))
            data.append(UInt8((codeUnit & 0xFF00) >> 8))
        }
        return data
    }

    func cssVariable(_ name: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let regex = try! NSRegularExpression(pattern: #"\#(escapedName):\s*([^;]+);"#)
        let range = NSRange(startIndex..<endIndex, in: self)
        guard
            let match = regex.firstMatch(in: self, range: range),
            let valueRange = Range(match.range(at: 1), in: self)
        else {
            return nil
        }

        return String(self[valueRange])
    }

    var cidReferences: Set<String> {
        let regex = try! NSRegularExpression(pattern: #"src="cid:([^"]+)""#)
        let range = NSRange(startIndex..<endIndex, in: self)
        let matches = regex.matches(in: self, range: range)
        return Set(matches.compactMap { match in
            guard let cidRange = Range(match.range(at: 1), in: self) else {
                return nil
            }
            return String(self[cidRange])
        })
    }
}
