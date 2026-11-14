import Foundation
import XCTest
@testable import WaferCore

final class ReviewRegressionTests: XCTestCase {
    func testHeadingIDsStayUniqueWhenLiteralTitlesMatchGeneratedSuffixes() {
        let document = MarkdownParser().parse(source: "# Foo\n# Foo\n# Foo 2\n# Foo\n", baseURL: nil)
        let output = WebKitHTMLRenderer().render(document: document)
        XCTAssertEqual(output.outlineItems.map(\.anchorID), ["foo", "foo-2", "foo-2-2", "foo-3"])
        for id in output.outlineItems.map(\.anchorID) {
            XCTAssertEqual(output.html.components(separatedBy: "id=\"\(id)\"").count - 1, 1)
        }
    }

    func testNestedWikiInputFindsOnlyTheInnermostValidSpan() {
        let text = String(repeating: "[[", count: 20_000) + "Café#Setup|Guide]]"
        let spans = WikiLinkSyntax.spans(in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.target, "Café")
        XCTAssertEqual(spans.first?.heading, "Setup")
        XCTAssertEqual(spans.first?.alias, "Guide")
        XCTAssertEqual(spans.first.map { String(text[$0.range]) }, "[[Café#Setup|Guide]]")
        XCTAssertTrue(WikiLinkSyntax.spans(in: "[[bad[single]]").isEmpty)
    }

    func testBoundedReaderReturnsPrefixAndRejectsOversizedCompleteRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.md")
        try Data("abcdefghij".utf8).write(to: url)
        let result = try BoundedFileReader.prefix(from: url, maximumByteCount: 4)
        XCTAssertEqual(result.data, Data("abcd".utf8))
        XCTAssertTrue(result.truncated)
        XCTAssertThrowsError(try BoundedFileReader.read(from: url, maximumByteCount: 4))
        XCTAssertEqual(try BoundedFileReader.read(from: url, maximumByteCount: 10), Data("abcdefghij".utf8))
    }

    func testTruncatedSourcePreservesCompleteUTF8AndUTF16Scalars() {
        let source = "# Hello 🙂!"
        let utf8 = Data(source.utf8)
        XCTAssertEqual(MarkdownSourceDecoding.decodePrefix(Data(utf8.dropLast(3)), truncated: true), "# Hello ")
        let utf16 = source.data(using: .utf16)!
        XCTAssertEqual(MarkdownSourceDecoding.decodePrefix(Data(utf16.dropLast(4)), truncated: true), "# Hello ")
    }

    func testPreviewRenderOmitsReaderMetadata() {
        let parsed = MarkdownParser().parse(source: "# Preview\n\nWords", baseURL: URL(fileURLWithPath: "/tmp/preview.md"))
        let output = WebKitHTMLRenderer(target: .preview).render(document: parsed)
        XCTAssertTrue(output.sidebarEntries.isEmpty)
        XCTAssertEqual(output.statistics, .zero)
        XCTAssertTrue(output.html.contains("<h1"))
    }
    func testIncrementalScanReusesMetadataAndDirtyPathDetectsSameSizeSameDateEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Note.md")
        try Data("# First".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        let initial = LibraryScanner.scan(rootURL: root)
        let first = try XCTUnwrap(initial.files.first)
        let cached = LibraryScanner.scan(rootURL: root, existingFiles: initial.files)
        XCTAssertEqual(cached.files, initial.files, "An unchanged metadata stamp reuses the previous parsed entry")
        XCTAssertEqual(cached.parsedFileCount, 0)
        try Data("# Other".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: first.contentFingerprint.modificationDate], ofItemAtPath: url.path)
        let recovered = LibraryScanner.scan(rootURL: root, existingFiles: initial.files, changedPaths: nil)
        XCTAssertEqual(recovered.files.first?.displayTitle, "Other", "The status-change stamp catches writes that restore mtime")
        let changed = LibraryScanner.scan(rootURL: root, existingFiles: initial.files, changedPaths: [first.identity])
        XCTAssertEqual(changed.files.first?.displayTitle, "Other")
        XCTAssertEqual(LibraryIndexDiff.apply(scan: changed, to: initial.files).changed.count, 1)
        let token = WorkCancellation()
        token.cancel()
        XCTAssertTrue(LibraryScanner.scan(rootURL: root, cancellation: token).files.isEmpty)
    }

    func testFirstRenderDoesNotReadLinkedNotesAndDemandSummaryRefreshes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = root.appendingPathComponent("Linked.md")
        let document = MarkdownParser().parse(source: "# Main\n\n[Linked](Linked.md)", baseURL: root.appendingPathComponent("Main.md"))
        let output = WebKitHTMLRenderer().render(document: document)
        let entry = try XCTUnwrap(output.sidebarEntries.first(where: { !$0.isCurrent }))
        XCTAssertTrue(entry.needsSummary)
        let cache = DocumentSummaryCache(capacity: 1)
        XCTAssertFalse(cache.summary(for: linked).isAvailable)
        try Data("# Actual title\n\nPreview body.".utf8).write(to: linked)
        XCTAssertEqual(cache.summary(for: linked).displayTitle, "Actual title")
        XCTAssertEqual(cache.summary(for: linked).previewText, "Preview body.")
    }

    func testPreviewRechecksAnAttachmentThatGrowsAfterComposition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: image)
        let composition = PreviewComposition(html: "<img src=\"cid:one\"><p>Text</p>", attachments: ["one": image], title: "Test", truncated: false)
        XCTAssertTrue(try PreviewComposer.inliningAttachments(in: composition).contains("data:image/png;base64,AQID"))
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: UInt64(PreviewComposer.attachmentByteLimit + 1))
        try handle.close()
        let html = try PreviewComposer.inliningAttachments(in: composition)
        XCTAssertTrue(html.contains("[Image omitted]"))
        XCTAssertTrue(html.contains("<p>Text</p>"))
        XCTAssertFalse(html.contains("data:image"))
    }

    func testSearchCanSkipSnippetsAndCancelWithoutChangingRanking() {
        let file = LibraryFile(fileURL: URL(fileURLWithPath: "/tmp/Note.md"), relativePathComponents: ["Note.md"],
            displayTitle: "Note", outlineItems: [], plainText: "Needle in a paragraph", searchableText: "needle in a paragraph",
            contentFingerprint: LibraryFileFingerprint(modificationDate: .distantPast, fileSize: 1))
        let complete = LibrarySearch.fullTextMatches(query: "needle", in: [file])
        let deferred = LibrarySearch.fullTextMatches(query: "needle", in: [file], includesSnippets: false)
        XCTAssertEqual(complete.map(\.score), deferred.map(\.score))
        XCTAssertEqual(complete.first?.snippet, LibrarySearch.snippet(query: "needle", in: file))
        XCTAssertEqual(deferred.first?.snippet, "")
        let token = WorkCancellation()
        token.cancel()
        XCTAssertTrue(LibrarySearch.fullTextMatches(query: "needle", in: [file], cancellation: token).isEmpty)
        XCTAssertTrue(LibrarySearch.quickOpenMatches(query: "note", in: [file], cancellation: token).isEmpty)
    }

}
