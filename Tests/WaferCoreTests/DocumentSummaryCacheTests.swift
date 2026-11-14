import Foundation
import XCTest
@testable import WaferCore

final class DocumentSummaryCacheTests: XCTestCase {
    /// A folder grant makes an unchanged file readable: same size and date.
    func testAnUnreadableSummaryIsReadAgainOnceTheUnchangedFileIsReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = root.appendingPathComponent("Linked.md")
        try Data("# Granted title\n\nBody.".utf8).write(to: linked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: linked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: linked.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: linked.path), "file permissions are not enforced for this user")
        let modified = try FileManager.default.attributesOfItem(atPath: linked.path)[.modificationDate] as? Date
        let cache = DocumentSummaryCache(capacity: 4)

        XCTAssertFalse(cache.summary(for: linked).isAvailable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: linked.path)

        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: linked.path)[.modificationDate] as? Date, modified)
        let summary = cache.summary(for: linked)
        XCTAssertTrue(summary.isAvailable)
        XCTAssertEqual(summary.displayTitle, "Granted title")
    }
}
