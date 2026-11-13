import Foundation
import XCTest
@testable import WaferCore

final class LibraryAvailabilityTests: XCTestCase {
    func testMissingRootIsAFailureAndEmptyRootIsSuccessful() throws {
        let directory = try AvailabilityTestDirectory()
        defer { directory.remove() }
        let missing = directory.url.appendingPathComponent("Missing", isDirectory: true)
        let unavailable = LibraryScanner.scan(rootURL: missing)
        XCTAssertEqual(unavailable.failure?.url.path, missing.path)
        XCTAssertTrue(unavailable.files.isEmpty)
        let empty = LibraryScanner.scan(rootURL: directory.url)
        XCTAssertNil(empty.failure)
        XCTAssertTrue(empty.files.isEmpty)
    }

    func testUnreadableSubtreeDoesNotPublishPartialFiles() throws {
        let directory = try AvailabilityTestDirectory()
        defer { directory.remove() }
        _ = try directory.createTextFile(named: "A.md", contents: "# A")
        let blocked = directory.url.appendingPathComponent("Z", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("# Hidden".utf8).write(to: blocked.appendingPathComponent("Hidden.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let result = LibraryScanner.scan(rootURL: directory.url)
        XCTAssertEqual(result.failure?.url.standardizedFileURL.path, blocked.standardizedFileURL.path)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testUnreadableMarkdownFileIsAFailureRatherThanADeletion() throws {
        let directory = try AvailabilityTestDirectory()
        defer { directory.remove() }
        let file = try directory.createTextFile(named: "Note.md", contents: "# Note")
        let previous = LibraryScanner.scan(rootURL: directory.url)
        XCTAssertEqual(previous.files.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let result = LibraryScanner.scan(rootURL: directory.url, existingFiles: previous.files, changedPaths: [file.path])
        XCTAssertEqual(result.failure?.url, file)
        XCTAssertTrue(result.files.isEmpty)
    }
}

private struct AvailabilityTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createTextFile(named name: String, contents: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
