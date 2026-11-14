import AppKit
import XCTest
@testable import WaferApp
import WaferCore

@MainActor
final class MarkdownSaveBoundsTests: XCTestCase {
    func testOversizedDiskVersionIsABoundedConflictAndIsNotOverwritten() throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let url = try directory.createTextFile(named: "Large.md", contents: "original")
        let originalFingerprint = FileFingerprint.sha256Hex(for: Data("original".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(MarkdownReaderDocument.maximumSourceByteCount + 1))
        try handle.close()
        let request = MarkdownSaveRequest(
            fileURL: url, snapshot: EditSnapshot(text: "mine", revision: 1), savedText: "original",
            expectedFingerprint: originalFingerprint, format: .default, overwrite: false
        )

        let result = MarkdownSaveWorker().perform(request)

        guard case .conflict(.changedOnDisk, let diskData) = result else {
            return XCTFail("An oversized disk file must be reported as changed on disk")
        }
        XCTAssertNil(diskData, "Do not read or retain the oversized file for the conflict prompt")
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       MarkdownReaderDocument.maximumSourceByteCount + 1)
    }

}
