import Foundation
import XCTest
@testable import WaferCore

final class LibraryWikiPathTests: XCTestCase {
    func testLibraryRelativeWikiPathsAgreeInReaderAndBacklinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["A", "B"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            try Data("# Guide\n\n## Setup".utf8).write(to: root.appendingPathComponent(directory + "/Guide.md"))
        }
        let hub = root.appendingPathComponent("Hub.md")
        try Data("# Hub\n\n[[B/Guide#Setup|Install]] and [[B/Guide.md]]".utf8).write(to: hub)
        let scan = LibraryScanner.scan(rootURL: root)
        let snapshot = LibrarySnapshot(files: scan.files)
        let target = root.appendingPathComponent("B/Guide.md")
        XCTAssertEqual(snapshot.wikiLinkIndex.resolve("B/Guide"), target)
        XCTAssertEqual(snapshot.wikiLinkIndex.resolve("B/Guide.md"), target)
        XCTAssertEqual(snapshot.wikiLinkIndex.resolve("b/GUIDE.MD"), target)
        XCTAssertEqual(snapshot.wikiLinkIndex.resolve("Hub.md"), hub)
        XCTAssertEqual(snapshot.wikiLinkIndex.resolve("Guide"), root.appendingPathComponent("A/Guide.md"))
        XCTAssertNil(snapshot.wikiLinkIndex.resolve("Missing/Guide"))
        XCTAssertNil(snapshot.wikiLinkIndex.resolve("../B/Guide"))
        XCTAssertEqual(WikiLinkIndex(files: scan.files.reversed()), snapshot.wikiLinkIndex)
        let document = MarkdownParser().parse(source: "[[B/Guide#Setup|Install]]", baseURL: hub)
        let html = WebKitHTMLRenderer(wikiLinkIndex: snapshot.wikiLinkIndex).render(document: document).html
        let href = try XCTUnwrap(WikiLinkURL.url(for: target, anchorID: "setup"))
        XCTAssertTrue(html.contains(href.absoluteString.replacingOccurrences(of: "&", with: "&amp;")))
        XCTAssertEqual(snapshot.backlinksByIdentity[target.path]?.map(\.sourceFileURL), [hub])
        XCTAssertEqual(BacklinkIndex.build(files: scan.files)[target.path]?.map(\.sourceFileURL), [hub])
    }
}
