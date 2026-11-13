import Foundation
import XCTest
@testable import WaferCore

final class LibraryIndexDiffTests: XCTestCase {
    func testDiffPreservesUnchangedFilesAndReportsAddedChangedRemoved() {
        let unchanged = libraryFile(path: "Unchanged.md", title: "Keep", fingerprint: 1)
        let changedOld = libraryFile(path: "Changed.md", title: "Old", fingerprint: 1)
        let removed = libraryFile(path: "Removed.md", title: "Removed", fingerprint: 1)
        let scannedUnchanged = libraryFile(path: "Unchanged.md", title: "Scanned", fingerprint: 1)
        let changedNew = libraryFile(path: "Changed.md", title: "New", fingerprint: 2)
        let added = libraryFile(path: "Added.md", title: "Added", fingerprint: 1)

        let diff = LibraryIndexDiff.apply(
            scan: LibraryScanner.Result(files: [added, changedNew, scannedUnchanged], truncated: true),
            to: [unchanged, changedOld, removed]
        )

        XCTAssertEqual(diff.files.map(\.displayTitle), ["Added", "New", "Keep"])
        XCTAssertEqual(diff.added, [added])
        XCTAssertEqual(diff.changed, [changedNew])
        XCTAssertEqual(diff.removed, [removed])
        XCTAssertTrue(diff.truncated)
    }

    func testDiffKeepsFirstExistingFileWhenExistingIdentitiesAreDuplicated() {
        let first = libraryFile(path: "Same.md", title: "First", fingerprint: 1)
        let duplicate = libraryFile(path: "Same.md", title: "Duplicate", fingerprint: 1)
        let scanned = libraryFile(path: "Same.md", title: "Scanned", fingerprint: 1)

        let diff = LibraryIndexDiff.apply(
            scan: LibraryScanner.Result(files: [scanned], truncated: false),
            to: [first, duplicate]
        )

        XCTAssertEqual(diff.files, [first])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.changed.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    private func libraryFile(path: String, title: String, fingerprint: TimeInterval) -> LibraryFile {
        LibraryFile(
            fileURL: URL(fileURLWithPath: "/tmp/\(path)"),
            relativePathComponents: [path],
            displayTitle: title,
            outlineItems: [],
            plainText: title,
            searchableText: title.libraryFoldedSearchText,
            contentFingerprint: LibraryFileFingerprint(
                modificationDate: Date(timeIntervalSince1970: fingerprint),
                fileSize: UInt64(fingerprint)
            )
        )
    }
}
